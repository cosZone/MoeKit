import Darwin
import Foundation

/// Discovery is an observation, never permission to execute. Only exact pinned
/// bytes can be selected automatically; preparation and launch verify them again.
enum MoleInstallationState: String, Equatable, Sendable {
    case usable, missing, incompatible, unverified
}

struct MoleInstallationCandidate: Identifiable, Equatable, Sendable {
    let path: String
    let state: MoleInstallationState
    let source: String
    let explanation: String
    var id: String { path }
}

struct MoleInstallationReport: Equatable, Sendable {
    let candidates: [MoleInstallationCandidate]
    let inspectedAt: Date
    var verifiedExecutable: URL? {
        candidates.first(where: { $0.state == .usable }).map { URL(fileURLWithPath: $0.path) }
    }
    var state: MoleInstallationState {
        if candidates.contains(where: { $0.state == .usable }) { return .usable }
        if candidates.contains(where: { $0.state == .incompatible }) { return .incompatible }
        if candidates.contains(where: { $0.state == .unverified }) { return .unverified }
        return .missing
    }
}

protocol MoleInstallationDiscovering: Sendable {
    func discover() async throws -> MoleInstallationReport
}

struct MoleInstallationLocation: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case analyzer, homebrew(cellar: URL), wrapper }
    let url: URL
    let kind: Kind
    var source: String {
        switch kind {
        case .analyzer: String(localized: "Official analyzer location")
        case .homebrew: String(localized: "Homebrew installation")
        case .wrapper: String(localized: "Mole command location")
        }
    }

    /// Fixed paths only. No PATH lookup, recursive walk, home enumeration, shell
    /// expansion, installer, version probe, network request or wrapper execution.
    static func standard(home: URL, prefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]) -> [Self] {
        var result = [
            Self(url: home.appendingPathComponent(MoleAnalyzerRelease.native.installationDirectoryName + "/analyze-go"), kind: .analyzer),
            Self(url: home.appendingPathComponent(".config/mole/bin/analyze-go"), kind: .analyzer)
        ]
        for prefix in prefixes {
            result.append(Self(url: prefix.appendingPathComponent("opt/mole/libexec/bin/analyze-go"),
                               kind: .homebrew(cellar: prefix.appendingPathComponent("Cellar/mole"))))
            for name in ["mo", "mole"] {
                result.append(Self(url: prefix.appendingPathComponent("bin/" + name), kind: .wrapper))
            }
        }
        for name in ["mo", "mole"] {
            result.append(Self(url: home.appendingPathComponent(".local/bin/" + name), kind: .wrapper))
        }
        return result
    }
}

/// Runs descriptor-based reads on an independent actor. At most ten fixed
/// locations and one release-sized hash per analyzer. Filesystem IO can block;
/// cancellation is cooperative, not a promised hard wall-clock timeout.
actor MoleInstallationDiscovery: MoleInstallationDiscovering {
    static let maximumLocations = 10
    private let locations: [MoleInstallationLocation]
    private let release: MoleAnalyzerRelease
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        locations = MoleInstallationLocation.standard(home: home)
        release = .native
    }
    // Internal fixture seam: no UI, settings or external file can change pins.
    init(locations: [MoleInstallationLocation], release: MoleAnalyzerRelease = .native) {
        self.locations = locations; self.release = release
    }

    func discover() async throws -> MoleInstallationReport {
        guard locations.count <= Self.maximumLocations else { throw MoleAnalysisFailure.invalidSelection }
        var candidates: [MoleInstallationCandidate] = []
        var seen = Set<String>()
        for location in locations {
            try Task.checkCancellation()
            let candidate = try inspect(location)
            if seen.insert(candidate.path).inserted { candidates.append(candidate) }
        }
        try Task.checkCancellation()
        return MoleInstallationReport(candidates: candidates, inspectedAt: Date())
    }

    private func inspect(_ location: MoleInstallationLocation) throws -> MoleInstallationCandidate {
        func observation(_ state: MoleInstallationState, _ explanation: String, path: String? = nil) -> MoleInstallationCandidate {
            MoleInstallationCandidate(path: path ?? location.url.path, state: state, source: location.source, explanation: explanation)
        }
        do { try MoleAnalysisFiles.validateLocalURL(location.url) }
        catch { return observation(.unverified, String(localized: "This location could not be safely checked.")) }
        var metadata = stat()
        guard lstat(location.url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return observation(.missing, String(localized: "No analyzer was found at this location. Custom locations have not been searched."))
            }
            return observation(.unverified, String(localized: "This location could not be read. That does not mean Mole is missing."))
        }
        if location.kind == .wrapper {
            return observation(.unverified, String(localized: "A Mole command is present. Commands and shell wrappers are never run during setup, so this does not verify an analyzer."))
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            return observation(.unverified, String(localized: "This analyzer path is a link or is not a regular file. It was not followed or run."))
        }
        do {
            let canonical = try MoleAnalysisFiles.canonicalURL(location.url)
            if case .homebrew(let cellar) = location.kind {
                // Homebrew opt is an expected ancestor alias, but may resolve
                // only to this formula's single-version Cellar layout.
                let root = try MoleAnalysisFiles.canonicalURL(cellar)
                let parts = canonical.pathComponents
                let prefix = root.pathComponents
                guard parts.starts(with: prefix), parts.count == prefix.count + 4,
                      Array(parts.suffix(3)) == ["libexec", "bin", "analyze-go"] else {
                    return observation(.unverified, String(localized: "The Homebrew link points outside the expected Mole installation. It was not accepted."))
                }
            }
            let fd = try MoleAnalysisFiles.openPath(canonical, directory: false)
            defer { close(fd) }
            _ = try MoleAnalysisFiles.verifyAnalyzer(fd, release: release)
            try Task.checkCancellation()
            return observation(.usable, String(localized: "The analyzer matches the reviewed official release for this app. It will be checked again before analysis."), path: canonical.path)
        } catch is CancellationError {
            throw CancellationError()
        } catch MoleAnalysisFailure.unsupportedBinary {
            return observation(.incompatible, String(localized: "This file does not match the supported official release. Homebrew builds, custom builds, other versions and another architecture can differ. Nothing was run."))
        } catch MoleAnalysisFailure.quarantinedBinary {
            return observation(.unverified, String(localized: "macOS quarantine is present. MoeKit will not remove it or bypass Gatekeeper. Review the system warning before continuing."))
        } catch {
            return observation(.unverified, String(localized: "The analyzer could not be verified or changed during the check. Recheck before continuing."))
        }
    }
}
