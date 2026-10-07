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
        await settlePreparation(store)
        let plan = try #require(store.plan)
        #expect(store.isReady)
        #expect(plan.commands == ["/opt/homebrew/bin/brew update", "/opt/homebrew/bin/brew upgrade --formula mole"])
        store.send(Data("\n\r/opt/homebrew/bin/brew upgrade --formula mole\r".utf8))
        #expect(await runner.starts == 0)
        store.handleUserReturn(planID: UUID())
        #expect(await runner.starts == 0)
        store.handleUserReturn(planID: plan.id)
        store.handleUserReturn(planID: plan.id)
        await runner.waitForStart()
        #expect(await runner.starts == 1)
        #expect(store.blocksAppUpdate)
        await runner.complete(.completed); await settleRun(store)
        #expect(store.outcome == .completed)
        #expect(!store.blocksAppUpdate)
        store.handleUserReturn(planID: plan.id)
        #expect(await runner.starts == 1)
        #expect(store.plan?.id == plan.id)
        store.prepare(source: .intelHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
        await settlePreparation(store)
        #expect(store.plan?.id != plan.id)
        store.handleUserReturn(planID: plan.id)
        #expect(await runner.starts == 1)
    }

    @Test("Closing and reopening a pending terminal cannot reuse its review")
    func closePending() async throws {
        let runner = OperationTerminalFixture()
        let store = MoleUpgradeTerminalStore(executor: runner)
        store.prepare(source: .intelHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        await settlePreparation(store)
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
        await settlePreparation(store)
        store.handleUserReturn(planID: try #require(store.plan?.id))
        await runner.waitForStart()
        store.send(Data([3]))
        #expect(await runner.takeInput().contains(3))
        let count = store.transcript.count
        store.cancel(); store.cancel()
        #expect(store.phase == .cancelling && store.isBusy && store.blocksAppUpdate)
        #expect(await runner.wasCancelled)
        await runner.complete(.cancelled); await settleRun(store)
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
        await settlePreparation(real)
        real.handleUserReturn(planID: try #require(real.plan?.id)); await runner.waitForStart()
        real.setDemoEnabled(true); real.setDemoEnabled(false)
        #expect(real.isBusy)
        await runner.emit("stale success output")
        await runner.complete(.completed); await settleRun(real)
        #expect(real.outcome == .cancelled)
        #expect(real.transcript.isEmpty)
        #expect(await runner.starts == 1)
    }

    @Test("Cancelling preparation retains ownership and rejects a delayed review")
    func cancelPreparation() async {
        let fixture = OperationTerminalFixture(pausePreparation: true)
        let store = MoleUpgradeTerminalStore(executor: fixture)
        store.prepare(source: .appleSiliconHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        await fixture.waitForPreparation()
        store.cancel()
        #expect(store.isBusy && store.phase == .cancelling)
        store.prepare(source: .intelHomebrew, currentVersion: nil, recommendedVersion: "1.58.0")
        await fixture.completePreparation()
        await settleRun(store)
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
        await settlePreparation(try #require(store))
        store?.handleUserReturn(planID: try #require(store?.plan?.id))
        await fixture.waitForStart()
        #expect(!safety.canTerminate)
        weak var observed = store
        store = nil
        #expect(observed == nil)
        #expect(await fixture.wasCancelled)
        // The independently retained operation lease must outlive the store.
        #expect(!safety.canTerminate)
        await fixture.complete(.cancelled)
        for _ in 0..<1000 {
            if safety.canTerminate { break }
            await Task.yield()
        }
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

    private func settlePreparation(_ store: MoleUpgradeTerminalStore) async {
        for _ in 0..<1000 { if store.phase != .preparing { return }; await Task.yield() }
        Issue.record("Synthetic preparation did not settle")
    }
    private func settleRun(_ store: MoleUpgradeTerminalStore) async {
        for _ in 0..<1000 { if !store.isBusy { return }; await Task.yield() }
        Issue.record("Synthetic operation did not settle")
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

actor OperationTerminalFixture: MoleUpgradeExecuting {
    var preparations = 0
    var starts = 0
    private let pausePreparation: Bool
    private var preparation: CheckedContinuation<Void, Never>?
    init(pausePreparation: Bool = false) { self.pausePreparation = pausePreparation }
    private var input: OperationTerminalInput?
    private var output: (@Sendable (Data) async -> Void)?
    private var completion: CheckedContinuation<OperationTerminalOutcome, Never>?
    var wasCancelled: Bool { input?.isCancelled == true }
    func prepare(source: MoleUpgradeSource, currentVersion: String?, recommendedVersion: String) async -> MoleUpgradePlan {
        preparations += 1
        if pausePreparation { await withCheckedContinuation { preparation = $0 } }
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
        await onOutput(Data("\u{1b}[32msynthetic output\u{1b}[0m\r\n".utf8))
        return await withCheckedContinuation { completion = $0 }
    }
    func waitForPreparation() async {
        for _ in 0..<1000 { if preparation != nil { return }; await Task.yield() }
        Issue.record("Synthetic preparation did not start")
    }
    func completePreparation() { preparation?.resume(); preparation = nil }
    func takeInput() -> Data { input?.takePending() ?? Data() }
    func emit(_ text: String) async { await output?(Data(text.utf8)) }
    func waitForStart() async {
        for _ in 0..<1000 { if completion != nil { return }; await Task.yield() }
        Issue.record("Synthetic terminal did not start")
    }
    func complete(_ result: OperationTerminalOutcome) { completion?.resume(returning: result); completion = nil }
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
