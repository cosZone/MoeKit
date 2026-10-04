import Foundation
import Observation

@MainActor @Observable
final class GitCleanupStore {
    private(set) var plan: GitCleanupPlan?
    private(set) var receipt: GitCleanupReceipt?
    private(set) var isBusy = false
    private(set) var isMutating = false
    private(set) var error: String?
    private(set) var outcome: String?
    @ObservationIgnored private let executor: NativeGitCleanupExecutor
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var permit: GitCleanupPermit?
    @ObservationIgnored var onMutation: (@MainActor (GitCleanupPlan, Bool) -> Void)?
    init(executor: NativeGitCleanupExecutor = .init()) { self.executor = executor }
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
    func confirm() {
        guard !isBusy, let plan else { return }
        let current = generation, permit = GitCleanupPermit()
        self.permit = permit; self.plan = nil; error = nil; isBusy = true; isMutating = true
        task = Task {
            do {
                let result = try await executor.execute(plan.id, permit: permit)
                // An operation already past its first rename finishes safely even
                // if navigation changes. Preserve its result without reviving a plan.
                receipt = result
                outcome = plan.request.action == .retireWorktree
                    ? "Worktree retired. Its branch and all files are retained in the recovery folder. Disk space has not been reclaimed."
                    : "Local branch removed. Its previous ref is retained for restore; no remote branch was changed."
                onMutation?(plan, false)
            } catch { self.error = error.localizedDescription }
            isMutating = false; isBusy = false
            if generation == current { task = nil; self.permit = nil }
        }
    }
    func restore() {
        guard !isBusy, let receipt else { return }
        let current = generation, permit = GitCleanupPermit()
        self.permit = permit; error = nil; isBusy = true; isMutating = true
        task = Task {
            do {
                try await executor.restore(receipt.id, permit: permit)
                self.receipt = nil; outcome = "Restored to the original location without overwriting an existing target."
                onMutation?(receipt.plan, true)
            } catch { self.error = error.localizedDescription }
            isMutating = false; isBusy = false
            if generation == current { task = nil; self.permit = nil }
        }
    }
}
