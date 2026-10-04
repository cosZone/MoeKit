import Darwin
import Foundation
@testable import MoeKit

/// An opt-in hosted-runner gate must produce affirmative runtime evidence. A
/// skipped or zero-selected test cannot produce this artifact or satisfy CI.
enum InstallerNativeFixtureEvidence {
    static func record(kind: String, detail: [String: String]) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              let sha = env["MOEKIT_INSTALLER_SOURCE_SHA"], sha.count == 40,
              sha.allSatisfy({ $0.isHexDigit }), let path = env["MOEKIT_INSTALLER_EVIDENCE_DIR"],
              ["native-trash", "mounted-image", "idle-use", "live-mole"].contains(kind), detail.count <= 16 else {
            throw InstallerTrashFailure.unavailable("Missing exact-commit hosted-runner fixture evidence configuration")
        }
        let directory = try InstallerDirectoryAnchor.open(URL(fileURLWithPath: path))
        try InstallerFileAccess.validatePrivate(directory.fd, directory: true)
        let payload: [String: Any] = ["schema": 1, "kind": kind, "sourceSHA": sha, "detail": detail]
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard bytes.count < 8192 else { throw InstallerTrashFailure.journal }
        let fd = openat(directory.fd, kind + ".json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InstallerTrashFailure.journal }
        defer { close(fd) }
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count, fsync(fd) == 0 else { throw InstallerTrashFailure.journal }
    }
}
