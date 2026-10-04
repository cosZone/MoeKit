import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Mole descriptor and private-session boundaries")
struct MoleAnalysisFilesTests {
    @Test("Non-following opens reject symbolic links and FIFOs without waiting")
    func specialFiles() throws {
        try fixture { base in
            let file = base.appendingPathComponent("file")
            try Data("fixture".utf8).write(to: file)
            let link = base.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(throws: MoleAnalysisFailure.invalidSelection) { try MoleAnalysisFiles.openPath(link, directory: false) }
            let fifo = base.appendingPathComponent("fifo")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            let fd = try MoleAnalysisFiles.openPath(fifo, directory: false)
            defer { close(fd) }
            #expect(throws: MoleAnalysisFailure.unsupportedBinary) { try MoleAnalysisFiles.verifyAnalyzer(fd, release: .native) }
        }
    }

    @Test("Canonicalization retains a physical spelling that non-following opens accept")
    func canonicalAliases() throws {
        let alias = FileManager.default.temporaryDirectory
        let physical = try MoleAnalysisFiles.canonicalURL(alias)
        let fd = try MoleAnalysisFiles.openDirectory(physical)
        defer { close(fd) }
        #expect(try MoleAnalysisFiles.identity(fd).inode > 0)
        #expect(try MoleAnalysisFiles.canonicalURL(physical) == physical)
    }

    @Test("A verified staged copy preserves bytes and xattrs; cleanup cannot follow outside links")
    func stagingAndCleanup() throws {
        try fixture { base in
            let source = base.appendingPathComponent("fixture-binary")
            let bytes = Data("synthetic binary bytes only; never executed".utf8)
            try bytes.write(to: source); #expect(chmod(source.path, 0o500) == 0)
            let fd = try MoleAnalysisFiles.openPath(source, directory: false)
            defer { close(fd) }
            let marker = Data("preserved".utf8)
            let set = marker.withUnsafeBytes { fsetxattr(fd, "com.moekit.test-origin", $0.baseAddress, $0.count, 0, 0) }
            #expect(set == 0)
            let release = fixtureRelease(bytes)
            let session = try MolePrivateSession(parent: base.appendingPathComponent("private"), sourceFD: fd, release: release)
            let staged = try MoleAnalysisFiles.openPath(session.executable, directory: false)
            defer { close(staged) }
            #expect(try MoleAnalysisFiles.verifyAnalyzer(staged, release: release) != MoleAnalysisFiles.identity(fd))
            #expect(fgetxattr(staged, "com.moekit.test-origin", nil, 0, 0, 0) == marker.count)
            let outside = base.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let sentinel = outside.appendingPathComponent("keep")
            try Data("untouched".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: session.home.appendingPathComponent("outside-link"), withDestinationURL: outside)
            try session.cleanup()
            #expect(!FileManager.default.fileExists(atPath: session.url.path))
            #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
            #expect(try Data(contentsOf: source) == bytes)
        }
    }

    @Test("Quarantine is refused and never removed")
    func quarantine() throws {
        try fixture { base in
            let file = base.appendingPathComponent("binary")
            let bytes = Data("synthetic".utf8)
            try bytes.write(to: file); #expect(chmod(file.path, 0o500) == 0)
            let fd = try MoleAnalysisFiles.openPath(file, directory: false)
            defer { close(fd) }
            let attr = Data("0081;fixture;MoeKitTest;".utf8)
            #expect(attr.withUnsafeBytes { fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) } == 0)
            #expect(throws: MoleAnalysisFailure.quarantinedBinary) { try MoleAnalysisFiles.verifyAnalyzer(fd, release: fixtureRelease(bytes)) }
            #expect(fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0) == attr.count)
        }
    }

    @Test("Replacing the session directory fails closed instead of cleaning a foreign directory")
    func replacedSession() throws {
        try fixture { base in
            let source = base.appendingPathComponent("fixture")
            let bytes = Data("fixture".utf8)
            try bytes.write(to: source); #expect(chmod(source.path, 0o500) == 0)
            let fd = try MoleAnalysisFiles.openPath(source, directory: false)
            defer { close(fd) }
            let session = try MolePrivateSession(parent: base.appendingPathComponent("private"), sourceFD: fd, release: fixtureRelease(bytes))
            try FileManager.default.moveItem(at: session.url, to: base.appendingPathComponent("moved-original"))
            try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: false)
            let sentinel = session.url.appendingPathComponent("keep")
            try Data("foreign".utf8).write(to: sentinel)
            #expect(throws: MoleAnalysisFailure.cleanupIncomplete) { try session.cleanup() }
            #expect(try Data(contentsOf: sentinel) == Data("foreign".utf8))
        }
    }

    @Test("Filesystem validation rejects report symlinks and replaced scope identities")
    func reportPathValidation() throws {
        try fixture { base in
            let scope = base.appendingPathComponent("selected")
            try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: false)
            let fd = try MoleAnalysisFiles.openDirectory(scope)
            defer { close(fd) }
            let identity = try MoleAnalysisFiles.identity(fd)
            let row = scope.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: row, withDestinationURL: base)
            let data = try JSONSerialization.data(withJSONObject: ["path":scope.path,"overview":false,"scan_status":"complete","total_size":0,
                "entries":[["path":row.path,"name":"link","is_dir":true,"size":0,"scan_status":"complete"]]])
            let report = try MoleLiveReportValidator.decode(data, selectedDirectory: scope)
            #expect(throws: MoleAnalysisFailure.outsideScope) { try MoleAnalysisFiles.verifyReportPaths(report, root: scope, identity: identity) }
        }
    }

    private func fixtureRelease(_ bytes: Data) -> MoleAnalyzerRelease {
        MoleAnalyzerRelease(version: "synthetic-test-only", architecture: "fixture", byteCount: bytes.count,
                            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    private func fixture(_ block: (URL) throws -> Void) throws {
        let base = (try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)).appendingPathComponent("MoeKit-mole-test-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        try block(base)
    }
}

@Suite("Official pinned Mole on synthetic input only")
struct MoleOfficialFixtureTests {
    @Test(.enabled(if: MoleOfficialFixtureLocation.path != nil,
                   "Requires the CI-only exact pinned upstream fixture download"))
    func officialAnalyzerDoesNotChangeSelectedFiles() async throws {
        let binary = try #require(MoleOfficialFixtureLocation.path)
        let base = (try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)).appendingPathComponent("MoeKit-official-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let scope = base.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: false)
        let sentinel = scope.appendingPathComponent("must-remain.txt")
        let bytes = Data(repeating: 65, count: 8192)
        try bytes.write(to: sentinel)
        let before = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        let unrelated = base.appendingPathComponent("existing-mole-cache")
        try Data("existing cache stays".utf8).write(to: unrelated)
        let executor = MoleAnalysisExecutor(privateSessionParent: base.appendingPathComponent("private-sessions"))
        let plan = try await executor.prepare(executable: URL(fileURLWithPath: binary), directory: scope)
        let result = try await executor.run(plan)
        #expect(result.report.path == scope.path)
        #expect(result.report.coverage == .known)
        #expect(result.report.entries.contains { $0.path == sentinel.path && ($0.measuredBytes ?? 0) > 0 })
        #expect(try Data(contentsOf: sentinel) == bytes)
        let after = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(try Data(contentsOf: unrelated) == Data("existing cache stays".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: plan.privateSessionParent.path).isEmpty)
    }
}

private final class MoleFixtureBundleToken: NSObject {}
private enum MoleOfficialFixtureLocation {
    static var path: String? {
        guard let url = Bundle(for: MoleFixtureBundleToken.self).url(forResource: "MoleAnalyzerFixturePath", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
