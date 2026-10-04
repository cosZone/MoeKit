import Darwin
import Foundation

protocol InstallerTrashSink: Sendable {
    func trash(_ url: URL) throws -> URL
}
struct NativeInstallerTrashSink: InstallerTrashSink {
    func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let resulting else { throw InstallerTrashFailure.changed }
        return resulting as URL
    }
}

struct InstallerTrashEnvironment: Sendable {
    let downloads: URL
    let recoveryRoot: URL
    let trash: URL
    let enforceLocalVolume: Bool
    static var user: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return .init(downloads: home.appendingPathComponent("Downloads"),
                     recoveryRoot: home.appendingPathComponent("Library/Application Support/MoeKit/InstallerRecovery"),
                     trash: home.appendingPathComponent(".Trash"), enforceLocalVolume: true)
    }
}

enum InstallerMutationCheckpoint: Equatable, Sendable { case beforeCapture, afterCapture, beforeTrash, afterTrash, afterRollback, beforeRestoreCapture, afterRestoreCapture, beforeRestore }

/// This actor owns all descriptors and one-use plans. There is no report-import,
/// serialized-plan, batch, permanent-delete or broad Mole-command execution API.
actor NativeInstallerTrashExecutor: InstallerTrashExecuting {
    private struct Prepared {
        let display: InstallerTrashPlan
        let parent: InstallerDirectoryAnchor
        let file: InstallerFileDescriptor
        let catalog: InstallerCatalogSnapshot
    }
    private struct PreparedRestore {
        let display: InstallerRestorePlan
        let parent: InstallerDirectoryAnchor
        let sourceParent: InstallerDirectoryAnchor
        let source: InstallerFileDescriptor
        let sourceIdentity: InstallerFileSnapshot
        let catalog: InstallerCatalogSnapshot
    }
    private let environment: InstallerTrashEnvironment
    private let evidence: any InstallerUseEvidenceProviding
    private let sink: any InstallerTrashSink
    private let nativeExecutionEnabled: Bool
    private let checkpoint: @Sendable (InstallerMutationCheckpoint) throws -> Void
    private var prepared: Prepared?
    private var preparedRestore: PreparedRestore?
    private var isMutating = false

    init(environment: InstallerTrashEnvironment = .user,
         evidence: any InstallerUseEvidenceProviding = NativeInstallerUseEvidenceProvider(),
         sink: any InstallerTrashSink = NativeInstallerTrashSink(),
         nativeExecutionEnabled: Bool = false,
         checkpoint: @escaping @Sendable (InstallerMutationCheckpoint) throws -> Void = { _ in }) {
        self.environment = environment; self.evidence = evidence; self.sink = sink
        self.nativeExecutionEnabled = nativeExecutionEnabled; self.checkpoint = checkpoint
    }
    func discardPlans() { prepared = nil; preparedRestore = nil }

    func prepare(selection: URL, scope: InstallerTrashScope) async throws -> InstallerTrashPlan {
        guard !isMutating else { throw InstallerTrashFailure.busy }
        discardPlans()
        try validateScope(selection, scope)
        let catalog = try catalogSnapshot(protecting: selection)
        let parent = try InstallerDirectoryAnchor.open(environment.downloads)
        try validateParent(parent)
        let namedBeforeOpen = try InstallerFileAccess.snapshotAt(parent.fd, selection.lastPathComponent)
        try InstallerFileAccess.validateRegular(namedBeforeOpen)
        let file = try InstallerFileDescriptor(parent: parent, name: selection.lastPathComponent)
        let identity = try InstallerFileAccess.snapshot(file.fd)
        guard namedBeforeOpen == identity else { throw InstallerTrashFailure.changed }
        try validateFile(file.fd, identity: identity, url: selection)
        guard identity.device == parent.identity.device,
              identity == (try InstallerFileAccess.snapshotAt(parent.fd, selection.lastPathComponent)) else { throw InstallerTrashFailure.changed }
        try await requireNoObservedUse(identity, path: selection.path, excluding: [file.fd])
        try parent.validate()
        guard identity == (try InstallerFileAccess.snapshot(file.fd)), identity == (try InstallerFileAccess.snapshotAt(parent.fd, selection.lastPathComponent)) else { throw InstallerTrashFailure.changed }
        try Task.checkCancellation()
        guard try catalogSnapshot(protecting: selection) == catalog else { throw InstallerTrashFailure.changed }
        let id = UUID(), now = Date()
        let display = InstallerTrashPlan(id: id, scope: scope, originalURL: selection, downloadsURL: environment.downloads,
            recoveryURL: environment.recoveryRoot.appendingPathComponent(id.uuidString), file: identity, preparedAt: now, expiresAt: now.addingTimeInterval(120))
        prepared = Prepared(display: display, parent: parent, file: file, catalog: catalog)
        return display
    }

    func moveToTrash(planID: UUID, scope: InstallerTrashScope) async throws -> InstallerTrashOutcome {
        guard nativeExecutionEnabled else { throw InstallerTrashFailure.unavailable(String(localized: "File moves are unavailable in this build while native recovery verification is pending.")) }
        guard !isMutating else { throw InstallerTrashFailure.busy }
        guard let plan = prepared, plan.display.id == planID, plan.display.scope == scope, Date() < plan.display.expiresAt else { throw InstallerTrashFailure.expired }
        prepared = nil; preparedRestore = nil; isMutating = true
        defer { isMutating = false }
        try validateScope(plan.display.originalURL, scope)
        try revalidate(plan)
        try await requireNoObservedUse(plan.display.file, path: plan.display.originalURL.path, excluding: [plan.file.fd])
        try revalidate(plan); try Task.checkCancellation()
        let journal = try InstallerRecoveryJournal(rootURL: environment.recoveryRoot, create: true, exclusive: true)
        guard journal.root.identity.device == plan.parent.identity.device else { throw InstallerTrashFailure.unsupportedRename }
        let catalogLease = try InstallerCatalogLease(app: journal.appParent)
        defer { withExtendedLifetime(catalogLease) {} }
        try catalogLease.requireSnapshot(plan.catalog)
        let operation = try journal.createOperation(planID)
        var receipt = InstallerTrashReceipt(policy: InstallerTrashReceipt.policyVersion, id: planID, sequence: 0,
            originalURL: plan.display.originalURL, originalParent: plan.parent.identity, originalFile: plan.display.file,
            operationURL: operation.url, operationDirectory: operation.identity, state: .captureIntent,
            recordedAt: Date(), payloadName: plan.display.originalURL.lastPathComponent, trashURL: nil, trashFile: nil)
        try journal.append(receipt, operation: operation)
        var captured = false
        var capturedSnapshot: InstallerFileSnapshot?
        var trashStarted = false
        do {
            try revalidate(plan); try journal.validate(); try catalogLease.requireSnapshot(plan.catalog); try Task.checkCancellation()
            try checkpoint(.beforeCapture)
            try InstallerFileAccess.exclusiveMove(from: plan.parent, name: plan.display.originalURL.lastPathComponent,
                to: operation, destinationName: plan.display.originalURL.lastPathComponent)
            captured = true
            capturedSnapshot = try InstallerFileAccess.snapshotAt(operation.fd, plan.display.originalURL.lastPathComponent)
            guard fsync(plan.parent.fd) == 0, fsync(operation.fd) == 0 else { throw InstallerTrashFailure.journal }
            try checkpoint(.afterCapture)
            // lstat before opening prevents unexpected directories/FIFOs/devices
            // from ever being read. A wrong capture can only roll back or remain.
            let capturedIdentity = try InstallerFileAccess.snapshotAt(operation.fd, plan.display.originalURL.lastPathComponent)
            guard capturedIdentity == capturedSnapshot else { throw InstallerTrashFailure.changed }
            receipt = receipt.advancing(to: .captured, payloadName: plan.display.originalURL.lastPathComponent, payloadFile: capturedIdentity)
            try journal.append(receipt, operation: operation)
            guard plan.display.file.matchesCaptured(capturedIdentity), plan.display.file.matchesCaptured(try InstallerFileAccess.snapshot(plan.file.fd)) else { throw InstallerTrashFailure.changed }
            let staged = try InstallerFileDescriptor(parent: operation, name: plan.display.originalURL.lastPathComponent)
            guard capturedIdentity == (try InstallerFileAccess.snapshot(staged.fd)) else { throw InstallerTrashFailure.changed }
            try await requireNoObservedUse(capturedIdentity, path: operation.url.appendingPathComponent(plan.display.originalURL.lastPathComponent).path,
                                          excluding: [plan.file.fd, staged.fd])
            try Task.checkCancellation()
            try validateParent(plan.parent); try operation.validate(); try journal.validate(); try catalogLease.requireSnapshot(plan.catalog)
            guard capturedIdentity == (try InstallerFileAccess.snapshotAt(operation.fd, plan.display.originalURL.lastPathComponent)),
                  capturedIdentity == (try InstallerFileAccess.snapshot(staged.fd)) else { throw InstallerTrashFailure.changed }
            receipt = receipt.advancing(to: .trashIntent, payloadName: plan.display.originalURL.lastPathComponent)
            try journal.append(receipt, operation: operation)
            try checkpoint(.beforeTrash); try Task.checkCancellation()
            try operation.validate(); try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
            guard capturedIdentity == (try InstallerFileAccess.snapshotAt(operation.fd, plan.display.originalURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
            // Apple accepts a URL, not an expected inode. Under the documented
            // cooperative threat model, never call it on the untrusted Downloads name.
            trashStarted = true
            let destination = try sink.trash(operation.url.appendingPathComponent(plan.display.originalURL.lastPathComponent))
            try checkpoint(.afterTrash)
            let actual = try verifiedTrashFile(destination, expected: plan.display.file)
            receipt = receipt.advancing(to: .trashed, trashURL: destination, trashFile: actual)
            try journal.append(receipt, operation: operation)
            return .init(receipt: receipt, message: String(localized: "File moved to Trash. This does not free disk space until Trash is emptied."), movedToTrash: true, requiresRecovery: false)
        } catch {
            if trashStarted {
                let unknown = receipt.advancing(to: .uncertain, payloadName: plan.display.originalURL.lastPathComponent)
                try? journal.append(unknown, operation: operation)
                return .init(receipt: unknown, message: String(localized: "The Trash outcome could not be verified. Do not repeat the move; inspect recovery and Finder."), movedToTrash: false, requiresRecovery: true)
            }
            if captured { return rollback(receipt, journal: journal, operation: operation, originalParent: plan.parent, payloadName: plan.display.originalURL.lastPathComponent, capturedSnapshot: capturedSnapshot) }
            throw error
        }
    }

    func recoveryReceipts() throws -> [InstallerRecoveryItem] {
        guard !isMutating else { throw InstallerTrashFailure.busy }
        // Missing private storage is an empty recovery history. All other errors
        // remain visible and never become an empty list.
        var status = stat()
        if lstat(environment.recoveryRoot.path, &status) != 0, errno == ENOENT { return [] }
        return try InstallerRecoveryJournal(rootURL: environment.recoveryRoot, create: false, exclusive: false).receipts()
    }
    func validatedRecoveryLocation(receiptID: UUID) throws -> URL {
        let journal = try InstallerRecoveryJournal(rootURL: environment.recoveryRoot, create: false, exclusive: false)
        let operation = try journal.operation(receiptID)
        guard let receipt = try? journal.latest(receiptID) else { return operation.url }
        if receipt.state == .trashed, let url = receipt.trashURL { _ = try verifiedTrashFile(url, expected: receipt.originalFile, exact: receipt.trashFile); return url }
        // Unknown/unexpected payloads are revealed as the validated owned
        // operation folder, not followed or converted to restore authority.
        return try journal.operation(receiptID).url
    }
    func prepareRestore(receiptID: UUID, context: InstallerRecoveryContext) async throws -> InstallerRestorePlan {
        guard !isMutating else { throw InstallerTrashFailure.busy }
        discardPlans()
        let journal = try InstallerRecoveryJournal(rootURL: environment.recoveryRoot, create: false, exclusive: false)
        let receipt = try journal.latest(receiptID)
        try validateRecoveryContext(context, target: receipt.originalURL)
        let catalog = try catalogSnapshot(protecting: receipt.originalURL)
        guard receipt.canOfferRestore else { throw InstallerTrashFailure.unavailable(String(localized: "This receipt has an uncertain or completed outcome. Inspect it in Finder; MoeKit will not retry automatically.")) }
        let parent = try InstallerDirectoryAnchor.open(receipt.originalURL.deletingLastPathComponent())
        guard parent.url.path == environment.downloads.path, receipt.originalParent.matchesDirectory(parent.identity) else { throw InstallerTrashFailure.changed }
        try validateParent(parent); try InstallerFileAccess.assertAbsent(parent, receipt.originalURL.lastPathComponent)
        let sourceURL: URL
        if receipt.state == .trashed {
            guard let trash = receipt.trashURL else { throw InstallerTrashFailure.journal }
            _ = try verifiedTrashFile(trash, expected: receipt.originalFile, exact: receipt.trashFile); sourceURL = trash
        } else {
            guard let name = receipt.payloadName else { throw InstallerTrashFailure.journal }
            try InstallerFileAccess.basename(name)
            guard name == receipt.originalURL.lastPathComponent || name == "restore.dmg" else { throw InstallerTrashFailure.journal }
            sourceURL = receipt.operationURL.appendingPathComponent(name)
        }
        let sourceParent = try InstallerDirectoryAnchor.open(sourceURL.deletingLastPathComponent())
        let expectedSource = receipt.state == .trashed ? receipt.trashFile : receipt.payloadFile
        guard let expectedSource,
              expectedSource == (try InstallerFileAccess.snapshotAt(sourceParent.fd, sourceURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
        try InstallerFileAccess.validateRegular(expectedSource)
        let source = try InstallerFileDescriptor(parent: sourceParent, name: sourceURL.lastPathComponent)
        let identity = try InstallerFileAccess.snapshot(source.fd)
        guard identity == expectedSource, receipt.originalFile.matchesCaptured(identity), identity == (try InstallerFileAccess.snapshotAt(sourceParent.fd, sourceURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
        try await requireNoObservedUse(identity, path: sourceURL.path, excluding: [source.fd])
        try parent.validate(); try sourceParent.validate()
        guard identity == (try InstallerFileAccess.snapshot(source.fd)),
              identity == (try InstallerFileAccess.snapshotAt(sourceParent.fd, sourceURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
        try InstallerFileAccess.assertAbsent(parent, receipt.originalURL.lastPathComponent)
        try Task.checkCancellation()
        guard try catalogSnapshot(protecting: receipt.originalURL) == catalog else { throw InstallerTrashFailure.changed }
        let now = Date()
        let display = InstallerRestorePlan(id: UUID(), receipt: receipt, sourceURL: sourceURL, context: context, preparedAt: now, expiresAt: now.addingTimeInterval(120))
        preparedRestore = .init(display: display, parent: parent, sourceParent: sourceParent, source: source, sourceIdentity: identity, catalog: catalog)
        return display
    }
    func restore(planID: UUID, context: InstallerRecoveryContext) async throws -> InstallerTrashOutcome {
        guard nativeExecutionEnabled else { throw InstallerTrashFailure.unavailable(String(localized: "File moves are unavailable in this build while native recovery verification is pending.")) }
        guard !isMutating else { throw InstallerTrashFailure.busy }
        guard let plan = preparedRestore, plan.display.id == planID, plan.display.context == context, Date() < plan.display.expiresAt else { throw InstallerTrashFailure.expired }
        preparedRestore = nil; prepared = nil; isMutating = true
        defer { isMutating = false }
        try validateRecoveryContext(context, target: plan.display.receipt.originalURL)
        let journal = try InstallerRecoveryJournal(rootURL: environment.recoveryRoot, create: false, exclusive: true)
        let catalogLease = try InstallerCatalogLease(app: journal.appParent)
        defer { withExtendedLifetime(catalogLease) {} }
        try catalogLease.requireSnapshot(plan.catalog)
        guard try journal.latest(plan.display.receipt.id) == plan.display.receipt else { throw InstallerTrashFailure.changed }
        let operation = try journal.operation(plan.display.receipt.id)
        try plan.parent.validate(); try plan.sourceParent.validate()
        try InstallerFileAccess.assertAbsent(plan.parent, plan.display.receipt.originalURL.lastPathComponent)
        guard plan.sourceIdentity == (try InstallerFileAccess.snapshot(plan.source.fd)),
              plan.sourceIdentity == (try InstallerFileAccess.snapshotAt(plan.sourceParent.fd, plan.display.sourceURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
        try await requireNoObservedUse(plan.sourceIdentity, path: plan.display.sourceURL.path, excluding: [plan.source.fd])
        try Task.checkCancellation()
        var receipt = plan.display.receipt
        var captured = false
        var restoreCapturedSnapshot: InstallerFileSnapshot?
        var restoreStageChanged = false
        var restoreRollbackCommitted = false
        var capturedVerified = false
        var originalMoveStarted = false
        // A retained source already in this exact restore slot needs no second
        // capture; all other sources get a verified exclusive stage first.
        let alreadyStaged = plan.sourceParent.url.path == operation.url.path && plan.display.sourceURL.lastPathComponent == "restore.dmg"
        do {
            receipt = receipt.advancing(to: .restoreCaptureIntent, payloadName: alreadyStaged ? "restore.dmg" : plan.display.sourceURL.lastPathComponent)
            try journal.append(receipt, operation: operation)
            // The observation and durable intent both take time. Recheck the
            // exact pre-rename snapshot (including ctime) immediately afterward.
            try plan.parent.validate(); try plan.sourceParent.validate(); try catalogLease.requireSnapshot(plan.catalog)
            guard plan.sourceIdentity == (try InstallerFileAccess.snapshot(plan.source.fd)),
                  plan.sourceIdentity == (try InstallerFileAccess.snapshotAt(plan.sourceParent.fd, plan.display.sourceURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
            try InstallerFileAccess.assertAbsent(plan.parent, receipt.originalURL.lastPathComponent)
            try Task.checkCancellation()
            if !alreadyStaged {
                try checkpoint(.beforeRestoreCapture)
                try InstallerFileAccess.exclusiveMove(from: plan.sourceParent, name: plan.display.sourceURL.lastPathComponent, to: operation, destinationName: "restore.dmg")
            }
            captured = true
            restoreCapturedSnapshot = try InstallerFileAccess.snapshotAt(operation.fd, "restore.dmg")
            guard fsync(plan.sourceParent.fd) == 0, fsync(operation.fd) == 0 else { throw InstallerTrashFailure.journal }
            try checkpoint(.afterRestoreCapture)
            let stagedIdentity = try InstallerFileAccess.snapshotAt(operation.fd, "restore.dmg")
            guard stagedIdentity == restoreCapturedSnapshot else { restoreStageChanged = true; throw InstallerTrashFailure.changed }
            receipt = receipt.advancing(to: .restoreCaptured, payloadName: "restore.dmg", payloadFile: stagedIdentity)
            try journal.append(receipt, operation: operation)
            guard plan.sourceIdentity.matchesCaptured(stagedIdentity), plan.sourceIdentity.matchesCaptured(try InstallerFileAccess.snapshot(plan.source.fd)) else { throw InstallerTrashFailure.changed }
            capturedVerified = true
            try Task.checkCancellation(); try validateParent(plan.parent); try catalogLease.requireSnapshot(plan.catalog)
            try InstallerFileAccess.assertAbsent(plan.parent, receipt.originalURL.lastPathComponent)
            receipt = receipt.advancing(to: .restoreIntent, payloadName: "restore.dmg")
            try journal.append(receipt, operation: operation)
            try checkpoint(.beforeRestore); try Task.checkCancellation()
            guard stagedIdentity == (try InstallerFileAccess.snapshotAt(operation.fd, "restore.dmg")) else { restoreStageChanged = true; throw InstallerTrashFailure.changed }
            try InstallerFileAccess.exclusiveMove(from: operation, name: "restore.dmg", to: plan.parent, destinationName: receipt.originalURL.lastPathComponent)
            originalMoveStarted = true
            guard receipt.originalFile.matchesCaptured(try InstallerFileAccess.snapshotAt(plan.parent.fd, receipt.originalURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
            guard fsync(plan.parent.fd) == 0, fsync(operation.fd) == 0 else { throw InstallerTrashFailure.journal }
            receipt = receipt.advancing(to: .restored)
            try journal.append(receipt, operation: operation)
            return .init(receipt: receipt, message: String(localized: "File restored to its original Downloads path. No existing file was replaced."), movedToTrash: false, requiresRecovery: false)
        } catch {
            if captured, !capturedVerified, !originalMoveStarted, !alreadyStaged, journal.mutationJournalIsHealthy {
                // Capture races must not return an unexpected object to Downloads.
                // Return it only to its original anchored recovery/Trash name.
                do {
                    guard let restoreCapturedSnapshot else { throw InstallerTrashFailure.changed }
                    guard restoreCapturedSnapshot == (try InstallerFileAccess.snapshotAt(operation.fd, "restore.dmg")) else {
                        restoreStageChanged = true; throw InstallerTrashFailure.changed
                    }
                    guard try journal.latest(receipt.id) == receipt else { throw InstallerTrashFailure.journal }
                    let intent = receipt.advancing(to: .rollbackIntent, payloadName: "restore.dmg", payloadFile: restoreCapturedSnapshot)
                    try journal.append(intent, operation: operation); receipt = intent
                    try InstallerFileAccess.exclusiveMove(from: operation, name: "restore.dmg", to: plan.sourceParent, destinationName: plan.display.sourceURL.lastPathComponent)
                    restoreRollbackCommitted = true
                    guard restoreCapturedSnapshot.matchesCaptured(try InstallerFileAccess.snapshotAt(plan.sourceParent.fd, plan.display.sourceURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
                    guard fsync(operation.fd) == 0, fsync(plan.sourceParent.fd) == 0 else { throw InstallerTrashFailure.journal }
                    let retained = receipt.advancing(to: .uncertain)
                    try journal.append(retained, operation: operation)
                    return .init(receipt: retained, message: String(localized: "Restore stopped and the captured item was returned without replacing anything. Review recovery; a new restore is not automatic."), movedToTrash: false, requiresRecovery: true)
                } catch { /* Keep every remaining object intact. */ }
            }
            let retained = receipt.advancing(to: originalMoveStarted || !captured || restoreStageChanged || restoreRollbackCommitted ? .uncertain : .retained, payloadName: captured && !originalMoveStarted ? "restore.dmg" : nil)
            try? journal.append(retained, operation: operation)
            return .init(receipt: retained, message: String(localized: "Restore could not be verified. Existing destinations were not overwritten; inspect the retained recovery location."), movedToTrash: false, requiresRecovery: true)
        }
    }

    private func rollback(_ receipt: InstallerTrashReceipt, journal: InstallerRecoveryJournal, operation: InstallerDirectoryAnchor,
                          originalParent: InstallerDirectoryAnchor, payloadName: String, capturedSnapshot: InstallerFileSnapshot?) -> InstallerTrashOutcome {
        var latest = receipt
        var returnedToOriginal = false
        var stageWasReplaced = false
        do {
            guard journal.mutationJournalIsHealthy, try journal.latest(receipt.id) == receipt else { throw InstallerTrashFailure.journal }
            guard let capturedSnapshot else { throw InstallerTrashFailure.changed }
            guard capturedSnapshot == (try InstallerFileAccess.snapshotAt(operation.fd, payloadName)) else {
                stageWasReplaced = true
                throw InstallerTrashFailure.changed
            }
            let intent = latest.advancing(to: .rollbackIntent, payloadName: payloadName, payloadFile: capturedSnapshot)
            try journal.append(intent, operation: operation); latest = intent
            try InstallerFileAccess.exclusiveMove(from: operation, name: payloadName, to: originalParent, destinationName: receipt.originalURL.lastPathComponent)
            returnedToOriginal = true
            guard capturedSnapshot.matchesCaptured(try InstallerFileAccess.snapshotAt(originalParent.fd, receipt.originalURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
            try checkpoint(.afterRollback)
            guard fsync(originalParent.fd) == 0, fsync(operation.fd) == 0 else { throw InstallerTrashFailure.journal }
            let rolledBack = latest.advancing(to: .rolledBack)
            try journal.append(rolledBack, operation: operation)
            return .init(receipt: rolledBack, message: String(localized: "The move stopped before Trash. The captured item was returned without replacing anything."), movedToTrash: false, requiresRecovery: false)
        } catch {
            let retained = latest.advancing(to: returnedToOriginal || stageWasReplaced ? .uncertain : .retained, payloadName: returnedToOriginal ? nil : payloadName)
            try? journal.append(retained, operation: operation)
            return .init(receipt: retained, message: returnedToOriginal ? String(localized: "The captured item was returned, but its final recovery record could not be verified. Inspect the original and recovery locations; do not repeat the move.") : String(localized: "The move stopped before Trash. Recovery data was retained; inspect it before any new operation."), movedToTrash: false, requiresRecovery: true)
        }
    }
    private func catalogSnapshot(protecting target: URL) throws -> InstallerCatalogSnapshot {
        let snapshot = try InstallerCatalogSnapshot.read(recoveryRoot: environment.recoveryRoot)
        try validateRecoveryContext(.init(generation: UUID(), protectedPaths: try snapshot.protectedPaths, catalogIsKnown: true), target: target)
        return snapshot
    }
    private func validateScope(_ selection: URL, _ scope: InstallerTrashScope) throws {
        _ = try InstallerFileAccess.components(selection)
        guard scope.catalogIsKnown, scope.protectedPaths.count <= 2_000 else { throw InstallerTrashFailure.protected }
        guard scope.liveDirectory.path == environment.downloads.path, scope.liveEntryPaths.count <= 50_000,
              scope.liveEntryPaths.contains(selection.path), selection.deletingLastPathComponent().path == environment.downloads.path,
              selection.pathExtension.lowercased() == "dmg", !selection.lastPathComponent.hasPrefix(".") else { throw InstallerTrashFailure.unsupported }
        try validateRecoveryContext(.init(generation: scope.generation, protectedPaths: scope.protectedPaths, catalogIsKnown: scope.catalogIsKnown), target: selection)
    }
    private func validateRecoveryContext(_ context: InstallerRecoveryContext, target: URL) throws {
        guard context.catalogIsKnown, context.protectedPaths.count <= 2_000 else { throw InstallerTrashFailure.protected }
        for path in context.protectedPaths {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw InstallerTrashFailure.protected }
            let protected = URL(fileURLWithPath: path).pathComponents
            let root = target.pathComponents
            if root.starts(with: protected) || protected.starts(with: root) { throw InstallerTrashFailure.protected }
        }
    }
    private func validateParent(_ parent: InstallerDirectoryAnchor) throws {
        try parent.validate(); try parent.rejectGitAncestors()
        guard parent.identity.uid == geteuid(), parent.identity.mode & 0o022 == 0,
              parent.identity.device == parent.parent?.identity.device else { throw InstallerTrashFailure.unsupported }
        if environment.enforceLocalVolume { try InstallerFileAccess.validateVolume(parent.fd, url: parent.url) }
        try InstallerFileAccess.rejectCloudAttributes(parent.fd)
    }
    private func validateFile(_ fd: Int32, identity: InstallerFileSnapshot, url: URL) throws {
        try InstallerFileAccess.validateRegular(identity)
        try InstallerFileAccess.rejectCloudAttributes(fd)
        if environment.enforceLocalVolume { try InstallerFileAccess.validateVolume(fd, url: url) }
    }
    private func revalidate(_ plan: Prepared) throws {
        try validateParent(plan.parent)
        guard plan.display.file == (try InstallerFileAccess.snapshot(plan.file.fd)),
              plan.display.file == (try InstallerFileAccess.snapshotAt(plan.parent.fd, plan.display.originalURL.lastPathComponent)) else { throw InstallerTrashFailure.changed }
        try validateFile(plan.file.fd, identity: plan.display.file, url: plan.display.originalURL)
    }
    private func requireNoObservedUse(_ identity: InstallerFileSnapshot, path: String, excluding descriptors: Set<Int32>) async throws {
        let result = await evidence.evidence(for: .init(device: identity.device, inode: identity.inode, path: path, observerRetainedFileDescriptors: descriptors))
        switch result {
        case .noUseObserved: return
        case .observedUse(let reason), .unavailable(let reason): throw InstallerTrashFailure.unavailable(reason)
        }
    }
    private func verifiedTrashFile(_ url: URL, expected: InstallerFileSnapshot, exact: InstallerFileSnapshot? = nil) throws -> InstallerFileSnapshot {
        _ = try InstallerFileAccess.components(url)
        guard url.deletingLastPathComponent().path == environment.trash.path else { throw InstallerTrashFailure.changed }
        let parent = try InstallerDirectoryAnchor.open(environment.trash)
        guard parent.identity.uid == geteuid(), parent.identity.device == expected.device else { throw InstallerTrashFailure.changed }
        let named = try InstallerFileAccess.snapshotAt(parent.fd, url.lastPathComponent)
        guard expected.matchesCaptured(named), exact == nil || exact == named else { throw InstallerTrashFailure.changed }
        let file = try InstallerFileDescriptor(parent: parent, name: url.lastPathComponent)
        let actual = try InstallerFileAccess.snapshot(file.fd)
        guard expected.matchesCaptured(actual), exact == nil || exact == actual, actual == (try InstallerFileAccess.snapshotAt(parent.fd, url.lastPathComponent)) else { throw InstallerTrashFailure.changed }
        return actual
    }
}
