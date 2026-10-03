import Foundation
import Testing
@testable import MoeKit

@Suite("Read-only process scan coordination") @MainActor
struct ProcessInventoryStoreTests {
    @Test("Construction and project navigation do not scan")
    func explicitScanOnly() async {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider)
        store.openProject(ProjectRecord(name: "Fixture", path: "/fixture", kind: .folder), projects: [])
        #expect(await provider.scanCount == 0)
        #expect(store.snapshot == nil)
        #expect(store.selection.isEmpty)
    }

    @Test("Repeated start during scan produces one request")
    func oneActiveScan() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        store.startScan(projects: [])
        #expect(await provider.scanCount == 1)
        await provider.complete(Self.snapshot())
        try await settle { !store.isScanning }
        #expect(store.snapshot?.records.count == 2)
    }

    @Test("Mode changes discard in-flight results even if provider ignores cancellation")
    func modeBoundary() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        var finished = 0
        store.onEvent = { if case .finished = $0 { finished += 1 } }
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        store.resetForModeChange()
        await provider.complete(Self.snapshot())
        // Let the cancelled task return from its controlled continuation.
        for _ in 0..<50 { await Task.yield() }
        #expect(!store.isScanning)
        #expect(store.snapshot == nil)
        #expect(store.projects.isEmpty)
        #expect(store.selection.isEmpty)
        #expect(store.plan == nil)
        #expect(finished == 1)
    }

    @Test("Search changes remove hidden selections and invalidate inspection")
    func selectionFiltering() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        let snapshot = Self.snapshot()
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.complete(snapshot)
        try await settle { !store.isScanning }
        store.selection = Set(snapshot.records.map(\.identity))
        store.reviewSelection()
        #expect(store.plan?.targets.count == 2)
        store.search = "first"
        #expect(store.selection == [snapshot.records[0].identity])
        #expect(store.plan == nil)
        store.reviewSelection()
        #expect(store.plan?.targets.count == 1)
        store.search = "first "
        #expect(store.selection == [snapshot.records[0].identity])
        #expect(store.plan == nil)
        store.reviewSelection()
        #expect(store.plan?.targets.count == 1)
        store.projectFilterID = UUID()
        #expect(store.selection.isEmpty)
        #expect(store.plan == nil)
    }

    @Test("Refresh clears old selection and stop preview before reading")
    func refreshInvalidatesPlan() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        let snapshot = Self.snapshot()
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.complete(snapshot)
        try await settle { !store.isScanning }
        store.selection = [snapshot.records[0].identity]
        store.reviewSelection()
        #expect(store.plan != nil)
        store.startScan(projects: [])
        #expect(store.selection.isEmpty)
        #expect(store.plan == nil)
        await provider.waitUntilStarted()
        store.cancel()
        await provider.complete(snapshot)
    }

    @Test("Short refresh bursts are bounded without a polling timer")
    func refreshBound() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 60)
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.complete(Self.snapshot())
        try await settle { !store.isScanning }
        store.startScan(projects: [])
        #expect(await provider.scanCount == 1)
        #expect(!store.isScanning)
        #expect(store.errorMessage != nil)
    }

    @Test("Partial snapshot is visible and reported as partial")
    func partialSnapshot() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider)
        var result: TaskStatus?
        store.onEvent = { if case let .finished(_, status, _) = $0 { result = status } }
        var snapshot = Self.snapshot()
        snapshot.isPartial = true
        snapshot.issues = ["Synthetic unreadable metadata"]
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.complete(snapshot)
        try await settle { !store.isScanning }
        #expect(result == .partial)
        #expect(store.snapshot?.isPartial == true)
        #expect(store.snapshot?.issues == snapshot.issues)
    }

    private static func snapshot() -> ProcessSnapshot {
        let records = ["first", "second"].enumerated().map { index, name in
            ProcessInventoryRecord(identity: ProcessIdentity(pid: Int32(100 + index), startSeconds: 1_700_000_000,
                startMicroseconds: 1, uid: 501, executablePath: "/fixture/\(name)"), name: name,
                parentPID: 10, processGroupID: Int32(100 + index), workingDirectory: nil, listeningPorts: [])
        }
        return ProcessSnapshot(records: records, currentUID: 501, observerPID: 999)
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "Coordinator did not settle after the synthetic provider completed")
    }
}

/// Intentionally ignores cancellation until the test supplies a result, proving
/// the coordinator rejects obsolete replies independently of provider behavior.
private actor ControlledProcessProvider: ProcessInventoryProviding {
    private var pending: CheckedContinuation<ProcessSnapshot, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var scanCount = 0

    func scan(options: ProcessScanOptions) async throws -> ProcessSnapshot {
        scanCount += 1
        return await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete(_ snapshot: ProcessSnapshot) {
        let continuation = pending; pending = nil
        continuation?.resume(returning: snapshot)
    }
}
