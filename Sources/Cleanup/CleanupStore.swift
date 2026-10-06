import Foundation
import Observation

/// The workspace generation is separate from plan invalidation: changing a
/// selection revokes a confirmation without changing the inspected scope.
struct CleanupWorkspaceContext: Equatable {
    let isDemoEnabled: Bool
    let modeGeneration: UUID
    let protectedPaths: [String]
    let catalogIsKnown: Bool
}

@MainActor @Observable
final class CleanupStore {
    private(set) var rootURL: URL?
    private(set) var inspection: CleanupInspection?
    private(set) var selectedPaths: Set<String> = []
    private(set) var plan: CleanupPlan?
    private(set) var recoveryPlan: CleanupRecoveryPlan?
    private(set) var workloadsStopped = false
    private(set) var contentRegenerable = false
    private(set) var irreversibleDeletionAccepted = false
    private(set) var isDemoEnabled = false
    private(set) var catalogIsKnown = false
    private(set) var isBusy = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
    private(set) var isCancelling = false
    private(set) var scanProgress: DirectoryScanProgress?
    private(set) var errorMessage: String?
    private(set) var lastMutationError: String?
    private(set) var lastOutcome: CleanupOutcome?
    private(set) var recoveryItems: [CleanupRecoveryItem] = []
    private(set) var hasReadRecovery = false
    let isEnabled: Bool

    @ObservationIgnored var onMutationOutcome: (@MainActor () -> Void)?
    @ObservationIgnored private let executor: (any CleanupExecuting)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var workspaceContext: CleanupWorkspaceContext?
    @ObservationIgnored private var contextProvider: (@MainActor () -> CleanupWorkspaceContext)?
    @ObservationIgnored private var contextGeneration = UUID()
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var discardTask: Task<Void, Never>?
    @ObservationIgnored private var activeRequest: UUID?

    /// Inert: no folder inspection, recovery read, directory creation or mutation.
    init(executor: (any CleanupExecuting)? = NativeCleanupExecutor(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.executor = executor
        self.isEnabled = executor != nil
        self.now = now
    }

    var candidates: [CleanupCandidate] { inspection?.candidates ?? [] }
    var receipts: [CleanupReceipt] { recoveryItems.compactMap(\.receipt) }
    var canInspect: Bool { isEnabled && !isBusy && !isDemoEnabled && rootURL != nil }
    var canPrepare: Bool { canInspect && catalogIsKnown && inspection != nil && !selectedPaths.isEmpty }
    var canReadRecovery: Bool { isEnabled && !isBusy && !isDemoEnabled }

    /// Read current workspace state before queued work and confirmations too;
    /// SwiftUI onChange alone may arrive after the next actor turn.
    func bindContext(_ provider: @escaping @MainActor () -> CleanupWorkspaceContext) {
        contextProvider = provider
        synchronizeContext()
    }

    func updateContext(_ value: CleanupWorkspaceContext) {
        guard workspaceContext != value else { return }
        workspaceContext = value
        isDemoEnabled = value.isDemoEnabled
        catalogIsKnown = value.catalogIsKnown
        contextGeneration = UUID()
        invalidate(clearInspection: true)
        rootURL = nil
    }

    func selectionTicket() -> UUID? {
        synchronizeContext()
        guard isEnabled, !isBusy, !isDemoEnabled else { return nil }
        return revision
    }

    func selectRoot(_ url: URL, ticket: UUID) {
        synchronizeContext()
        guard isEnabled, !isBusy, !isDemoEnabled, revision == ticket, url.isFileURL else { return }
        invalidate(clearInspection: true)
        contextGeneration = UUID()
        rootURL = url
    }

    func select(paths: Set<String>) {
        synchronizeContext()
        guard !isBusy, !isDemoEnabled, let inspection, inspection.context == context else { return }
        let allowed = Set(inspection.candidates.filter(\.isEligible).map(\.id))
        let proposed = paths.intersection(allowed)
        guard selectedPaths != proposed else { return }
        invalidate(clearInspection: false)
        selectedPaths = proposed
    }

    func inspect() {
        synchronizeContext()
        guard canInspect, let executor, let rootURL else { return }
        invalidate(clearInspection: true)
        let expected = revision, scope = context, priorDiscard = discardTask, request = begin()
        task = Task { [weak self, executor] in
            do {
                await priorDiscard?.value
                try Task.checkCancellation()
                let result = try await executor.inspect(root: rootURL, context: scope) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self else { return }; self.synchronizeContext()
                        guard self.activeRequest == request, self.revision == expected,
                              self.context == scope, !self.isDemoEnabled, !self.isCancelling else { return }
                        self.scanProgress = value
                    }
                }
                try Task.checkCancellation()
                guard let self else { return }
                self.synchronizeContext()
                guard self.revision == expected, self.context == scope, !self.isDemoEnabled,
                      self.rootURL == rootURL, result.rootURL == rootURL, result.context == scope else {
                    self.finish(request); return
                }
                self.inspection = result
                self.finish(request)
            } catch { self?.fail(error, request: request, expected: expected) }
        }
    }

    func prepare() {
        synchronizeContext()
        guard canPrepare, let executor, let inspection else { return }
        invalidate(clearInspection: false)
        let expected = revision, scope = context, selected = selectedPaths, priorDiscard = discardTask, request = begin()
        task = Task { [weak self, executor] in
            do {
                await priorDiscard?.value
                try Task.checkCancellation()
                let result = try await executor.prepare(inspectionID: inspection.id, selectedPaths: selected, context: scope)
                try Task.checkCancellation()
                guard let self else { await executor.discardPlans(); return }
                self.synchronizeContext()
                let exactPaths = result.targets.map { $0.originalURL.path }
                guard self.revision == expected, !self.isDemoEnabled, self.context == scope,
                      self.inspection?.id == inspection.id, self.selectedPaths == selected,
                      result.context == scope, result.inspectionID == inspection.id, result.rootURL == inspection.rootURL,
                      Set(exactPaths) == selected, exactPaths.count == selected.count, result.expiresAt > self.now() else {
                    await executor.discardPlans(); self.finish(request); return
                }
                self.plan = result
                self.finish(request)
            } catch {
                await executor.discardPlans()
                self?.fail(error, request: request, expected: expected)
            }
        }
    }

    func attestWorkloadsStopped(_ value: Bool, planID: UUID) {
        synchronizeContext()
        guard !isBusy, plan?.id == planID else { return }
        workloadsStopped = value
    }
    func attestContentRegenerable(_ value: Bool, planID: UUID) {
        synchronizeContext()
        guard !isBusy, plan?.id == planID else { return }
        contentRegenerable = value
    }
    func canConfirm(planID: UUID) -> Bool {
        guard currentWorkspaceMatches, isEnabled, !isBusy, !isDemoEnabled, workloadsStopped, contentRegenerable,
              let plan, plan.id == planID, plan.expiresAt > now(), plan.context == context,
              plan.inspectionID == inspection?.id, Set(plan.targets.map { $0.originalURL.path }) == selectedPaths else { return false }
        return true
    }
    func confirm(planID: UUID) {
        synchronizeContext()
        guard let plan, plan.id == planID, !isBusy else { return }
        guard plan.expiresAt > now() else { expire(); return }
        guard canConfirm(planID: planID), let executor else { return }
        let scope = context, expected = revision, request = begin()
        self.plan = nil; workloadsStopped = false; contentRegenerable = false; errorMessage = nil
        task = Task { [weak self, executor] in
            do {
                try Task.checkCancellation()
                self?.synchronizeContext()
                guard let self, self.revision == expected, self.context == scope, !self.isDemoEnabled else { throw CancellationError() }
                let outcome = try await executor.moveToTrash(planID: planID, context: scope)
                // An actual namespace change can outlive cancellation. Preserve
                // its result, including uncertain and partial item receipts.
                self.record(outcome)
            } catch { self?.lastMutationError = Self.message(error) }
            self?.invalidate(clearInspection: true)
            self?.onMutationOutcome?()
            self?.finish(request)
        }
    }

    func loadRecovery() {
        synchronizeContext()
        guard canReadRecovery, let executor else { return }
        invalidate(clearInspection: false)
        let expected = revision, priorDiscard = discardTask, request = begin()
        task = Task { [weak self, executor] in
            do {
                await priorDiscard?.value
                try Task.checkCancellation()
                let result = try await executor.recoveryRecords()
                try Task.checkCancellation()
                guard let self else { return }
                self.synchronizeContext()
                if self.revision == expected, !self.isDemoEnabled {
                    let ids = Set(result.map(\.id))
                    for index in self.recoveryItems.indices where !ids.contains(self.recoveryItems[index].id) {
                        let previous = self.recoveryItems[index]
                        self.recoveryItems[index] = CleanupRecoveryItem(id: previous.id, operationURL: previous.operationURL, receipt: nil,
                            issue: String(localized: "Recovery record unavailable; outcome unknown"))
                    }
                    for item in result { self.merge(item) }
                    self.hasReadRecovery = true
                }
                self.finish(request)
            } catch { self?.fail(error, request: request, expected: expected) }
        }
    }

    func prepareRecovery(receiptID: UUID, action: CleanupRecoveryPlan.Action) {
        synchronizeContext()
        guard canReadRecovery, catalogIsKnown, let executor,
              let receipt = receipts.first(where: { $0.id == receiptID }),
              action == .restore ? receipt.canRestore : receipt.canDeletePermanently else { return }
        invalidate(clearInspection: false)
        let expected = revision, scope = context, priorDiscard = discardTask, request = begin()
        task = Task { [weak self, executor] in
            do {
                await priorDiscard?.value
                try Task.checkCancellation()
                let result = try await executor.prepareRecovery(receiptID: receiptID, action: action, context: scope)
                try Task.checkCancellation()
                guard let self else { await executor.discardPlans(); return }
                self.synchronizeContext()
                guard self.revision == expected, !self.isDemoEnabled, self.context == scope,
                      result.receipt.id == receiptID, result.action == action, result.context == scope,
                      result.expiresAt > self.now() else {
                    await executor.discardPlans(); self.finish(request); return
                }
                self.recoveryPlan = result
                self.finish(request)
            } catch {
                await executor.discardPlans()
                self?.fail(error, request: request, expected: expected)
            }
        }
    }
    func attestIrreversibleDeletion(_ value: Bool, planID: UUID) {
        synchronizeContext()
        guard !isBusy, recoveryPlan?.id == planID, recoveryPlan?.action == .deletePermanently else { return }
        irreversibleDeletionAccepted = value
    }
    func canConfirmRecovery(planID: UUID) -> Bool {
        guard currentWorkspaceMatches, isEnabled, !isBusy, !isDemoEnabled, catalogIsKnown,
              let recoveryPlan, recoveryPlan.id == planID, recoveryPlan.context == context,
              recoveryPlan.expiresAt > now() else { return false }
        return recoveryPlan.action == .restore || irreversibleDeletionAccepted
    }
    func confirmRecovery(planID: UUID) {
        synchronizeContext()
        guard let recoveryPlan, recoveryPlan.id == planID, !isBusy else { return }
        guard recoveryPlan.expiresAt > now() else { expire(); return }
        guard canConfirmRecovery(planID: planID), let executor else { return }
        let scope = context, expected = revision, request = begin()
        self.recoveryPlan = nil; irreversibleDeletionAccepted = false; errorMessage = nil
        task = Task { [weak self, executor] in
            do {
                try Task.checkCancellation()
                self?.synchronizeContext()
                guard let self, self.revision == expected, self.context == scope, !self.isDemoEnabled else { throw CancellationError() }
                let outcome = try await executor.applyRecovery(planID: planID, context: scope)
                self.record(outcome)
            } catch { self?.lastMutationError = Self.message(error) }
            self?.invalidate(clearInspection: true)
            self?.onMutationOutcome?()
            self?.finish(request)
        }
    }

    func cancel() { invalidate(clearInspection: false) }

    private var currentWorkspaceMatches: Bool { contextProvider.map { $0() == workspaceContext } ?? true }
    private var context: CleanupContext {
        CleanupContext(generation: contextGeneration, protectedPaths: workspaceContext?.protectedPaths ?? [], catalogIsKnown: catalogIsKnown)
    }
    private func synchronizeContext() { if let contextProvider { updateContext(contextProvider()) } }
    private func invalidate(clearInspection: Bool) {
        scanProgress = nil
        revision = UUID(); plan = nil; recoveryPlan = nil
        workloadsStopped = false; contentRegenerable = false; irreversibleDeletionAccepted = false; errorMessage = nil
        if clearInspection { inspection = nil; selectedPaths = [] }
        if task != nil { task?.cancel(); isCancelling = true }
        if let executor {
            let previous = discardTask
            discardTask = Task { await previous?.value; await executor.discardPlans() }
        }
    }
    private func expire() { invalidate(clearInspection: false); errorMessage = CleanupFailure.expired.errorDescription }
    private func begin() -> UUID {
        let id = UUID(); activeRequest = id; isBusy = true; isCancelling = false; scanProgress = nil
        return id
    }
    private func finish(_ id: UUID) {
        guard activeRequest == id else { return }
        task = nil; activeRequest = nil; isBusy = false; isCancelling = false; scanProgress = nil
    }
    private func fail(_ error: any Error, request: UUID, expected: UUID) {
        synchronizeContext()
        if revision == expected, !isDemoEnabled { errorMessage = Self.message(error) }
        finish(request)
    }
    private func record(_ outcome: CleanupOutcome) {
        lastOutcome = outcome; lastMutationError = nil
        for item in outcome.items {
            if let receipt = item.receipt {
                merge(CleanupRecoveryItem(id: receipt.id, operationURL: receipt.operationURL, receipt: receipt, issue: nil))
            }
        }
    }
    private func merge(_ item: CleanupRecoveryItem) {
        if let index = recoveryItems.firstIndex(where: { $0.id == item.id }) { recoveryItems[index] = item }
        else { recoveryItems.append(item) }
        recoveryItems.sort { $0.operationURL.path < $1.operationURL.path }
    }
    private static func message(_ error: any Error) -> String {
        if error is CancellationError { return String(localized: "Cleanup was cancelled. Review any actual outcomes before trying again.") }
        return (error as? CleanupFailure)?.errorDescription
            ?? String(localized: "Cleanup could not be verified. Read recovery records before retrying; no automatic retry will occur.")
    }
}
