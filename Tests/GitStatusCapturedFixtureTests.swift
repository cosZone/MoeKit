import Foundation
import Testing
@testable import MoeKit

// Captured from official /usr/bin/git in unique temporary synthetic repositories.
// Generator used git version 2.47.3; no subprocess runs in the app or these tests.
struct GitStatusCapturedFixtureTests {
    @Test func unborn() throws {
        let bytes = try #require(Data(base64Encoded: "IyBicmFuY2gub2lkIChpbml0aWFsKQAjIGJyYW5jaC5oZWFkIG1haW4APyBmaXJzdAA="))
        let result = try GitStatusParser.parse(bytes)
        #expect(result.stagedCount == 0)
        #expect(result.unstagedCount == 0)
        #expect(result.untrackedCount == 1)
        #expect(result.conflictCount == 0)
        #expect(result.changedPathCount == 1)
        #expect(result.ahead == nil)
        #expect(result.behind == nil)
    }

    @Test func noChanges() throws {
        let bytes = try #require(Data(base64Encoded: "IyBicmFuY2gub2lkIGYyNjNhNjc3OTM2NDU4ZGYxOTY5ZGI0MzliYmE5NWFmZWRlZTQ0MmEAIyBicmFuY2guaGVhZCBtYWluAA=="))
        let result = try GitStatusParser.parse(bytes)
        #expect(result.stagedCount == 0)
        #expect(result.unstagedCount == 0)
        #expect(result.untrackedCount == 0)
        #expect(result.conflictCount == 0)
        #expect(result.changedPathCount == 0)
        #expect(result.ahead == nil)
        #expect(result.behind == nil)
    }

    @Test func bothAndUntracked() throws {
        let bytes = try #require(Data(base64Encoded: "IyBicmFuY2gub2lkIGYyNjNhNjc3OTM2NDU4ZGYxOTY5ZGI0MzliYmE5NWFmZWRlZTQ0MmEAIyBicmFuY2guaGVhZCBtYWluADEgTU0gTi4uLiAxMDA2NDQgMTAwNjQ0IDEwMDY0NCA1NjI2YWJmMGY3MmU1OGQ3YTE1MzM2OGJhNTdkYjRjNjczYzBlMTcxIGY3MTllZmQ0MzBkNTJiY2ZjODU2NmE0M2IyZWI2NTU2ODhkMzg4NzEgZmlyc3QAPyBuZXcKd2l0aCBzcGFjZXMA"))
        let result = try GitStatusParser.parse(bytes)
        #expect(result.stagedCount == 1)
        #expect(result.unstagedCount == 1)
        #expect(result.untrackedCount == 1)
        #expect(result.conflictCount == 0)
        #expect(result.changedPathCount == 2)
        #expect(result.ahead == nil)
        #expect(result.behind == nil)
    }

    @Test func renamed() throws {
        let bytes = try #require(Data(base64Encoded: "IyBicmFuY2gub2lkIGU0OWMxNTUyNGJhMzc0YTc3NzM2YWQ2NTQ1YzcxYmRkMDBiNDA3MzcAIyBicmFuY2guaGVhZCBtYWluADIgUi4gTi4uLiAxMDA2NDQgMTAwNjQ0IDEwMDY0NCAyYmRmNjdhYmIxNjNhNGZmYjJkN2YzZjA4ODBjOWZlNTA2OGNlNzgyIDJiZGY2N2FiYjE2M2E0ZmZiMmQ3ZjNmMDg4MGM5ZmU1MDY4Y2U3ODIgUjEwMCByZW5hbWVkAGZpcnN0AA=="))
        let result = try GitStatusParser.parse(bytes)
        #expect(result.stagedCount == 1)
        #expect(result.unstagedCount == 0)
        #expect(result.untrackedCount == 0)
        #expect(result.conflictCount == 0)
        #expect(result.changedPathCount == 1)
        #expect(result.ahead == nil)
        #expect(result.behind == nil)
    }

    @Test func detached() throws {
        let bytes = try #require(Data(base64Encoded: "IyBicmFuY2gub2lkIGJiNWZkN2FlYzdhODBkMDlhNmRjNDc0MmRiNGNlZTY5ZTdhYzQ3ZDAAIyBicmFuY2guaGVhZCAoZGV0YWNoZWQpAA=="))
        let result = try GitStatusParser.parse(bytes)
        #expect(result.stagedCount == 0)
        #expect(result.unstagedCount == 0)
        #expect(result.untrackedCount == 0)
        #expect(result.conflictCount == 0)
        #expect(result.changedPathCount == 0)
        #expect(result.ahead == nil)
        #expect(result.behind == nil)
    }

    @Test func conflicted() throws {
        let bytes = try #require(Data(base64Encoded: "IyBicmFuY2gub2lkIDYzODZhMTgzYjk4MjI4ZmYyNDNmYzFiZTZjMWJkNjJmY2I3ZjFmNzAAIyBicmFuY2guaGVhZCBtYWluAHUgVVUgTi4uLiAxMDA2NDQgMTAwNjQ0IDEwMDY0NCAxMDA2NDQgZGY5NjdiOTZhNTc5ZTQ1YTE4YjgyNTE3MzJkMTY4MDRiMmU1NmE1NSBiYTI5MDZkMDY2NmNmNzI2YzdlYWFkZDJjZDNkYjYxNWRlZGZkZjNhIGU0NWM5YzI2NjZkNDRlMDMyN2MxZjljMjM5YTc0YzUwODMzNjA1M2UgY29uZmxpY3QA"))
        let result = try GitStatusParser.parse(bytes)
        #expect(result.stagedCount == 0)
        #expect(result.unstagedCount == 0)
        #expect(result.untrackedCount == 0)
        #expect(result.conflictCount == 1)
        #expect(result.changedPathCount == 1)
        #expect(result.ahead == nil)
        #expect(result.behind == nil)
    }

    @Test func divergedLocally() throws {
        let bytes = try #require(Data(base64Encoded: "IyBicmFuY2gub2lkIDYzODZhMTgzYjk4MjI4ZmYyNDNmYzFiZTZjMWJkNjJmY2I3ZjFmNzAAIyBicmFuY2guaGVhZCBtYWluACMgYnJhbmNoLnVwc3RyZWFtIG9yaWdpbi9tYWluACMgYnJhbmNoLmFiICsxIC0xAA=="))
        let result = try GitStatusParser.parse(bytes)
        #expect(result.stagedCount == 0)
        #expect(result.unstagedCount == 0)
        #expect(result.untrackedCount == 0)
        #expect(result.conflictCount == 0)
        #expect(result.changedPathCount == 0)
        #expect(result.ahead == 1)
        #expect(result.behind == 1)
    }

    @Test func sha256() throws {
        let bytes = try #require(Data(base64Encoded: "IyBicmFuY2gub2lkIDBiMzFmMTc2OTUyMGM0NTdmOWZhMWJkODlhZDIyNTBlMzczNTM1MmJhZjlmMjE3ZjlmOGI0ZjhkZTEyNzZiMjMAIyBicmFuY2guaGVhZCBtYWluADEgLk0gTi4uLiAxMDA2NDQgMTAwNjQ0IDEwMDY0NCA0Mzc2MTNmMjAwMGQxNDg4MjExM2E4Y2VlYjVlNjg1NzI1ODllZGFjMjkyMzBjOWZlY2QwOWQ2ODI2MTJjNGEzIDQzNzYxM2YyMDAwZDE0ODgyMTEzYThjZWViNWU2ODU3MjU4OWVkYWMyOTIzMGM5ZmVjZDA5ZDY4MjYxMmM0YTMgZmlyc3QA"))
        let result = try GitStatusParser.parse(bytes)
        #expect(result.stagedCount == 0)
        #expect(result.unstagedCount == 1)
        #expect(result.untrackedCount == 0)
        #expect(result.conflictCount == 0)
        #expect(result.changedPathCount == 1)
        #expect(result.ahead == nil)
        #expect(result.behind == nil)
    }

}
