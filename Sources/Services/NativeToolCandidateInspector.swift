import Foundation
import Darwin

/// Metadata-only inspection of at most eight explicit paths. lstat deliberately
/// does not follow the final symbolic link. Ancestors may resolve normally; this
/// observation is never an executable identity or an authorization to run it.
actor NativeToolCandidateInspector: ToolCandidateInspecting {
    static let maximumLocations = 8
    enum InspectionError: Error { case tooManyLocations }

    func inspect(_ locations: [URL]) async throws -> [ToolCandidateObservation] {
        guard locations.count <= Self.maximumLocations else { throw InspectionError.tooManyLocations }
        var results: [ToolCandidateObservation] = []
        for location in locations {
            try Task.checkCancellation()
            let observation = inspectOne(location)
            try Task.checkCancellation()
            results.append(observation)
        }
        return results
    }

    private func inspectOne(_ url: URL) -> ToolCandidateObservation {
        let path = url.path
        func result(_ state: ToolCandidateState) -> ToolCandidateObservation {
            ToolCandidateObservation(path: path, state: state, observedAt: Date())
        }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < Int(PATH_MAX) else {
            return result(.unsupported(.invalidPath))
        }
        var status = stat()
        let code = path.withCString { Darwin.lstat($0, &status) }
        guard code == 0 else {
            let error = errno
            return result(error == ENOENT || error == ENOTDIR ? .missing : .unreadable)
        }
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFLNK): return result(.foundUnverified(symbolicLink: true))
        case mode_t(S_IFREG):
            return result(status.st_mode & 0o111 == 0 ? .unsupported(.notExecutable) : .foundUnverified(symbolicLink: false))
        default: return result(.unsupported(.notRegularFile))
        }
    }
}
