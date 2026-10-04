import Darwin
import Foundation

enum GitCleanupCheckpoint: Sendable, Equatable { case beforeWorktreeMove, afterWorktreeMove, beforeBranchMove, beforeRestoreMove }

protocol GitCleanupExecuting: Sendable {
    func prepare(_ request: GitCleanupRequest) async throws -> GitCleanupPlan
    func execute(_ id: UUID, permit: GitCleanupPermit) async throws -> GitCleanupReceipt
    func restore(_ id: UUID, permit: GitCleanupPermit) async throws
}

/// All user-target mutations are same-volume, exclusive renames. There is no
/// recursive deletion, force flag, shell, Git worktree remove, or Git branch -D.
actor NativeGitCleanupExecutor: GitCleanupExecuting {
    private var prepared: GitCleanupPlan?
    private var preparedCatalog: InstallerCatalogSnapshot?
    private var preparedDeadline: TimeInterval?
    private var receipts: [UUID: GitCleanupReceipt] = [:]
    private let catalogDirectory: URL
    private let checkpoint: @Sendable (GitCleanupCheckpoint) throws -> Void
    init(catalogDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MoeKit"),
         checkpoint: @escaping @Sendable (GitCleanupCheckpoint) throws -> Void = { _ in }) {
        self.catalogDirectory = catalogDirectory; self.checkpoint = checkpoint
    }
    func discard() { prepared = nil; preparedCatalog = nil; preparedDeadline = nil }
    func prepare(_ request: GitCleanupRequest) throws -> GitCleanupPlan {
        discard()
        let catalog = try GitCleanupInspectionStage.check("catalog protection") { try catalogSnapshot(request) }
        let evidence = try GitCleanupInspection.inspect(request)
        let id = UUID()
        let plan = GitCleanupPlan(id: id, request: request, commonDirectory: evidence.common.url,
            registration: evidence.registrationParent.flatMap { parent in evidence.registrationName.map { parent.url.appendingPathComponent($0) } },
            recovery: evidence.common.url.appendingPathComponent("moekit-recovery/" + id.uuidString),
            targetOID: evidence.targetOID, baseOID: evidence.baseOID, fingerprint: evidence.fingerprint,
            preparedAt: Date(), bytes: evidence.bytes, gitVersion: evidence.gitVersion)
        preparedCatalog = catalog; preparedDeadline = ProcessInfo.processInfo.systemUptime + 120; prepared = plan; return plan
    }
    func execute(_ id: UUID, permit: GitCleanupPermit) throws -> GitCleanupReceipt {
        guard let plan = prepared, let catalog = preparedCatalog, let deadline = preparedDeadline,
              plan.id == id, ProcessInfo.processInfo.systemUptime < deadline else { throw GitCleanupFailure.expired }
        discard()
        let fresh = try GitCleanupInspection.inspect(plan.request)
        defer { withExtendedLifetime(fresh) {} }
        guard fresh.fingerprint == plan.fingerprint, fresh.targetOID == plan.targetOID, fresh.baseOID == plan.baseOID,
              fresh.common.url == plan.commonDirectory else { throw GitCleanupFailure.changed }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCleanupFailure.expired }
        try Task.checkCancellation(); try permit.consume()
        let lease = try InstallerCatalogLease(app: InstallerDirectoryAnchor.open(catalogDirectory))
        defer { withExtendedLifetime(lease) {} }
        try GitCleanupInspectionStage.check("catalog lease") { try lease.requireSnapshot(catalog) }
        // Once namespace changes start, finish the bounded pair or retain an
        // explicit recovery record. Bounded read checks may still observe Task
        // cancellation; the partial path never triggers deletion or retry.
        let recoveryRoot = try ensurePrivateChild(fresh.common, "moekit-recovery")
        guard mkdirat(recoveryRoot.fd, id.uuidString, 0o700) == 0 else { throw GitCleanupFailure.occupied }
        guard fsync(fresh.common.fd) == 0, fsync(recoveryRoot.fd) == 0 else { throw GitCleanupFailure.changed }
        let recovery = try recoveryRoot.child(id.uuidString)
        try record(plan, state: "prepared", recovery: recovery)
        var payloadMoved = false
        var lockedRegistration: InstallerDirectoryAnchor?
        do {
            if plan.request.action == .retireWorktree {
                guard let registrationParent = fresh.registrationParent, let registrationName = fresh.registrationName else { throw GitCleanupFailure.changed }
                guard let registration = fresh.registration else { throw GitCleanupFailure.changed }
                let packedLock = try GitCleanupOwnedLock(parent: fresh.common, name: "packed-refs.lock")
                let targetLock = try GitCleanupOwnedLock(parent: fresh.branchParent, name: fresh.branchName + ".lock")
                let baseParent = try refParent(fresh.common, branch: plan.request.baseBranch)
                let baseLock = try GitCleanupOwnedLock(parent: baseParent.0, name: baseParent.1 + ".lock")
                defer { withExtendedLifetime((packedLock, targetLock, baseLock)) {} }
                func checkRetirementRefs() throws {
                    try packedLock.validate(); try targetLock.validate(); try baseLock.validate()
                    let refs = try GitCleanupInspection.readRefsUnderLocks(fresh.common, branch: plan.request.branch,
                        baseBranch: plan.request.baseBranch, permittedHead: "worktrees/" + registrationName + "/HEAD")
                    guard try GitCleanupInspection.resolveReference("refs/heads/" + plan.request.branch, admin: refs) == plan.targetOID,
                          try GitCleanupInspection.resolveReference("refs/heads/" + plan.request.baseBranch, admin: refs) == plan.baseOID else { throw GitCleanupFailure.changed }
                }
                try checkRetirementRefs()
                // A conventional worktree lock blocks cooperating Git removal.
                // Its exact ownership marker is retained with the registration.
                try writeNew(Data(("MoeKit retirement " + id.uuidString + "\n").utf8), parent: registration, name: "locked")
                lockedRegistration = registration
                try record(plan, state: "worktree-move-intent", recovery: recovery)
                try checkpoint(.beforeWorktreeMove)
                try checkRetirementRefs()
                try fresh.target.validate(); try registration.validate()
                try InstallerFileAccess.exclusiveMove(from: fresh.targetParent, name: plan.request.project.url.lastPathComponent, to: recovery, destinationName: "worktree")
                payloadMoved = true
                guard fresh.target.identity.matchesDirectory(try InstallerFileAccess.snapshotAt(recovery.fd, "worktree")) else { throw GitCleanupFailure.changed }
                let captured = GitCleanupCapture(allowedFiles: fresh.worktreeFiles)
                try captured.collect(recovery.child("worktree"))
                guard captured.moveFingerprint == fresh.worktreeMoveFingerprint else { throw GitCleanupFailure.changed }
                try checkpoint(.afterWorktreeMove)
                try record(plan, state: "registration-move-intent", recovery: recovery)
                try checkRetirementRefs()
                try registration.validate()
                try InstallerFileAccess.exclusiveMove(from: registrationParent, name: registrationName, to: recovery, destinationName: "registration")
                guard registration.identity.matchesDirectory(try InstallerFileAccess.snapshotAt(recovery.fd, "registration")) else { throw GitCleanupFailure.changed }
                let capturedRegistration = GitCleanupCapture()
                try capturedRegistration.collect(recovery.child("registration"), skip: ["locked"])
                guard capturedRegistration.moveFingerprint == fresh.registrationMoveFingerprint else { throw GitCleanupFailure.changed }
                guard fsync(fresh.targetParent.fd) == 0, fsync(registrationParent.fd) == 0 else { throw GitCleanupFailure.changed }
            } else {
                // Cooperating Git writers must acquire this same loose-ref lock.
                let packedLock = try GitCleanupOwnedLock(parent: fresh.common, name: "packed-refs.lock")
                let refLock = try GitCleanupOwnedLock(parent: fresh.branchParent, name: fresh.branchName + ".lock")
                let baseParent = try refParent(fresh.common, branch: plan.request.baseBranch)
                let baseLock = try GitCleanupOwnedLock(parent: baseParent.0, name: baseParent.1 + ".lock")
                defer { withExtendedLifetime((packedLock, refLock, baseLock)) {} }
                let refs = try GitCleanupInspection.readRefsUnderLocks(fresh.common, branch: plan.request.branch, baseBranch: plan.request.baseBranch)
                guard try GitCleanupInspection.resolveReference("refs/heads/" + plan.request.baseBranch, admin: refs) == plan.baseOID else { throw GitCleanupFailure.changed }
                _ = try GitCleanupInspection.validateSelectionTopology(plan.request, target: fresh.target, common: fresh.common, admin: refs)
                guard try GitCleanupInspection.oid(GitCleanupInspection.read(fresh.branchParent, fresh.branchName, maximum: 128)) == plan.targetOID else { throw GitCleanupFailure.changed }
                try record(plan, state: "branch-move-intent", recovery: recovery)
                try checkpoint(.beforeBranchMove)
                try packedLock.validate(); try refLock.validate(); try baseLock.validate()
                let finalRefs = try GitCleanupInspection.readRefsUnderLocks(fresh.common, branch: plan.request.branch, baseBranch: plan.request.baseBranch)
                guard try GitCleanupInspection.resolveReference("refs/heads/" + plan.request.baseBranch, admin: finalRefs) == plan.baseOID else { throw GitCleanupFailure.changed }
                guard fresh.branchIdentity == (try InstallerFileAccess.snapshotAt(fresh.branchParent.fd, fresh.branchName)),
                      fresh.branchIdentity == (try InstallerFileAccess.snapshot(fresh.branchFile.fd)) else { throw GitCleanupFailure.changed }
                try InstallerFileAccess.exclusiveMove(from: fresh.branchParent, name: fresh.branchName, to: recovery, destinationName: "branch")
                payloadMoved = true
                guard fresh.branchIdentity.matchesCaptured(try InstallerFileAccess.snapshotAt(recovery.fd, "branch")),
                      try GitCleanupInspection.oid(GitCleanupInspection.read(recovery, "branch", maximum: 128)) == plan.targetOID,
                      fsync(fresh.branchParent.fd) == 0 else { throw GitCleanupFailure.changed }
            }
            guard fsync(recovery.fd) == 0, fsync(fresh.common.fd) == 0 else { throw GitCleanupFailure.changed }
            let payload = plan.request.action == .retireWorktree ? "worktree" : "branch"
            let receipt = GitCleanupReceipt(id: id, plan: plan, recoveryIdentity: try InstallerFileAccess.snapshot(recovery.fd),
                payloadIdentity: try InstallerFileAccess.snapshotAt(recovery.fd, payload),
                registrationIdentity: plan.request.action == .retireWorktree ? try InstallerFileAccess.snapshotAt(recovery.fd, "registration") : nil,
                commonIdentity: try InstallerFileAccess.snapshot(fresh.common.fd), scopeIdentity: try InstallerFileAccess.snapshot(fresh.scope.fd),
                destinationParentIdentity: try InstallerFileAccess.snapshot(plan.request.action == .retireWorktree ? fresh.targetParent.fd : fresh.branchParent.fd),
                registrationParentIdentity: try fresh.registrationParent.map { try InstallerFileAccess.snapshot($0.fd) })
            try record(plan, state: "completed", recovery: recovery)
            receipts[id] = receipt
            return receipt
        } catch {
            if !payloadMoved, let registration = lockedRegistration,
               (try? GitCleanupInspection.read(registration, "locked", maximum: 256)) == Data(("MoeKit retirement " + id.uuidString + "\n").utf8) {
                _ = unlinkat(registration.fd, "locked", 0) // only this operation's own marker
            }
            try? record(plan, state: payloadMoved ? "retained-partial" : "stopped", recovery: recovery)
            throw GitCleanupFailure.partial(recovery.url.path)
        }
    }
    func restore(_ id: UUID, permit: GitCleanupPermit) throws {
        guard let receipt = receipts[id] else { throw GitCleanupFailure.expired }
        let plan = receipt.plan
        let catalog = try catalogSnapshot(plan.request, requireSelected: false)
        let recovery = try InstallerDirectoryAnchor.open(plan.recovery)
        guard receipt.recoveryIdentity.matchesDirectory(try InstallerFileAccess.snapshot(recovery.fd)) else { throw GitCleanupFailure.changed }
        try recovery.validateTrustedMutationAncestry()
        let lease = try InstallerCatalogLease(app: InstallerDirectoryAnchor.open(catalogDirectory))
        defer { withExtendedLifetime(lease) {} }
        try lease.requireSnapshot(catalog)
        let common = try InstallerDirectoryAnchor.open(plan.commonDirectory)
        let scope = try InstallerDirectoryAnchor.open(plan.request.scope)
        defer { withExtendedLifetime((common, scope, recovery)) {} }
        guard receipt.commonIdentity.matchesDirectory(try InstallerFileAccess.snapshot(common.fd)),
              receipt.scopeIdentity.matchesDirectory(try InstallerFileAccess.snapshot(scope.fd)) else { throw GitCleanupFailure.changed }
        let payload = plan.request.action == .retireWorktree ? "worktree" : "branch"
        let actual = try InstallerFileAccess.snapshotAt(recovery.fd, payload)
        guard plan.request.action == .retireWorktree ? receipt.payloadIdentity.matchesDirectory(actual) : receipt.payloadIdentity.matchesCaptured(actual) else { throw GitCleanupFailure.changed }
        let destination: InstallerDirectoryAnchor
        let name: String
        if plan.request.action == .retireWorktree {
            destination = try InstallerDirectoryAnchor.open(plan.request.project.url.deletingLastPathComponent()); name = plan.request.project.url.lastPathComponent
            defer { withExtendedLifetime(destination) {} }
            try destination.validateTrustedMutationAncestry()
            guard let registrationURL = plan.registration, let identity = receipt.registrationIdentity,
                  identity.matchesDirectory(try InstallerFileAccess.snapshotAt(recovery.fd, "registration")) else { throw GitCleanupFailure.changed }
            let registrations = try InstallerDirectoryAnchor.open(registrationURL.deletingLastPathComponent())
            defer { withExtendedLifetime(registrations) {} }
            try registrations.validateTrustedMutationAncestry()
            guard receipt.destinationParentIdentity.matchesDirectory(try InstallerFileAccess.snapshot(destination.fd)),
                  receipt.registrationParentIdentity?.matchesDirectory(try InstallerFileAccess.snapshot(registrations.fd)) == true else { throw GitCleanupFailure.changed }
            let registration = try recovery.child("registration")
            let worktree = try recovery.child("worktree")
            defer { withExtendedLifetime((registration, worktree)) {} }
            let retainedFiles = GitCleanupCapture(); try retainedFiles.collect(worktree)
            let retainedRegistration = GitCleanupCapture(); try retainedRegistration.collect(registration)
            guard try GitCleanupInspection.read(worktree, ".git", maximum: 4096) == Data(("gitdir: " + registrationURL.path + "\n").utf8),
                  try GitCleanupInspection.read(registration, "HEAD", maximum: 512) == Data(("ref: refs/heads/" + plan.request.branch + "\n").utf8),
                  try GitCleanupInspection.read(registration, "commondir", maximum: 128) == Data("../..\n".utf8),
                  try GitCleanupInspection.read(registration, "gitdir", maximum: 4096) == Data((plan.request.project.url.appendingPathComponent(".git").path + "\n").utf8),
                  try GitCleanupInspection.read(registration, "locked", maximum: 256) == Data(("MoeKit retirement " + id.uuidString + "\n").utf8) else { throw GitCleanupFailure.changed }
            let admin = GitCleanupCapture(); try admin.collect(common, skip: ["objects", "hooks", "logs", "moekit-recovery"])
            guard !admin.files.keys.contains(where: { $0.hasSuffix(".lock") }) else { throw GitCleanupFailure.locked }
            try GitCleanupInspection.strictConfig(admin.files["config"]?.data)
            try GitCleanupInspection.validateUnoccupiedHeads(admin, branch: plan.request.branch)
            let ref = "refs/heads/" + plan.request.branch
            guard try GitCleanupInspection.oid(admin.files[ref]?.data) == plan.targetOID else { throw GitCleanupFailure.changed }
            try InstallerFileAccess.assertAbsent(registrations, registrationURL.lastPathComponent)
            try InstallerFileAccess.assertAbsent(destination, name)
            try Task.checkCancellation(); try permit.consume()
            let packedLock = try GitCleanupOwnedLock(parent: common, name: "packed-refs.lock")
            let branchParent = try refParent(common, branch: plan.request.branch)
            let targetLock = try GitCleanupOwnedLock(parent: branchParent.0, name: branchParent.1 + ".lock")
            defer { withExtendedLifetime((packedLock, targetLock)) {} }
            try record(plan, state: "restore-intent", recovery: recovery)
            try checkpoint(.beforeRestoreMove)
            try packedLock.validate(); try targetLock.validate()
            let finalRefs = try GitCleanupInspection.readRefsUnderLocks(common, branch: plan.request.branch)
            guard try GitCleanupInspection.resolveReference(ref, admin: finalRefs) == plan.targetOID else { throw GitCleanupFailure.changed }
            let finalFiles = GitCleanupCapture(); try finalFiles.collect(worktree)
            let finalRegistration = GitCleanupCapture(); try finalRegistration.collect(registration)
            guard finalFiles.fingerprint == retainedFiles.fingerprint, finalRegistration.fingerprint == retainedRegistration.fingerprint else { throw GitCleanupFailure.changed }
            guard receipt.payloadIdentity.matchesDirectory(try InstallerFileAccess.snapshotAt(recovery.fd, "worktree")),
                  identity.matchesDirectory(try InstallerFileAccess.snapshotAt(recovery.fd, "registration")) else { throw GitCleanupFailure.changed }
            try InstallerFileAccess.exclusiveMove(from: recovery, name: "registration", to: registrations, destinationName: registrationURL.lastPathComponent)
            do {
                guard identity.matchesDirectory(try InstallerFileAccess.snapshotAt(registrations.fd, registrationURL.lastPathComponent)) else { throw GitCleanupFailure.changed }
                guard receipt.payloadIdentity.matchesDirectory(try InstallerFileAccess.snapshotAt(recovery.fd, payload)) else { throw GitCleanupFailure.changed }
                try InstallerFileAccess.exclusiveMove(from: recovery, name: payload, to: destination, destinationName: name)
                guard receipt.payloadIdentity.matchesDirectory(try InstallerFileAccess.snapshotAt(destination.fd, name)) else { throw GitCleanupFailure.changed }
                let restoredRegistration = try registrations.child(registrationURL.lastPathComponent)
                defer { withExtendedLifetime(restoredRegistration) {} }
                let marker = Data(("MoeKit retirement " + id.uuidString + "\n").utf8)
                guard try GitCleanupInspection.read(restoredRegistration, "locked", maximum: 256) == marker,
                      unlinkat(restoredRegistration.fd, "locked", 0) == 0 else { throw GitCleanupFailure.changed }
                guard fsync(restoredRegistration.fd) == 0, fsync(registrations.fd) == 0, fsync(destination.fd) == 0 else { throw GitCleanupFailure.changed }
            } catch { throw GitCleanupFailure.partial(recovery.url.path) }
        } else {
            let parts = try GitCleanupInspection.branchComponents(plan.request.branch)
            var parent = try common.child("refs").child("heads")
            for component in parts.dropLast() { parent = try parent.child(component) }
            destination = parent; name = parts.last!
            defer { withExtendedLifetime(destination) {} }
            try destination.validateTrustedMutationAncestry()
            let retainedBranch = try InstallerFileDescriptor(parent: recovery, name: payload)
            defer { withExtendedLifetime(retainedBranch) {} }
            try InstallerFileAccess.rejectMutationGrantingACL(retainedBranch.fd)
            guard receipt.destinationParentIdentity.matchesDirectory(try InstallerFileAccess.snapshot(destination.fd)) else { throw GitCleanupFailure.changed }
            try InstallerFileAccess.assertAbsent(destination, name)
            // A newly packed branch also counts as occupied.
            var packedStatus = stat()
            if fstatat(common.fd, "packed-refs", &packedStatus, AT_SYMLINK_NOFOLLOW) == 0 {
                let packed = try GitCleanupInspection.read(common, "packed-refs", maximum: 8 * 1_024 * 1_024)
                if try GitCleanupInspection.packedContains(packed, branch: plan.request.branch) { throw GitCleanupFailure.occupied }
            } else if errno != ENOENT { throw GitCleanupFailure.changed }
            let objects = try GitObjectSnapshot(common: common); defer { objects.remove() }
            _ = try objects.treeOID(plan.targetOID); try objects.validateSource()
            try Task.checkCancellation(); try permit.consume()
            let packedLock = try GitCleanupOwnedLock(parent: common, name: "packed-refs.lock")
            let refLock = try GitCleanupOwnedLock(parent: destination, name: name + ".lock")
            defer { withExtendedLifetime((packedLock, refLock)) {} }
            _ = try GitCleanupInspection.readRefsUnderLocks(common, branch: plan.request.branch)
            try InstallerFileAccess.assertAbsent(destination, name)
            try record(plan, state: "restore-intent", recovery: recovery)
            try checkpoint(.beforeRestoreMove)
            try packedLock.validate(); try refLock.validate()
            _ = try GitCleanupInspection.readRefsUnderLocks(common, branch: plan.request.branch)
            try InstallerFileAccess.assertAbsent(destination, name)
            guard receipt.payloadIdentity.matchesCaptured(try InstallerFileAccess.snapshot(retainedBranch.fd)),
                  receipt.payloadIdentity.matchesCaptured(try InstallerFileAccess.snapshotAt(recovery.fd, payload)),
                  try GitCleanupInspection.oid(GitCleanupInspection.read(recovery, payload, maximum: 128)) == plan.targetOID else { throw GitCleanupFailure.changed }
            try InstallerFileAccess.exclusiveMove(from: recovery, name: payload, to: destination, destinationName: name)
            guard receipt.payloadIdentity.matchesCaptured(try InstallerFileAccess.snapshotAt(destination.fd, name)),
                  try GitCleanupInspection.oid(GitCleanupInspection.read(destination, name, maximum: 128)) == plan.targetOID else { throw GitCleanupFailure.partial(recovery.url.path) }
            guard fsync(destination.fd) == 0 else { throw GitCleanupFailure.changed }
        }
        guard fsync(recovery.fd) == 0 else { throw GitCleanupFailure.changed }
        try record(plan, state: "restored", recovery: recovery)
        receipts[id] = nil
    }
    private func ensurePrivateChild(_ parent: InstallerDirectoryAnchor, _ name: String) throws -> InstallerDirectoryAnchor {
        if mkdirat(parent.fd, name, 0o700) != 0, errno != EEXIST { throw GitCleanupFailure.changed }
        let child = try parent.child(name)
        try InstallerFileAccess.validatePrivate(child.fd, directory: true)
        return child
    }
    private func refParent(_ common: InstallerDirectoryAnchor, branch: String) throws -> (InstallerDirectoryAnchor, String) {
        let parts = try GitCleanupInspection.branchComponents(branch)
        var parent = try common.child("refs").child("heads")
        for component in parts.dropLast() { parent = try parent.child(component) }
        return (parent, parts.last!)
    }
    private func catalogSnapshot(_ request: GitCleanupRequest, requireSelected: Bool = true) throws -> InstallerCatalogSnapshot {
        let app = try InstallerDirectoryAnchor.open(catalogDirectory)
        let snapshot = try InstallerCatalogSnapshot.read(app: app)
        guard let bytes = snapshot.bytes else { throw GitCleanupFailure.scope }
        let projects = try CatalogPersistence.decodedProjectsForReadOnlyProtection(bytes)
        if requireSelected {
            guard projects.contains(where: { $0 == request.project }) else { throw GitCleanupFailure.changed }
        }
        if request.action == .retireWorktree {
            for project in projects where project.id != request.project.id {
                let path = URL(fileURLWithPath: project.path)
                guard !GitCleanupInspection.within(path, scope: request.project.url),
                      !GitCleanupInspection.within(request.project.url, scope: path) else { throw GitCleanupFailure.scope }
            }
        }
        return snapshot
    }
    private func record(_ plan: GitCleanupPlan, state: String, recovery: InstallerDirectoryAnchor) throws {
        let value: [String: Any] = ["version": 1, "id": plan.id.uuidString, "state": state,
            "action": plan.request.action.rawValue, "originalWorktree": plan.request.project.path,
            "registration": plan.registration?.path ?? "", "branch": plan.request.branch,
            "branchOID": plan.targetOID, "baseBranch": plan.request.baseBranch, "baseOID": plan.baseOID,
            "commonDirectory": plan.commonDirectory.path, "gitVersion": plan.gitVersion, "recordedAt": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try writeNew(data, parent: recovery, name: "receipt-" + state + ".json")
    }
    private func writeNew(_ data: Data, parent: InstallerDirectoryAnchor, name: String) throws {
        try parent.validate()
        let fd = openat(parent.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GitCleanupFailure.occupied }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var remaining = buffer.count, offset = 0
            while remaining > 0 {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw GitCleanupFailure.changed }
                remaining -= count; offset += count
            }
        }
        guard fsync(fd) == 0, fsync(parent.fd) == 0 else { throw GitCleanupFailure.changed }
    }
}

/// Cooperating Git lock names, acquired only after confirmation. Never remove
/// a replacement lock; a retained descriptor and exact named identity own cleanup.
private final class GitCleanupOwnedLock {
    private let parent: InstallerDirectoryAnchor
    private let name: String
    private let fd: Int32
    private let identity: InstallerFileSnapshot
    init(parent: InstallerDirectoryAnchor, name: String) throws {
        self.parent = parent; self.name = name
        try parent.validate(); try InstallerFileAccess.rejectMutationGrantingACL(parent.fd)
        let opened = openat(parent.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard opened >= 0 else { throw GitCleanupFailure.locked }
        fd = opened
        do {
            try InstallerFileAccess.validatePrivate(opened, directory: false)
            identity = try InstallerFileAccess.snapshot(opened)
            guard fsync(opened) == 0, fsync(parent.fd) == 0 else { throw GitCleanupFailure.changed }
        } catch {
            if let held = try? InstallerFileAccess.snapshot(opened), let named = try? InstallerFileAccess.snapshotAt(parent.fd, name), held == named {
                _ = unlinkat(parent.fd, name, 0); _ = fsync(parent.fd)
            }
            close(opened); throw error
        }
    }
    deinit {
        do { try validate(); _ = unlinkat(parent.fd, name, 0); _ = fsync(parent.fd) } catch {}
        close(fd)
    }
    func validate() throws {
        try parent.validate()
        guard identity == (try InstallerFileAccess.snapshot(fd)), identity == (try InstallerFileAccess.snapshotAt(parent.fd, name)) else { throw GitCleanupFailure.changed }
    }
}
