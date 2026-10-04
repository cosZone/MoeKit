import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Exact process termination confirmation")
struct ProcessTerminationTests {
    @Test("Real/effective/saved user/group IDs and set-ID history are all required")
    func credentials() {
        var ordinary = proc_bsdinfo()
        ordinary.pbi_uid = 501; ordinary.pbi_ruid = 501; ordinary.pbi_svuid = 501
        ordinary.pbi_gid = 20; ordinary.pbi_rgid = 20; ordinary.pbi_svgid = 20
        #expect(NativeProcessCredentials.read(ordinary).isOrdinary(uid: 501, gid: 20))
        for field in 0..<7 {
            var changed = ordinary
            switch field {
            case 0: changed.pbi_uid = 0
            case 1: changed.pbi_ruid = 0
            case 2: changed.pbi_svuid = 0
            case 3: changed.pbi_gid = 0
            case 4: changed.pbi_rgid = 0
            case 5: changed.pbi_svgid = 0
            default: changed.pbi_flags = UInt32(PROC_FLAG_PSUGID)
            }
            #expect(!NativeProcessCredentials.read(changed).isOrdinary(uid: 501, gid: 20))
        }
    }

    @Test("Expiry and revocation during final adapter inspection refuse submission", arguments: [false, true])
    func finalSinkGuard(revoke: Bool) async throws {
        let system = GatedStopSystem(holdSignal: true)
        let clock = StopFixtureClock()
        let executor = ProcessTerminationExecutor(system: system, now: { clock.read() })
        let review = try await executor.prepare(records: [stopFixture()], mode: .graceful)
        let run = Task { try await executor.execute(reviewID: review.id) }
        for _ in 0..<200 {
            if await system.isHeld { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await system.isHeld)
        if revoke { await executor.invalidate() } else { clock.advance(61) }
        await system.resume()
        let results = try await run.value
        #expect(await system.signals == 0)
        #expect(results.first?.signalSubmitted == false)
    }

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
            let system = FakeTerminationSystem(records: [row])
            let executor = ProcessTerminationExecutor(system: system)
            await #expect(throws: ProcessTerminationError.protectedTarget) { try await executor.prepare(records: [row], mode: .graceful) }
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
    @Test("Reset after submission retains ownership and actual outcome until settlement")
    func resetAfterSubmission() async throws {
        let system = GatedStopSystem(holdSignal: false)
        let store = ProcessTerminationStore(executor: ProcessTerminationExecutor(system: system))
        store.prepare([stopFixture()], mode: .graceful)
        try await settle { store.review != nil }
        let id = try #require(store.review?.id)
        store.acknowledge(reviewID: id, value: true)
        store.confirm(reviewID: id)
        for _ in 0..<200 {
            if await system.isHeld { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await system.signals == 1)
        store.reset()
        #expect(store.isBusy)
        #expect(store.isExecuting)
        store.prepare([stopFixture()], mode: .graceful)
        #expect(store.review == nil)
        await system.resume()
        try await settle { !store.isBusy }
        #expect(store.results.first?.signalSubmitted == true)
        #expect(store.results.first?.presence == .exited)
        #expect(store.forceCandidates.isEmpty)
        store.reset()
        #expect(store.results.count == 1)
    }

    @Test("Acknowledgement is exact-nonce authority and never carries to a replacement review")
    func nonceAcknowledgement() async throws {
        let system = FakeTerminationSystem()
        let store = ProcessTerminationStore(executor: ProcessTerminationExecutor(system: system))
        store.prepare([stopFixture()], mode: .graceful)
        try await settle { store.review != nil }
        let old = try #require(store.review?.id)
        store.acknowledge(reviewID: old, value: true)
        store.prepare([stopFixture()], mode: .graceful)
        try await settle { store.review != nil }
        let fresh = try #require(store.review?.id)
        #expect(fresh != old)
        #expect(store.acknowledgedReviewID == nil)
        store.acknowledge(reviewID: old, value: true)
        store.confirm(reviewID: old)
        store.confirm(reviewID: fresh)
        #expect(await system.sent.isEmpty)
        store.acknowledge(reviewID: fresh, value: true)
        store.confirm(reviewID: fresh)
        try await settle { !store.isBusy }
        #expect(await system.sent.count == 1)
    }

    @Test("Mode reset during preparation or final preflight cannot send late signals", arguments: [1, 2])
    func latePreflight(blockAt: Int) async throws {
        let system = BlockingTerminationSystem(blockAt: blockAt)
        let store = ProcessTerminationStore(executor: ProcessTerminationExecutor(system: system))
        store.prepare([stopFixture()], mode: .graceful)
        if blockAt == 2 {
            try await settle { store.review != nil }
            let id = try #require(store.review?.id)
            store.acknowledge(reviewID: id, value: true)
            store.confirm(reviewID: id)
        }
        for _ in 0..<200 {
            if await system.isBlocked { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await system.isBlocked)
        store.reset()
        await system.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(await system.signals == 0)
        #expect(store.review == nil)
        #expect(store.results.isEmpty)
        #expect(!store.isBusy)
    }

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
        store.acknowledge(reviewID: id, value: true)
        store.confirm(reviewID: id)
        store.confirm(reviewID: id)
        try await settle { !store.isBusy }
        #expect(await system.sent.count == 1)
        #expect(store.results.count == 1)
        store.reset()
        #expect(store.review == nil)
        #expect(store.results.count == 1)
        store.prepare([stopFixture(pid: 102)], mode: .graceful)
        try await settle { store.review != nil }
        let next = try #require(store.review?.id)
        #expect(store.review?.records.first?.identity.pid == 102)
        #expect(store.acknowledgedReviewID == nil)
        store.acknowledge(reviewID: next, value: true)
        store.confirm(reviewID: next)
        try await settle { !store.isBusy }
        #expect(await system.sent.map(\.pid) == [101, 102])
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
    private let fixtureRows: [ProcessInventoryRecord]?
    init(records: [ProcessInventoryRecord]? = nil) { fixtureRows = records }
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
            replacement ?? fixtureRows?.first(where: { $0.identity == identity }) ?? stopFixture(pid: identity.pid, uid: identity.uid ?? 501, path: identity.executablePath ?? "/tmp/worker", version: identity.executionVersion)
        }, currentUID: 501, observerPID: 900, isPartial: partial, currentGID: 20)
    }
    func signal(_ record: ProcessInventoryRecord, mode: ProcessStopMode, authority: ProcessSignalAuthority) async throws {
        if record.identity == failIdentity { throw ProcessTerminationError.unavailable }
        try authority.submit { sent.append(record.identity); modes.append(mode) }
    }
    func presence(of identity: ProcessIdentity) async -> ProcessPresence { running ? .running : .exited }
}

private func stopFixture(pid: Int32 = 101, uid: UInt32 = 501, name: String = "worker", path: String = "/tmp/worker",
                         version: UInt32? = 7, cwd: String = "/tmp/project") -> ProcessInventoryRecord {
    ProcessInventoryRecord(identity: ProcessIdentity(pid: pid, startSeconds: 1_700_000_000, startMicroseconds: 7,
        uid: uid, executablePath: path, executionVersion: version), name: name,
        parentPID: 42, processGroupID: 42, workingDirectory: cwd, listeningPorts: [],
        credentials: ProcessCredentials(realUID: uid, effectiveUID: uid, savedUID: uid,
            realGID: 20, effectiveGID: 20, savedGID: 20, hasSetIDHistory: false))
}

private final class StopFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func read() -> TimeInterval { lock.withLock { time } }
    func advance(_ value: TimeInterval) { lock.withLock { time += value } }
}

private actor BlockingTerminationSystem: ProcessTerminationSystem {
    let blockAt: Int
    var calls = 0
    var signals = 0
    var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(blockAt: Int) { self.blockAt = blockAt }
    func inspect(_ identities: [ProcessIdentity]) async throws -> ProcessSnapshot {
        calls += 1
        if calls == blockAt {
            isBlocked = true
            await withCheckedContinuation { continuation = $0 }
        }
        return ProcessSnapshot(records: [stopFixture()], currentUID: 501, observerPID: 900, currentGID: 20)
    }
    func resume() { continuation?.resume(); continuation = nil }
    func signal(_ record: ProcessInventoryRecord, mode: ProcessStopMode, authority: ProcessSignalAuthority) async throws { try authority.submit { signals += 1 } }
    func presence(of identity: ProcessIdentity) async -> ProcessPresence { .exited }
}

private actor GatedStopSystem: ProcessTerminationSystem {
    let holdSignal: Bool
    var signals = 0
    var isHeld = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(holdSignal: Bool) { self.holdSignal = holdSignal }
    func inspect(_ identities: [ProcessIdentity]) async throws -> ProcessSnapshot {
        ProcessSnapshot(records: [stopFixture()], currentUID: 501, observerPID: 900, currentGID: 20)
    }
    func signal(_ record: ProcessInventoryRecord, mode: ProcessStopMode, authority: ProcessSignalAuthority) async throws {
        if holdSignal { await hold() }
        try authority.submit { signals += 1 }
    }
    func presence(of identity: ProcessIdentity) async -> ProcessPresence {
        if !holdSignal { await hold() }
        return .exited
    }
    private func hold() async {
        isHeld = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
