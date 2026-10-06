import Darwin
import Foundation

/// Native fast-forward only. Git reads a private object snapshot; no Git process
/// is given a live repository, configuration, index, hook, or worktree path.
actor NativeGitWorktreeFinishExecutor: GitWorktreeFinishExecuting {
    private var prepared: GitWorktreeFinishPlan?
    private var catalog: InstallerCatalogSnapshot?
    private var deadline: TimeInterval?
    private let catalogDirectory: URL
    private let checkpoint: @Sendable (GitWorktreeFinishCheckpoint) throws -> Void
    init(catalogDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MoeKit"),
         checkpoint: @escaping @Sendable (GitWorktreeFinishCheckpoint) throws -> Void = { _ in }) {
        self.catalogDirectory = catalogDirectory; self.checkpoint = checkpoint
    }
    func discard() { prepared = nil; catalog = nil; deadline = nil }
    func prepare(_ request: GitWorktreeFinishRequest) throws -> GitWorktreeFinishPlan {
        discard()
        let capturedCatalog = try catalogSnapshot(request)
        let evidence = try GitWorktreeFinishInspection.inspect(request)
        let id = UUID()
        let plan = GitWorktreeFinishPlan(id: id, request: request, sourceBranch: evidence.sourceBranch,
            sourceOID: evidence.sourceOID, targetOID: evidence.targetOID, targetWorktree: evidence.primaryTarget ? evidence.main.url : nil,
            sourceStatus: evidence.sourceStatus, targetStatus: evidence.targetStatus,
            uniqueCommitCount: evidence.uniqueCommitCount, blockers: evidence.blockers,
            recovery: evidence.common.url.appendingPathComponent("moekit-recovery/finish-" + id.uuidString),
            fingerprint: evidence.fingerprint, preparedAt: Date(), gitVersion: evidence.gitVersion)
        prepared = plan; catalog = capturedCatalog; deadline = ProcessInfo.processInfo.systemUptime + 120
        return plan
    }
    func merge(_ id: UUID, permit: GitCleanupPermit) throws -> GitWorktreeFinishResult {
        guard let plan = prepared, plan.id == id, plan.canMerge, let catalog, let deadline,
              ProcessInfo.processInfo.systemUptime < deadline else { throw GitCleanupFailure.expired }
        discard()
        let fresh = try GitWorktreeFinishInspection.inspect(plan.request)
        defer { withExtendedLifetime(fresh) {} }
        guard fresh.fingerprint == plan.fingerprint, fresh.blockers.isEmpty,
              fresh.sourceOID == plan.sourceOID, fresh.targetOID == plan.targetOID else { throw GitCleanupFailure.changed }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCleanupFailure.expired }
        try Task.checkCancellation(); try permit.consume()
        let lease = try InstallerCatalogLease(app: InstallerDirectoryAnchor.open(catalogDirectory))
        defer { withExtendedLifetime(lease) {} }
        try lease.requireSnapshot(catalog)
        let recoveryRoot = try GitFinishIO.privateChild(fresh.common, "moekit-recovery", create: true)
        let recovery = try GitFinishIO.privateChild(recoveryRoot, "finish-" + id.uuidString, create: true, exclusive: true)
        try record(plan, state: "prepared", recovery: recovery)
        let previous = try GitFinishIO.privateChild(recovery, "previous", create: true, exclusive: true)
        let staged = try GitFinishIO.privateChild(recovery, "staged", create: true, exclusive: true)
        if fresh.primaryTarget { try stage(fresh.sourceFiles, index: fresh.sourceIndex, into: staged) }
        let sourceRef = try GitFinishIO.refParent(fresh.common, branch: plan.sourceBranch)
        let targetRef = try GitFinishIO.refParent(fresh.common, branch: plan.request.targetBranch)
        var locks: [GitFinishLock] = []
        defer { withExtendedLifetime(locks) {} }
        var liveChanged = false
        do {
            // Conventional lock names protect cooperating Git writers only.
            // Editors are not fenced by these files: the UI requires closing them.
            let packed = try GitFinishLock(parent: fresh.common, name: "packed-refs.lock"); locks.append(packed)
            let source = try GitFinishLock(parent: sourceRef.0, name: sourceRef.1 + ".lock"); locks.append(source)
            let target = try GitFinishLock(parent: targetRef.0, name: targetRef.1 + ".lock"); locks.append(target)
            let sourceIndex = try GitFinishLock(parent: fresh.registration, name: "index.lock"); locks.append(sourceIndex)
            let sourceHead = try GitFinishLock(parent: fresh.registration, name: "HEAD.lock"); locks.append(sourceHead)
            var primaryIndex: GitFinishLock?
            if fresh.primaryTarget {
                let head = try GitFinishLock(parent: fresh.common, name: "HEAD.lock"); locks.append(head)
                let index = try GitFinishLock(parent: fresh.common, name: "index.lock"); locks.append(index); primaryIndex = index
                try index.write(try GitFinishIO.freshIndex(fresh.sourceIndex))
            }
            try target.write(Data((plan.sourceOID + "\n").utf8))
            let ownLocks = Set(locks.map { String($0.url.path.dropFirst(fresh.common.url.path.count + 1)) })
            try requireControls(fresh, ownLocks: ownLocks)
            try checkpoint(.beforeMutation)
            try requireControls(fresh, ownLocks: ownLocks)
            try requireWorking(fresh.sourceFiles, at: fresh.source)
            if let targetFiles = fresh.targetFiles { try requireWorking(targetFiles, at: fresh.main) }
            try record(plan, state: "retain-target-intent", recovery: recovery)
            if let targetFiles = fresh.targetFiles {
                for name in GitFinishIO.topLevel(targetFiles) {
                    try locks.forEach { try $0.validate() }
                    try requireEntry(targetFiles, name: name, at: fresh.main)
                    try InstallerFileAccess.exclusiveMove(from: fresh.main, name: name, to: previous, destinationName: name)
                    liveChanged = true
                    try requireMovedEntry(targetFiles, name: name, at: previous)
                }
                try checkpoint(.afterTargetFilesRetained)
                try record(plan, state: "install-target-intent", recovery: recovery)
                for name in GitFinishIO.topLevel(fresh.sourceFiles) {
                    try locks.forEach { try $0.validate() }
                    try InstallerFileAccess.exclusiveMove(from: staged, name: name, to: fresh.main, destinationName: name)
                    liveChanged = true
                }
                let installed = GitCleanupCapture(); try installed.collect(fresh.main, skip: [".git"])
                guard GitWorktreeFinishInspection.status(fresh.sourceIndex, files: installed, committedTree: fresh.sourceIndex.treeOID).clean else { throw GitCleanupFailure.changed }
            }
            try checkpoint(.beforeIndexCommit)
            try requireControls(fresh, ownLocks: ownLocks)
            if let primaryIndex {
                try record(plan, state: "commit-index-intent", recovery: recovery)
                try InstallerFileAccess.exclusiveMove(from: fresh.common, name: "index", to: recovery, destinationName: "previous-index")
                liveChanged = true
                try primaryIndex.commit(to: "index")
            }
            try checkpoint(.beforeRefCommit)
            try requireControls(fresh, ownLocks: ownLocks, installedIndex: fresh.primaryTarget)
            try locks.forEach { try $0.validate() }
            // Recheck the exact expected ref after the checkpoint and before the
            // only branch advance. Failure never restores over another writer.
            guard fresh.admin.files["refs/heads/" + plan.request.targetBranch]?.identity == (try InstallerFileAccess.snapshotAt(targetRef.0.fd, targetRef.1)),
                  fresh.admin.files["refs/heads/" + plan.sourceBranch]?.identity == (try InstallerFileAccess.snapshotAt(sourceRef.0.fd, sourceRef.1)),
                  try GitCleanupInspection.oid(GitCleanupInspection.read(targetRef.0, targetRef.1, maximum: 128)) == plan.targetOID,
                  try GitCleanupInspection.oid(GitCleanupInspection.read(sourceRef.0, sourceRef.1, maximum: 128)) == plan.sourceOID else { throw GitCleanupFailure.changed }
            try record(plan, state: "commit-ref-intent", recovery: recovery)
            try InstallerFileAccess.exclusiveMove(from: targetRef.0, name: targetRef.1, to: recovery, destinationName: "previous-ref")
            liveChanged = true
            try target.commit(to: targetRef.1)
            try checkpoint(.afterRefCommit)
            try requireControls(fresh, ownLocks: ownLocks, installedIndex: fresh.primaryTarget, advancedTarget: plan.request.targetBranch)
            try locks.forEach { try $0.validate() }
            guard try GitCleanupInspection.oid(GitCleanupInspection.read(targetRef.0, targetRef.1, maximum: 128)) == plan.sourceOID else { throw GitCleanupFailure.changed }
            try requireWorking(fresh.sourceFiles, at: fresh.source)
            try requireSourceLink(fresh)
            if fresh.primaryTarget {
                let finalIndex = try GitPlainIndex.parse(GitCleanupInspection.read(fresh.common, "index", maximum: GitPlainIndex.maximumBytes))
                let finalFiles = GitCleanupCapture(); try finalFiles.collect(fresh.main, skip: [".git"])
                guard finalIndex.treeOID == fresh.sourceIndex.treeOID,
                      GitWorktreeFinishInspection.status(finalIndex, files: finalFiles, committedTree: fresh.sourceIndex.treeOID).clean else { throw GitCleanupFailure.changed }
            }
            guard fsync(fresh.main.fd) == 0, fsync(fresh.common.fd) == 0, fsync(targetRef.0.fd) == 0,
                  fsync(previous.fd) == 0, fsync(recovery.fd) == 0 else { throw GitCleanupFailure.changed }
            try record(plan, state: "local-verified", recovery: recovery)
            return .init(id: id, plan: plan, verifiedOID: plan.sourceOID, recovery: recovery.url)
        } catch {
            // Keep conventional locks after a partial live change, even across
            // process exit. The receipt lists them for deliberate manual recovery.
            // No automatic rollback, force, hidden reset, or retry is safe here.
            if liveChanged { locks.forEach { $0.retainForRecovery() } }
            try? record(plan, state: liveChanged ? "retained-partial" : "stopped", recovery: recovery,
                        retainedLocks: liveChanged ? locks.filter { !$0.committed }.map(\.recoveryRecord) : [])
            throw GitCleanupFailure.partial(recovery.url.path)
        }
    }
    private func catalogSnapshot(_ request: GitWorktreeFinishRequest) throws -> InstallerCatalogSnapshot {
        let snapshot = try InstallerCatalogSnapshot.read(app: InstallerDirectoryAnchor.open(catalogDirectory))
        guard let bytes = snapshot.bytes else { throw GitCleanupFailure.scope }
        let projects = try CatalogPersistence.decodedProjectsForReadOnlyProtection(bytes)
        guard projects.contains(request.project), let common = request.project.gitMetadata?.commonDirectoryPath else { throw GitCleanupFailure.changed }
        let main = URL(fileURLWithPath: common).deletingLastPathComponent()
        for project in projects where project.id != request.project.id && project.url != main && project.kind != .group {
            guard !GitCleanupInspection.within(project.url, scope: request.project.url),
                  !GitCleanupInspection.within(project.url, scope: main) else { throw GitCleanupFailure.scope }
        }
        return snapshot
    }
    private func requireControls(_ evidence: GitWorktreeFinishEvidence, ownLocks: Set<String>, installedIndex: Bool = false, advancedTarget: String? = nil) throws {
        try requireSourceLink(evidence)
        let current = try GitWorktreeFinishInspection.captureAdmin(evidence.common)
        try GitWorktreeFinishInspection.validateAdmin(current, permittedLocks: ownLocks)
        guard Set(current.files.keys).subtracting(ownLocks) == Set(evidence.admin.files.keys),
              current.directories.keys.sorted() == evidence.admin.directories.keys.sorted() else { throw GitCleanupFailure.changed }
        for (path, file) in evidence.admin.files {
            if installedIndex && path == "index" {
                guard current.files[path]?.data == (try GitFinishIO.freshIndex(evidence.sourceIndex)) else { throw GitCleanupFailure.changed }
            } else if let advancedTarget, path == "refs/heads/" + advancedTarget {
                guard current.files[path]?.data == Data((evidence.sourceOID + "\n").utf8) else { throw GitCleanupFailure.changed }
            } else { guard current.files[path] == file else { throw GitCleanupFailure.changed } }
        }
    }
    private func requireSourceLink(_ evidence: GitWorktreeFinishEvidence) throws {
        guard evidence.sourceGitFile.identity == (try InstallerFileAccess.snapshotAt(evidence.source.fd, ".git")),
              evidence.sourceGitFile.data == (try GitCleanupInspection.read(evidence.source, ".git", maximum: 4096)) else { throw GitCleanupFailure.changed }
    }
    private func requireWorking(_ expected: GitCleanupCapture, at root: InstallerDirectoryAnchor) throws {
        let current = GitCleanupCapture(); try current.collect(root, skip: [".git"])
        guard current.fingerprint == expected.fingerprint else { throw GitCleanupFailure.changed }
    }
    private func requireEntry(_ capture: GitCleanupCapture, name: String, at parent: InstallerDirectoryAnchor) throws {
        let actual = try InstallerFileAccess.snapshotAt(parent.fd, name)
        if let directory = capture.directories[name] { guard directory == actual else { throw GitCleanupFailure.changed } }
        else { guard capture.files[name]?.identity == actual else { throw GitCleanupFailure.changed } }
    }
    private func requireMovedEntry(_ capture: GitCleanupCapture, name: String, at parent: InstallerDirectoryAnchor) throws {
        let actual = try InstallerFileAccess.snapshotAt(parent.fd, name)
        if let directory = capture.directories[name] {
            guard directory.matchesCaptured(actual) else { throw GitCleanupFailure.changed }
            let moved = GitCleanupCapture(); try moved.collect(parent.child(name))
            let expectedFiles = capture.files.filter { $0.key.hasPrefix(name + "/") }
            guard Set(moved.files.keys) == Set(expectedFiles.keys.map { String($0.dropFirst(name.count + 1)) }) else { throw GitCleanupFailure.changed }
            for (path, file) in expectedFiles {
                guard moved.files[String(path.dropFirst(name.count + 1))] == file else { throw GitCleanupFailure.changed }
            }
        } else {
            guard let file = capture.files[name], file.identity.matchesCaptured(actual),
                  try GitCleanupInspection.read(parent, name, maximum: 64 * 1_024 * 1_024) == file.data else { throw GitCleanupFailure.changed }
        }
    }
    private func stage(_ capture: GitCleanupCapture, index: GitPlainIndex, into root: InstallerDirectoryAnchor) throws {
        for path in capture.directories.keys.sorted() where !path.isEmpty {
            let parts = path.split(separator: "/").map(String.init)
            let parent = try GitFinishIO.descend(root, components: Array(parts.dropLast()))
            _ = try GitFinishIO.privateChild(parent, parts.last!, create: true, exclusive: true)
        }
        for entry in index.entries {
            guard let file = capture.files[entry.path] else { throw GitCleanupFailure.changed }
            let parts = entry.path.split(separator: "/").map(String.init)
            let parent = try GitFinishIO.descend(root, components: Array(parts.dropLast()))
            try GitFinishIO.writeNew(file.data, parent: parent, name: parts.last!, mode: entry.executable ? 0o700 : 0o600)
        }
    }
    private func record(_ plan: GitWorktreeFinishPlan, state: String, recovery: InstallerDirectoryAnchor, retainedLocks: [[String: String]] = []) throws {
        let value: [String: Any] = ["version": 1, "id": plan.id.uuidString, "state": state,
            "sourceWorktree": plan.request.project.path, "sourceBranch": plan.sourceBranch, "sourceOID": plan.sourceOID,
            "targetBranch": plan.request.targetBranch, "previousTargetOID": plan.targetOID,
            "targetWorktree": plan.targetWorktree?.path ?? "", "gitVersion": plan.gitVersion, "retainedLocks": retainedLocks,
            "warning": "Multi-step local fast-forward, not a filesystem transaction. Retain all files. No automatic rollback or remote push."]
        try GitFinishIO.writeNew(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
                                 parent: recovery, name: "receipt-" + state + ".json")
    }
}
