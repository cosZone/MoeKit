import Darwin
import Foundation

/// Current user's home Trash only. No external .Trashes, volume-wide cleanup,
/// Finder scripting, shell command, permission repair, or privileged helper.
actor NativeTrashExecutor: TrashExecuting {
    private struct Inspection {
        let display: TrashInspection
        let root: InstallerDirectoryAnchor?
    }
    private struct Prepared {
        let display: TrashRemovalPlan
        let root: InstallerDirectoryAnchor
    }
    private let environment: TrashEnvironment
    private let checkpoint: @Sendable (CleanupCheckpoint) throws -> Void
    private var inspection: Inspection?
    private var prepared: Prepared?
    private var busy = false
    static let maximumItems = 256

    init(environment: TrashEnvironment = .user,
         checkpoint: @escaping @Sendable (CleanupCheckpoint) throws -> Void = { _ in }) {
        self.environment = environment; self.checkpoint = checkpoint
    }
    func discardPlan() { prepared = nil }

    func inspect(context: TrashContext) throws -> TrashInspection {
        guard !busy else { throw TrashFailure.busy }
        prepared = nil; inspection = nil
        let home: InstallerDirectoryAnchor
        do { home = try verifiedHome() } catch { throw TrashFailure.unavailable }
        var status = stat()
        if fstatat(home.fd, environment.trash.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw TrashFailure.unavailable }
            let display = TrashInspection(id: UUID(), rootURL: environment.trash, items: [], context: context, observedAt: Date(), rootExists: false)
            inspection = .init(display: display, root: nil)
            return display
        }
        let root: InstallerDirectoryAnchor
        do { root = try home.child(environment.trash.lastPathComponent); try validate(root) }
        catch { throw TrashFailure.unavailable }
        let names = try CleanupFiles.names(root, limit: Self.maximumItems)
        let deadline = Date().addingTimeInterval(45)
        var items: [TrashItem] = [], remaining = CleanupFiles.maximumEntries
        for name in names {
            try Task.checkCancellation()
            let url = root.url.appendingPathComponent(name)
            var modified: Date?
            do {
                let metadata = try InstallerFileAccess.snapshotAt(root.fd, name)
                modified = Date(timeIntervalSince1970: Double(metadata.modifiedSeconds))
                try protect(name)
                let manifest = try CleanupFiles.manifest(parent: root, name: name, environment: environment.files,
                                                         maximumEntries: remaining, deadline: deadline)
                try CleanupPermanentRemoval.preflight(manifest)
                remaining -= manifest.itemCount
                items.append(.init(url: url, manifest: manifest, modifiedAt: modified, blocker: nil))
            } catch is CancellationError { throw CancellationError() }
            catch {
                items.append(.init(url: url, manifest: nil, modifiedAt: modified, blocker: TrashFailure.message(error)))
            }
        }
        try validate(root)
        guard names == (try CleanupFiles.names(root, limit: Self.maximumItems)) else { throw TrashFailure.changed }
        let display = TrashInspection(id: UUID(), rootURL: root.url, items: items, context: context, observedAt: Date(), rootExists: true)
        inspection = .init(display: display, root: root)
        return display
    }

    func prepare(inspectionID: UUID, selectedPaths: Set<String>, action: TrashRemovalPlan.Action, context: TrashContext) throws -> TrashRemovalPlan {
        guard !busy else { throw TrashFailure.busy }
        prepared = nil
        guard let inspection, inspection.display.id == inspectionID, inspection.display.context == context,
              let root = inspection.root, !selectedPaths.isEmpty else { throw TrashFailure.expired }
        try validate(root)
        if action == .clearSnapshot {
            guard inspection.display.canClearSnapshot,
                  selectedPaths == Set(inspection.display.items.map(\.id)),
                  Set(try CleanupFiles.names(root, limit: Self.maximumItems)) == Set(inspection.display.items.map { $0.url.lastPathComponent }) else { throw TrashFailure.changed }
        }
        var items: [TrashItem] = []
        for path in selectedPaths.sorted() {
            guard let item = inspection.display.items.first(where: { $0.id == path }), item.isEligible else { throw TrashFailure.changed }
            try revalidate(item, root: root)
            items.append(item)
        }
        guard items.count <= Self.maximumItems, items.reduce(0, { $0 + ($1.manifest?.itemCount ?? 0) }) <= CleanupFiles.maximumEntries else { throw TrashFailure.limit }
        _ = try items.reduce(Int64(0)) { sum, item in
            let next = sum.addingReportingOverflow(item.logicalBytes ?? 0)
            guard !next.overflow else { throw TrashFailure.limit }; return next.partialValue
        }
        let display = TrashRemovalPlan(id: UUID(), inspectionID: inspectionID, action: action, rootURL: root.url,
            items: items, context: context, recoveryURL: environment.recovery, expiresAt: Date().addingTimeInterval(120))
        prepared = .init(display: display, root: root)
        return display
    }

    func remove(planID: UUID, context: TrashContext, progress: @escaping @Sendable (TrashProgress) -> Void) throws -> TrashOutcome {
        guard !busy else { throw TrashFailure.busy }
        guard let plan = prepared, plan.display.id == planID, plan.display.context == context,
              plan.display.expiresAt > Date() else { throw TrashFailure.expired }
        prepared = nil; inspection = nil; busy = true
        defer { busy = false }
        try validate(plan.root)
        if plan.display.action == .clearSnapshot {
            guard Set(try CleanupFiles.names(plan.root, limit: Self.maximumItems)) == Set(plan.display.items.map { $0.url.lastPathComponent }) else { throw TrashFailure.changed }
        }
        // Entire batch is rechecked before the first journal/directory write.
        for item in plan.display.items { try revalidate(item, root: plan.root) }
        try Task.checkCancellation()
        let journal = try TrashJournal(environment: environment, create: true, exclusive: true)
        guard journal.storage.root.identity.device == plan.root.identity.device else { throw TrashFailure.unsupported }
        var outcomes: [TrashItemOutcome] = [], stopped = false
        for item in plan.display.items {
            progress(.init(finished: outcomes.count, total: plan.display.items.count, currentPath: item.url.path))
            if stopped || Task.isCancelled {
                outcomes.append(.init(originalURL: item.url, status: .notAttempted,
                    message: String(localized: "Not attempted. The batch stopped or was cancelled; this item was not automatically retried."), operationURL: nil))
                continue
            }
            do {
                try revalidate(item, root: plan.root)
                let outcome = try removeItem(item, root: plan.root, journal: journal)
                outcomes.append(outcome)
                stopped = outcome.status != .deleted
            } catch {
                outcomes.append(.init(originalURL: item.url, status: .notAttempted, message: TrashFailure.message(error), operationURL: nil))
                stopped = true
            }
        }
        progress(.init(finished: outcomes.count, total: outcomes.count, currentPath: nil))
        return .init(items: outcomes)
    }

    private func removeItem(_ item: TrashItem, root: InstallerDirectoryAnchor, journal: TrashJournal) throws -> TrashItemOutcome {
        guard let approved = item.manifest else { throw TrashFailure.changed }
        let operationID = UUID()
        let operation = try journal.createOperation(operationID)
        var record = TrashRecord(id: operationID, sequence: 0, originalURL: item.url, originalParent: root.identity,
            operationURL: operation.url, operationIdentity: operation.identity, approvedManifest: approved,
            capturedManifest: nil, state: .captureIntent, recordedAt: Date())
        try journal.append(record, operation: operation)
        var captured = false, started = false
        do {
            try checkpoint(.beforeCapture); try Task.checkCancellation()
            try revalidate(item, root: root)
            try journal.storage.validate()
            try InstallerFileAccess.exclusiveMove(from: root, name: item.url.lastPathComponent, to: operation, destinationName: "payload")
            captured = true
            guard fsync(root.fd) == 0, fsync(operation.fd) == 0 else { throw TrashFailure.records }
            try checkpoint(.afterCapture)
            let actual = try CleanupFiles.manifest(parent: operation, name: "payload", environment: environment.files)
            guard CleanupFiles.matchesAfterMove(approved, actual) else { throw TrashFailure.changed }
            record = record.advancing(.captured, captured: actual); try journal.append(record, operation: operation)
            try Task.checkCancellation()
            record = record.advancing(.deleting); try journal.append(record, operation: operation)
            try checkpoint(.beforePermanentDelete); try Task.checkCancellation()
            // A retained descriptor must still be in its reviewed namespace.
            try validate(root); try journal.storage.validate()
            guard actual == (try CleanupFiles.manifest(parent: operation, name: "payload", environment: environment.files)) else { throw TrashFailure.changed }
            started = true
            try CleanupPermanentRemoval.remove(manifest: actual, parent: operation, name: "payload", environment: environment.files, isolation: self) { point in
                try self.checkpoint(point)
                try self.validate(root)
                try journal.storage.validate()
            }
            try checkpoint(.afterPermanentDelete)
            record = record.advancing(.deleted); try journal.append(record, operation: operation)
            return .init(originalURL: item.url, status: .deleted,
                message: String(localized: "Permanently deleted the confirmed item. Physical disk space reclaimed may be smaller or delayed."), operationURL: operation.url)
        } catch {
            // No rollback, retry, or cleanup on error. This includes substituted
            // roots/leaves and partial deletion. Evidence is useful even if the
            // final record failed; the in-memory result must still expose the slot.
            let retained = record.advancing(.retained)
            try? journal.append(retained, operation: operation)
            return .init(originalURL: item.url, status: .retained,
                message: started
                    ? String(localized: "Deletion stopped after it began. Some confirmed entries may be gone; remaining or uncertain data is retained in the operation folder. No automatic retry occurs.")
                    : (captured
                        ? String(localized: "Deletion did not begin. Captured or changed data is retained in the operation folder. Inspect it in Finder before taking another action.")
                        : String(localized: "Deletion did not begin. The item remains unverified at its Trash location; inspect it and scan again.")),
                operationURL: operation.url)
        }
    }

    func readRecords() throws -> [TrashRecoveryItem] {
        guard !busy else { throw TrashFailure.busy }
        var status = stat()
        if lstat(environment.recovery.path, &status) != 0 {
            guard errno == ENOENT else { throw TrashFailure.records }
            return []
        }
        return try TrashJournal(environment: environment, create: false, exclusive: false).records()
    }
    private func verifiedHome() throws -> InstallerDirectoryAnchor {
        guard geteuid() != 0, environment.trash.deletingLastPathComponent().path == environment.home.path,
              !environment.trash.lastPathComponent.isEmpty else { throw TrashFailure.unsupported }
        if environment.enforceProductionPolicy {
            guard environment.home.path == FileManager.default.homeDirectoryForCurrentUser.path,
                  environment.trash.lastPathComponent == ".Trash",
                  environment.recovery.path == environment.home.appendingPathComponent("Library/Application Support/MoeKit/TrashRemovalRecords").path else { throw TrashFailure.unsupported }
        }
        let home = try InstallerDirectoryAnchor.open(environment.home)
        guard home.identity.uid == geteuid() else { throw TrashFailure.unsupported }
        if environment.enforceProductionPolicy { try home.validateTrustedMutationAncestry() }
        return home
    }
    private func validate(_ root: InstallerDirectoryAnchor) throws {
        guard root.url.path == environment.trash.path else { throw TrashFailure.unsupported }
        _ = try verifiedHome()
        try CleanupFiles.validateNamespace(root, environment: environment.files)
        try InstallerFileAccess.validatePrivate(root.fd, directory: true)
        try InstallerFileAccess.rejectCloudAttributes(root.fd)
        if environment.enforceProductionPolicy { try InstallerFileAccess.validateVolume(root.fd, url: root.url) }
    }
    private func revalidate(_ item: TrashItem, root: InstallerDirectoryAnchor) throws {
        try Task.checkCancellation(); try validate(root); try protect(item.url.lastPathComponent)
        guard item.url.deletingLastPathComponent().path == root.url.path, let manifest = item.manifest,
              manifest == (try CleanupFiles.manifest(parent: root, name: item.url.lastPathComponent, environment: environment.files)) else { throw TrashFailure.changed }
        try CleanupPermanentRemoval.preflight(manifest)
    }
    private func protect(_ name: String) throws {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let sensitive = [".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".kube", ".env", "id_rsa", "id_ed25519", "moekit", "trashremovalrecords", "cacherecovery", "installerrecovery"]
        guard !sensitive.contains(folded), !CleanupFiles.isProtectedSecretName(folded) else {
            throw CleanupFailure.refused(String(localized: "Credential, vault, and MoeKit recovery locations are protected. Manage this item yourself in Finder."))
        }
    }
}
