import Darwin
import Foundation

enum CleanupCheckpoint: Sendable { case beforeCapture, afterCapture, beforeTrash, afterTrash, beforeRecoveryCapture, afterRecoveryCapture, beforePermanentDelete, beforeLeafCapture, afterLeafCapture, afterPermanentDelete, beforeRestore }

/// Only native, explicit-plan operations. No Mole cleanup command, shell,
/// process termination, recursive pathname deletion, or whole-Trash operation.
actor NativeCleanupExecutor: CleanupExecuting {
    private struct Inspection {
        let display: CleanupInspection
        let root: InstallerDirectoryAnchor
        let catalog: InstallerCatalogSnapshot
    }
    private struct Prepared {
        let display: CleanupPlan
        let root: InstallerDirectoryAnchor
        let catalog: InstallerCatalogSnapshot
    }
    private struct Recovery {
        let display: CleanupRecoveryPlan
        let sourceParent: InstallerDirectoryAnchor
        let originalParent: InstallerDirectoryAnchor
        let catalog: InstallerCatalogSnapshot
    }
    private let environment: CleanupEnvironment
    private let sink: any InstallerTrashSink
    private let checkpoint: @Sendable (CleanupCheckpoint) throws -> Void
    private var inspection: Inspection?
    private var prepared: Prepared?
    private var recovery: Recovery?
    private var busy = false

    init(environment: CleanupEnvironment = .user, sink: any InstallerTrashSink = NativeInstallerTrashSink(),
         checkpoint: @escaping @Sendable (CleanupCheckpoint) throws -> Void = { _ in }) {
        self.environment = environment; self.sink = sink; self.checkpoint = checkpoint
    }
    func discardPlans() { prepared = nil; recovery = nil }

    func inspect(root: URL, context: CleanupContext) throws -> CleanupInspection {
        guard !busy else { throw CleanupFailure.busy }
        discardPlans(); inspection = nil
        try requireContext(context)
        let anchor = try InstallerDirectoryAnchor.open(root)
        try CleanupFiles.validateRoot(anchor, environment: environment)
        let catalog = try catalogSnapshot()
        let protection = try protectedPaths(context, catalog: catalog)
        let names = try CleanupFiles.names(anchor, limit: 512)
        var candidates: [CleanupCandidate] = []
        let deadline = Date().addingTimeInterval(45)
        var remainingEntries = CleanupFiles.maximumEntries
        for name in names {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(name)
            do {
                guard remainingEntries > 0, Date() < deadline else { throw CleanupFailure.limit }
                let identity = try InstallerFileAccess.snapshotAt(anchor.fd, name)
                // No file or symlink-root candidate can authorize a tree move.
                guard identity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { continue }
                try CleanupFiles.protect(url, paths: protection)
                let directory = try anchor.child(name)
                let evidence = try CleanupFiles.evidence(parent: anchor, candidate: directory, environment: environment)
                let manifest = try CleanupFiles.manifest(directory, environment: environment, maximumEntries: remainingEntries, deadline: deadline)
                remainingEntries -= manifest.itemCount
                candidates.append(.init(url: url, evidence: evidence, manifest: manifest, blocker: nil))
            } catch is CancellationError { throw CancellationError() }
            catch {
                candidates.append(.init(url: url, evidence: "", manifest: nil, blocker: Self.explanation(error)))
            }
        }
        try anchor.validate()
        guard try catalogSnapshot() == catalog else { throw CleanupFailure.changed }
        let display = CleanupInspection(id: UUID(), rootURL: root, candidates: candidates, context: context, observedAt: Date())
        inspection = .init(display: display, root: anchor, catalog: catalog)
        return display
    }
    func prepare(inspectionID: UUID, selectedPaths: Set<String>, context: CleanupContext) throws -> CleanupPlan {
        guard !busy else { throw CleanupFailure.busy }
        discardPlans()
        guard let inspection, inspection.display.id == inspectionID, inspection.display.context == context,
              !selectedPaths.isEmpty, selectedPaths.count <= CleanupFiles.maximumTargets else { throw CleanupFailure.expired }
        try requireContext(context)
        try CleanupFiles.validateRoot(inspection.root, environment: environment)
        guard try catalogSnapshot() == inspection.catalog else { throw CleanupFailure.changed }
        var targets: [CleanupTarget] = []
        for path in selectedPaths.sorted() {
            guard let candidate = inspection.display.candidates.first(where: { $0.url.path == path }),
                  candidate.isEligible, let expected = candidate.manifest else { throw CleanupFailure.changed }
            try CleanupFiles.protect(candidate.url, paths: try protectedPaths(context, catalog: inspection.catalog))
            let directory = try inspection.root.child(candidate.url.lastPathComponent)
            let evidence = try CleanupFiles.evidence(parent: inspection.root, candidate: directory, environment: environment)
            let actual = try CleanupFiles.manifest(directory, environment: environment)
            guard expected == actual, evidence == candidate.evidence else { throw CleanupFailure.changed }
            targets.append(.init(originalURL: candidate.url, evidence: evidence, manifest: actual))
        }
        guard targets.reduce(0, { $0 + $1.manifest.itemCount }) <= CleanupFiles.maximumEntries else { throw CleanupFailure.limit }
        _ = try targets.reduce(Int64(0)) { total, target in
            let result = total.addingReportingOverflow(target.manifest.logicalBytes)
            guard !result.overflow else { throw CleanupFailure.limit }
            return result.partialValue
        }
        let now = Date()
        let display = CleanupPlan(id: UUID(), inspectionID: inspectionID, rootURL: inspection.display.rootURL,
            targets: targets, context: context, recoveryRoot: environment.recovery, preparedAt: now, expiresAt: now.addingTimeInterval(120))
        prepared = .init(display: display, root: inspection.root, catalog: inspection.catalog)
        return display
    }
    func moveToTrash(planID: UUID, context: CleanupContext) throws -> CleanupOutcome {
        guard !busy else { throw CleanupFailure.busy }
        guard let plan = prepared, plan.display.id == planID, plan.display.context == context,
              plan.display.expiresAt > Date() else { throw CleanupFailure.expired }
        discardPlans(); inspection = nil; busy = true
        defer { busy = false }
        try requireContext(context)
        try CleanupFiles.validateRoot(plan.root, environment: environment)
        guard try catalogSnapshot() == plan.catalog else { throw CleanupFailure.changed }
        // Validate the complete selected batch before any journal or file write.
        for target in plan.display.targets { try revalidate(target, root: plan.root, context: context, catalog: plan.catalog) }
        try Task.checkCancellation()
        let journal = try CleanupJournal(environment: environment, create: true, exclusive: true)
        guard journal.storage.root.identity.device == plan.root.identity.device else { throw CleanupFailure.changed }
        let lease = try InstallerCatalogLease(app: journal.app)
        defer { withExtendedLifetime(lease) {} }
        try lease.requireSnapshot(plan.catalog)
        var outcomes: [CleanupItemOutcome] = []
        var stopped = false
        for target in plan.display.targets {
            if stopped || Task.isCancelled {
                outcomes.append(.init(id: UUID(), originalURL: target.originalURL, receipt: nil,
                    message: String(localized: "Not attempted. An earlier item stopped or the batch was cancelled."), succeeded: false, requiresRecovery: false))
                continue
            }
            do {
                try revalidate(target, root: plan.root, context: context, catalog: plan.catalog)
                try lease.requireSnapshot(plan.catalog)
                let result = try trash(target, root: plan.root, journal: journal, lease: lease, catalog: plan.catalog)
                outcomes.append(result)
                if !result.succeeded { stopped = true }
            } catch {
                outcomes.append(.init(id: UUID(), originalURL: target.originalURL, receipt: nil,
                    message: Self.explanation(error), succeeded: false, requiresRecovery: false))
                stopped = true
            }
        }
        return .init(items: outcomes)
    }
    private func trash(_ target: CleanupTarget, root: InstallerDirectoryAnchor, journal: CleanupJournal,
                       lease: InstallerCatalogLease, catalog: InstallerCatalogSnapshot) throws -> CleanupItemOutcome {
        let id = UUID(), operation = try journal.storage.createOperation(UUID())
        let operationID = UUID(uuidString: operation.url.lastPathComponent)!
        let payload = operation.url.appendingPathComponent(target.originalURL.lastPathComponent)
        var receipt = CleanupReceipt(id: operationID, sequence: 0, target: target, originalParent: root.identity,
            operationURL: operation.url, operationIdentity: operation.identity, state: .captureIntent,
            payloadURL: payload, manifest: target.manifest, recordedAt: Date())
        try journal.append(receipt, operation: operation)
        var captured = false, trashStarted = false
        do {
            try Task.checkCancellation(); try lease.requireSnapshot(catalog)
            try checkpoint(.beforeCapture)
            try exclusiveMove(from: root, name: target.originalURL.lastPathComponent,
                to: operation, destinationName: target.originalURL.lastPathComponent)
            captured = true
            guard fsync(root.fd) == 0, fsync(operation.fd) == 0 else { throw CleanupFailure.journal }
            try checkpoint(.afterCapture)
            let staged = try operation.child(target.originalURL.lastPathComponent)
            let actual = try CleanupFiles.manifest(staged, environment: environment, honorCancellation: false)
            guard CleanupFiles.matchesAfterMove(target.manifest, actual) else { throw CleanupFailure.changed }
            receipt = receipt.advancing(.staged, payloadURL: payload, manifest: actual)
            try journal.append(receipt, operation: operation)
            try Task.checkCancellation(); try lease.requireSnapshot(catalog)
            receipt = receipt.advancing(.trashIntent, payloadURL: payload)
            try journal.append(receipt, operation: operation)
            try checkpoint(.beforeTrash); try Task.checkCancellation()
            try CleanupFiles.validateNamespace(operation, environment: environment)
            guard actual == (try CleanupFiles.manifest(staged, environment: environment)) else { throw CleanupFailure.changed }
            trashStarted = true
            let destination = try sink.trash(payload)
            guard destination.deletingLastPathComponent().path == environment.trash.path else { throw CleanupFailure.changed }
            try checkpoint(.afterTrash)
            let moved = try verifiedPayload(destination, expected: actual, allowRootRename: true)
            receipt = receipt.advancing(.trashed, payloadURL: destination, manifest: moved)
            try journal.append(receipt, operation: operation)
            return .init(id: id, originalURL: target.originalURL, receipt: receipt,
                message: String(localized: "Moved to Trash. No disk-space release is claimed; restore or permanent deletion requires another review."), succeeded: true, requiresRecovery: false)
        } catch {
            // Once the URL-based OS sink starts, a missing source is not success.
            // Before it starts, keep a captured tree intact and expose recovery.
            let verifiedCapture = receipt.state == .staged || receipt.state == .trashIntent
            var intact = false
            if !trashStarted, captured, verifiedCapture {
                intact = retainedTreeIsIntact(receipt, payload: payload, operation: operation, journal: journal)
            }
            let state: CleanupReceiptState = intact ? .retained : .uncertain
            let retained = recordFailure(receipt.advancing(state, payloadURL: payload), journal: journal, operation: operation)
            return .init(id: id, originalURL: target.originalURL, receipt: retained,
                message: String(localized: "Cleanup stopped. The receipt shows retained or uncertain data; nothing is retried automatically."), succeeded: false, requiresRecovery: true)
        }
    }
    func recoveryRecords() throws -> [CleanupRecoveryItem] {
        guard !busy else { throw CleanupFailure.busy }
        var info = stat()
        if lstat(environment.recovery.path, &info) != 0, errno == ENOENT { return [] }
        return try CleanupJournal(environment: environment, create: false, exclusive: false).records()
    }
    func prepareRecovery(receiptID: UUID, action: CleanupRecoveryPlan.Action, context: CleanupContext) throws -> CleanupRecoveryPlan {
        guard !busy else { throw CleanupFailure.busy }
        discardPlans(); try requireContext(context)
        let journal = try CleanupJournal(environment: environment, create: false, exclusive: false)
        let receipt = try journal.latest(receiptID)
        guard action == .restore ? receipt.canRestore : receipt.canDeletePermanently,
              let source = receipt.payloadURL else { throw CleanupFailure.expired }
        let catalog = try catalogSnapshot()
        try CleanupFiles.protect(receipt.target.originalURL, paths: try protectedPaths(context, catalog: catalog), originalIdentity: receipt.target.manifest.entries[0].identity)
        let parent = try InstallerDirectoryAnchor.open(receipt.target.originalURL.deletingLastPathComponent())
        try CleanupFiles.validateRoot(parent, environment: environment)
        guard receipt.originalParent.matchesDirectory(parent.identity) else { throw CleanupFailure.changed }
        if action == .restore { try InstallerFileAccess.assertAbsent(parent, receipt.target.originalURL.lastPathComponent) }
        try validateReceiptSource(receipt)
        let sourceParent = try InstallerDirectoryAnchor.open(source.deletingLastPathComponent())
        if action == .deletePermanently { try CleanupPermanentRemoval.preflight(receipt.manifest) }
        let current = try verifiedPayload(source, expected: receipt.manifest, allowRootRename: false)
        guard current == receipt.manifest else { throw CleanupFailure.changed }
        let now = Date()
        let display = CleanupRecoveryPlan(id: UUID(), action: action, receipt: receipt, sourceURL: source,
            context: context, preparedAt: now, expiresAt: now.addingTimeInterval(120))
        recovery = .init(display: display, sourceParent: sourceParent, originalParent: parent, catalog: catalog)
        return display
    }
    func applyRecovery(planID: UUID, context: CleanupContext) throws -> CleanupOutcome {
        guard !busy else { throw CleanupFailure.busy }
        guard let plan = recovery, plan.display.id == planID, plan.display.context == context,
              plan.display.expiresAt > Date() else { throw CleanupFailure.expired }
        discardPlans(); inspection = nil; busy = true
        defer { busy = false }
        try requireContext(context); try validateReceiptSource(plan.display.receipt)
        let journal = try CleanupJournal(environment: environment, create: false, exclusive: true)
        let lease = try InstallerCatalogLease(app: journal.app)
        defer { withExtendedLifetime(lease) {} }
        try lease.requireSnapshot(plan.catalog)
        guard try journal.latest(plan.display.receipt.id) == plan.display.receipt else { throw CleanupFailure.changed }
        try plan.originalParent.validate(); try plan.sourceParent.validate()
        _ = try verifiedPayload(plan.display.sourceURL, expected: plan.display.receipt.manifest, allowRootRename: false)
        try Task.checkCancellation()
        let result: CleanupItemOutcome
        switch plan.display.action {
        case .restore: result = try restore(plan, journal: journal, lease: lease)
        case .deletePermanently: result = try deletePermanently(plan, journal: journal, lease: lease)
        }
        return .init(items: [result])
    }
    private func restore(_ plan: Recovery, journal: CleanupJournal, lease: InstallerCatalogLease) throws -> CleanupItemOutcome {
        var receipt = plan.display.receipt
        let operation = try journal.storage.operation(receipt.id)
        let stageName = plan.display.sourceURL.lastPathComponent == "restore-payload" ? "restore-payload-again" : "restore-payload", stageURL = operation.url.appendingPathComponent(stageName)
        var captured = false, restored = false
        do {
            try InstallerFileAccess.assertAbsent(plan.originalParent, receipt.target.originalURL.lastPathComponent)
            receipt = receipt.advancing(.restoreCaptureIntent, payloadURL: plan.display.sourceURL)
            try journal.append(receipt, operation: operation)
            try checkpoint(.beforeRecoveryCapture); try Task.checkCancellation(); try lease.requireSnapshot(plan.catalog)
            try exclusiveMove(from: plan.sourceParent, name: plan.display.sourceURL.lastPathComponent,
                to: operation, destinationName: stageName)
            captured = true
            guard fsync(plan.sourceParent.fd) == 0, fsync(operation.fd) == 0 else { throw CleanupFailure.journal }
            try checkpoint(.afterRecoveryCapture)
            let actual = try CleanupFiles.manifest(operation.child(stageName), environment: environment, honorCancellation: false)
            guard CleanupFiles.matchesAfterMove(receipt.manifest, actual) else { throw CleanupFailure.changed }
            receipt = receipt.advancing(.restoreStaged, payloadURL: stageURL, manifest: actual)
            try journal.append(receipt, operation: operation)
            receipt = receipt.advancing(.restoreIntent, payloadURL: stageURL)
            try journal.append(receipt, operation: operation)
            try checkpoint(.beforeRestore); try Task.checkCancellation(); try lease.requireSnapshot(plan.catalog)
            try CleanupFiles.validateNamespace(plan.originalParent, environment: environment)
            guard actual == (try CleanupFiles.manifest(operation.child(stageName), environment: environment)) else { throw CleanupFailure.changed }
            try exclusiveMove(from: operation, name: stageName, to: plan.originalParent,
                                                  destinationName: receipt.target.originalURL.lastPathComponent)
            restored = true
            let final = try CleanupFiles.manifest(plan.originalParent.child(receipt.target.originalURL.lastPathComponent), environment: environment, honorCancellation: false)
            guard CleanupFiles.matchesAfterMove(actual, final), fsync(operation.fd) == 0, fsync(plan.originalParent.fd) == 0 else { throw CleanupFailure.changed }
            receipt = receipt.advancing(.restored, payloadURL: receipt.target.originalURL, manifest: final)
            try journal.append(receipt, operation: operation)
            return outcome(receipt, message: String(localized: "Restored to its original location without replacing any existing file."), success: true)
        } catch {
            let verifiedCapture = receipt.state == .restoreStaged || receipt.state == .restoreIntent
            var intact = false
            if !restored, captured, verifiedCapture {
                intact = retainedTreeIsIntact(receipt, payload: stageURL, operation: operation, journal: journal)
            }
            receipt = receipt.advancing(intact ? .retained : .uncertain,
                payloadURL: restored ? receipt.target.originalURL : (captured ? stageURL : plan.display.sourceURL))
            receipt = recordFailure(receipt, journal: journal, operation: operation)
            return outcome(receipt, message: String(localized: "Restore stopped. The exact recovery location is retained in the receipt; no destination was overwritten."), success: false)
        }
    }
    private func deletePermanently(_ plan: Recovery, journal: CleanupJournal, lease: InstallerCatalogLease) throws -> CleanupItemOutcome {
        var receipt = plan.display.receipt
        let operation = try journal.storage.operation(receipt.id)
        let stageName = "delete-payload", stageURL = operation.url.appendingPathComponent(stageName)
        var captured = false, deletionStarted = false
        do {
            receipt = receipt.advancing(.deleteCaptureIntent, payloadURL: plan.display.sourceURL)
            try journal.append(receipt, operation: operation)
            try checkpoint(.beforeRecoveryCapture); try Task.checkCancellation(); try lease.requireSnapshot(plan.catalog)
            try exclusiveMove(from: plan.sourceParent, name: plan.display.sourceURL.lastPathComponent,
                to: operation, destinationName: stageName)
            captured = true
            guard fsync(plan.sourceParent.fd) == 0, fsync(operation.fd) == 0 else { throw CleanupFailure.journal }
            try checkpoint(.afterRecoveryCapture)
            let staged = try operation.child(stageName)
            let actual = try CleanupFiles.manifest(staged, environment: environment, honorCancellation: false)
            guard CleanupFiles.matchesAfterMove(receipt.manifest, actual) else { throw CleanupFailure.changed }
            receipt = receipt.advancing(.deleteStaged, payloadURL: stageURL, manifest: actual)
            try journal.append(receipt, operation: operation)
            try Task.checkCancellation(); try lease.requireSnapshot(plan.catalog)
            receipt = receipt.advancing(.deleteIntent, payloadURL: stageURL)
            try journal.append(receipt, operation: operation)
            try checkpoint(.beforePermanentDelete); try Task.checkCancellation()
            guard actual == (try CleanupFiles.manifest(staged, environment: environment)) else { throw CleanupFailure.changed }
            deletionStarted = true
            try CleanupPermanentRemoval.remove(manifest: actual, directory: staged, parent: operation, name: stageName,
                                               environment: environment, checkpoint: checkpoint)
            try checkpoint(.afterPermanentDelete)
            guard fsync(operation.fd) == 0 else { throw CleanupFailure.journal }
            receipt = receipt.advancing(.deleted, payloadURL: nil)
            try journal.append(receipt, operation: operation)
            return outcome(receipt, message: String(localized: "Permanently removed the confirmed cache entries. Restore is no longer available. Open files, hard links and APFS snapshots may delay or reduce physical space reclaimed."), success: true)
        } catch {
            let verifiedCapture = receipt.state == .deleteStaged || receipt.state == .deleteIntent
            var intact = false
            if !deletionStarted, captured, verifiedCapture {
                intact = retainedTreeIsIntact(receipt, payload: stageURL, operation: operation, journal: journal)
            }
            receipt = receipt.advancing(intact ? .retained : .uncertain, payloadURL: captured ? stageURL : plan.display.sourceURL)
            receipt = recordFailure(receipt, journal: journal, operation: operation)
            return outcome(receipt, message: deletionStarted
                ? String(localized: "Permanent deletion stopped after it began. Some confirmed entries may already be removed; remaining data is retained. No automatic retry is allowed.")
                : String(localized: "Permanent deletion did not begin. The file tree is retained at its recorded recovery location; inspect it before any new action."), success: false)
        }
    }
    private func outcome(_ receipt: CleanupReceipt, message: String, success: Bool) -> CleanupItemOutcome {
        .init(id: receipt.id, originalURL: receipt.target.originalURL, receipt: receipt, message: message,
              succeeded: success, requiresRecovery: !success)
    }
    private func validateReceiptSource(_ receipt: CleanupReceipt) throws {
        guard let source = receipt.payloadURL else { throw CleanupFailure.changed }
        _ = try InstallerFileAccess.components(source)
        if receipt.state == .trashed {
            guard source.deletingLastPathComponent().path == environment.trash.path else { throw CleanupFailure.changed }
        } else {
            guard source.deletingLastPathComponent().path == receipt.operationURL.path,
                  receipt.operationURL.deletingLastPathComponent().path == environment.recovery.path,
                  source.lastPathComponent == receipt.target.originalURL.lastPathComponent || source.lastPathComponent == "delete-payload" || source.lastPathComponent == "restore-payload" || source.lastPathComponent == "restore-payload-again" else { throw CleanupFailure.changed }
        }
    }
    private func verifiedPayload(_ url: URL, expected: CleanupManifest, allowRootRename: Bool) throws -> CleanupManifest {
        let parent = try InstallerDirectoryAnchor.open(url.deletingLastPathComponent())
        try CleanupFiles.validateNamespace(parent, environment: environment)
        let directory = try parent.child(url.lastPathComponent)
        let actual = try CleanupFiles.manifest(directory, environment: environment, honorCancellation: false)
        guard allowRootRename ? CleanupFiles.matchesAfterMove(expected, actual) : expected == actual else { throw CleanupFailure.changed }
        return actual
    }
    private func revalidate(_ target: CleanupTarget, root: InstallerDirectoryAnchor, context: CleanupContext, catalog: InstallerCatalogSnapshot) throws {
        try CleanupFiles.validateRoot(root, environment: environment)
        try CleanupFiles.protect(target.originalURL, paths: try protectedPaths(context, catalog: catalog))
        guard target.originalURL.deletingLastPathComponent().path == root.url.path else { throw CleanupFailure.changed }
        let directory = try root.child(target.originalURL.lastPathComponent)
        guard target.evidence == (try CleanupFiles.evidence(parent: root, candidate: directory, environment: environment)),
              target.manifest == (try CleanupFiles.manifest(directory, environment: environment)) else { throw CleanupFailure.changed }
    }
    private func protectedPaths(_ context: CleanupContext, catalog: InstallerCatalogSnapshot) throws -> [String] {
        context.protectedPaths + (try catalog.protectedPaths) + [environment.recovery.deletingLastPathComponent().path, environment.trash.path]
    }
    private func exclusiveMove(from: InstallerDirectoryAnchor, name: String, to: InstallerDirectoryAnchor, destinationName: String) throws {
        try CleanupFiles.validateNamespace(from, environment: environment)
        try CleanupFiles.validateNamespace(to, environment: environment)
        try InstallerFileAccess.exclusiveMove(from: from, name: name, to: to, destinationName: destinationName)
    }
    private func retainedTreeIsIntact(_ receipt: CleanupReceipt, payload: URL, operation: InstallerDirectoryAnchor, journal: CleanupJournal) -> Bool {
        do {
            guard journal.isHealthy, payload.deletingLastPathComponent().path == operation.url.path,
                  try journal.latest(receipt.id) == receipt else { return false }
            try CleanupFiles.validateNamespace(operation, environment: environment)
            try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
            let tree = try operation.child(payload.lastPathComponent)
            return try CleanupFiles.manifest(tree, environment: environment, honorCancellation: false) == receipt.manifest
        } catch { return false }
    }
    private func recordFailure(_ proposed: CleanupReceipt, journal: CleanupJournal, operation: InstallerDirectoryAnchor) -> CleanupReceipt {
        do { try journal.append(proposed, operation: operation); return proposed }
        catch {
            // An in-memory guess must never expose restore/delete buttons when
            // its receipt was not durably committed. A fresh read will classify
            // any incomplete record separately, without falling back.
            return CleanupReceipt(id: proposed.id, sequence: proposed.sequence, target: proposed.target,
                originalParent: proposed.originalParent, operationURL: proposed.operationURL,
                operationIdentity: proposed.operationIdentity, state: .uncertain, payloadURL: proposed.payloadURL,
                manifest: proposed.manifest, recordedAt: Date())
        }
    }
    private func catalogSnapshot() throws -> InstallerCatalogSnapshot {
        try InstallerCatalogSnapshot.read(recoveryRoot: environment.recovery)
    }
    private func requireContext(_ context: CleanupContext) throws {
        guard context.catalogIsKnown, context.protectedPaths.count <= 2_000 else {
            throw CleanupFailure.refused(String(localized: "A readable project catalog is required before cache cleanup."))
        }
    }
    static func explanation(_ error: any Error) -> String {
        if error is CancellationError { return String(localized: "Cancelled before this item was changed.") }
        if let error = error as? CleanupFailure { return error.errorDescription! }
        return String(localized: "This cache could not be fully verified. Git ancestry, ownership, links in containing folders, cloud metadata, active writes, or inaccessible contents may make it unsupported.")
    }
}
