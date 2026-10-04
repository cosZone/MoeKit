import Foundation
import Testing
@testable import MoeKit

struct ReleaseVersionTests {
    @Test func numericOrderingAndChannels() throws {
        let versions = try ["0.1.0-preview.2", "0.1.0-preview.7", "0.1.0-preview.10", "0.1.0", "0.2.0-preview.1", "1.0.0"].map { try #require(ReleaseVersion($0)) }
        #expect(versions.shuffled().sorted() == versions)
        #expect(!(versions[0] < versions[0]))
        #expect(ReleaseVersion("9999.9999.9999-preview.999999") != nil)
    }

    @Test(arguments: ["", "v0.1.0", "0.1", "00.1.0", "0.01.0", "0.1.00", "1.0.0-preview.01", "1.0.0-preview.-1", "1.0.0-preview.1.extra", "1.0.0+build", "1.0.0-beta.1", "1.0.0/../../other", "1.0.0-preview.1000000", "10000.0.0", "１.0.0", " 1.0.0", "1.0.0\n"])
    func invalidVersions(_ value: String) { #expect(ReleaseVersion(value) == nil) }

    @Test func installedIdentityIsNeverGuessedFromMarketingOrBuild() {
        #expect(ReleaseVersion.installed(in: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "500"]) == nil)
        #expect(ReleaseVersion.installed(in: ["MoeKitPreviewVersion": "0.1.0-preview.7"])?.description == "0.1.0-preview.7")
        #expect(ReleaseVersion.installed(in: ["MoeKitReleaseVersion": "0.1.0"])?.description == "0.1.0")
        #expect(ReleaseVersion.installed(in: ["MoeKitPreviewVersion": "$(PREVIEW_VERSION)"]) == nil)
    }

    @Test func responseFilteringAndRepositoryBoundNavigation() throws {
        let data = Data("""
        [{"tag_name":"v0.1.0-preview.7","draft":false,"prerelease":true,"html_url":"https://evil.invalid"},
         {"tag_name":"v0.1.0","draft":false,"prerelease":false},
         {"tag_name":"v0.2.0","draft":true,"prerelease":false},
         {"tag_name":"v9.0.0","draft":false,"prerelease":true},
         {"tag_name":"v9.0.0-preview.1","draft":false,"prerelease":false},
         {"tag_name":"v1.0.0/../../evil","draft":false,"prerelease":false}]
        """.utf8)
        let releases = try GitHubReleaseChecker.decode(data)
        #expect(releases.count == 2)
        #expect(releases[0].pageURL.absoluteString == "https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.7")
        #expect(throws: ReleaseCheckError.invalidResponse) { try GitHubReleaseChecker.decode(Data("{}".utf8)) }
        #expect(throws: ReleaseCheckError.tooLarge) { try GitHubReleaseChecker.decode(Data(repeating: 32, count: GitHubReleaseChecker.maximumBytes + 1)) }
    }

    @Test func responseStatusRedirectMimeAndCoverageAreChecked() throws {
        func response(_ status: Int = 200, url: URL = GitHubReleaseChecker.endpoint, headers: [String: String] = ["Content-Type": "application/json"]) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
        }
        try GitHubReleaseChecker.validate(response())
        #expect(throws: ReleaseCheckError.rateLimited) { try GitHubReleaseChecker.validate(response(403)) }
        #expect(throws: ReleaseCheckError.rateLimited) { try GitHubReleaseChecker.validate(response(429)) }
        #expect(throws: ReleaseCheckError.invalidResponse) { try GitHubReleaseChecker.validate(response(302)) }
        #expect(throws: ReleaseCheckError.invalidResponse) { try GitHubReleaseChecker.validate(response(url: URL(string: "https://example.invalid")!)) }
        #expect(throws: ReleaseCheckError.invalidResponse) { try GitHubReleaseChecker.validate(response(headers: ["Content-Type": "text/html"])) }
        #expect(throws: ReleaseCheckError.incomplete) { try GitHubReleaseChecker.validate(response(headers: ["Content-Type": "application/json", "Link": "<https://api.github.com/next>; rel=\"next\""])) }
        #expect(throws: ReleaseCheckError.tooLarge) { try GitHubReleaseChecker.validate(response(headers: ["Content-Type": "application/json", "Content-Length": "1048577"])) }
    }
}

private actor ControlledReleaseChecker: ReleaseChecking {
    private var waits: [CheckedContinuation<[PublishedRelease], any Error>] = []
    private(set) var requests = 0
    func releases() async throws -> [PublishedRelease] {
        requests += 1
        return try await withCheckedThrowingContinuation { waits.append($0) }
    }
    func complete(_ result: Result<[PublishedRelease], any Error>) { waits.removeFirst().resume(with: result) }
}

@MainActor
struct ReleaseCheckStoreTests {
    private func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Controlled update-check operation did not settle")
    }
    private func release(_ text: String) -> PublishedRelease { PublishedRelease(version: ReleaseVersion(text)!) }

    @Test func explicitOnlyRepeatedClicksAndNumericLatest() async {
        let checker = ControlledReleaseChecker()
        let store = ReleaseCheckStore(checker: checker, installedVersion: ReleaseVersion("0.1.0-preview.7"))
        #expect(await checker.requests == 0)
        #expect(store.state == .idle)
        store.check(); store.check()
        await waitFor { await checker.requests == 1 }
        await checker.complete(.success([release("0.1.0-preview.10"), release("0.1.0-preview.2")]))
        await waitFor { !store.isChecking }
        #expect(store.state == .available(release("0.1.0-preview.10")))
        #expect(store.checkedAt != nil)
    }

    @Test func closeCancelReopenAndLateCompletion() async {
        let checker = ControlledReleaseChecker()
        let store = ReleaseCheckStore(checker: checker, installedVersion: ReleaseVersion("0.1.0-preview.7"))
        store.check()
        await waitFor { await checker.requests == 1 }
        store.cancel()
        #expect(store.state == .cancelled)
        store.check()
        await waitFor { await checker.requests == 2 }
        await checker.complete(.success([release("99.0.0")]))
        #expect(store.state == .checking)
        await checker.complete(.success([release("0.1.0-preview.7")]))
        await waitFor { !store.isChecking }
        #expect(store.state == .current(ReleaseVersion("0.1.0-preview.7")!))
    }

    @Test func channelChangeInvalidatesOldResultAndStableExcludesPreviews() async {
        let checker = ControlledReleaseChecker()
        let store = ReleaseCheckStore(checker: checker, installedVersion: ReleaseVersion("0.1.0"))
        #expect(!store.includePreviews)
        store.check()
        await waitFor { await checker.requests == 1 }
        store.includePreviews = true
        #expect(store.state == .idle)
        await checker.complete(.success([release("99.0.0")]))
        store.includePreviews = false
        store.check()
        await waitFor { await checker.requests == 2 }
        await checker.complete(.success([release("99.0.0-preview.1"), release("0.1.0")]))
        await waitFor { !store.isChecking }
        #expect(store.state == .current(ReleaseVersion("0.1.0")!))
    }

    @Test func errorsAndNoReleaseNeverBecomeUpToDate() async {
        let checker = ControlledReleaseChecker()
        let store = ReleaseCheckStore(checker: checker, installedVersion: nil)
        store.check()
        await waitFor { await checker.requests == 1 }
        await checker.complete(.failure(ReleaseCheckError.rateLimited))
        await waitFor { !store.isChecking }
        #expect(store.state == .failed(ReleaseCheckError.rateLimited.message))
        #expect(store.checkedAt == nil)
        store.check()
        await waitFor { await checker.requests == 2 }
        await checker.complete(.success([]))
        await waitFor { !store.isChecking }
        #expect(store.state == .noReleases)
        store.check()
        await waitFor { await checker.requests == 3 }
        await checker.complete(.success([release("0.1.0-preview.7")]))
        await waitFor { !store.isChecking }
        #expect(store.state == .latestForDevelopment(release("0.1.0-preview.7")))
    }
}
