import Foundation
import Testing
@testable import MoeKit

private actor RemoteStoreFixture: GitRemotePushExecuting {
    private(set) var inspections = 0
    private(set) var pushes = 0
    private(set) var reconciliations = 0
    private var plan: GitRemotePushPlan?
    private var outcome: GitRemotePushState = .verified
    private var delay: UInt64 = 0
    func setOutcome(_ state: GitRemotePushState) { outcome = state }
    func setDelay(_ value: UInt64) { delay = value }
    func prepare(_ request: GitRemotePushRequest, credentialPermit: GitCleanupPermit) throws -> GitRemotePushPlan {
        try credentialPermit.consume(); inspections += 1
        let result = GitRemotePushPlan(id: UUID(), request: request, host: try GitRemoteEndpoint(request.remoteURL).host,
            remoteRef: try GitRemoteEndpoint.ref(branch: request.remoteBranch), sourceOID: request.finish.verifiedOID,
            expectedRemoteOID: String(repeating: "b", count: 40), preparedAt: Date(), gitVersion: "synthetic")
        plan = result; return result
    }
    func push(_ id: UUID, permit: GitCleanupPermit) async throws -> GitRemotePushResult {
        guard let plan, plan.id == id else { throw GitRemotePushFailure.expired }
        try permit.consume(); pushes += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return makeResult(plan)
    }
    func reconcile(_ id: UUID, credentialPermit: GitCleanupPermit) throws -> GitRemotePushResult {
        guard let plan, plan.id == id else { throw GitRemotePushFailure.expired }
        try credentialPermit.consume(); reconciliations += 1
        return makeResult(plan)
    }
    private func makeResult(_ plan: GitRemotePushPlan) -> GitRemotePushResult {
        .init(plan: plan, state: outcome, observedOID: outcome == .verified ? plan.sourceOID : outcome == .notUpdated ? plan.expectedRemoteOID : nil)
    }
}

@MainActor @Suite("Remote push separate consent and outcome handling")
struct GitRemotePushStoreTests {
    private var request: GitRemotePushRequest {
        let id = UUID(), status = GitFinishStatus(stagedChanges: false, modifiedCount: 0, untrackedOrIgnoredCount: 0, extraDirectoryCount: 0)
        let local = GitWorktreeFinishRequest(scope: URL(fileURLWithPath: "/Synthetic"),
            project: .init(id: UUID(), name: "Synthetic", path: "/Synthetic/feature", kind: .worktree, branch: "feature"), targetBranch: "main")
        let plan = GitWorktreeFinishPlan(id: id, request: local, sourceBranch: "feature", sourceOID: String(repeating: "a", count: 40),
            targetOID: String(repeating: "b", count: 40), targetWorktree: URL(fileURLWithPath: "/Synthetic/main"),
            sourceStatus: status, targetStatus: status, uniqueCommitCount: 1, blockers: [],
            recovery: URL(fileURLWithPath: "/Synthetic/recovery"), fingerprint: "synthetic", preparedAt: Date(), gitVersion: "synthetic")
        return .init(finish: .init(id: id, plan: plan, verifiedOID: plan.sourceOID, recovery: plan.recovery),
            remoteURL: "https://git.example.com/owner/repository.git", remoteBranch: "integration")
    }
    private func settle(_ store: GitRemotePushStore) async throws {
        for _ in 0..<10_000 {
            if !store.isBusy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw GitRemotePushFailure.expired
    }
    @Test("No network preparation without explicit credential consent or in Demo")
    func consent() async throws {
        let executor = RemoteStoreFixture(), store = GitRemotePushStore(executor: executor)
        store.inspect(request, credentialConsent: false)
        store.setDemoEnabled(true); store.inspect(request, credentialConsent: true)
        #expect(await executor.inspections == 0)
        store.setDemoEnabled(false); store.inspect(request, credentialConsent: true); try await settle(store)
        #expect(await executor.inspections == 1)
        #expect(store.plan?.remoteRef == "refs/heads/integration")
    }
    @Test("Exact remote ref and exact displayed plan are required for a one-use push")
    func exactPush() async throws {
        let executor = RemoteStoreFixture(), store = GitRemotePushStore(executor: executor)
        store.inspect(request, credentialConsent: true); try await settle(store)
        let plan = try #require(store.plan)
        for typed in ["integration", "refs/heads/main", "refs/heads/integration ", "refs/heads/Integration"] {
            store.push(planID: plan.id, typedRef: typed, credentialConsent: true)
        }
        store.push(planID: UUID(), typedRef: plan.remoteRef, credentialConsent: true)
        store.push(planID: plan.id, typedRef: plan.remoteRef, credentialConsent: false)
        #expect(await executor.pushes == 0)
        store.push(planID: plan.id, typedRef: plan.remoteRef, credentialConsent: true)
        store.push(planID: plan.id, typedRef: plan.remoteRef, credentialConsent: true)
        try await settle(store)
        #expect(await executor.pushes == 1)
        #expect(store.result?.verified == true && store.plan == nil)
    }
    @Test("Unknown and rejected outcomes never retry; reconciliation only reads", arguments: [GitRemotePushState.unknown, .notUpdated, .differentOID])
    func unknown(_ state: GitRemotePushState) async throws {
        let executor = RemoteStoreFixture(), store = GitRemotePushStore(executor: executor)
        await executor.setOutcome(state)
        store.inspect(request, credentialConsent: true); try await settle(store)
        let plan = try #require(store.plan)
        store.push(planID: plan.id, typedRef: plan.remoteRef, credentialConsent: true); try await settle(store)
        #expect(store.result?.state == state && store.result?.verified == false)
        #expect(await executor.pushes == 1)
        store.reconcile(resultID: plan.id, credentialConsent: false)
        #expect(await executor.reconciliations == 0)
        await executor.setOutcome(.verified)
        store.reconcile(resultID: plan.id, credentialConsent: true); try await settle(store)
        #expect(store.result?.verified == true)
        #expect(await executor.reconciliations == 1)
        #expect(await executor.pushes == 1)
    }
    @Test("Completed remote outcome survives invalidation only as an informational session record")
    func staleResult() async throws {
        let executor = RemoteStoreFixture(), store = GitRemotePushStore(executor: executor)
        await executor.setDelay(100_000_000)
        store.inspect(request, credentialConsent: true); try await settle(store)
        let plan = try #require(store.plan)
        store.push(planID: plan.id, typedRef: plan.remoteRef, credentialConsent: true)
        for _ in 0..<1000 {
            if await executor.pushes == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        store.setDemoEnabled(true)
        #expect(store.isBusy && store.blocksAppUpdate)
        try await settle(store)
        #expect(store.result == nil && store.plan == nil && !store.isBusy)
        #expect(store.lastResult?.verified == true)
        store.reconcile(resultID: plan.id, credentialConsent: true)
        #expect(await executor.reconciliations == 0)
        store.setDemoEnabled(false)
        store.reconcile(resultID: plan.id, credentialConsent: true)
        #expect(await executor.reconciliations == 0)
        store.reconcile(resultID: plan.id, credentialConsent: true, allowSessionRecord: true)
        try await settle(store)
        #expect(await executor.pushes == 1)
        #expect(await executor.reconciliations == 1)
        #expect(store.lastResult?.verified == true)
    }
}
