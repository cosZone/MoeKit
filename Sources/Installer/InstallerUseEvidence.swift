import Darwin
import Foundation

/// Device numbers use the unsigned bit pattern of Darwin's signed dev_t.
struct InstallerUseFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct InstallerUseTarget: Sendable {
    let device: UInt64
    let inode: UInt64
    let path: String
    /// Only descriptors retained by the caller for this exact target. The caller
    /// must keep them open for the entire observation; never pass unrelated FDs.
    let observerRetainedFileDescriptors: Set<Int32>

    var identity: InstallerUseFileIdentity { .init(device: device, inode: inode) }
}

enum InstallerUseEvidence: Equatable, Sendable {
    case observedUse(reason: String)
    case noUseObserved
    case unavailable(reason: String)

    static let attachedImageLimitation = String(localized: "This version requires a complete, empty disk-image inventory and cannot rule out use through any attached image. Eject only images you opened yourself, then check again. Leave system-managed images alone; their presence can keep this action unavailable. MoeKit does not classify or eject images.")

    static let scopeDescription = String(localized: "Requires a complete, empty disk-image inventory and checks current-user open file descriptors and fileports. Only eject images you opened yourself; leave system-managed images alone. MoeKit does not classify images, so unsupported system inventory can keep this action unavailable. Memory mappings, system processes, and other users' use are not verified. This observation is not proof that the file is unused.")
}

/// Diagnostic-only handle scope. No case represents overall installer eligibility:
/// mounted images, memory mappings, system processes and other users are excluded.
enum InstallerCurrentUserHandleDiagnostic: Equatable, Sendable {
    case observedHandleUse(reason: String)
    case noHandleUseObserved
    case unavailable(reason: String)
}

protocol InstallerUseEvidenceProviding: Sendable {
    func evidence(for target: InstallerUseTarget) async -> InstallerUseEvidence
}

struct InstallerUseProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let isZombie: Bool
}

struct InstallerUseHandle: Hashable, Sendable {
    let number: UInt32
    let isVnode: Bool
}

/// Injection boundary keeps coverage/race fixtures independent of the user's
/// processes. Native tests below this boundary inspect only the test process.
protocol InstallerUseSystemReading: Sendable {
    var currentUID: UInt32 { get }
    var observerPID: Int32 { get }
    func now() -> TimeInterval
    func processes(maximum: Int) throws -> [Int32]
    func identity(pid: Int32) throws -> InstallerUseProcessIdentity
    func descriptors(pid: Int32, maximum: Int) throws -> [InstallerUseHandle]
    func fileports(pid: Int32, maximum: Int) throws -> [InstallerUseHandle]
    func descriptorIdentity(pid: Int32, descriptor: Int32) throws -> InstallerUseFileIdentity
    func fileportIdentity(pid: Int32, port: UInt32) throws -> InstallerUseFileIdentity
    func mountedImages(deadline: TimeInterval) async throws -> Set<InstallerUseFileIdentity>
}

enum InstallerUseReadError: Error, Sendable {
    case unavailable(String)
}

/// A bounded, non-atomic observation, not a lock or authority to mutate a file.
/// The budget is cooperative around synchronous kernel/filesystem calls; those
/// calls cannot be interrupted. The fixed system helper has a bounded wait.
/// No private libproc flavors, task ports, process signals, or privilege requests.
/// In particular, public PROC_PIDREGIONPATHINFO can silently omit failed vnode
/// reads. It is NOT used to manufacture exhaustive memory-mapping coverage.
actor NativeInstallerUseEvidenceProvider: InstallerUseEvidenceProviding {
    private let system: any InstallerUseSystemReading
    private let maximumProcesses: Int
    private let maximumHandles: Int
    private let maximumDuration: TimeInterval

    init(system: any InstallerUseSystemReading = NativeInstallerUseSystem(),
         maximumProcesses: Int = 4_096, maximumHandles: Int = 16_384,
         maximumDuration: TimeInterval = 12) {
        self.system = system
        self.maximumProcesses = maximumProcesses
        self.maximumHandles = maximumHandles
        self.maximumDuration = maximumDuration
    }

    func evidence(for target: InstallerUseTarget) async -> InstallerUseEvidence {
        guard isValidRequest(target) else {
            return .unavailable(reason: String(localized: "The file-use observation request is invalid."))
        }
        let deadline = system.now() + maximumDuration
        do {
            try check(deadline)
            // The helper has exited and its pipes are closed before PID capture.
            // Our own helper's expected creation/exit never becomes PID churn.
            let mountedBefore = try await system.mountedImages(deadline: deadline)
            try check(deadline)
            guard mountedBefore.isEmpty else {
                return .unavailable(reason: InstallerUseEvidence.attachedImageLimitation)
            }
            switch try observeCurrentUserHandles(for: target, deadline: deadline) {
            case .observedHandleUse(let reason): return .observedUse(reason: reason)
            case .noHandleUseObserved: break
            case .unavailable(let reason): return .unavailable(reason: reason)
            }
            let mountedAfter = try await system.mountedImages(deadline: deadline)
            try check(deadline)
            guard mountedAfter.isEmpty else {
                return .unavailable(reason: InstallerUseEvidence.attachedImageLimitation)
            }
            return .noUseObserved
        } catch InstallerUseReadError.unavailable(let reason) {
            return .unavailable(reason: reason)
        } catch is CancellationError {
            return .unavailable(reason: String(localized: "The file-use observation was cancelled."))
        } catch {
            return .unavailable(reason: String(localized: "File-use evidence could not be completely read in the stated scope."))
        }
    }

    /// Uses exactly the production handle scanner, without manufacturing an
    /// empty mount inventory or returning the full provider's evidence type.
    func currentUserHandleDiagnostic(for target: InstallerUseTarget) -> InstallerCurrentUserHandleDiagnostic {
        guard isValidRequest(target) else {
            return .unavailable(reason: String(localized: "The file-use observation request is invalid."))
        }
        let deadline = system.now() + maximumDuration
        do {
            try check(deadline)
            return try observeCurrentUserHandles(for: target, deadline: deadline)
        } catch InstallerUseReadError.unavailable(let reason) {
            return .unavailable(reason: reason)
        } catch is CancellationError {
            return .unavailable(reason: String(localized: "The file-use observation was cancelled."))
        } catch {
            return .unavailable(reason: String(localized: "File-use evidence could not be completely read in the stated scope."))
        }
    }

    private func isValidRequest(_ target: InstallerUseTarget) -> Bool {
        (1...16_384).contains(maximumProcesses) &&
            (1...65_536).contains(maximumHandles) &&
            maximumDuration.isFinite && maximumDuration > 0 && maximumDuration <= 30 &&
            target.inode != 0 && target.device <= UInt64(UInt32.max) &&
            target.path.hasPrefix("/") && !target.path.utf8.contains(0) &&
            target.observerRetainedFileDescriptors.allSatisfy({ $0 >= 0 })
    }

    private func observeCurrentUserHandles(for target: InstallerUseTarget, deadline: TimeInterval) throws -> InstallerCurrentUserHandleDiagnostic {
        let before = try pidSet(system.processes(maximum: maximumProcesses))
        guard before.contains(system.observerPID) else {
            throw InstallerUseReadError.unavailable(String(localized: "The current-user process list is incomplete."))
        }
        var identities: [Int32: InstallerUseProcessIdentity] = [:]
        // Inspect self first; other open self FDs must not be hidden by the
        // one retained observation handle excluded below.
        let ordered = before.sorted { a, b in
            let aIsObserver = a == system.observerPID, bIsObserver = b == system.observerPID
            if aIsObserver != bIsObserver { return aIsObserver }
            return a < b
        }
        for pid in ordered {
            try check(deadline)
            let identity = try verifiedIdentity(pid: pid)
            identities[pid] = identity
            if !identity.isZombie {
                let fds = try handleSet(system.descriptors(pid: pid, maximum: maximumHandles))
                let ports = try handleSet(system.fileports(pid: pid, maximum: maximumHandles))
                var descriptorIdentities: [UInt32: InstallerUseFileIdentity] = [:]
                var portIdentities: [UInt32: InstallerUseFileIdentity] = [:]
                for fd in fds where fd.isVnode {
                    try check(deadline)
                    guard let descriptor = Int32(exactly: fd.number) else {
                        throw InstallerUseReadError.unavailable(String(localized: "An open-file descriptor could not be validated."))
                    }
                    let file = try system.descriptorIdentity(pid: pid, descriptor: descriptor)
                    descriptorIdentities[fd.number] = file
                    if file == target.identity {
                        if pid == system.observerPID && target.observerRetainedFileDescriptors.contains(descriptor) { continue }
                        return .observedHandleUse(reason: String(localized: "A current-user process has this file open."))
                    }
                    // A claimed retained target descriptor that was reused
                    // must block, even when its new identity is unrelated.
                    if pid == system.observerPID && target.observerRetainedFileDescriptors.contains(descriptor) {
                        throw InstallerUseReadError.unavailable(String(localized: "The retained observation handle changed."))
                    }
                }
                for port in ports where port.isVnode {
                    try check(deadline)
                    let file = try system.fileportIdentity(pid: pid, port: port.number)
                    portIdentities[port.number] = file
                    if file == target.identity {
                        return .observedHandleUse(reason: String(localized: "A current-user process retains a fileport for this file."))
                    }
                }
                try check(deadline)
                guard fds == (try handleSet(system.descriptors(pid: pid, maximum: maximumHandles))),
                      ports == (try handleSet(system.fileports(pid: pid, maximum: maximumHandles))) else {
                    throw InstallerUseReadError.unavailable(String(localized: "Open-file handles changed during the observation. Check again."))
                }
                // Same handle number/type does not establish same vnode:
                // close/reopen and fileport-name reuse must also be checked.
                for (number, expected) in descriptorIdentities {
                    try check(deadline)
                    let actual = try system.descriptorIdentity(pid: pid, descriptor: Int32(number))
                    guard actual == expected else {
                        throw InstallerUseReadError.unavailable(String(localized: "An open-file descriptor changed its file identity. Check again."))
                    }
                }
                for (number, expected) in portIdentities {
                    try check(deadline)
                    let actual = try system.fileportIdentity(pid: pid, port: number)
                    guard actual == expected else {
                        throw InstallerUseReadError.unavailable(String(localized: "A fileport changed its file identity. Check again."))
                    }
                }
                if pid == system.observerPID {
                    let observed = Set(fds.filter(\.isVnode).compactMap { Int32(exactly: $0.number) })
                    guard target.observerRetainedFileDescriptors.isSubset(of: observed) else {
                        throw InstallerUseReadError.unavailable(String(localized: "A retained observation handle is no longer present."))
                    }
                }
            }
            try check(deadline)
            guard identity == (try verifiedIdentity(pid: pid)) else {
                throw InstallerUseReadError.unavailable(String(localized: "A process changed identity during the observation. Check again."))
            }
        }
        try check(deadline)
        guard before == (try pidSet(system.processes(maximum: maximumProcesses))) else {
            throw InstallerUseReadError.unavailable(String(localized: "The current-user process list changed. Check again."))
        }
        // Revalidate all identities again: a PID could have been reused
        // after its row completed but before the second list was captured.
        for pid in ordered {
            try check(deadline)
            guard identities[pid] == (try verifiedIdentity(pid: pid)) else {
                throw InstallerUseReadError.unavailable(String(localized: "A process exited or changed identity. Check again."))
            }
        }
        return .noHandleUseObserved
    }

    private func verifiedIdentity(pid: Int32) throws -> InstallerUseProcessIdentity {
        let identity = try system.identity(pid: pid)
        guard identity.pid == pid, identity.uid == system.currentUID,
              identity.startSeconds > 0, identity.startMicroseconds < 1_000_000 else {
            throw InstallerUseReadError.unavailable(String(localized: "A current-user process identity could not be verified."))
        }
        return identity
    }

    private func pidSet(_ values: [Int32]) throws -> Set<Int32> {
        let unique = Set(values)
        guard !values.isEmpty, values.count <= maximumProcesses,
              unique.count == values.count, values.allSatisfy({ $0 > 0 }) else {
            throw InstallerUseReadError.unavailable(String(localized: "The current-user process list is incomplete or exceeded its limit."))
        }
        return unique
    }

    private func handleSet(_ values: [InstallerUseHandle]) throws -> Set<InstallerUseHandle> {
        guard values.count <= maximumHandles,
              Set(values.map(\.number)).count == values.count else {
            throw InstallerUseReadError.unavailable(String(localized: "The open-file list is incomplete or exceeded its limit."))
        }
        return Set(values)
    }

    private func check(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard system.now() < deadline else {
            throw InstallerUseReadError.unavailable(String(localized: "The file-use observation reached its time limit."))
        }
    }
}

struct NativeInstallerUseSystem: InstallerUseSystemReading {
    var currentUID: UInt32 { geteuid() }
    var observerPID: Int32 { getpid() }
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func processes(maximum: Int) throws -> [Int32] {
        var values = [pid_t](repeating: 0, count: maximum + 1)
        errno = 0
        let bytes = values.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), currentUID, $0.baseAddress, Int32($0.count))
        }
        let error = errno
        let count = try InstallerUseNativeParsing.listCount(bytes: bytes, error: error,
            stride: MemoryLayout<pid_t>.stride, maximum: maximum, permitsEmpty: false)
        return Array(values.prefix(count))
    }

    func identity(pid: Int32) throws -> InstallerUseProcessIdentity {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        // Public TBSDINFO's nonzero argument includes zombie metadata; only a
        // positively identified, stable zombie may skip the handle walk.
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 1, &info, size)
        let error = errno
        guard bytes == size else { throw unreadable(pid: pid, stage: "PROC_PIDTBSDINFO", code: error) }
        return .init(pid: Int32(bitPattern: info.pbi_pid), uid: info.pbi_uid,
                     startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
                     isZombie: info.pbi_status == UInt32(SZOMB))
    }

    func descriptors(pid: Int32, maximum: Int) throws -> [InstallerUseHandle] {
        var values = [proc_fdinfo](repeating: proc_fdinfo(), count: maximum + 1)
        errno = 0
        let bytes = values.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        let error = errno
        let count = try nativeCount(bytes: bytes, error: error, stride: MemoryLayout<proc_fdinfo>.stride,
                                    maximum: maximum, pid: pid, stage: "PROC_PIDLISTFDS")
        return try values.prefix(count).map {
            guard $0.proc_fd >= 0 else { throw unreadable(pid: pid, stage: "PROC_PIDLISTFDS", code: 0) }
            return .init(number: UInt32($0.proc_fd), isVnode: $0.proc_fdtype == UInt32(PROX_FDTYPE_VNODE))
        }
    }

    func fileports(pid: Int32, maximum: Int) throws -> [InstallerUseHandle] {
        var values = [proc_fileportinfo](repeating: proc_fileportinfo(), count: maximum + 1)
        errno = 0
        let bytes = values.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFILEPORTS, 0, $0.baseAddress, Int32($0.count))
        }
        let error = errno
        let count = try nativeCount(bytes: bytes, error: error, stride: MemoryLayout<proc_fileportinfo>.stride,
                                    maximum: maximum, pid: pid, stage: "PROC_PIDLISTFILEPORTS")
        return try values.prefix(count).map {
            guard $0.proc_fileport != 0 else { throw unreadable(pid: pid, stage: "PROC_PIDLISTFILEPORTS", code: 0) }
            return .init(number: $0.proc_fileport, isVnode: $0.proc_fdtype == UInt32(PROX_FDTYPE_VNODE))
        }
    }

    func descriptorIdentity(pid: Int32, descriptor: Int32) throws -> InstallerUseFileIdentity {
        var info = vnode_fdinfo()
        let size = Int32(MemoryLayout<vnode_fdinfo>.size)
        errno = 0
        let bytes = proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEINFO, &info, size)
        let error = errno
        guard bytes == size else { throw unreadable(pid: pid, stage: "PROC_PIDFDVNODEINFO", code: error) }
        return try InstallerUseNativeParsing.fileIdentity(info.pvi.vi_stat)
    }

    func fileportIdentity(pid: Int32, port: UInt32) throws -> InstallerUseFileIdentity {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        errno = 0
        let bytes = proc_pidfileportinfo(pid, port, PROC_PIDFILEPORTVNODEPATHINFO, &info, size)
        let error = errno
        guard bytes == size else { throw unreadable(pid: pid, stage: "PROC_PIDFILEPORTVNODEPATHINFO", code: error) }
        // Ignore paths, argv, and file contents. Device + inode survives rename.
        return try InstallerUseNativeParsing.fileIdentity(info.pvip.vip_vi.vi_stat)
    }

    func mountedImages(deadline: TimeInterval) async throws -> Set<InstallerUseFileIdentity> {
        let data = try await InstallerDiskImageInventory.shared.read(deadline: deadline)
        try InstallerUseNativeParsing.requireEmptyMountedInventory(data: data)
        return []
    }

    private func nativeCount(bytes: Int32, error: Int32, stride: Int, maximum: Int, pid: Int32, stage: String) throws -> Int {
        do {
            return try InstallerUseNativeParsing.listCount(bytes: bytes, error: error, stride: stride,
                                                           maximum: maximum, permitsEmpty: true)
        } catch _ {
            throw unreadable(pid: pid, stage: stage, code: error)
        }
    }

    private func unreadable(pid: Int32, stage: String, code: Int32) -> InstallerUseReadError {
        .unavailable(String(localized: "Current-user process \(pid) could not be completely checked at \(stage) (system error \(code)). It may have exited, changed, exceeded a limit, or denied access."))
    }
}

/// Independent parsing tests exercise short reads, zero/error ambiguity and the
/// exact device-bit representation without consulting any live process list.
enum InstallerUseNativeParsing {
    static func listCount(bytes: Int32, error: Int32, stride: Int, maximum: Int, permitsEmpty: Bool) throws -> Int {
        guard stride > 0, maximum > 0, bytes >= 0, error == 0,
              Int(bytes) % stride == 0, Int(bytes) / stride <= maximum,
              permitsEmpty || bytes > 0 else {
            throw InstallerUseReadError.unavailable(String(localized: "Native file-use coverage was denied, truncated, or incomplete."))
        }
        return Int(bytes) / stride
    }

    static func fileIdentity(_ value: vinfo_stat) throws -> InstallerUseFileIdentity {
        guard value.vst_ino != 0, value.vst_mode != 0 else {
            throw InstallerUseReadError.unavailable(String(localized: "An open-file identity could not be read."))
        }
        return .init(device: UInt64(value.vst_dev), inode: value.vst_ino)
    }

    static func identity(at url: URL) throws -> InstallerUseFileIdentity {
        guard url.isFileURL else { throw mountUnavailable() }
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return stat(path, &info) == 0
        }), info.st_ino != 0 else { throw mountUnavailable() }
        return .init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    /// Modern hdiutil records need not include an original-source alias or
    /// identity. This supported subset accepts ONLY a complete empty inventory.
    /// Every nonempty record blocks, including apparently unrelated images.
    /// Path matching must never be used to manufacture negative mount evidence.
    static func requireEmptyMountedInventory(data: Data) throws {
        guard !data.isEmpty, data.count <= InstallerDiskImageInventory.maximumOutput,
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { throw mountUnavailable() }
        guard images.isEmpty else {
            throw InstallerUseReadError.unavailable(InstallerUseEvidence.attachedImageLimitation)
        }
    }

    private static func mountUnavailable() -> InstallerUseReadError {
        .unavailable(String(localized: "The disk-image inventory is incomplete or unreadable; no file was moved. You may eject images you opened yourself and check again, but leave system-managed images alone. MoeKit does not classify or eject images; unsupported system inventory can keep this action unavailable."))
    }

}

/// Only this fixed, read-only system invocation is permitted here. Apple DTS
/// recommends hdiutil's machine-readable info output for attached source paths:
/// https://developer.apple.com/forums/thread/721232
/// No target path, shell, user arguments, environment, stdin, or temp file is used.
actor InstallerDiskImageInventory {
    static let shared = InstallerDiskImageInventory()
    static let maximumOutput = 2 * 1_024 * 1_024
    private var pending: InstallerDiskImageRead?

    func read(deadline: TimeInterval) async throws -> Data {
        // A timed-out helper is retained and drained without signals. Refuse a
        // second launch while it remains pending; never accumulate subprocesses.
        if let pending, !pending.isFinished {
            throw InstallerUseReadError.unavailable(String(localized: "The disk-image inventory is still pending. Check again after it finishes."))
        }
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw timeout() }
        let read = InstallerDiskImageRead()
        pending = read
        read.start()
        while !read.isFinished {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw timeout() }
            try await Task.sleep(for: .milliseconds(25))
        }
        // Do not clear someone else's new invocation after actor reentrancy.
        if pending === read { pending = nil }
        return try read.result()
    }

    private func timeout() -> InstallerUseReadError {
        .unavailable(String(localized: "The disk-image inventory reached its time limit; no file was moved."))
    }
}

/// Lock-protected completion state; the worker owns Process and all pipe handles.
/// Buffers are bounded even after a timeout. No process name/PID is used to signal
/// or control another process. A stuck OS helper may remain pending until exit.
private final class InstallerDiskImageRead: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: Result<Data, InstallerUseReadError>?
    var isFinished: Bool { lock.withLock { completion != nil } }

    func start() {
        Task.detached(priority: .utility) { [self] in
            let process = Process()
            let output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["info", "-plist"]
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            let result: Result<Data, InstallerUseReadError>
            do {
                try Self.validateSystemHelper()
                try process.run()
                try? output.fileHandleForWriting.close()
                try? errors.fileHandleForWriting.close()
                let stderr = Task.detached(priority: .utility) {
                    Self.drain(errors.fileHandleForReading, maximum: 8_192)
                }
                let stdout = Self.drain(output.fileHandleForReading, maximum: InstallerDiskImageInventory.maximumOutput)
                process.waitUntilExit()
                let errorOutput = await stderr.value
                guard process.terminationReason == .exit, process.terminationStatus == 0,
                      let stdout, let errorOutput, errorOutput.isEmpty else {
                    throw InstallerUseReadError.unavailable(String(localized: "The disk-image inventory failed, emitted diagnostics, or exceeded its output limit."))
                }
                result = .success(stdout)
            } catch {
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
                try? errors.fileHandleForReading.close()
                try? errors.fileHandleForWriting.close()
                result = .failure(.unavailable(String(localized: "The read-only disk-image inventory could not complete.")))
            }
            lock.withLock { completion = result }
        }
    }

    func result() throws -> Data {
        try lock.withLock {
            guard let completion else { throw InstallerUseReadError.unavailable("Disk-image inventory is pending.") }
            return try completion.get()
        }
    }

    /// Root-owned, non-writable system chain; no untrusted PATH resolution or
    /// symlink can substitute an executable. A privileged OS replacement is
    /// outside this ordinary-user observation's threat model.
    private static func validateSystemHelper() throws {
        for path in ["/", "/usr", "/usr/bin", "/usr/bin/hdiutil"] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == 0,
                  (info.st_mode & 0o022) == 0,
                  (info.st_mode & S_IFMT) == (path == "/usr/bin/hdiutil" ? S_IFREG : S_IFDIR) else {
                throw InstallerUseReadError.unavailable("The fixed system disk-image helper could not be verified.")
            }
        }
    }

    private static func drain(_ handle: FileHandle, maximum: Int) -> Data? {
        defer { try? handle.close() }
        var output = Data()
        var exceeded = false
        do {
            while let bytes = try handle.read(upToCount: 16_384), !bytes.isEmpty {
                if !exceeded && bytes.count <= maximum - output.count { output.append(bytes) }
                else { exceeded = true }
            }
            return exceeded ? nil : output
        } catch { return nil }
    }
}
