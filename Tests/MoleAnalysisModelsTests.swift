import Foundation
import Testing
@testable import MoeKit

@Suite("Mole live analysis contract")
struct MoleAnalysisModelsTests {
    @Test("Official pins are architecture-specific without version execution")
    func pins() {
        #expect(MoleAnalyzerRelease.arm64.byteCount == 3_827_474)
        #expect(MoleAnalyzerRelease.x86_64.byteCount == 4_022_992)
        #expect(MoleAnalyzerRelease.arm64.sha256.count == 64)
        #expect(MoleAnalyzerRelease.arm64.sha256 != MoleAnalyzerRelease.x86_64.sha256)
    }

    @Test("Live report accepts known, partial and unavailable without inventing bytes", arguments: ["complete", "partial", "unavailable"])
    func validCoverage(coverage: String) throws {
        let result = try decode(report(coverage: coverage))
        #expect(result.coverage == MoleScanCoverage(wireValue: coverage))
        #expect((result.measuredBytes == nil) == (coverage == "unavailable"))
    }

    @Test("Live report rejects unknown/legacy coverage", arguments: ["unknown", "new-status", ""])
    func unknownCoverage(coverage: String) {
        #expect(throws: MoleAnalysisFailure.unknownCoverage) { try decode(report(coverage: coverage)) }
    }

    @Test("Live report rejects scope escapes, aliases and nested entry rows", arguments: [
        "/Outside/a", "/Selected-other/a", "/Selected/../a", "/Selected//a", "/Selected/./a", "/Selected/a/b", "relative"
    ])
    func outsideEntries(path: String) {
        #expect(throws: MoleAnalysisFailure.outsideScope) { try decode(report(entry: path)) }
    }

    @Test("Live large-file paths may be descendants but never escape")
    func largeFiles() throws {
        #expect(try decode(report(largeFile: "/Selected/a/b")).largeFiles.count == 1)
        #expect(throws: MoleAnalysisFailure.outsideScope) { try decode(report(largeFile: "/Selected-other/a")) }
        #expect(throws: MoleAnalysisFailure.outsideScope) { try decode(report(largeFile: "/Selected/a/../../Outside")) }
    }

    @Test("Overview and wrong root do not become selected-folder results")
    func roots() {
        #expect(throws: MoleAnalysisFailure.outsideScope) { try decode(report().replacingOccurrences(of: "false", with: "true")) }
        #expect(throws: MoleAnalysisFailure.outsideScope) { try decode(report().replacingOccurrences(of: "\"path\":\"/Selected\"", with: "\"path\":\"/Other\"")) }
    }

    @Test("Malformed, duplicated and oversized output is rejected")
    func malformed() {
        #expect(throws: MoleAnalysisFailure.invalidReport) { try decode("not json") }
        #expect(throws: MoleAnalysisFailure.outputLimit) {
            try MoleLiveReportValidator.decode(Data(repeating: 0, count: MoleLiveReportValidator.maximumBytes + 1), selectedDirectory: URL(fileURLWithPath: "/Selected"))
        }
    }

    @Test("Private session scope overlap is component-aware")
    func overlap() {
        #expect(MoleLiveReportValidator.overlaps(URL(fileURLWithPath: "/Users/a"), URL(fileURLWithPath: "/Users/a/Library/Caches/MoeKit")))
        #expect(!MoleLiveReportValidator.overlaps(URL(fileURLWithPath: "/Users/ab"), URL(fileURLWithPath: "/Users/a")))
    }

    private func decode(_ text: String) throws -> MoleAnalyzeReport {
        try MoleLiveReportValidator.decode(Data(text.utf8), selectedDirectory: URL(fileURLWithPath: "/Selected"))
    }
    private func report(coverage: String = "complete", entry: String = "/Selected/a", largeFile: String? = nil) -> String {
        let large = largeFile.map { ",\"large_files\":[{\"name\":\"b\",\"path\":\"\($0)\",\"size\":1}]" } ?? ""
        return """
        {"path":"/Selected","overview":false,"scan_status":"\(coverage)","total_size":1,
        "entries":[{"name":"a","path":"\(entry)","size":1,"is_dir":true,"scan_status":"\(coverage)"}]\(large)}
        """
    }
}
