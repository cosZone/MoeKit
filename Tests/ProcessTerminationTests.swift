import Foundation
import Testing
@testable import MoeKit

@Suite("Exact process termination confirmation")
struct ProcessTerminationTests {
    @Test("Control and direction markers cannot disguise confirmation identities")
    func escapedIdentity() {
        #expect(ProcessDisplayText.escape("/tmp/line\nname\u{202E}txt") == "/tmp/line\\u{A}name\\u{202E}txt")
        #expect(ProcessDisplayText.escape("/tmp/项目") == "/tmp/项目")
    }

    @Test("Preparation never sends; each confirmation is single use")
    func oneUse() async throws {
        let system = FakeTerminationSystem()
        let executor = ProcessTerminationExecutor(system: system)
        let row = stopFixture()
        let review = try await executor.prepare(records: [row], mode: .graceful)
        #expect(await system.sent.isEmpty)
        let results = try await executor.execute(reviewID: review.id)
        #expect(results.count == 1)
        #expect(results[0].signalSubmitted)
        #expect(results[0].presence == .exited)
        #expect(await system.sent == [row.identity])
        await #expect(throws: ProcessTerminationError.self) { try await executor.execute(reviewID: review.id) }
        #expect(await system.sent.count == 1)
    }

    @Test("An expired, invalidated or unknown nonce sends nothing")
    func invalidAuthority() async throws {
        let system = FakeTerminationSystem()
        let clock = StopFixtureClock()
        let executor = ProcessTerminationExecutor(system: system, now: { clock.read() })
        let review = try await executor.prepare(records: [stopFixture()], mode: .graceful)
        clock.advance(61)
        await #expect(throws: ProcessTerminationError.self) { try await executor.execute(reviewID: review.id) }
        let newer = try await executor.prepare(records: [stopFixture()], mode: .graceful)
        await executor.invalidate()
        await #expect(throws: ProcessTerminationError.self) { try await executor.execute(reviewID: newer.id) }
        await #expect(throws: ProcessTerminationError.self) { try await executor.execute(reviewID: UUID()) }
        #expect(await system.sent.isEmpty)
    }

    @Test("Empty, duplicate and broad selections are refused")
    func boundedSelection() async {
        let system = FakeTerminationSystem()
        let executor = ProcessTerminationExecutor(system: system)
        for records in [[], [stopFixture(), stopFixture()], (0..<17).map { stopFixture(pid: Int32(100 + $0)) }] {
            await #expect(throws: ProcessTerminationError.self) { try await executor.prepare(records: records, mode: .graceful) }
        }
        #expect(await system.sent.isEmpty)
    }

    @Test("Browser/application/system/self and foreign-owner rows cannot be confirmed")
    func protection() async {
        for row in [stopFixture(name: "Google Chrome", path: "/tmp/Google Chrome"),
                    stopFixture(path: "/Applications/Tool.app/Contents/MacOS/worker"),
                    stopFixture(path: "/usr/libexec/worker"), stopFixture(pid: 900), stopFixture(uid: 502),
                    stopFixture(name: "postgres"), stopFixture(path: "/bin/zsh")] {
            let system = FakeTerminationSystem()
            let executor = ProcessTerminationExecutor(system: system)
            await #expect(throws: ProcessTerminationError.self) { try await executor.prepare(records: [row], mode: .graceful) }
            #expect(await system.sent.isEmpty)
        }
    }

    @Test("Changed version, metadata, incomplete identity and partial reads fail closed")
    func identityAndCoverage() async throws {
        for replacement in [stopFixture(version: 8), stopFixture(path: "/tmp/replaced"), stopFixture(cwd: "/tmp/other"),
                            stopFixture(version: nil)] {
            let system = FakeTerminationSystem()
            let executor = ProcessTerminationExecutor(system: system)
            let review = try await executor.prepare(records: [stopFixture()], mode: .graceful)
            await system.replace(with: replacement)
            await #expect(throws: ProcessTerminationError.self) { try await executor.execute(reviewID: review.id) }
            #expect(await system.sent.isEmpty)
        }
        let system = FakeTerminationSystem()
        await system.makePartial()
        let executor = ProcessTerminationExecutor(system: system)
        await #expect(throws: ProcessTerminationError.self) { try await executor.prepare(records: [stopFixture()], mode: .graceful) }
    }

    @Test("No group, name or child expansion and per-target failure remains visible")
    func exactTargets() async throws {
        let first = stopFixture(pid: 101), second = stopFixture(pid: 102)
        let system = FakeTerminationSystem()
        await system.failSignal(for: second.identity)
        let executor = ProcessTerminationExecutor(system: system)
        let review = try await executor.prepare(records: [first, second], mode: .graceful)
        let result = try await executor.execute(reviewID: review.id)
        #expect(result.map(\.id) == [first.identity, second.identity])
        #expect(result[0].signalSubmitted)
        #expect(!result[1].signalSubmitted)
        #expect(await system.sent == [first.identity])
    }

    @Test("Force stop requires prior TERM, still-running identity and a new confirmation")
    func forceConfirmation() async throws {
        let system = FakeTerminationSystem()
        await system.remainRunning()
        let executor = ProcessTerminationExecutor(system: system)
        let row = stopFixture()
        await #expect(throws: ProcessTerminationError.self) { try await executor.prepare(records: [row], mode: .force) }
        let graceful = try await executor.prepare(records: [row], mode: .graceful)
        let result = try await executor.execute(reviewID: graceful.id)
        #expect(result[0].presence == .running)
        #expect(await system.modes == [.graceful])
        let force = try await executor.prepare(records: [row], mode: .force)
        #expect(await system.modes == [.graceful])
        _ = try await executor.execute(reviewID: force.id)
        #expect(await system.modes == [.graceful, .force])
    }
}

@Suite("Process stop UI coordination") @MainActor
struct ProcessTerminationStoreTests {
    @Test("Double confirm is consumed once; cancelling review never signals")
    func coordinator() async throws {
        let system = FakeTerminationSystem()
        let store = ProcessTerminationStore(executor: ProcessTerminationExecutor(system: system))
        store.prepare([stopFixture()], mode: .graceful)
        try await settle { store.review != nil }
        store.cancelReview()
        #expect(await system.sent.isEmpty)
        store.prepare([stopFixture()], mode: .graceful)
        try await settle { store.review != nil }
        let id = try #require(store.review?.id)
        store.confirm(reviewID: id)
        store.confirm(reviewID: id)
        try await settle { !store.isBusy }
        #expect(await system.sent.count == 1)
        #expect(store.results.count == 1)
        store.reset()
        #expect(store.review == nil)
        #expect(store.results.isEmpty)
    }

    private func settle(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Coordinator did not settle")
    }
}

private actor FakeTerminationSystem: ProcessTerminationSystem {
    var sent: [ProcessIdentity] = []
    var modes: [ProcessStopMode] = []
    private var replacement: ProcessInventoryRecord?
    private var partial = false
    private var running = false
    private var failIdentity: ProcessIdentity?
    func replace(with record: ProcessInventoryRecord) { replacement = record }
    func makePartial() { partial = true }
    func remainRunning() { running = true }
    func failSignal(for identity: ProcessIdentity) { failIdentity = identity }
    func inspect(_ identities: [ProcessIdentity]) async throws -> ProcessSnapshot {
        ProcessSnapshot(records: identities.map { identity in
            replacement ?? stopFixture(pid: identity.pid, uid: identity.uid ?? 501, path: identity.executablePath ?? "/tmp/worker", version: identity.executionVersion)
        }, currentUID: 501, observerPID: 900, isPartial: partial)
    }
    func signal(_ record: ProcessInventoryRecord, mode: ProcessStopMode) async throws {
        if record.identity == failIdentity { throw ProcessTerminationError.unavailable }
        sent.append(record.identity); modes.append(mode)
    }
    func presence(of identity: ProcessIdentity) async -> ProcessPresence { running ? .running : .exited }
}

private func stopFixture(pid: Int32 = 101, uid: UInt32 = 501, name: String = "worker", path: String = "/tmp/worker",
                         version: UInt32? = 7, cwd: String = "/tmp/project") -> ProcessInventoryRecord {
    ProcessInventoryRecord(identity: ProcessIdentity(pid: pid, startSeconds: 1_700_000_000, startMicroseconds: 7,
        uid: uid, executablePath: path, executionVersion: version), name: name,
        parentPID: 42, processGroupID: 42, workingDirectory: cwd, listeningPorts: [])
}

private final class StopFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func read() -> TimeInterval { lock.withLock { time } }
    func advance(_ value: TimeInterval) { lock.withLock { time += value } }
}
