import CryptoKit
import Darwin
import Foundation
import Security

/// All Git processes see only this app-owned object snapshot. Runtime tools are
/// copies of already-installed verified Apple binaries, never downloaded tools.
/// The sole hook is our copied compiled exact-record gate. Git's fixed helper
/// dispatch may internally use its shell; this is not an OS sandbox boundary.
final class GitRemoteTransportSession {
    let objects: GitObjectSnapshot
    let endpoint: GitRemoteEndpoint
    let ref: String
    let sourceOID: String
    private let root: InstallerDirectoryAnchor
    private let tools: InstallerDirectoryAnchor
    private let hooks: InstallerDirectoryAnchor
    private let supervisor: URL
    private var binaries: [(InstallerDirectoryAnchor, String, String)] = []
    private var safelySettled = true
    private var pending: GitRemoteHelperLifetime?

    init(common: InstallerDirectoryAnchor, endpoint: GitRemoteEndpoint, ref: String, sourceOID: String) throws {
        self.endpoint = endpoint; self.ref = ref; self.sourceOID = sourceOID
        objects = try GitObjectSnapshot(common: common)
        do {
            root = try InstallerDirectoryAnchor.open(objects.directory)
            guard !root.url.path.contains(":"), root.url.path.utf8.count < 3800 else { throw GitRemotePushFailure.unavailable }
            tools = try GitFinishIO.privateChild(root, "transport-tools", create: true, exclusive: true)
            hooks = try GitFinishIO.privateChild(tools, "hooks", create: true, exclusive: true)
            guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("GitRemoteTransport") else {
                throw GitRemotePushFailure.unavailable
            }
            try Self.validateRunningBundleSeal()
            // This helper is part of MoeKit's signed bundle. Copy exactly those
            // bytes; the copied signature must retain the fixed helper identity.
            let native = try BoundedRegularFileReader.read(at: helper, maximumBytes: 8 * 1_024 * 1_024)
            supervisor = tools.url.appendingPathComponent("GitRemoteTransport")
            try Self.writeExecutable(native, at: supervisor, requirement: "identifier \"com.yusixian.MoeKit.GitRemoteTransport\"")
            try Self.writeExecutable(native, at: tools.url.appendingPathComponent("git-credential-moekit-keychain"), requirement: "identifier \"com.yusixian.MoeKit.GitRemoteTransport\"")
            try Self.writeExecutable(native, at: hooks.url.appendingPathComponent("pre-push"), requirement: "identifier \"com.yusixian.MoeKit.GitRemoteTransport\"")
            binaries = [(tools, "GitRemoteTransport", Self.digest(native)), (tools, "git-credential-moekit-keychain", Self.digest(native)), (hooks, "pre-push", Self.digest(native))]
            let candidates = ["/Library/Developer/CommandLineTools/usr",
                "/Applications/Xcode.app/Contents/Developer/usr",
                "/Applications/Xcode_16.4.app/Contents/Developer/usr"]
            var selected: [(String, Data)]?
            for base in candidates {
                guard let git = try? BoundedRegularFileReader.read(at: URL(fileURLWithPath: base + "/bin/git"), maximumBytes: 32 * 1_024 * 1_024),
                      Self.digest(git) == objects.provenance.split(separator: "|").last.map(String.init),
                      let credential = try? BoundedRegularFileReader.read(at: URL(fileURLWithPath: base + "/libexec/git-core/git-credential-osxkeychain"), maximumBytes: 32 * 1_024 * 1_024) else { continue }
                // Some installations use a symlink for remote-https. Read only
                // a regular fixed-name transport file, then copy as remote-https.
                let https = try? BoundedRegularFileReader.read(at: URL(fileURLWithPath: base + "/libexec/git-core/git-remote-https"), maximumBytes: 32 * 1_024 * 1_024)
                let http = try? BoundedRegularFileReader.read(at: URL(fileURLWithPath: base + "/libexec/git-core/git-remote-http"), maximumBytes: 32 * 1_024 * 1_024)
                guard let remote = https ?? http else { continue }
                selected = [("git", git), ("git-remote-https", remote), ("git-credential-osxkeychain", credential)]; break
            }
            guard let selected else { throw GitRemotePushFailure.unavailable }
            for (name, data) in selected {
                try Self.writeExecutable(data, at: tools.url.appendingPathComponent(name), requirement: "anchor apple")
                binaries.append((tools, name, Self.digest(data)))
            }
            // Bracket the immutable byte copies with the running app's nested
            // seal validation, and require the source helper still has those
            // exact bytes. No identifier-only substituted helper is accepted.
            try Self.validateRunningBundleSeal()
            guard try BoundedRegularFileReader.read(at: helper, maximumBytes: 8 * 1_024 * 1_024) == native else {
                throw GitRemotePushFailure.changed
            }
            try validateTools()
        } catch {
            objects.remove()
            throw error
        }
    }

    deinit { remove() }
    func remove() {
        if safelySettled || pending?.isSettled == true { objects.remove() }
    }

    func readRemote() throws -> String? {
        let output = try run(operation: "inspect", expected: "-")
        if output.status == 77 { return nil }
        guard output.status == 0 else { throw GitRemotePushFailure.inspection }
        return try Self.parseAdvertisement(output.data, ref: ref)
    }

    /// The outcome remains unverified regardless of the push command's status.
    /// Only a subsequent exact remote read can establish the observed result.
    func attemptPush(expected: String) throws {
        _ = try run(operation: "push", expected: expected)
    }

    static func parseAdvertisement(_ data: Data, ref: String) throws -> String {
        guard data.count <= 4096, let value = String(data: data, encoding: .utf8),
              value.hasSuffix("\n") else { throw GitRemotePushFailure.inspection }
        let fields = value.dropLast().split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[1] == ref, GitRemoteEndpoint.oid(String(fields[0])) else {
            throw GitRemotePushFailure.inspection
        }
        return String(fields[0])
    }

    private func validateTools() throws {
        guard try GitCleanupInspection.read(root, "config", maximum: 256) == Data("[core]\nrepositoryformatversion = 0\nbare = true\n".utf8),
              try GitCleanupInspection.read(root, "HEAD", maximum: 128) == Data("ref: refs/heads/private\n".utf8) else {
            throw GitRemotePushFailure.changed
        }
        for anchor in [root, tools, hooks] {
            try anchor.validate(); try InstallerFileAccess.validatePrivate(anchor.fd, directory: true)
        }
        for (parent, name, digest) in binaries {
            let file = try InstallerFileDescriptor(parent: parent, name: name)
            let before = try InstallerFileAccess.snapshot(file.fd)
            guard before.mode & UInt32(S_IFMT) == UInt32(S_IFREG), before.mode & 0o777 == 0o700,
                  before.uid == geteuid(), before.links == 1, before.flags == 0 else { throw GitRemotePushFailure.changed }
            try InstallerFileAccess.rejectMutationGrantingACL(file.fd)
            let bytes = try BoundedRegularFileReader.read(descriptor: file.fd, maximumBytes: 32 * 1_024 * 1_024)
            guard Self.digest(bytes) == digest, before == (try InstallerFileAccess.snapshotAt(parent.fd, name)) else {
                throw GitRemotePushFailure.changed
            }
        }
    }

    private func run(operation: String, expected: String) throws -> (status: Int32, data: Data) {
        if !safelySettled, pending?.isSettled == true { safelySettled = true; pending = nil }
        guard safelySettled else { throw GitRemotePushFailure.inspection }
        try validateTools()
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = supervisor
        process.arguments = [tools.url.path, objects.directory.path, operation, endpoint.url, ref, sourceOID, expected]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.currentDirectoryURL = objects.directory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let lifetime = GitRemoteHelperLifetime(process: process, objects: objects, root: root)
        defer { withExtendedLifetime(lifetime) {} }
        safelySettled = false; pending = lifetime
        do { try process.run() }
        catch { lifetime.settled(); safelySettled = true; throw GitRemotePushFailure.unavailable }
        let drained = DispatchGroup(); drained.enter()
        DispatchQueue.global().async {
            // The supervisor never returns raw Git/server/credential output.
            // Stable setup diagnostics are discarded too; do not log this pipe.
            while (try? errors.fileHandleForReading.read(upToCount: 4096))?.isEmpty == false {}
            drained.leave()
        }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        try? input.fileHandleForWriting.close()
        guard GitHelperSettlement.observe(timeout: 2, finished: { !process.isRunning }),
              drained.wait(timeout: .now() + 2) == .success, process.terminationReason == .exit else {
            throw GitRemotePushFailure.inspection
        }
        safelySettled = true; pending = nil
        guard bytes.count <= 4096 else { throw GitRemotePushFailure.inspection }
        return (process.terminationStatus, bytes)
    }

    /// Validate the running app's own static code and nested resource seal
    /// before trusting a bundled helper. Identifier-only helper signatures are
    /// forgeable and are not our authenticity boundary. Dynamic self validation
    /// binds the seal to this running application, including ad-hoc CI builds;
    /// release packaging independently requires the Developer ID identity.
    private static func validateRunningBundleSeal() throws {
        var running: SecCode?, installed: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(running, [], &installed) == errSecSuccess, let installed,
              SecStaticCodeCheckValidity(installed,
                SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), nil) == errSecSuccess else {
            throw GitRemotePushFailure.unavailable
        }
        var runningPath: CFURL?
        guard SecCodeCopyPath(installed, [], &runningPath) == errSecSuccess,
              let runningPath, (runningPath as URL).standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL else {
            throw GitRemotePushFailure.unavailable
        }
    }

    private static func writeExecutable(_ data: Data, at url: URL, requirement text: String) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw GitRemotePushFailure.unavailable }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private final class GitRemoteHelperLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var finished = false
    var isSettled: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    private var objects: GitObjectSnapshot?
    private var root: InstallerDirectoryAnchor?
    init(process: Process, objects: GitObjectSnapshot, root: InstallerDirectoryAnchor) {
        self.process = process; self.objects = objects; self.root = root
        process.terminationHandler = { [self] _ in settled() }
    }
    func settled() {
        lock.lock(); defer { lock.unlock() }
        finished = true; process = nil; objects = nil; root = nil
    }
}
