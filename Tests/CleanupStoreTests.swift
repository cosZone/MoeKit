import Foundation
import Testing
@testable import MoeKit

@MainActor @Suite("Explicit native cache cleanup state machine")
struct CleanupStoreTests {
    private let root = URL(fileURLWithPath: "/Synthetic/Caches", isDirectory: true)
    private let mode = UUID()
    private var first: String { root.appendingPathComponent("one").path }
    private var second: String { root.appendingPathComponent("two").path }

    @Test("Construction starts no inspection, record read, preparation or mutation")
    func inertConstruction() async {
        let fixture = CleanupStoreFixture(), store = CleanupStore(executor: nil)
        let live = CleanupStore(executor: fixture)
        for _ in 0..<20 { await Task.yield() }
        #expect(live.isEnabled && !live.isBusy && live.inspection == nil && live.plan == nil)
        #expect(live.recoveryItems.isEmpty && !live.hasReadRecovery && live.lastOutcome == nil)
        #expect(await fixture.inspectCount == 0)
        #expect(await fixture.recoveryCount == 0)
        #expect(await fixture.moveCount == 0)
        #expect(!store.isEnabled && !store.canInspect && !store.canReadRecovery)
        live.inspect(); live.prepare(); live.confirm(planID: UUID()); live.confirmRecovery(planID: UUID())
        #expect(!live.isBusy)
    }

    @Test("Selecting a folder stays inert and stale picker tickets cannot cross Demo")
    func folderTickets() async throws {
        let fixture = CleanupStoreFixture(), store = CleanupStore(executor: CleanupStoreFixture())
        let active = CleanupStore(executor: fixture)
        context(active)
        let ticket = try #require(active.selectionTicket())
        active.selectRoot(root, ticket: ticket)
        #expect(active.rootURL == root && active.canInspect)
        #expect(await fixture.inspectCount == 0)
        context(store)
        let stale = try #require(store.selectionTicket())
        context(store, demo: true); context(store)
        store.selectRoot(root, ticket: stale)
        #expect(store.rootURL == nil && !store.canInspect)
    }

    @Test("Only inspected eligible membership is selectable and every selection change resets attestation")
    func selectionMembership() async throws {
        let fixture = CleanupStoreFixture(), store = CleanupStore(executor: fixture)
        try await inspect(store)
        store.select(paths: [first, second, root.appendingPathComponent("blocked").path, "/Synthetic/Outside"])
        #expect(store.selectedPaths == [first, second])
        store.prepare(); await settle(store)
        let plan = try #require(store.plan)
        store.attestWorkloadsStopped(true, planID: plan.id)
        store.attestContentRegenerable(true, planID: plan.id)
        #expect(store.canConfirm(planID: plan.id))
        store.select(paths: [second])
        #expect(store.plan == nil && !store.workloadsStopped && !store.contentRegenerable)
        store.confirm(planID: plan.id)
        #expect(await fixture.moveCount == 0)
    }

    @Test("Trash requires both attestations and accepts one exact plan once")
    func confirmationOneUse() async throws {
        let fixture = CleanupStoreFixture(), store = CleanupStore(executor: fixture)
        let plan = try await prepare(store)
        store.confirm(planID: plan.id)
        #expect(await fixture.moveCount == 0)
        store.attestWorkloadsStopped(true, planID: plan.id)
        #expect(!store.canConfirm(planID: plan.id))
        store.attestContentRegenerable(true, planID: UUID())
        #expect(!store.contentRegenerable)
        store.attestContentRegenerable(true, planID: plan.id)
        store.confirm(planID: UUID())
        #expect(store.plan?.id == plan.id)
        store.confirm(planID: plan.id); store.confirm(planID: plan.id)
        await settle(store)
        #expect(await fixture.moveCount == 1)
        #expect(store.lastOutcome?.items.count == 2 && store.inspection == nil && store.selectedPaths.isEmpty)
        #expect(store.receipts.count == 2)
    }

    @Test("Expired confirmation cannot execute or retain attestation")
    func expiredConfirmation() async throws {
        let clock = CleanupTestClock(), fixture = CleanupStoreFixture()
        let store = CleanupStore(executor: fixture, now: { clock.now })
        let plan = try await prepare(store)
        store.attestWorkloadsStopped(true, planID: plan.id); store.attestContentRegenerable(true, planID: plan.id)
        clock.set(.distantFuture)
        store.confirm(planID: plan.id)
        #expect(store.plan == nil && !store.workloadsStopped && store.errorMessage != nil)
        #expect(await fixture.moveCount == 0)
    }

    @Test("Late inspection cannot cross cancellation, Demo or a catalog change")
    func staleInspection() async throws {
        let fixture = CleanupStoreFixture(holdInspection: true)
        let active = CleanupStore(executor: fixture)
        context(active)
        active.selectRoot(root, ticket: try #require(active.selectionTicket()))
        active.inspect(); await fixture.waitForInspection()
        active.cancel(); context(active, demo: true); context(active, protected: ["/Synthetic/Project"])
        #expect(active.isBusy && active.isCancelling)
        active.inspect(); active.loadRecovery()
        await fixture.releaseInspection(); await settle(active)
        #expect(active.inspection == nil && active.rootURL == nil && active.plan == nil)
        #expect(await fixture.inspectCount == 1)
        #expect(await fixture.recoveryCount == 0)
    }

    @Test("Late preparation cannot publish after context invalidation")
    func stalePreparation() async throws {
        let fixture = CleanupStoreFixture(holdPreparation: true)
        let active = CleanupStore(executor: fixture)
        try await inspect(active); active.select(paths: [first]); active.prepare()
        await fixture.waitForPreparation()
        context(active, protected: [first])
        await fixture.releasePreparation(); await settle(active)
        #expect(active.plan == nil && active.selectedPaths.isEmpty)
        #expect(await fixture.moveCount == 0)
    }

    @Test("Mismatched backend targets are not offered as the user's plan")
    func mismatchedPreparedTargets() async throws {
        let fixture = CleanupStoreFixture(mismatchedPlan: true)
        let active = CleanupStore(executor: fixture)
        try await inspect(active); active.select(paths: [first]); active.prepare(); await settle(active)
        #expect(active.plan == nil && !active.workloadsStopped)
        #expect(await fixture.moveCount == 0)
    }

    @Test("Cancel before queued mutation prevents executor entry")
    func cancelQueuedMutation() async throws {
        let fixture = CleanupStoreFixture(), store = CleanupStore(executor: fixture)
        let plan = try await prepare(store)
        store.attestWorkloadsStopped(true, planID: plan.id); store.attestContentRegenerable(true, planID: plan.id)
        store.confirm(planID: plan.id); store.cancel(); await settle(store)
        #expect(await fixture.moveCount == 0)
        #expect(store.lastOutcome == nil && store.plan == nil)
    }

    @Test("Live context is re-read before execution even without a SwiftUI change callback")
    func synchronousContextGuard() async throws {
        let fixture = CleanupStoreFixture(), store = CleanupStore(executor: fixture)
        let box = CleanupContextBox(CleanupWorkspaceContext(isDemoEnabled: false, modeGeneration: mode, protectedPaths: [], catalogIsKnown: true))
        store.bindContext { box.value }
        store.selectRoot(root, ticket: try #require(store.selectionTicket()))
        store.inspect(); await settle(store); store.select(paths: [first]); store.prepare(); await settle(store)
        let plan = try #require(store.plan)
        store.attestWorkloadsStopped(true, planID: plan.id); store.attestContentRegenerable(true, planID: plan.id)
        store.confirm(planID: plan.id)
        box.value = CleanupWorkspaceContext(isDemoEnabled: false, modeGeneration: UUID(), protectedPaths: [], catalogIsKnown: true)
        await settle(store)
        #expect(await fixture.moveCount == 0)
        #expect(store.plan == nil && store.inspection == nil)
    }

    @Test("Actual partial mutation outcomes survive cancel and Demo boundaries")
    func retainedActualOutcome() async throws {
        let fixture = CleanupStoreFixture(holdMutation: true, partialOutcome: true), store = CleanupStore(executor: fixture)
        let plan = try await prepare(store)
        store.attestWorkloadsStopped(true, planID: plan.id); store.attestContentRegenerable(true, planID: plan.id)
        store.confirm(planID: plan.id); await fixture.waitForMutation()
        store.cancel(); context(store, demo: true)
        #expect(store.isBusy && store.isCancelling)
        await fixture.releaseMutation(); await settle(store)
        #expect(store.isDemoEnabled && store.lastOutcome?.items.count == 2)
        #expect(store.lastOutcome?.items.first?.succeeded == true)
        #expect(store.lastOutcome?.items.last?.succeeded == false)
        #expect(store.receipts.count == 1 && !store.canReadRecovery)
    }

    @Test("Permanent deletion requires a separate receipt plan and irreversible attestation")
    func separatePermanentDeletion() async throws {
        let fixture = CleanupStoreFixture(), store = CleanupStore(executor: fixture)
        context(store)
        #expect(await fixture.recoveryCount == 0)
        store.loadRecovery(); await settle(store)
        let receipt = try #require(store.receipts.first)
        store.prepareRecovery(receiptID: UUID(), action: .deletePermanently)
        #expect(!store.isBusy)
        store.prepareRecovery(receiptID: receipt.id, action: .deletePermanently); await settle(store)
        let plan = try #require(store.recoveryPlan)
        store.confirmRecovery(planID: plan.id)
        #expect(await fixture.applyCount == 0)
        store.attestIrreversibleDeletion(true, planID: UUID())
        #expect(!store.canConfirmRecovery(planID: plan.id))
        store.attestIrreversibleDeletion(true, planID: plan.id)
        store.confirmRecovery(planID: plan.id); store.confirmRecovery(planID: plan.id); await settle(store)
        #expect(await fixture.applyCount == 1)
        #expect(store.receipts.first?.state == .deleted && !store.irreversibleDeletionAccepted)
    }

    @Test("Restore needs a new plan, while no deletion attestation transfers to a replacement")
    func independentRecoveryPlans() async throws {
        let fixture = CleanupStoreFixture(), store = CleanupStore(executor: fixture)
        context(store); store.loadRecovery(); await settle(store)
        let id = try #require(store.receipts.first?.id)
        store.prepareRecovery(receiptID: id, action: .deletePermanently); await settle(store)
        let stale = try #require(store.recoveryPlan)
        store.attestIrreversibleDeletion(true, planID: stale.id)
        store.prepareRecovery(receiptID: id, action: .restore); await settle(store)
        #expect(!store.irreversibleDeletionAccepted)
        store.confirmRecovery(planID: stale.id)
        #expect(await fixture.applyCount == 0)
        let restore = try #require(store.recoveryPlan)
        #expect(store.canConfirmRecovery(planID: restore.id))
        store.confirmRecovery(planID: restore.id); await settle(store)
        #expect(store.receipts.first?.state == .restored)
    }

    @Test("A new recovery read revokes vanished receipts and plans without erasing actual outcomes")
    func vanishedReceipt() async throws {
        let fixture = CleanupStoreFixture(), store = CleanupStore(executor: fixture)
        let plan = try await prepare(store)
        store.attestWorkloadsStopped(true, planID: plan.id); store.attestContentRegenerable(true, planID: plan.id)
        store.confirm(planID: plan.id); await settle(store)
        let receipt = try #require(store.receipts.first)
        store.prepareRecovery(receiptID: receipt.id, action: .deletePermanently); await settle(store)
        let stale = try #require(store.recoveryPlan)
        await fixture.setRecoveryMissing()
        store.loadRecovery(); await settle(store)
        #expect(store.receipts.isEmpty && store.recoveryItems.count == 2)
        #expect(store.lastOutcome?.items.count == 2 && store.recoveryPlan == nil)
        store.attestIrreversibleDeletion(true, planID: stale.id); store.confirmRecovery(planID: stale.id)
        store.prepareRecovery(receiptID: receipt.id, action: .deletePermanently)
        #expect(await fixture.applyCount == 0)
    }

    @Test("Late permanent-delete outcomes remain visible after context invalidation")
    func lateDeleteOutcome() async throws {
        let fixture = CleanupStoreFixture(holdRecoveryMutation: true), store = CleanupStore(executor: fixture)
        context(store); store.loadRecovery(); await settle(store)
        store.prepareRecovery(receiptID: try #require(store.receipts.first?.id), action: .deletePermanently); await settle(store)
        let plan = try #require(store.recoveryPlan)
        store.attestIrreversibleDeletion(true, planID: plan.id); store.confirmRecovery(planID: plan.id)
        await fixture.waitForRecoveryMutation()
        context(store, demo: true); await fixture.releaseRecoveryMutation(); await settle(store)
        #expect(store.receipts.first?.state == .deleted && store.lastOutcome != nil && store.isDemoEnabled)
    }

    private func context(_ store: CleanupStore, demo: Bool = false, protected: [String] = []) {
        store.updateContext(CleanupWorkspaceContext(isDemoEnabled: demo, modeGeneration: mode, protectedPaths: protected, catalogIsKnown: true))
    }
    private func inspect(_ store: CleanupStore) async throws {
        context(store)
        store.selectRoot(root, ticket: try #require(store.selectionTicket()))
        store.inspect(); await settle(store)
        #expect(store.inspection != nil)
    }
    private func prepare(_ store: CleanupStore) async throws -> CleanupPlan {
        try await inspect(store)
        store.select(paths: [first, second]); store.prepare(); await settle(store)
        return try #require(store.plan)
    }
    private func settle(_ store: CleanupStore) async {
        for _ in 0..<10000 { if !store.isBusy { return }; await Task.yield() }
        Issue.record("Cleanup fixture state did not settle")
    }
}

@MainActor private final class CleanupContextBox {
    var value: CleanupWorkspaceContext
    init(_ value: CleanupWorkspaceContext) { self.value = value }
}
private final class CleanupTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; date = value }
}

private actor CleanupStoreFixture: CleanupExecuting {
    private(set) var inspectCount = 0
    private(set) var prepareCount = 0
    private(set) var moveCount = 0
    private(set) var recoveryCount = 0
    private(set) var applyCount = 0
    private let holdInspection: Bool
    private let holdPreparation: Bool
    private let holdMutation: Bool
    private let holdRecoveryMutation: Bool
    private let partialOutcome: Bool
    private let mismatchedPlan: Bool
    private var inspectionWaiter: CheckedContinuation<Void, Never>?
    private var preparationWaiter: CheckedContinuation<Void, Never>?
    private var mutationWaiter: CheckedContinuation<Void, Never>?
    private var recoveryMutationWaiter: CheckedContinuation<Void, Never>?
    private var inspection: CleanupInspection?
    private var trashPlans: [UUID: CleanupPlan] = [:]
    private var recoveryPlans: [UUID: CleanupRecoveryPlan] = [:]
    private var records: [CleanupReceipt] = []
    private var recoveryMissing = false
    private let root = URL(fileURLWithPath: "/Synthetic/Caches", isDirectory: true)

    init(holdInspection: Bool = false, holdPreparation: Bool = false, holdMutation: Bool = false,
         holdRecoveryMutation: Bool = false, partialOutcome: Bool = false, mismatchedPlan: Bool = false) {
        self.holdInspection = holdInspection; self.holdPreparation = holdPreparation; self.holdMutation = holdMutation
        self.holdRecoveryMutation = holdRecoveryMutation; self.partialOutcome = partialOutcome; self.mismatchedPlan = mismatchedPlan
    }
    func inspect(root: URL, context: CleanupContext) async throws -> CleanupInspection {
        inspectCount += 1
        if holdInspection { await withCheckedContinuation { inspectionWaiter = $0 } }
        let candidates = ["one", "two"].map {
            CleanupCandidate(url: root.appendingPathComponent($0), evidence: "Synthetic cache", manifest: Self.manifest, blocker: nil)
        } + [CleanupCandidate(url: root.appendingPathComponent("blocked"), evidence: "Synthetic blocker", manifest: nil, blocker: "Unreadable")]
        let result = CleanupInspection(id: UUID(), rootURL: root, candidates: candidates, context: context, observedAt: Date())
        inspection = result
        return result
    }
    func prepare(inspectionID: UUID, selectedPaths: Set<String>, context: CleanupContext) async throws -> CleanupPlan {
        prepareCount += 1
        if holdPreparation { await withCheckedContinuation { preparationWaiter = $0 } }
        guard let inspection, inspection.id == inspectionID else { throw CleanupFailure.changed }
        let targets = selectedPaths.sorted().map { path in
            CleanupTarget(originalURL: URL(fileURLWithPath: mismatchedPlan ? "/Synthetic/Outside" : path), evidence: "Synthetic cache", manifest: Self.manifest)
        }
        let result = CleanupPlan(id: UUID(), inspectionID: inspectionID, rootURL: inspection.rootURL, targets: targets,
            context: context, recoveryRoot: URL(fileURLWithPath: "/Synthetic/Recovery"), preparedAt: Date(), expiresAt: Date().addingTimeInterval(120))
        trashPlans[result.id] = result
        return result
    }
    func discardPlans() async { trashPlans = [:]; recoveryPlans = [:] }
    func moveToTrash(planID: UUID, context: CleanupContext) async throws -> CleanupOutcome {
        guard let plan = trashPlans.removeValue(forKey: planID), plan.context == context else { throw CleanupFailure.expired }
        moveCount += 1
        if holdMutation { await withCheckedContinuation { mutationWaiter = $0 } }
        return CleanupOutcome(items: plan.targets.enumerated().map { index, target in
            if partialOutcome && index > 0 {
                return CleanupItemOutcome(id: UUID(), originalURL: target.originalURL, receipt: nil, message: "Not attempted after earlier interruption", succeeded: false, requiresRecovery: false)
            }
            let receipt = makeReceipt(target: target, state: .trashed)
            records.append(receipt)
            return CleanupItemOutcome(id: receipt.id, originalURL: target.originalURL, receipt: receipt, message: "Synthetic Trash outcome", succeeded: true, requiresRecovery: false)
        })
    }
    func recoveryRecords() async throws -> [CleanupRecoveryItem] {
        recoveryCount += 1
        if recoveryMissing { return [] }
        if records.isEmpty { records = [makeReceipt(target: CleanupTarget(originalURL: root.appendingPathComponent("one"), evidence: "Synthetic cache", manifest: Self.manifest), state: .trashed)] }
        return records.map { CleanupRecoveryItem(id: $0.id, operationURL: $0.operationURL, receipt: $0, issue: nil) }
    }
    func prepareRecovery(receiptID: UUID, action: CleanupRecoveryPlan.Action, context: CleanupContext) async throws -> CleanupRecoveryPlan {
        guard let receipt = records.first(where: { $0.id == receiptID }), let source = receipt.payloadURL else { throw CleanupFailure.journal }
        let plan = CleanupRecoveryPlan(id: UUID(), action: action, receipt: receipt, sourceURL: source, context: context,
            preparedAt: Date(), expiresAt: Date().addingTimeInterval(120))
        recoveryPlans[plan.id] = plan
        return plan
    }
    func applyRecovery(planID: UUID, context: CleanupContext) async throws -> CleanupOutcome {
        guard let plan = recoveryPlans.removeValue(forKey: planID), plan.context == context else { throw CleanupFailure.expired }
        applyCount += 1
        if holdRecoveryMutation { await withCheckedContinuation { recoveryMutationWaiter = $0 } }
        let old = plan.receipt
        let receipt = CleanupReceipt(id: old.id, sequence: old.sequence + 1, target: old.target, originalParent: old.originalParent,
            operationURL: old.operationURL, operationIdentity: old.operationIdentity, state: plan.action == .restore ? .restored : .deleted,
            payloadURL: nil, manifest: old.manifest, recordedAt: Date())
        records = records.map { $0.id == receipt.id ? receipt : $0 }
        return CleanupOutcome(items: [CleanupItemOutcome(id: receipt.id, originalURL: receipt.target.originalURL,
            receipt: receipt, message: "Synthetic recovery outcome", succeeded: true, requiresRecovery: false)])
    }
    func setRecoveryMissing() { recoveryMissing = true }
    func releaseInspection() { inspectionWaiter?.resume(); inspectionWaiter = nil }
    func releasePreparation() { preparationWaiter?.resume(); preparationWaiter = nil }
    func releaseMutation() { mutationWaiter?.resume(); mutationWaiter = nil }
    func releaseRecoveryMutation() { recoveryMutationWaiter?.resume(); recoveryMutationWaiter = nil }
    func waitForInspection() async { for _ in 0..<10000 { if inspectionWaiter != nil { return }; await Task.yield() }; Issue.record("Inspection did not enter") }
    func waitForPreparation() async { for _ in 0..<10000 { if preparationWaiter != nil { return }; await Task.yield() }; Issue.record("Preparation did not enter") }
    func waitForMutation() async { for _ in 0..<10000 { if mutationWaiter != nil { return }; await Task.yield() }; Issue.record("Mutation did not enter") }
    func waitForRecoveryMutation() async { for _ in 0..<10000 { if recoveryMutationWaiter != nil { return }; await Task.yield() }; Issue.record("Recovery mutation did not enter") }
    private func makeReceipt(target: CleanupTarget, state: CleanupReceiptState) -> CleanupReceipt {
        let id = UUID()
        return CleanupReceipt(id: id, sequence: 3, target: target, originalParent: Self.identity,
            operationURL: URL(fileURLWithPath: "/Synthetic/Recovery/\(id)"), operationIdentity: Self.identity,
            state: state, payloadURL: URL(fileURLWithPath: "/Synthetic/Trash/\(target.originalURL.lastPathComponent)"),
            manifest: target.manifest, recordedAt: Date())
    }
    private static let identity = InstallerFileSnapshot(device: 1, inode: 2, mode: 0o100600, uid: 501, gid: 20,
        links: 1, flags: 0, bytes: 12, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
    private static let manifest = CleanupManifest(entries: [
        CleanupEntry(relativePath: "", kind: .directory, identity: identity, linkDestination: nil),
        CleanupEntry(relativePath: "data", kind: .file, identity: identity, linkDestination: nil)
    ], logicalBytes: 12)
}
