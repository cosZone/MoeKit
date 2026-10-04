import Foundation
import Darwin

/// An advisory transaction for cooperating MoeKit writers, not exclusion of
/// arbitrary editors/sync tools. Keep the sidecar inode permanently: unlinking
/// a "stale" lock can create two independently locked inodes for the same catalog.
/// All data IO uses this one opened directory, including the atomic rename.
struct CatalogWriteCoordinator {
    static let catalogName = "projects.json"
    static let lockName = "projects.json.lock"

    private let directory: Int32
    private let lock: Int32
    private let directoryURL: URL

    static func withExclusiveAccess<T>(at directoryURL: URL,
                                      body: (CatalogWriteCoordinator) throws -> T) throws -> T {
        // Attributes apply only to newly created directories; existing directory
        // permissions/ACLs are deliberately not migrated or chmod-ed.
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = try openDirectory(directoryURL)
        defer { Darwin.close(directory) }
        let lock = Darwin.openat(directory, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw posixError() }
        defer { Darwin.close(lock) } // Closing also releases flock, even on errors.
        try validateLock(status(lock))
        // Unqualified overload resolution selects the C function; Darwin.flock
        // resolves to the identically named C struct in the macOS Swift SDK.
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { throw CatalogPersistence.CatalogError.writerBusy }
            throw posixError(code)
        }
        let writer = CatalogWriteCoordinator(directory: directory, lock: lock, directoryURL: directoryURL)
        try writer.verifyIdentity()
        return try body(writer)
    }

    func readExistingData() throws -> Data? {
        let file = Darwin.openat(directory, Self.catalogName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP { throw BoundedRegularFileReader.ReadError.symbolicLink }
            throw Self.posixError(code)
        }
        defer { Darwin.close(file) }
        return try BoundedRegularFileReader.read(descriptor: file, maximumBytes: CatalogPersistence.maximumBytes)
    }

    /// The rename is the commit point. No throwing operation follows it, so a
    /// reported failure cannot conceal a successful replacement or stale snapshot.
    /// This does not promise persistence across power loss (no directory fsync).
    func replace(with data: Data, beforeRename: () throws -> Void = {}) throws {
        let name = ".projects-\(UUID().uuidString).tmp"
        let file = Darwin.openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.posixError() }
        var committed = false
        defer {
            // Remove only our own still-named temporary file on failure. Never
            // unlink the sidecar or an externally replaced temporary pathname.
            if !committed, let opened = try? Self.status(file) {
                var named = stat()
                if Darwin.fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   Self.sameIdentity(opened, named) {
                    Darwin.unlinkat(directory, name, 0)
                }
            }
            Darwin.close(file)
        }
        try Self.writeAll(data, descriptor: file)
        guard Darwin.fsync(file) == 0 else { throw Self.posixError() }
        let prepared = try Self.status(file)
        try beforeRename()
        try verifyIdentity()
        let current = try Self.status(file)
        var named = stat()
        guard current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), current.st_nlink == 1,
              Darwin.fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameIdentity(current, named), named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              prepared.st_size == current.st_size,
              prepared.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec,
              prepared.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec,
              prepared.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec,
              prepared.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec else {
            throw CatalogPersistence.CatalogError.changedSinceLoad
        }
        guard Darwin.renameat(directory, name, directory, Self.catalogName) == 0 else { throw Self.posixError() }
        committed = true
    }

    /// Injection is only for exercising short writes/EINTR deterministically;
    /// production always calls Darwin.write on the exclusively created tempfile.
    static func writeAll(_ data: Data, descriptor: Int32,
                         write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw posixError(code)
                }
                guard count > 0, count <= bytes.count - offset else { throw posixError(EIO) }
                offset += count
            }
        }
    }

    private func verifyIdentity() throws {
        let opened = try Self.status(lock)
        try Self.validateLock(opened)
        var named = stat()
        guard Darwin.fstatat(directory, Self.lockName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameIdentity(opened, named) else { throw CatalogPersistence.CatalogError.changedSinceLoad }
        try Self.validateLock(named)
        let currentDirectory = try Self.openDirectory(directoryURL)
        defer { Darwin.close(currentDirectory) }
        guard Self.sameIdentity(try Self.status(directory), try Self.status(currentDirectory)) else {
            throw CatalogPersistence.CatalogError.changedSinceLoad
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw BoundedRegularFileReader.ReadError.invalidPath }
            // A trailing slash would make a final symlink an ancestor and defeat
            // O_NOFOLLOW. Remove only terminal slash bytes, retaining root and all
            // interior components exactly as provided by the filesystem URL.
            var bytes = Array(UnsafeBufferPointer(start: path, count: Darwin.strlen(path)))
            while bytes.count > 1, bytes.last == CChar(47) { bytes.removeLast() }
            bytes.append(0)
            // Ancestor aliases such as macOS /tmp -> /private/tmp remain valid;
            // the catalog directory itself must not be a symbolic link.
            let opened = bytes.withUnsafeBufferPointer {
                Darwin.open($0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard opened >= 0 else { throw posixError() }
            return opened
        }
    }

    private static func status(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw posixError() }
        return value
    }

    private static func validateLock(_ value: stat) throws {
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_nlink == 1,
              value.st_uid == Darwin.geteuid(), value.st_mode & 0o077 == 0 else {
            throw CatalogPersistence.CatalogError.unsafeLock
        }
    }

    private static func sameIdentity(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
