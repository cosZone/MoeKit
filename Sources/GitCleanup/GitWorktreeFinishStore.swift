import Foundation
import Observation

/// Coordinates the reviewed local integration step. An AI completion label is
/// never an input, and merge authority never authorizes worktree retirement.
@MainActor @Observable
final class GitWorktreeFinishStore {
    let remotePush: GitRemotePushStore
    private(set) var plan: GitWorktreeFinishPlan?
    private(set) var result: GitWorktreeFinishResult?
    // Session-only records remain available after a context change. They are
    // informational recovery evidence, never a plan or retirement authority.
    private(set) var lastOperationRequest: GitWorktreeFinishRequest?
    private(set) var lastOperationResult: GitWorktreeFinishResult?
    private(set) var lastOperationError: String?
    private(set) var isBusy = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
    private(set) var isMutating = false
    private(set) var error: String?
    private(set) var isDemoEnabled = false
    @ObservationIgnored private let executor: any GitWorktreeFinishExecuting
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var permit: GitCleanupPermit?

    init(executor: any GitWorktreeFinishExecuting = NativeGitWorktreeFinishExecutor(), remotePush: GitRemotePushStore? = nil) {
        self.executor = executor
        self.remotePush = remotePush ?? GitRemotePushStore()
    }

    func setDemoEnabled(_ enabled: Bool) {
        guard isDemoEnabled != enabled else { return }
        isDemoEnabled = enabled
        remotePush.setDemoEnabled(enabled)
        invalidate()
    }

    /// A new context discards all displayed authority and results. A native
    /// mutation already past its commit boundary remains busy until it returns.
    func invalidate() {
        generation = UUID()
        remotePush.invalidate()
        task?.cancel(); task = nil
        permit?.invalidate(); permit = nil
        plan = nil; result = nil; error = nil
        if !isMutating { isBusy = false }
    }

    func inspect(_ request: GitWorktreeFinishRequest) {
        guard !isDemoEnabled, !isMutating, !remotePush.isBusy else { return }
        invalidate()
        isBusy = true
        let current = generation
        task = Task {
            do {
                let value = try await executor.prepare(request)
                guard generation == current, !Task.isCancelled, !isDemoEnabled else { return }
                guard value.request == request else { throw GitCleanupFailure.changed }
                plan = value
            } catch {
                guard generation == current, !Task.isCancelled, !isDemoEnabled else { return }
                self.error = error.localizedDescription
            }
            if generation == current { isBusy = false; task = nil }
        }
    }

    func canConfirm(planID: UUID?, targetBranch: String, stoppedTools: Bool) -> Bool {
        guard !isDemoEnabled, !isBusy, !remotePush.isBusy, let plan, plan.id == planID,
              plan.canMerge, stoppedTools, targetBranch == plan.request.targetBranch else { return false }
        // This is a display safeguard only. The native executor enforces its
        // own monotonic expiry and one-use confirmation at the mutation boundary.
        let age = Date().timeIntervalSince(plan.preparedAt)
        return age >= 0 && age < 120
    }

    func confirm(planID: UUID? = nil, targetBranch: String, stoppedTools: Bool) {
        guard canConfirm(planID: planID, targetBranch: targetBranch, stoppedTools: stoppedTools), let plan else { return }
        let current = generation, permit = GitCleanupPermit()
        self.permit = permit
        self.plan = nil; result = nil; error = nil
        isMutating = true; isBusy = true
        task = Task {
            do {
                let value = try await executor.merge(plan.id, permit: permit)
                guard value.id == plan.id, value.plan == plan, value.verifiedOID == plan.sourceOID else { throw GitCleanupFailure.changed }
                // Only the native executor's verified result may report local
                // success. Never revive a dismissed or Demo-mode inspection.
                lastOperationRequest = plan.request
                lastOperationResult = value; lastOperationError = nil
                if generation == current, !isDemoEnabled { result = value }
            } catch {
                lastOperationRequest = plan.request
                lastOperationResult = nil; lastOperationError = error.localizedDescription
                if generation == current, !isDemoEnabled { self.error = error.localizedDescription }
            }
            isMutating = false; isBusy = false
            if generation == current { task = nil; self.permit = nil }
        }
    }
}

extension GitWorktreeFinishStore: AppUpdateBlocking {
    var blocksAppUpdate: Bool { isBusy }
}
