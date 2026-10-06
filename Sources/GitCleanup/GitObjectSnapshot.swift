import CryptoKit
import Darwin
import Foundation
import Security

/// Apple Git receives an app-owned, configuration-free object database only.
/// No live index, refs, worktree path, config, alternates, hooks or attributes enter it.
final class GitObjectSnapshot {
    let directory: URL
    let fingerprint: String
    private let git: URL
    private let source: InstallerDirectoryAnchor
    private let privateRoot: InstallerDirectoryAnchor
    private(set) var version = ""
    private var binaryDigest = ""
    private var removalIsSafe = true
    var provenance: String { version + "|" + binaryDigest }
    init(common: InstallerDirectoryAnchor, temporaryRoot: URL? = nil) throws {
        let objectDirectory = try GitCleanupInspectionStage.check("object directory anchor") { try common.child("objects") }
        source = objectDirectory
        let objects = GitCleanupCapture(maximumBytes: 256 * 1_024 * 1_024)
        try GitCleanupInspectionStage.check("object capture") { try objects.collect(objectDirectory) }
        guard objects.directories.keys.allSatisfy({ $0.isEmpty || $0 == "pack" || $0 == "info" || ($0.count == 2 && $0.utf8.allSatisfy(Self.hex)) }),
              objects.files.keys.allSatisfy(Self.allowedObject) else { throw GitCleanupFailure.unsupported }
        fingerprint = objects.fingerprint
        // Canonicalize only the app-owned temporary parent. Foundation may retain
        // macOS system aliases such as /var; the strict no-follow anchor must see
        // the physical path. Live repository paths never use this exception.
        let temp = try GitCleanupInspectionStage.check("temporary directory canonicalization") {
            try MoleAnalysisFiles.canonicalURL(temporaryRoot ?? FileManager.default.temporaryDirectory)
        }
        let tempAnchor = try GitCleanupInspectionStage.check("temporary directory anchor") { try InstallerDirectoryAnchor.open(temp) }
        try GitCleanupInspectionStage.check("temporary ancestry") { try tempAnchor.validateTrustedMutationAncestry() }
        let name = "MoeKit-Git-" + UUID().uuidString
        directory = temp.appendingPathComponent(name, isDirectory: true)
        git = directory.appendingPathComponent("git")
        guard mkdirat(tempAnchor.fd, name, 0o700) == 0 else { throw GitCleanupFailure.helper }
        privateRoot = try GitCleanupInspectionStage.check("private snapshot anchor") { try tempAnchor.child(name) }
        do {
            try GitCleanupInspectionStage.check("private snapshot root") { try InstallerFileAccess.validatePrivate(privateRoot.fd, directory: true) }
            try Data(name.utf8).write(to: directory.appendingPathComponent(".moekit-owner"), options: .withoutOverwriting)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("objects"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("refs"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("ref: refs/heads/private\n".utf8).write(to: directory.appendingPathComponent("HEAD"), options: .withoutOverwriting)
            try Data("[core]\nrepositoryformatversion = 0\nbare = true\n".utf8).write(to: directory.appendingPathComponent("config"), options: .withoutOverwriting)
            for path in objects.directories.keys.sorted() where !path.isEmpty {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("objects/" + path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            for (path, file) in objects.files {
                try file.data.write(to: directory.appendingPathComponent("objects/" + path), options: .withoutOverwriting)
            }
            // Read a real toolchain binary, never the /usr/bin/git install-on-demand shim.
            // Apple-signature validation follows the no-follow bounded copy.
            let candidates = ["/Library/Developer/CommandLineTools/usr/bin/git",
                "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
                "/Applications/Xcode_16.4.app/Contents/Developer/usr/bin/git"]
            var copied = false
            for path in candidates {
                guard let data = try? BoundedRegularFileReader.read(at: URL(fileURLWithPath: path), maximumBytes: 32 * 1_024 * 1_024) else { continue }
                try data.write(to: git, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: git.path)
                var code: SecStaticCode?, requirement: SecRequirement?
                guard SecStaticCodeCreateWithPath(git as CFURL, [], &code) == errSecSuccess,
                      SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
                      let code, let requirement,
                      SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw GitCleanupFailure.helper }
                binaryDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                copied = true; break
            }
            guard copied else { throw GitCleanupFailure.helper }
            version = try Self.validateVersion(run("version", "-"))
        } catch { remove(); throw error }
    }
    func remove() {
        guard removalIsSafe else { return } // retain the private snapshot after uncertain helper settlement
        do {
            try privateRoot.validate(); try InstallerFileAccess.validatePrivate(privateRoot.fd, directory: true)
            guard try GitCleanupInspection.read(privateRoot, ".moekit-owner", maximum: 128) == Data(directory.lastPathComponent.utf8) else { return }
            try FileManager.default.removeItem(at: directory)
        } catch {}
    }
    func validateSource() throws {
        let current = GitCleanupCapture(maximumBytes: 256 * 1_024 * 1_024)
        try GitCleanupInspectionStage.check("object recapture") { try current.collect(source) }
        guard current.fingerprint == fingerprint else { throw GitCleanupFailure.changed }
    }
    func treeOID(_ oid: String) throws -> String { try GitCleanupInspection.oid(run(oid, "-")) }
    func requireAncestor(_ ancestor: String, _ descendant: String) throws {
        _ = try run(ancestor, descendant)
    }
    func uniqueCommitCount(_ source: String, excluding target: String) throws -> Int {
        let data = try run(source, target, count: true)
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n"),
              text.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text.dropLast()), value >= 0 else { throw GitCleanupFailure.helper }
        return value
    }
    private func run(_ first: String, _ second: String, count: Bool = false) throws -> Data {
        try Task.checkCancellation()
        try GitCleanupInspectionStage.check("private executable namespace") {
            try privateRoot.validate(); try InstallerFileAccess.validatePrivate(privateRoot.fd, directory: true)
        }
        let executable = try GitCleanupInspectionStage.check("copied executable anchor") { try InstallerFileDescriptor(parent: privateRoot, name: "git") }
        defer { withExtendedLifetime(executable) {} }
        let expected = try GitCleanupInspectionStage.check("copied executable identity") { try InstallerFileAccess.snapshot(executable.fd) }
        guard expected.mode & UInt32(S_IFMT) == UInt32(S_IFREG), expected.uid == geteuid(), expected.mode & 0o777 == 0o700,
              expected.links == 1, expected.flags == 0 else { throw GitCleanupFailure.helper }
        try GitCleanupInspectionStage.check("executable ACL") { try InstallerFileAccess.rejectMutationGrantingACL(executable.fd) }
        let bytes = try BoundedRegularFileReader.read(descriptor: executable.fd, maximumBytes: 32 * 1_024 * 1_024)
        let named = try GitCleanupInspectionStage.check("copied executable named identity") { try InstallerFileAccess.snapshotAt(privateRoot.fd, "git") }
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == binaryDigest,
              expected == named else { throw GitCleanupFailure.changed }
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("GitObjectInspector"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw GitCleanupFailure.helper }
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = helper
        process.arguments = [git.path, directory.path, first, second] + (count ? ["count"] : [])
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.currentDirectoryURL = directory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let lifetime = GitHelperLifetime(process: process, root: privateRoot)
        defer { withExtendedLifetime(lifetime) {} }
        removalIsSafe = false
        do { try process.run() }
        catch { lifetime.settled(); removalIsSafe = true; throw error }
        // Helper buffers at most 128 stdout + 64 KiB stderr bytes and has a 15s
        // wall deadline. Drain stderr concurrently to avoid pipe backpressure.
        let drained = DispatchGroup(); drained.enter()
        DispatchQueue.global().async {
            while (try? errors.fileHandleForReading.read(upToCount: 4096))?.isEmpty == false {}
            drained.leave()
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        try? input.fileHandleForWriting.close()
        // Foundation waitUntilExit can stall even after isRunning is false in
        // a Swift-concurrency test host. Bound only the post-stdout-EOF wait;
        // the synchronous stdout read above is not an end-to-end deadline.
        guard GitHelperSettlement.observe(timeout: 2, finished: { !process.isRunning }),
              drained.wait(timeout: .now() + 2) == .success,
              process.terminationReason == .exit else { throw GitCleanupFailure.helper }
        removalIsSafe = true
        try Task.checkCancellation()
        guard result.count <= 128 else { throw GitCleanupFailure.helper }
        if process.terminationStatus == 75 { throw GitCleanupFailure.uniqueCommits }
        if [71, 72, 76].contains(process.terminationStatus) { throw GitCleanupFailure.budget }
        guard process.terminationStatus == 0 else { throw GitCleanupFailure.helper }
        return result
    }
    private static func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...102).contains(byte) }
    static func validateVersion(_ data: Data) throws -> String {
        guard data.count <= 128, let text = String(data: data, encoding: .utf8), text.hasSuffix("\n"),
              text.range(of: #"\Agit version 2\.[0-9]+\.[0-9]+ \(Apple Git-[0-9]+\)\n\z"#, options: .regularExpression) != nil else { throw GitCleanupFailure.helper }
        let fields = text.split(separator: " ")
        let version = fields[2].split(separator: ".").compactMap { Int($0) }
        let build = Int(fields[4].dropFirst(4).prefix(while: { $0.isNumber }))
        guard version.count == 3, version[1] > 39 || (version[1] == 39 && version[2] >= 5), let build, build >= 154 else { throw GitCleanupFailure.helper }
        return text.trimmingCharacters(in: .newlines)
    }
    private static func allowedObject(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return false }
        if parts[0] == "pack" {
            let name = String(parts[1])
            let suffix = [".pack", ".idx", ".rev", ".keep"].first(where: name.hasSuffix)
            guard let suffix, name.hasPrefix("pack-"), name.count == 45 + suffix.count else { return false }
            return name.dropFirst(5).dropLast(suffix.count).utf8.allSatisfy(hex)
        }
        return parts[0].count == 2 && parts[1].count == 38 && parts.joined().utf8.allSatisfy(hex)
    }
}

/// Retain the owned process and root through actual helper termination even if
/// post-EOF observation times out. The callback only releases this lifetime;
/// it never signals by PID, deletes a snapshot or retries an operation.
private final class GitHelperLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var root: InstallerDirectoryAnchor?
    init(process: Process, root: InstallerDirectoryAnchor) {
        self.process = process; self.root = root
        process.terminationHandler = { [self] _ in settled() }
    }
    func settled() {
        lock.lock(); defer { lock.unlock() }
        // Break the retaining cycle without mutating Process from its callback.
        process = nil; root = nil
    }
}

enum GitHelperSettlement {
    static func observe(timeout: TimeInterval, finished: () -> Bool) -> Bool {
        guard timeout.isFinite, timeout > 0, timeout <= 2 else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !finished() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            usleep(10_000)
        }
        return true
    }
}
