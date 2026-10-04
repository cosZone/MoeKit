import Darwin
import Foundation
import Testing
@testable import MoeKit

private final class ProcessFixtureBundle: NSObject {}

@Suite("Native identity-bound process signals", .serialized)
struct NativeProcessTerminationTests {
    @Test("Owned fixtures: stale generation, same-path exec, TERM, confirmed KILL, and an untouched neighbor")
    func ownedFixtureLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moekit-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(Bundle(for: ProcessFixtureBundle.self).url(forResource: "ProcessTerminationFixture", withExtension: "c"))
        let executable = root.appendingPathComponent("owned-worker")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-Wall", "-Wextra", "-Werror", source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)
        let sentinel = try await OwnedStopFixture.launch(executable, root: root, mode: "wait")
        defer { sentinel.cleanUp() }
        let target = try await OwnedStopFixture.launch(executable, root: root, mode: "ignore-term")
        defer { target.cleanUp() }
        let inventory = NativeProcessInventoryProvider()
        let snapshot = try await inventory.inspectSelected([target.pid])
        let original = try #require(snapshot.records.first)
        let version = try #require(original.identity.executionVersion)
        var stale = try #require(NativeProcessToken.read(pid: target.pid))
        stale.val.7 &+= 1
        #expect(proc_signal_with_audittoken(&stale, SIGTERM) == ESRCH)
        #expect(target.process.isRunning)
        #expect(sentinel.process.isRunning)

        // Deliberately re-exec the exact fixture path in the same PID. Birth time
        // and executable path alone must not authorize the replacement execution.
        var beforeExec = try #require(NativeProcessToken.read(pid: target.pid))
        #expect(proc_signal_with_audittoken(&beforeExec, SIGUSR1) == 0)
        var newVersion: UInt32?
        for _ in 0..<200 {
            newVersion = NativeProcessToken.read(pid: target.pid)?.val.7
            if let newVersion, newVersion != version { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(newVersion != nil && newVersion != version)
        #expect(proc_signal_with_audittoken(&beforeExec, SIGTERM) == ESRCH)
        let executor = ProcessTerminationExecutor()
        await #expect(throws: ProcessTerminationError.self) {
            try await executor.prepare(records: [original], mode: .graceful)
        }
        let fresh = try #require(try await inventory.inspectSelected([target.pid]).records.first)
        let graceful = try await executor.prepare(records: [fresh], mode: .graceful)
        #expect(target.process.isRunning)
        let firstResults = try await executor.execute(reviewID: graceful.id)
        #expect(firstResults.first?.signalSubmitted == true)
        #expect(firstResults.first?.presence == .running)
        #expect(sentinel.process.isRunning)
        let force = try await executor.prepare(records: [fresh], mode: .force)
        #expect(target.process.isRunning) // review alone never signals
        let forceResults = try await executor.execute(reviewID: force.id)
        #expect(forceResults.first?.signalSubmitted == true)
        try await waitForExit(target.process)
        #expect(sentinel.process.isRunning)
        #expect(target.process.terminationReason == .uncaughtSignal)
        #expect(target.process.terminationStatus == SIGKILL)

        let cooperative = try await OwnedStopFixture.launch(executable, root: root, mode: "wait")
        defer { cooperative.cleanUp() }
        let cooperativeRecord = try #require(try await inventory.inspectSelected([cooperative.pid]).records.first)
        let term = try await executor.prepare(records: [cooperativeRecord], mode: .graceful)
        let termResults = try await executor.execute(reviewID: term.id)
        #expect(termResults.first?.signalSubmitted == true)
        try await waitForExit(cooperative.process)
        #expect(cooperative.process.terminationStatus == SIGTERM)
        #expect(sentinel.process.isRunning)
    }

    private func waitForExit(_ process: Process) async throws {
        for _ in 0..<200 {
            if !process.isRunning { process.waitUntilExit(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Owned fixture did not exit after its confirmed signal")
    }
}

private struct OwnedStopFixture {
    let process: Process
    let executable: URL
    let seconds: UInt64
    let microseconds: UInt64
    var pid: Int32 { process.processIdentifier }

    static func launch(_ executable: URL, root: URL, mode: String) async throws -> Self {
        let ready = root.appendingPathComponent("ready-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = root
        process.arguments = [mode, ready.path]
        try process.run()
        var birth = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &birth, size) == size else {
            throw ProcessTerminationError.unavailable
        }
        let fixture = Self(process: process, executable: executable, seconds: birth.pbi_start_tvsec, microseconds: birth.pbi_start_tvusec)
        do {
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: ready.path) { return fixture }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ProcessTerminationError.unavailable
        } catch { fixture.cleanUp(); throw error }
    }

    /// Only fixture-owned birth+path identities; no PID-only emergency fallback.
    func cleanUp() {
        guard process.isRunning, var token = NativeProcessToken.read(pid: pid) else { return }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_start_tvsec == seconds, info.pbi_start_tvusec == microseconds else { return }
        var path = [UInt8](repeating: 0, count: NativeProcessInventoryParsing.executablePathCapacity)
        let read = path.withUnsafeMutableBytes { proc_pidpath_audittoken(&token, $0.baseAddress, UInt32($0.count)) }
        guard read > 0, path.withUnsafeBytes(NativeProcessInventoryParsing.decodeCString) == executable.path,
              NativeProcessToken.read(pid: pid)?.val.7 == token.val.7 else { return }
        if proc_signal_with_audittoken(&token, SIGKILL) == 0 { process.waitUntilExit() }
    }
}
