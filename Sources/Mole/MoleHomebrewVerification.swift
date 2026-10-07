import zlib
import CryptoKit
import Foundation

/// Proof of bytes, not permission to run them. The caller must bind this evidence
/// to a fresh descriptor/identity check and the user's separate analysis consent.
struct MoleHomebrewEvidence: Equatable, Sendable {
    let version: String
    let architecture: String
    let byteCount: Int
    let sha256: String
    let bottleSHA256: String
    let bottleTag: String
    let sourceURL: URL
    let checkedAt: Date
    var bottleURL: URL { sourceURL }
}

protocol MoleHomebrewVerifying: Sendable {
    func verify(expectedVersion: String, architecture: String,
                installedByteCount: Int, installedSHA256: String) async throws -> MoleHomebrewEvidence
}

enum MoleHomebrewVerificationFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidInstallationMetadata
    case currentVersionMismatch(currentVersion: String)
    case noMatchingArchitectureBottle
    case installedBytesMismatch
    case unavailable
    case invalidOfficialMetadata
    case unexpectedSource
    case bottleChecksumMismatch
    case malformedArchive
    case resourceLimit
    case timeLimit

    var errorDescription: String? {
        switch self {
        case .invalidInstallationMetadata:
            String(localized: "This installation's reported version, architecture or file information cannot be verified. Nothing was run.")
        case .currentVersionMismatch(let currentVersion):
            String(localized: "Homebrew currently publishes Mole \(currentVersion). This installation reports a different version, so the current bottle cannot verify it.")
        case .noMatchingArchitectureBottle:
            String(localized: "Homebrew does not currently publish a supported Mole bottle for this app's architecture. Nothing was run.")
        case .installedBytesMismatch:
            String(localized: "The installed analyzer differs from every checked official Homebrew bottle. It may be a source build or a modified file. It has not been approved for analysis.")
        case .unavailable:
            String(localized: "The official Homebrew verification service could not be reached or did not return a usable response. Try verification again later.")
        case .invalidOfficialMetadata:
            String(localized: "Homebrew's response did not identify a valid official Mole bottle. The installation remains unverified.")
        case .unexpectedSource:
            String(localized: "Verification encountered an unexpected address or redirect and stopped. The installation remains unverified.")
        case .bottleChecksumMismatch:
            String(localized: "The downloaded bottle did not match Homebrew's published checksum. It was rejected; this does not establish whether the installed file is modified.")
        case .malformedArchive:
            String(localized: "The official bottle could not be safely inspected as a complete archive with one regular analyzer file. The installation remains unverified.")
        case .resourceLimit:
            String(localized: "Verification exceeded its download, archive or file limits and stopped. The installation remains unverified.")
        case .timeLimit:
            String(localized: "Verification reached its time limit and stopped. Try again later.")
        }
    }
}

struct MoleHomebrewHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
    /// Includes the original request URL and every followed redirect.
    let urlChain: [URL]
}

/// Test seam: ordinary tests supply only in-memory responses. The production
/// implementation bounds bytes *while receiving*, not after an unbounded read.
protocol MoleHomebrewTransport: Sendable {
    func get(_ url: URL, bearerToken: String?, maximumBytes: Int,
             timeout: TimeInterval) async throws -> MoleHomebrewHTTPResponse
}

/// Opt-in only. Initializing this actor makes no request, reads no installation,
/// and stores no proof on disk. Only the fixed public formula and bottle services
/// receive requests; local paths, receipts, sizes and hashes are never uploaded.
actor MoleHomebrewVerifier: MoleHomebrewVerifying {
    static let formulaURL = URL(string: "https://formulae.brew.sh/api/formula/mole.json")!
    static let tokenURL = URL(string: "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/mole:pull")!
    static let maximumMetadataBytes = 1_048_576
    static let maximumBottleBytes = 32 * 1_048_576
    static let maximumBottles = 8
    static let maximumAnalyzerBytes = 8 * 1_048_576
    static let totalTimeLimit: Duration = .seconds(120)

    private let transport: any MoleHomebrewTransport
    init(transport: any MoleHomebrewTransport = MoleHomebrewURLSessionTransport()) {
        self.transport = transport
    }

    func verify(expectedVersion: String, architecture: String,
                installedByteCount: Int, installedSHA256: String) async throws -> MoleHomebrewEvidence {
        try Task.checkCancellation()
        guard Self.validKegVersion(expectedVersion), ["arm64", "x86_64"].contains(architecture),
              (1...Self.maximumAnalyzerBytes).contains(installedByteCount),
              Self.validSHA256(installedSHA256) else {
            throw MoleHomebrewVerificationFailure.invalidInstallationMetadata
        }
        let deadline = ContinuousClock.now.advanced(by: Self.totalTimeLimit)
        let metadata = try await request(Self.formulaURL, maximumBytes: Self.maximumMetadataBytes, deadline: deadline)
        guard metadata.statusCode == 200 else { throw MoleHomebrewVerificationFailure.unavailable }
        let formula: Formula
        do { formula = try JSONDecoder().decode(Formula.self, from: metadata.body) }
        catch { throw MoleHomebrewVerificationFailure.invalidOfficialMetadata }
        guard formula.name == "mole", formula.full_name == "mole", formula.tap == "homebrew/core",
              Self.validStableVersion(formula.versions.stable), (0...10_000).contains(formula.revision),
              formula.versions.bottle, formula.bottle.stable.root_url == "https://ghcr.io/v2/homebrew/core",
              formula.bottle.stable.files.count <= 32 else {
            throw MoleHomebrewVerificationFailure.invalidOfficialMetadata
        }
        let version = formula.versions.stable + (formula.revision == 0 ? "" : "_\(formula.revision)")
        guard version == expectedVersion else {
            throw MoleHomebrewVerificationFailure.currentVersionMismatch(currentVersion: version)
        }
        let bottles = formula.bottle.stable.files.filter { Self.matches(tag: $0.key, architecture: architecture) }
            .sorted { $0.key < $1.key }
        guard !bottles.isEmpty else { throw MoleHomebrewVerificationFailure.noMatchingArchitectureBottle }
        guard bottles.count <= Self.maximumBottles else { throw MoleHomebrewVerificationFailure.resourceLimit }
        // Validate *all* selected source declarations before the first download.
        for (_, bottle) in bottles {
            guard Self.validSHA256(bottle.sha256), bottle.url == Self.bottleURL(bottle.sha256).absoluteString else {
                throw MoleHomebrewVerificationFailure.invalidOfficialMetadata
            }
        }
        var anonymousToken: String?
        var seenDigests = Set<String>()
        for (tag, bottle) in bottles {
            try Self.checkpoint(deadline)
            guard seenDigests.insert(bottle.sha256).inserted else { continue }
            let url = Self.bottleURL(bottle.sha256)
            var response = try await request(url, bearerToken: anonymousToken,
                                             maximumBytes: Self.maximumBottleBytes, deadline: deadline)
            if response.statusCode == 401 && anonymousToken == nil {
                // Never follow a server-provided authentication realm, use a
                // user's GitHub session, or consult Keychain/credential files.
                let authorization = try await request(Self.tokenURL, maximumBytes: 32_768, deadline: deadline)
                guard authorization.statusCode == 200,
                      let token = try? JSONDecoder().decode(Token.self, from: authorization.body).token,
                      !token.isEmpty, token.utf8.count <= 8192,
                      token.utf8.allSatisfy({ (33...126).contains($0) }) else {
                    throw MoleHomebrewVerificationFailure.unavailable
                }
                anonymousToken = token
                response = try await request(url, bearerToken: token,
                                             maximumBytes: Self.maximumBottleBytes, deadline: deadline)
            }
            guard response.statusCode == 200 else { throw MoleHomebrewVerificationFailure.unavailable }
            try Self.checkpoint(deadline)
            guard Self.digest(response.body) == bottle.sha256 else {
                throw MoleHomebrewVerificationFailure.bottleChecksumMismatch
            }
            let member = try MoleHomebrewArchive.analyzer(in: response.body, version: version, deadline: deadline)
            if member.byteCount == installedByteCount && member.sha256 == installedSHA256 {
                try Self.checkpoint(deadline)
                return MoleHomebrewEvidence(version: version, architecture: architecture,
                    byteCount: member.byteCount, sha256: member.sha256, bottleSHA256: bottle.sha256,
                    bottleTag: tag, sourceURL: url, checkedAt: Date())
            }
        }
        throw MoleHomebrewVerificationFailure.installedBytesMismatch
    }

    private func request(_ url: URL, bearerToken: String? = nil, maximumBytes: Int,
                         deadline: ContinuousClock.Instant) async throws -> MoleHomebrewHTTPResponse {
        try Self.checkpoint(deadline)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        let response: MoleHomebrewHTTPResponse
        do {
            response = try await transport.get(url, bearerToken: bearerToken,
                maximumBytes: maximumBytes, timeout: min(45, seconds))
        } catch is CancellationError { throw CancellationError() }
        catch let failure as MoleHomebrewVerificationFailure { throw failure }
        catch {
            try Self.checkpoint(deadline)
            throw MoleHomebrewVerificationFailure.unavailable
        }
        try Self.checkpoint(deadline)
        guard response.body.count <= maximumBytes else { throw MoleHomebrewVerificationFailure.resourceLimit }
        guard MoleHomebrewNetworkPolicy.validChain(response.urlChain, original: url) else {
            throw MoleHomebrewVerificationFailure.unexpectedSource
        }
        return response
    }

    static func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MoleHomebrewVerificationFailure.timeLimit }
    }
    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validStableVersion(_ value: String) -> Bool {
        guard value.utf8.count <= 48 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(components.count) && components.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 10 && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
    static func validKegVersion(_ value: String) -> Bool {
        let parts = value.split(separator: "_", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), validStableVersion(String(parts[0])) else { return false }
        return parts.count == 1 || (!parts[1].isEmpty && parts[1].utf8.count <= 5 && parts[1].utf8.allSatisfy { (48...57).contains($0) })
    }
    static func bottleURL(_ sha256: String) -> URL {
        URL(string: "https://ghcr.io/v2/homebrew/core/mole/blobs/sha256:" + sha256)!
    }
    static func matches(tag: String, architecture: String) -> Bool {
        // Homebrew's unprefixed macOS tags are Intel; Linux and future unknown
        // platform tags must never silently become macOS architecture evidence.
        let macOS = Set(["catalina", "big_sur", "monterey", "ventura", "sonoma", "sequoia", "tahoe", "golden_gate"])
        if architecture == "arm64" { return tag.hasPrefix("arm64_") && macOS.contains(String(tag.dropFirst(6))) }
        return architecture == "x86_64" && macOS.contains(tag)
    }
    private struct Token: Decodable { let token: String }
    private struct Formula: Decodable {
        let name: String
        let full_name: String
        let tap: String
        let revision: Int
        let versions: Versions
        let bottle: Bottles
        struct Versions: Decodable { let stable: String; let bottle: Bool }
        struct Bottles: Decodable { let stable: Stable }
        struct Stable: Decodable { let root_url: String; let files: [String: Bottle] }
        struct Bottle: Decodable { let url: String; let sha256: String }
    }
}

/// Only a single GHCR-to-GitHub-packages CDN hop is supported, with the public
/// token stripped. Formula/token endpoints cannot redirect. No wildcard hosts.
enum MoleHomebrewNetworkPolicy {
    static func validHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port == nil || url.port == 443) &&
            url.user == nil && url.password == nil && url.fragment == nil
    }
    static func isBottle(_ url: URL) -> Bool {
        guard validHTTPS(url), url.host == "ghcr.io", url.query == nil else { return false }
        let prefix = "https://ghcr.io/v2/homebrew/core/mole/blobs/sha256:"
        return url.absoluteString.hasPrefix(prefix) &&
            MoleHomebrewVerifier.validSHA256(String(url.absoluteString.dropFirst(prefix.count)))
    }
    static func validOriginal(_ url: URL) -> Bool {
        url == MoleHomebrewVerifier.formulaURL || url == MoleHomebrewVerifier.tokenURL || isBottle(url)
    }
    static func validChain(_ chain: [URL], original: URL) -> Bool {
        guard validOriginal(original), chain.first == original else { return false }
        if chain.count == 1 { return true }
        return chain.count == 2 && isBottle(original) && validHTTPS(chain[1]) &&
            chain[1].host == "pkg-containers.githubusercontent.com"
    }
}

struct MoleHomebrewURLSessionTransport: MoleHomebrewTransport {
    func get(_ url: URL, bearerToken: String?, maximumBytes: Int,
             timeout: TimeInterval) async throws -> MoleHomebrewHTTPResponse {
        guard MoleHomebrewNetworkPolicy.validOriginal(url), maximumBytes > 0,
              maximumBytes <= MoleHomebrewVerifier.maximumBottleBytes, timeout > 0,
              bearerToken == nil || MoleHomebrewNetworkPolicy.isBottle(url) else {
            throw MoleHomebrewVerificationFailure.unexpectedSource
        }
        let transfer = MoleHomebrewTransfer(url: url, maximumBytes: maximumBytes, timeout: timeout, token: bearerToken)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await transfer.run()
        } onCancel: { transfer.cancel() }
    }
}

/// Delegate state is exclusively protected by lock. Completion is single-shot,
/// including cancellation before a continuation or session has been installed.
private final class MoleHomebrewTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let maximumBytes: Int
    private let timeout: TimeInterval
    private let token: String?
    private var continuation: CheckedContinuation<MoleHomebrewHTTPResponse, any Error>?
    private var terminal: Result<MoleHomebrewHTTPResponse, any Error>?
    private var session: URLSession?
    private var body = Data()
    private var chain: [URL]
    private var statusCode: Int?

    init(url: URL, maximumBytes: Int, timeout: TimeInterval, token: String?) {
        self.url = url; self.maximumBytes = maximumBytes; self.timeout = timeout; self.token = token
        chain = [url]
    }
    func run() async throws -> MoleHomebrewHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminal { lock.unlock(); continuation.resume(with: terminal); return }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = min(20, timeout)
            configuration.timeoutIntervalForResource = timeout
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("MoeKit-Mole-Verification", forHTTPHeaderField: "User-Agent")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            let task = session.dataTask(with: request)
            lock.unlock()
            task.resume()
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<MoleHomebrewHTTPResponse, any Error>) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = result
        let continuation = self.continuation, session = self.session
        self.continuation = nil; self.session = nil
        body = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let expected = chain.last
        let cancelled = terminal != nil
        lock.unlock()
        guard !cancelled, let http = response as? HTTPURLResponse, http.url == expected else {
            completionHandler(.cancel)
            finish(.failure(MoleHomebrewVerificationFailure.unexpectedSource)); return
        }
        guard http.expectedContentLength <= Int64(maximumBytes),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            completionHandler(.cancel)
            finish(.failure(MoleHomebrewVerificationFailure.resourceLimit)); return
        }
        lock.lock(); statusCode = http.statusCode; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        guard data.count <= maximumBytes - body.count else {
            lock.unlock(); finish(.failure(MoleHomebrewVerificationFailure.resourceLimit)); return
        }
        body.append(data)
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let result = statusCode.map { MoleHomebrewHTTPResponse(statusCode: $0, body: body, urlChain: chain) }
        lock.unlock()
        if let result { finish(.success(result)) }
        else { finish(.failure(MoleHomebrewVerificationFailure.unavailable)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        let next = request.url.map { chain + [$0] }
        guard terminal == nil, let next, MoleHomebrewNetworkPolicy.validChain(next, original: url) else {
            lock.unlock(); completionHandler(nil)
            finish(.failure(MoleHomebrewVerificationFailure.unexpectedSource)); return
        }
        chain = next
        lock.unlock()
        // Build a fresh request: do not forward Authorization or cookies to CDN.
        var redirected = URLRequest(url: next[1])
        redirected.httpMethod = "GET"
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(redirected)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

struct MoleHomebrewArchiveMember: Equatable, Sendable {
    let byteCount: Int
    let sha256: String
}

/// Original bounded gzip/ustar reader. SDK zlib decodes raw RFC 1951 DEFLATE
/// with exact consumed-input accounting; this reader separately validates
/// RFC 1952 framing and CRC. No package or downloaded decoder is used.
/// https://zlib.net/manual.html (inflate / inflateInit2)
/// https://www.rfc-editor.org/rfc/rfc1952
/// No extraction, subprocess, permissions,
/// executable mapping, or code-signature normalization. Only the exact regular
/// analyzer member is hashed. Other contents never leave the streaming buffer.
enum MoleHomebrewArchive {
    static let maximumUncompressedBytes = 64 * 1_048_576
    static let maximumMembers = 2048
    static let maximumHeaderBytes = 4096

    static func analyzer(in gzip: Data, version: String,
                         deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(30)),
                         maximumOutput: Int = MoleHomebrewArchive.maximumUncompressedBytes,
                         maximumMembers: Int = MoleHomebrewArchive.maximumMembers) throws -> MoleHomebrewArchiveMember {
        guard MoleHomebrewVerifier.validKegVersion(version), gzip.count >= 20,
              gzip.count <= MoleHomebrewVerifier.maximumBottleBytes,
              maximumOutput > 0, maximumOutput <= maximumUncompressedBytes,
              maximumMembers > 0, maximumMembers <= Self.maximumMembers else {
            throw MoleHomebrewVerificationFailure.malformedArchive
        }
        return try gzip.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: UInt8.self)
            let payloadStart = try gzipHeader(input)
            let footer = input.count - 8
            guard payloadStart < footer else { throw MoleHomebrewVerificationFailure.malformedArchive }
            var crc = CRC32()
            var total = 0
            var tar = TarReader(version: version, maximumMembers: maximumMembers)
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
            defer { output.deallocate() }
            let compressedCount = footer - payloadStart
            // zlib retains this address in its internal state. A separately
            // allocated, initialized stream stays stable across every C call.
            let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            stream.initialize(to: z_stream())
            defer {
                stream.deinitialize(count: 1)
                stream.deallocate()
            }
            // zlib's legacy C signature is mutable; inflate never writes input.
            stream.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.advanced(by: payloadStart))
            stream.pointee.avail_in = uInt(compressedCount) // bounded to 32 MiB above
            guard inflateInit2_(stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw MoleHomebrewVerificationFailure.malformedArchive
            }
            // LIFO defers end zlib before destroying or freeing the stream.
            defer { _ = inflateEnd(stream) }
            while true {
                try MoleHomebrewVerifier.checkpoint(deadline)
                stream.pointee.next_out = output; stream.pointee.avail_out = 65_536
                let previousInput = stream.pointee.total_in
                let status = inflate(stream, Z_NO_FLUSH)
                let count = 65_536 - Int(stream.pointee.avail_out)
                guard count <= maximumOutput - total else { throw MoleHomebrewVerificationFailure.resourceLimit }
                total += count
                let bytes = UnsafeBufferPointer(start: output, count: count)
                crc.update(bytes)
                try tar.consume(bytes)
                if status == Z_STREAM_END {
                    // A decoder may buffer beyond the final DEFLATE block.
                    // zlib returns unread whole bytes in avail_in and counts
                    // actual consumed bytes in total_in. Never reset/continue
                    // into another member or accept bytes before the trailer.
                    guard stream.pointee.avail_in == 0, stream.pointee.total_in == uLong(compressedCount),
                          stream.pointee.total_out == uLong(total) else {
                        throw MoleHomebrewVerificationFailure.malformedArchive
                    }
                    break
                }
                // All input is already supplied. No progress means truncation;
                // Z_BUF_ERROR cannot be repaired by fetching more input here.
                guard status == Z_OK, count > 0 || stream.pointee.total_in > previousInput else {
                    throw MoleHomebrewVerificationFailure.malformedArchive
                }
            }
            guard crc.value == littleEndian32(input, footer), UInt32(total) == littleEndian32(input, footer + 4) else {
                throw MoleHomebrewVerificationFailure.malformedArchive
            }
            try MoleHomebrewVerifier.checkpoint(deadline)
            return try tar.finish()
        }
    }

    private static func gzipHeader(_ bytes: UnsafeBufferPointer<UInt8>) throws -> Int {
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8, bytes[3] & 0xe0 == 0 else {
            throw MoleHomebrewVerificationFailure.malformedArchive
        }
        let limit = min(bytes.count - 8, maximumHeaderBytes)
        var cursor = 10
        func advance(_ count: Int) throws {
            guard count >= 0, count <= limit - cursor else { throw MoleHomebrewVerificationFailure.malformedArchive }
            cursor += count
        }
        if bytes[3] & 4 != 0 {
            try advance(2)
            let extra = Int(bytes[cursor - 2]) | Int(bytes[cursor - 1]) << 8
            try advance(extra)
        }
        for flag in [UInt8(8), 16] where bytes[3] & flag != 0 {
            while true {
                try advance(1)
                if bytes[cursor - 1] == 0 { break }
            }
        }
        if bytes[3] & 2 != 0 {
            var crc = CRC32()
            crc.update(UnsafeBufferPointer(rebasing: bytes[0..<cursor]))
            try advance(2)
            guard UInt16(truncatingIfNeeded: crc.value) == (UInt16(bytes[cursor - 2]) | UInt16(bytes[cursor - 1]) << 8) else {
                throw MoleHomebrewVerificationFailure.malformedArchive
            }
        }
        return cursor
    }
    private static func littleEndian32(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    private struct CRC32 {
        private static let table: [UInt32] = (0..<256).map { value in
            var crc = UInt32(value)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            return crc
        }
        private var crc: UInt32 = 0xffffffff
        var value: UInt32 { crc ^ 0xffffffff }
        mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
            for byte in bytes { crc = Self.table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        }
    }

    private struct TarReader {
        let root: String
        let target: String
        let maximumMembers: Int
        private var header: [UInt8] = []
        private var remaining = 0
        private var padding = 0
        private var hashing = false
        private var hasher = SHA256()
        private var targetSize: Int?
        private var names = Set<String>()
        private var zeroBlocks = 0
        private var totalBytes = 0

        init(version: String, maximumMembers: Int) {
            root = "mole/\(version)"
            target = "mole/\(version)/libexec/bin/analyze-go"
            self.maximumMembers = maximumMembers
            header.reserveCapacity(512)
        }
        mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) throws {
            totalBytes += bytes.count
            var offset = 0
            while offset < bytes.count {
                if remaining > 0 {
                    let count = min(remaining, bytes.count - offset)
                    if hashing { hasher.update(bufferPointer: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: bytes[offset..<(offset + count)]))) }
                    remaining -= count; offset += count
                } else if padding > 0 {
                    let count = min(padding, bytes.count - offset)
                    guard bytes[offset..<(offset + count)].allSatisfy({ $0 == 0 }) else {
                        throw MoleHomebrewVerificationFailure.malformedArchive
                    }
                    padding -= count; offset += count
                } else {
                    let count = min(512 - header.count, bytes.count - offset)
                    header.append(contentsOf: bytes[offset..<(offset + count)])
                    offset += count
                    if header.count == 512 {
                        try readHeader()
                        header.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
        mutating func readHeader() throws {
            if header.allSatisfy({ $0 == 0 }) { zeroBlocks += 1; return }
            guard zeroBlocks == 0 else { throw MoleHomebrewVerificationFailure.malformedArchive }
            let checksum = try octal(148..<156)
            let actual = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            guard checksum == actual, Array(header[257..<265]) == Array("ustar\u{0}00".utf8) else {
                throw MoleHomebrewVerificationFailure.malformedArchive
            }
            let type = header[156]
            // Reject all PAX/GNU/sparse/long-name overrides. Official wrappers
            // may be unrelated symlinks; they are never followed or extracted.
            guard [UInt8(0), 48, 50, 53].contains(type) else { throw MoleHomebrewVerificationFailure.malformedArchive }
            let name = try string(0..<100), prefix = try string(345..<500)
            var path = prefix.isEmpty ? name : prefix + "/" + name
            if type == 53 && path.hasSuffix("/") { path.removeLast() }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= 512, !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  path == root || path.hasPrefix(root + "/"), names.insert(path).inserted else {
                throw MoleHomebrewVerificationFailure.malformedArchive
            }
            guard names.count <= maximumMembers else { throw MoleHomebrewVerificationFailure.resourceLimit }
            let size = try octal(124..<136)
            guard size <= MoleHomebrewArchive.maximumUncompressedBytes else { throw MoleHomebrewVerificationFailure.resourceLimit }
            let isRegular = type == 0 || type == 48
            guard isRegular || size == 0 else { throw MoleHomebrewVerificationFailure.malformedArchive }
            // An ancestor cannot alias another member or regular file.
            if target.hasPrefix(path + "/") && type != 53 { throw MoleHomebrewVerificationFailure.malformedArchive }
            hashing = path == target
            if hashing {
                let mode = try octal(100..<108)
                guard isRegular, targetSize == nil, size > 0,
                      size <= MoleHomebrewVerifier.maximumAnalyzerBytes, mode & 0o111 != 0, try string(157..<257).isEmpty else {
                    throw MoleHomebrewVerificationFailure.malformedArchive
                }
                targetSize = size
            }
            remaining = size
            padding = (512 - size % 512) % 512
        }
        mutating func finish() throws -> MoleHomebrewArchiveMember {
            guard remaining == 0, padding == 0, header.isEmpty, zeroBlocks >= 2,
                  totalBytes % 512 == 0, let targetSize else {
                throw MoleHomebrewVerificationFailure.malformedArchive
            }
            return MoleHomebrewArchiveMember(byteCount: targetSize,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
        private func string(_ range: Range<Int>) throws -> String {
            let bytes = header[range]
            let end = bytes.firstIndex(of: 0) ?? range.upperBound
            guard header[end..<range.upperBound].allSatisfy({ $0 == 0 }),
                  let value = String(bytes: header[range.lowerBound..<end], encoding: .utf8),
                  value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else {
                throw MoleHomebrewVerificationFailure.malformedArchive
            }
            return value
        }
        private func octal(_ range: Range<Int>) throws -> Int {
            let bytes = Array(header[range])
            let digits = bytes.drop(while: { $0 == 32 }).prefix(while: { (48...55).contains($0) })
            guard !digits.isEmpty else { throw MoleHomebrewVerificationFailure.malformedArchive }
            let start = bytes.firstIndex(where: { $0 != 32 })!
            guard bytes.dropFirst(start + digits.count).allSatisfy({ $0 == 0 || $0 == 32 }) else {
                throw MoleHomebrewVerificationFailure.malformedArchive
            }
            var value = 0
            for digit in digits {
                guard value <= (Int.max - 7) / 8 else { throw MoleHomebrewVerificationFailure.resourceLimit }
                value = value * 8 + Int(digit - 48)
            }
            return value
        }
    }
}
