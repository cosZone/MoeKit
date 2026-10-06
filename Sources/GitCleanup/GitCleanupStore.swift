import Foundation
import Observation

@MainActor @Observable
final class GitCleanupStore {
    private(set) var plan: GitCleanupPlan?
    private(set) var receipt: GitCleanupReceipt?
    private(set) var isBusy = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
    private(set) var isMutating = false
    private(set) var error: String?
    private(set) var outcome: String?
    @ObservationIgnored private let executor: any GitCleanupExecuting
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var permit: GitCleanupPermit?
    @ObservationIgnored var onMutation: (@MainActor (GitCleanupPlan, Bool) -> Void)?
    init(executor: any GitCleanupExecuting = NativeGitCleanupExecutor()) { self.executor = executor }
    func invalidate() {
        generation = UUID(); task?.cancel(); task = nil; permit?.invalidate(); permit = nil
        plan = nil
        if !isMutating { isBusy = false }
    }
    func inspect(_ request: GitCleanupRequest) {
        guard !isMutating else { return }
        invalidate(); error = nil; outcome = nil; receipt = nil; isBusy = true
        let current = generation
        task = Task {
            do {
                let value = try await executor.prepare(request)
                guard generation == current, !Task.isCancelled else { return }
                plan = value
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if generation == current { isBusy = false; task = nil }
        }
    }
    func confirm(planID: UUID? = nil) {
        guard !isBusy, let plan, plan.id == planID else { return }
        let current = generation, permit = GitCleanupPermit()
        self.permit = permit; self.plan = nil; error = nil; isBusy = true; isMutating = true
        task = Task {
            do {
                let result = try await executor.execute(plan.id, permit: permit)
                await completeMutation(plan, receipt: result)
            } catch { self.error = error.localizedDescription }
            isMutating = false; isBusy = false
            if generation == current { task = nil; self.permit = nil }
        }
    }
    func restore(receiptID: UUID? = nil) {
        guard !isBusy, let receipt, receipt.id == receiptID else { return }
        let current = generation, permit = GitCleanupPermit()
        self.permit = permit; error = nil; isBusy = true; isMutating = true
        task = Task {
            do {
                try await executor.restore(receipt.id, permit: permit)
                await completeMutation(receipt.plan, receipt: nil)
            } catch { self.error = error.localizedDescription }
            isMutating = false; isBusy = false
            if generation == current { task = nil; self.permit = nil }
        }
    }

    private func completeMutation(_ plan: GitCleanupPlan, receipt: GitCleanupReceipt?) async {
        // This unstructured MainActor task does not inherit cancellation. Only a
        // confirmed final executor result reaches it; it grants no new mutation
        // authority. A completed move still needs catalog bookkeeping when its
        // original task was cancelled after mutation started.
        await Task { @MainActor in
            // Updating the catalog invalidates cleanup context. Detach the old
            // operation first so that callback cannot cancel its own persistence.
            task = nil; permit = nil
            self.receipt = receipt
            if receipt == nil {
                outcome = "Restored to the original location without overwriting an existing target."
            } else {
                outcome = plan.request.action == .retireWorktree
                    ? "Worktree retired. Its branch and all files are retained in the recovery folder. Disk space has not been reclaimed."
                    : "Local branch removed. Its previous ref is retained for restore; no remote branch was changed."
            }
            onMutation?(plan, receipt == nil)
        }.value
    }
}
