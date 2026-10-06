import Foundation
import Testing
@testable import MoeKit

/// In-memory gates exercise cancellation before and after an executor's commit
/// boundary. These fixtures never inspect or mutate a real repository.
private actor FinishStoreGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func pause() async { await withCheckedContinuation { continuation = $0 } }
    func resume() {
        let waiting = continuation; continuation = nil; waiting?.resume()
    }
}

private actor FinishStoreExecutor: GitWorktreeFinishExecuting {
    private let prepareGate: FinishStoreGate?
    private let mergeGate: FinishStoreGate?
    private let pauseBeforeMerge: Bool
    private let blockers: [String]
    private let uniqueCommitCount: Int
    private let preparedAt: Date?
    private var plans: [UUID: GitWorktreeFinishPlan] = [:]
    private var mergeFailure: GitCleanupFailure?
    private(set) var requests: [GitWorktreeFinishRequest] = []
    private(set) var merged: [UUID] = []
    private(set) var pendingPermit: GitCleanupPermit?

    init(prepareGate: FinishStoreGate? = nil, mergeGate: FinishStoreGate? = nil,
         pauseBeforeMerge: Bool = false, blockers: [String] = [], uniqueCommitCount: Int = 2,
         preparedAt: Date? = nil) {
        self.prepareGate = prepareGate; self.mergeGate = mergeGate
        self.pauseBeforeMerge = pauseBeforeMerge; self.blockers = blockers
        self.uniqueCommitCount = uniqueCommitCount; self.preparedAt = preparedAt
    }

    func failMerge() { mergeFailure = .partial("/Synthetic/recovery/owned-operation") }

    func prepare(_ request: GitWorktreeFinishRequest) async -> GitWorktreeFinishPlan {
        requests.append(request)
        let status = GitFinishStatus(stagedChanges: false, modifiedCount: 0,
            untrackedOrIgnoredCount: 0, extraDirectoryCount: 0)
        let value = GitWorktreeFinishPlan(id: UUID(), request: request, sourceBranch: "feature",
            sourceOID: String(repeating: "a", count: 40), targetOID: String(repeating: "b", count: 40),
            targetWorktree: URL(fileURLWithPath: "/Synthetic/main"), sourceStatus: status, targetStatus: status,
            uniqueCommitCount: uniqueCommitCount, blockers: blockers,
            recovery: URL(fileURLWithPath: "/Synthetic/recovery/owned-operation"),
            fingerprint: "in-memory fixture", preparedAt: preparedAt ?? Date(),
            gitVersion: "git version 2.39.5 (Apple Git-154)")
        plans[value.id] = value
        await prepareGate?.pause()
        return value
    }

    func merge(_ id: UUID, permit: GitCleanupPermit) async throws -> GitWorktreeFinishResult {
        guard let plan = plans.removeValue(forKey: id) else { throw GitCleanupFailure.expired }
        pendingPermit = permit
        if pauseBeforeMerge { await mergeGate?.pause() }
        try Task.checkCancellation(); try permit.consume()
        merged.append(id)
        if !pauseBeforeMerge { await mergeGate?.pause() }
        if let mergeFailure { throw mergeFailure }
        return GitWorktreeFinishResult(id: id, plan: plan, verifiedOID: plan.sourceOID, recovery: plan.recovery)
    }
}

@MainActor @Suite("AI worktree finish confirmation and context isolation")
struct GitWorktreeFinishStoreTests {
    private var request: GitWorktreeFinishRequest {
        .init(scope: URL(fileURLWithPath: "/Synthetic"),
            project: ProjectRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!, name: "Owned source", path: "/Synthetic/feature", kind: .worktree, branch: "feature"),
            targetBranch: "main")
    }

    private func settle(_ store: GitWorktreeFinishStore) async throws {
        for _ in 0..<10_000 {
            if !store.isBusy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("In-memory finish store did not settle")
        throw GitCleanupFailure.expired
    }

    private func wait(_ gate: FinishStoreGate) async throws {
        for _ in 0..<10_000 {
            if await gate.isWaiting { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("In-memory finish executor did not reach its controlled boundary")
        throw GitCleanupFailure.expired
    }

    @Test("Initialization performs no inspection or merge")
    func idle() async {
        let executor = FinishStoreExecutor(), store = GitWorktreeFinishStore(executor: executor)
        #expect(store.plan == nil && store.result == nil && !store.isBusy && !store.isMutating)
        #expect(store.lastOperationResult == nil && !store.blocksAppUpdate)
        #expect(await executor.requests.isEmpty)
        #expect(await executor.merged.isEmpty)
    }

    @Test("Exact target text and closed-tools attestation are enforced in the store")
    func confirmation() async throws {
        let executor = FinishStoreExecutor(), store = GitWorktreeFinishStore(executor: executor)
        store.inspect(request); try await settle(store)
        let plan = try #require(store.plan)
        for (branch, stopped) in [("feature", true), ("main ", true), ("Main", true), ("main", false)] {
            #expect(!store.canConfirm(planID: plan.id, targetBranch: branch, stoppedTools: stopped))
            store.confirm(planID: plan.id, targetBranch: branch, stoppedTools: stopped)
        }
        store.confirm(targetBranch: "main", stoppedTools: true)
        store.confirm(planID: UUID(), targetBranch: "main", stoppedTools: true)
        #expect(await executor.merged.isEmpty)
        #expect(store.plan?.id == plan.id)
        store.confirm(planID: plan.id, targetBranch: "main", stoppedTools: true)
        store.confirm(planID: plan.id, targetBranch: "main", stoppedTools: true)
        try await settle(store)
        #expect(await executor.merged == [plan.id])
        #expect(store.plan == nil && store.result?.verifiedOID == plan.sourceOID)
        #expect(store.lastOperationResult?.id == plan.id)
        store.confirm(planID: plan.id, targetBranch: "main", stoppedTools: true)
        #expect(await executor.merged == [plan.id])
    }

    @Test("An old displayed plan cannot approve a new plan for the same target")
    func stalePlan() async throws {
        let executor = FinishStoreExecutor(), store = GitWorktreeFinishStore(executor: executor)
        store.inspect(request); try await settle(store)
        let old = try #require(store.plan)
        store.inspect(request); try await settle(store)
        let current = try #require(store.plan)
        #expect(old.id != current.id)
        store.confirm(planID: old.id, targetBranch: "main", stoppedTools: true)
        #expect(await executor.merged.isEmpty)
        #expect(store.plan?.id == current.id)
    }

    @Test("Blockers and already-contained source commits cannot authorize a merge")
    func blockedPlans() async throws {
        for executor in [FinishStoreExecutor(blockers: ["Target is dirty"]), FinishStoreExecutor(uniqueCommitCount: 0)] {
            let store = GitWorktreeFinishStore(executor: executor)
            store.inspect(request); try await settle(store)
            let plan = try #require(store.plan)
            #expect(!plan.canMerge)
            store.confirm(planID: plan.id, targetBranch: "main", stoppedTools: true)
            #expect(await executor.merged.isEmpty)
        }
    }

    @Test("Expired displayed plans require a new inspection")
    func expiredPlan() async throws {
        let executor = FinishStoreExecutor(preparedAt: Date().addingTimeInterval(-121))
        let store = GitWorktreeFinishStore(executor: executor)
        store.inspect(request); try await settle(store)
        let plan = try #require(store.plan)
        #expect(!store.canConfirm(planID: plan.id, targetBranch: "main", stoppedTools: true))
        store.confirm(planID: plan.id, targetBranch: "main", stoppedTools: true)
        #expect(await executor.merged.isEmpty)
    }

    @Test("Demo rejects inspection and discards previously displayed authority")
    func demoMode() async throws {
        let executor = FinishStoreExecutor(), store = GitWorktreeFinishStore(executor: executor)
        store.setDemoEnabled(true); store.inspect(request)
        #expect(await executor.requests.isEmpty)
        store.setDemoEnabled(false); store.inspect(request); try await settle(store)
        let plan = try #require(store.plan)
        store.setDemoEnabled(true)
        store.confirm(planID: plan.id, targetBranch: "main", stoppedTools: true)
        #expect(store.plan == nil && store.result == nil && !store.isBusy)
        #expect(await executor.merged.isEmpty)
    }

    @Test("An obsolete inspection cannot cross a context or Demo boundary", arguments: [false, true])
    func obsoleteInspection(demo: Bool) async throws {
        let gate = FinishStoreGate(), executor = FinishStoreExecutor(prepareGate: gate)
        let store = GitWorktreeFinishStore(executor: executor)
        store.inspect(request); try await wait(gate)
        if demo { store.setDemoEnabled(true) } else { store.invalidate() }
        await gate.resume()
        // A canceled producer may finish later. Give that producer a turn and
        // verify it cannot repopulate any visible authority or record.
        for _ in 0..<20 { await Task.yield() }
        #expect(store.plan == nil && store.result == nil && store.error == nil && !store.isBusy)
        #expect(store.lastOperationResult == nil)
        #expect(await executor.merged.isEmpty)
    }

    @Test("Invalidation before mutation revokes one-use authority")
    func cancelBeforeMutation() async throws {
        let gate = FinishStoreGate(), executor = FinishStoreExecutor(mergeGate: gate, pauseBeforeMerge: true)
        let store = GitWorktreeFinishStore(executor: executor)
        store.inspect(request); try await settle(store)
        let plan = try #require(store.plan)
        store.confirm(planID: plan.id, targetBranch: "main", stoppedTools: true)
        try await wait(gate)
        #expect(store.blocksAppUpdate)
        let permit = try #require(await executor.pendingPermit)
        store.invalidate()
        #expect(store.isBusy && store.isMutating)
        #expect(throws: GitCleanupFailure.expired) { try permit.consume() }
        store.inspect(request)
        #expect(await executor.requests.count == 1)
        await gate.resume(); try await settle(store)
        #expect(await executor.merged.isEmpty)
        #expect(store.plan == nil && store.result == nil && store.error == nil)
        #expect(!store.blocksAppUpdate && !store.isMutating)
    }

    @Test("A completed mutation after invalidation retains recovery evidence without a fresh-result grant", arguments: [false, true])
    func completedAfterInvalidation(demo: Bool) async throws {
        let gate = FinishStoreGate(), executor = FinishStoreExecutor(mergeGate: gate)
        let store = GitWorktreeFinishStore(executor: executor)
        store.inspect(request); try await settle(store)
        let plan = try #require(store.plan)
        store.confirm(planID: plan.id, targetBranch: "main", stoppedTools: true)
        try await wait(gate)
        if demo { store.setDemoEnabled(true) } else { store.invalidate() }
        #expect(store.isBusy && store.isMutating && store.blocksAppUpdate)
        await gate.resume(); try await settle(store)
        #expect(await executor.merged == [plan.id])
        #expect(store.plan == nil && store.result == nil && store.error == nil)
        #expect(store.lastOperationResult?.recovery == plan.recovery)
        #expect(store.lastOperationRequest == request)
        #expect(!store.blocksAppUpdate)
        store.setDemoEnabled(false)
        #expect(store.result == nil && store.lastOperationResult?.id == plan.id)
    }

    @Test("A failed or partial merge never reports verified success, including after Demo invalidation", arguments: [false, true])
    func failedMerge(demo: Bool) async throws {
        let gate = FinishStoreGate(), executor = FinishStoreExecutor(mergeGate: gate)
        let store = GitWorktreeFinishStore(executor: executor)
        store.inspect(request); try await settle(store)
        let plan = try #require(store.plan)
        store.confirm(planID: plan.id, targetBranch: "main", stoppedTools: true)
        try await wait(gate); await executor.failMerge()
        if demo { store.setDemoEnabled(true) }
        await gate.resume(); try await settle(store)
        #expect(store.result == nil && store.lastOperationResult == nil)
        #expect(store.lastOperationError?.contains("/Synthetic/recovery/owned-operation") == true)
        #expect((store.error == nil) == demo)
        #expect(store.plan == nil && !store.isBusy && !store.isMutating)
    }
}
