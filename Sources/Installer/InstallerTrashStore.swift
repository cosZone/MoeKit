import AppKit
import Foundation
import Observation

/// The UI holds display plans, never filesystem authority. The executor owns
/// descriptors and one-use tokens. A live report only supplies selection hints.
@MainActor @Observable
final class InstallerTrashStore {
    private(set) var selectedPath: String?
    private(set) var plan: InstallerTrashPlan?
    private(set) var restorePlan: InstallerRestorePlan?
    private(set) var installationFinished = false
    private(set) var isDemoEnabled = false
    private(set) var isBusy = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
    private(set) var isCancelling = false
    private(set) var errorMessage: String?
    private(set) var lastOutcome: InstallerTrashOutcome?
    private(set) var lastMutationError: String?
    private(set) var recoveryItems: [InstallerRecoveryItem] = []
    var receipts: [InstallerTrashReceipt] { recoveryItems.compactMap(\.receipt) }
    private(set) var hasReadRecovery = false
    private(set) var eligibleEntries: [MoleAnalyzeEntry] = []
    private(set) var liveAnalysisID: UUID?
    private(set) var liveDirectory: URL?
    private(set) var catalogIsKnown = false
    let isEnabled: Bool
    let downloadsURL: URL?

    @ObservationIgnored var onMutationOutcome: (@MainActor () -> Void)?
    @ObservationIgnored private let executor: (any InstallerTrashExecuting)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let revealLocation: @MainActor (URL) -> Void
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var entryPaths: Set<String> = []
    @ObservationIgnored private var protectedPaths: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var discardTask: Task<Void, Never>?
    @ObservationIgnored private var activeRequest: UUID?

    /// Construction is inert: no scan, recovery read, staging or file move.
    /// Every native operation still needs its independent plan and confirmation.
    init(executor: (any InstallerTrashExecuting)? = NativeInstallerTrashExecutor(nativeExecutionEnabled: true), downloadsURL: URL? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         revealLocation: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.executor = executor
        self.isEnabled = executor != nil
        self.downloadsURL = downloadsURL ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        self.now = now
        self.revealLocation = revealLocation
    }

    var canPrepare: Bool { isEnabled && !isBusy && !isDemoEnabled && selectedPath != nil && currentScope != nil }
    var canReadRecovery: Bool { isEnabled && !isBusy && !isDemoEnabled }

    /// Called synchronously by Workspace for every live-analysis, catalog,
    /// import and mode boundary, including changes that restore earlier values.
    /// Imported report values are never passed here as a live result.
    func updateContext(liveAnalysisID: UUID?, result: MoleAnalysisResult?, isDemoEnabled: Bool,
                       protectedPaths: [String], catalogIsKnown: Bool) {
        invalidate(clearSelection: true)
        self.isDemoEnabled = isDemoEnabled
        self.protectedPaths = protectedPaths
        self.catalogIsKnown = catalogIsKnown
        self.liveAnalysisID = nil; liveDirectory = nil; entryPaths = []; eligibleEntries = []
        guard !isDemoEnabled, let liveAnalysisID, let result, let downloadsURL,
              result.directory.path == downloadsURL.path, result.report.path == downloadsURL.path,
              !result.report.overview, result.report.coverage == .known || result.report.coverage == .partial else { return }
        self.liveAnalysisID = liveAnalysisID
        liveDirectory = result.directory
        entryPaths = Set(result.report.entries.map(\.path))
        eligibleEntries = result.report.entries.filter { entry in
            guard !entry.isDirectory, !entry.insight, entry.coverage == .known,
                  let components = MoleLiveReportValidator.components(entry.path),
                  let root = MoleLiveReportValidator.components(downloadsURL.path),
                  components.count == root.count + 1,
                  components.dropLast().elementsEqual(root) else { return false }
            return URL(fileURLWithPath: entry.path).pathExtension.lowercased() == "dmg"
        }
    }

    func select(path: String?) {
        guard !isBusy else { return }
        invalidate(clearSelection: true)
        guard !isDemoEnabled, currentScope != nil, let path,
              eligibleEntries.contains(where: { $0.path == path }) else { return }
        selectedPath = path
    }

    func prepare() {
        guard canPrepare, let executor, let selectedPath, let scope = currentScope else { return }
        plan = nil; restorePlan = nil; installationFinished = false; errorMessage = nil
        let request = beginRequest(), expectedGeneration = generation, priorDiscard = discardTask
        task = Task { [weak self, executor] in
            do {
                await priorDiscard?.value
                try Task.checkCancellation()
                let prepared = try await executor.prepare(selection: URL(fileURLWithPath: selectedPath), scope: scope)
                try Task.checkCancellation()
                guard let self else { await executor.discardPlans(); return }
                guard self.generation == expectedGeneration, self.currentScope == scope,
                      self.selectedPath == selectedPath, prepared.scope == scope,
                      prepared.originalURL.path == selectedPath, prepared.downloadsURL.path == self.downloadsURL?.path,
                      prepared.expiresAt > self.now() else {
                    await executor.discardPlans(); self.finish(request); return
                }
                self.plan = prepared
                self.finish(request)
            } catch {
                await executor.discardPlans()
                self?.fail(error, request: request, generation: expectedGeneration)
            }
        }
    }

    func attestInstallationFinished(_ finished: Bool, planID: UUID) {
        guard !isBusy, plan?.id == planID else { return }
        installationFinished = finished
    }

    func canConfirm(planID: UUID) -> Bool {
        guard !isBusy, !isDemoEnabled, installationFinished, let plan,
              plan.id == planID, plan.expiresAt > now(), plan.scope == currentScope,
              selectedPath == plan.originalURL.path else { return false }
        return isEnabled
    }

    func confirm(planID: UUID) {
        guard !isBusy, let plan, plan.id == planID else { return }
        guard plan.expiresAt > now() else { invalidate(clearSelection: false); errorMessage = InstallerTrashFailure.expired.errorDescription; return }
        guard canConfirm(planID: planID), let executor, let scope = currentScope else { return }
        self.plan = nil; installationFinished = false; errorMessage = nil
        let request = beginRequest(), expectedGeneration = generation
        task = Task { [weak self, executor] in
            do {
                try Task.checkCancellation()
                guard self?.generation == expectedGeneration, self?.currentScope == scope else { throw InstallerTrashFailure.cancelled }
                let outcome = try await executor.moveToTrash(planID: planID, scope: scope)
                // A synchronous namespace change can outlive cancellation or a
                // Demo switch. Its actual receipt must never be discarded.
                self?.record(outcome)
            } catch { self?.lastMutationError = Self.message(for: error) }
            self?.invalidateAfterMutation()
            self?.finish(request)
        }
    }

    func loadRecovery() {
        guard canReadRecovery, let executor else { return }
        invalidate(clearSelection: false)
        errorMessage = nil
        let request = beginRequest(), expectedGeneration = generation, priorDiscard = discardTask
        task = Task { [weak self, executor] in
            do {
                await priorDiscard?.value; try Task.checkCancellation()
                let loaded = try await executor.recoveryReceipts()
                try Task.checkCancellation()
                guard let self else { return }
                if self.generation == expectedGeneration, !self.isDemoEnabled {
                    // This is a complete successful listing, not an additive
                    // feed. Keep history visible, but revoke a vanished
                    // operation's stale receipt and restore affordance. Absence
                    // does not establish whether its file moved or was removed.
                    let currentIDs = Set(loaded.map(\.id))
                    for index in self.recoveryItems.indices where !currentIDs.contains(self.recoveryItems[index].id) {
                        let previous = self.recoveryItems[index]
                        self.recoveryItems[index] = InstallerRecoveryItem(id: previous.id, operationURL: previous.operationURL,
                            receipt: nil, issue: String(localized: "Recovery record unavailable; outcome unknown"))
                    }
                    for item in loaded { self.merge(item) }
                    self.hasReadRecovery = true
                }
                self.finish(request)
            } catch { self?.fail(error, request: request, generation: expectedGeneration) }
        }
    }

    func prepareRestore(receiptID: UUID) {
        guard canReadRecovery, catalogIsKnown, let executor,
              receipts.contains(where: { $0.id == receiptID && $0.canOfferRestore }) else { return }
        invalidate(clearSelection: false)
        errorMessage = nil
        let request = beginRequest(), expectedGeneration = generation, priorDiscard = discardTask
        let context = recoveryContext
        task = Task { [weak self, executor] in
            do {
                await priorDiscard?.value; try Task.checkCancellation()
                let prepared = try await executor.prepareRestore(receiptID: receiptID, context: context)
                try Task.checkCancellation()
                guard let self else { await executor.discardPlans(); return }
                guard self.generation == expectedGeneration, !self.isDemoEnabled,
                      prepared.receipt.id == receiptID, prepared.context == context, self.recoveryContext == context,
                      prepared.expiresAt > self.now() else {
                    await executor.discardPlans(); self.finish(request); return
                }
                self.restorePlan = prepared
                self.finish(request)
            } catch {
                await executor.discardPlans()
                self?.fail(error, request: request, generation: expectedGeneration)
            }
        }
    }

    func canConfirmRestore(planID: UUID) -> Bool {
        isEnabled && !isBusy && !isDemoEnabled && catalogIsKnown && restorePlan?.id == planID
            && restorePlan?.context == recoveryContext && (restorePlan?.expiresAt ?? .distantPast) > now()
    }

    func confirmRestore(planID: UUID) {
        guard !isBusy, let restorePlan, restorePlan.id == planID else { return }
        guard restorePlan.expiresAt > now() else { invalidate(clearSelection: false); errorMessage = InstallerTrashFailure.expired.errorDescription; return }
        guard canConfirmRestore(planID: planID), let executor else { return }
        self.restorePlan = nil; errorMessage = nil
        let request = beginRequest(), expectedGeneration = generation
        task = Task { [weak self, executor] in
            do {
                try Task.checkCancellation()
                guard self?.generation == expectedGeneration, self?.isDemoEnabled == false,
                      self?.recoveryContext == restorePlan.context else { throw InstallerTrashFailure.cancelled }
                let outcome = try await executor.restore(planID: planID, context: restorePlan.context)
                self?.record(outcome)
            } catch { self?.lastMutationError = Self.message(for: error) }
            self?.invalidateAfterMutation()
            self?.finish(request)
        }
    }

    /// Never reveal a decoded/stale receipt URL directly. The executor performs
    /// a fresh read-only validation of the actual recovery location first.
    func reveal(receiptID: UUID) {
        guard canReadRecovery, let executor, recoveryItems.contains(where: { $0.id == receiptID }) else { return }
        let request = beginRequest(), expectedGeneration = generation
        task = Task { [weak self, executor] in
            do {
                let location = try await executor.validatedRecoveryLocation(receiptID: receiptID)
                try Task.checkCancellation()
                guard let self else { return }
                if self.generation == expectedGeneration, !self.isDemoEnabled { self.revealLocation(location) }
                self.finish(request)
            } catch { self?.fail(error, request: request, generation: expectedGeneration) }
        }
    }

    func cancel() { invalidate(clearSelection: false) }

    private var recoveryContext: InstallerRecoveryContext {
        InstallerRecoveryContext(generation: generation, protectedPaths: protectedPaths, catalogIsKnown: catalogIsKnown)
    }

    private var currentScope: InstallerTrashScope? {
        guard !isDemoEnabled, catalogIsKnown, let liveAnalysisID, let liveDirectory else { return nil }
        return InstallerTrashScope(generation: generation, liveAnalysisID: liveAnalysisID, liveDirectory: liveDirectory,
                                   liveEntryPaths: entryPaths, protectedPaths: protectedPaths, catalogIsKnown: catalogIsKnown)
    }

    private func invalidate(clearSelection: Bool) {
        generation = UUID(); plan = nil; restorePlan = nil; installationFinished = false; errorMessage = nil
        if clearSelection { selectedPath = nil }
        if task != nil { isCancelling = true; task?.cancel() }
        if let executor {
            // Serialize invalidations so a delayed discard cannot erase a new
            // token. New preparation waits for this chain before invoking IO.
            let previous = discardTask
            discardTask = Task { await previous?.value; await executor.discardPlans() }
        }
    }

    private func beginRequest() -> UUID {
        let id = UUID(); activeRequest = id; isBusy = true; isCancelling = false
        return id
    }
    private func finish(_ request: UUID) {
        guard activeRequest == request else { return }
        task = nil; activeRequest = nil; isBusy = false; isCancelling = false
    }
    private func fail(_ error: any Error, request: UUID, generation expected: UUID) {
        if generation == expected, !isDemoEnabled { errorMessage = Self.message(for: error) }
        finish(request)
    }
    private func invalidateAfterMutation() {
        // Once execution was submitted, even an uncertain or cancelled return
        // makes the old report's membership and measured sizes obsolete.
        invalidate(clearSelection: true)
        liveAnalysisID = nil; liveDirectory = nil; entryPaths = []; eligibleEntries = []
        onMutationOutcome?()
    }
    private func record(_ outcome: InstallerTrashOutcome) {
        lastOutcome = outcome; lastMutationError = nil
        if let receipt = outcome.receipt {
            merge(InstallerRecoveryItem(id: receipt.id, operationURL: receipt.operationURL, receipt: receipt, issue: nil))
        }
    }
    private func merge(_ item: InstallerRecoveryItem) {
        if let index = recoveryItems.firstIndex(where: { $0.id == item.id }) {
            // Unknown/corrupt records must replace previously valid display
            // data, so that no stale restore affordance survives a fresh read.
            recoveryItems[index] = item
        } else { recoveryItems.append(item) }
        recoveryItems.sort { $0.operationURL.path < $1.operationURL.path }
    }
    private static func message(for error: any Error) -> String {
        if error is CancellationError { return InstallerTrashFailure.cancelled.errorDescription! }
        return (error as? InstallerTrashFailure)?.errorDescription
            ?? String(localized: "The operation could not be verified. Read recovery records before trying again; no automatic retry will occur.")
    }
}
