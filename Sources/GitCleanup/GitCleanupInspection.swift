import CryptoKit
import Darwin
import Foundation

struct GitCapturedFile: Equatable {
    let identity: InstallerFileSnapshot
    let data: Data
}

/// Bounded descriptor-relative capture. No repository program or configuration is executed.
final class GitCleanupCapture {
    var files: [String: GitCapturedFile] = [:]
    var directories: [String: InstallerFileSnapshot] = [:]
    var bytes = 0
    private var count = 0
    private let deadline = ProcessInfo.processInfo.systemUptime + 30
    private let maximumBytes: Int
    private let allowedFiles: Set<String>?
    private let allowedDirectories: Set<String>?
    init(maximumBytes: Int = 64 * 1_024 * 1_024, allowedFiles: Set<String>? = nil) {
        self.maximumBytes = maximumBytes; self.allowedFiles = allowedFiles
        self.allowedDirectories = allowedFiles.map { files in
            Set(files.flatMap { path -> [String] in
                let parts = path.split(separator: "/")
                return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
            }).union([""])
        }
    }
    func collect(_ directory: InstallerDirectoryAnchor, prefix: String = "", skip: Set<String> = []) throws {
        try Task.checkCancellation()
        guard prefix.split(separator: "/").count < 48 else { throw GitCleanupFailure.budget }
        try directory.validate()
        try InstallerFileAccess.rejectMutationGrantingACL(directory.fd)
        try InstallerFileAccess.rejectCloudAttributes(directory.fd)
        directories[prefix] = try InstallerFileAccess.snapshot(directory.fd)
        let duplicate = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }; throw GitCleanupFailure.changed
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let next = readdir(stream) else {
                guard errno == 0 else { throw GitCleanupFailure.changed }; break
            }
            guard let name = withUnsafeBytes(of: next.pointee.d_name, { String(validatingCString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }) else { throw GitCleanupFailure.unsupported }
            if name == "." || name == ".." || (prefix.isEmpty && skip.contains(name)) { continue }
            try Task.checkCancellation()
            count += 1
            guard count <= 20_000, ProcessInfo.processInfo.systemUptime < deadline else { throw GitCleanupFailure.budget }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if let allowedFiles, let allowedDirectories,
               !allowedFiles.contains(path) && !allowedDirectories.contains(path) { throw GitCleanupFailure.dirty }
            let snapshot = try InstallerFileAccess.snapshotAt(directory.fd, name)
            guard snapshot.uid == geteuid(), snapshot.mode & 0o022 == 0, snapshot.flags == 0 else { throw GitCleanupFailure.unsupported }
            switch snapshot.mode & UInt32(S_IFMT) {
            case UInt32(S_IFDIR):
                if let allowedDirectories, !allowedDirectories.contains(path) { throw GitCleanupFailure.dirty }
                try collect(directory.child(name), prefix: path)
            case UInt32(S_IFREG):
                guard snapshot.links == 1, snapshot.bytes >= 0, snapshot.bytes <= 64 * 1_024 * 1_024 else { throw GitCleanupFailure.budget }
                let file = try InstallerFileDescriptor(parent: directory, name: name)
                try InstallerFileAccess.rejectMutationGrantingACL(file.fd)
                try InstallerFileAccess.rejectCloudAttributes(file.fd)
                let data = try BoundedRegularFileReader.read(descriptor: file.fd, maximumBytes: 64 * 1_024 * 1_024)
                guard snapshot == (try InstallerFileAccess.snapshot(file.fd)), snapshot == (try InstallerFileAccess.snapshotAt(directory.fd, name)) else { throw GitCleanupFailure.changed }
                bytes += data.count
                guard bytes <= maximumBytes else { throw GitCleanupFailure.budget }
                files[path] = .init(identity: snapshot, data: data)
            default: throw GitCleanupFailure.unsupported
            }
        }
        try directory.validate()
        guard directories[prefix] == (try InstallerFileAccess.snapshot(directory.fd)) else { throw GitCleanupFailure.changed }
    }
    var fingerprint: String {
        makeFingerprint(normalizeRoot: false)
    }
    /// Moving a captured directory changes root metadata. Child identity,
    /// contents and enumeration remain exact; only the moved root is normalized.
    var moveFingerprint: String { makeFingerprint(normalizeRoot: true) }
    private func makeFingerprint(normalizeRoot: Bool) -> String {
        var hash = SHA256()
        for path in directories.keys.sorted() {
            let value = directories[path]!
            let description = normalizeRoot && path.isEmpty
                ? "\(value.device)|\(value.inode)|\(value.mode)|\(value.uid)|\(value.gid)|\(value.flags)"
                : String(describing: value)
            hash.update(data: Data(("D" + path + description).utf8))
        }
        for path in files.keys.sorted() {
            hash.update(data: Data(("F" + path + String(describing: files[path]!.identity)).utf8))
            hash.update(data: files[path]!.data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct GitCleanupEvidence {
    let common: InstallerDirectoryAnchor
    let scope: InstallerDirectoryAnchor
    let targetParent: InstallerDirectoryAnchor
    let registrationParent: InstallerDirectoryAnchor?
    let registrationName: String?
    let branchParent: InstallerDirectoryAnchor
    let branchName: String
    let targetOID: String
    let baseOID: String
    let fingerprint: String
    let bytes: Int64
    let gitVersion: String
    let target: InstallerDirectoryAnchor
    let registration: InstallerDirectoryAnchor?
    let branchFile: InstallerFileDescriptor
    let branchIdentity: InstallerFileSnapshot
    let worktreeMoveFingerprint: String?
    let registrationMoveFingerprint: String?
    let worktreeFiles: Set<String>?
}

enum GitCleanupInspection {
    static func branchComponents(_ branch: String) throws -> [String] {
        let parts = branch.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !branch.isEmpty, branch.utf8.count <= 200, parts.count <= 12, branch != "HEAD",
              !branch.contains(".."), !branch.contains("@{"), !branch.contains("\\"),
              !branch.contains(where: { $0.isWhitespace || $0.isNewline }),
              !branch.unicodeScalars.contains(where: { $0.value < 33 || CharacterSet.controlCharacters.contains($0) }),
              !branch.contains(where: { "~^:?*[".contains($0) }) else { throw GitCleanupFailure.unsupported }
        for part in parts {
            guard !part.isEmpty, !part.hasPrefix("."), !part.hasPrefix("-"), !part.hasSuffix("."), !part.hasSuffix(".lock") else { throw GitCleanupFailure.unsupported }
        }
        return parts
    }
    static func oid(_ data: Data?) throws -> String {
        guard let data, let text = String(data: data, encoding: .utf8), text.count == 41, text.hasSuffix("\n") else { throw GitCleanupFailure.unsupported }
        let value = String(text.dropLast())
        guard value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), value != String(repeating: "0", count: 40) else { throw GitCleanupFailure.unsupported }
        return value
    }
    static func strictConfig(_ data: Data?) throws {
        guard let data, data.count <= 128 * 1_024, let text = String(data: data, encoding: .utf8) else { throw GitCleanupFailure.unsupported }
        var section = ""
        let core: [String: Set<String>] = ["repositoryformatversion": ["0"], "filemode": ["true", "false"], "bare": ["false"],
            "logallrefupdates": ["true", "false"], "ignorecase": ["true", "false"], "precomposeunicode": ["true", "false"], "autocrlf": ["false"], "symlinks": ["true", "false"]]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.contains("\\") else { throw GitCleanupFailure.unsupported }
                section = String(line.dropFirst().dropLast()).lowercased().split(separator: " ").first.map(String.init) ?? ""
                guard !["include", "includeif", "filter", "extensions"].contains(section) else { throw GitCleanupFailure.unsupported }
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard !section.isEmpty, pair.count == 2, !line.hasSuffix("\\"), pair[0] != "promisor", pair[0] != "partialclonefilter" else { throw GitCleanupFailure.unsupported }
            if section == "core" { guard core[pair[0]]?.contains(pair[1]) == true else { throw GitCleanupFailure.unsupported } }
        }
    }

    static func inspect(_ request: GitCleanupRequest) throws -> GitCleanupEvidence {
        guard geteuid() != 0, request.project.kind == .worktree || request.project.kind == .repository else { throw GitCleanupFailure.unsupported }
        guard [request.scope.path, request.project.path, request.project.gitMetadata?.commonDirectoryPath ?? ""].allSatisfy({ path in
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else { throw GitCleanupFailure.scope }
        _ = try branchComponents(request.branch); _ = try branchComponents(request.baseBranch)
        guard request.branch != request.baseBranch, !["main", "master", "develop", "development", "release"].contains(request.branch.lowercased()) else { throw GitCleanupFailure.locked }
        let scope = try InstallerDirectoryAnchor.open(request.scope)
        try GitCleanupInspectionStage.check("scope ancestry") { try scope.validateTrustedMutationAncestry() }
        let target = try InstallerDirectoryAnchor.open(request.project.url)
        if request.action == .retireWorktree {
            guard !request.protectedPaths.contains(where: { path in
                let other = URL(fileURLWithPath: path)
                return within(other, scope: target.url) || within(target.url, scope: other)
            }) else { throw GitCleanupFailure.scope }
        }
        guard let targetParent = target.parent, let metadata = request.project.gitMetadata else { throw GitCleanupFailure.scope }
        let common = try InstallerDirectoryAnchor.open(URL(fileURLWithPath: metadata.commonDirectoryPath))
        for directory in [scope, target, common] {
            var volume = statfs()
            guard fstatfs(directory.fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
                  volume.f_flags & UInt32(MNT_RDONLY) == 0, directory.identity.device == common.identity.device else { throw GitCleanupFailure.unsupported }
            try InstallerFileAccess.rejectCloudAttributes(directory.fd)
        }
        guard common.name == ".git", let main = common.parent,
              within(target.url, scope: scope.url), within(main.url, scope: scope.url),
              target.url != scope.url, main.url != scope.url,
              request.action != .retireWorktree || !within(target.url, scope: main.url) else { throw GitCleanupFailure.scope }
        try GitCleanupInspectionStage.check("repository ancestry") {
            try common.validateTrustedMutationAncestry(); try target.validateTrustedMutationAncestry()
        }
        var ancestor = target.parent
        while let node = ancestor, node.url != scope.url {
            var status = stat()
            guard fstatat(node.fd, ".git", &status, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw GitCleanupFailure.scope }
            ancestor = node.parent
        }
        let admin = GitCleanupCapture()
        try GitCleanupInspectionStage.check("metadata capture") { try admin.collect(common, skip: ["objects", "hooks", "logs", "moekit-recovery"]) }
        guard admin.files["worktrees"] == nil else { throw GitCleanupFailure.unsupported }
        guard !admin.files.keys.contains(where: { $0.hasSuffix(".lock") || ["shallow", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "MERGE_MSG", "AUTO_MERGE"].contains(String($0.split(separator: "/").last ?? "")) || ["info/grafts", "info/attributes"].contains($0) }),
              !admin.directories.keys.contains(where: { $0 == "modules" || $0.split(separator: "/").contains(where: { $0.hasPrefix("rebase-") || $0 == "sequencer" }) || $0 == "rr-cache" || $0 == "refs/replace" }) else { throw GitCleanupFailure.locked }
        try strictConfig(admin.files["config"]?.data)
        let targetRef = "refs/heads/" + request.branch, baseRef = "refs/heads/" + request.baseBranch
        // Loose-only deletion avoids rewriting unrelated packed references.
        let targetOID = try oid(admin.files[targetRef]?.data)
        if let packed = admin.files["packed-refs"]?.data {
            guard try !packedContains(packed, branch: request.branch) else { throw GitCleanupFailure.unsupported }
        }
        let baseOID = try resolveReference(baseRef, admin: admin)
        guard let mainHead = admin.files["HEAD"]?.data else { throw GitCleanupFailure.unsupported }
        try validateHead(mainHead)
        guard !headMatches(mainHead, branch: request.branch) else { throw GitCleanupFailure.locked }
        let indexHeads = admin.files.filter { $0.key.hasPrefix("worktrees/") && $0.key.hasSuffix("/HEAD") && $0.key.split(separator: "/").count == 3 }
        for (_, file) in indexHeads { try validateHead(file.data) }
        for path in admin.directories.keys where path.hasPrefix("worktrees/") && path.split(separator: "/").count == 2 {
            guard admin.files[path + "/HEAD"] != nil else { throw GitCleanupFailure.unsupported }
        }
        let selectedRegistration = try validateSelectionTopology(request, target: target, common: common, admin: admin)
        var registrationParent: InstallerDirectoryAnchor?, registrationName: String?
        var workingFingerprint = ""
        var size: Int64 = 0
        var gitVersion = ""
        var worktreeMoveFingerprint: String?, registrationMoveFingerprint: String?
        var worktreeFiles: Set<String>?
        if request.action == .retireWorktree {
            guard request.project.kind == .worktree, metadata.isLinkedWorktree,
                  let path = String(data: try read(target, ".git", maximum: 4096), encoding: .utf8),
                  path.hasPrefix("gitdir: "), path.hasSuffix("\n") else { throw GitCleanupFailure.unsupported }
            let registrationURL = URL(fileURLWithPath: String(path.dropFirst(8).dropLast()))
            guard registrationURL.path == metadata.gitDirectoryPath, registrationURL.deletingLastPathComponent().path == common.url.appendingPathComponent("worktrees").path else { throw GitCleanupFailure.scope }
            let name = registrationURL.lastPathComponent
            let prefix = "worktrees/" + name + "/"
            guard admin.files[prefix + "HEAD"]?.data == Data(("ref: " + targetRef + "\n").utf8),
                  admin.files[prefix + "commondir"]?.data == Data("../..\n".utf8),
                  admin.files[prefix + "gitdir"]?.data == Data((target.url.appendingPathComponent(".git").path + "\n").utf8),
                  admin.files[prefix + "locked"] == nil,
                  indexHeads.filter({ headMatches($0.value.data, branch: request.branch) }).count == 1,
                  let indexData = admin.files[prefix + "index"]?.data else { throw GitCleanupFailure.locked }
            let index = try GitPlainIndex.parse(indexData)
            let expected = Set(index.entries.map(\.path)).union([".git"])
            let working = GitCleanupCapture(allowedFiles: expected)
            try GitCleanupInspectionStage.check("worktree capture") { try working.collect(target) }
            guard Set(working.files.keys) == expected else { throw GitCleanupFailure.dirty }
            let expectedDirectories = Set(index.entries.flatMap { entry -> [String] in
                let parts = entry.path.split(separator: "/"); return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
            }).union([""])
            guard Set(working.directories.keys) == expectedDirectories else { throw GitCleanupFailure.dirty }
            for entry in index.entries {
                guard let file = working.files[entry.path], ((file.identity.mode & 0o111) != 0) == entry.executable,
                      blobOID(file.data) == entry.oid else { throw GitCleanupFailure.dirty }
            }
            let objects = try GitObjectSnapshot(common: common)
            defer { objects.remove() }
            guard try objects.treeOID(targetOID) == index.treeOID else { throw GitCleanupFailure.dirty }
            try objects.requireAncestor(targetOID, baseOID)
            try objects.validateSource()
            let finalWorking = GitCleanupCapture(allowedFiles: expected); try finalWorking.collect(target)
            guard finalWorking.fingerprint == working.fingerprint else { throw GitCleanupFailure.changed }
            workingFingerprint = working.fingerprint + objects.fingerprint + objects.provenance
            gitVersion = objects.version
            size = Int64(working.bytes)
            registrationParent = try common.child("worktrees"); registrationName = name
            worktreeMoveFingerprint = working.moveFingerprint; worktreeFiles = expected
            guard let selectedRegistration else { throw GitCleanupFailure.changed }
            let registrationCapture = GitCleanupCapture(); try registrationCapture.collect(selectedRegistration)
            registrationMoveFingerprint = registrationCapture.moveFingerprint
        } else {
            guard !indexHeads.contains(where: { headMatches($0.value.data, branch: request.branch) }) else { throw GitCleanupFailure.locked }
            let objects = try GitObjectSnapshot(common: common); defer { objects.remove() }
            try objects.requireAncestor(targetOID, baseOID)
            try objects.validateSource()
            workingFingerprint = objects.fingerprint + objects.provenance
            gitVersion = objects.version
        }
        let branchParts = try branchComponents(request.branch)
        var branchParent = try common.child("refs").child("heads")
        for name in branchParts.dropLast() { branchParent = try branchParent.child(name) }
        // A packed-only nested base may have no loose parent directory. Do not
        // offer a plan that would need unconfirmed namespace creation for its lock.
        do {
            var baseParent = try common.child("refs").child("heads")
            for component in try branchComponents(request.baseBranch).dropLast() { baseParent = try baseParent.child(component) }
            try baseParent.validateTrustedMutationAncestry()
        } catch { throw GitCleanupFailure.unsupported }
        let finalAdmin = GitCleanupCapture()
        try finalAdmin.collect(common, skip: ["objects", "hooks", "logs", "moekit-recovery"])
        guard finalAdmin.fingerprint == admin.fingerprint else { throw GitCleanupFailure.changed }
        let branchFile = try InstallerFileDescriptor(parent: branchParent, name: branchParts.last!)
        let branchIdentity = try InstallerFileAccess.snapshot(branchFile.fd)
        guard branchIdentity == admin.files[targetRef]?.identity else { throw GitCleanupFailure.changed }
        try scope.validate(); try target.validate(); try common.validate()
        return .init(common: common, scope: scope, targetParent: targetParent, registrationParent: registrationParent,
                     registrationName: registrationName, branchParent: branchParent, branchName: branchParts.last!,
                     targetOID: targetOID, baseOID: baseOID, fingerprint: admin.fingerprint + workingFingerprint,
                     bytes: size, gitVersion: gitVersion, target: target, registration: selectedRegistration,
                     branchFile: branchFile, branchIdentity: branchIdentity, worktreeMoveFingerprint: worktreeMoveFingerprint,
                     registrationMoveFingerprint: registrationMoveFingerprint, worktreeFiles: worktreeFiles)
    }
    static func within(_ url: URL, scope: URL) -> Bool { url.pathComponents.starts(with: scope.pathComponents) }
    static func validateHead(_ data: Data) throws {
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("ref: refs/heads/"), text.hasSuffix("\n") {
            _ = try branchComponents(String(text.dropFirst(16).dropLast()))
        } else { _ = try oid(data) }
    }
    static func headMatches(_ data: Data, branch: String) -> Bool {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("ref: refs/heads/"), text.hasSuffix("\n") else { return false }
        return branchKey(String(text.dropFirst(16).dropLast())) == branchKey(branch)
    }
    private static func branchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    static func validateSelectionTopology(_ request: GitCleanupRequest, target: InstallerDirectoryAnchor,
                                                  common: InstallerDirectoryAnchor, admin: GitCleanupCapture) throws -> InstallerDirectoryAnchor? {
        guard let metadata = request.project.gitMetadata else { throw GitCleanupFailure.scope }
        if request.project.kind == .repository {
            guard !metadata.isLinkedWorktree, target.url == common.parent?.url,
                  metadata.gitDirectoryPath == common.url.path,
                  try target.child(".git").identity.matchesDirectory(InstallerFileAccess.snapshot(common.fd)) else { throw GitCleanupFailure.scope }
            return nil
        }
        guard metadata.isLinkedWorktree,
              let text = String(data: try read(target, ".git", maximum: 4096), encoding: .utf8),
              text.hasPrefix("gitdir: /"), text.hasSuffix("\n") else { throw GitCleanupFailure.scope }
        let path = String(text.dropFirst(8).dropLast())
        let url = URL(fileURLWithPath: path)
        guard path == metadata.gitDirectoryPath,
              url.deletingLastPathComponent() == common.url.appendingPathComponent("worktrees") else { throw GitCleanupFailure.scope }
        let prefix = "worktrees/" + url.lastPathComponent + "/"
        guard admin.files[prefix + "commondir"]?.data == Data("../..\n".utf8),
              admin.files[prefix + "gitdir"]?.data == Data((target.url.appendingPathComponent(".git").path + "\n").utf8),
              let head = admin.files[prefix + "HEAD"]?.data else { throw GitCleanupFailure.scope }
        try validateHead(head)
        return try common.child("worktrees").child(url.lastPathComponent)
    }
    static func read(_ parent: InstallerDirectoryAnchor, _ name: String, maximum: Int) throws -> Data {
        let file = try InstallerFileDescriptor(parent: parent, name: name)
        let result = try BoundedRegularFileReader.read(descriptor: file.fd, maximumBytes: maximum)
        try parent.validate(); return result
    }
    static func blobOID(_ data: Data) -> String {
        var sha = Insecure.SHA1(); sha.update(data: Data("blob \(data.count)\0".utf8)); sha.update(data: data)
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func resolveReference(_ ref: String, admin: GitCleanupCapture) throws -> String {
        if let value = admin.files[ref] { return try oid(value.data) }
        guard let data = admin.files["packed-refs"]?.data, let value = try packedRefs(data)[ref] else { throw GitCleanupFailure.unsupported }
        return value
    }
    static func packedContains(_ data: Data, branch: String) throws -> Bool {
        try packedRefs(data).keys.contains { $0.hasPrefix("refs/heads/") && branchKey(String($0.dropFirst(11))) == branchKey(branch) }
    }
    private static func packedRefs(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw GitCleanupFailure.unsupported }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("^") { _ = try oid(Data((line.dropFirst() + "\n").utf8)); continue }
            let pair = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[1].hasPrefix("refs/"), !pair[1].contains(where: { $0.isWhitespace }), result[String(pair[1])] == nil else { throw GitCleanupFailure.unsupported }
            result[String(pair[1])] = try oid(Data((pair[0] + "\n").utf8))
        }
        return result
    }
    static func readRefsUnderLocks(_ common: InstallerDirectoryAnchor, branch: String, baseBranch: String? = nil,
                                   permittedHead: String? = nil) throws -> GitCleanupCapture {
        let admin = GitCleanupCapture()
        try admin.collect(common, skip: ["objects", "hooks", "logs", "moekit-recovery", "packed-refs.lock"])
        let ownLocks = Set(["refs/heads/" + branch + ".lock"] + (baseBranch.map { ["refs/heads/" + $0 + ".lock"] } ?? []))
        guard !admin.files.keys.contains(where: { $0.hasSuffix(".lock") && !ownLocks.contains($0) }) else { throw GitCleanupFailure.locked }
        try strictConfig(admin.files["config"]?.data)
        try validateUnoccupiedHeads(admin, branch: branch, permittedHead: permittedHead)
        if let packed = admin.files["packed-refs"]?.data, try packedContains(packed, branch: branch) { throw GitCleanupFailure.occupied }
        return admin
    }
    static func validateUnoccupiedHeads(_ admin: GitCleanupCapture, branch: String, permittedHead: String? = nil) throws {
        guard let head = admin.files["HEAD"]?.data else { throw GitCleanupFailure.unsupported }
        try validateHead(head)
        for (path, file) in admin.files where path == "HEAD" || (path.hasPrefix("worktrees/") && path.hasSuffix("/HEAD") && path.split(separator: "/").count == 3) {
            try validateHead(file.data)
            if headMatches(file.data, branch: branch) {
                guard path == permittedHead, file.data == Data(("ref: refs/heads/" + branch + "\n").utf8) else { throw GitCleanupFailure.locked }
            }
        }
        for path in admin.directories.keys where path.hasPrefix("worktrees/") && path.split(separator: "/").count == 2 {
            guard admin.files[path + "/HEAD"] != nil else { throw GitCleanupFailure.unsupported }
        }
        if let permittedHead {
            guard admin.files[permittedHead]?.data == Data(("ref: refs/heads/" + branch + "\n").utf8) else { throw GitCleanupFailure.changed }
        }
    }
}
