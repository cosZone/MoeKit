import Foundation

/// Exact upstream artifacts, identified without running a version command.
/// This is a version allowlist, not permission to run an arbitrary installed tool.
struct MoleAnalyzerRelease: Equatable, Sendable {
    let version: String
    let architecture: String
    let byteCount: Int
    let sha256: String

    static let arm64 = MoleAnalyzerRelease(version: "V1.57.0", architecture: "arm64", byteCount: 3_827_474,
        sha256: "62c6b5076349081a34e60256a1471979f600d74d8f4990745a37d30d6faa00e1")
    static let x86_64 = MoleAnalyzerRelease(version: "V1.57.0", architecture: "x86_64", byteCount: 4_022_992,
        sha256: "cff7d9da8bd18cb3364d566186944b5b14b01e21e5bb4a3d61579f553ea39ad7")
    static var native: MoleAnalyzerRelease {
        #if arch(arm64)
        arm64
        #else
        x86_64
        #endif
    }
}

struct MoleFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct MoleAnalysisPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let executable: URL
    let directory: URL
    let executableIdentity: MoleFileIdentity
    let directoryIdentity: MoleFileIdentity
    let release: MoleAnalyzerRelease
    let preparedAt: Date
    let privateSessionParent: URL
}

struct MoleAnalysisResult: Sendable {
    let report: MoleAnalyzeReport
    let directory: URL
    let release: MoleAnalyzerRelease
    let startedAt: Date
    let finishedAt: Date
}

enum MoleAnalysisFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidSelection, unsupportedBinary, quarantinedBinary, changedSelection
    case unsafePrivateDirectory, invalidReport, outsideScope, unknownCoverage
    case outputLimit, timeLimit, processFailed, supervisorUnavailable, cancelled
    case cleanupIncomplete

    var errorDescription: String? {
        switch self {
        case .invalidSelection: String(localized: "Choose an existing local folder and the direct installed Mole analyzer. Root, symbolic links and overlapping private-session paths are unsupported.")
        case .unsupportedBinary: String(localized: "This file does not match the supported official Mole V1.57.0 analyzer for this Mac. No tool was run.")
        case .quarantinedBinary: String(localized: "macOS quarantine is present on this analyzer. MoeKit will not remove it or bypass Gatekeeper.")
        case .changedSelection: String(localized: "The selected folder or analyzer changed. Choose them again and review a new analysis plan.")
        case .unsafePrivateDirectory: String(localized: "MoeKit could not establish its private analysis directory. No analysis was started.")
        case .invalidReport: String(localized: "Mole returned an invalid or inconsistent report. It has not replaced the last result.")
        case .outsideScope: String(localized: "The report contained paths outside the selected scope, or paths changed during validation. It was rejected.")
        case .unknownCoverage: String(localized: "The live report does not identify its scan coverage. It was rejected.")
        case .outputLimit: String(localized: "Analysis exceeded its output limit and was stopped. No complete report is available.")
        case .timeLimit: String(localized: "Analysis reached its time limit and was stopped. No complete report is available.")
        case .processFailed: String(localized: "The analyzer exited unsuccessfully or reached a resource limit. No complete report is available.")
        case .supervisorUnavailable: String(localized: "The bundled analysis supervisor is unavailable. Reinstall a verified MoeKit build.")
        case .cancelled: String(localized: "Analysis cancelled. No new report was accepted.")
        case .cleanupIncomplete: String(localized: "Analysis stopped, but private-session cleanup could not be verified. No user folder was deleted.")
        }
    }
}

/// Live reports have a stricter scope contract than imported legacy reports.
/// Lexical validation is defense in depth, not filesystem confinement.
enum MoleLiveReportValidator {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumEntries = 50_000

    static func decode(_ data: Data, selectedDirectory: URL) throws -> MoleAnalyzeReport {
        guard data.count <= maximumBytes else { throw MoleAnalysisFailure.outputLimit }
        let report: MoleAnalyzeReport
        do { report = try JSONDecoder().decode(MoleAnalyzeReport.self, from: data) }
        catch { throw MoleAnalysisFailure.invalidReport }
        guard !report.overview, report.path == selectedDirectory.path,
              let root = components(report.path), !root.isEmpty,
              report.entries.count <= maximumEntries,
              report.largeFiles.count <= maximumEntries else { throw MoleAnalysisFailure.outsideScope }
        guard report.coverage != .unknown, report.entries.allSatisfy({ $0.coverage != .unknown }) else {
            throw MoleAnalysisFailure.unknownCoverage
        }
        for entry in report.entries {
            guard !entry.insight, let path = components(entry.path),
                  path.count == root.count + 1, path.dropLast().elementsEqual(root) else {
                throw MoleAnalysisFailure.outsideScope
            }
        }
        for file in report.largeFiles {
            guard let path = components(file.path), path.count > root.count,
                  path.prefix(root.count).elementsEqual(root) else { throw MoleAnalysisFailure.outsideScope }
        }
        guard report.coverage != .known || report.entries.allSatisfy({ $0.coverage == .known }) else {
            throw MoleAnalysisFailure.invalidReport
        }
        return report
    }

    static func components(_ path: String) -> [Substring]? {
        guard path.hasPrefix("/"), path.utf8.count < 4096, !path.contains("\0") else { return nil }
        if path == "/" { return [] }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }

    static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let lhs = a.pathComponents, rhs = b.pathComponents
        return lhs.starts(with: rhs) || rhs.starts(with: lhs)
    }
}
