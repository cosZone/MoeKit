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

    @Test("Port filters constrain selected identities and invalidate an open preview")
    func portFilterSelection() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        let snapshot = Self.portSnapshot()
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.complete(snapshot)
        try await settle { !store.isScanning }
        store.selection = Set(snapshot.records.map(\.identity))
        store.reviewSelection()
        #expect(store.plan?.targets.count == 3)
        store.portFilter = .listening
        #expect(store.rows.map(\.name) == ["listener"])
        #expect(store.selection == [snapshot.records[0].identity])
        #expect(store.plan == nil)
        #expect(store.count(for: .all) == 3)
        #expect(store.count(for: .listening) == 1)
        #expect(store.count(for: .unknown) == 1)
        store.reviewSelection()
        store.portFilter = .all
        #expect(store.plan == nil)
        #expect(store.selection == [snapshot.records[0].identity])
        store.portFilter = .unknown
        #expect(store.rows.map(\.name) == ["unknown"])
        #expect(store.selection.isEmpty)
        store.clearFilters()
        #expect(store.rows.count == 3)
        #expect(!store.hasActiveFilters)
    }

    @Test("Search includes local addresses and transport without reading command arguments")
    func portSearch() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.complete(Self.portSnapshot())
        try await settle { !store.isScanning }
        for query in ["::1", "TCP 3000", "listener ::1 3000"] {
            store.search = query
            #expect(store.rows.map(\.name) == ["listener"])
            #expect(store.count(for: .all) == 1)
            #expect(store.count(for: .unknown) == 0)
        }
        store.search = "3001"
        #expect(store.rows.isEmpty)
    }

    @Test("Cancelled refresh retains the previous snapshot with an explicit notice")
    func cancelledRefresh() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        let previous = Self.snapshot()
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.complete(previous)
        try await settle { !store.isScanning }
        #expect(store.retainedSnapshotNotice == nil)
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        #expect(store.retainedSnapshotNotice != nil)
        store.cancel()
        #expect(store.lastScanStatus == .cancelled)
        #expect(store.snapshot?.id == previous.id)
        #expect(store.retainedSnapshotNotice == String(localized: "Refresh cancelled. Showing the previous snapshot; these rows were not refreshed."))
        await provider.complete(Self.portSnapshot())
        for _ in 0..<50 { await Task.yield() }
        #expect(store.snapshot?.id == previous.id)
        #expect(store.lastScanStatus == .cancelled)
    }

    @Test("Failed refresh exposes retained data and a successful retry replaces it")
    func failedRefreshThenRetry() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        let previous = Self.snapshot()
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.complete(previous)
        try await settle { !store.isScanning }
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.fail()
        try await settle { !store.isScanning }
        #expect(store.lastScanStatus == .failed)
        #expect(store.snapshot?.id == previous.id)
        #expect(store.errorMessage != nil)
        #expect(store.retainedSnapshotNotice == String(localized: "Refresh failed. Showing the previous snapshot; these rows were not refreshed."))
        let replacement = Self.portSnapshot()
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        await provider.complete(replacement)
        try await settle { !store.isScanning }
        #expect(store.snapshot?.id == replacement.id)
        #expect(store.lastScanStatus == .completed)
        #expect(store.errorMessage == nil)
        #expect(store.retainedSnapshotNotice == nil)
    }

    @Test("A cancelled first scan cannot turn a late provider error into failure")
    func cancelledFirstScanIgnoresLateError() async throws {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        store.startScan(projects: [])
        await provider.waitUntilStarted()
        store.cancel()
        await provider.fail()
        for _ in 0..<50 { await Task.yield() }
        #expect(store.snapshot == nil)
        #expect(store.lastScanStatus == .cancelled)
        #expect(store.retainedSnapshotNotice == nil)
        #expect(store.errorMessage == nil)
        store.portFilter = .unknown
        store.resetForModeChange()
        #expect(store.lastScanStatus == nil)
        #expect(store.portFilter == .all)
        #expect(store.unavailableProjectCount == 0)
    }

    @Test("Project navigation clears a prior port filter without starting a scan")
    func projectNavigationClearsPortFilter() async {
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider)
        store.portFilter = .unknown
        store.search = "hidden"
        let project = ProjectRecord(name: "Fixture", path: "/fixture", kind: .folder)
        store.openProject(project, projects: [])
        #expect(store.portFilter == .all)
        #expect(store.search.isEmpty)
        #expect(store.projectFilterID == project.id)
        #expect(await provider.scanCount == 0)
    }

    @Test("Unavailable project roots remain visible without converting a valid process snapshot to empty")
    func unavailableProjectRoots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = [
            ProjectRecord(name: "Readable", path: root.path, kind: .folder),
            ProjectRecord(name: "Missing", path: root.appendingPathComponent("missing").path, kind: .folder),
            ProjectRecord(name: "Root", path: "/", kind: .folder),
            ProjectRecord(name: "Group", path: "", kind: .group)
        ]
        let provider = ControlledProcessProvider()
        let store = ProcessInventoryStore(provider: provider, minimumRefreshInterval: 0)
        store.startScan(projects: catalog)
        await provider.waitUntilStarted()
        await provider.complete(Self.snapshot())
        try await settle { !store.isScanning }
        #expect(store.projects.map(\.id) == [catalog[0].id])
        #expect(store.unavailableProjectCount == 2)
        #expect(store.rows.count == 2)
        #expect(store.lastScanStatus == .completed)
    }

    private static func portSnapshot() -> ProcessSnapshot {
        let ports: [[ListeningPort]?] = [[ListeningPort(port: 3_000, address: "::1", transport: "TCP")], [], nil]
        let records = ["listener", "empty", "unknown"].enumerated().map { index, name in
            ProcessInventoryRecord(identity: ProcessIdentity(pid: Int32(200 + index), startSeconds: 1_700_000_000,
                startMicroseconds: 1, uid: 501, executablePath: "/fixture/\(name)"), name: name,
                parentPID: 10, processGroupID: Int32(200 + index), workingDirectory: nil, listeningPorts: ports[index])
        }
        return ProcessSnapshot(records: records, currentUID: 501, observerPID: 999)
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
    private enum FixtureError: Error { case failed }
    private var pending: CheckedContinuation<ProcessSnapshot, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var scanCount = 0

    func scan(options: ProcessScanOptions) async throws -> ProcessSnapshot {
        scanCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func fail() {
        let continuation = pending; pending = nil
        continuation?.resume(throwing: FixtureError.failed)
    }
    func complete(_ snapshot: ProcessSnapshot) {
        let continuation = pending; pending = nil
        continuation?.resume(returning: snapshot)
    }
}
