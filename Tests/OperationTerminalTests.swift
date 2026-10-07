import AppKit
import Foundation
import Darwin
import Testing
@testable import MoeKit

@MainActor @Suite("Controlled Mole upgrade terminal")
struct OperationTerminalTests {
    @Test("Preparation and pending paste/feed never execute; Return consumes exactly one immutable plan")
    func enterGate() async throws {
        let runner = OperationTerminalFixture()
        let store = MoleUpgradeTerminalStore(executor: runner)
        #expect(await runner.starts == 0)
        store.prepare(source: .appleSiliconHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
        try await settlePreparation(store)
        let plan = try #require(store.plan)
        #expect(store.isReady)
        #expect(plan.commands == ["/opt/homebrew/bin/brew update", "/opt/homebrew/bin/brew upgrade --formula mole"])
        store.send(Data("\n\r/opt/homebrew/bin/brew upgrade --formula mole\r".utf8))
        #expect(await runner.starts == 0)
        store.handleUserReturn(planID: UUID())
        #expect(await runner.starts == 0)
        store.handleUserReturn(planID: plan.id)
        store.handleUserReturn(planID: plan.id)
        try await runner.waitForStart()
        #expect(await runner.starts == 1)
        #expect(store.blocksAppUpdate)
        await runner.complete(.completed); try await settleRun(store)
        #expect(store.outcome == .completed)
        #expect(!store.blocksAppUpdate)
        store.handleUserReturn(planID: plan.id)
        #expect(await runner.starts == 1)
        #expect(store.plan?.id == plan.id)
        store.prepare(source: .intelHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
        try await settlePreparation(store)
        #expect(store.plan?.id != plan.id)
        store.handleUserReturn(planID: plan.id)
        #expect(await runner.starts == 1)
    }

    @Test("Closing and reopening a pending terminal cannot reuse its review")
    func closePending() async throws {
        let runner = OperationTerminalFixture()
        let store = MoleUpgradeTerminalStore(executor: runner)
        store.prepare(source: .intelHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        try await settlePreparation(store)
        let plan = try #require(store.plan)
        store.cancel()
        store.handleUserReturn(planID: plan.id)
        #expect(await runner.starts == 0)
        #expect(!store.isReady)
    }

    @Test("Stop retains ownership until helper settles and preserves terminal output")
    func cancelActive() async throws {
        let runner = OperationTerminalFixture()
        let store = MoleUpgradeTerminalStore(executor: runner)
        store.prepare(source: .appleSiliconHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
        try await settlePreparation(store)
        store.handleUserReturn(planID: try #require(store.plan?.id))
        try await runner.waitForStart()
        store.send(Data([3]))
        #expect(await runner.takeInput().contains(3))
        let count = store.transcript.count
        store.cancel(); store.cancel()
        #expect(store.phase == .cancelling && store.isBusy && store.blocksAppUpdate)
        #expect(await runner.wasCancelled)
        await runner.complete(.cancelled); try await settleRun(store)
        #expect(store.outcome == .cancelled)
        #expect(store.transcript.count > count)
        #expect(String(decoding: store.transcript, as: UTF8.self).contains("synthetic output"))
    }

    @Test("Demo is inert; a rapid mode round trip rejects delayed real output and success")
    func demoBoundary() async throws {
        let runner = OperationTerminalFixture()
        let store = MoleUpgradeTerminalStore(executor: runner)
        store.setDemoEnabled(true)
        store.prepare(source: .appleSiliconHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        #expect(await runner.preparations == 0)
        // No mode switch itself starts a review or process.
        let real = MoleUpgradeTerminalStore(executor: runner)
        real.prepare(source: .appleSiliconHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        try await settlePreparation(real)
        real.handleUserReturn(planID: try #require(real.plan?.id)); try await runner.waitForStart()
        real.setDemoEnabled(true); real.setDemoEnabled(false)
        #expect(real.isBusy)
        await runner.emit("stale success output")
        await runner.complete(.completed); try await settleRun(real)
        #expect(real.outcome == .cancelled)
        #expect(real.transcript.isEmpty)
        #expect(await runner.starts == 1)
    }

    @Test("Cancelling preparation retains ownership and rejects a delayed review")
    func cancelPreparation() async throws {
        let fixture = OperationTerminalFixture(pausePreparation: true)
        let store = MoleUpgradeTerminalStore(executor: fixture)
        store.prepare(source: .appleSiliconHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        try await fixture.waitForPreparation()
        store.cancel()
        #expect(store.isBusy && store.phase == .cancelling)
        store.prepare(source: .intelHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        await fixture.completePreparation()
        try await settleRun(store)
        #expect(store.plan == nil)
        #expect(store.outcome == .cancelled)
        #expect(await fixture.preparations == 1)
        #expect(await fixture.starts == 0)
    }

    @Test("Releasing the coordinator cancels its owned session even after the view disappears")
    func releaseOwner() async throws {
        let fixture = OperationTerminalFixture()
        let safety = UpdateInstallationSafety()
        var store: MoleUpgradeTerminalStore? = MoleUpgradeTerminalStore(executor: fixture, updateSafety: safety)
        store?.prepare(source: .appleSiliconHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        try await settlePreparation(try #require(store))
        store?.handleUserReturn(planID: try #require(store?.plan?.id))
        try await fixture.waitForStart()
        #expect(!safety.canTerminate)
        weak var observed = store
        store = nil
        #expect(observed == nil)
        #expect(await fixture.wasCancelled)
        // The independently retained operation lease must outlive the store.
        #expect(!safety.canTerminate)
        await fixture.complete(.cancelled)
        try await waitUntil("operation lifetime lease") { safety.canTerminate }
        #expect(safety.canTerminate)
    }

    @Test("Only unmodified fresh focused keyDown Return qualifies")
    func keyboardBoundary() throws {
        func event(code: UInt16 = 36, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: code))
        }
        #expect(OperationTerminalKeyGate.accepts(try event(), hasTerminalFocus: true))
        #expect(OperationTerminalKeyGate.accepts(try event(code: 76, modifiers: .numericPad), hasTerminalFocus: true))
        #expect(!OperationTerminalKeyGate.accepts(try event(), hasTerminalFocus: false))
        #expect(!OperationTerminalKeyGate.accepts(try event(repeatKey: true), hasTerminalFocus: true))
        #expect(!OperationTerminalKeyGate.accepts(try event(type: .keyUp), hasTerminalFocus: true))
        #expect(!OperationTerminalKeyGate.accepts(try event(code: 9, modifiers: .command), hasTerminalFocus: true))
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift, .function] {
            #expect(!OperationTerminalKeyGate.accepts(try event(modifiers: flags), hasTerminalFocus: true))
        }
    }

    private func settlePreparation(_ store: MoleUpgradeTerminalStore) async throws {
        try await waitUntil("store preparation") { store.phase != .preparing }
    }
    private func settleRun(_ store: MoleUpgradeTerminalStore) async throws {
        try await waitUntil("store operation") { !store.isBusy }
    }
    private func waitUntil(_ stage: String, _ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while !predicate() {
            guard clock.now < deadline else { throw OperationTerminalFixtureFailure.timedOut(stage) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite("Operation terminal transport boundaries")
struct OperationTerminalTransportTests {
    @Test func statusDecoding() {
        func parse(_ text: String, _ code: Int32) -> OperationTerminalOutcome { OperationTerminalStatus.parse(Data(text.utf8), helperExit: code) }
        #expect(parse("MKOT1 PHASE update\nMKOT1 EXIT update 0\nMKOT1 PHASE upgrade\nMKOT1 EXIT upgrade 0\nMKOT1 RESULT 0\n", 0) == .completed)
        #expect(parse("MKOT1 PHASE update\nMKOT1 EXIT update 7\nMKOT1 RESULT 73\n", 73) == .failed(step: "update", exitCode: 7, signal: nil))
        #expect(parse("MKOT1 PHASE update\nMKOT1 SIGNAL update 2\nMKOT1 RESULT 73\n", 73) == .failed(step: "update", exitCode: nil, signal: 2))
        #expect(parse("MKOT1 PHASE update\nMKOT1 SIGNAL update 9\nMKOT1 RESULT 74\n", 74) == .cancelled)
        #expect(parse("MKOT1 PHASE update\nMKOT1 RESULT 74\n", 74) == .interrupted(code: 74))
        #expect(parse("MKOT1 PHASE update\nMKOT1 EXIT update 0\nMKOT1 RESULT 73\n", 73) == .interrupted(code: 73))
        #expect(parse("MKOT1 PHASE update\nMKOT1 EXIT update 0\nMKOT1 RESULT 0\n", 0) == .interrupted(code: 0))
        #expect(parse("MKOT1 RESULT 0\n", 0) == .interrupted(code: 0))
        #expect(parse("MKOT1 RESULT 74\nMKOT1 RESULT 0\n", 0) == .interrupted(code: 0))
        #expect(parse("MKOT1 PHASE update\nMKOT1 EXIT update 0\nMKOT1 RESULT 76\n", 76) == .interrupted(code: 76))
        #expect(parse("fake success", 0) == .interrupted(code: 0))
    }
    @Test func boundedFrames() {
        let input = OperationTerminalInput()
        input.setPhase(1)
        input.resize(columns: 200, rows: 30)
        #expect(input.send(Data([3])))
        #expect(input.takePending() == Data([82, 0, 0, 0, 4, 0, 30, 0, 200, 73, 0, 0, 0, 2, 1, 3]))
        #expect(!input.send(Data(repeating: 97, count: 64 * 1024)))
        #expect(input.takePending().isEmpty)
        input.cancel()
        #expect(!input.send(Data([13])))
        #expect(input.isCancelled)
    }
    @Test func inputIsBoundToItsOriginalCommandPhase() {
        let input = OperationTerminalInput()
        #expect(!input.send(Data([13])))
        input.setPhase(1)
        #expect(input.send(Data([65])))
        let partlyWrittenOldFrame = input.takePending()
        #expect(partlyWrittenOldFrame == Data([73, 0, 0, 0, 2, 1, 65]))
        #expect(input.send(Data([66])))
        input.setPhase(nil)
        #expect(input.takePending().isEmpty)
        input.setPhase(2)
        #expect(input.send(Data([67])))
        #expect(input.takePending() == Data([73, 0, 0, 0, 2, 2, 67]))
        #expect(partlyWrittenOldFrame[5] == 1) // cannot be relabelled as upgrade input
        #expect(OperationTerminalStatus.inputPhase(Data("MKOT1 PHASE up".utf8)) == nil)
        #expect(OperationTerminalStatus.inputPhase(Data("MKOT1 PHASE update\n".utf8)) == 1)
        #expect(OperationTerminalStatus.inputPhase(Data("MKOT1 PHASE update\nMKOT1 EXIT update 0\n".utf8)) == nil)
        #expect(OperationTerminalStatus.inputPhase(Data("MKOT1 PHASE update\nMKOT1 EXIT update 0\nMKOT1 PHASE upgrade\n".utf8)) == 2)
    }
    @Test func streamingControlsAreInert() {
        var filter = OperationTerminalOutputFilter()
        let malicious = "hello\u{1b}]52;c;c2VjcmV0\u{7}\u{1b}]7;file:///private\u{1b}\\\u{1b}]8;;https://example.com\u{7}link\u{1b}]8;;\u{7}\u{1b}PqIMAGE\u{1b}\\\u{1b}_GFILE\u{1b}\\\u{1b}[8;999;999t\u{1b}[31mred\u{1b}[0m\r\n中文"
        var actual = Data()
        for byte in malicious.utf8 { actual.append(filter.consume(Data([byte]))) }
        #expect(String(decoding: actual, as: UTF8.self) == "hellolink\u{1b}[31mred\u{1b}[0m\r\n中文")
        var oversized = OperationTerminalOutputFilter()
        #expect(oversized.consume(Data("\u{1b}[999999999999999999999999999999Ssafe".utf8)) == Data("safe".utf8))
    }
    @Test func sourceCannotBecomeArbitraryCommand() {
        #expect(MoleUpgradeSource(prefix: URL(fileURLWithPath: "/opt/homebrew")) == .appleSiliconHomebrew)
        #expect(MoleUpgradeSource(prefix: URL(fileURLWithPath: "/usr/local")) == .intelHomebrew)
        #expect(MoleUpgradeSource(prefix: URL(fileURLWithPath: "/tmp/brew")) == nil)
        #expect(MoleUpgradeSource(prefix: URL(string: "https://example.com/opt/homebrew")!) == nil)
    }
}

@Suite("Operation terminal fixture readiness")
struct OperationTerminalFixtureTests {
    @Test("Completion before run is delivered at the completion boundary")
    func earlyCompletionIsRemembered() async throws {
        let fixture = OperationTerminalFixture()
        let plan = await fixture.prepare(source: .appleSiliconHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        await fixture.complete(.completed)
        let invocation = Task {
            await fixture.run(plan, input: OperationTerminalInput()) { _ in }
        }
        try await fixture.waitForStart()
        #expect(await fixture.completionBoundaryReached)
        let stillWaiting = await fixture.isWaitingForCompletion
        #expect(!stillWaiting)
        if stillWaiting { await fixture.complete(.cancelled) } // bounded failure cleanup
        #expect(await invocation.value == .completed)
    }

    @Test("Run count does not signal readiness while output delivery is suspended")
    func completionDuringOutputIsRemembered() async throws {
        let fixture = OperationTerminalFixture()
        let plan = await fixture.prepare(source: .appleSiliconHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        let outputGate = OperationTerminalFixtureOutputGate()
        let invocation = Task {
            await fixture.run(plan, input: OperationTerminalInput()) { _ in await outputGate.suspend() }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while !(await outputGate.entered) {
            guard clock.now < deadline else {
                await outputGate.release(); await fixture.complete(.cancelled)
                throw OperationTerminalFixtureFailure.timedOut("blocked output entry")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.starts == 1)
        #expect(await fixture.completionBoundaryReached == false)
        await fixture.complete(.completed)
        #expect(await fixture.completionBoundaryReached == false)
        await outputGate.release()
        try await fixture.waitForStart()
        let stillWaiting = await fixture.isWaitingForCompletion
        #expect(!stillWaiting)
        if stillWaiting { await fixture.complete(.cancelled) }
        #expect(await invocation.value == .completed)
    }

    @Test("A missing start throws instead of returning apparent success")
    func missingStartThrows() async throws {
        let fixture = OperationTerminalFixture()
        do {
            try await fixture.waitForStart(timeout: .milliseconds(20))
            Issue.record("A fixture that never started reported readiness")
        } catch let error as OperationTerminalFixtureFailure {
            #expect(error == .timedOut("completion boundary"))
        }
        #expect(await fixture.starts == 0)
        #expect(await fixture.completionBoundaryReached == false)
    }
}

private actor OperationTerminalFixtureOutputGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func suspend() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

enum OperationTerminalFixtureFailure: Error, Equatable, CustomStringConvertible {
    case timedOut(String)
    var description: String {
        switch self { case .timedOut(let stage): "Timed out waiting for synthetic terminal \(stage)" }
    }
}

actor OperationTerminalFixture: MoleUpgradeExecuting {
    var preparations = 0
    var starts = 0
    private let pausePreparation: Bool
    private var preparation: CheckedContinuation<Void, Never>?
    private var preparationReleasedEarly = false
    private var preparationBoundaryReached = false
    init(pausePreparation: Bool = false) { self.pausePreparation = pausePreparation }
    private var input: OperationTerminalInput?
    private var output: (@Sendable (Data) async -> Void)?
    private var completion: CheckedContinuation<OperationTerminalOutcome, Never>?
    private var pendingCompletion: OperationTerminalOutcome?
    private(set) var completionBoundaryReached = false
    var isWaitingForCompletion: Bool { completion != nil }
    var wasCancelled: Bool { input?.isCancelled == true }
    func prepare(source: MoleUpgradeSource, currentVersion: String?, recommendedVersion: String) async -> MoleUpgradePlan {
        preparations += 1
        if pausePreparation {
            await withCheckedContinuation { continuation in
                preparationBoundaryReached = true
                if preparationReleasedEarly {
                    preparationReleasedEarly = false
                    continuation.resume()
                } else { preparation = continuation }
            }
        }
        return MoleUpgradePlan(id: UUID(), source: source, executable: source.executable, currentVersion: currentVersion,
            recommendedVersion: recommendedVersion,
            executableSnapshot: OperationExecutableSnapshot(device: 1, inode: 2, owner: 501, mode: 0o100755,
                size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5, changedSeconds: 6, changedNanoseconds: 7,
                sha256: String(repeating: "0", count: 64)),
            home: URL(fileURLWithPath: "/Synthetic/Home"), preparedAt: Date())
    }
    func run(_ plan: MoleUpgradePlan, input: OperationTerminalInput,
             onOutput: @escaping @Sendable (Data) async -> Void) async -> OperationTerminalOutcome {
        starts += 1; self.input = input; input.setPhase(1); output = onOutput
        completionBoundaryReached = false
        await onOutput(Data("\u{1b}[32msynthetic output\u{1b}[0m\r\n".utf8))
        return await withCheckedContinuation { continuation in
            // Starting run() is not readiness: its MainActor output callback may
            // still be pending. Publish readiness only at continuation setup.
            completionBoundaryReached = true
            if let result = pendingCompletion {
                pendingCompletion = nil
                continuation.resume(returning: result)
            } else { completion = continuation }
        }
    }
    func waitForPreparation(timeout: Duration = .seconds(6)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !preparationBoundaryReached {
            guard clock.now < deadline else {
                completePreparation()
                throw OperationTerminalFixtureFailure.timedOut("preparation boundary")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func completePreparation() {
        if let continuation = preparation {
            preparation = nil; continuation.resume()
        } else { preparationReleasedEarly = true }
    }
    func takeInput() -> Data { input?.takePending() ?? Data() }
    func emit(_ text: String) async { await output?(Data(text.utf8)) }
    func waitForStart(timeout: Duration = .seconds(6)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !completionBoundaryReached {
            guard clock.now < deadline else {
                complete(.cancelled)
                throw OperationTerminalFixtureFailure.timedOut("completion boundary")
            }
            // Real suspension lets the AppKit/MainActor output callback run.
            // A fixed number of Task.yield() calls is not a readiness timeout.
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func complete(_ result: OperationTerminalOutcome) {
        if let continuation = completion {
            completion = nil; continuation.resume(returning: result)
        } else { pendingCompletion = result }
    }
}

@Suite("Operation executable snapshot reads")
struct OperationTerminalFileTests {
    @Test func descriptorSnapshotRejectsChangesAndLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moekit-terminal-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned-script")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        #expect(chmod(file.path, 0o700) == 0)
        let first = try OperationExecutableVerifier.capture(file)
        #expect(first == (try OperationExecutableVerifier.capture(file)))
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file)
        #expect(first != (try OperationExecutableVerifier.capture(file)))
        let link = root.appendingPathComponent("final-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: OperationTerminalFailure.unsafeExecutable) { try OperationExecutableVerifier.capture(link) }
        #expect(chmod(file.path, 0o722) == 0)
        #expect(throws: OperationTerminalFailure.unsafeExecutable) { try OperationExecutableVerifier.capture(file) }
        #expect(throws: OperationTerminalFailure.unsafeExecutable) { try OperationExecutableVerifier.capture(root) }
    }
}
