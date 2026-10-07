import Darwin
import Foundation

/// A bounded, lock-protected mailbox. It owns no process and never signals a PID.
/// Only the helper's dedicated stdin pipe controls cancellation/PTY input.
final class OperationTerminalInput: @unchecked Sendable {
    static let maximumQueuedBytes = 64 * 1024
    private let lock = NSLock()
    private var queued = Data()
    private var size: (rows: UInt16, columns: UInt16)?
    private var cancelled = false
    private var phase: UInt8?

    @discardableResult func send(_ bytes: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, let phase, !bytes.isEmpty,
              bytes.count <= Self.maximumQueuedBytes,
              queued.count + bytes.count + ((bytes.count + 4095) / 4096) * 6 <= Self.maximumQueuedBytes else { return false }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 4096, bytes.count)
            var payload = Data([phase]); payload.append(bytes.subdata(in: offset..<end))
            queued.append(Self.frame(type: 73, payload: payload))
            offset = end
        }
        return true
    }
    func setPhase(_ phase: UInt8?) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, phase == nil || phase == 1 || phase == 2 else { return }
        if self.phase != phase { queued.removeAll(keepingCapacity: true) }
        self.phase = phase
    }
    func resize(columns: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        size = (UInt16(min(1000, max(1, rows))), UInt16(min(1000, max(1, columns))))
    }
    func cancel() {
        lock.lock(); cancelled = true; queued.removeAll(); size = nil; lock.unlock()
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func takePending() -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return Data() }
        var result = Data()
        if let size {
            result.append(Self.frame(type: 82, payload: Data([
                UInt8(size.rows >> 8), UInt8(size.rows & 255),
                UInt8(size.columns >> 8), UInt8(size.columns & 255)])))
            self.size = nil
        }
        result.append(queued); queued.removeAll(keepingCapacity: true)
        return result
    }
    private static func frame(type: UInt8, payload: Data) -> Data {
        let n = UInt32(payload.count)
        var result = Data([type, UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        result.append(payload); return result
    }
}

enum OperationTerminalOutcome: Equatable, Sendable {
    case completed
    case failed(step: String, exitCode: Int32?, signal: Int32?)
    case cancelled
    case interrupted(code: Int32)
    case notStarted(String)

    var message: String {
        switch self {
        case .completed:
            String(localized: "Homebrew finished successfully. Recheck Mole to verify the installed version and analyzer before analysis.")
        case .failed(let step, let code, let signal):
            String(localized: "The upgrade did not finish. Changes may be partial. No retry or rollback was attempted.") +
                " (\(step): " + (signal.map { "signal \($0)" } ?? code.map { "exit \($0)" } ?? "unknown") + ")"
        case .cancelled:
            String(localized: "The operation stopped. Homebrew or Mole may already have changed. Recheck the installation; nothing was rolled back.")
        case .interrupted:
            String(localized: "The operation has no verified successful result. Changes may be partial. Keep this output and recheck the installation before trying anything else.")
        case .notStarted(let reason): reason
        }
    }
}

protocol MoleUpgradeExecuting: Sendable {
    func prepare(source: MoleUpgradeSource, currentVersion: String?, recommendedVersion: String) async throws -> MoleUpgradePlan
    func run(_ plan: MoleUpgradePlan, input: OperationTerminalInput,
             onOutput: @escaping @Sendable (Data) async -> Void) async -> OperationTerminalOutcome
}

actor MoleUpgradeExecutor: MoleUpgradeExecuting {
    func prepare(source: MoleUpgradeSource, currentVersion: String?, recommendedVersion: String) async throws -> MoleUpgradePlan {
        try Task.checkCancellation()
        let executable = try OperationExecutableVerifier.executionURL(for: source)
        let snapshot = try OperationExecutableVerifier.capture(executable)
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        var metadata = stat()
        guard home.isFileURL, home.path != "/", lstat(home.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid(), geteuid() != 0 else {
            throw OperationTerminalFailure.invalidHome
        }
        return MoleUpgradePlan(id: UUID(), source: source, executable: executable, currentVersion: currentVersion,
            recommendedVersion: recommendedVersion, executableSnapshot: snapshot, home: home, preparedAt: Date())
    }

    func run(_ plan: MoleUpgradePlan, input: OperationTerminalInput,
             onOutput: @escaping @Sendable (Data) async -> Void) async -> OperationTerminalOutcome {
        await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                await OperationTerminalSession.run(plan, input: input, onOutput: onOutput)
            }.value
        } onCancel: { input.cancel() }
    }
}

/// The app launches only its reviewed native supervisor. Fork/session/group
/// ownership is confined to that single-threaded C program, never Swift.
private enum OperationTerminalSession {
    static let maximumOutputBytes = 16 * 1024 * 1024
    static let maximumStatusBytes = 4096

    static func run(_ plan: MoleUpgradePlan, input: OperationTerminalInput,
                    onOutput: @escaping @Sendable (Data) async -> Void) async -> OperationTerminalOutcome {
        let process = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), statusPipe = Pipe()
        var started = false
        var stdinOpen = true
        defer {
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? statusPipe.fileHandleForReading.close()
        }
        do {
            guard !input.isCancelled else { return .cancelled }
            guard Date().timeIntervalSince(plan.preparedAt) >= 0,
                  Date().timeIntervalSince(plan.preparedAt) < 600 else { throw OperationTerminalFailure.expiredPlan }
            guard try OperationExecutableVerifier.executionURL(for: plan.source) == plan.executable,
                  try OperationExecutableVerifier.capture(plan.executable) == plan.executableSnapshot else {
                throw OperationTerminalFailure.changedExecutable
            }
            guard !input.isCancelled else { return .cancelled }
            guard let helper = Bundle.main.url(forAuxiliaryExecutable: "OperationTerminal") else {
                throw OperationTerminalFailure.unavailable
            }
            process.executableURL = helper
            process.arguments = [plan.executable.path, plan.home.path] + plan.executableSnapshot.supervisorArguments
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": plan.home.path]
            process.currentDirectoryURL = plan.home
            process.standardInput = stdinPipe; process.standardOutput = stdoutPipe; process.standardError = statusPipe
            try process.run(); started = true
            // Close the parent's unused ends; helper EOF must describe only its lifetime.
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? statusPipe.fileHandleForWriting.close()
            let inFD = stdinPipe.fileHandleForWriting.fileDescriptor
            let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
            let statusFD = statusPipe.fileHandleForReading.fileDescriptor
            // F_SETNOSIGPIPE is per descriptor. Never change app-global SIGPIPE handling.
            guard fcntl(inFD, F_SETNOSIGPIPE, 1) == 0 else { throw OperationTerminalFailure.io }
            for fd in [inFD, outFD, statusFD] {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw OperationTerminalFailure.io }
            }
            var outputOpen = true, statusOpen = true
            var pending = Data(), written = 0, totalOutput = 0
            var status = Data()
            var transportFailed = false
            while outputOpen || statusOpen {
                if input.isCancelled, stdinOpen {
                    try? stdinPipe.fileHandleForWriting.close(); stdinOpen = false
                    pending.removeAll(); written = 0
                }
                if stdinOpen, written == pending.count { pending = input.takePending(); written = 0 }
                var fds = [pollfd(fd: outputOpen ? outFD : -1, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: statusOpen ? statusFD : -1, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: stdinOpen && written < pending.count ? inFD : -1, events: Int16(POLLOUT), revents: 0)]
                let result = poll(&fds, nfds_t(fds.count), 25)
                if result < 0 && errno == EINTR { continue }
                guard result >= 0 else { throw OperationTerminalFailure.io }
                if stdinOpen, written < pending.count, fds[2].revents != 0 {
                    let count = pending.withUnsafeBytes { ptr in
                        Darwin.write(inFD, ptr.baseAddress!.advanced(by: written), pending.count - written)
                    }
                    if count > 0 { written += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR {
                        // A completed helper may close input before its final status is read.
                        try? stdinPipe.fileHandleForWriting.close(); stdinOpen = false
                    }
                }
                for index in [1, 0] where fds[index].revents != 0 {
                    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                    let count = Darwin.read(fds[index].fd, &buffer, buffer.count)
                    if count == 0 {
                        if index == 0 { outputOpen = false } else { statusOpen = false }
                    } else if count > 0 {
                        if index == 0 {
                            guard count <= maximumOutputBytes - totalOutput else {
                                transportFailed = true; input.cancel(); continue
                            }
                            totalOutput += count
                            await onOutput(Data(buffer.prefix(count)))
                        } else if count <= maximumStatusBytes - status.count {
                            status.append(contentsOf: buffer.prefix(count))
                            input.setPhase(OperationTerminalStatus.inputPhase(status))
                        } else { transportFailed = true; input.cancel() }
                    } else if errno != EAGAIN && errno != EINTR { throw OperationTerminalFailure.io }
                }
            }
            try? stdinPipe.fileHandleForWriting.close(); stdinOpen = false
            process.waitUntilExit()
            guard !transportFailed, process.terminationReason == .exit else { return .interrupted(code: -1) }
            return OperationTerminalStatus.parse(status, helperExit: process.terminationStatus)
        } catch {
            // Closing the channel requests owned-group termination. Retain the
            // Process until the helper has completed cleanup; never terminate(pid).
            input.cancel()
            try? stdinPipe.fileHandleForWriting.close(); stdinOpen = false
            if started { process.waitUntilExit() }
            if started { return .interrupted(code: -1) }
            return .notStarted((error as? LocalizedError)?.errorDescription ?? OperationTerminalFailure.io.errorDescription!)
        }
    }
}

/// Status is a separate supervisor pipe, never parsed from untrusted PTY text.
enum OperationTerminalStatus {
    private struct Records {
        var phase: String?
        var result: Int32?
        var exitCode: Int32?
        var signal: Int32?
    }

    /// Phase-tag every input frame. Unsent/partially written old-phase frames
    /// cannot become keystrokes in the next command, even across a fast exit.
    static func inputPhase(_ data: Data) -> UInt8? {
        guard let records = records(data, allowPartial: true), records.result == nil,
              records.exitCode == nil, records.signal == nil else { return nil }
        return records.phase == "update" ? 1 : records.phase == "upgrade" ? 2 : nil
    }
    static func parse(_ data: Data, helperExit: Int32) -> OperationTerminalOutcome {
        guard let records = records(data, allowPartial: false), records.result == helperExit else {
            return .interrupted(code: helperExit)
        }
        switch helperExit {
        case 0 where records.phase == "upgrade" && records.exitCode == 0: return .completed
        case 73 where records.phase != nil && ((records.exitCode ?? 0) != 0 || records.signal != nil):
            return .failed(step: records.phase!, exitCode: records.exitCode, signal: records.signal)
        case 74 where records.phase == nil || records.exitCode != nil || records.signal != nil: return .cancelled
        case 64 where records.phase == nil, 76 where records.phase == nil:
            return .notStarted(OperationTerminalFailure.changedExecutable.errorDescription!)
        default: return .interrupted(code: helperExit)
        }
    }
    private static func records(_ data: Data, allowPartial: Bool) -> Records? {
        guard var text = String(data: data, encoding: .utf8), data.allSatisfy({ $0 < 128 }) else { return nil }
        if !text.hasSuffix("\n") {
            guard allowPartial else { return nil }
            text = text.lastIndex(of: "\n").map { String(text[...$0]) } ?? ""
        }
        var records = Records()
        for parts in text.split(separator: "\n").map({ $0.split(separator: " ").map(String.init) }) {
            guard records.result == nil, parts.first == "MKOT1" else { return nil }
            if parts.count == 3, parts[1] == "PHASE", ["update", "upgrade"].contains(parts[2]) {
                guard (records.phase == nil && parts[2] == "update") ||
                        (records.phase == "update" && records.exitCode == 0 && parts[2] == "upgrade") else { return nil }
                records.phase = parts[2]; records.exitCode = nil; records.signal = nil
            } else if parts.count == 4, parts[2] == records.phase, let value = Int32(parts[3]),
                      records.exitCode == nil, records.signal == nil {
                if parts[1] == "EXIT", (0...255).contains(value) { records.exitCode = value }
                else if parts[1] == "SIGNAL", (1...127).contains(value) { records.signal = value }
                else { return nil }
            } else if parts.count == 3, parts[1] == "RESULT", let value = Int32(parts[2]) { records.result = value }
            else { return nil }
        }
        return records
    }
}
