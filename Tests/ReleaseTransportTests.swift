import Foundation
import Testing
@testable import MoeKit

/// Serial fixtures replace URL loading itself; no request reaches a socket.
@Suite(.serialized)
struct ReleaseTransportTests {
    private func checker(_ fixture: ReleaseHTTPFixture) -> GitHubReleaseChecker {
        ReleaseFixtureProtocol.state.configure(fixture)
        return GitHubReleaseChecker(makeConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReleaseFixtureProtocol.self]
            return configuration
        })
    }

    @Test func streamsBoundedResponseWithoutContentLength() async throws {
        let service = checker(.init(body: Data("[{\"tag_name\":\"v0.1.0-preview.10\",\"draft\":false,\"prerelease\":true}]".utf8)))
        let result = try await service.releases()
        #expect(result.first?.version.description == "0.1.0-preview.10")
        #expect(ReleaseFixtureProtocol.state.starts == 1)
    }

    @Test func refusesMissingLengthOversizeWhileStreaming() async {
        let service = checker(.init(body: Data(repeating: 32, count: GitHubReleaseChecker.maximumBytes + 1)))
        await #expect(throws: ReleaseCheckError.tooLarge) { try await service.releases() }
    }

    @Test func refusesRedirectWithoutLoadingAnotherURL() async {
        let service = checker(.init(redirect: true))
        await #expect(throws: (any Error).self) { try await service.releases() }
        #expect(ReleaseFixtureProtocol.state.starts == 1)
        #expect(!ReleaseFixtureProtocol.state.unexpectedURL)
    }

    @Test func cancellationStopsAnOpenResponseStream() async throws {
        let service = checker(.init(body: Data("[".utf8), holdOpen: true))
        let task = Task { try await service.releases() }
        let deadline = ContinuousClock.now + .seconds(5)
        while ReleaseFixtureProtocol.state.starts == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ReleaseFixtureProtocol.state.starts == 1)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled response unexpectedly succeeded") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let stopDeadline = ContinuousClock.now + .seconds(5)
        while ReleaseFixtureProtocol.state.stops == 0 && ContinuousClock.now < stopDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ReleaseFixtureProtocol.state.stops == 1)
    }
}

private struct ReleaseHTTPFixture: Sendable {
    var body = Data()
    var holdOpen = false
    var redirect = false
}

private final class ReleaseHTTPFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var fixture = ReleaseHTTPFixture()
    private var startCount = 0
    private var stopCount = 0
    private var wrongURL = false
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var unexpectedURL: Bool { lock.withLock { wrongURL } }
    func configure(_ value: ReleaseHTTPFixture) {
        lock.withLock { fixture = value; startCount = 0; stopCount = 0; wrongURL = false }
    }
    func start(url: URL?) -> ReleaseHTTPFixture {
        lock.withLock { startCount += 1; wrongURL = url != GitHubReleaseChecker.endpoint; return fixture }
    }
    func stop() { lock.withLock { stopCount += 1 } }
}

private final class ReleaseFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = ReleaseHTTPFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.state.start(url: request.url)
        guard let url = request.url, url == GitHubReleaseChecker.endpoint else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if fixture.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://unexpected.invalid/"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://unexpected.invalid/")!), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        if !fixture.holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.state.stop() }
}
