import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Mole descriptor and private-session boundaries")
struct MoleAnalysisFilesTests {
    @Test("Nonlocal, NUL and oversized selections are rejected before filesystem calls")
    func malformedSelections() throws {
        for url in [URL(string: "file://remote-host/tmp/fixture")!, URL(fileURLWithPath: "/tmp/a\0b"),
                    URL(fileURLWithPath: "/" + String(repeating: "a", count: 4096))] {
            #expect(throws: MoleAnalysisFailure.invalidSelection) { try MoleAnalysisFiles.validateLocalURL(url) }
        }
    }

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
            try bytes.write(to: source); try #require(chmod(source.path, 0o700) == 0)
            let fd = try MoleAnalysisFiles.openPath(source, directory: false)
            defer { close(fd) }
            let marker = Data("preserved".utf8)
            let set = marker.withUnsafeBytes { fsetxattr(fd, "com.moekit.test-origin", $0.baseAddress, $0.count, 0, 0) }
            try #require(set == 0)
            try #require(fchmod(fd, 0o500) == 0)
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

    @Test("Staging refuses a source that grew or truncated after its pin and caps target bytes", arguments: [false, true])
    func boundedCopy(grew: Bool) throws {
        try fixture { base in
            let original = Data(repeating: 65, count: 1024)
            let changed = grew ? original + Data(repeating: 66, count: 1024) : Data(original.prefix(100))
            let source = base.appendingPathComponent("source")
            let target = base.appendingPathComponent("target")
            try changed.write(to: source)
            let sourceFD = try MoleAnalysisFiles.openPath(source, directory: false)
            defer { close(sourceFD) }
            let targetFD = open(target.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
            try #require(targetFD >= 0)
            defer { close(targetFD) }
            #expect(throws: MoleAnalysisFailure.changedSelection) {
                try MoleAnalysisFiles.copyPinnedBytesAndAttributes(from: sourceFD, to: targetFD, release: fixtureRelease(original))
            }
            var info = stat()
            try #require(fstat(targetFD, &info) == 0)
            #expect(info.st_size <= original.count)
        }
    }

    @Test("Cancelled staging creates no copied payload")
    func cancelledCopy() async throws {
        let base = (try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)).appendingPathComponent("MoeKit-cancel-copy-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        let data = Data(repeating: 65, count: 128 * 1024)
        try data.write(to: source)
        let release = fixtureRelease(data)
        let sourceFD = try MoleAnalysisFiles.openPath(source, directory: false)
        let targetFD = open(target.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        try #require(targetFD >= 0)
        defer { close(sourceFD); close(targetFD) }
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try MoleAnalysisFiles.copyPinnedBytesAndAttributes(from: sourceFD, to: targetFD, release: release)
                return false
            } catch { return error is CancellationError }
        }.value
        #expect(cancelled)
        var info = stat()
        try #require(fstat(targetFD, &info) == 0)
        #expect(info.st_size == 0)
    }

    @Test("Quarantine is refused and never removed")
    func quarantine() throws {
        try fixture { base in
            let file = base.appendingPathComponent("binary")
            let bytes = Data("synthetic".utf8)
            try bytes.write(to: file); try #require(chmod(file.path, 0o700) == 0)
            let fd = try MoleAnalysisFiles.openPath(file, directory: false)
            defer { close(fd) }
            let attr = Data("0081;fixture;MoeKitTest;".utf8)
            try #require(attr.withUnsafeBytes { fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) } == 0)
            try #require(fchmod(fd, 0o500) == 0)
            #expect(throws: MoleAnalysisFailure.quarantinedBinary) { try MoleAnalysisFiles.verifyAnalyzer(fd, release: fixtureRelease(bytes)) }
            #expect(fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0) == attr.count)
        }
    }

    @Test("Replacing the session directory fails closed instead of cleaning a foreign directory")
    func replacedSession() throws {
        try fixture { base in
            let source = base.appendingPathComponent("fixture")
            let bytes = Data("fixture".utf8)
            try bytes.write(to: source); try #require(chmod(source.path, 0o700) == 0)
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
        let unrelated = base.appendingPathComponent("unrelated-input-sentinel")
        try Data("unrelated input stays".utf8).write(to: unrelated)
        let executor = MoleAnalysisExecutor(privateSessionParent: base.appendingPathComponent("private-sessions"))
        let plan = try await executor.prepare(executable: URL(fileURLWithPath: binary), directory: scope)
        let result = try await executor.run(plan)
        #expect(result.report.path == scope.path)
        #expect(result.report.coverage == .known)
        #expect(result.report.entries.contains { $0.path == sentinel.path && $0.measuredBytes == Int64(bytes.count) })
        #expect(try Data(contentsOf: sentinel) == bytes)
        let after = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(try Data(contentsOf: unrelated) == Data("unrelated input stays".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: plan.privateSessionParent.path).isEmpty)

        // The same real upstream analyzer must preserve useful partial results
        // when a synthetic direct child is not readable by the runner user.
        let restricted = scope.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: false)
        try Data("do not change".utf8).write(to: restricted.appendingPathComponent("keep"))
        #expect(chmod(restricted.path, 0o000) == 0)
        defer { _ = chmod(restricted.path, 0o700) }
        #expect(geteuid() != 0, "Permission-denial fixture requires an unprivileged runner")
        let partialPlan = try await executor.prepare(executable: URL(fileURLWithPath: binary), directory: scope)
        let partial = try await executor.run(partialPlan)
        #expect(partial.report.coverage == .partial)
        #expect(partial.report.entries.contains { $0.path == restricted.path && $0.coverage == .unavailable && $0.measuredBytes == nil })
        #expect(partial.report.entries.contains { $0.path == sentinel.path && $0.measuredBytes == Int64(bytes.count) })
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: plan.privateSessionParent.path).isEmpty)
        #expect(chmod(restricted.path, 0o700) == 0)
        #expect(try Data(contentsOf: restricted.appendingPathComponent("keep")) == Data("do not change".utf8))
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
