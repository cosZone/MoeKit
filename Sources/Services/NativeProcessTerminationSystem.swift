import Darwin
import Foundation

/// Kernel-issued token read using a name right only, never task_for_pid/control
/// rights. SDK libproc.h supplies the version-bound signal entry point. There is
/// deliberately no numeric-PID fallback, symbol lookup, or private syscall.
enum NativeProcessToken {
    static func read(pid: Int32) -> audit_token_t? {
        guard pid > 1 else { return nil }
        var name = mach_port_name_t(MACH_PORT_NULL)
        guard task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, name) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let expected = count
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
                task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == expected, token.val.5 == UInt32(pid) else { return nil }
        return token
    }
}

actor NativeProcessTerminationSystem: ProcessTerminationSystem {
    private let inventory = NativeProcessInventoryProvider()

    func inspect(_ identities: [ProcessIdentity]) async throws -> ProcessSnapshot {
        guard geteuid() != 0, geteuid() == getuid() else { throw ProcessTerminationError.protectedTarget }
        let snapshot = try await inventory.inspectSelected(identities.map(\.pid))
        try Task.checkCancellation()
        let ancestors = try ancestorPIDs()
        guard !identities.contains(where: { ancestors.contains($0.pid) }) else { throw ProcessTerminationError.protectedTarget }
        return snapshot
    }

    func signal(_ record: ProcessInventoryRecord, mode: ProcessStopMode) async throws {
        let fresh = try await inspect([record.identity])
        try ProcessTerminationExecutor.validate([record], fresh: fresh)
        guard var token = NativeProcessToken.read(pid: record.identity.pid),
              token.val.1 == geteuid(), token.val.3 == getuid(),
              token.val.7 == record.identity.executionVersion else { throw ProcessTerminationError.changed }
        try Task.checkCancellation()
        // Kernel checks the execution version and retains the exact process.
        // Mutable cwd/listeners may still change; this is not an atomic snapshot.
        let code = proc_signal_with_audittoken(&token, mode == .graceful ? SIGTERM : SIGKILL)
        guard code == 0 else { throw ProcessTerminationError.unavailable }
    }

    func presence(of identity: ProcessIdentity) async -> ProcessPresence {
        if let token = NativeProcessToken.read(pid: identity.pid) {
            return token.val.7 == identity.executionVersion ? .running : .exited
        }
        var info = proc_bsdinfo()
        errno = 0
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, size)
        if read == 0, errno == ESRCH { return .exited }
        if read == size, info.pbi_status == UInt32(SZOMB) { return .exited }
        return .unknown
    }

    private func ancestorPIDs() throws -> Set<Int32> {
        var result: Set<Int32> = []
        var pid = getpid()
        for _ in 0..<64 {
            guard pid > 1 else { return result }
            guard result.insert(pid).inserted else { throw ProcessTerminationError.unavailable }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  let parent = Int32(exactly: info.pbi_ppid) else { throw ProcessTerminationError.unavailable }
            pid = parent
        }
        throw ProcessTerminationError.unavailable
    }
}
