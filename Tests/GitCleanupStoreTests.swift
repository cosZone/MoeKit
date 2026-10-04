import Foundation
import Testing
@testable import MoeKit

private actor GitStoreFixtureExecutor: GitCleanupExecuting {
    private var prepared: GitCleanupPlan?
    private var receipt: GitCleanupReceipt?
    private(set) var executed: [UUID] = []
    private(set) var restored: [UUID] = []
    func prepare(_ request: GitCleanupRequest) -> GitCleanupPlan {
        let plan = GitCleanupPlan(id: UUID(), request: request, commonDirectory: URL(fileURLWithPath: "/Synthetic/main/.git"),
            registration: nil, recovery: URL(fileURLWithPath: "/Synthetic/recovery"), targetOID: String(repeating: "a", count: 40),
            baseOID: String(repeating: "b", count: 40), fingerprint: "owned test display", preparedAt: Date(), bytes: 1,
            gitVersion: "git version 2.39.5 (Apple Git-154)")
        prepared = plan; return plan
    }
    func execute(_ id: UUID, permit: GitCleanupPermit) throws -> GitCleanupReceipt {
        guard let plan = prepared, plan.id == id else { throw GitCleanupFailure.expired }
        try permit.consume(); prepared = nil; executed.append(id)
        let identity = InstallerFileSnapshot(device: 1, inode: 1, mode: 0, uid: 1, gid: 1, links: 1, flags: 0, bytes: 1,
            modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
        let value = GitCleanupReceipt(id: id, plan: plan, recoveryIdentity: identity, payloadIdentity: identity,
            registrationIdentity: nil, commonIdentity: identity, scopeIdentity: identity,
            destinationParentIdentity: identity, registrationParentIdentity: nil)
        receipt = value; return value
    }
    func restore(_ id: UUID, permit: GitCleanupPermit) throws {
        guard receipt?.id == id else { throw GitCleanupFailure.expired }
        try permit.consume(); receipt = nil; restored.append(id)
    }
}

@MainActor @Suite("Git cleanup displayed confirmation identity")
struct GitCleanupStoreTests {
    private var request: GitCleanupRequest {
        .init(scope: URL(fileURLWithPath: "/Synthetic"), project: ProjectRecord(name: "Owned synthetic", path: "/Synthetic/main", kind: .repository),
            baseBranch: "main", branch: "feature", action: .deleteBranch)
    }
    private func wait(_ store: GitCleanupStore) async throws {
        for _ in 0..<10_000 {
            if !store.isBusy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Synthetic store did not finish its in-memory operation")
        throw GitCleanupFailure.expired
    }
    @Test("An old displayed plan cannot approve a newer plan with the same branch text")
    func staleDisplay() async throws {
        let executor = GitStoreFixtureExecutor(), store = GitCleanupStore(executor: executor)
        store.inspect(request); try await wait(store)
        let old = try #require(store.plan)
        store.inspect(request); try await wait(store)
        let current = try #require(store.plan)
        #expect(old.id != current.id)
        store.confirm(planID: old.id)
        store.confirm()
        #expect(await executor.executed.isEmpty)
        #expect(store.plan?.id == current.id && !store.isBusy)
        store.confirm(planID: current.id); try await wait(store)
        #expect(await executor.executed == [current.id])
        store.confirm(planID: current.id)
        #expect(await executor.executed == [current.id])
    }
    @Test("Restore confirmation is bound to the displayed receipt, not a later operation")
    func staleRestore() async throws {
        let executor = GitStoreFixtureExecutor(), store = GitCleanupStore(executor: executor)
        store.inspect(request); try await wait(store)
        let first = try #require(store.plan)
        store.confirm(planID: first.id); try await wait(store)
        let displayed = try #require(store.receipt)
        store.inspect(request); try await wait(store)
        let second = try #require(store.plan)
        store.confirm(planID: second.id); try await wait(store)
        store.restore(receiptID: displayed.id)
        store.restore()
        #expect(await executor.restored.isEmpty)
        #expect(store.receipt?.id == second.id)
        store.restore(receiptID: second.id); try await wait(store)
        #expect(await executor.restored == [second.id])
        #expect(store.receipt == nil)
    }
    @Test("Closing or changing context discards displayed confirmation authority")
    func invalidation() async throws {
        let executor = GitStoreFixtureExecutor(), store = GitCleanupStore(executor: executor)
        store.inspect(request); try await wait(store)
        let plan = try #require(store.plan)
        store.invalidate(); store.confirm(planID: plan.id)
        #expect(await executor.executed.isEmpty)
        #expect(store.plan == nil && !store.isBusy)
    }
}
