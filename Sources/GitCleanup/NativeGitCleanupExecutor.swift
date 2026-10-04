import Darwin
import Foundation

enum GitCleanupCheckpoint: Sendable, Equatable { case beforeWorktreeMove, afterWorktreeMove, beforeBranchMove, beforeRestoreMove }

/// All user-target mutations are same-volume, exclusive renames. There is no
/// recursive deletion, force flag, shell, Git worktree remove, or Git branch -D.
actor NativeGitCleanupExecutor {
    private var prepared: GitCleanupPlan?
    private var preparedCatalog: InstallerCatalogSnapshot?
    private var receipts: [UUID: GitCleanupReceipt] = [:]
    private let catalogDirectory: URL
    private let checkpoint: @Sendable (GitCleanupCheckpoint) throws -> Void
    init(catalogDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MoeKit"),
         checkpoint: @escaping @Sendable (GitCleanupCheckpoint) throws -> Void = { _ in }) {
        self.catalogDirectory = catalogDirectory; self.checkpoint = checkpoint
    }
    func discard() { prepared = nil; preparedCatalog = nil }
    func prepare(_ request: GitCleanupRequest) throws -> GitCleanupPlan {
        discard()
        let catalog = try catalogSnapshot(request)
        let evidence = try GitCleanupInspection.inspect(request)
        let id = UUID()
        let plan = GitCleanupPlan(id: id, request: request, commonDirectory: evidence.common.url,
            registration: evidence.registrationParent.flatMap { parent in evidence.registrationName.map { parent.url.appendingPathComponent($0) } },
            recovery: evidence.common.url.appendingPathComponent("moekit-recovery/" + id.uuidString),
            targetOID: evidence.targetOID, baseOID: evidence.baseOID, fingerprint: evidence.fingerprint,
            preparedAt: Date(), bytes: evidence.bytes, gitVersion: evidence.gitVersion)
        preparedCatalog = catalog; prepared = plan; return plan
    }
    func execute(_ id: UUID, permit: GitCleanupPermit) throws -> GitCleanupReceipt {
        guard let plan = prepared, let catalog = preparedCatalog, plan.id == id, Date().timeIntervalSince(plan.preparedAt) < 120 else { throw GitCleanupFailure.expired }
        discard()
        let fresh = try GitCleanupInspection.inspect(plan.request)
        guard fresh.fingerprint == plan.fingerprint, fresh.targetOID == plan.targetOID, fresh.baseOID == plan.baseOID,
              fresh.common.url == plan.commonDirectory else { throw GitCleanupFailure.changed }
        guard Date().timeIntervalSince(plan.preparedAt) < 120 else { throw GitCleanupFailure.expired }
        try Task.checkCancellation(); try permit.consume()
        let lease = try InstallerCatalogLease(app: InstallerDirectoryAnchor.open(catalogDirectory))
        defer { withExtendedLifetime(lease) {} }
        try lease.requireSnapshot(catalog)
        // No cancellation after the first mutation: finish the bounded pair or
        // leave an explicit recovery record. Cancellation never triggers deletion.
        let recoveryRoot = try ensurePrivateChild(fresh.common, "moekit-recovery")
        guard mkdirat(recoveryRoot.fd, id.uuidString, 0o700) == 0 else { throw GitCleanupFailure.occupied }
        let recovery = try recoveryRoot.child(id.uuidString)
        try record(plan, state: "prepared", recovery: recovery)
        var payloadMoved = false
        var lockedRegistration: InstallerDirectoryAnchor?
        do {
            if plan.request.action == .retireWorktree {
                guard let registrationParent = fresh.registrationParent, let registrationName = fresh.registrationName else { throw GitCleanupFailure.changed }
                let registration = try registrationParent.child(registrationName)
                // A conventional worktree lock blocks cooperating Git removal.
                // Its exact ownership marker is retained with the registration.
                try writeNew(Data(("MoeKit retirement " + id.uuidString + "\n").utf8), parent: registration, name: "locked")
                lockedRegistration = registration
                try record(plan, state: "worktree-move-intent", recovery: recovery)
                try checkpoint(.beforeWorktreeMove)
                try InstallerFileAccess.exclusiveMove(from: fresh.targetParent, name: plan.request.project.url.lastPathComponent, to: recovery, destinationName: "worktree")
                payloadMoved = true
                try checkpoint(.afterWorktreeMove)
                try record(plan, state: "registration-move-intent", recovery: recovery)
                try InstallerFileAccess.exclusiveMove(from: registrationParent, name: registrationName, to: recovery, destinationName: "registration")
            } else {
                // Cooperating Git writers must acquire this same loose-ref lock.
                let lockName = fresh.branchName + ".lock"
                try writeNew(Data(), parent: fresh.branchParent, name: lockName)
                defer { _ = unlinkat(fresh.branchParent.fd, lockName, 0) } // our exclusive, empty lock only
                guard try GitCleanupInspection.oid(GitCleanupInspection.read(fresh.branchParent, fresh.branchName, maximum: 128)) == plan.targetOID else { throw GitCleanupFailure.changed }
                try record(plan, state: "branch-move-intent", recovery: recovery)
                try checkpoint(.beforeBranchMove)
                try InstallerFileAccess.exclusiveMove(from: fresh.branchParent, name: fresh.branchName, to: recovery, destinationName: "branch")
                payloadMoved = true
            }
            guard fsync(recovery.fd) == 0, fsync(fresh.common.fd) == 0 else { throw GitCleanupFailure.changed }
            let payload = plan.request.action == .retireWorktree ? "worktree" : "branch"
            let receipt = GitCleanupReceipt(id: id, plan: plan, recoveryIdentity: try InstallerFileAccess.snapshot(recovery.fd),
                payloadIdentity: try InstallerFileAccess.snapshotAt(recovery.fd, payload),
                registrationIdentity: plan.request.action == .retireWorktree ? try InstallerFileAccess.snapshotAt(recovery.fd, "registration") : nil)
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
        let payload = plan.request.action == .retireWorktree ? "worktree" : "branch"
        let actual = try InstallerFileAccess.snapshotAt(recovery.fd, payload)
        guard plan.request.action == .retireWorktree ? receipt.payloadIdentity.matchesDirectory(actual) : receipt.payloadIdentity.matchesCaptured(actual) else { throw GitCleanupFailure.changed }
        let destination: InstallerDirectoryAnchor
        let name: String
        if plan.request.action == .retireWorktree {
            destination = try InstallerDirectoryAnchor.open(plan.request.project.url.deletingLastPathComponent()); name = plan.request.project.url.lastPathComponent
            guard let registrationURL = plan.registration, let identity = receipt.registrationIdentity,
                  identity.matchesDirectory(try InstallerFileAccess.snapshotAt(recovery.fd, "registration")) else { throw GitCleanupFailure.changed }
            let registrations = try InstallerDirectoryAnchor.open(registrationURL.deletingLastPathComponent())
            try InstallerFileAccess.assertAbsent(registrations, registrationURL.lastPathComponent)
            try InstallerFileAccess.assertAbsent(destination, name)
            try Task.checkCancellation(); try permit.consume()
            try record(plan, state: "restore-intent", recovery: recovery)
            try checkpoint(.beforeRestoreMove)
            try InstallerFileAccess.exclusiveMove(from: recovery, name: "registration", to: registrations, destinationName: registrationURL.lastPathComponent)
            do {
                try InstallerFileAccess.exclusiveMove(from: recovery, name: payload, to: destination, destinationName: name)
                let restoredRegistration = try registrations.child(registrationURL.lastPathComponent)
                let marker = Data(("MoeKit retirement " + id.uuidString + "\n").utf8)
                guard try GitCleanupInspection.read(restoredRegistration, "locked", maximum: 256) == marker,
                      unlinkat(restoredRegistration.fd, "locked", 0) == 0 else { throw GitCleanupFailure.changed }
            } catch { throw GitCleanupFailure.partial(recovery.url.path) }
        } else {
            let parts = try GitCleanupInspection.branchComponents(plan.request.branch)
            var parent = try common.child("refs").child("heads")
            for component in parts.dropLast() { parent = try parent.child(component) }
            destination = parent; name = parts.last!
            try InstallerFileAccess.assertAbsent(destination, name)
            // A newly packed branch also counts as occupied.
            if let packed = try? GitCleanupInspection.read(common, "packed-refs", maximum: 8 * 1_024 * 1_024),
               String(decoding: packed, as: UTF8.self).split(separator: "\n").contains(where: { $0.hasSuffix(" refs/heads/" + plan.request.branch) }) { throw GitCleanupFailure.occupied }
            try Task.checkCancellation(); try permit.consume()
            try writeNew(Data(), parent: destination, name: name + ".lock")
            defer { _ = unlinkat(destination.fd, name + ".lock", 0) }
            try record(plan, state: "restore-intent", recovery: recovery)
            try checkpoint(.beforeRestoreMove)
            try InstallerFileAccess.exclusiveMove(from: recovery, name: payload, to: destination, destinationName: name)
        }
        try record(plan, state: "restored", recovery: recovery)
        receipts[id] = nil
    }
    private func ensurePrivateChild(_ parent: InstallerDirectoryAnchor, _ name: String) throws -> InstallerDirectoryAnchor {
        if mkdirat(parent.fd, name, 0o700) != 0, errno != EEXIST { throw GitCleanupFailure.changed }
        let child = try parent.child(name)
        try InstallerFileAccess.validatePrivate(child.fd, directory: true)
        return child
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
