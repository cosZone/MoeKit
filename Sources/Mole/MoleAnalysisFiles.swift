import CryptoKit
import Darwin
import Foundation

/// Descriptor-based checks and session storage. These reduce path races; they do
/// not defend against a malicious same-user process or confer an OS sandbox.
enum MoleAnalysisFiles {
    static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil,
              MoleLiveReportValidator.components(url.path) != nil else { throw MoleAnalysisFailure.invalidSelection }
    }

    static func canonicalURL(_ url: URL) throws -> URL {
        try validateLocalURL(url)
        guard let resolved = realpath(url.path, nil) else { throw MoleAnalysisFailure.invalidSelection }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        try openPath(url, directory: true)
    }

    static func openPath(_ url: URL, directory: Bool) throws -> Int32 {
        guard url.isFileURL, let parts = MoleLiveReportValidator.components(url.path), !parts.isEmpty else {
            throw MoleAnalysisFailure.invalidSelection
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw MoleAnalysisFailure.invalidSelection }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK |
                ((index < parts.count - 1 || directory) ? O_DIRECTORY : 0)
            let next = String(part).withCString { openat(fd, $0, flags) }
            close(fd)
            guard next >= 0 else { throw MoleAnalysisFailure.invalidSelection }
            fd = next
        }
        return fd
    }

    static func identity(_ fd: Int32) throws -> MoleFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw MoleAnalysisFailure.changedSelection }
        return MoleFileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }

    static func verifyAnalyzer(_ fd: Int32, release: MoleAnalyzerRelease) throws -> MoleFileIdentity {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o111 != 0, before.st_mode & 0o022 == 0,
              before.st_size == release.byteCount,
              before.st_uid == geteuid() || before.st_uid == 0 else {
            throw MoleAnalysisFailure.unsupportedBinary
        }
        try refuseQuarantine(fd)
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw MoleAnalysisFailure.unsupportedBinary }
        var hash = SHA256()
        var count = 0
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let amount = read(fd, &bytes, bytes.count)
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else { throw MoleAnalysisFailure.unsupportedBinary }
            if amount == 0 { break }
            count += amount
            guard count <= release.byteCount else { throw MoleAnalysisFailure.changedSelection }
            hash.update(data: Data(bytes.prefix(amount)))
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw MoleAnalysisFailure.changedSelection
        }
        guard count == release.byteCount, digest == release.sha256 else { throw MoleAnalysisFailure.unsupportedBinary }
        try refuseQuarantine(fd)
        return try identity(fd)
    }

    static func copyPinnedBytesAndAttributes(from source: Int32, to target: Int32, release: MoleAnalyzerRelease) throws {
        guard lseek(source, 0, SEEK_SET) == 0 else { throw MoleAnalysisFailure.changedSelection }
        var remaining = release.byteCount
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            try Task.checkCancellation()
            let capacity = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, capacity) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw MoleAnalysisFailure.changedSelection }
            var written = 0
            while written < count {
                try Task.checkCancellation()
                let amount = buffer.withUnsafeBytes { write(target, $0.baseAddress!.advanced(by: written), count - written) }
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw MoleAnalysisFailure.unsafePrivateDirectory }
                written += amount
            }
            remaining -= count
        }
        var extra: UInt8 = 0
        guard read(source, &extra, 1) == 0 else { throw MoleAnalysisFailure.changedSelection }
        // Copy security/origin attributes without an unbounded fcopyfile data pass.
        let namesSize = flistxattr(source, nil, 0, 0)
        guard namesSize >= 0, namesSize <= 64 * 1024 else { throw MoleAnalysisFailure.unsupportedBinary }
        if namesSize == 0 { return }
        var names = [CChar](repeating: 0, count: namesSize)
        guard flistxattr(source, &names, namesSize, 0) == namesSize, names.last == 0 else {
            throw MoleAnalysisFailure.changedSelection
        }
        var attributeBytes = 0
        for rawName in names.split(separator: 0) {
            try Task.checkCancellation()
            let name = String(decoding: rawName.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = fgetxattr(source, name, nil, 0, 0, 0)
            guard size >= 0, size <= 64 * 1024, attributeBytes <= 256 * 1024 - size else {
                throw MoleAnalysisFailure.unsupportedBinary
            }
            attributeBytes += size
            var value = [UInt8](repeating: 0, count: max(1, size))
            let received = value.withUnsafeMutableBytes { fgetxattr(source, name, $0.baseAddress, size, 0, 0) }
            guard received == size else { throw MoleAnalysisFailure.changedSelection }
            let copied = value.withUnsafeBytes { fsetxattr(target, name, $0.baseAddress, size, 0, 0) }
            guard copied == 0 else { throw MoleAnalysisFailure.unsafePrivateDirectory }
        }
    }

    static func refuseQuarantine(_ fd: Int32) throws {
        let size = fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0)
        guard size == -1, errno == ENOATTR else {
            throw MoleAnalysisFailure.quarantinedBinary
        }
    }

    static func privateParent() throws -> URL {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw MoleAnalysisFailure.unsafePrivateDirectory
        }
        // Canonicalize macOS's system aliases before the no-follow walk.
        return try canonicalURL(base).appendingPathComponent("com.yusixian.MoeKit.MoleAnalysis", isDirectory: true)
    }

    static func verifyReportPaths(_ report: MoleAnalyzeReport, root: URL, identity expected: MoleFileIdentity) throws {
        let rootFD = try openDirectory(root)
        defer { close(rootFD) }
        guard try identity(rootFD) == expected else { throw MoleAnalysisFailure.changedSelection }
        for path in report.entries.map(\.path) + report.largeFiles.map(\.path) {
            try Task.checkCancellation()
            let relative = String(path.dropFirst(root.path.count + 1))
            let parts = relative.split(separator: "/")
            var fd = dup(rootFD)
            guard fd >= 0 else { throw MoleAnalysisFailure.outsideScope }
            for part in parts.dropLast() {
                let next = String(part).withCString { openat(fd, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY) }
                close(fd)
                guard next >= 0 else { throw MoleAnalysisFailure.outsideScope }
                fd = next
            }
            var info = stat()
            let valid = parts.last.map { part in
                String(part).withCString { fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) } == 0
                    && (info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR)
            } ?? false
            close(fd)
            guard valid else { throw MoleAnalysisFailure.outsideScope }
        }
        let fresh = try openDirectory(root)
        defer { close(fresh) }
        guard try identity(fresh) == expected else { throw MoleAnalysisFailure.changedSelection }
    }
}

/// Owns open directory descriptors until all children have stopped and cleanup
/// has finished. Uncertain/foreign entries fail closed instead of following them.
final class MolePrivateSession {
    let url: URL
    let executable: URL
    let home: URL
    private let parentHandle: MoleOwnedDescriptor
    private let directoryHandle: MoleOwnedDescriptor
    private var parentFD: Int32 { parentHandle.rawValue }
    private var directoryFD: Int32 { directoryHandle.rawValue }
    private let identity: MoleFileIdentity
    private let name: String
    private var cleaned = false

    init(parent: URL, sourceFD: Int32, release: MoleAnalyzerRelease) throws {
        let base = parent.deletingLastPathComponent()
        let baseFD = try MoleAnalysisFiles.openDirectory(base)
        defer { close(baseFD) }
        let parentName = parent.lastPathComponent
        let made = parentName.withCString { mkdirat(baseFD, $0, 0o700) }
        guard made == 0 || errno == EEXIST else { throw MoleAnalysisFailure.unsafePrivateDirectory }
        let openedParent = parentName.withCString { openat(baseFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard openedParent >= 0 else { throw MoleAnalysisFailure.unsafePrivateDirectory }
        var parentInfo = stat()
        guard fstat(openedParent, &parentInfo) == 0, parentInfo.st_uid == geteuid(), parentInfo.st_mode & 0o077 == 0 else {
            close(openedParent); throw MoleAnalysisFailure.unsafePrivateDirectory
        }
        let sessionName = UUID().uuidString
        guard sessionName.withCString({ mkdirat(openedParent, $0, 0o700) }) == 0 else {
            close(openedParent); throw MoleAnalysisFailure.unsafePrivateDirectory
        }
        let openedSession = sessionName.withCString { openat(openedParent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard openedSession >= 0 else {
            let removed = sessionName.withCString { unlinkat(openedParent, $0, AT_REMOVEDIR) }
            close(openedParent)
            throw removed == 0 ? MoleAnalysisFailure.unsafePrivateDirectory : MoleAnalysisFailure.cleanupIncomplete
        }
        let sessionIdentity: MoleFileIdentity
        do { sessionIdentity = try MoleAnalysisFiles.identity(openedSession) }
        catch {
            close(openedSession)
            _ = sessionName.withCString { unlinkat(openedParent, $0, AT_REMOVEDIR) }
            close(openedParent)
            throw MoleAnalysisFailure.cleanupIncomplete
        }
        self.parentHandle = MoleOwnedDescriptor(openedParent)
        self.directoryHandle = MoleOwnedDescriptor(openedSession)
        self.identity = sessionIdentity
        self.name = sessionName
        self.url = parent.appendingPathComponent(sessionName, isDirectory: true)
        self.executable = url.appendingPathComponent("analyze-go")
        self.home = url.appendingPathComponent("home", isDirectory: true)
        do {
            guard mkdirat(directoryFD, "home", 0o700) == 0 else { throw MoleAnalysisFailure.unsafePrivateDirectory }
            let homeFD = openat(directoryFD, "home", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard homeFD >= 0 else { throw MoleAnalysisFailure.unsafePrivateDirectory }
            let tempMade = mkdirat(homeFD, "tmp", 0o700)
            close(homeFD)
            guard tempMade == 0 else { throw MoleAnalysisFailure.unsafePrivateDirectory }
            let targetFD = openat(directoryFD, "analyze-go", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard targetFD >= 0 else { throw MoleAnalysisFailure.unsafePrivateDirectory }
            defer { close(targetFD) }
            try MoleAnalysisFiles.copyPinnedBytesAndAttributes(from: sourceFD, to: targetFD, release: release)
            guard fchmod(targetFD, 0o500) == 0, fsync(targetFD) == 0 else {
                throw MoleAnalysisFailure.unsafePrivateDirectory
            }
            // The original embedded code signature and all security xattrs remain.
            _ = try MoleAnalysisFiles.verifyAnalyzer(targetFD, release: release)
            _ = try MoleAnalysisFiles.verifyAnalyzer(sourceFD, release: release)
        } catch {
            do { try cleanup() }
            catch { throw MoleAnalysisFailure.cleanupIncomplete }
            throw error
        }
    }


    func cleanup() throws {
        guard !cleaned else { return }
        var info = stat()
        guard name.withCString({ fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
              UInt64(truncatingIfNeeded: info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode,
              info.st_mode & S_IFMT == S_IFDIR else { throw MoleAnalysisFailure.cleanupIncomplete }
        var remaining = 20_000
        try removeChildren(directoryFD, depth: 0, remaining: &remaining)
        var after = stat()
        guard name.withCString({ fstatat(parentFD, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
              UInt64(truncatingIfNeeded: after.st_dev) == identity.device, UInt64(after.st_ino) == identity.inode,
              after.st_mode & S_IFMT == S_IFDIR,
              name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) == 0 else {
            throw MoleAnalysisFailure.cleanupIncomplete
        }
        cleaned = true
    }

    private func removeChildren(_ fd: Int32, depth: Int, remaining: inout Int) throws {
        guard depth < 16 else { throw MoleAnalysisFailure.cleanupIncomplete }
        let inventory = dup(fd)
        guard inventory >= 0 else { throw MoleAnalysisFailure.cleanupIncomplete }
        guard let stream = fdopendir(inventory) else {
            close(inventory); throw MoleAnalysisFailure.cleanupIncomplete
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name: String
            do { name = try DarwinDirectoryEntry.name(entry) }
            catch { throw MoleAnalysisFailure.cleanupIncomplete }
            if name == "." || name == ".." { continue }
            remaining -= 1
            guard remaining >= 0 else { throw MoleAnalysisFailure.cleanupIncomplete }
            var before = stat()
            guard name.withCString({ fstatat(fd, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
                  before.st_uid == geteuid(), UInt64(truncatingIfNeeded: before.st_dev) == identity.device else { throw MoleAnalysisFailure.cleanupIncomplete }
            if before.st_mode & S_IFMT == S_IFDIR {
                let child = name.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard child >= 0 else { throw MoleAnalysisFailure.cleanupIncomplete }
                defer { close(child) }
                let childID = try MoleAnalysisFiles.identity(child)
                guard childID.device == UInt64(truncatingIfNeeded: before.st_dev), childID.inode == UInt64(before.st_ino) else {
                    throw MoleAnalysisFailure.cleanupIncomplete
                }
                try removeChildren(child, depth: depth + 1, remaining: &remaining)
                var after = stat()
                guard name.withCString({ fstatat(fd, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
                      before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                      name.withCString({ unlinkat(fd, $0, AT_REMOVEDIR) }) == 0 else {
                    throw MoleAnalysisFailure.cleanupIncomplete
                }
            } else {
                // unlinkat removes only this directory entry, including a symlink;
                // it never follows a cache-provided path to an external target.
                guard name.withCString({ unlinkat(fd, $0, 0) }) == 0 else { throw MoleAnalysisFailure.cleanupIncomplete }
            }
        }
    }
}

private final class MoleOwnedDescriptor {
    let rawValue: Int32
    init(_ rawValue: Int32) { self.rawValue = rawValue }
    deinit { close(rawValue) }
}
