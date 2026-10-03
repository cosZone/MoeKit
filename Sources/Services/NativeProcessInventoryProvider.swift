import Darwin
import Foundation

enum NativeProcessInventoryError: Error, Sendable, LocalizedError {
    case invalidOptions
    case enumerationUnavailable(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return String(localized: "Use 1–16,384 processes, 1–4,096 descriptors per process, and a finite duration above zero and at most 30 seconds.")
        case .enumerationUnavailable(let code):
            return String(localized: "The current user's process list could not be read (system error \(code)).")
        }
    }
}

/// A read-only, on-demand snapshot. All native reads and path resolution run on this
/// actor, away from MainActor. There is no timer, shell, argv/environment read,
/// process launch, signal, or privilege escalation.
///
/// The duration is a cooperative budget checked around native calls; a synchronous
/// kernel/filesystem call cannot be interrupted. Individual rows are observations,
/// not an atomic system snapshot or proof that a later action would be safe.
///
/// SDK declarations: Apple's xnu bsd/sys/proc_info.h and
/// libsyscall/wrappers/libproc/libproc.h. These SDK interfaces are version-sensitive.
actor NativeProcessInventoryProvider: ProcessInventoryProviding {
    private enum BudgetExpired: Error { case expired }

    private struct Observation {
        let identity: ProcessIdentity
        let name: String
        let parentPID: Int32?
        let processGroupID: Int32?
    }

    func scan(options: ProcessScanOptions) async throws -> ProcessSnapshot {
        try Task.checkCancellation()
        guard (1...16_384).contains(options.maximumProcesses),
              (1...4_096).contains(options.maximumFileDescriptorsPerProcess),
              options.maximumDuration.isFinite,
              options.maximumDuration > 0,
              options.maximumDuration <= 30 else {
            throw NativeProcessInventoryError.invalidOptions
        }

        let currentUID = geteuid()
        let observerPID = getpid()
        let capturedAt = Date()
        let deadline = ProcessInfo.processInfo.systemUptime + options.maximumDuration
        var records: [ProcessInventoryRecord] = []
        var issues: [String] = []
        var isPartial = false
        var unavailableCount = 0
        var changedCount = 0

        do {
            // One extra slot detects a saturated result without an unbounded retry
            // or allocation derived from an untrusted/changing process count.
            var pids = [pid_t](repeating: 0, count: options.maximumProcesses + 1)
            try checkBudget(deadline)
            errno = 0
            let bytesRead = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(UInt32(PROC_UID_ONLY), currentUID, buffer.baseAddress, Int32(buffer.count))
            }
            let enumerationError = errno
            try checkBudget(deadline)
            let stride = MemoryLayout<pid_t>.stride
            guard bytesRead > 0,
                  Int(bytesRead) <= pids.count * stride,
                  Int(bytesRead) % stride == 0 else {
                throw NativeProcessInventoryError.enumerationUnavailable(enumerationError)
            }

            let count = Int(bytesRead) / stride
            if count > options.maximumProcesses {
                isPartial = true
                issues.append(String(localized: "The process limit was reached; some processes were not inspected."))
            }

            var seen = Set<pid_t>()
            for pid in pids.prefix(min(count, options.maximumProcesses)) {
                try checkBudget(deadline)
                guard pid > 0, seen.insert(pid).inserted else { continue }
                guard let before = try observation(pid: pid, currentUID: currentUID, deadline: deadline) else {
                    unavailableCount += 1
                    isPartial = true
                    continue
                }

                var metadataIssues: [String] = []
                if before.identity.executablePath == nil {
                    metadataIssues.append(String(localized: "Executable path unavailable; process identity is incomplete."))
                }
                if before.identity.startSeconds == nil {
                    metadataIssues.append(String(localized: "Process start time unavailable; process identity is incomplete."))
                }
                if before.name.isEmpty { metadataIssues.append(String(localized: "Process name unavailable.")) }

                let workingDirectory = try workingDirectory(pid: pid, deadline: deadline)
                if workingDirectory == nil {
                    metadataIssues.append(String(localized: "Working directory unavailable or could not be resolved."))
                }
                let ports = try listeningPorts(
                    pid: pid,
                    maximumDescriptors: options.maximumFileDescriptorsPerProcess,
                    deadline: deadline,
                    issues: &metadataIssues
                )

                // PID alone is not identity. Recheck the UID, start time and
                // executable path after all per-process metadata has been read.
                guard let after = try observation(pid: pid, currentUID: currentUID, deadline: deadline),
                      before.identity == after.identity else {
                    changedCount += 1
                    isPartial = true
                    continue
                }
                if !metadataIssues.isEmpty { isPartial = true }
                records.append(ProcessInventoryRecord(
                    identity: before.identity,
                    name: before.name,
                    parentPID: before.parentPID,
                    processGroupID: before.processGroupID,
                    workingDirectory: workingDirectory,
                    listeningPorts: ports,
                    metadataIssues: metadataIssues
                ))
            }
        } catch BudgetExpired.expired {
            isPartial = true
            issues.append(String(localized: "The scan time budget was reached; unfinished rows were discarded."))
        }

        // Cancellation is not converted into a successful partial snapshot.
        try Task.checkCancellation()
        if unavailableCount > 0 {
            issues.append(String(localized: "\(unavailableCount) processes exited, became unreadable, or could not be verified as belonging to the current user."))
        }
        if changedCount > 0 {
            issues.append(String(localized: "\(changedCount) rows were discarded because identity changed or could not be revalidated during the scan."))
        }
        records.sort { $0.identity.pid < $1.identity.pid }
        return ProcessSnapshot(
            capturedAt: capturedAt,
            records: records,
            currentUID: currentUID,
            observerPID: observerPID,
            issues: issues,
            isPartial: isPartial
        )
    }

    private func checkBudget(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        if ProcessInfo.processInfo.systemUptime >= deadline { throw BudgetExpired.expired }
    }

    private func observation(pid: pid_t, currentUID: uid_t, deadline: TimeInterval) throws -> Observation? {
        try checkBudget(deadline)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytesRead = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        try checkBudget(deadline)
        // Never collect cwd/socket metadata when ownership could not be verified.
        guard bytesRead == size, info.pbi_pid == UInt32(pid), info.pbi_uid == currentUID else { return nil }

        let path = try executablePath(pid: pid, deadline: deadline)
        let name = withUnsafeBytes(of: &info.pbi_name, NativeProcessInventoryParsing.decodeCString)
            ?? withUnsafeBytes(of: &info.pbi_comm, NativeProcessInventoryParsing.decodeCString)
            ?? ""
        let validStart = info.pbi_start_tvsec > 0 && info.pbi_start_tvusec < 1_000_000
        return Observation(
            identity: ProcessIdentity(
                pid: pid,
                startSeconds: validStart ? info.pbi_start_tvsec : nil,
                startMicroseconds: validStart ? info.pbi_start_tvusec : nil,
                uid: info.pbi_uid,
                executablePath: path
            ),
            name: name,
            parentPID: Int32(exactly: info.pbi_ppid),
            processGroupID: Int32(exactly: info.pbi_pgid)
        )
    }

    private func executablePath(pid: pid_t, deadline: TimeInterval) throws -> String? {
        try checkBudget(deadline)
        var buffer = [UInt8](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let bytesRead = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        try checkBudget(deadline)
        guard bytesRead > 0, Int(bytesRead) < buffer.count,
              let path = buffer.withUnsafeBytes(NativeProcessInventoryParsing.decodeCString),
              path.hasPrefix("/") else { return nil }
        return path
    }

    private func workingDirectory(pid: pid_t, deadline: TimeInterval) throws -> String? {
        try checkBudget(deadline)
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let bytesRead = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        try checkBudget(deadline)
        guard bytesRead == size,
              let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path, NativeProcessInventoryParsing.decodeCString),
              path.hasPrefix("/") else { return nil }

        // A failed realpath is unknown, not a guessed project association. The
        // fixed output buffer follows macOS realpath's PATH_MAX contract.
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let succeeded = path.withCString { source in
            resolved.withUnsafeMutableBufferPointer { destination in
                realpath(source, destination.baseAddress) != nil
            }
        }
        try checkBudget(deadline)
        guard succeeded else { return nil }
        return resolved.withUnsafeBytes(NativeProcessInventoryParsing.decodeCString)
    }

    private func listeningPorts(
        pid: pid_t,
        maximumDescriptors: Int,
        deadline: TimeInterval,
        issues: inout [String]
    ) throws -> [ListeningPort]? {
        try checkBudget(deadline)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: maximumDescriptors + 1)
        errno = 0
        let bytesRead = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        let descriptorError = errno
        try checkBudget(deadline)
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard bytesRead >= 0, !(bytesRead == 0 && descriptorError != 0),
              Int(bytesRead) <= descriptors.count * stride,
              Int(bytesRead) % stride == 0 else {
            issues.append(String(localized: "TCP listener coverage unknown: file descriptors could not be read."))
            return nil
        }
        let count = Int(bytesRead) / stride
        guard count <= maximumDescriptors else {
            issues.append(String(localized: "TCP listener coverage unknown: the per-process file descriptor limit was reached."))
            return nil
        }

        var ports = Set<ListeningPort>()
        for descriptor in descriptors.prefix(count) {
            try checkBudget(deadline)
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            guard descriptor.proc_fd >= 0 else {
                issues.append(String(localized: "TCP listener coverage unknown: a socket descriptor was invalid."))
                return nil
            }
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size)
            try checkBudget(deadline)
            guard read == size else {
                issues.append(String(localized: "TCP listener coverage unknown: a socket closed or became unreadable during the scan."))
                return nil
            }
            // The SDK supplies a full socket structure. Only protocol/listen state
            // and the local listening address/port are inspected or retained.
            // Foreign endpoints, connected sockets and socket handles are not
            // copied into the snapshot, logs, or persistent storage.
            switch NativeProcessInventoryParsing.tcpListener(socket) {
            case .notListener:
                continue
            case .listener(let port):
                ports.insert(port)
            case .unavailable:
                issues.append(String(localized: "TCP listener coverage unknown: a local listener address could not be decoded."))
                return nil
            }
        }
        return ports.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.address < $1.address
        }
    }
}

/// Pure decoding helpers are separate so tests can use synthetic SDK structures
/// without enumerating processes, opening sockets, or examining the test machine.
enum NativeProcessInventoryParsing {
    enum ListenerResult: Equatable {
        case notListener
        case listener(ListeningPort)
        case unavailable
    }

    static func decodeCString(_ bytes: UnsafeRawBufferPointer) -> String? {
        guard let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
        return String(bytes: bytes[..<end], encoding: .utf8)
    }

    static func tcpListener(_ socket: socket_fdinfo) -> ListenerResult {
        guard socket.psi.soi_kind == Int32(SOCKINFO_TCP),
              socket.psi.soi_protocol == IPPROTO_TCP,
              socket.psi.soi_type == SOCK_STREAM else { return .notListener }
        let tcp = socket.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { return .notListener }
        let local = tcp.tcpsi_ini
        guard (1...Int32(UInt16.max)).contains(local.insi_lport) else { return .unavailable }
        let port = UInt16(bigEndian: UInt16(local.insi_lport))
        let address: String?
        switch socket.psi.soi_family {
        case AF_INET:
            guard local.insi_vflag & UInt8(INI_IPV4) != 0 else { return .unavailable }
            var value = local.insi_laddr.ina_46.i46a_addr4
            address = formatAddress(&value, family: AF_INET)
        case AF_INET6:
            guard local.insi_vflag & UInt8(INI_IPV6) != 0 else { return .unavailable }
            var value = local.insi_laddr.ina_6
            address = formatAddress(&value, family: AF_INET6)
        default:
            return .unavailable
        }
        guard let address else { return .unavailable }
        return .listener(ListeningPort(port: port, address: address, transport: "TCP"))
    }

    private static func formatAddress<T>(_ address: inout T, family: Int32) -> String? {
        let capacity = Int(INET6_ADDRSTRLEN)
        var buffer = [CChar](repeating: 0, count: capacity)
        let succeeded = withUnsafePointer(to: &address) { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                inet_ntop(family, source, destination.baseAddress, socklen_t(capacity)) != nil
            }
        }
        guard succeeded else { return nil }
        return buffer.withUnsafeBytes(decodeCString)
    }
}
