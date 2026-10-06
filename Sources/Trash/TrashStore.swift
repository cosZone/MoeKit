import Foundation
import Observation

struct TrashWorkspaceContext: Equatable {
    let isDemoEnabled: Bool
    let modeGeneration: UUID
}

@MainActor @Observable
final class TrashStore {
    private(set) var inspection: TrashInspection?
    private(set) var selectedPaths: Set<String> = []
    private(set) var plan: TrashRemovalPlan?
    private(set) var irreversibleAccepted = false
    private(set) var workloadsStopped = false
    private(set) var typedConfirmation = ""
    private(set) var isDemoEnabled = false
    private(set) var isBusy = false { didSet { UpdateInstallationSafety.shared.changed(self) } }
    private(set) var isCancelling = false
    private(set) var errorMessage: String?
    private(set) var lastMutationError: String?
    private(set) var lastOutcome: TrashOutcome?
    private(set) var scanProgress: DirectoryScanProgress?
    private(set) var progress: TrashProgress?
    private(set) var recoveryItems: [TrashRecoveryItem] = []
    private(set) var hasReadRecords = false
    let isEnabled: Bool
    @ObservationIgnored var onMutationOutcome: (@MainActor () -> Void)?
    @ObservationIgnored private let executor: (any TrashExecuting)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var workspaceContext: TrashWorkspaceContext?
    @ObservationIgnored private var contextProvider: (@MainActor () -> TrashWorkspaceContext)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var discardTask: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    /// Construction never reads Trash, recovery records, or the filesystem.
    init(executor: (any TrashExecuting)? = NativeTrashExecutor(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.executor = executor; self.now = now; isEnabled = executor != nil
    }
    var items: [TrashItem] { inspection?.items ?? [] }
    var canInspect: Bool { isEnabled && !isBusy && !isDemoEnabled }
    var canPrepare: Bool { canInspect && inspection != nil && !selectedPaths.isEmpty }
    var canClear: Bool { canInspect && inspection?.canClearSnapshot == true }
    var canReadRecords: Bool { canInspect }
    var context: TrashContext { .init(generation: generation) }

    func bindContext(_ provider: @escaping @MainActor () -> TrashWorkspaceContext) {
        contextProvider = provider; synchronize()
    }
    func updateContext(_ value: TrashWorkspaceContext) {
        guard workspaceContext != value else { return }
        workspaceContext = value; isDemoEnabled = value.isDemoEnabled; generation = UUID()
        invalidate(clearInspection: true)
    }
    func select(paths: Set<String>) {
        synchronize()
        guard canInspect, let inspection, inspection.context == context else { return }
        let proposed = paths.intersection(Set(items.filter(\.isEligible).map(\.id)))
        guard selectedPaths != proposed else { return }
        invalidate(clearInspection: false); selectedPaths = proposed
    }
    func inspect() {
        synchronize()
        guard canInspect, let executor else { return }
        invalidate(clearInspection: true)
        let expected = revision, scope = context, prior = discardTask, request = begin()
        task = Task { [weak self, executor] in
            do {
                await prior?.value; try Task.checkCancellation()
                let result = try await executor.inspect(context: scope) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self else { return }; self.synchronize()
                        guard self.requestID == request, self.revision == expected,
                              self.context == scope, !self.isDemoEnabled, !self.isCancelling else { return }
                        self.scanProgress = value
                    }
                }
                try Task.checkCancellation()
                guard let self else { return }
                self.synchronize()
                if self.revision == expected, self.context == scope, !self.isDemoEnabled, result.context == scope {
                    self.inspection = result
                }
                self.finish(request)
            } catch { self?.fail(error, request: request, expected: expected) }
        }
    }
    func prepare(action: TrashRemovalPlan.Action) {
        synchronize()
        guard action == .clearSnapshot ? canClear : canPrepare, let executor, let inspection else { return }
        invalidate(clearInspection: false)
        let paths = action == .clearSnapshot ? Set(inspection.items.map(\.id)) : selectedPaths
        let expected = revision, scope = context, prior = discardTask, request = begin()
        task = Task { [weak self, executor] in
            do {
                await prior?.value; try Task.checkCancellation()
                let result = try await executor.prepare(inspectionID: inspection.id, selectedPaths: paths, action: action, context: scope)
                try Task.checkCancellation()
                guard let self else { await executor.discardPlan(); return }
                self.synchronize()
                guard self.revision == expected, self.context == scope, !self.isDemoEnabled,
                      self.inspection?.id == inspection.id, result.inspectionID == inspection.id,
                      result.context == scope, result.rootURL == inspection.rootURL, result.action == action,
                      Set(result.items.map(\.id)) == paths, result.items.count == paths.count,
                      result.items.allSatisfy(\.isEligible), result.items.allSatisfy({ inspection.items.contains($0) }), result.expiresAt > self.now() else {
                    await executor.discardPlan(); self.finish(request); return
                }
                self.plan = result; self.finish(request)
            } catch {
                await executor.discardPlan(); self?.fail(error, request: request, expected: expected)
            }
        }
    }
    func attestIrreversible(_ value: Bool, planID: UUID) {
        synchronize(); guard !isBusy, plan?.id == planID else { return }; irreversibleAccepted = value
    }
    func attestWorkloadsStopped(_ value: Bool, planID: UUID) {
        synchronize(); guard !isBusy, plan?.id == planID else { return }; workloadsStopped = value
    }
    func typeConfirmation(_ value: String, planID: UUID) {
        synchronize(); guard !isBusy, plan?.id == planID else { return }; typedConfirmation = value
    }
    func canConfirm(planID: UUID) -> Bool {
        guard contextProvider.map({ $0() == workspaceContext }) ?? true,
              isEnabled, !isBusy, !isDemoEnabled, irreversibleAccepted, workloadsStopped,
              let plan, plan.id == planID, plan.context == context, plan.expiresAt > now(),
              plan.inspectionID == inspection?.id else { return false }
        if plan.action == .clearSnapshot {
            return typedConfirmation == TrashRemovalPlan.clearConfirmation && inspection?.canClearSnapshot == true
                && Set(plan.items.map(\.id)) == Set(items.map(\.id))
        }
        return Set(plan.items.map(\.id)) == selectedPaths
    }
    func confirm(planID: UUID) {
        synchronize()
        guard let plan, plan.id == planID, !isBusy else { return }
        guard plan.expiresAt > now() else {
            invalidate(clearInspection: false); errorMessage = TrashFailure.expired.errorDescription; return
        }
        guard canConfirm(planID: planID), let executor else { return }
        let scope = context, expected = revision, request = begin()
        self.plan = nil; irreversibleAccepted = false; workloadsStopped = false; typedConfirmation = ""
        progress = .init(finished: 0, total: plan.items.count, currentPath: nil)
        task = Task { [weak self, executor] in
            do {
                try Task.checkCancellation(); self?.synchronize()
                guard let self, self.revision == expected, self.context == scope, !self.isDemoEnabled else { throw CancellationError() }
                let result = try await executor.remove(planID: planID, context: scope) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard self?.requestID == request else { return }; self?.progress = value
                    }
                }
                // Real outcomes survive cancellation, dismissal and Demo changes.
                self.lastOutcome = result; self.lastMutationError = nil
            } catch { self?.lastMutationError = TrashFailure.message(error) }
            self?.invalidate(clearInspection: true)
            self?.onMutationOutcome?(); self?.finish(request)
        }
    }
    func readRecords() {
        synchronize(); guard canReadRecords, let executor else { return }
        invalidate(clearInspection: false)
        let expected = revision, prior = discardTask, request = begin()
        task = Task { [weak self, executor] in
            do {
                await prior?.value; try Task.checkCancellation()
                let result = try await executor.readRecords(); try Task.checkCancellation()
                guard let self else { return }; self.synchronize()
                if self.revision == expected, !self.isDemoEnabled {
                    self.recoveryItems = result; self.hasReadRecords = true
                }
                self.finish(request)
            } catch { self?.fail(error, request: request, expected: expected) }
        }
    }
    func cancel() { invalidate(clearInspection: false) }
    private func synchronize() { if let contextProvider { updateContext(contextProvider()) } }
    private func invalidate(clearInspection: Bool) {
        scanProgress = nil
        revision = UUID(); plan = nil; irreversibleAccepted = false; workloadsStopped = false; typedConfirmation = ""; errorMessage = nil
        if clearInspection { inspection = nil; selectedPaths = [] }
        if task != nil { task?.cancel(); isCancelling = true }
        if let executor {
            let prior = discardTask
            discardTask = Task { await prior?.value; await executor.discardPlan() }
        }
    }
    private func begin() -> UUID {
        let id = UUID(); requestID = id; isBusy = true; isCancelling = false; progress = nil; scanProgress = nil; return id
    }
    private func finish(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil; task = nil; isBusy = false; isCancelling = false; progress = nil; scanProgress = nil
    }
    private func fail(_ error: any Error, request: UUID, expected: UUID) {
        synchronize(); if revision == expected, !isDemoEnabled { errorMessage = TrashFailure.message(error) }; finish(request)
    }
}

extension TrashStore: AppUpdateBlocking { var blocksAppUpdate: Bool { isBusy } }
