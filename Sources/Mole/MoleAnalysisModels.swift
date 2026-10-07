import Foundation

/// Reviewed artifacts and ephemeral, authenticated Homebrew bottle evidence.
/// A version declaration alone never authorizes execution.
struct MoleAnalyzerRelease: Equatable, Sendable {
    enum Origin: String, Sendable { case officialRelease, homebrewBottle, verifiedHomebrewBottle }
    let version: String
    let architecture: String
    let byteCount: Int
    let sha256: String
    var origin: Origin = .officialRelease
    var onlineProof: MoleOnlineArtifactProof? = nil

    static let latestTestedVersion = "1.58.0"
    static let reportFormatFloor = MoleVersion(major: 1, minor: 56, patch: 1)
    static let arm64 = MoleAnalyzerRelease(version: "V1.58.0", architecture: "arm64", byteCount: 3_860_946,
        sha256: "e7e6fd63dcbc7db90df1b63f2b2db3357e82ce919cf09df5b0ca645bdb10d180")
    static let x86_64 = MoleAnalyzerRelease(version: "V1.58.0", architecture: "x86_64", byteCount: 4_056_192,
        sha256: "cf0830df63162dc34e120c19a409c130d6f468ed2d6039f9872e63e8a88adbc9")
    static let legacyArm64 = MoleAnalyzerRelease(version: "V1.57.0", architecture: "arm64", byteCount: 3_827_474,
        sha256: "62c6b5076349081a34e60256a1471979f600d74d8f4990745a37d30d6faa00e1")
    static let legacyX86_64 = MoleAnalyzerRelease(version: "V1.57.0", architecture: "x86_64", byteCount: 4_022_992,
        sha256: "cff7d9da8bd18cb3364d566186944b5b14b01e21e5bb4a3d61579f553ea39ad7")
    static let homebrewArm64 = MoleAnalyzerRelease(version: "V1.58.0", architecture: "arm64", byteCount: 4_348_258,
        sha256: "d32d92f4c32d8079d464c496312fa616a9af6580457d40ffe7bfd28213f93866", origin: .homebrewBottle)
    static let reviewedArtifacts = [arm64, x86_64, legacyArm64, legacyX86_64, homebrewArm64]
    static var nativeArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
    static var native: MoleAnalyzerRelease { nativeArchitecture == "arm64" ? arm64 : x86_64 }
    static var nativeArtifacts: [MoleAnalyzerRelease] { reviewedArtifacts.filter { $0.architecture == nativeArchitecture } }
    var normalizedVersion: String { version.hasPrefix("V") ? String(version.dropFirst()) : version }
    var isReviewed: Bool { Self.reviewedArtifacts.contains { $0.sha256 == sha256 && $0.byteCount == byteCount && $0.architecture == architecture } }
    var requiresUntestedConsent: Bool { !isReviewed }
    var isEligible: Bool {
        guard architecture == Self.nativeArchitecture else { return false }
        if isReviewed { return true }
        guard origin == .verifiedHomebrewBottle, let proof = onlineProof,
              let version = MoleVersion(normalizedVersion), version.major == 1,
              version >= Self.reportFormatFloor,
              proof.verifiedAt <= Date(), Date().timeIntervalSince(proof.verifiedAt) < 3600,
              MoleHomebrewVerifier.validSHA256(proof.bottleSHA256),
              proof.bottleURL == MoleHomebrewVerifier.bottleURL(proof.bottleSHA256),
              MoleHomebrewVerifier.validSHA256(sha256), byteCount > 0, byteCount <= 8 * 1024 * 1024 else { return false }
        return true
    }
}

struct MoleOnlineArtifactProof: Equatable, Sendable {
    let verifiedAt: Date
    let bottleSHA256: String
    let bottleURL: URL
}

/// Strict displayed version parsing, not executable identity. Homebrew's keg
/// revision suffix is retained separately by discovery and never becomes argv.
struct MoleVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    init(major: Int, minor: Int, patch: Int) { self.major = major; self.minor = minor; self.patch = patch }
    init?(_ string: String) {
        let raw = string.hasPrefix("V") ? String(string.dropFirst()) : string
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
    var description: String { "\(major).\(minor).\(patch)" }
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
    case cleanupIncomplete, untestedConsentRequired

    var errorDescription: String? {
        switch self {
        case .invalidSelection: String(localized: "Choose an existing local folder and the direct installed Mole analyzer. Root, symbolic links and overlapping private-session paths are unsupported.")
        case .unsupportedBinary: String(localized: "This analyzer build has not been verified. Check its version and source before continuing. No tool was run.")
        case .quarantinedBinary: String(localized: "macOS quarantine is present on this analyzer. MoeKit will not remove it or bypass Gatekeeper.")
        case .changedSelection: String(localized: "The selected folder or analyzer changed. Choose them again and review a new analysis plan.")
        case .unsafePrivateDirectory: String(localized: "MoeKit could not establish its private analysis directory. No analysis was started.")
        case .invalidReport: String(localized: "Mole returned an invalid or inconsistent report. No new report was accepted.")
        case .outsideScope: String(localized: "The report contained paths outside the selected scope, or paths changed during validation. It was rejected.")
        case .unknownCoverage: String(localized: "The live report does not identify its scan coverage. It was rejected.")
        case .outputLimit: String(localized: "Analysis exceeded its output limit and was stopped. No complete report is available.")
        case .timeLimit: String(localized: "Analysis reached its time limit and was stopped. No complete report is available.")
        case .processFailed: String(localized: "The analyzer exited unsuccessfully or reached a resource limit. No complete report is available.")
        case .supervisorUnavailable: String(localized: "The bundled analysis supervisor is unavailable. Reinstall a verified MoeKit build.")
        case .cancelled: String(localized: "Analysis cancelled. No new report was accepted.")
        case .untestedConsentRequired: String(localized: "This official build has not been tested with MoeKit. Review and acknowledge the untested-version warning before analysis.")
        case .cleanupIncomplete: String(localized: "Analysis stopped, but MoeKit could not verify cleanup of its private session. Review the diagnostics before continuing.")
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
