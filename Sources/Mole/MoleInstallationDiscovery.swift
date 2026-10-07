import Darwin
import Foundation

/// Coarse grouping for presentation; the issue carries the actionable reason.
enum MoleInstallationState: String, Equatable, Sendable {
    case usable, missing, incompatible, unverified
}

enum MoleInstallationOrigin: Equatable, Sendable {
    case homebrew(prefix: URL), official, standalone, command
}

enum MoleInstallationIssue: String, Equatable, Sendable {
    case missingVersion, unsupportedFormat, unverifiedBuild, modifiedBuild, quarantine
    case unreadable, unsupportedArchitecture, untestedVersion, unsafeFile, commandOnly
    case changed, customTap, missingAnalyzer, metadataConflict, unsupportedMajor
    var title: String {
        switch self {
        case .unsupportedMajor: String(localized: "This Mole major version needs a newer adapter")
        case .missingVersion: String(localized: "Installed version is unknown")
        case .unsupportedFormat: String(localized: "This version needs a newer report format")
        case .unverifiedBuild: String(localized: "Installed build needs verification")
        case .modifiedBuild: String(localized: "Installed file differs from the official bottle")
        case .quarantine: String(localized: "macOS has quarantined this file")
        case .unreadable: String(localized: "Installation could not be read")
        case .unsupportedArchitecture: String(localized: "Analyzer architecture does not match this app")
        case .untestedVersion: String(localized: "Official build verified · version not yet tested")
        case .unsafeFile: String(localized: "Analyzer file or permissions need attention")
        case .commandOnly: String(localized: "Mole command found · analyzer not verified")
        case .changed: String(localized: "Installation changed during verification")
        case .customTap: String(localized: "Custom Homebrew source")
        case .missingAnalyzer: String(localized: "Homebrew installation is missing its analyzer")
        case .metadataConflict: String(localized: "Installation version records disagree")
        }
    }
    var explanation: String {
        switch self {
        case .unsupportedMajor: String(localized: "This major version has not been adapted for Mole analysis. Keep the installed version and check for a MoeKit update; do not downgrade automatically.")
        case .unsupportedFormat: String(localized: "This installation reports a version older than 1.56.1, which lacks the scan-coverage fields required for live analysis. Upgrade the existing installation; imported reports can still be viewed.")
        case .unverifiedBuild: String(localized: "The version may support analysis, but this file has not been matched to an official build. Verify its Homebrew bottle before running it.")
        case .modifiedBuild: String(localized: "The file does not match any verified current Homebrew bottle for this architecture. It may be modified or built from source. No analyzer was run.")
        case .quarantine: String(localized: "MoeKit does not remove quarantine or bypass macOS protection. Review the system warning; another download is not a security bypass.")
        case .untestedVersion: String(localized: "The bytes match an official Homebrew bottle, but this version has not been tested with MoeKit. Separate acknowledgement is required before each analysis.")
        case .missingVersion: String(localized: "No reliable version declaration was found. MoeKit does not execute an unknown file to ask for its version.")
        case .unsupportedArchitecture: String(localized: "Use an analyzer matching the architecture of the running MoeKit app. No version probe or analyzer was run.")
        case .customTap: String(localized: "This installation comes from a different Homebrew tap. The automatic core-bottle verifier and upgrade command are unavailable for this source.")
        case .metadataConflict: String(localized: "The Homebrew keg and receipt report different versions. Recheck or review the installation before choosing an upgrade.")
        case .missingAnalyzer: String(localized: "Homebrew metadata is present but its direct analyzer is missing. Review the existing installation instead of installing an older parallel copy.")
        case .commandOnly: String(localized: "A command or wrapper exists. Its presence does not prove an analyzer version or compatible file; no wrapper was run.")
        case .changed: String(localized: "The file changed during the check. Recheck to get a fresh observation.")
        case .unsafeFile: String(localized: "The analyzer must be a readable regular executable owned by you or root, without group/world write access or a final symbolic link.")
        case .unreadable: String(localized: "The installation could not be safely read. This does not mean it is missing.")
        }
    }
}

struct MoleInstallationCandidate: Identifiable, Equatable, Sendable {
    let path: String
    let state: MoleInstallationState
    let source: String
    let explanation: String
    var declaredVersion: String? = nil
    var verifiedRelease: MoleAnalyzerRelease? = nil
    var origin: MoleInstallationOrigin = .standalone
    var issue: MoleInstallationIssue? = nil
    var observation: MoleAnalysisFiles.AnalyzerObservation? = nil
    var kegVersion: String? = nil
    var isHomebrewCore = false
    var id: String { path }
    var currentVersion: String? { verifiedRelease?.normalizedVersion ?? declaredVersion }
    var canVerifyHomebrew: Bool {
        guard case .homebrew = origin, isHomebrewCore, observation != nil, kegVersion != nil,
              let text = declaredVersion, let version = MoleVersion(text), version.major == 1,
              version >= MoleAnalyzerRelease.reportFormatFloor else { return false }
        return issue == .unverifiedBuild || issue == .untestedVersion || issue == .modifiedBuild
    }
    var canUpgradeHomebrew: Bool {
        guard case .homebrew = origin, isHomebrewCore, issue != .quarantine,
              issue != .metadataConflict, let currentVersion, let version = MoleVersion(currentVersion),
              let tested = MoleVersion(MoleAnalyzerRelease.latestTestedVersion) else { return false }
        return version < tested
    }
}

struct MoleInstallationReport: Equatable, Sendable {
    let candidates: [MoleInstallationCandidate]
    let inspectedAt: Date
    /// Prefer the existing managed installation over a parallel fallback file.
    var selectedCandidate: MoleInstallationCandidate? {
        let present = candidates.filter { $0.state != .missing }
        let managed = present.filter { candidate in
            switch candidate.origin { case .homebrew, .official: true; default: false }
        }
        if !managed.isEmpty {
            return managed.first { $0.state == .usable || $0.verifiedRelease?.isEligible == true }
                ?? managed.first { $0.issue != .unsupportedArchitecture } ?? managed.first
        }
        return present.first { $0.origin != .command } ?? present.first ?? candidates.first
    }
    var verifiedExecutable: URL? {
        guard let candidate = selectedCandidate,
              candidate.state == .usable || candidate.verifiedRelease?.isEligible == true else { return nil }
        return URL(fileURLWithPath: candidate.path)
    }
    var state: MoleInstallationState { selectedCandidate?.state ?? .missing }
}

protocol MoleInstallationDiscovering: Sendable {
    func discover() async throws -> MoleInstallationReport
}

struct MoleInstallationLocation: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case analyzer, homebrew(cellar: URL), wrapper }
    let url: URL
    let kind: Kind
    var versionFile: URL? = nil
    var source: String {
        switch kind {
        case .analyzer: String(localized: "Official analyzer location")
        case .homebrew: String(localized: "Homebrew installation")
        case .wrapper: String(localized: "Mole command location")
        }
    }
    static func standard(home: URL, prefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]) -> [Self] {
        let preferred = MoleAnalyzerRelease.nativeArchitecture == "arm64" ? "/opt/homebrew" : "/usr/local"
        let ordered = prefixes.sorted { $0.path == preferred && $1.path != preferred }
        var result = ordered.map { prefix in
            Self(url: prefix.appendingPathComponent("opt/mole/libexec/bin/analyze-go"),
                 kind: .homebrew(cellar: prefix.appendingPathComponent("Cellar/mole")))
        }
        result.append(Self(url: home.appendingPathComponent(".config/mole/bin/analyze-go"), kind: .analyzer,
                           versionFile: URL(fileURLWithPath: "/usr/local/bin/mole")))
        for version in [MoleAnalyzerRelease.native, MoleAnalyzerRelease.nativeArchitecture == "arm64" ? .legacyArm64 : .legacyX86_64] {
            result.append(Self(url: home.appendingPathComponent(version.installationDirectoryName + "/analyze-go"), kind: .analyzer))
        }
        for prefix in prefixes {
            for name in ["mo", "mole"] { result.append(Self(url: prefix.appendingPathComponent("bin/" + name), kind: .wrapper)) }
        }
        for name in ["mo", "mole"] { result.append(Self(url: home.appendingPathComponent(".local/bin/" + name), kind: .wrapper)) }
        return result
    }
}

/// Fixed bounded reads on a separate actor. No wrapper, installer, version
/// command, PATH search, directory walk, network or execution during discovery.
actor MoleInstallationDiscovery: MoleInstallationDiscovering {
    static let maximumLocations = 12
    private let locations: [MoleInstallationLocation]
    private let releases: [MoleAnalyzerRelease]
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        locations = MoleInstallationLocation.standard(home: home); releases = MoleAnalyzerRelease.reviewedArtifacts
    }
    init(locations: [MoleInstallationLocation], release: MoleAnalyzerRelease = .native) {
        self.locations = locations; releases = [release]
    }
    init(locations: [MoleInstallationLocation], releases: [MoleAnalyzerRelease]) {
        self.locations = locations; self.releases = releases
    }

    func discover() async throws -> MoleInstallationReport {
        guard locations.count <= Self.maximumLocations else { throw MoleAnalysisFailure.invalidSelection }
        var candidates: [MoleInstallationCandidate] = [], seen = Set<String>()
        for location in locations {
            try Task.checkCancellation()
            let candidate = try inspect(location)
            if seen.insert(candidate.path).inserted { candidates.append(candidate) }
        }
        try Task.checkCancellation()
        return MoleInstallationReport(candidates: candidates, inspectedAt: Date())
    }

    private func inspect(_ location: MoleInstallationLocation) throws -> MoleInstallationCandidate {
        var candidate = MoleInstallationCandidate(path: location.url.path, state: .unverified, source: location.source, explanation: "")
        if case .homebrew(let cellar) = location.kind {
            candidate.origin = .homebrew(prefix: cellar.deletingLastPathComponent().deletingLastPathComponent())
        } else if location.kind == .wrapper { candidate.origin = .command }
        else if location.versionFile != nil { candidate.origin = .official }
        func result(_ state: MoleInstallationState, _ issue: MoleInstallationIssue?, path: String? = nil) -> MoleInstallationCandidate {
            MoleInstallationCandidate(path: path ?? candidate.path, state: state, source: candidate.source,
                explanation: issue?.explanation ?? (state == .missing ? String(localized: "No analyzer was found at this location. Custom locations have not been searched.") : String(localized: "The analyzer matches a tested official build. It will be verified again before analysis.")),
                declaredVersion: candidate.declaredVersion, verifiedRelease: candidate.verifiedRelease,
                origin: candidate.origin, issue: issue, observation: candidate.observation,
                kegVersion: candidate.kegVersion, isHomebrewCore: candidate.isHomebrewCore)
        }
        do { try MoleAnalysisFiles.validateLocalURL(location.url) }
        catch { return result(.unverified, .unreadable) }
        if case .homebrew(let cellar) = location.kind {
            let kegAlias = location.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if let keg = try? MoleAnalysisFiles.canonicalURL(kegAlias),
               let root = try? MoleAnalysisFiles.canonicalURL(cellar),
               keg.deletingLastPathComponent() == root {
                let metadata = MoleInstallationMetadata.homebrew(keg: keg)
                candidate.declaredVersion = metadata.version
                candidate.kegVersion = metadata.kegVersion
                candidate.isHomebrewCore = metadata.core
                if metadata.conflicting { return result(.unverified, .metadataConflict) }
            }
        } else if let versionFile = location.versionFile {
            candidate.declaredVersion = MoleInstallationMetadata.wrapperVersion(at: versionFile)
        }
        var metadata = stat()
        guard lstat(location.url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                if candidate.kegVersion != nil { return result(.unverified, .missingAnalyzer) }
                return result(.missing, nil)
            }
            return result(.unverified, .unreadable)
        }
        if location.kind == .wrapper { return result(.unverified, .commandOnly) }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return result(.unverified, .unsafeFile) }
        do {
            let canonical = try MoleAnalysisFiles.canonicalURL(location.url)
            if case .homebrew(let cellar) = location.kind {
                let root = try MoleAnalysisFiles.canonicalURL(cellar)
                let parts = canonical.pathComponents, prefix = root.pathComponents
                guard parts.starts(with: prefix), parts.count == prefix.count + 4,
                      Array(parts.suffix(3)) == ["libexec", "bin", "analyze-go"] else { return result(.unverified, .unreadable) }
            }
            let fd = try MoleAnalysisFiles.openPath(canonical, directory: false)
            defer { close(fd) }
            let observation = try MoleAnalysisFiles.observeAnalyzer(fd)
            candidate.observation = observation
            if let release = releases.first(where: { $0.sha256 == observation.sha256 && $0.byteCount == observation.byteCount }) {
                candidate.verifiedRelease = release
                guard release.architecture == MoleAnalyzerRelease.nativeArchitecture || release.architecture == "fixture" else {
                    return result(.incompatible, .unsupportedArchitecture, path: canonical.path)
                }
                return result(.usable, nil, path: canonical.path)
            }
            if case .homebrew = candidate.origin, candidate.kegVersion != nil, !candidate.isHomebrewCore {
                return result(.unverified, .customTap, path: canonical.path)
            }
            guard let declared = candidate.declaredVersion, let version = MoleVersion(declared) else {
                return result(.unverified, .missingVersion, path: canonical.path)
            }
            if version.major != 1 { return result(.incompatible, .unsupportedMajor, path: canonical.path) }
            if version < MoleAnalyzerRelease.reportFormatFloor { return result(.incompatible, .unsupportedFormat, path: canonical.path) }
            return result(.unverified, .unverifiedBuild, path: canonical.path)
        } catch is CancellationError { throw CancellationError() }
        catch MoleAnalysisFailure.quarantinedBinary { return result(.unverified, .quarantine) }
        catch MoleAnalysisFailure.unsupportedBinary { return result(.unverified, .unsafeFile) }
        catch MoleAnalysisFailure.changedSelection { return result(.unverified, .changed) }
        catch { return result(.unverified, .unreadable) }
    }
}

/// Local package declarations are display hints, never provenance or execution
/// permission. Reads are bounded, descriptor-based, regular-file and non-following.
enum MoleInstallationMetadata {
    struct Homebrew: Sendable { let version: String?; let kegVersion: String?; let core: Bool; let conflicting: Bool }
    static func homebrew(keg: URL) -> Homebrew {
        let name = keg.lastPathComponent
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count <= 2, let base = parts.first, let version = MoleVersion(String(base)),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].count < 6 && parts[1].utf8.allSatisfy { $0 >= 48 && $0 <= 57 }) else {
            return Homebrew(version: nil, kegVersion: nil, core: false, conflicting: false)
        }
        guard let data = read(keg.appendingPathComponent("INSTALL_RECEIPT.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = json["source"] as? [String: Any] else {
            return Homebrew(version: version.description, kegVersion: name, core: false, conflicting: false)
        }
        let declared = (source["versions"] as? [String: Any])?["stable"] as? String
        let conflict = declared != nil && declared != version.description
        return Homebrew(version: version.description, kegVersion: name,
                        core: source["tap"] as? String == "homebrew/core", conflicting: conflict)
    }
    static func wrapperVersion(at url: URL) -> String? {
        guard let data = read(url), let text = String(data: data, encoding: .utf8) else { return nil }
        let versions = text.split(separator: "\n").compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("VERSION=\""), line.hasSuffix("\"") else { return nil }
            let value = String(line.dropFirst(9).dropLast())
            return MoleVersion(value)?.description
        }
        return versions.count == 1 ? versions.first : nil
    }
    private static func read(_ url: URL) -> Data? {
        guard let canonical = try? MoleAnalysisFiles.canonicalURL(url), canonical.lastPathComponent == url.lastPathComponent,
              let fd = try? MoleAnalysisFiles.openPath(url, directory: false) else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= 64 * 1024 else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if Task.isCancelled { return nil }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            guard data.count <= 64 * 1024 - count else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, data.count == before.st_size,
              before.st_ino == after.st_ino, before.st_dev == after.st_dev, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
        return data
    }
}
