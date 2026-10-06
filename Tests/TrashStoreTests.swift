import Foundation
import Testing
@testable import MoeKit

@MainActor @Suite("Trash review state machine")
struct TrashStoreTests {
    private let mode = UUID()
    private func configure(_ store: TrashStore, demo: Bool = false) {
        store.updateContext(.init(isDemoEnabled: demo, modeGeneration: mode))
    }
    private func inspect(_ store: TrashStore) async {
        configure(store); store.inspect(); await settle(store)
    }
    private func prepare(_ store: TrashStore, action: TrashRemovalPlan.Action = .selectedItems) async throws -> TrashRemovalPlan {
        await inspect(store); store.select(paths: Set(store.items.filter(\.isEligible).map(\.id)))
        store.prepare(action: action); await settle(store); return try #require(store.plan)
    }
    private func attest(_ store: TrashStore, _ plan: TrashRemovalPlan) {
        store.attestIrreversible(true, planID: plan.id); store.attestWorkloadsStopped(true, planID: plan.id)
    }
    private func settle(_ store: TrashStore) async {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!store.isBusy)
    }
    @Test("Construction and Demo remain inert")
    func inertConstruction() async {
        let fixture = TrashStoreFixture(), store = TrashStore(executor: fixture)
        for _ in 0..<10 { await Task.yield() }
        #expect(await fixture.inspectCount == 0)
        #expect(await fixture.removeCount == 0)
        #expect(await fixture.readCount == 0)
        #expect(store.inspection == nil && store.plan == nil && store.lastOutcome == nil)
        configure(store, demo: true); store.inspect(); store.readRecords(); store.prepare(action: .clearSnapshot)
        #expect(!store.isBusy && !store.canInspect && !store.canClear)
        #expect(await fixture.inspectCount == 0)
        let unavailable = TrashStore(executor: nil)
        #expect(!unavailable.isEnabled && !unavailable.canInspect)
    }
    @Test("Selected deletion requires both exact-plan attestations and executes once")
    func selectedConfirmation() async throws {
        let fixture = TrashStoreFixture(), store = TrashStore(executor: fixture), plan = try await prepare(store)
        store.confirm(planID: plan.id); #expect(await fixture.removeCount == 0)
        store.attestIrreversible(true, planID: plan.id); #expect(!store.canConfirm(planID: plan.id))
        store.attestWorkloadsStopped(true, planID: UUID()); #expect(!store.workloadsStopped)
        store.attestWorkloadsStopped(true, planID: plan.id); #expect(store.canConfirm(planID: plan.id))
        store.confirm(planID: plan.id); store.confirm(planID: plan.id); await settle(store)
        #expect(await fixture.removeCount == 1)
        #expect(store.lastOutcome?.items.count == 2 && store.inspection == nil && store.plan == nil)
    }
    @Test("Clear requires the exact typed token, separately from selected deletion")
    func typedClear() async throws {
        let fixture = TrashStoreFixture(), store = TrashStore(executor: fixture), plan = try await prepare(store, action: .clearSnapshot)
        attest(store, plan)
        for value in ["", "empty", " EMPTY", "EMPTY "] {
            store.typeConfirmation(value, planID: plan.id); #expect(!store.canConfirm(planID: plan.id))
        }
        store.typeConfirmation("EMPTY", planID: UUID()); #expect(!store.canConfirm(planID: plan.id))
        store.typeConfirmation("EMPTY", planID: plan.id); #expect(store.canConfirm(planID: plan.id))
        store.confirm(planID: plan.id); await settle(store)
        #expect(await fixture.removeCount == 1)
        #expect(store.typedConfirmation.isEmpty && !store.irreversibleAccepted && !store.workloadsStopped)
    }
    @Test("Selection changes, cancellation, rescans and Demo revoke the old confirmation")
    func invalidateOldPlan() async throws {
        let fixture = TrashStoreFixture(), store = TrashStore(executor: fixture)
        let plan = try await prepare(store); attest(store, plan)
        store.select(paths: [store.items[0].id]); store.confirm(planID: plan.id)
        #expect(store.plan == nil && !store.irreversibleAccepted)
        store.prepare(action: .selectedItems); await settle(store)
        let next = try #require(store.plan); attest(store, next); store.cancel(); store.confirm(planID: next.id)
        store.prepare(action: .selectedItems); await settle(store)
        let third = try #require(store.plan); attest(store, third); configure(store, demo: true); store.confirm(planID: third.id)
        #expect(await fixture.removeCount == 0)
        #expect(store.inspection == nil && store.selectedPaths.isEmpty)
    }
    @Test("Unknown and blocked items cannot be selected and disable clearing")
    func membership() async throws {
        let fixture = TrashStoreFixture(blocked: true), store = TrashStore(executor: fixture)
        await inspect(store); store.select(paths: Set(store.items.map(\.id) + ["/outside"]))
        #expect(store.selectedPaths.count == 2 && !store.canClear)
        store.prepare(action: .clearSnapshot); #expect(!store.isBusy && store.plan == nil)
    }
    @Test("Late inspection and preparation cannot cross a Demo generation")
    func staleResults() async {
        let inspectionFixture = TrashStoreFixture(holdInspection: true), store = TrashStore(executor: inspectionFixture)
        configure(store); store.inspect(); await inspectionFixture.waitUntilHeld()
        configure(store, demo: true); configure(store); await inspectionFixture.release(); await settle(store)
        #expect(store.inspection == nil)
        let prepareFixture = TrashStoreFixture(holdPreparation: true), preparedStore = TrashStore(executor: prepareFixture)
        await inspect(preparedStore); preparedStore.select(paths: Set(preparedStore.items.map(\.id)))
        preparedStore.prepare(action: .selectedItems); await prepareFixture.waitUntilHeld()
        configure(preparedStore, demo: true); await prepareFixture.release(); await settle(preparedStore)
        #expect(preparedStore.plan == nil)
    }
    @Test("Actual partial results survive cancel, dismissal and Demo; update installation remains blocked until completion")
    func actualOutcomesSurvive() async throws {
        let fixture = TrashStoreFixture(holdMutation: true), store = TrashStore(executor: fixture), plan = try await prepare(store)
        attest(store, plan); store.confirm(planID: plan.id); await fixture.waitUntilHeld()
        #expect(!UpdateInstallationSafety.shared.canTerminate)
        store.cancel(); configure(store, demo: true)
        #expect(store.isBusy && store.isCancelling && !UpdateInstallationSafety.shared.canTerminate)
        await fixture.release(); await settle(store)
        #expect(store.lastOutcome?.items.count == 2 && store.lastOutcome?.items.first?.status == .deleted)
        #expect(store.lastOutcome?.items.last?.status == .notAttempted)
        #expect(store.plan == nil && store.inspection == nil && !store.blocksAppUpdate)
    }
    @Test("Context provider is checked synchronously before confirming")
    func immediateContextChange() async throws {
        let fixture = TrashStoreFixture(), store = TrashStore(executor: fixture)
        var state = TrashWorkspaceContext(isDemoEnabled: false, modeGeneration: mode)
        store.bindContext { state }
        store.inspect(); await settle(store); store.select(paths: Set(store.items.map(\.id)))
        store.prepare(action: .selectedItems); await settle(store)
        let plan = try #require(store.plan); attest(store, plan)
        state = .init(isDemoEnabled: true, modeGeneration: UUID())
        #expect(!store.canConfirm(planID: plan.id)); store.confirm(planID: plan.id)
        #expect(await fixture.removeCount == 0)
    }
    @Test("Late read-only progress cannot leak across Demo or cancellation")
    func staleScanProgress() async {
        let fixture = TrashStoreFixture(holdInspection: true), store = TrashStore(executor: fixture)
        configure(store); store.inspect(); await fixture.waitUntilHeld()
        store.cancel(); configure(store, demo: true)
        await fixture.emitLateProgress()
        for _ in 0..<10 { await Task.yield() }
        #expect(store.scanProgress == nil)
        await fixture.release(); await settle(store)
        #expect(store.inspection == nil && store.scanProgress == nil)
    }
    @Test("Expired confirmations cannot execute")
    func expired() async throws {
        let fixture = TrashStoreFixture(expired: true), store = TrashStore(executor: fixture)
        await inspect(store); store.select(paths: Set(store.items.map(\.id))); store.prepare(action: .selectedItems); await settle(store)
        #expect(store.plan == nil && !store.irreversibleAccepted)
        #expect(await fixture.removeCount == 0)
    }
    @Test("Recovery records are explicitly read and never authorize actions")
    func recordsReadOnly() async {
        let fixture = TrashStoreFixture(), store = TrashStore(executor: fixture)
        configure(store); store.readRecords(); await settle(store)
        #expect(store.hasReadRecords && store.recoveryItems.isEmpty && store.plan == nil)
        #expect(await fixture.readCount == 1)
        #expect(await fixture.removeCount == 0)
    }
    @Test("A mismatched returned plan is never displayed as approved scope")
    func mismatchedPlan() async {
        let fixture = TrashStoreFixture(mismatch: true), store = TrashStore(executor: fixture)
        await inspect(store); store.select(paths: Set(store.items.map(\.id))); store.prepare(action: .selectedItems); await settle(store)
        #expect(store.plan == nil && !store.irreversibleAccepted)
    }
}

actor TrashStoreFixture: TrashExecuting {
    private(set) var inspectCount = 0, removeCount = 0, readCount = 0
    private let blocked: Bool, holdInspection: Bool, holdPreparation: Bool, holdMutation: Bool, expired: Bool, mismatch: Bool, failMutation: Bool
    private var scanCallback: (@Sendable (DirectoryScanProgress) -> Void)?
    private var waiter: CheckedContinuation<Void, Never>?
    private var report: TrashInspection?
    private var plan: TrashRemovalPlan?
    init(blocked: Bool = false, holdInspection: Bool = false, holdPreparation: Bool = false, holdMutation: Bool = false,
         expired: Bool = false, mismatch: Bool = false, failMutation: Bool = false) {
        self.blocked = blocked; self.holdInspection = holdInspection; self.holdPreparation = holdPreparation
        self.holdMutation = holdMutation; self.expired = expired; self.mismatch = mismatch; self.failMutation = failMutation
    }
    func inspect(context: TrashContext, progress: @escaping @Sendable (DirectoryScanProgress) -> Void) async throws -> TrashInspection {
        scanCallback = progress
        progress(.init(phase: .sizing, finished: 0, total: 2, currentPath: "/Synthetic/Trash"))
        return try await inspect(context: context)
    }
    func emitLateProgress() {
        scanCallback?(.init(phase: .sizing, finished: 1, total: 2, currentPath: "/Sensitive/old-trash"))
    }
    func inspect(context: TrashContext) async throws -> TrashInspection {
        inspectCount += 1
        if holdInspection { await withCheckedContinuation { waiter = $0 } }
        let root = URL(fileURLWithPath: "/Synthetic/Trash")
        var items = ["photo 空格.txt", "old download.zip"].map {
            TrashItem(url: root.appendingPathComponent($0), manifest: Self.manifest, modifiedAt: Date(), blocker: nil)
        }
        if blocked { items.append(.init(url: root.appendingPathComponent("blocked"), manifest: nil, modifiedAt: nil, blocker: "Unreadable fixture")) }
        let value = TrashInspection(id: UUID(), rootURL: root, items: items, context: context, observedAt: Date(), rootExists: true)
        report = value; return value
    }
    func prepare(inspectionID: UUID, selectedPaths: Set<String>, action: TrashRemovalPlan.Action, context: TrashContext) async throws -> TrashRemovalPlan {
        if holdPreparation { await withCheckedContinuation { waiter = $0 } }
        guard let report else { throw TrashFailure.changed }
        let value = TrashRemovalPlan(id: UUID(), inspectionID: inspectionID, action: action, rootURL: report.rootURL,
            items: mismatch ? [] : report.items.filter { selectedPaths.contains($0.id) }, context: context,
            recoveryURL: URL(fileURLWithPath: "/Synthetic/Support/MoeKit/TrashRemovalRecords"), expiresAt: Date().addingTimeInterval(expired ? -1 : 120))
        plan = value; return value
    }
    func discardPlan() { plan = nil }
    func remove(planID: UUID, context: TrashContext, progress: @escaping @Sendable (TrashProgress) -> Void) async throws -> TrashOutcome {
        guard let value = plan, value.id == planID, value.context == context else { throw TrashFailure.expired }
        plan = nil; removeCount += 1
        progress(.init(finished: 0, total: value.items.count, currentPath: value.items.first?.url.path))
        if holdMutation { await withCheckedContinuation { waiter = $0 } }
        if failMutation { throw TrashFailure.changed }
        return .init(items: value.items.enumerated().map { index, item in
            .init(originalURL: item.url, status: holdMutation && index > 0 ? .notAttempted : .deleted,
                  message: "Synthetic actual outcome", operationURL: nil)
        })
    }
    func readRecords() -> [TrashRecoveryItem] { readCount += 1; return [] }
    func release() { waiter?.resume(); waiter = nil }
    func waitUntilHeld() async {
        let end = Date().addingTimeInterval(5)
        while waiter == nil && Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(waiter != nil)
    }
    private static let identity = InstallerFileSnapshot(device: 1, inode: 2, mode: 0o100600, uid: 501, gid: 20,
        links: 1, flags: 0, bytes: 12, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
    private static let manifest = CleanupManifest(entries: [.init(relativePath: "", kind: .file, identity: identity, linkDestination: nil)], logicalBytes: 12)
}
