import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Mole version, provenance and report compatibility")
struct MoleCompatibilityTests {
    @Test("A numeric version is not provenance or an unbounded format guarantee")
    func versions() {
        #expect(MoleVersion("V1.58.0") == MoleVersion("1.58.0"))
        #expect(MoleVersion("1.50.0")! < MoleAnalyzerRelease.reportFormatFloor)
        #expect(MoleVersion("1.56.1") == MoleAnalyzerRelease.reportFormatFloor)
        for value in ["1.58", "1.58.0; rm", "1.58.0_1", "v1.58.0", "1.-1.0", "1.58.0\n"] {
            #expect(MoleVersion(value) == nil)
        }
        #expect(MoleAnalyzerRelease.nativeArtifacts.allSatisfy { $0.isReviewed && !$0.requiresUntestedConsent })
        #expect(MoleAnalyzerRelease.reviewedArtifacts.count == 5)
        #expect(MoleAnalyzerRelease.legacyArm64.normalizedVersion == "1.57.0")
    }

    @Test("Homebrew 1.50 describes the coverage-format blocker and retains its upgrade source")
    func legacyHomebrew() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let candidate = try await makeInstallation(base, version: "1.50.0")
        #expect(candidate.currentVersion == "1.50.0")
        #expect(candidate.issue == .unsupportedFormat)
        #expect(candidate.isHomebrewCore && candidate.canUpgradeHomebrew)
        #expect(!candidate.canVerifyHomebrew && candidate.verifiedRelease == nil)
        #expect(candidate.origin == .homebrew(prefix: base))
    }

    @Test("A current source build is unverified, not blanket incompatible")
    func unverifiedCurrent() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let candidate = try await makeInstallation(base, version: "1.58.0")
        #expect(candidate.currentVersion == "1.58.0" && candidate.state == .unverified)
        #expect(candidate.issue == .unverifiedBuild && candidate.canVerifyHomebrew)
        #expect(!candidate.canUpgradeHomebrew)
        let unknown = MoleInstallationCandidate(path: "/Synthetic/analyze-go", state: .unverified,
            source: "Synthetic", explanation: "", origin: .standalone, issue: .missingVersion)
        #expect(unknown.currentVersion == nil && !unknown.canUpgradeHomebrew)
    }

    @Test("Custom tap and conflicting version records do not generate a core upgrade")
    func sourceDisagreement() async throws {
        for (tap, receiptVersion, expected) in [("custom/tap", "1.50.0", MoleInstallationIssue.customTap),
                                               ("homebrew/core", "1.58.0", .metadataConflict)] {
            let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
            let candidate = try await makeInstallation(base, version: "1.50.0", tap: tap, receiptVersion: receiptVersion)
            #expect(candidate.issue == expected && !candidate.canUpgradeHomebrew && !candidate.canVerifyHomebrew)
        }
    }

    @Test("Metadata strings are parsed as data and never executed")
    func wrapperMetadata() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("mole")
        try Data("#!/bin/sh\nVERSION=\"1.58.0\"\nexit 98\n".utf8).write(to: path)
        #expect(MoleInstallationMetadata.wrapperVersion(at: path) == "1.58.0")
        try Data("VERSION=\"$(touch malicious)\"\n".utf8).write(to: path)
        #expect(MoleInstallationMetadata.wrapperVersion(at: path) == nil)
        try Data("VERSION=\"1.58.0\"\nVERSION=\"1.59.0\"\n".utf8).write(to: path)
        #expect(MoleInstallationMetadata.wrapperVersion(at: path) == nil)
        let link = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        #expect(MoleInstallationMetadata.wrapperVersion(at: link) == nil)
    }

    @Test("Existing managed installs are not masked by a parallel known old analyzer")
    func sourcePreference() {
        let managed = MoleInstallationCandidate(path: "/opt/homebrew/Cellar/mole/1.50.0/libexec/bin/analyze-go",
            state: .incompatible, source: "Homebrew", explanation: "", declaredVersion: "1.50.0",
            origin: .homebrew(prefix: URL(fileURLWithPath: "/opt/homebrew")), issue: .unsupportedFormat,
            kegVersion: "1.50.0", isHomebrewCore: true)
        let fallback = MoleInstallationCandidate(path: "/Synthetic/old/analyze-go", state: .usable,
            source: "Standalone", explanation: "", verifiedRelease: .legacyArm64)
        let report = MoleInstallationReport(candidates: [managed, fallback], inspectedAt: Date())
        #expect(report.selectedCandidate?.path == managed.path)
        #expect(report.verifiedExecutable == nil && report.state == .incompatible)
    }

    @Test("A wrong-architecture managed prefix cannot hide another eligible managed installation")
    func dualHomebrewPrefixes() {
        let wrong = MoleInstallationCandidate(path: "/Synthetic/wrong/analyze-go", state: .incompatible,
            source: "Homebrew", explanation: "", declaredVersion: "1.58.0",
            verifiedRelease: MoleAnalyzerRelease.nativeArchitecture == "arm64" ? .x86_64 : .arm64,
            origin: .homebrew(prefix: URL(fileURLWithPath: "/opt/homebrew")), issue: .unsupportedArchitecture)
        let right = MoleInstallationCandidate(path: "/Synthetic/native/analyze-go", state: .usable,
            source: "Homebrew", explanation: "", verifiedRelease: .native,
            origin: .homebrew(prefix: URL(fileURLWithPath: "/usr/local")))
        let report = MoleInstallationReport(candidates: [wrong, right], inspectedAt: Date())
        #expect(report.selectedCandidate?.path == right.path && report.verifiedExecutable?.path == right.path)
        let locations = MoleInstallationLocation.standard(home: URL(fileURLWithPath: "/Synthetic"))
        #expect(locations.first?.url.path.hasPrefix(MoleAnalyzerRelease.nativeArchitecture == "arm64" ? "/opt/homebrew/" : "/usr/local/") == true)
    }

    @Test("Online proof requires a current official origin, architecture and bounded major-version contract")
    func onlineProof() {
        var release = MoleAnalyzerRelease(version: "V1.59.0", architecture: MoleAnalyzerRelease.nativeArchitecture,
            byteCount: 12, sha256: String(repeating: "a", count: 64), origin: .verifiedHomebrewBottle,
            onlineProof: MoleOnlineArtifactProof(verifiedAt: Date(), bottleSHA256: String(repeating: "b", count: 64),
                bottleURL: URL(string: "https://ghcr.io/v2/homebrew/core/mole/blobs/sha256:" + String(repeating: "b", count: 64))!))
        #expect(release.isEligible && release.requiresUntestedConsent)
        release.onlineProof = nil
        #expect(!release.isEligible)
        release.onlineProof = MoleOnlineArtifactProof(verifiedAt: Date(timeIntervalSinceNow: -7200),
            bottleSHA256: String(repeating: "b", count: 64), bottleURL: URL(string: "https://ghcr.io/x")!)
        #expect(!release.isEligible)
    }

    private func makeInstallation(_ base: URL, version: String, tap: String = "homebrew/core", receiptVersion: String? = nil) async throws -> MoleInstallationCandidate {
        let cellar = base.appendingPathComponent("Cellar/mole"), keg = base.appendingPathComponent("Cellar/mole/" + version)
        let bin = keg.appendingPathComponent("libexec/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let bytes = Data("synthetic unverified analyzer; never executed".utf8)
        let analyzer = bin.appendingPathComponent("analyze-go")
        try bytes.write(to: analyzer); try #require(chmod(analyzer.path, 0o700) == 0)
        let receipt = ["source": ["tap": tap, "versions": ["stable": receiptVersion ?? version]]] as [String: Any]
        try JSONSerialization.data(withJSONObject: receipt).write(to: keg.appendingPathComponent("INSTALL_RECEIPT.json"))
        let report = try await MoleInstallationDiscovery(locations: [.init(url: analyzer, kind: .homebrew(cellar: cellar))]).discover()
        return try #require(report.selectedCandidate)
    }
    private func fixture() throws -> URL {
        let url = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory).appendingPathComponent("MoeKit-compatibility-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
