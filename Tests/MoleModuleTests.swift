import Foundation
import Testing
@testable import MoeKit

@Suite("Built-in tool modules")
struct MoleModuleTests {
    @Test("Mole has stable module and capability identities")
    func stableIdentities() throws {
        let registry = ToolModuleRegistry.builtIn
        let mole = try #require(registry.descriptor(id: "mole"))

        #expect(mole.id == MoleModule.id)
        #expect(mole.capabilities.map(\.id) == [
            "mole.space", "mole.clean", "mole.apps", "mole.maintenance", "mole.status"
        ])
        #expect(MoleCapability.allCases.map(\.rawValue) == ["space", "clean", "apps", "maintenance", "status"])
        #expect(mole.capabilities.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
        #expect(mole.systemImage == "internaldrive")
    }

    @Test("Every Mole operation is explicitly unavailable in this milestone")
    func honestReadiness() throws {
        let mole = try #require(ToolModuleRegistry.builtIn.descriptor(id: MoleModule.id))
        #expect(!mole.readiness.canExecute)
        #expect(mole.readiness.explanation?.isEmpty == false)
        #expect(mole.capabilities.allSatisfy { !$0.readiness.canExecute })
        #expect(mole.capabilities.allSatisfy { $0.readiness.explanation?.isEmpty == false })
    }

    @Test("Search covers IDs, keywords, and capabilities with all words required")
    func registrySearch() {
        let registry = ToolModuleRegistry.builtIn
        #expect(registry.search(" \n\t ").map(\.id) == ["mole"])
        #expect(registry.search("MOLE").map(\.id) == ["mole"])
        #expect(registry.search("mole disk").map(\.id) == ["mole"])
        #expect(registry.search("uninstall").map(\.id) == ["mole"])
        #expect(registry.search("mole.maintenance").map(\.id) == ["mole"])
        #expect(registry.search("清理").map(\.id) == ["mole"])
        #expect(registry.search("mole no-such-capability").isEmpty)
        #expect(registry.module(id: "missing") == nil)
    }

    @Test("The catalog can contain another compiled-in personal CLI tool")
    func registryExtensibility() throws {
        let other = FixtureModule(descriptor: ToolModuleDescriptor(
            id: "fixture.developer-tool",
            title: "Developer Tool",
            summary: "A separate built-in integration",
            systemImage: "hammer",
            category: .development,
            keywords: ["worktree"],
            readiness: .unavailable(reason: "Not connected"),
            capabilities: []
        ))
        let registry = try ToolModuleRegistry(modules: [MoleModule(), other])
        #expect(registry.descriptors.map(\.id) == ["mole", "fixture.developer-tool"])
        #expect(registry.search("worktree").map(\.id) == ["fixture.developer-tool"])
        #expect(registry.module(id: "fixture.developer-tool") != nil)
    }

    @Test("Duplicate IDs cannot silently overwrite a module or capability")
    func duplicateIdentities() {
        #expect(throws: ToolModuleRegistryError.duplicateModuleID("mole")) {
            try ToolModuleRegistry(modules: [MoleModule(), MoleModule()])
        }

        let collision = FixtureModule(descriptor: ToolModuleDescriptor(
            id: "another-module",
            title: "Another module",
            summary: "A malformed fixture",
            systemImage: "hammer",
            category: .development,
            keywords: [],
            readiness: .unavailable(reason: "Not connected"),
            capabilities: [MoleCapability.space.descriptor]
        ))
        #expect(throws: ToolModuleRegistryError.duplicateCapabilityID("mole.space")) {
            try ToolModuleRegistry(modules: [MoleModule(), collision])
        }
    }

    private struct FixtureModule: ToolModule {
        let descriptor: ToolModuleDescriptor
    }
}

@Suite("Read-only Mole analyze JSON")
struct MoleAnalyzeReportTests {
    @Test("Current JSON retains bytes, flags, timestamps, and large-file identity")
    func modernReport() throws {
        let report = try decode(#"""
        {
          "scan_status": "complete", "path": "/Fixture", "overview": false,
          "entries": [
            {"scan_status":"complete", "name":"Build", "path":"/Fixture/Build", "size":4096,
             "is_dir":true, "cleanable":true, "last_access":"2026-10-03T06:00:00Z"},
            {"scan_status":"complete", "name":"movie.mp4", "path":"/Fixture/movie.mp4", "size":8192,
             "is_dir":false}
          ],
          "large_files": [{"name":"movie.mp4", "path":"/Fixture/movie.mp4", "size":8192}],
          "total_size":12288, "total_files":3
        }
        """#)
        let entry = try #require(report.entries.first)

        #expect(report.path == "/Fixture")
        #expect(!report.overview)
        #expect(report.coverage == .known)
        #expect(report.reportedBytes == 12_288)
        #expect(report.measuredBytes == 12_288)
        #expect(report.totalFiles == 3)
        #expect(entry.id == "/Fixture/Build")
        #expect(entry.isDirectory)
        #expect(entry.cleanable)
        #expect(!entry.insight)
        #expect(entry.lastAccessTimestamp == "2026-10-03T06:00:00Z")
        #expect(entry.lastAccess != nil)
        #expect(report.largeFiles.first?.id == "/Fixture/movie.mp4")
        #expect(report.largeFiles.first?.reportedBytes == 8192)
        #expect(report.canShowAdditivePercentages)
    }

    @Test("Legacy JSON retains the reported size with unknown coverage")
    func legacyReport() throws {
        let report = try decode(#"""
        {"path":"/Fixture", "overview":false,
         "entries":[{"name":"Library", "path":"/Fixture/Library", "size":2048, "is_dir":true}],
         "total_size":2048}
        """#)

        #expect(report.coverage == .unknown)
        #expect(report.entries.first?.coverage == .unknown)
        #expect(report.measuredBytes == 2048)
        #expect(report.entries.first?.measuredBytes == 2048)
        #expect(report.totalFiles == nil)
        #expect(report.largeFiles.isEmpty)
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("Partial bytes are a lower bound and unavailable zero is not empty")
    func partialReport() throws {
        let report = try decode(#"""
        {"scan_status":"partial", "path":"/Fixture", "overview":false,
         "entries":[
            {"scan_status":"partial", "name":"Partial", "path":"/Fixture/Partial", "size":3072, "is_dir":true},
            {"scan_status":"unavailable", "name":"Restricted", "path":"/Fixture/Restricted", "size":0, "is_dir":true}
         ], "total_size":3072}
        """#)
        let partial = try #require(report.entries.first)
        let unavailable = try #require(report.entries.last)

        #expect(report.coverage == .partial)
        #expect(report.measuredBytes == 3072)
        #expect(report.measurement.isLowerBound)
        #expect(partial.measurement.isLowerBound)
        #expect(partial.measuredBytes == 3072)
        #expect(unavailable.coverage == .unavailable)
        #expect(unavailable.reportedBytes == 0)
        #expect(unavailable.measuredBytes == nil)
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("Unavailable top-level results never present reported bytes as measured", arguments: [0, 4096])
    func unavailableReport(bytes: Int) throws {
        let report = try decode("""
        {"scan_status":"unavailable", "path":"/Fixture", "overview":false, "entries":[], "total_size":\(bytes)}
        """)
        #expect(report.reportedBytes == Int64(bytes))
        #expect(report.measuredBytes == nil)
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("Null arrays and optional values are accepted without fabricating coverage")
    func nullArrays() throws {
        let report = try decode(#"""
        {"scan_status":null, "path":"/Fixture", "overview":false,
         "entries":null, "large_files":null, "total_size":0, "total_files":null}
        """#)
        #expect(report.entries.isEmpty)
        #expect(report.largeFiles.isEmpty)
        #expect(report.totalFiles == nil)
        #expect(report.coverage == .unknown)
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("Unknown fields and future status strings remain usable with unknown coverage")
    func futureSchema() throws {
        let report = try decode(#"""
        {"scan_status":"cached", "path":"/Fixture", "overview":false,
         "entries":[{"scan_status":"future-status", "name":"Folder", "path":"/Fixture/Folder",
           "size":12, "is_dir":true, "last_access":null, "cleanable":null, "insight":null,
           "future_metadata":{"example":true}}],
         "total_size":12, "schema_version":"future", "unexpected":[1,2,3]}
        """#)
        let entry = try #require(report.entries.first)
        #expect(report.coverage == .unknown)
        #expect(entry.coverage == .unknown)
        #expect(entry.measuredBytes == 12)
        #expect(!entry.cleanable)
        #expect(!entry.insight)
        #expect(entry.lastAccess == nil)
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("An overview never permits additive percentages even when totals reconcile")
    func overlappingOverview() throws {
        let report = try decode(#"""
        {"scan_status":"complete", "path":"/", "overview":true,
         "entries":[
           {"scan_status":"complete", "name":"Home", "path":"/Users/fixture", "size":100, "is_dir":true},
           {"scan_status":"complete", "name":"Old Downloads", "path":"/Users/fixture/Downloads", "size":25, "is_dir":true, "insight":true}
         ], "total_size":125}
        """#)
        #expect(report.reportedBytes == 125)
        #expect(report.entries.last?.insight == true)
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("Entry identity is its path even when display names are identical")
    func pathIdentity() throws {
        let report = try decode(#"""
        {"path":"/", "overview":true, "entries":[
          {"name":"Cache", "path":"/A/Cache", "size":1, "is_dir":true},
          {"name":"Cache", "path":"/B/Cache", "size":1, "is_dir":true}
        ], "total_size":2}
        """#)
        #expect(report.entries.map(\.id) == ["/A/Cache", "/B/Cache"])
        #expect(Set(report.entries.map(\.id)).count == 2)
    }

    @Test("Negative total, entry, large-file, and count values are rejected", arguments: [
        #"{"path":"/", "overview":false, "entries":[], "total_size":-1}"#,
        #"{"path":"/", "overview":false, "entries":[{"name":"x", "path":"/x", "size":-1, "is_dir":true}], "total_size":0}"#,
        #"{"path":"/", "overview":false, "entries":[], "large_files":[{"name":"x", "path":"/x", "size":-1}], "total_size":0}"#,
        #"{"path":"/", "overview":false, "entries":[], "total_size":0, "total_files":-1}"#,
        #"{"scan_status":"unavailable", "path":"/", "overview":false, "entries":[], "total_size":-1}"#
    ])
    func rejectNegativeValues(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test("Byte integers preserve precision beyond Double's exact integer range")
    func integerPrecision() throws {
        let report = try decode(#"""
        {"scan_status":"complete", "path":"/Fixture", "overview":false,
         "entries":[{"scan_status":"complete", "name":"big", "path":"/Fixture/big", "size":9007199254740993, "is_dir":false}],
         "total_size":9007199254740993}
        """#)
        #expect(report.reportedBytes == 9_007_199_254_740_993)
        #expect(report.entries.first?.reportedBytes == 9_007_199_254_740_993)
        #expect(report.canShowAdditivePercentages)
    }

    @Test("Invalid number types and missing required size are rejected", arguments: [
        #"{"path":"/", "overview":false, "entries":[], "total_size":1.5}"#,
        #"{"path":"/", "overview":false, "entries":[], "total_size":"1024"}"#,
        #"{"path":"/", "overview":false, "entries":[], "total_size":9223372036854775808}"#,
        #"{"path":"/", "overview":false, "entries":[], "total_size":null}"#,
        #"{"path":"/", "overview":false, "entries":[]}"#
    ])
    func rejectInvalidValues(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test("An overflowing row sum cannot enable misleading proportions")
    func overflowingSum() throws {
        let report = try decode(#"""
        {"scan_status":"complete", "path":"/Fixture", "overview":false, "entries":[
          {"scan_status":"complete", "name":"a", "path":"/Fixture/a", "size":9223372036854775807, "is_dir":false},
          {"scan_status":"complete", "name":"b", "path":"/Fixture/b", "size":1, "is_dir":false}
        ], "total_size":9223372036854775807}
        """#)
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("A mismatched total cannot enable additive proportions")
    func inconsistentDirectoryTotals() throws {
        let report = try decode(#"""
        {"scan_status":"complete", "path":"/Fixture", "overview":false,
         "entries":[{"scan_status":"complete", "name":"a", "path":"/Fixture/a", "size":4, "is_dir":false}],
         "total_size":5}
        """#)
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("Duplicate path identities within either row array reject import", arguments: [
        (#"{"path":"/Fixture","overview":false,"entries":[{"name":"a","path":"/Fixture/a","size":4,"is_dir":false},{"name":"alias","path":"/Fixture/a","size":4,"is_dir":false}],"total_size":8}"#, "entries"),
        (#"{"path":"/Fixture","overview":false,"entries":[],"large_files":[{"name":"a","path":"/Fixture/a","size":4},{"name":"alias","path":"/Fixture/a","size":4}],"total_size":8}"#, "large_files")
    ])
    func rejectDuplicateRowIdentities(json: String, key: String) throws {
        do {
            _ = try decode(json)
            Issue.record("Expected duplicate path identities to reject import.")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.codingPath.last?.stringValue == key)
            #expect(context.debugDescription.contains("Duplicate"))
        }
    }

    @Test("Additive views require lexical direct children, not nested or unrelated paths", arguments: [
        ["/Fixture/a", "/Fixture/a/child"],
        ["/Fixture/a", "/Other/b"],
        ["/Fixture/a", "/Fixture"],
        ["/Fixture/a", "/Fixture-other/b"],
        ["/Fixture/a", "/"]
    ])
    func rejectNonDirectChildren(paths: [String]) throws {
        let report = try directoryReport(path: "/Fixture", entryPaths: paths)
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("Ambiguous or nonabsolute child identities disable additive views", arguments: [
        "relative", "Fixture/a", "", "/Fixture/./a", "/Fixture/../a",
        "/Fixture/a/", "/Fixture//a", "//Fixture/a", "/Fixture/a\0b"
    ])
    func rejectAmbiguousChildPath(path: String) throws {
        let report = try directoryReport(path: "/Fixture", entryPaths: [path])
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("Ambiguous or nonabsolute report paths disable additive views", arguments: [
        "Fixture", "", "/Fixture/", "/./Fixture", "/A/../Fixture", "//Fixture", "/Fix\0ture"
    ])
    func rejectAmbiguousParentPath(path: String) throws {
        let report = try directoryReport(path: path, entryPaths: ["/Fixture/a"])
        #expect(!report.canShowAdditivePercentages)
    }

    @Test("Canonical absolute direct-child paths work at root and with Unicode names", arguments: [
        ("/", ["/Applications", "/Library"]),
        ("/Fixture", ["/Fixture/工作目录", "/Fixture/a b"]),
        ("/Fixture/nested", ["/Fixture/nested/a", "/Fixture/nested/b"])
    ])
    func canonicalDirectChildren(path: String, children: [String]) throws {
        let report = try directoryReport(path: path, entryPaths: children)
        #expect(report.canShowAdditivePercentages)
    }

    @Test("Invalid optional dates stay unknown, while fractional RFC3339 is supported", arguments: [
        ("not-a-date", false), ("2026-10-03T06:00:00.125Z", true)
    ])
    func optionalDates(timestamp: String, isValid: Bool) throws {
        let report = try decode("""
        {"path":"/Fixture", "overview":false,
         "entries":[{"name":"a", "path":"/Fixture/a", "size":1, "is_dir":false, "last_access":"\(timestamp)"}],
         "total_size":1}
        """)
        let entry = try #require(report.entries.first)
        #expect((entry.lastAccess != nil) == isValid)
        #expect(entry.lastAccessTimestamp == timestamp)
    }

    private func decode(_ json: String) throws -> MoleAnalyzeReport {
        try JSONDecoder().decode(MoleAnalyzeReport.self, from: Data(json.utf8))
    }

    private func directoryReport(path: String, entryPaths: [String]) throws -> MoleAnalyzeReport {
        let fixture: [String: Any] = [
            "scan_status": "complete", "path": path, "overview": false,
            "entries": entryPaths.map { entryPath -> [String: Any] in
                ["scan_status": "complete", "name": "Entry", "path": entryPath, "size": 1, "is_dir": true]
            },
            "total_size": entryPaths.count
        ]
        return try JSONDecoder().decode(MoleAnalyzeReport.self, from: JSONSerialization.data(withJSONObject: fixture))
    }
}
