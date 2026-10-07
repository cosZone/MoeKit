import CryptoKit
import Darwin
import Foundation

/// These are the only upgrade providers. No path, command or argument editor is exposed.
enum MoleUpgradeSource: String, CaseIterable, Sendable {
    case appleSiliconHomebrew, intelHomebrew

    init?(prefix: URL) {
        guard prefix.isFileURL else { return nil }
        switch prefix.standardizedFileURL.path {
        case "/opt/homebrew": self = .appleSiliconHomebrew
        case "/usr/local": self = .intelHomebrew
        default: return nil
        }
    }
    var executable: URL {
        URL(fileURLWithPath: self == .appleSiliconHomebrew ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew")
    }
}

struct OperationExecutableSnapshot: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let mode: UInt32
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let sha256: String

    var supervisorArguments: [String] {
        [String(device), String(inode), String(owner), String(mode), String(size),
         String(modifiedSeconds), String(modifiedNanoseconds), sha256]
    }
}

/// Version strings are display-only provenance. Homebrew decides which current
/// formula it installs; this plan neither pins nor promises the recommended version.
struct MoleUpgradePlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: MoleUpgradeSource
    let executable: URL
    let currentVersion: String?
    let recommendedVersion: String
    let executableSnapshot: OperationExecutableSnapshot
    let home: URL
    let preparedAt: Date

    var commands: [String] {
        [executable.path + " update", executable.path + " upgrade --formula mole"]
    }
    var reviewText: String {
        "[1/2] " + commands[0] + "\r\n" +
        "[2/2, " + String(localized: "Only if step 1 succeeds") + "] " + commands[1] + "\r\n\r\n" +
        String(localized: "Nothing has run. Press Return in this terminal to execute these commands.") + "\r\n"
    }
}

enum OperationTerminalFailure: Error, LocalizedError, Equatable {
    case unavailable, unsafeExecutable, changedExecutable, expiredPlan, invalidHome, io, protocolFailure
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "The bundled upgrade helper is unavailable. Nothing was started.")
        case .unsafeExecutable: String(localized: "The standard Homebrew executable is missing, a link, or has unsafe ownership or permissions. Nothing was started.")
        case .changedExecutable: String(localized: "Homebrew changed after this review. This plan was not run. Recheck the installation before a new review.")
        case .expiredPlan: String(localized: "This upgrade review expired. Nothing was started. Recheck the installation before a new review.")
        case .invalidHome: String(localized: "The current user's home directory could not be verified. Nothing was started.")
        case .io, .protocolFailure: String(localized: "The upgrade helper did not establish a reliable result. Check the output and recheck the installation; changes may be partial.")
        }
    }
}

/// Bounded descriptor reads only. Never invoke brew or a version probe to prepare.
enum OperationExecutableVerifier {
    static let maximumExecutableBytes = 2 * 1024 * 1024

    /// The only supported alias is Intel Homebrew's documented standard layout.
    /// The resulting regular file (not the alias) is displayed and snapshotted.
    static func executionURL(for source: MoleUpgradeSource) throws -> URL {
        let nominal = source.executable
        var info = stat()
        guard lstat(nominal.path, &info) == 0 else { throw OperationTerminalFailure.unsafeExecutable }
        if info.st_mode & S_IFMT == S_IFREG { return nominal }
        guard source == .intelHomebrew, info.st_mode & S_IFMT == S_IFLNK,
              info.st_uid == geteuid() || info.st_uid == 0 else { throw OperationTerminalFailure.unsafeExecutable }
        var bytes = [CChar](repeating: 0, count: 4096)
        let count = readlink(nominal.path, &bytes, bytes.count)
        guard count > 0, count < bytes.count else { throw OperationTerminalFailure.unsafeExecutable }
        let target = String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard target == "../Homebrew/bin/brew" || target == "/usr/local/Homebrew/bin/brew" else {
            throw OperationTerminalFailure.unsafeExecutable
        }
        let canonical = URL(fileURLWithPath: "/usr/local/Homebrew/bin/brew")
        guard canonical.resolvingSymlinksInPath().path == canonical.path else {
            throw OperationTerminalFailure.unsafeExecutable
        }
        var after = stat()
        guard lstat(nominal.path, &after) == 0, sameMetadata(info, after) else {
            throw OperationTerminalFailure.changedExecutable
        }
        return canonical
    }

    static func capture(_ url: URL) throws -> OperationExecutableSnapshot {
        var pathInfo = stat()
        guard url.isFileURL, lstat(url.path, &pathInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFREG else { throw OperationTerminalFailure.unsafeExecutable }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw OperationTerminalFailure.unsafeExecutable }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_dev == pathInfo.st_dev, before.st_ino == pathInfo.st_ino,
              before.st_uid == geteuid() || before.st_uid == 0,
              before.st_mode & 0o022 == 0, before.st_mode & 0o111 != 0,
              before.st_mode & 0o6000 == 0,
              before.st_size > 0, before.st_size <= off_t(maximumExecutableBytes) else {
            throw OperationTerminalFailure.unsafeExecutable
        }
        var hash = SHA256()
        var readBytes = 0
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw OperationTerminalFailure.unsafeExecutable }
            if count == 0 { break }
            readBytes += count
            guard readBytes <= maximumExecutableBytes else { throw OperationTerminalFailure.unsafeExecutable }
            hash.update(data: Data(bytes.prefix(count)))
        }
        var after = stat(), latestPath = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &latestPath) == 0,
              sameMetadata(before, after), sameMetadata(after, latestPath),
              Int64(readBytes) == after.st_size else { throw OperationTerminalFailure.changedExecutable }
        return snapshot(after, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func sameMetadata(_ a: stat, _ b: stat) -> Bool {
        snapshot(a, digest: "") == snapshot(b, digest: "")
    }
    private static func snapshot(_ info: stat, digest: String) -> OperationExecutableSnapshot {
        OperationExecutableSnapshot(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            owner: info.st_uid, mode: UInt32(info.st_mode), size: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec), sha256: digest)
    }
}
