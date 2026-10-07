import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Bounded Mole setup discovery")
struct MoleInstallationDiscoveryTests {
    @Test("The novice path and both Homebrew layouts are fixed, bounded, and shell independent")
    func fixedLocations() {
        let home = URL(fileURLWithPath: "/Synthetic/Home")
        let locations = MoleInstallationLocation.standard(home: home)
        #expect(locations.count == 11)
        #expect(locations.count <= MoleInstallationDiscovery.maximumLocations)
        #expect(locations.contains { $0.url.path == home.path + "/" + MoleAnalyzerRelease.native.installationDirectoryName + "/analyze-go" })
        #expect(locations.contains { $0.url.path == "/Synthetic/Home/.config/mole/bin/analyze-go" })
        #expect(locations.contains { $0.url.path == "/opt/homebrew/opt/mole/libexec/bin/analyze-go" })
        #expect(locations.contains { $0.url.path == "/usr/local/opt/mole/libexec/bin/analyze-go" })
        #expect(locations.filter { $0.kind == .wrapper }.count == 6)
    }

    @Test("Exact bytes are usable; installed unsupported files do not become missing")
    func classifications() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data("synthetic analyzer; never execute".utf8)
        let good = try file(base, "good", bytes)
        let bad = try file(base, "bad", Data(repeating: 0, count: bytes.count))
        let locations = [good, bad, base.appendingPathComponent("missing")].map { MoleInstallationLocation(url: $0, kind: .analyzer) }
        let report = try await MoleInstallationDiscovery(locations: locations, release: pin(bytes)).discover()
        #expect(report.candidates.map(\.state) == [.usable, .unverified, .missing])
        #expect(report.state == .usable)
        #expect(report.verifiedExecutable == good)
        #expect(try Data(contentsOf: good) == bytes)
        let unsupported = try await MoleInstallationDiscovery(locations: [locations[1]]).discover()
        #expect(unsupported.state == .unverified && unsupported.verifiedExecutable == nil)
    }

    @Test("Commands, final links, FIFO and directories remain unverified and are never run")
    func noExecutionOrSpecialFileReads() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let sentinel = base.appendingPathComponent("must-not-exist")
        let script = try file(base, "mo", Data("#!/bin/sh\ntouch '\(sentinel.path)'\n".utf8))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        let dangling = base.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "absent")
        let fifo = base.appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let locations = [MoleInstallationLocation(url: script, kind: .wrapper)] +
            [link, dangling, fifo, base].map { MoleInstallationLocation(url: $0, kind: .analyzer) }
        let report = try await MoleInstallationDiscovery(locations: locations).discover()
        #expect(report.candidates.allSatisfy { $0.state == .unverified })
        #expect(report.state == .unverified && report.verifiedExecutable == nil)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("Homebrew opt aliases resolve only into the expected formula version layout")
    func homebrewAliases() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let cellar = base.appendingPathComponent("Cellar/mole")
        let version = cellar.appendingPathComponent("1.57.0")
        let binaryDirectory = version.appendingPathComponent("libexec/bin")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let bytes = Data("homebrew-layout fixture".utf8)
        let analyzer = try file(binaryDirectory, "analyze-go", bytes)
        let opt = base.appendingPathComponent("opt")
        try FileManager.default.createSymbolicLink(at: opt, withDestinationURL: version)
        let location = MoleInstallationLocation(url: opt.appendingPathComponent("libexec/bin/analyze-go"), kind: .homebrew(cellar: cellar))
        let report = try await MoleInstallationDiscovery(locations: [location], release: pin(bytes)).discover()
        #expect(report.verifiedExecutable == analyzer)
        // A real Homebrew build differs: a recognized location never grants trust.
        #expect(try await MoleInstallationDiscovery(locations: [location]).discover().state == .unverified)
        let outside = MoleInstallationLocation(url: analyzer, kind: .homebrew(cellar: base))
        #expect(try await MoleInstallationDiscovery(locations: [outside], release: pin(bytes)).discover().state == .unverified)
    }

    @Test("Quarantine, permission changes and unreadable ancestors cannot claim readiness")
    func blockedCandidates() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data("fixture".utf8)
        let quarantined = try file(base, "quarantined", bytes)
        let fd = try MoleAnalysisFiles.openPath(quarantined, directory: false); defer { close(fd) }
        let attr = Data("0081;fixture;MoeKitTest;".utf8)
        try #require(attr.withUnsafeBytes { fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) } == 0)
        let writable = try file(base, "writable", bytes)
        try #require(chmod(writable.path, 0o777) == 0)
        let noExec = try file(base, "no-exec", bytes)
        try #require(chmod(noExec.path, 0o600) == 0)
        let loop = base.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")
        let locations = [quarantined, writable, noExec, loop.appendingPathComponent("analyze-go")].map {
            MoleInstallationLocation(url: $0, kind: .analyzer)
        }
        let report = try await MoleInstallationDiscovery(locations: locations, release: pin(bytes)).discover()
        #expect(report.candidates.map(\.state) == [.unverified, .unverified, .unverified, .unverified])
        #expect(report.verifiedExecutable == nil)
        #expect(fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0) == attr.count)
    }

    @Test("Invalid URLs and oversized discovery requests stop safely")
    func budgetAndInvalidURLs() async throws {
        let invalid = MoleInstallationLocation(url: URL(string: "https://example.invalid/analyze-go")!, kind: .analyzer)
        #expect(try await MoleInstallationDiscovery(locations: [invalid]).discover().state == .unverified)
        await #expect(throws: MoleAnalysisFailure.invalidSelection) {
            try await MoleInstallationDiscovery(locations: Array(repeating: invalid, count: 13)).discover()
        }
    }

    @Test("Recheck observes replaced bytes instead of retaining earlier readiness")
    func changedBetweenChecks() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data("fixture-one".utf8)
        let analyzer = try file(base, "analyze-go", bytes)
        let discovery = MoleInstallationDiscovery(locations: [.init(url: analyzer, kind: .analyzer)], release: pin(bytes))
        #expect(try await discovery.discover().state == .usable)
        try Data("fixture-two".utf8).write(to: analyzer)
        #expect(try await discovery.discover().state == .unverified)
    }

    private func fixture() throws -> URL {
        let base = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)
            .appendingPathComponent("MoeKit-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        return base
    }
    private func file(_ base: URL, _ name: String, _ bytes: Data) throws -> URL {
        let url = base.appendingPathComponent(name)
        try bytes.write(to: url); try #require(chmod(url.path, 0o700) == 0)
        return url
    }
    private func pin(_ bytes: Data) -> MoleAnalyzerRelease {
        MoleAnalyzerRelease(version: "synthetic-only", architecture: "fixture", byteCount: bytes.count,
                            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
