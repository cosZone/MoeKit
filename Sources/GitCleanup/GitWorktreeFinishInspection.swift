import CryptoKit
import Darwin
import Foundation

struct GitWorktreeFinishEvidence {
    let common: InstallerDirectoryAnchor
    let source: InstallerDirectoryAnchor
    let main: InstallerDirectoryAnchor
    let registration: InstallerDirectoryAnchor
    let admin: GitCleanupCapture
    let sourceGitFile: GitCapturedFile
    let sourceFiles: GitCleanupCapture
    let targetFiles: GitCleanupCapture?
    let sourceIndex: GitPlainIndex
    let targetIndex: GitPlainIndex?
    let sourceBranch: String
    let sourceOID: String
    let targetOID: String
    let primaryTarget: Bool
    let sourceStatus: GitFinishStatus
    let targetStatus: GitFinishStatus?
    let uniqueCommitCount: Int
    let blockers: [String]
    let fingerprint: String
    let gitVersion: String
}

enum GitWorktreeFinishInspection {
    static func inspect(_ request: GitWorktreeFinishRequest) throws -> GitWorktreeFinishEvidence {
        guard geteuid() != 0, request.project.kind == .worktree,
              let metadata = request.project.gitMetadata, metadata.isLinkedWorktree,
              let sourceBranch = request.project.branch else { throw GitCleanupFailure.unsupported }
        _ = try GitCleanupInspection.branchComponents(sourceBranch)
        _ = try GitCleanupInspection.branchComponents(request.targetBranch)
        guard sourceBranch.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping != request.targetBranch.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping else { throw GitCleanupFailure.locked }
        for path in [request.scope.path, request.project.path, metadata.commonDirectoryPath] {
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw GitCleanupFailure.scope }
        }
        let scope = try InstallerDirectoryAnchor.open(request.scope)
        let source = try InstallerDirectoryAnchor.open(request.project.url)
        let common = try InstallerDirectoryAnchor.open(URL(fileURLWithPath: metadata.commonDirectoryPath))
        guard common.name == ".git", let main = common.parent,
              GitCleanupInspection.within(source.url, scope: scope.url),
              GitCleanupInspection.within(main.url, scope: scope.url),
              source.url != scope.url, main.url != scope.url,
              !GitCleanupInspection.within(source.url, scope: main.url),
              !GitCleanupInspection.within(main.url, scope: source.url) else { throw GitCleanupFailure.scope }
        for anchor in [scope, source, common, main] {
            try anchor.validateTrustedMutationAncestry()
            try InstallerFileAccess.rejectCloudAttributes(anchor.fd)
            var volume = statfs()
            guard fstatfs(anchor.fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
                  volume.f_flags & UInt32(MNT_RDONLY) == 0, anchor.identity.device == common.identity.device else { throw GitCleanupFailure.unsupported }
        }
        var ancestor = source.parent
        while let node = ancestor, node.url != scope.url {
            var entry = stat()
            guard fstatat(node.fd, ".git", &entry, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw GitCleanupFailure.scope }
            ancestor = node.parent
        }
        for path in request.protectedPaths {
            let other = URL(fileURLWithPath: path)
            if other != main.url && other != source.url &&
                (GitCleanupInspection.within(other, scope: main.url) || GitCleanupInspection.within(other, scope: source.url)) {
                throw GitCleanupFailure.scope
            }
        }
        let admin = try captureAdmin(common)
        try validateAdmin(admin)
        let selection = GitCleanupRequest(scope: request.scope, project: request.project, baseBranch: request.targetBranch,
                                          branch: sourceBranch, action: .retireWorktree)
        guard let registration = try GitCleanupInspection.validateSelectionTopology(selection, target: source, common: common, admin: admin),
              let registrationName = registration.name else { throw GitCleanupFailure.scope }
        let prefix = "worktrees/" + registrationName + "/"
        guard admin.files[prefix + "HEAD"]?.data == Data(("ref: refs/heads/" + sourceBranch + "\n").utf8),
              admin.files[prefix + "locked"] == nil else { throw GitCleanupFailure.locked }
        try GitCleanupInspection.validateUnoccupiedHeads(admin, branch: sourceBranch, permittedHead: prefix + "HEAD")
        let primaryTarget = admin.files["HEAD"]?.data == Data(("ref: refs/heads/" + request.targetBranch + "\n").utf8)
        try GitCleanupInspection.validateUnoccupiedHeads(admin, branch: request.targetBranch, permittedHead: primaryTarget ? "HEAD" : nil)
        let sourceOID = try GitCleanupInspection.resolveReference("refs/heads/" + sourceBranch, admin: admin)
        let targetOID = try GitCleanupInspection.resolveReference("refs/heads/" + request.targetBranch, admin: admin)
        // Existing loose refs only: no implicit shadowing of packed refs, symbolic
        // refs, creation of ref directories, or rewriting another branch.
        guard admin.files["refs/heads/" + sourceBranch] != nil,
              admin.files["refs/heads/" + request.targetBranch] != nil else { throw GitCleanupFailure.unsupported }
        if let packed = admin.files["packed-refs"]?.data {
            guard try !GitCleanupInspection.packedContains(packed, branch: sourceBranch),
                  try !GitCleanupInspection.packedContains(packed, branch: request.targetBranch) else { throw GitCleanupFailure.unsupported }
        }
        guard let sourceIndexData = admin.files[prefix + "index"]?.data else { throw GitCleanupFailure.unsupported }
        let sourceIndex = try GitPlainIndex.parse(sourceIndexData)
        let sourceGitFile = GitCapturedFile(identity: try InstallerFileAccess.snapshotAt(source.fd, ".git"), data: try GitCleanupInspection.read(source, ".git", maximum: 4096))
        guard sourceGitFile.identity == (try InstallerFileAccess.snapshotAt(source.fd, ".git")) else { throw GitCleanupFailure.changed }
        let sourceFiles = GitCleanupCapture(); try sourceFiles.collect(source, skip: [".git"])
        let targetIndex: GitPlainIndex?
        let targetFiles: GitCleanupCapture?
        if primaryTarget {
            guard let bytes = admin.files["index"]?.data else { throw GitCleanupFailure.unsupported }
            targetIndex = try GitPlainIndex.parse(bytes)
            let capture = GitCleanupCapture(); try capture.collect(main, skip: [".git"]); targetFiles = capture
        } else { targetIndex = nil; targetFiles = nil }
        let objects = try GitObjectSnapshot(common: common); defer { objects.remove() }
        let sourceStatus = status(sourceIndex, files: sourceFiles, committedTree: try objects.treeOID(sourceOID))
        let targetStatus: GitFinishStatus?
        if let targetIndex, let targetFiles {
            targetStatus = status(targetIndex, files: targetFiles, committedTree: try objects.treeOID(targetOID))
        } else { targetStatus = nil }
        let unique = try objects.uniqueCommitCount(sourceOID, excluding: targetOID)
        var blockers: [String] = []
        if !sourceStatus.clean { blockers.append("The source worktree has staged, modified, untracked, ignored, or extra directory content. Preserve it before merging.") }
        if let targetStatus, !targetStatus.clean { blockers.append("The primary target worktree is not exactly clean. Preserve its changes before merging.") }
        do { try objects.requireAncestor(targetOID, sourceOID) }
        catch GitCleanupFailure.uniqueCommits { blockers.append("The branches have diverged. Resolve the merge in your Git client; both worktrees are retained.") }
        if unique == 0 { blockers.append("The source has no commits to add to this target. You can inspect retirement separately.") }
        try objects.validateSource()
        let sourceAgain = GitCleanupCapture(); try sourceAgain.collect(source, skip: [".git"])
        guard sourceAgain.fingerprint == sourceFiles.fingerprint else { throw GitCleanupFailure.changed }
        if let targetFiles {
            let again = GitCleanupCapture(); try again.collect(main, skip: [".git"])
            guard again.fingerprint == targetFiles.fingerprint else { throw GitCleanupFailure.changed }
        }
        let finalAdmin = try captureAdmin(common)
        guard finalAdmin.fingerprint == admin.fingerprint else { throw GitCleanupFailure.changed }
        return .init(common: common, source: source, main: main, registration: registration, admin: admin,
            sourceGitFile: sourceGitFile, sourceFiles: sourceFiles, targetFiles: targetFiles, sourceIndex: sourceIndex, targetIndex: targetIndex,
            sourceBranch: sourceBranch, sourceOID: sourceOID, targetOID: targetOID, primaryTarget: primaryTarget,
            sourceStatus: sourceStatus, targetStatus: targetStatus, uniqueCommitCount: unique, blockers: blockers,
            fingerprint: admin.fingerprint + String(describing: sourceGitFile.identity) + GitCleanupInspection.blobOID(sourceGitFile.data) + sourceFiles.fingerprint + (targetFiles?.fingerprint ?? "") + objects.fingerprint + objects.provenance,
            gitVersion: objects.version)
    }
    static func status(_ index: GitPlainIndex, files: GitCleanupCapture, committedTree: String) -> GitFinishStatus {
        let expected = Set(index.entries.map(\.path))
        let directories = Set(index.entries.flatMap { entry -> [String] in
            let parts = entry.path.split(separator: "/")
            return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        }).union([""])
        let changed = index.entries.filter { entry in
            guard let file = files.files[entry.path] else { return true }
            return GitCleanupInspection.blobOID(file.data) != entry.oid || ((file.identity.mode & 0o111) != 0) != entry.executable
        }.count
        return .init(stagedChanges: index.treeOID != committedTree, modifiedCount: changed,
            untrackedOrIgnoredCount: Set(files.files.keys).subtracting(expected).count,
            extraDirectoryCount: Set(files.directories.keys).subtracting(directories).count)
    }
    static func captureAdmin(_ common: InstallerDirectoryAnchor) throws -> GitCleanupCapture {
        let capture = GitCleanupCapture()
        try capture.collect(common, skip: ["objects", "hooks", "logs", "moekit-recovery"])
        return capture
    }
    static func validateAdmin(_ admin: GitCleanupCapture, permittedLocks: Set<String> = []) throws {
        try GitCleanupInspection.strictConfig(admin.files["config"]?.data)
        guard !admin.files.keys.contains(where: { ($0.hasSuffix(".lock") && !permittedLocks.contains($0)) ||
            ["shallow", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "MERGE_MSG", "AUTO_MERGE", "locked"].contains(String($0.split(separator: "/").last ?? "")) ||
            ["info/grafts", "info/attributes"].contains($0) }),
            !admin.directories.keys.contains(where: { $0 == "modules" || $0 == "rr-cache" || $0 == "refs/replace" ||
                $0.split(separator: "/").contains(where: { $0.hasPrefix("rebase-") || $0 == "sequencer" }) }) else { throw GitCleanupFailure.locked }
    }
}
