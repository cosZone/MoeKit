import Foundation
import Testing
@testable import MoeKit

struct GitStatusParserTests {
    private let hash = String(repeating: "a", count: 40)
    private var headers: String { "# branch.oid \(hash)\0# branch.head main\0" }
    private func ordinary(_ xy: String, path: String) -> String { "1 \(xy) N... 100644 100644 100644 \(hash) \(hash) \(path)\0" }

    @Test("Complete empty status is an observation, with no guessed upstream")
    func emptyObservation() throws {
        let summary = try GitStatusParser.parse(Data(headers.utf8))
        #expect(summary.changedPathCount == 0)
        #expect(summary.branch == "main")
        #expect(summary.upstream == nil && summary.ahead == nil && summary.behind == nil)
    }

    @Test("Index and worktree counts overlap without double-counting changed paths")
    func counts() throws {
        let text = headers + ordinary("M.", path: "staged") + ordinary(".M", path: "unstaged") +
            ordinary("MM", path: "both") + "? new\nfile with spaces\0" +
            "u UU N... 100644 100644 100644 100644 \(hash) \(hash) \(hash) conflict\0"
        let summary = try GitStatusParser.parse(Data(text.utf8))
        #expect(summary.stagedCount == 2 && summary.unstagedCount == 2)
        #expect(summary.untrackedCount == 1 && summary.conflictCount == 1)
        #expect(summary.changedPathCount == 5)
    }

    @Test("Rename source is a second NUL record even if it looks like a header")
    func renamedPaths() throws {
        let text = headers + "2 R. N... 100644 100644 100644 \(hash) \(hash) R100 to\0# branch.ab +999 -999\0? new\0"
        let summary = try GitStatusParser.parse(Data(text.utf8))
        #expect(summary.stagedCount == 1 && summary.untrackedCount == 1)
        #expect(summary.changedPathCount == 2 && summary.ahead == nil)
    }

    @Test("Filenames are bytes, not UTF-8 text or newline-delimited records")
    func invalidUTF8Path() throws {
        var bytes = Data((headers + "? ").utf8)
        bytes.append(contentsOf: [255, 10, 32, 0])
        #expect(try GitStatusParser.parse(bytes).untrackedCount == 1)
    }

    @Test("Ahead and behind refer only to the reported local upstream")
    func localComparison() throws {
        let summary = try GitStatusParser.parse(Data((headers + "# branch.upstream origin/main\0# branch.ab +2 -3\0# future.header ignored\0").utf8))
        #expect(summary.upstream == "origin/main")
        #expect(summary.ahead == 2 && summary.behind == 3)
        let gone = try GitStatusParser.parse(Data((headers + "# branch.upstream origin/main\0").utf8))
        #expect(gone.ahead == nil && gone.behind == nil)
    }

    @Test("Unborn and detached branches stay distinct")
    func branchKinds() throws {
        #expect(try GitStatusParser.parse(Data("# branch.oid (initial)\0# branch.head main\0".utf8)).isUnborn)
        #expect(try GitStatusParser.parse(Data("# branch.oid \(hash)\0# branch.head (detached)\0".utf8)).branch == nil)
    }

    @Test("Malformed, truncated, or unexpected output cannot become a zero status")
    func invalidOutput() {
        let bad = ["", "# branch.head main\0", headers + "? file", headers + "? \0", headers + "\0",
            headers + "! ignored\0", headers + "1 garbage\0", headers + "# branch.head other\0",
            headers + "# branch.ab +0 -0\0", headers + "# branch.upstream origin/main\0# branch.ab +-1 -0\0",
            headers + "# branch.upstream origin/main\0# branch.ab +99999999999999999999999 -0\0",
            headers + "2 R. N... 100644 100644 100644 \(hash) \(hash) R100 to\0",
            headers + ordinary("..", path: "unchanged"), headers + ordinary("UU", path: "conflict")]
        for text in bad { #expect(throws: (any Error).self) { try GitStatusParser.parse(Data(text.utf8)) } }
    }

    @Test("Output budgets are enforced before parsing")
    func budget() {
        #expect(throws: GitStatusParseError.oversized) {
            try GitStatusParser.parse(Data(repeating: 0, count: GitStatusParser.maximumBytes + 1))
        }
    }

    @Test("All porcelain unmerged states count only as conflicts")
    func conflictStates() throws {
        for xy in ["DD", "AU", "UD", "UA", "DU", "AA", "UU"] {
            let text = headers + "u \(xy) N... 000000 100644 100644 100644 \(hash) \(hash) \(hash) conflict\0"
            let result = try GitStatusParser.parse(Data(text.utf8))
            #expect(result.conflictCount == 1 && result.changedPathCount == 1)
            #expect(result.stagedCount == 0 && result.unstagedCount == 0)
        }
    }

    @Test("Unknown headers are ignored even if future syntax differs")
    func futureHeaders() throws {
        var bytes = Data((headers + "# future-no-value\0# future-bytes ").utf8)
        bytes.append(contentsOf: [255, 0])
        #expect(try GitStatusParser.parse(bytes).changedPathCount == 0)
    }

    @Test("Duplicate paths and contradictory records fail closed")
    func contradictoryRecords() {
        let bad = [headers + ordinary("M.", path: "same") + "? same\0",
            headers + "? same\0? same\0",
            headers + "2 R. N... 100644 100644 100644 \(hash) \(hash) C100 to\0from\0",
            headers + "# branch.upstream bad branch\0",
            "# branch.oid (initial)\0# branch.head (detached)\0",
            "# branch.oid \(hash)\0# branch.head ../bad\0",
            "# branch.oid \(String(repeating: "a", count: 64))\0# branch.head main\0" + ordinary("M.", path: "mixed-format")]
        for text in bad { #expect(throws: (any Error).self) { try GitStatusParser.parse(Data(text.utf8)) } }
    }

    @Test("Failure and not-checked states never manufacture a snapshot")
    func explicitUnknownStates() throws {
        let reasons: [GitStatusUnavailableReason] = [.executionDisabled, .unsupportedGit, .unsupportedRepository,
            .repositoryChanged, .commandFailed, .invalidOutput, .outputLimit, .timedOut, .cancelled]
        #expect(GitStatusState.notChecked.snapshot == nil)
        for reason in reasons { #expect(GitStatusState.unavailable(reason).snapshot == nil) }
        let snapshot = GitStatusSnapshot(observedAt: Date(timeIntervalSince1970: 100),
            summary: try GitStatusParser.parse(Data(headers.utf8)))
        #expect(GitStatusState.observed(snapshot).snapshot == snapshot)
        #expect(!snapshot.summary.hasReportedChanges)
        let project = ProjectRecord(name: "fixture", path: "/fixture", kind: .repository)
        #expect(project.status == String(localized: "Not checked"))
        #expect(!ProjectCleanupPreview(project: project).isEligible)
    }

}
