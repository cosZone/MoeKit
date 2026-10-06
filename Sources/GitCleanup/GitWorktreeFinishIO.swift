import CryptoKit
import Darwin
import Foundation

enum GitFinishIO {
    static func privateChild(_ parent: InstallerDirectoryAnchor, _ name: String, create: Bool, exclusive: Bool = false) throws -> InstallerDirectoryAnchor {
        try InstallerFileAccess.basename(name); try parent.validate()
        if create {
            if mkdirat(parent.fd, name, 0o700) != 0 {
                guard errno == EEXIST, !exclusive else { throw GitCleanupFailure.occupied }
            }
            guard fsync(parent.fd) == 0 else { throw GitCleanupFailure.changed }
        }
        let child = try parent.child(name)
        try InstallerFileAccess.validatePrivate(child.fd, directory: true)
        return child
    }
    static func descend(_ root: InstallerDirectoryAnchor, components: [String]) throws -> InstallerDirectoryAnchor {
        var result = root
        for name in components { result = try result.child(name) }
        return result
    }
    static func refParent(_ common: InstallerDirectoryAnchor, branch: String) throws -> (InstallerDirectoryAnchor, String) {
        let parts = try GitCleanupInspection.branchComponents(branch)
        return (try descend(common, components: ["refs", "heads"] + Array(parts.dropLast())), parts.last!)
    }
    static func topLevel(_ capture: GitCleanupCapture) -> [String] {
        Set(Set(capture.files.keys).union(capture.directories.keys).filter { !$0.isEmpty }.map { String($0.split(separator: "/")[0]) }).sorted()
    }
    static func writeNew(_ data: Data, parent: InstallerDirectoryAnchor, name: String, mode: mode_t = 0o600) throws {
        try InstallerFileAccess.basename(name); try parent.validate()
        let fd = openat(parent.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw GitCleanupFailure.occupied }
        defer { close(fd) }
        try write(data, fd: fd)
        guard fsync(fd) == 0, fsync(parent.fd) == 0 else { throw GitCleanupFailure.changed }
    }
    static func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw GitCleanupFailure.changed }
                offset += count
            }
        }
    }
    /// Zero all stat cache fields. Git must recheck the newly materialized files.
    /// Never copy source inode/stat shortcuts, flags, conflict stages or extensions.
    static func freshIndex(_ index: GitPlainIndex) throws -> Data {
        var data = Data("DIRC".utf8)
        func integer(_ value: UInt32) { data.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
        integer(2); integer(UInt32(index.entries.count))
        for entry in index.entries {
            let start = data.count
            data.append(Data(repeating: 0, count: 24)); integer(entry.executable ? 0o100755 : 0o100644)
            data.append(Data(repeating: 0, count: 12))
            let hex = Array(entry.oid.utf8)
            guard hex.count == 40 else { throw GitCleanupFailure.unsupported }
            for offset in stride(from: 0, to: 40, by: 2) {
                guard let byte = UInt8(String(decoding: hex[offset...offset + 1], as: UTF8.self), radix: 16) else { throw GitCleanupFailure.unsupported }
                data.append(byte)
            }
            let path = Array(entry.path.utf8), flags = UInt16(min(path.count, 0x0fff))
            data.append(contentsOf: [UInt8(flags >> 8), UInt8(flags & 255)])
            data.append(contentsOf: path); data.append(0)
            data.append(Data(repeating: 0, count: (8 - (data.count - start) % 8) % 8))
        }
        let checksum = Insecure.SHA1.hash(data: data)
        data.append(contentsOf: checksum)
        guard try GitPlainIndex.parse(data).treeOID == index.treeOID else { throw GitCleanupFailure.changed }
        return data
    }
}

final class GitFinishLock {
    let url: URL
    private let parent: InstallerDirectoryAnchor
    private let name: String
    private let fd: Int32
    private var identity: InstallerFileSnapshot
    private var committedName: String?
    private var retain = false
    var committed: Bool { committedName != nil }
    var recoveryRecord: [String: String] {
        ["path": url.path, "device": String(identity.device), "inode": String(identity.inode),
         "bytes": String(identity.bytes), "ownerUID": String(identity.uid)]
    }
    init(parent: InstallerDirectoryAnchor, name: String) throws {
        try InstallerFileAccess.basename(name); try parent.validate()
        self.parent = parent; self.name = name; self.url = parent.url.appendingPathComponent(name)
        try InstallerFileAccess.rejectMutationGrantingACL(parent.fd)
        let opened = openat(parent.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard opened >= 0 else { throw GitCleanupFailure.locked }
        fd = opened
        do {
            try InstallerFileAccess.validatePrivate(opened, directory: false)
            identity = try InstallerFileAccess.snapshot(opened)
            guard fsync(opened) == 0, fsync(parent.fd) == 0 else { throw GitCleanupFailure.changed }
        } catch {
            if let held = try? InstallerFileAccess.snapshot(opened), let named = try? InstallerFileAccess.snapshotAt(parent.fd, name), held == named { _ = unlinkat(parent.fd, name, 0) }
            close(opened); throw error
        }
    }
    deinit {
        if !retain && !committed {
            do { try validate(); _ = unlinkat(parent.fd, name, 0); _ = fsync(parent.fd) } catch {}
        }
        close(fd)
    }
    func write(_ data: Data) throws {
        try validate()
        guard !committed, identity.bytes == 0 else { throw GitCleanupFailure.changed }
        try GitFinishIO.write(data, fd: fd)
        guard fsync(fd) == 0 else { throw GitCleanupFailure.changed }
        identity = try InstallerFileAccess.snapshot(fd)
        try validate()
    }
    func validate() throws {
        try parent.validate()
        let held = try InstallerFileAccess.snapshot(fd)
        let named = try InstallerFileAccess.snapshotAt(parent.fd, committedName ?? name)
        guard committed ? identity.matchesCaptured(held) && identity.matchesCaptured(named) : identity == held && identity == named else { throw GitCleanupFailure.changed }
    }
    func commit(to destination: String) throws {
        try validate(); guard !committed else { throw GitCleanupFailure.expired }
        try InstallerFileAccess.exclusiveMove(from: parent, name: name, to: parent, destinationName: destination)
        committedName = destination
        try validate()
        guard fsync(parent.fd) == 0 else { throw GitCleanupFailure.changed }
    }
    func retainForRecovery() { retain = true }
}
