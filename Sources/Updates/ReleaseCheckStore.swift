import Foundation
import Observation

protocol ReleaseChecking: Sendable {
    func releases() async throws -> [PublishedRelease]
}

enum ReleaseCheckError: Error, Equatable {
    case rateLimited, invalidResponse, tooLarge, incomplete

    var message: String {
        switch self {
        case .rateLimited: String(localized: "GitHub’s request limit was reached. Try again later or open the releases page.")
        case .invalidResponse: String(localized: "GitHub returned an unexpected response. Try again or open the releases page.")
        case .tooLarge, .incomplete: String(localized: "The release list could not be checked completely. Open the releases page to review available versions.")
        }
    }
}

/// Redirects are unnecessary for the fixed public API and are never followed.
private final class ReleaseRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GitHubReleaseChecker: ReleaseChecking {
    static let endpoint = URL(string: "https://api.github.com/repos/cosZone/MoeKit/releases?per_page=100")!
    static let maximumBytes = 1_048_576
    var makeConfiguration: @Sendable () -> URLSessionConfiguration = { .ephemeral }

    func releases() async throws -> [PublishedRelease] {
        let configuration = makeConfiguration()
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ReleaseRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MoeKit-Release-Check", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReleaseCheckError.invalidResponse }
        try Self.validate(http)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw ReleaseCheckError.tooLarge }
            data.append(byte)
        }
        return try Self.decode(data)
    }

    static func validate(_ response: HTTPURLResponse) throws {
        guard response.url == endpoint else { throw ReleaseCheckError.invalidResponse }
        if [403, 429].contains(response.statusCode) { throw ReleaseCheckError.rateLimited }
        guard response.statusCode == 200, response.mimeType == "application/json" else {
            throw ReleaseCheckError.invalidResponse
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw ReleaseCheckError.tooLarge }
        if response.value(forHTTPHeaderField: "Link")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            // Never report “up to date” from a partial history.
            throw ReleaseCheckError.incomplete
        }
    }

    static func decode(_ data: Data) throws -> [PublishedRelease] {
        guard data.count <= maximumBytes else { throw ReleaseCheckError.tooLarge }
        guard let records = try? JSONDecoder().decode([GitHubReleaseRecord].self, from: data), records.count <= 100 else {
            throw ReleaseCheckError.invalidResponse
        }
        return records.compactMap(\.release)
    }
}

enum ReleaseCheckState: Equatable {
    case idle, checking, cancelled
    case available(PublishedRelease)
    case current(ReleaseVersion)
    case latestForDevelopment(PublishedRelease)
    case noReleases
    case failed(String)
}

@MainActor @Observable
final class ReleaseCheckStore {
    let installedVersion: ReleaseVersion?
    private(set) var state: ReleaseCheckState = .idle
    private(set) var checkedAt: Date?
    var includePreviews: Bool { didSet { if includePreviews != oldValue { cancel(); state = .idle; checkedAt = nil } } }
    @ObservationIgnored private let checker: any ReleaseChecking
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    init(checker: any ReleaseChecking = GitHubReleaseChecker(),
         installedVersion: ReleaseVersion? = ReleaseVersion.installed(in: Bundle.main.infoDictionary)) {
        self.checker = checker
        self.installedVersion = installedVersion
        includePreviews = installedVersion == nil || installedVersion?.preview != nil
    }

    var isChecking: Bool { state == .checking }

    func check() {
        guard !isChecking else { return }
        let id = UUID()
        let includePreviews = includePreviews
        requestID = id
        checkedAt = nil
        state = .checking
        task = Task { [weak self, checker] in
            do {
                let releases = try await checker.releases()
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.checkedAt = Date()
                let latest = releases.filter { includePreviews || $0.version.preview == nil }
                    .max { $0.version < $1.version }
                if let latest {
                    if let installed = self.installedVersion {
                        self.state = latest.version > installed ? .available(latest) : .current(installed)
                    } else {
                        self.state = .latestForDevelopment(latest)
                    }
                } else { self.state = .noReleases }
                self.task = nil; self.requestID = nil
            } catch {
                guard let self, self.requestID == id else { return }
                self.state = error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? .cancelled : .failed((error as? ReleaseCheckError)?.message ?? String(localized: "Could not reach GitHub. Check your connection and try again."))
                self.task = nil; self.requestID = nil
            }
        }
    }

    func cancel() {
        requestID = nil
        task?.cancel(); task = nil
        if isChecking { state = .cancelled }
    }
}
