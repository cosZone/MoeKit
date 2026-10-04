import Darwin
import Foundation

/// All native mutation paths use this strict no-follow chain. Unlike discovery,
/// it does not canonicalize symlink ancestors or accept system path aliases.
final class InstallerDirectoryAnchor {
    let url: URL
    let fd: Int32
    let identity: InstallerFileSnapshot
    let parent: InstallerDirectoryAnchor?
    let name: String?

    private init(url: URL, fd: Int32, parent: InstallerDirectoryAnchor?, name: String?) throws {
        self.url = url; self.fd = fd; self.parent = parent; self.name = name
        identity = try InstallerFileAccess.snapshot(fd)
        guard identity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { throw InstallerTrashFailure.changed }
    }
    deinit { close(fd) }
    static func open(_ url: URL) throws -> InstallerDirectoryAnchor {
        let parts = try InstallerFileAccess.components(url)
        guard parts.count <= 100 else { throw InstallerTrashFailure.unsupported }
        let descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw InstallerTrashFailure.changed }
        var current: InstallerDirectoryAnchor
        do { current = try .init(url: URL(fileURLWithPath: "/"), fd: descriptor, parent: nil, name: nil) }
        catch { close(descriptor); throw error }
        for part in parts { current = try current.child(part) }
        try current.validate()
        return current
    }
    func child(_ name: String) throws -> InstallerDirectoryAnchor {
        try InstallerFileAccess.basename(name); try validate()
        let descriptor = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw InstallerTrashFailure.changed }
        let child: InstallerDirectoryAnchor
        do { child = try .init(url: url.appendingPathComponent(name), fd: descriptor, parent: self, name: name) }
        catch { close(descriptor); throw error }
        try child.validate(); return child
    }
    func validate() throws {
        if let parent, let name {
            try parent.validate()
            guard identity.matchesDirectory(try InstallerFileAccess.snapshotAt(parent.fd, name)) else { throw InstallerTrashFailure.changed }
        }
        guard identity.matchesDirectory(try InstallerFileAccess.snapshot(fd)) else { throw InstallerTrashFailure.changed }
    }
    func rejectGitAncestors() throws {
        var current: InstallerDirectoryAnchor? = self
        while let node = current {
            var s = stat()
            let result = fstatat(node.fd, ".git", &s, AT_SYMLINK_NOFOLLOW)
            guard result != 0, errno == ENOENT else { throw InstallerTrashFailure.protected }
            current = node.parent
        }
    }
}

final class InstallerFileDescriptor {
    let fd: Int32
    init(parent: InstallerDirectoryAnchor, name: String) throws {
        try InstallerFileAccess.basename(name); try parent.validate()
        fd = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw InstallerTrashFailure.changed }
    }
    deinit { close(fd) }
}

enum InstallerFileAccess {
    static func basename(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0), name.utf8.count <= 255 else {
            throw InstallerTrashFailure.unsupported
        }
    }
    static func components(_ url: URL) throws -> [String] {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), !url.path.utf8.contains(0), url.path.utf8.count <= 4096 else { throw InstallerTrashFailure.unsupported }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in parts { try basename(part) }
        return parts
    }
    static func snapshot(_ fd: Int32) throws -> InstallerFileSnapshot {
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw InstallerTrashFailure.changed }
        return snapshot(status)
    }
    static func snapshotAt(_ fd: Int32, _ name: String) throws -> InstallerFileSnapshot {
        try basename(name)
        var status = stat()
        guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw InstallerTrashFailure.changed }
        return snapshot(status)
    }
    private static func snapshot(_ s: stat) -> InstallerFileSnapshot {
        .init(device: UInt64(UInt32(bitPattern: s.st_dev)), inode: UInt64(s.st_ino), mode: UInt32(s.st_mode), uid: s.st_uid, gid: s.st_gid,
              links: UInt64(s.st_nlink), flags: s.st_flags, bytes: s.st_size,
              modifiedSeconds: Int64(s.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(s.st_mtimespec.tv_nsec),
              changedSeconds: Int64(s.st_ctimespec.tv_sec), changedNanoseconds: Int64(s.st_ctimespec.tv_nsec))
    }
    static func validateRegular(_ s: InstallerFileSnapshot) throws {
        guard s.mode & UInt32(S_IFMT) == UInt32(S_IFREG), s.links == 1, s.uid == geteuid(), s.mode & 0o022 == 0,
              s.flags == 0, s.bytes > 0 else { throw InstallerTrashFailure.unsupported }
    }
    static func validatePrivate(_ fd: Int32, directory: Bool) throws {
        let s = try snapshot(fd)
        guard s.uid == geteuid(), s.mode & 0o777 == (directory ? 0o700 : 0o600), s.flags == 0,
              s.mode & UInt32(S_IFMT) == UInt32(directory ? S_IFDIR : S_IFREG), directory || s.links == 1 else { throw InstallerTrashFailure.unsafeRecovery }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { throw InstallerTrashFailure.unsafeRecovery }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw InstallerTrashFailure.unsafeRecovery }
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        // Darwin returns 0 for an existing entry, and -1/EINVAL at the end
        // of a valid ACL (including empty). This differs from Linux POSIX ACL.
        guard result == -1, errno == EINVAL else { throw InstallerTrashFailure.unsafeRecovery }
    }
    static func validateVolume(_ fd: Int32, url: URL) throws {
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0, volume.f_flags & UInt32(MNT_RDONLY) == 0 else {
            throw InstallerTrashFailure.unsupported
        }
        let type = withUnsafeBytes(of: &volume.f_fstypename) { bytes in String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let values = try url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .isUbiquitousItemKey])
        guard type == "apfs", values.volumeIsLocal == true, values.volumeIsInternal == true,
              values.volumeIsRemovable == false, values.volumeIsEjectable == false, values.isUbiquitousItem == false else { throw InstallerTrashFailure.unsupported }
    }
    static func rejectCloudAttributes(_ fd: Int32) throws {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0, size <= 64 * 1024 else { throw InstallerTrashFailure.unsupported }
        if size == 0 { return }
        var buffer = [CChar](repeating: 0, count: size)
        guard flistxattr(fd, &buffer, size, 0) == size, buffer.last == 0 else { throw InstallerTrashFailure.changed }
        for bytes in buffer.split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
            guard !name.contains("fileprovider"), !name.contains("ubiquity"), !name.contains("icloud") else { throw InstallerTrashFailure.unsupported }
        }
    }
    static func exclusiveMove(from parent: InstallerDirectoryAnchor, name: String, to destination: InstallerDirectoryAnchor, destinationName: String) throws {
        try basename(name); try basename(destinationName)
        try parent.validate(); try destination.validate()
        guard parent.identity.device == destination.identity.device else { throw InstallerTrashFailure.unsupportedRename }
        guard renameatx_np(parent.fd, name, destination.fd, destinationName, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw InstallerTrashFailure.collision }
            throw InstallerTrashFailure.unsupportedRename
        }
    }
    static func assertAbsent(_ parent: InstallerDirectoryAnchor, _ name: String) throws {
        var s = stat()
        guard fstatat(parent.fd, name, &s, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw InstallerTrashFailure.collision }
    }
}
