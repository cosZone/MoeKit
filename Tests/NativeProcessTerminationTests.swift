import Darwin
import Foundation
import Testing
@testable import MoeKit

private final class ProcessFixtureBundle: NSObject {}

@Suite("Native identity-bound process signals", .serialized)
struct NativeProcessTerminationTests {
    @Test("Owned fixtures: stale generation, same-path exec, TERM, confirmed KILL, and an untouched neighbor", .timeLimit(.minutes(2)))
    func ownedFixtureLifecycle() async throws {
        let storage = try OwnedStopFixtureDirectory()
        let root = storage.root
        // Retain this small private fixture directory. Never recursively remove
        // a path that may have changed while subprocess tests were suspended.
        let source = try #require(Bundle(for: ProcessFixtureBundle.self).url(forResource: "ProcessTerminationFixtureSource", withExtension: "txt"))
        let executable = root.appendingPathComponent("owned-worker")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-x", "c", "-Wall", "-Wextra", "-Werror", source.path, "-o", executable.path]
        compiler.standardInput = FileHandle.nullDevice
        fixtureStage("compiler launch")
        try compiler.run()
        let compilerIdentity = OwnedCompilerIdentity.capture(compiler, storage: storage)
        defer { compilerIdentity?.cleanUp() }
        fixtureStage("compiler completion wait")
        try await waitForExit(compiler, seconds: 30, stage: "compiler completion")
        try #require(compiler.terminationReason == .exit && compiler.terminationStatus == 0)
        fixtureStage("compiler completed; sentinel launch")
        let sentinel = try await OwnedStopFixture.launch(executable, storage: storage, mode: "wait")
        defer { sentinel.cleanUp() }
        fixtureStage("sentinel ready; target launch")
        let target = try await OwnedStopFixture.launch(executable, storage: storage, mode: "ignore-term")
        defer { target.cleanUp() }
        fixtureStage("target ready; initial native inspection")
        let inventory = NativeProcessInventoryProvider()
        let snapshot = try await inventory.inspectSelected([target.pid])
        let original = try #require(snapshot.records.first)
        let version = try #require(original.identity.executionVersion)
        fixtureStage("stale-generation signal refusal")
        var stale = try #require(target.verifiedToken())
        stale.val.7 &+= 1
        let staleCode = proc_signal_with_audittoken(&stale, SIGTERM)
        #expect(staleCode == ESRCH)
        #expect(target.process.isRunning)
        #expect(sentinel.process.isRunning)

        // Deliberately re-exec the exact fixture path in the same PID. Birth time
        // and executable path alone must not authorize the replacement execution.
        fixtureStage("same-path re-exec")
        var beforeExec = try #require(target.verifiedToken())
        #expect(proc_signal_with_audittoken(&beforeExec, SIGUSR1) == 0)
        var newVersion: UInt32?
        for _ in 0..<200 {
            newVersion = NativeProcessToken.read(pid: target.pid)?.val.7
            if let newVersion, newVersion != version { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(newVersion != nil && newVersion != version)
        _ = try #require(target.verifiedToken())
        let staleExecCode = proc_signal_with_audittoken(&beforeExec, SIGTERM)
        #expect(staleExecCode == ESRCH)
        fixtureStage("stale-execution review refusal")
        let executor = ProcessTerminationExecutor()
        await #expect(throws: ProcessTerminationError.self) {
            try await executor.prepare(records: [original], mode: .graceful)
        }
        fixtureStage("fresh target inspection and graceful review")
        let fresh = try #require(try await inventory.inspectSelected([target.pid]).records.first)
        let graceful = try await executor.prepare(records: [fresh], mode: .graceful)
        #expect(target.process.isRunning)
        fixtureStage("graceful signal and bounded observation")
        let firstResults = try await executor.execute(reviewID: graceful.id)
        #expect(firstResults.first?.signalSubmitted == true)
        #expect(firstResults.first?.presence == .running)
        #expect(sentinel.process.isRunning)
        fixtureStage("force review and signal")
        let force = try await executor.prepare(records: [fresh], mode: .force)
        #expect(target.process.isRunning) // review alone never signals
        let forceResults = try await executor.execute(reviewID: force.id)
        #expect(forceResults.first?.signalSubmitted == true)
        fixtureStage("forced target completion wait")
        try await waitForExit(target.process, stage: "forced target completion")
        #expect(sentinel.process.isRunning)
        #expect(target.process.terminationReason == .uncaughtSignal)
        #expect(target.process.terminationStatus == SIGKILL)

        fixtureStage("cooperative target launch")
        let cooperative = try await OwnedStopFixture.launch(executable, storage: storage, mode: "wait")
        defer { cooperative.cleanUp() }
        let cooperativeRecord = try #require(try await inventory.inspectSelected([cooperative.pid]).records.first)
        let term = try await executor.prepare(records: [cooperativeRecord], mode: .graceful)
        fixtureStage("cooperative signal and bounded observation")
        let termResults = try await executor.execute(reviewID: term.id)
        #expect(termResults.first?.signalSubmitted == true)
        try await waitForExit(cooperative.process, stage: "cooperative target completion")
        #expect(cooperative.process.terminationStatus == SIGTERM)
        #expect(sentinel.process.isRunning)
        let neighborSurvived = sentinel.process.isRunning && sentinel.verifiedToken() != nil
        fixtureStage("explicit cleanup after neighbor survival proof")
        cooperative.cleanUp()
        target.cleanUp()
        sentinel.cleanUp()
        try #require(!cooperative.process.isRunning && !target.process.isRunning && !sentinel.process.isRunning,
            "Every owned helper must settle before affirmative native evidence is written")
        fixtureStage("all owned helpers settled; write affirmative native evidence")
        try recordEvidence([
            "stale_generation_refused": staleCode == ESRCH,
            "same_path_exec_refused": staleExecCode == ESRCH && newVersion != nil && newVersion != version,
            "term_submitted": termResults.first?.signalSubmitted == true,
            "term_observed": !cooperative.process.isRunning && cooperative.process.terminationStatus == SIGTERM,
            "kill_submitted": forceResults.first?.signalSubmitted == true,
            "kill_observed": !target.process.isRunning && target.process.terminationStatus == SIGKILL,
            "unselected_neighbor_survived": neighborSurvived
        ])
        fixtureStage("lifecycle body completed")
    }

    private func recordEvidence(_ checks: [String: Bool]) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sha = environment["MOEKIT_PROCESS_SOURCE_SHA"], let path = environment["MOEKIT_PROCESS_EVIDENCE_DIR"] else {
            guard environment["MOEKIT_PROCESS_SOURCE_SHA"] == nil, environment["MOEKIT_PROCESS_EVIDENCE_DIR"] == nil else { throw ProcessTerminationError.unavailable }
            return
        }
        guard sha.count == 40, sha.allSatisfy({ $0.isHexDigit }), checks.values.allSatisfy({ $0 }) else {
            throw ProcessTerminationError.unavailable
        }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ProcessTerminationError.unavailable }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw ProcessTerminationError.unavailable
        }
        let data = try JSONSerialization.data(withJSONObject: ["source_sha": sha, "checks": checks], options: [.sortedKeys])
        let file = openat(directory, "process-fixture-\(UUID().uuidString).json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ProcessTerminationError.unavailable }
        defer { close(file) }
        guard data.withUnsafeBytes({ write(file, $0.baseAddress, $0.count) }) == data.count, fsync(file) == 0 else {
            throw ProcessTerminationError.unavailable
        }
    }

    private func waitForExit(_ process: Process, seconds: TimeInterval = 2, stage: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("Owned process exceeded its deadline at: \(stage)")
                throw ProcessTerminationError.unavailable
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The task is no longer running, so its termination properties are readable.
        // Do not enter waitUntilExit's unbounded current-run-loop polling here.
    }
}

private struct OwnedStopFixture {
    let process: Process
    let executable: URL
    let storage: OwnedStopFixtureDirectory
    let seconds: UInt64
    let microseconds: UInt64
    var pid: Int32 { process.processIdentifier }

    static func launch(_ executable: URL, storage: OwnedStopFixtureDirectory, mode: String) async throws -> Self {
        guard storage.isIntact else { throw ProcessTerminationError.unavailable }
        let ready = storage.root.appendingPathComponent("ready-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = storage.root
        process.arguments = [mode, ready.path]
        fixtureStage("owned helper launch")
        try process.run()
        fixtureStage("owned helper launched; capture birth")
        var birth = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &birth, size) == size else {
            // No birth identity means no safe cleanup signal. The helper has a
            // fixed 30-second self-expiry; wait boundedly for that owned child.
            for _ in 0..<320 {
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ProcessTerminationError.unavailable
        }
        let fixture = Self(process: process, executable: executable, storage: storage,
            seconds: birth.pbi_start_tvsec, microseconds: birth.pbi_start_tvusec)
        fixtureStage("owned helper readiness wait")
        do {
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: ready.path) { return fixture }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ProcessTerminationError.unavailable
        } catch { fixture.cleanUp(); throw error }
    }

    /// Pin/check the private fixture directory, birth and executable before each
    /// direct test signal. A stale version is changed deliberately only after
    /// obtaining this verified exact-target token for the negative test.
    func verifiedToken() -> audit_token_t? {
        guard storage.isIntact, process.isRunning, var token = NativeProcessToken.read(pid: pid) else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_start_tvsec == seconds, info.pbi_start_tvusec == microseconds,
              NativeProcessCredentials.read(info).isOrdinary(uid: geteuid(), gid: getegid()) else { return nil }
        var path = [UInt8](repeating: 0, count: NativeProcessInventoryParsing.executablePathCapacity)
        let read = path.withUnsafeMutableBytes { proc_pidpath_audittoken(&token, $0.baseAddress, UInt32($0.count)) }
        guard read > 0, path.withUnsafeBytes(NativeProcessInventoryParsing.decodeCString) == executable.path,
              NativeProcessToken.read(pid: pid)?.val.7 == token.val.7 else { return nil }
        return token
    }

    func cleanUp() {
        fixtureStage("owned helper cleanup entered")
        defer { fixtureStage("owned helper cleanup returned") }
        guard process.isRunning else { return }
        guard var token = verifiedToken() else { return } // ambiguity: retain, self-expiry applies
        fixtureStage("owned helper cleanup exact signal")
        guard proc_signal_with_audittoken(&token, SIGKILL) == 0 else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning { Issue.record("Owned helper cleanup did not settle before its deadline") }
        // Re-entering waitUntilExit after the task has stopped adds unbounded
        // current-run-loop polling to an otherwise bounded cleanup path.
    }
}

private final class OwnedStopFixtureDirectory {
    let root: URL
    private let descriptor: Int32
    private let identity: stat
    private let marker: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moekit-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var physical = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.path.withCString { source in
            physical.withUnsafeMutableBufferPointer { realpath(source, $0.baseAddress) != nil }
        }
        guard resolved, let path = physical.withUnsafeBytes(NativeProcessInventoryParsing.decodeCString) else {
            throw ProcessTerminationError.unavailable
        }
        // Foundation path standardization strips /private on macOS. Compare
        // the actual physical spelling returned by the same API as libproc.
        root = URL(fileURLWithPath: path, isDirectory: true)
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProcessTerminationError.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            close(descriptor); throw ProcessTerminationError.unavailable
        }
        let marker = UUID().uuidString
        let file = openat(descriptor, "owner-marker", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { close(descriptor); throw ProcessTerminationError.unavailable }
        defer { close(file) }
        let bytes = Array(marker.utf8)
        guard bytes.withUnsafeBytes({ write(file, $0.baseAddress, $0.count) }) == bytes.count else {
            close(descriptor); throw ProcessTerminationError.unavailable
        }
        self.descriptor = descriptor
        identity = info
        self.marker = marker
    }
    deinit { close(descriptor) }
    var isIntact: Bool {
        var pinned = stat(), named = stat()
        guard fstat(descriptor, &pinned) == 0, lstat(root.path, &named) == 0,
              pinned.st_dev == identity.st_dev, pinned.st_ino == identity.st_ino,
              named.st_dev == identity.st_dev, named.st_ino == identity.st_ino,
              named.st_mode & S_IFMT == S_IFDIR, named.st_mode & 0o777 == 0o700, named.st_uid == geteuid() else { return false }
        let file = openat(descriptor, "owner-marker", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return false }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_size == marker.utf8.count else { return false }
        var bytes = [UInt8](repeating: 0, count: marker.utf8.count)
        return bytes.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) } == bytes.count
            && String(bytes: bytes, encoding: .utf8) == marker
    }
}

/// Fixed diagnostic strings only: no user process paths, arguments or environment.
private func fixtureStage(_ stage: String) {
    let line = Array("[owned-process-fixture] \(stage)\n".utf8)
    _ = line.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
}

/// The compiler is an explicitly launched test child, not a user-selected target.
/// Refuse cleanup if it has re-executed or changed identity since capture. Never
/// fall back to numeric-PID/name/group signaling or touch any compiler descendant.
private struct OwnedCompilerIdentity {
    let process: Process
    let storage: OwnedStopFixtureDirectory
    let seconds: UInt64
    let microseconds: UInt64
    let version: UInt32
    let executable: String

    static func capture(_ process: Process, storage: OwnedStopFixtureDirectory) -> Self? {
        guard storage.isIntact, process.isRunning,
              var token = NativeProcessToken.read(pid: process.processIdentifier) else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_ppid == UInt32(getpid()),
              NativeProcessCredentials.read(info).isOrdinary(uid: geteuid(), gid: getegid()) else { return nil }
        var bytes = [UInt8](repeating: 0, count: NativeProcessInventoryParsing.executablePathCapacity)
        let read = bytes.withUnsafeMutableBytes { proc_pidpath_audittoken(&token, $0.baseAddress, UInt32($0.count)) }
        guard read > 0, let executable = bytes.withUnsafeBytes(NativeProcessInventoryParsing.decodeCString),
              NativeProcessToken.read(pid: process.processIdentifier)?.val.7 == token.val.7 else { return nil }
        return Self(process: process, storage: storage, seconds: info.pbi_start_tvsec,
            microseconds: info.pbi_start_tvusec, version: token.val.7, executable: executable)
    }

    func cleanUp() {
        guard process.isRunning else { return }
        fixtureStage("compiler deadline cleanup")
        guard storage.isIntact, let current = Self.capture(process, storage: storage),
              current.seconds == seconds, current.microseconds == microseconds,
              current.version == version, current.executable == executable,
              var token = NativeProcessToken.read(pid: process.processIdentifier), token.val.7 == version else {
            Issue.record("Compiler identity changed or became unavailable; no cleanup signal submitted")
            return
        }
        guard proc_signal_with_audittoken(&token, SIGKILL) == 0 else {
            Issue.record("Exact owned compiler cleanup signal failed")
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning { Issue.record("Owned compiler cleanup did not settle before its deadline") }
    }
}
