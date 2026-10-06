import Foundation
import Testing
@testable import MoeKit

@MainActor @Suite("Beginner Mole setup lifecycle")
struct MoleSetupStoreTests {
    @Test("Construction and Demo never inspect tools; opening analysis checks once")
    func firstOpen() async throws {
        let provider = SetupDiscoveryFixture()
        let store = MoleAnalysisStore(discovery: provider)
        #expect(await provider.count == 0)
        store.setDemoEnabled(true); store.discoverIfNeeded()
        #expect(await provider.count == 0 && !store.isBusy)
        store.setDemoEnabled(false); store.discoverIfNeeded()
        await provider.waitForStart(); await provider.complete(.usable)
        await settle(store)
        #expect(store.installation?.state == .usable)
        #expect(store.executable?.path == "/Synthetic/analyze-go")
        #expect(!store.canPrepare)
        store.discoverIfNeeded()
        #expect(await provider.count == 1)
    }

    @Test("Recheck preserves folder choice but invalidates old analyzer and confirmation")
    func recheck() async throws {
        let provider = SetupDiscoveryFixture()
        let executor = SetupExecutorFixture()
        let store = MoleAnalysisStore(executor: executor, discovery: provider)
        store.selectExecutable(URL(fileURLWithPath: "/Synthetic/old"), ticket: try #require(store.selectionTicket()))
        store.selectDirectory(URL(fileURLWithPath: "/Synthetic/folder"), ticket: try #require(store.selectionTicket()))
        store.prepare(); await settle(store)
        let oldPlan = try #require(store.plan?.id)
        store.discoverInstalledAnalyzer()
        #expect(store.executable == nil && store.plan == nil && !store.canPrepare)
        #expect(store.directory?.path == "/Synthetic/folder")
        await provider.waitForStart(); await provider.complete(.incompatible)
        await settle(store)
        #expect(store.executable == nil && !store.canPrepare)
        store.confirm(planID: oldPlan)
        #expect(await executor.runCount == 0)
        store.discoverInstalledAnalyzer()
        await provider.waitForStart(); await provider.complete(.usable)
        await settle(store)
        #expect(store.canPrepare)
        #expect(await executor.runCount == 0)
    }

    @Test("Duplicate checks and close cancellation retain ownership and reject late success")
    func cancellation() async throws {
        let provider = SetupDiscoveryFixture()
        let store = MoleAnalysisStore(discovery: provider)
        store.discoverIfNeeded(); await provider.waitForStart()
        store.discoverInstalledAnalyzer(); store.cancel(); store.discoverInstalledAnalyzer()
        #expect(store.isDiscovering && store.isCancelling && store.isBusy)
        #expect(store.selectionTicket() == nil)
        #expect(await provider.count == 1)
        await provider.complete(.usable); await settle(store)
        #expect(store.installation == nil && store.executable == nil)
        store.discoverIfNeeded(); await provider.waitForStart()
        await provider.complete(.missing); await settle(store)
        #expect(store.installation?.state == .missing)
        #expect(await provider.count == 2)
    }

    @Test("A rapid Demo round trip cannot publish a real installation or reuse a chooser ticket")
    func demoBoundary() async throws {
        let provider = SetupDiscoveryFixture()
        let store = MoleAnalysisStore(discovery: provider)
        let oldTicket = try #require(store.selectionTicket())
        store.discoverInstalledAnalyzer(); await provider.waitForStart()
        store.setDemoEnabled(true); store.setDemoEnabled(false)
        await provider.complete(.usable); await settle(store)
        #expect(store.installation == nil && store.executable == nil)
        store.selectExecutable(URL(fileURLWithPath: "/Synthetic/stale"), ticket: oldTicket)
        #expect(store.executable == nil)
    }

    @Test("A manual choice is never labelled automatically verified")
    func manualSelection() async throws {
        let provider = SetupDiscoveryFixture()
        let store = MoleAnalysisStore(discovery: provider)
        store.discoverInstalledAnalyzer(); await provider.waitForStart()
        await provider.complete(.usable); await settle(store)
        store.selectExecutable(URL(fileURLWithPath: "/Synthetic/manual"), ticket: try #require(store.selectionTicket()))
        #expect(store.installation == nil)
        #expect(store.executable?.path == "/Synthetic/manual")
        store.discoverIfNeeded()
        #expect(await provider.count == 1)
    }

    private func settle(_ store: MoleAnalysisStore) async {
        for _ in 0..<1000 { if !store.isBusy { return }; await Task.yield() }
        Issue.record("Mole setup did not settle")
    }
}

private actor SetupDiscoveryFixture: MoleInstallationDiscovering {
    var count = 0
    private var continuation: CheckedContinuation<MoleInstallationReport, Never>?
    func discover() async throws -> MoleInstallationReport {
        count += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitForStart() async {
        for _ in 0..<1000 { if continuation != nil { return }; await Task.yield() }
        Issue.record("Discovery provider did not start")
    }
    func complete(_ state: MoleInstallationState) {
        continuation?.resume(returning: MoleInstallationReport(candidates: [
            MoleInstallationCandidate(path: "/Synthetic/analyze-go", state: state, source: "Synthetic", explanation: "Synthetic only")
        ], inspectedAt: Date()))
        continuation = nil
    }
}

private actor SetupExecutorFixture: MoleAnalysisExecuting {
    var runCount = 0
    func prepare(executable: URL, directory: URL) async throws -> MoleAnalysisPlan {
        MoleAnalysisPlan(id: UUID(), executable: executable, directory: directory,
                         executableIdentity: .init(device: 1, inode: 2), directoryIdentity: .init(device: 1, inode: 3),
                         release: .native, preparedAt: Date(), privateSessionParent: URL(fileURLWithPath: "/Synthetic/private"))
    }
    func run(_ plan: MoleAnalysisPlan) async throws -> MoleAnalysisResult {
        runCount += 1
        throw MoleAnalysisFailure.processFailed
    }
}
