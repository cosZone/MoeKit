import Foundation
import Darwin

/// A bounded read of an already selected path. The caller owns any directory-scope
/// checks; O_NOFOLLOW protects the final component, not its ancestor directories.
/// O_NONBLOCK prevents a regular-file-to-FIFO replacement from waiting for a writer.
/// Validate the opened descriptor before reading, rather than trusting an earlier stat.
enum BoundedRegularFileReader {
    enum ReadError: Error, Equatable {
        case notRegularFile
        case symbolicLink
        case tooLarge
        case changedDuringRead
        case invalidPath
        case invalidLimit
    }

    static func read(at url: URL, maximumBytes: Int,
                     validateAfterOpen: () throws -> Void = {}) throws -> Data {
        try Task.checkCancellation()
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw ReadError.invalidLimit }
        guard url.isFileURL else { throw ReadError.invalidPath }
        let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw ReadError.invalidPath }
            let opened = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else {
                let code = errno
                if code == ELOOP { throw ReadError.symbolicLink }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            return opened
        }
        defer { Darwin.close(descriptor) }

        let before = try checkedStatus(descriptor, maximumBytes: maximumBytes)
        // Preserve the caller's scope recheck after opening and before any content
        // read. This is still best effort for ancestor-directory replacement races.
        try validateAfterOpen()
        try Task.checkCancellation()
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let requested = min(buffer.count, maximumBytes - data.count + 1)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, requested)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw ReadError.tooLarge }
        }
        let after = try checkedStatus(descriptor, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        // Do not turn a truncated or concurrently rewritten file into a successful
        // snapshot. This detects observable changes, not every filesystem race.
        guard before.st_size == after.st_size, after.st_size == off_t(data.count),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ReadError.changedDuringRead
        }
        return data
    }

    private static func checkedStatus(_ descriptor: Int32, maximumBytes: Int) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ReadError.notRegularFile
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumBytes) else {
            throw ReadError.tooLarge
        }
        return status
    }
}
