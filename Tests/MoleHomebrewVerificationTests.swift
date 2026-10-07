import CryptoKit
import Foundation
import Testing
@testable import MoeKit

@Suite("Opt-in official Homebrew Mole byte verification")
struct MoleHomebrewVerificationTests {
    private let version = "1.58.0"
    private let analyzer = Data("synthetic analyzer, never execute".utf8)

    @Test("The exact installed bytes gain versioned bottle evidence, without uploading local metadata")
    func exactBytes() async throws {
        let bottle = gzip(tar([member(analyzer)]))
        let transport = FixtureTransport([reply(metadata(["arm64_sequoia": bottle])), reply(bottle)])
        let verifier = MoleHomebrewVerifier(transport: transport)
        #expect(await transport.requests.isEmpty)
        let evidence = try await verifier.verify(expectedVersion: version, architecture: "arm64",
            installedByteCount: analyzer.count, installedSHA256: hash(analyzer))
        #expect(evidence.version == version)
        #expect(evidence.architecture == "arm64")
        #expect(evidence.byteCount == analyzer.count && evidence.sha256 == hash(analyzer))
        #expect(evidence.bottleTag == "arm64_sequoia" && evidence.bottleSHA256 == hash(bottle))
        #expect(evidence.sourceURL == MoleHomebrewVerifier.bottleURL(hash(bottle)))
        #expect(abs(evidence.checkedAt.timeIntervalSinceNow) < 10)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.map(\.url) == [MoleHomebrewVerifier.formulaURL, evidence.sourceURL])
        #expect(requests.allSatisfy { $0.token == nil && $0.timeout > 0 && $0.timeout <= 45 })
        #expect(requests[0].maximumBytes == MoleHomebrewVerifier.maximumMetadataBytes)
        #expect(requests[1].maximumBytes == MoleHomebrewVerifier.maximumBottleBytes)
    }

    @Test("Declared version and receipt-like hints never substitute for matching bytes")
    func versionAndByteMismatch() async throws {
        let bottle = gzip(tar([member(analyzer)]))
        let old = FixtureTransport([reply(metadata(["arm64_sequoia": bottle]))])
        await expectFailure(.currentVersionMismatch(currentVersion: version), transport: old, expectedVersion: "1.57.0")
        #expect(await old.requests.count == 1)
        let modified = FixtureTransport([reply(metadata(["arm64_sequoia": bottle])), reply(bottle)])
        await expectFailure(.installedBytesMismatch, transport: modified, installed: Data(repeating: 0, count: analyzer.count))
        let differentSize = FixtureTransport([reply(metadata(["arm64_sequoia": bottle])), reply(bottle)])
        await expectFailure(.installedBytesMismatch, transport: differentSize, installed: Data("short".utf8))
    }

    @Test("Formula revision is part of the exact keg and archive path")
    func revision() async throws {
        let bottle = gzip(tar([member(analyzer, path: "mole/1.58.0_1/libexec/bin/analyze-go")]))
        let metadata = metadata(["arm64_sequoia": bottle], revision: 1)
        let transport = FixtureTransport([reply(metadata), reply(bottle)])
        let result = try await MoleHomebrewVerifier(transport: transport).verify(expectedVersion: "1.58.0_1", architecture: "arm64",
            installedByteCount: analyzer.count, installedSHA256: hash(analyzer))
        #expect(result.version == "1.58.0_1")
        let unversioned = FixtureTransport([reply(metadata)])
        await expectFailure(.currentVersionMismatch(currentVersion: "1.58.0_1"), transport: unversioned)
    }

    @Test("Only matching macOS architecture bottles are considered")
    func architecture() async throws {
        let bottle = gzip(tar([member(analyzer)]))
        let noIntel = FixtureTransport([reply(metadata(["arm64_sequoia": bottle, "x86_64_linux": bottle]))])
        await expectFailure(.noMatchingArchitectureBottle, transport: noIntel, architecture: "x86_64")
        #expect(await noIntel.requests.count == 1)
        let intel = FixtureTransport([reply(metadata(["sequoia": bottle, "arm64_linux": Data()])), reply(bottle)])
        let proof = try await MoleHomebrewVerifier(transport: intel).verify(expectedVersion: version, architecture: "x86_64",
            installedByteCount: analyzer.count, installedSHA256: hash(analyzer))
        #expect(proof.bottleTag == "sequoia")
        #expect(!MoleHomebrewVerifier.matches(tag: "arm64_linux", architecture: "arm64"))
        #expect(!MoleHomebrewVerifier.matches(tag: "arm64_unknown_platform", architecture: "arm64"))
    }

    @Test("Different current macOS bottles may contain different exact analyzer builds")
    func tryCurrentBottles() async throws {
        let different = gzip(tar([member(Data("different toolchain build".utf8))]))
        let matching = gzip(tar([member(analyzer)]))
        let transport = FixtureTransport([reply(metadata(["arm64_sequoia": different, "arm64_tahoe": matching])), reply(different), reply(matching)])
        let proof = try await MoleHomebrewVerifier(transport: transport).verify(expectedVersion: version, architecture: "arm64",
            installedByteCount: analyzer.count, installedSHA256: hash(analyzer))
        #expect(proof.bottleTag == "arm64_tahoe")
        #expect(await transport.requests.count == 3)
    }

    @Test("Anonymous GHCR token is requested only after 401 and only for the fixed public package")
    func anonymousPull() async throws {
        let bottle = gzip(tar([member(analyzer)]))
        let token = Data(#"{"token":"public-anonymous-pull-token"}"#.utf8)
        let transport = FixtureTransport([reply(metadata(["arm64_sequoia": bottle])), reply(Data(), status: 401), reply(token), reply(bottle)])
        _ = try await MoleHomebrewVerifier(transport: transport).verify(expectedVersion: version, architecture: "arm64",
            installedByteCount: analyzer.count, installedSHA256: hash(analyzer))
        let requests = await transport.requests
        #expect(requests.count == 4 && requests[2].url == MoleHomebrewVerifier.tokenURL)
        #expect(requests[0].token == nil && requests[1].token == nil && requests[2].token == nil)
        #expect(requests[3].token == "public-anonymous-pull-token")
        #expect(requests[3].url == requests[1].url)
    }

    @Test("No retries with private credentials or unlimited token negotiation")
    func deniedAuthentication() async {
        let bottle = gzip(tar([member(analyzer)]))
        let transport = FixtureTransport([reply(metadata(["arm64_sequoia": bottle])), reply(Data(), status: 401),
            reply(Data(#"{"token":"public"}"#.utf8)), reply(Data(), status: 401)])
        await expectFailure(.unavailable, transport: transport)
        #expect(await transport.requests.count == 4)
        let badToken = FixtureTransport([reply(metadata(["arm64_sequoia": bottle])), reply(Data(), status: 401),
            reply(Data(#"{"token":"bad\r\nheader"}"#.utf8))])
        await expectFailure(.unavailable, transport: badToken)
        #expect(await badToken.requests.count == 3)
    }

    @Test("Unexpected formula identities, source URLs and digests fail before downloading")
    func forgedMetadata() async throws {
        let bottle = gzip(tar([member(analyzer)]))
        let ordinary = try #require(JSONSerialization.jsonObject(with: metadata(["arm64_sequoia": bottle])) as? [String: Any])
        for (key, value) in [("name", "other"), ("full_name", "other/mole"), ("tap", "untrusted/tap")] {
            var forged = ordinary
            forged[key] = value
            let transport = FixtureTransport([reply(try JSONSerialization.data(withJSONObject: forged))])
            await expectFailure(.invalidOfficialMetadata, transport: transport)
            #expect(await transport.requests.count == 1)
        }
        for url in ["https://evil.example/mole", "http://ghcr.io/v2/homebrew/core/mole/blobs/sha256:" + hash(bottle),
                    "https://ghcr.io/v2/homebrew/core/other/blobs/sha256:" + hash(bottle)] {
            let transport = FixtureTransport([reply(metadata(["arm64_sequoia": bottle], bottleURLOverride: url))])
            await expectFailure(.invalidOfficialMetadata, transport: transport)
            #expect(await transport.requests.count == 1)
        }
        let badDigest = FixtureTransport([reply(metadata(["arm64_sequoia": bottle], digestOverride: String(repeating: "G", count: 64)))])
        await expectFailure(.invalidOfficialMetadata, transport: badDigest)
    }

    @Test("Full bottle checksum precedes archive parsing")
    func checksum() async {
        let bottle = gzip(tar([member(analyzer)]))
        let transport = FixtureTransport([reply(metadata(["arm64_sequoia": bottle])), reply(Data("not even an archive".utf8))])
        await expectFailure(.bottleChecksumMismatch, transport: transport)
    }

    @Test("Network failure, non-success and oversized responses never produce evidence")
    func unavailableAndLimits() async {
        let unavailable = FixtureTransport([.failure(URLError(.notConnectedToInternet))])
        await expectFailure(.unavailable, transport: unavailable)
        let serverError = FixtureTransport([reply(Data(), status: 503)])
        await expectFailure(.unavailable, transport: serverError)
        let invalid = FixtureTransport([reply(Data("{".utf8))])
        await expectFailure(.invalidOfficialMetadata, transport: invalid)
        let oversized = FixtureTransport([reply(Data(repeating: 0, count: MoleHomebrewVerifier.maximumMetadataBytes + 1))])
        await expectFailure(.resourceLimit, transport: oversized)
    }

    @Test("Only one exact HTTPS GitHub packages CDN redirect is permitted")
    func redirectPolicy() async {
        let original = MoleHomebrewVerifier.bottleURL(String(repeating: "a", count: 64))
        let cdn = URL(string: "https://pkg-containers.githubusercontent.com/ghcr1/blobs/sha256:example?sig=public")!
        #expect(MoleHomebrewNetworkPolicy.validChain([original], original: original))
        #expect(MoleHomebrewNetworkPolicy.validChain([original, cdn], original: original))
        #expect(!MoleHomebrewNetworkPolicy.validChain([original, cdn, cdn], original: original))
        for unsafe in ["https://evil.example/", "http://pkg-containers.githubusercontent.com/", "https://pkg-containers.githubusercontent.com.evil.example/",
                       "https://user@pkg-containers.githubusercontent.com/", "https://pkg-containers.githubusercontent.com:444/", "https://pkg-containers.githubusercontent.com/#fragment"] {
            #expect(!MoleHomebrewNetworkPolicy.validChain([original, URL(string: unsafe)!], original: original))
        }
        #expect(!MoleHomebrewNetworkPolicy.validChain([MoleHomebrewVerifier.formulaURL, cdn], original: MoleHomebrewVerifier.formulaURL))
        #expect(!MoleHomebrewNetworkPolicy.validChain([MoleHomebrewVerifier.tokenURL, cdn], original: MoleHomebrewVerifier.tokenURL))
        let body = metadata(["arm64_sequoia": gzip(tar([member(analyzer)]))])
        let forged = FixtureTransport([.success(.init(statusCode: 200, body: body, urlChain: [URL(string: "https://evil.example")!]))])
        await expectFailure(.unexpectedSource, transport: forged)
    }

    @Test("Invalid local inputs cause no network request")
    func localValidation() async {
        for (version, architecture, size, digest) in [
            ("../../elsewhere", "arm64", analyzer.count, hash(analyzer)),
            ("V1.58.0", "arm64", analyzer.count, hash(analyzer)),
            (self.version, "amd64", analyzer.count, hash(analyzer)),
            (self.version, "arm64", 0, hash(analyzer)),
            (self.version, "arm64", analyzer.count, "not-a-sha")
        ] {
            let transport = FixtureTransport([])
            do {
                _ = try await MoleHomebrewVerifier(transport: transport).verify(expectedVersion: version, architecture: architecture,
                    installedByteCount: size, installedSHA256: digest)
                Issue.record("Invalid local metadata was accepted")
            } catch { #expect(error as? MoleHomebrewVerificationFailure == .invalidInstallationMetadata) }
            #expect(await transport.requests.isEmpty)
        }
    }

    @Test("Cancellation is propagated and cannot become successful evidence")
    func cancellation() async throws {
        let transport = FixtureTransport([.failure(CancellationError())])
        do {
            _ = try await MoleHomebrewVerifier(transport: transport).verify(expectedVersion: version, architecture: "arm64",
                installedByteCount: analyzer.count, installedSHA256: hash(analyzer))
            Issue.record("Cancelled verification returned evidence")
        } catch { #expect(error is CancellationError) }
        let waiting = WaitingTransport()
        let version = self.version, analyzer = self.analyzer
        let task = Task {
            try await MoleHomebrewVerifier(transport: waiting).verify(expectedVersion: version, architecture: "arm64",
                installedByteCount: analyzer.count, installedSHA256: hash(analyzer))
        }
        await waiting.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled transfer returned evidence") }
        catch { #expect(error is CancellationError) }
    }

    @Test("Streaming reader supports multiple DEFLATE blocks and normal unrelated wrapper links")
    func streamingAndLinks() throws {
        let large = Data((0..<200_000).map { UInt8($0 % 251) })
        let archive = gzip(tar([
            member(Data(), path: "mole/1.58.0/", type: 53),
            member(Data(), path: "mole/1.58.0/bin/mo", type: 50),
            member(large), member(Data("other file".utf8), path: "mole/1.58.0/README.md")
        ]), filename: "mole-bottle.tar")
        let result = try MoleHomebrewArchive.analyzer(in: archive, version: version)
        #expect(result.byteCount == large.count && result.sha256 == hash(large))
    }

    @Test("Independent dynamic-Huffman fixture validates optional gzip fields and header CRC")
    func dynamicHuffmanAndHeaderCRC() throws {
        // Generated independently with Python zlib, containing only synthetic
        // text. This exercises the format used by the real audited bottles.
        let encoded = """
            H4sIHgAAAAAAAwMAYWJjbW9sZS1ib3R0bGUudGFyAGZpeHR1cmUAVzTt0ktKw1AUgOGMXUU20CZRYgU34DbSeKOB5BbSG2lcvfEx
            0JGDghT8/sl9wMeZnPEwhKLa1nfbshj6fTiFttj3sWhiMyyvYfN0yM6uXNvV9ce59vPcXX//+7xXN7dVmeXl+aN/bz6mZlrH/8Ws
            C+y4xPQcUt/mj0tsxr7dPMxdNzYx/9qAKe/6U5qncJ/H8LI+31dkTuGKJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmS
            JEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmS
            JEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmS
            JEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmS
            JEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmS
            JEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmS
            JEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmS
            JEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmS
            JEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmS
            JEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEmSJEnyMmUm6d/2BsgJBN8ApgMA
            """
        let archive = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let member = try MoleHomebrewArchive.analyzer(in: archive, version: version)
        #expect(member.byteCount == 237_568)
        #expect(member.sha256 == "e6f9649e4bfde8215791fc1d9965bb209b6d094d0f561f932df8f311afd4a63d")
        var changedHeaderCRC = archive
        changedHeaderCRC[39] ^= 1
        expectArchiveFailure(changedHeaderCRC)
    }

    @Test("Target links, duplicate entries, ancestor aliases and PAX/GNU overrides are rejected")
    func unsafeMembers() {
        for entries in [
            [member(analyzer), member(analyzer)],
            [member(Data(), type: 50)],
            [member(Data(), type: 49)],
            [member(Data(), path: "mole/1.58.0/libexec", type: 50), member(analyzer)],
            [member(Data("override".utf8), path: "mole/1.58.0/PaxHeaders/x", type: 120), member(analyzer)],
            [member(Data("override".utf8), path: "mole/1.58.0/global", type: 103), member(analyzer)],
            [member(Data("override".utf8), path: "mole/1.58.0/long", type: 76), member(analyzer)],
            [member(analyzer, path: "mole/1.58.0/../libexec/bin/analyze-go")],
            [member(analyzer, path: "/mole/1.58.0/libexec/bin/analyze-go")],
            [member(analyzer, path: "mole/1.58.0/./libexec/bin/analyze-go")],
            [member(analyzer, path: "mole/1.57.0/libexec/bin/analyze-go")],
            [member(analyzer, mode: 0o644)]
        ] { expectArchiveFailure(gzip(tar(entries))) }
    }

    @Test("Header checksums, octal sizes, padding, and exact member completion are mandatory")
    func tarIntegrity() {
        let valid = tar([member(analyzer)])
        var checksum = valid; checksum[100] ^= 1
        expectArchiveFailure(gzip(checksum))
        var padding = valid; padding[512 + analyzer.count] = 1
        expectArchiveFailure(gzip(padding))
        var binarySize = valid; binarySize[124] = 0x80
        rewriteChecksum(&binarySize)
        expectArchiveFailure(gzip(binarySize))
        let oversized = tar([member(Data(), declaredSize: MoleHomebrewArchive.maximumUncompressedBytes + 1)])
        expectArchiveFailure(gzip(oversized), expected: .resourceLimit)
        expectArchiveFailure(gzip(Data(valid.prefix(520))))
        expectArchiveFailure(gzip(Data(valid.dropLast(1024))))
        var trailing = valid; trailing.append(1)
        expectArchiveFailure(gzip(trailing))
        var afterEnd = valid; afterEnd.append(contentsOf: tar([member(analyzer)]))
        expectArchiveFailure(gzip(afterEnd))
        expectArchiveFailure(gzip(tar([member(Data("irrelevant".utf8), path: "mole/1.58.0/README.md")])))
    }

    @Test("Malformed gzip framing is rejected", arguments: [
        "CRC mismatch", "ISIZE mismatch", "reserved flags", "truncated trailer", "oversized filename"
    ])
    func gzipIntegrity(corruption: String) {
        let valid = gzip(tar([member(analyzer)]))
        var malformed = valid
        switch corruption {
        case "CRC mismatch": malformed[malformed.count - 8] ^= 1
        case "ISIZE mismatch": malformed[malformed.count - 4] ^= 1
        case "reserved flags": malformed[3] = 0xe0
        case "truncated trailer": malformed = Data(valid.dropLast())
        case "oversized filename": malformed = gzip(tar([member(analyzer)]), filename: String(repeating: "a", count: 5000))
        default: Issue.record("Unknown gzip corruption fixture"); return
        }
        #expect(throws: MoleHomebrewVerificationFailure.malformedArchive) {
            try MoleHomebrewArchive.analyzer(in: malformed, version: version)
        }
    }

    @Test("Concatenated identical gzip members are rejected even when both trailers match")
    func gzipConcatenatedMembers() {
        let valid = gzip(tar([member(analyzer)]))
        #expect(throws: MoleHomebrewVerificationFailure.malformedArchive) {
            try MoleHomebrewArchive.analyzer(in: valid + valid, version: version)
        }
    }

    @Test("Bytes after DEFLATE and before the intact gzip trailer are rejected", arguments: [1, 2, 65_536])
    func gzipTrailingDeflateBytes(count: Int) {
        let valid = gzip(tar([member(analyzer)]))
        var malformed = valid
        malformed.insert(contentsOf: repeatElement(UInt8(0), count: count), at: malformed.count - 8)
        #expect(throws: MoleHomebrewVerificationFailure.malformedArchive) {
            try MoleHomebrewArchive.analyzer(in: malformed, version: version)
        }
    }

    @Test("Uncompressed, member count, cancellation and elapsed time have explicit bounds")
    func parserBudgets() throws {
        let archive = gzip(tar([member(analyzer)]))
        #expect(throws: MoleHomebrewVerificationFailure.resourceLimit) {
            try MoleHomebrewArchive.analyzer(in: archive, version: version, maximumOutput: 512)
        }
        let many = gzip(tar([member(analyzer), member(Data(), path: "mole/1.58.0/README.md")]))
        #expect(throws: MoleHomebrewVerificationFailure.resourceLimit) {
            try MoleHomebrewArchive.analyzer(in: many, version: version, maximumMembers: 1)
        }
        #expect(throws: MoleHomebrewVerificationFailure.timeLimit) {
            try MoleHomebrewArchive.analyzer(in: archive, version: version, deadline: .now.advanced(by: .seconds(-1)))
        }
    }

    private func expectFailure(_ expected: MoleHomebrewVerificationFailure, transport: FixtureTransport,
                               expectedVersion: String? = nil, architecture: String = "arm64", installed: Data? = nil) async {
        let installed = installed ?? analyzer
        do {
            _ = try await MoleHomebrewVerifier(transport: transport).verify(expectedVersion: expectedVersion ?? version,
                architecture: architecture, installedByteCount: installed.count, installedSHA256: hash(installed))
            Issue.record("Unexpected Homebrew verification success")
        } catch { #expect(error as? MoleHomebrewVerificationFailure == expected) }
    }
    private func expectArchiveFailure(_ data: Data, expected: MoleHomebrewVerificationFailure = .malformedArchive) {
        #expect(throws: expected) { try MoleHomebrewArchive.analyzer(in: data, version: version) }
    }
    private func metadata(_ bottles: [String: Data], revision: Int = 0, bottleURLOverride: String? = nil, digestOverride: String? = nil) -> Data {
        let files = bottles.mapValues { bytes in
            let digest = digestOverride ?? hash(bytes)
            return ["url": bottleURLOverride ?? "https://ghcr.io/v2/homebrew/core/mole/blobs/sha256:" + digest, "sha256": digest]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "name": "mole", "full_name": "mole", "tap": "homebrew/core", "revision": revision,
            "versions": ["stable": version, "bottle": true],
            "bottle": ["stable": ["root_url": "https://ghcr.io/v2/homebrew/core", "files": files]]
        ])
    }
    private func reply(_ body: Data, status: Int = 200) -> Result<MoleHomebrewHTTPResponse, any Error> {
        // Empty chain is populated with the actual requested URL by the fixture.
        .success(.init(statusCode: status, body: body, urlChain: []))
    }
    private func member(_ data: Data, path: String = "mole/1.58.0/libexec/bin/analyze-go", type: UInt8 = 48,
                        mode: Int = 0o755, declaredSize: Int? = nil) -> TarFixtureMember {
        .init(path: path, data: data, type: type, mode: mode, declaredSize: declaredSize)
    }
}

private actor FixtureTransport: MoleHomebrewTransport {
    struct Request: Sendable { let url: URL; let token: String?; let maximumBytes: Int; let timeout: TimeInterval }
    private var responses: [Result<MoleHomebrewHTTPResponse, any Error>]
    private(set) var requests: [Request] = []
    init(_ responses: [Result<MoleHomebrewHTTPResponse, any Error>]) { self.responses = responses }
    func get(_ url: URL, bearerToken: String?, maximumBytes: Int, timeout: TimeInterval) async throws -> MoleHomebrewHTTPResponse {
        requests.append(.init(url: url, token: bearerToken, maximumBytes: maximumBytes, timeout: timeout))
        guard !responses.isEmpty else { throw MoleHomebrewVerificationFailure.unavailable }
        let response = try responses.removeFirst().get()
        return .init(statusCode: response.statusCode, body: response.body, urlChain: response.urlChain.isEmpty ? [url] : response.urlChain)
    }
}

private actor WaitingTransport: MoleHomebrewTransport {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func get(_ url: URL, bearerToken: String?, maximumBytes: Int, timeout: TimeInterval) async throws -> MoleHomebrewHTTPResponse {
        started = true; waiter?.resume(); waiter = nil
        try await Task.sleep(for: .seconds(60))
        throw MoleHomebrewVerificationFailure.unavailable
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private struct TarFixtureMember {
    let path: String
    let data: Data
    let type: UInt8
    let mode: Int
    let declaredSize: Int?
}
private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func tar(_ members: [TarFixtureMember]) -> Data {
    var archive = Data()
    for member in members {
        var header = Data(repeating: 0, count: 512)
        func put(_ string: String, at offset: Int) { header.replaceSubrange(offset..<(offset + string.utf8.count), with: string.utf8) }
        put(member.path, at: 0)
        put(String(format: "%07o", member.mode), at: 100)
        put("0000000", at: 108); put("0000000", at: 116)
        put(String(format: "%011o", member.declaredSize ?? member.data.count), at: 124)
        put("00000000000", at: 136)
        header[156] = member.type
        put("ustar\u{0}00", at: 257)
        rewriteChecksum(&header)
        archive.append(header)
        archive.append(member.data)
        archive.append(Data(repeating: 0, count: (512 - member.data.count % 512) % 512))
    }
    archive.append(Data(repeating: 0, count: 1024))
    return archive
}
private func rewriteChecksum(_ data: inout Data) {
    data.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
    let sum = data.prefix(512).reduce(0) { $0 + Int($1) }
    data.replaceSubrange(148..<156, with: Array(String(format: "%06o", sum).utf8) + [0, 32])
}
/// Independent gzip fixture writer: RFC 1951 stored blocks, not the production
/// decoder or an external compressor. No archive bytes are executed or written.
private func gzip(_ plain: Data, filename: String? = nil) -> Data {
    var result = Data([0x1f, 0x8b, 8, filename == nil ? 0 : 8, 0, 0, 0, 0, 0, 3])
    if let filename { result.append(contentsOf: filename.utf8); result.append(0) }
    var offset = 0
    repeat {
        let length = min(65_535, plain.count - offset)
        result.append(offset + length == plain.count ? 1 : 0)
        for value in [UInt16(length), ~UInt16(length)] {
            result.append(UInt8(truncatingIfNeeded: value)); result.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        result.append(plain[offset..<(offset + length)])
        offset += length
    } while offset < plain.count
    var crc: UInt32 = 0xffffffff
    for byte in plain {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
    }
    for value in [crc ^ 0xffffffff, UInt32(plain.count)] {
        for shift in stride(from: 0, through: 24, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    return result
}
