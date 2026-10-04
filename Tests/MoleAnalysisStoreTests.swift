import Foundation
import Observation
import Testing
@testable import MoeKit

@MainActor @Suite("Mole explicit analysis state machine")
struct MoleAnalysisStoreTests {
    @Test("Busy state participates in observation")
    func busyObservation() async {
        let store = MoleAnalysisStore(executor: AnalysisFixture())
        store.selectExecutable(URL(fileURLWithPath: "/Analyzer"), ticket: store.selectionTicket()!)
        store.selectDirectory(URL(fileURLWithPath: "/Selected"), ticket: store.selectionTicket()!)
        let changed = MoleObservationFlag()
        withObservationTracking { _ = store.isBusy } onChange: { changed.set() }
        store.prepare()
        #expect(changed.value)
        await waitFor { !store.isBusy }
    }

    @Test("Selections never execute; only the current confirmation can execute once")
    func confirmation() async throws {
        let executor = AnalysisFixture()
        let store = MoleAnalysisStore(executor: executor)
        store.selectExecutable(URL(fileURLWithPath: "/Analyzer"), ticket: store.selectionTicket()!)
        store.selectDirectory(URL(fileURLWithPath: "/Selected"), ticket: store.selectionTicket()!)
        #expect(await executor.runCount == 0)
        store.confirm(planID: UUID())
        #expect(await executor.runCount == 0)
        store.prepare()
        await waitFor { !store.isBusy }
        let plan = try #require(store.plan)
        #expect(await executor.runCount == 0)
        store.confirm(planID: UUID())
        #expect(!store.isBusy)
        store.confirm(planID: plan.id)
        store.confirm(planID: plan.id)
        await waitFor { !store.isBusy }
        #expect(await executor.runCount == 1)
        #expect(store.result?.report.coverage == .partial)
    }

    @Test("Changing selection invalidates the pending confirmation")
    func stalePlan() async throws {
        let executor = AnalysisFixture()
        let store = MoleAnalysisStore(executor: executor)
        store.selectExecutable(URL(fileURLWithPath: "/Analyzer"), ticket: store.selectionTicket()!); store.selectDirectory(URL(fileURLWithPath: "/Selected"), ticket: store.selectionTicket()!)
        store.prepare(); await waitFor { !store.isBusy }
        let id = try #require(store.plan?.id)
        store.selectDirectory(URL(fileURLWithPath: "/Other"), ticket: store.selectionTicket()!)
        store.confirm(planID: id)
        #expect(await executor.runCount == 0)
        #expect(store.plan == nil)
    }

    @Test("Demo prevents preparation and execution")
    func demo() async {
        let executor = AnalysisFixture()
        let store = MoleAnalysisStore(executor: executor)
        store.selectExecutable(URL(fileURLWithPath: "/Analyzer"), ticket: store.selectionTicket()!); store.selectDirectory(URL(fileURLWithPath: "/Selected"), ticket: store.selectionTicket()!)
        store.setDemoEnabled(true); store.prepare()
        #expect(!store.isBusy)
        #expect(await executor.prepareCount == 0)
        #expect(await executor.runCount == 0)
    }

    @Test("Cancellation holds ownership and discards a provider's late success")
    func cancellation() async throws {
        let executor = AnalysisFixture(holdRun: true)
        let store = MoleAnalysisStore(executor: executor)
        store.selectExecutable(URL(fileURLWithPath: "/Analyzer"), ticket: store.selectionTicket()!); store.selectDirectory(URL(fileURLWithPath: "/Selected"), ticket: store.selectionTicket()!)
        store.prepare(); await waitFor { !store.isBusy }
        store.confirm(planID: try #require(store.plan?.id))
        await executor.waitUntilRunning()
        store.cancel()
        #expect(store.isBusy && store.isCancelling)
        store.prepare()
        await executor.releaseRun()
        await waitFor { !store.isBusy }
        #expect(store.result == nil)
        #expect(await executor.runCount == 1)
    }

    @Test("A rapid Demo round trip invalidates chooser and confirmation tickets")
    func demoRoundTrip() async throws {
        let executor = AnalysisFixture()
        let store = MoleAnalysisStore(executor: executor)
        let ticket = try #require(store.selectionTicket())
        store.setDemoEnabled(true); store.setDemoEnabled(false)
        store.selectExecutable(URL(fileURLWithPath: "/Analyzer"), ticket: ticket)
        #expect(store.executable == nil)
        store.selectExecutable(URL(fileURLWithPath: "/Analyzer"), ticket: store.selectionTicket()!)
        store.selectDirectory(URL(fileURLWithPath: "/Selected"), ticket: store.selectionTicket()!)
        store.prepare(); await waitFor { !store.isBusy }
        let plan = try #require(store.plan)
        store.setDemoEnabled(true)
        #expect(store.executable == nil && store.directory == nil && store.result == nil)
        store.setDemoEnabled(false)
        store.confirm(planID: plan.id)
        #expect(await executor.runCount == 0)
    }

    @Test("Execution failures remain failures, not zero-byte reports")
    func failure() async throws {
        let executor = AnalysisFixture(failure: .timeLimit)
        let store = MoleAnalysisStore(executor: executor)
        store.selectExecutable(URL(fileURLWithPath: "/Analyzer"), ticket: store.selectionTicket()!); store.selectDirectory(URL(fileURLWithPath: "/Selected"), ticket: store.selectionTicket()!)
        store.prepare(); await waitFor { !store.isBusy }
        store.confirm(planID: try #require(store.plan?.id)); await waitFor { !store.isBusy }
        #expect(store.result == nil)
        #expect(store.errorMessage == MoleAnalysisFailure.timeLimit.errorDescription)
    }

    private func waitFor(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("State did not settle")
    }
}

private actor AnalysisFixture: MoleAnalysisExecuting {
    var prepareCount = 0
    var runCount = 0
    private let holdRun: Bool
    private let failure: MoleAnalysisFailure?
    private var continuation: CheckedContinuation<Void, Never>?
    init(holdRun: Bool = false, failure: MoleAnalysisFailure? = nil) { self.holdRun = holdRun; self.failure = failure }
    func prepare(executable: URL, directory: URL) async throws -> MoleAnalysisPlan {
        prepareCount += 1
        return MoleAnalysisPlan(id: UUID(), executable: executable, directory: directory,
            executableIdentity: MoleFileIdentity(device: 1, inode: 2), directoryIdentity: MoleFileIdentity(device: 1, inode: 3),
            release: .native, preparedAt: Date(), privateSessionParent: URL(fileURLWithPath: "/Private"))
    }
    func run(_ plan: MoleAnalysisPlan) async throws -> MoleAnalysisResult {
        runCount += 1
        if holdRun { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        let data = Data("{\"path\":\"/Selected\",\"overview\":false,\"scan_status\":\"partial\",\"entries\":[],\"total_size\":0}".utf8)
        return MoleAnalysisResult(report: try JSONDecoder().decode(MoleAnalyzeReport.self, from: data), directory: plan.directory,
                                  release: plan.release, startedAt: Date(), finishedAt: Date())
    }
    func waitUntilRunning() async {
        for _ in 0..<1000 { if continuation != nil { return }; await Task.yield() }
    }
    func releaseRun() { continuation?.resume(); continuation = nil }
}

private final class MoleObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}
