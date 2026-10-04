import Foundation
import Observation
import Testing
@testable import MoeKit

@MainActor @Suite("Confirmed installer Trash state machine")
struct InstallerTrashStoreTests {
    private let downloads = URL(fileURLWithPath: "/Synthetic/Downloads", isDirectory: true)
    private var selected: String { downloads.appendingPathComponent("Installer.dmg").path }

    @Test("Production default has no native mutation sink")
    func defaultGate() {
        let store = InstallerTrashStore()
        #expect(!store.isEnabled)
        #expect(!store.canPrepare)
        #expect(!store.canReadRecovery)
    }

    @Test("Only an explicit regular-file hint directly listed by current Downloads analysis can prepare")
    func selectionMembership() async throws {
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        try context(store, entries: [entry(selected), entry(downloads.appendingPathComponent("Folder.dmg").path, directory: true),
                                   entry(downloads.appendingPathComponent("Setup.pkg").path),
                                   entry(downloads.appendingPathComponent("Nested/Child.dmg").path),
                                   entry(downloads.appendingPathComponent("Unknown.dmg").path, status: "unavailable"),
                                   entry(downloads.appendingPathComponent("Hint.dmg").path, insight: true)])
        #expect(store.eligibleEntries.map(\.path) == [selected])
        store.prepare(); await settle(store)
        #expect(await executor.prepareCount == 0)
        for path in ["/Other/Installer.dmg", "/Synthetic/Downloads/../Downloads/Installer.dmg", downloads.appendingPathComponent("Missing.dmg").path] {
            store.select(path: path); store.prepare()
            #expect(store.selectedPath == nil)
        }
        #expect(await executor.prepareCount == 0)
        store.select(path: selected); store.prepare(); await settle(store)
        let plan = try #require(store.plan)
        #expect(plan.scope.liveEntryPaths.count == 6)
        #expect(plan.originalURL.path == selected)
        #expect(await executor.moveCount == 0)
    }

    @Test("Directory URL trailing-slash spelling does not reject an exact live Downloads path")
    func directoryURLSpelling() async throws {
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        let plain = URL(fileURLWithPath: downloads.path, isDirectory: false)
        #expect(plain.path == downloads.path)
        store.updateContext(liveAnalysisID: UUID(), result: try reportResult(directory: plain),
                            isDemoEnabled: false, protectedPaths: [], catalogIsKnown: true)
        store.select(path: selected); store.prepare(); await settle(store)
        #expect(store.plan != nil)
        #expect(await executor.prepareCount == 1)
    }

    @Test("Attestation, exact pending UUID, expiry and one-use consumption gate mutation")
    func exactConfirmation() async throws {
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        try context(store); store.select(path: selected); store.prepare(); await settle(store)
        let plan = try #require(store.plan)
        store.confirm(planID: plan.id)
        #expect(await executor.moveCount == 0)
        store.attestInstallationFinished(true, planID: UUID())
        #expect(!store.installationFinished)
        store.attestInstallationFinished(true, planID: plan.id)
        store.confirm(planID: UUID())
        #expect(store.plan != nil)
        store.confirm(planID: plan.id)
        store.confirm(planID: plan.id)
        #expect(store.isBusy && store.plan == nil && !store.installationFinished)
        await settle(store)
        #expect(await executor.moveCount == 1)
        #expect(store.lastOutcome?.movedToTrash == true)
        #expect(store.receipts.count == 1)
        #expect(store.liveAnalysisID == nil && store.eligibleEntries.isEmpty && store.selectedPath == nil)
        store.confirm(planID: plan.id)
        #expect(await executor.moveCount == 1)
    }

    @Test("Selection or any catalog and live context generation change invalidates confirmation")
    func generationInvalidation() async throws {
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        let liveID = UUID()
        try context(store, id: liveID)
        store.select(path: selected); store.prepare(); await settle(store)
        let old = try #require(store.plan)
        store.attestInstallationFinished(true, planID: old.id)
        store.select(path: selected)
        #expect(store.plan == nil && !store.installationFinished)
        store.confirm(planID: old.id)
        store.prepare(); await settle(store)
        let replacement = try #require(store.plan)
        #expect(replacement.scope.generation != old.scope.generation)
        try context(store, id: liveID, protected: ["/Synthetic/Project", "/Synthetic/Project/.git"])
        #expect(store.selectedPath == nil && store.plan == nil)
        store.confirm(planID: replacement.id)
        store.select(path: selected); store.prepare(); await settle(store)
        #expect(store.plan?.scope.protectedPaths == ["/Synthetic/Project", "/Synthetic/Project/.git"])
        try context(store, id: liveID, known: false)
        store.select(path: selected); store.prepare()
        #expect(!store.canPrepare && store.plan == nil)
        #expect(await executor.moveCount == 0)
    }

    @Test("Other roots, absent live UUID, unknown coverage and Demo cannot prepare")
    func contextIsolation() async throws {
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        for demo in [false, true] {
            store.updateContext(liveAnalysisID: nil, result: try reportResult(), isDemoEnabled: demo, protectedPaths: [], catalogIsKnown: true)
            store.select(path: selected); store.prepare()
            #expect(!store.canPrepare)
        }
        let other = URL(fileURLWithPath: "/Synthetic/Other", isDirectory: true)
        store.updateContext(liveAnalysisID: UUID(), result: try reportResult(directory: other), isDemoEnabled: false, protectedPaths: [], catalogIsKnown: true)
        store.select(path: selected); store.prepare()
        #expect(store.liveAnalysisID == nil)
        try context(store, status: "unavailable")
        #expect(store.liveAnalysisID == nil)
        try context(store); store.select(path: selected); store.prepare(); await settle(store)
        let old = try #require(store.plan)
        try context(store, demo: true)
        try context(store)
        store.confirm(planID: old.id)
        #expect(await executor.moveCount == 0)
    }

    @Test("Expired display plans cannot reach executor")
    func expiry() async throws {
        let clock = TrashClock(Date())
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads, now: { clock.now })
        try context(store); store.select(path: selected); store.prepare(); await settle(store)
        let plan = try #require(store.plan)
        store.attestInstallationFinished(true, planID: plan.id)
        clock.set(plan.expiresAt)
        #expect(!store.canConfirm(planID: plan.id))
        store.confirm(planID: plan.id)
        #expect(store.plan == nil && store.errorMessage == InstallerTrashFailure.expired.errorDescription)
        #expect(await executor.moveCount == 0)
    }

    @Test("Cancelled preparation stays owned and ignores late success")
    func cancelledPreparation() async throws {
        let executor = TrashFixture(holdPrepare: true)
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        try context(store); store.select(path: selected); store.prepare()
        await executor.waitForPrepare()
        store.cancel(); store.prepare()
        #expect(store.isBusy && store.isCancelling)
        await executor.releasePrepare(); await settle(store)
        #expect(store.plan == nil)
        #expect(await executor.prepareCount == 1)
        #expect(await executor.moveCount == 0)
    }

    @Test("Late preparation cannot cross a live-result or Demo boundary")
    func obsoletePreparation() async throws {
        let executor = TrashFixture(holdPrepare: true)
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        try context(store); store.select(path: selected); store.prepare()
        await executor.waitForPrepare()
        try context(store, demo: true); try context(store)
        await executor.releasePrepare(); await settle(store)
        #expect(store.plan == nil && store.selectedPath == nil)
        #expect(await executor.moveCount == 0)
    }

    @Test("Cancel before the queued mutation starts prevents executor entry")
    func cancellationBeforeMutation() async throws {
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        try context(store); store.select(path: selected); store.prepare(); await settle(store)
        let plan = try #require(store.plan)
        store.attestInstallationFinished(true, planID: plan.id)
        store.confirm(planID: plan.id); store.cancel()
        await settle(store)
        #expect(await executor.moveCount == 0)
    }

    @Test("Synchronous mutation outcome remains visible after cancellation and Demo change")
    func retainedMutationOutcome() async throws {
        let executor = TrashFixture(holdMove: true)
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        try context(store); store.select(path: selected); store.prepare(); await settle(store)
        let plan = try #require(store.plan)
        store.attestInstallationFinished(true, planID: plan.id); store.confirm(planID: plan.id)
        await executor.waitForMove()
        store.cancel(); try context(store, demo: true)
        #expect(store.isBusy && store.isCancelling)
        await executor.releaseMove(); await settle(store)
        #expect(store.isDemoEnabled)
        #expect(store.lastOutcome?.movedToTrash == true)
        #expect(store.receipts.first?.state == .trashed)
        #expect(!store.canReadRecovery)
    }

    @Test("Recovery is explicit read-only, Reveal validates and restore needs fresh one-use confirmation")
    func recoveryAndRestore() async throws {
        let executor = TrashFixture()
        var revealed: URL?
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads, revealLocation: { revealed = $0 })
        try context(store)
        #expect(await executor.recoveryCount == 0)
        store.loadRecovery(); await settle(store)
        let receipt = try #require(store.receipts.first)
        #expect(await executor.restoreCount == 0)
        store.reveal(receiptID: UUID())
        #expect(revealed == nil)
        store.reveal(receiptID: receipt.id); await settle(store)
        #expect(await executor.revealCount == 1)
        #expect(revealed == receipt.trashURL)
        store.prepareRestore(receiptID: receipt.id); await settle(store)
        let stale = try #require(store.restorePlan)
        try context(store)
        store.confirmRestore(planID: stale.id)
        #expect(await executor.restoreCount == 0)
        store.prepareRestore(receiptID: receipt.id); await settle(store)
        let plan = try #require(store.restorePlan)
        store.confirmRestore(planID: UUID())
        #expect(store.restorePlan != nil)
        store.confirmRestore(planID: plan.id); store.confirmRestore(planID: plan.id)
        await settle(store)
        #expect(await executor.restoreCount == 1)
        #expect(store.receipts.first?.state == .restored)
    }

    @Test("Restore expiry and late completion obey the same boundary")
    func restoreExpiryAndLateOutcome() async throws {
        let clock = TrashClock(Date())
        let executor = TrashFixture(holdRestore: true)
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads, now: { clock.now })
        try context(store); store.loadRecovery(); await settle(store)
        let receipt = try #require(store.receipts.first)
        store.prepareRestore(receiptID: receipt.id); await settle(store)
        let expired = try #require(store.restorePlan)
        clock.set(expired.expiresAt); store.confirmRestore(planID: expired.id)
        #expect(await executor.restoreCount == 0)
        clock.set(Date()); store.prepareRestore(receiptID: receipt.id); await settle(store)
        store.confirmRestore(planID: try #require(store.restorePlan?.id))
        await executor.waitForRestore()
        try context(store, demo: true)
        await executor.releaseRestore(); await settle(store)
        #expect(store.receipts.first?.state == .restored)
        #expect(store.lastOutcome != nil)
    }

    @Test("Incomplete records remain visible beside valid peers and cannot authorize restore")
    func incompleteRecovery() async throws {
        let executor = TrashFixture(includeIncomplete: true)
        var revealed: URL?
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads, revealLocation: { revealed = $0 })
        try context(store); store.loadRecovery(); await settle(store)
        #expect(store.recoveryItems.count == 2 && store.receipts.count == 1)
        let incomplete = try #require(store.recoveryItems.first(where: { $0.receipt == nil }))
        #expect(incomplete.issue != nil)
        store.prepareRestore(receiptID: incomplete.id)
        #expect(store.restorePlan == nil)
        #expect(await executor.prepareRestoreCount == 0)
        store.reveal(receiptID: incomplete.id); await settle(store)
        #expect(revealed == incomplete.operationURL)
        #expect(await executor.restoreCount == 0)
    }

    @Test("A fresh listing revokes vanished receipts without inferring an outcome or trusting their old Reveal paths")
    func vanishedRecoveryRecord() async throws {
        let executor = TrashFixture()
        var revealed: URL?
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads, revealLocation: { revealed = $0 })
        try context(store); store.loadRecovery(); await settle(store)
        let previous = try #require(store.recoveryItems.first)
        store.prepareRestore(receiptID: previous.id); await settle(store)
        let stalePlan = try #require(store.restorePlan)
        await executor.setRecoveryPresent(false)
        store.loadRecovery(); await settle(store)
        #expect(store.recoveryItems.count == 1 && store.receipts.isEmpty)
        let missing = try #require(store.recoveryItems.first)
        #expect(missing.id == previous.id && missing.operationURL == previous.operationURL)
        #expect(missing.receipt == nil && missing.issue != nil)
        #expect(store.restorePlan == nil)
        store.confirmRestore(planID: stalePlan.id)
        store.prepareRestore(receiptID: previous.id)
        #expect(await executor.prepareRestoreCount == 1)
        #expect(await executor.restoreCount == 0)
        store.reveal(receiptID: previous.id); await settle(store)
        #expect(revealed == nil && store.errorMessage == InstallerTrashFailure.unsafeRecovery.errorDescription)
        #expect(await executor.revealCount == 1)
        // Only a subsequent validated listing can restore the review affordance.
        await executor.setRecoveryPresent(true)
        store.loadRecovery(); await settle(store)
        #expect(store.receipts.count == 1 && store.restorePlan == nil)
        store.confirmRestore(planID: stalePlan.id)
        #expect(await executor.restoreCount == 0)
    }

    @Test("A vanished recovery record does not erase the actual completed mutation receipt")
    func vanishedRecoveryPreservesSessionOutcome() async throws {
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        try context(store); store.select(path: selected); store.prepare(); await settle(store)
        let plan = try #require(store.plan)
        store.attestInstallationFinished(true, planID: plan.id); store.confirm(planID: plan.id); await settle(store)
        let outcomeReceipt = try #require(store.lastOutcome?.receipt)
        await executor.setRecoveryPresent(false)
        store.loadRecovery(); await settle(store)
        #expect(store.lastOutcome?.receipt == outcomeReceipt)
        #expect(store.recoveryItems.count == 1 && store.recoveryItems.first?.receipt == nil)
        #expect(store.receipts.isEmpty)
        store.prepareRestore(receiptID: outcomeReceipt.id)
        #expect(await executor.prepareRestoreCount == 0)
    }

    @Test("Recovery works without live analysis and binds the fresh project protection context")
    func recoveryWithoutLiveAnalysis() async throws {
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        store.updateContext(liveAnalysisID: nil, result: nil, isDemoEnabled: false,
                            protectedPaths: ["/Synthetic/Project"], catalogIsKnown: true)
        store.loadRecovery(); await settle(store)
        store.prepareRestore(receiptID: try #require(store.receipts.first?.id)); await settle(store)
        let plan = try #require(store.restorePlan)
        #expect(plan.context.protectedPaths == ["/Synthetic/Project"])
        store.confirmRestore(planID: plan.id); await settle(store)
        #expect(await executor.restoreCount == 1)
    }

    @Test("Control characters and bidi filename markers display as one quoted path without altering selection")
    func escapedPath() async throws {
        // Direct scalars below ensure the fixture contains actual controls.
        let unusual = downloads.appendingPathComponent("quoted\"\\\n\t\r\u{202E}image.dmg").path
        let displayed = InstallerPathDisplay.quoted(unusual)
        #expect(displayed.hasPrefix("\"") && displayed.hasSuffix("\""))
        #expect(displayed.contains("\\\"") && displayed.contains("\\\\"))
        #expect(displayed.contains("\\n") && displayed.contains("\\t") && displayed.contains("\\r"))
        #expect(displayed.contains("\\u{202E}"))
        #expect(!displayed.contains("\n") && !displayed.contains("\u{202E}"))
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        try context(store, entries: [entry(unusual)])
        store.select(path: unusual); store.prepare(); await settle(store)
        #expect(store.plan?.originalURL.path == unusual)
    }

    @Test("Workspace binds live UUID and catalog, while imported JSON invalidates live authority")
    func workspaceIntegration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-installer-store-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = TrashFixture()
        let store = InstallerTrashStore(executor: executor, downloadsURL: downloads)
        let analysis = MoleAnalysisStore(executor: StoreLiveAnalysisFixture(result: try reportResult()))
        let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), moleAnalysis: analysis, installerTrash: store)
        analysis.selectExecutable(URL(fileURLWithPath: "/Synthetic/Analyzer"), ticket: try #require(analysis.selectionTicket()))
        analysis.selectDirectory(downloads, ticket: try #require(analysis.selectionTicket()))
        analysis.prepare(); await settle(analysis)
        analysis.confirm(planID: try #require(analysis.plan?.id)); await settle(analysis)
        #expect(store.liveAnalysisID == analysis.liveResultID)
        store.select(path: selected); store.prepare(); await settle(store)
        let plan = try #require(store.plan)
        workspace.projects = [ProjectRecord(name: "Project", path: "/Synthetic/Project", kind: .folder)]
        #expect(store.plan == nil)
        store.select(path: selected); store.prepare(); await settle(store)
        #expect(store.plan?.scope.protectedPaths == ["/Synthetic/Project"])
        workspace.importedReport = try reportResult().report
        #expect(analysis.result == nil && analysis.liveResultID == nil && store.liveAnalysisID == nil)
        store.confirm(planID: plan.id)
        store.select(path: selected); store.prepare()
        #expect(await executor.moveCount == 0)
        #expect(!store.canPrepare)
    }

    private func context(_ store: InstallerTrashStore, id: UUID = UUID(), demo: Bool = false, known: Bool = true,
                         entries: [[String: Any]]? = nil, protected: [String] = [], status: String = "complete") throws {
        store.updateContext(liveAnalysisID: id, result: try reportResult(entries: entries, status: status), isDemoEnabled: demo,
                            protectedPaths: protected, catalogIsKnown: known)
    }
    private func reportResult(directory: URL? = nil, entries: [[String: Any]]? = nil, status: String = "complete") throws -> MoleAnalysisResult {
        let directory = directory ?? downloads
        let data = try JSONSerialization.data(withJSONObject: ["path": directory.path, "overview": false, "scan_status": status,
                                                               "total_size": 1024, "entries": entries ?? [entry(selected)]])
        return MoleAnalysisResult(report: try JSONDecoder().decode(MoleAnalyzeReport.self, from: data), directory: directory,
                                  release: .native, startedAt: Date(), finishedAt: Date())
    }
    private func entry(_ path: String, directory: Bool = false, status: String = "complete", insight: Bool = false) -> [String: Any] {
        ["path": path, "name": URL(fileURLWithPath: path).lastPathComponent, "is_dir": directory, "scan_status": status,
         "size": 1024, "insight": insight]
    }
    private func settle(_ store: InstallerTrashStore) async { await wait { !store.isBusy } }
    private func settle(_ store: MoleAnalysisStore) async { await wait { !store.isBusy } }
    private func wait(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<2000 { if predicate() { return }; await Task.yield() }
        Issue.record("Fixture state did not settle")
    }
}

private actor TrashFixture: InstallerTrashExecuting {
    var prepareCount = 0; var moveCount = 0; var recoveryCount = 0; var restoreCount = 0; var revealCount = 0; var prepareRestoreCount = 0
    private let holdPrepare: Bool; private let holdMove: Bool; private let holdRestore: Bool; private let includeIncomplete: Bool
    private var prepareWaiter: CheckedContinuation<Void, Never>?
    private var moveWaiter: CheckedContinuation<Void, Never>?
    private var restoreWaiter: CheckedContinuation<Void, Never>?
    private let receiptID = UUID()
    private let incompleteID = UUID()
    private var pendingPlans: Set<UUID> = []
    private var recoveryPresent = true
    func setRecoveryPresent(_ present: Bool) { recoveryPresent = present }
    init(holdPrepare: Bool = false, holdMove: Bool = false, holdRestore: Bool = false, includeIncomplete: Bool = false) {
        self.holdPrepare = holdPrepare; self.holdMove = holdMove; self.holdRestore = holdRestore; self.includeIncomplete = includeIncomplete
    }
    func prepare(selection: URL, scope: InstallerTrashScope) async throws -> InstallerTrashPlan {
        prepareCount += 1
        if holdPrepare { await withCheckedContinuation { prepareWaiter = $0 } }
        let id = UUID(); pendingPlans.insert(id)
        return InstallerTrashPlan(id: id, scope: scope, originalURL: selection, downloadsURL: scope.liveDirectory,
                                  recoveryURL: URL(fileURLWithPath: "/Synthetic/Recovery/\(receiptID)"), file: Self.file,
                                  preparedAt: Date(), expiresAt: Date().addingTimeInterval(120))
    }
    func discardPlans() async { pendingPlans = [] }
    func moveToTrash(planID: UUID, scope: InstallerTrashScope) async throws -> InstallerTrashOutcome {
        guard pendingPlans.remove(planID) != nil else { throw InstallerTrashFailure.expired }
        moveCount += 1
        if holdMove { await withCheckedContinuation { moveWaiter = $0 } }
        return InstallerTrashOutcome(receipt: receipt(.trashed), message: "Synthetic Trash result", movedToTrash: true, requiresRecovery: false)
    }
    func recoveryReceipts() async throws -> [InstallerRecoveryItem] {
        recoveryCount += 1
        guard recoveryPresent else { return [] }
        let receipt = receipt(.trashed)
        var items = [InstallerRecoveryItem(id: receipt.id, operationURL: receipt.operationURL, receipt: receipt, issue: nil)]
        if includeIncomplete {
            items.append(InstallerRecoveryItem(id: incompleteID, operationURL: URL(fileURLWithPath: "/Synthetic/Recovery/\(incompleteID)"), receipt: nil, issue: "Synthetic incomplete record"))
        }
        return items
    }
    func validatedRecoveryLocation(receiptID: UUID) async throws -> URL {
        revealCount += 1
        guard recoveryPresent else { throw InstallerTrashFailure.unsafeRecovery }
        if includeIncomplete, receiptID == incompleteID { return URL(fileURLWithPath: "/Synthetic/Recovery/\(incompleteID)") }
        guard receiptID == self.receiptID else { throw InstallerTrashFailure.unsafeRecovery }
        return receipt(.trashed).trashURL!
    }
    func prepareRestore(receiptID: UUID, context: InstallerRecoveryContext) async throws -> InstallerRestorePlan {
        prepareRestoreCount += 1
        guard receiptID == self.receiptID else { throw InstallerTrashFailure.unsafeRecovery }
        let id = UUID(); pendingPlans.insert(id)
        return InstallerRestorePlan(id: id, receipt: receipt(.trashed), sourceURL: receipt(.trashed).trashURL!, context: context,
                                    preparedAt: Date(), expiresAt: Date().addingTimeInterval(120))
    }
    func restore(planID: UUID, context: InstallerRecoveryContext) async throws -> InstallerTrashOutcome {
        guard pendingPlans.remove(planID) != nil else { throw InstallerTrashFailure.expired }
        restoreCount += 1
        if holdRestore { await withCheckedContinuation { restoreWaiter = $0 } }
        return InstallerTrashOutcome(receipt: receipt(.restored), message: "Synthetic restore result", movedToTrash: false, requiresRecovery: false)
    }
    func waitForPrepare() async { for _ in 0..<2000 { if prepareWaiter != nil { return }; await Task.yield() }; Issue.record("Preparation did not enter fixture") }
    func waitForMove() async { for _ in 0..<2000 { if moveWaiter != nil { return }; await Task.yield() }; Issue.record("Move did not enter fixture") }
    func waitForRestore() async { for _ in 0..<2000 { if restoreWaiter != nil { return }; await Task.yield() }; Issue.record("Restore did not enter fixture") }
    func releasePrepare() { prepareWaiter?.resume(); prepareWaiter = nil }
    func releaseMove() { moveWaiter?.resume(); moveWaiter = nil }
    func releaseRestore() { restoreWaiter?.resume(); restoreWaiter = nil }
    private func receipt(_ state: InstallerReceiptState) -> InstallerTrashReceipt {
        InstallerTrashReceipt(policy: InstallerTrashReceipt.policyVersion, id: receiptID, sequence: state == .restored ? 6 : 3,
            originalURL: URL(fileURLWithPath: "/Synthetic/Downloads/Installer.dmg"), originalParent: Self.file, originalFile: Self.file,
            operationURL: URL(fileURLWithPath: "/Synthetic/Recovery/\(receiptID)"), operationDirectory: Self.file,
            state: state, recordedAt: Date(), payloadName: nil, trashURL: URL(fileURLWithPath: "/Synthetic/Trash/Installer.dmg"), trashFile: Self.file)
    }
    private static let file = InstallerFileSnapshot(device: 1, inode: 2, mode: 0o100600, uid: 501, gid: 20, links: 1, flags: 0,
                                                    bytes: 1024, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
}

private final class TrashClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; date = value }
}

private struct StoreLiveAnalysisFixture: MoleAnalysisExecuting {
    let result: MoleAnalysisResult
    func prepare(executable: URL, directory: URL) async throws -> MoleAnalysisPlan {
        MoleAnalysisPlan(id: UUID(), executable: executable, directory: directory,
                         executableIdentity: MoleFileIdentity(device: 1, inode: 2), directoryIdentity: MoleFileIdentity(device: 1, inode: 3),
                         release: .native, preparedAt: Date(), privateSessionParent: URL(fileURLWithPath: "/Synthetic/Cache"))
    }
    func run(_ plan: MoleAnalysisPlan) async throws -> MoleAnalysisResult { result }
}
