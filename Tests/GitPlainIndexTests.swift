import CryptoKit
import Foundation
import Testing
@testable import MoeKit

struct GitPlainIndexTests {
    // Git's SHA-1 blob ID for the six bytes "hello\n".
    private static let blobOID: [UInt8] = [
        0xce, 0x01, 0x36, 0x25, 0x03, 0x0b, 0xa8, 0xdb, 0xa9, 0x06,
        0xf7, 0x56, 0x96, 0x7f, 0x9e, 0x9c, 0xa3, 0x94, 0x46, 0x4a
    ]

    private struct FixtureEntry {
        let path: [UInt8]
        var mode: UInt32 = 0o100644
        var flags: UInt16? = nil
        var oid: [UInt8] = GitPlainIndexTests.blobOID

        init(_ path: String, mode: UInt32 = 0o100644, flags: UInt16? = nil) {
            self.path = Array(path.utf8)
            self.mode = mode
            self.flags = flags
        }

        init(bytes: [UInt8]) { path = bytes }
    }

    private func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private func sealed(_ body: [UInt8]) -> Data {
        var result = Data(body)
        let digest = Insecure.SHA1.hash(data: result)
        result.append(contentsOf: digest)
        return result
    }

    private func body(_ entries: [FixtureEntry], version: UInt32 = 2) -> [UInt8] {
        var result = Array("DIRC".utf8) + uint32(version) + uint32(UInt32(entries.count))
        for entry in entries {
            let start = result.count
            result += Array(repeating: 0, count: 24)
            result += uint32(entry.mode)
            result += Array(repeating: 0, count: 12)
            result += entry.oid
            let flags = entry.flags ?? UInt16(min(entry.path.count, 0x0fff))
            result += [UInt8(truncatingIfNeeded: flags >> 8), UInt8(truncatingIfNeeded: flags)]
            result += entry.path + [0]
            while (result.count - start) % 8 != 0 { result.append(0) }
        }
        return result
    }

    private func index(_ entries: [FixtureEntry], version: UInt32 = 2) -> Data {
        sealed(body(entries, version: version))
    }

    private func extended(_ entries: [FixtureEntry], signature: String, payload: [UInt8], declaredSize: UInt32? = nil) -> Data {
        sealed(body(entries) + Array(signature.utf8) + uint32(declaredSize ?? UInt32(payload.count)) + payload)
    }

    @Test("A plain empty index reconstructs Git's canonical empty tree")
    func emptyIndex() throws {
        let result = try GitPlainIndex.parse(index([]))
        #expect(result.entries.isEmpty)
        #expect(result.treeOID == "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    }

    @Test("The index checksum and the reconstructed tree use canonical Git SHA-1 framing")
    func singleFile() throws {
        let result = try GitPlainIndex.parse(index([FixtureEntry("hello.txt")]))
        #expect(result.entries == [GitPlainIndex.Entry(path: "hello.txt",
            oid: "ce013625030ba8dba906f756967f9e9ca394464a", executable: false)])
        #expect(result.treeOID == "aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7")
    }

    @Test("Trees sort directory names with slash and preserve executable modes")
    func nestedTree() throws {
        let result = try GitPlainIndex.parse(index([
            FixtureEntry("a.c"), FixtureEntry("a/file"), FixtureEntry("a0"), FixtureEntry("b", mode: 0o100755)
        ]))
        #expect(result.treeOID == "1fc251f810a3554fc0d4149723d189a318a4acfd")
        #expect(result.entries.map(\.executable) == [false, false, false, true])
    }

    @Test("A captured system-Git v2 index agrees with independently generated write-tree output")
    func capturedGitIndex() throws {
        // Captured from an isolated, temporary repository containing a.c,
        // a/file, a0 and executable b, each containing "hello\n". Only unused
        // stat fields were zeroed and the index checksum refreshed. No process
        // or filesystem access occurs in this test or in the parser.
        let encoded = "RElSQwAAAAIAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBpAAAAAAAAAAAAAAAAM4BNiUDC6jbqQb3VpZ/npyjlEZKAANhLmMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBpAAAAAAAAAAAAAAAAM4BNiUDC6jbqQb3VpZ/npyjlEZKAAZhL2ZpbGUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBpAAAAAAAAAAAAAAAAM4BNiUDC6jbqQb3VpZ/npyjlEZKAAJhMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACB7QAAAAAAAAAAAAAAAM4BNiUDC6jbqQb3VpZ/npyjlEZKAAFiAFRSRUUAAAAzADQgMQofwlH4EKNVT8DUFJcj0YmjGKSs/WEAMSAwCvtahhmfYyQxYO5bRj0s1cNvr+tt7XWu7WEzIo0v1wPnao62sG7tgC4="
        let data = try #require(Data(base64Encoded: encoded))
        let result = try GitPlainIndex.parse(data)
        #expect(result.entries.map(\.path) == ["a.c", "a/file", "a0", "b"])
        #expect(result.entries.last?.executable == true)
        #expect(result.treeOID == "1fc251f810a3554fc0d4149723d189a318a4acfd")
    }

    @Test("All eight pathname alignment residues are relative to the entry start")
    func entryAlignment() throws {
        let entries = (1...8).map { FixtureEntry(String(repeating: "a", count: $0)) }
        let result = try GitPlainIndex.parse(index(entries))
        #expect(result.entries.map(\.path) == (1...8).map { String(repeating: "a", count: $0) })
    }

    @Test("Nonzero Data offsets and UTF-8 filenames preserve exact bytes")
    func dataSliceAndUnicode() throws {
        let expected = index([FixtureEntry("résumé.txt")])
        let prefixed = Data([1, 2, 3]) + expected
        #expect(try GitPlainIndex.parse(prefixed.dropFirst(3)).entries.first?.path == "résumé.txt")
    }

    @Test("Name length sentinel accepts bounded paths of 4095 or more UTF-8 bytes")
    func longPathSentinel() throws {
        let prefix = Array(repeating: String(repeating: "a", count: 255), count: 15).joined(separator: "/")
        for lastLength in [255, 256] {
            // Keep components <= 255 bytes while reaching 4095 and 4096 total.
            let suffix = lastLength == 255 ? String(repeating: "b", count: 255) : "b/" + String(repeating: "c", count: 254)
            let path = prefix + "/" + suffix
            #expect(path.utf8.count == (lastLength == 255 ? 4_095 : 4_096))
            #expect(try GitPlainIndex.parse(index([FixtureEntry(path)])).entries.first?.path == path)
        }
    }

    @Test("Wrong versions, headers, checksums and zero object IDs fail closed")
    func invalidIdentity() {
        for version in [UInt32(0), 1, 3, 4, UInt32.max] {
            #expect(throws: GitPlainIndexError.unsupportedVersion) { try GitPlainIndex.parse(index([], version: version)) }
        }
        var badHeader = body([])
        badHeader[0] = 0
        #expect(throws: GitPlainIndexError.invalidHeader) { try GitPlainIndex.parse(sealed(badHeader)) }
        var badChecksum = index([FixtureEntry("file")])
        badChecksum[20] ^= 1
        #expect(throws: GitPlainIndexError.invalidChecksum) { try GitPlainIndex.parse(badChecksum) }
        var zeroOID = FixtureEntry("file")
        zeroOID.oid = Array(repeating: 0, count: 20)
        #expect(throws: GitPlainIndexError.invalidObjectID) { try GitPlainIndex.parse(index([zeroOID])) }
    }

    @Test("Assume-valid, extended flags and every nonzero merge stage are unsupported")
    func flags() {
        for bit in [UInt16(0x8000), 0x4000, 0x1000, 0x2000, 0x3000, 0xffff] {
            #expect(throws: GitPlainIndexError.unsupportedFlags) {
                try GitPlainIndex.parse(index([FixtureEntry("file", flags: bit | 4)]))
            }
        }
        for length in [UInt16(0), 3, 5, 0x0fff] {
            #expect(throws: GitPlainIndexError.invalidPath) {
                try GitPlainIndex.parse(index([FixtureEntry("file", flags: length)]))
            }
        }
    }

    @Test("Only exact ordinary-file modes are accepted")
    func modes() {
        for mode in [UInt32(0), 0o040000, 0o120000, 0o160000, 0o100600, 0o100664, 0o100777, 0x100081a4] {
            #expect(throws: GitPlainIndexError.unsupportedMode) { try GitPlainIndex.parse(index([FixtureEntry("file", mode: mode)])) }
        }
    }

    @Test("Unsafe paths, Git metadata and attributes are rejected at every level")
    func paths() {
        let invalid = ["", "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a\\b", "a:b",
            "a\nb", "a\tb", "a\u{7f}b", "a\u{85}b", ".gi\u{200c}t", "a.", "a ", ".git", ".GIT/config", "a/.git/config",
            ".gitattributes", "a/.GITATTRIBUTES", "a/.gitattributes/file", String(repeating: "a", count: 256)]
        for path in invalid {
            #expect(throws: (any Error).self) { try GitPlainIndex.parse(index([FixtureEntry(path)])) }
        }
        #expect(throws: GitPlainIndexError.invalidPath) { try GitPlainIndex.parse(index([FixtureEntry(bytes: [0xff])])) }
        #expect(throws: GitPlainIndexError.invalidPath) { try GitPlainIndex.parse(index([FixtureEntry(bytes: [0xc0, 0xaf])])) }
    }

    @Test("Duplicate, unsorted, case-folded and Unicode-normalization aliases fail closed")
    func collisions() {
        let invalid = [["a", "a"], ["b", "a"], ["A", "a"], ["A/one", "a/two"], ["a", "a/file"],
            ["A", "a/file"], ["a/b", "a/b/c"], ["e\u{301}", "é"], ["Straße", "strasse"]]
        for paths in invalid {
            #expect(throws: (any Error).self) { try GitPlainIndex.parse(index(paths.map { FixtureEntry($0) })) }
        }
    }

    @Test("TREE is bounded and ignored; cached object IDs never override fresh tree hashing")
    func cachedTree() throws {
        let payload = Array("\0-1 0\n".utf8)
        let plain = try GitPlainIndex.parse(index([FixtureEntry("file")]))
        let cached = try GitPlainIndex.parse(extended([FixtureEntry("file")], signature: "TREE", payload: payload))
        #expect(cached.treeOID == plain.treeOID)
        let stalePayload = Array("\0".utf8) + Array("1 0\n".utf8) + Array(repeating: UInt8(0xaa), count: 20)
        #expect(try GitPlainIndex.parse(extended([FixtureEntry("file")], signature: "TREE", payload: stalePayload)).treeOID == plain.treeOID)
    }

    @Test("All other extensions, duplicate TREE frames and out-of-bounds lengths are rejected")
    func extensions() {
        for signature in ["link", "FSMN", "UNTR", "sdir", "REUC", "EOIE", "IEOT", "TEST", "tree"] {
            #expect(throws: GitPlainIndexError.unsupportedExtension) {
                try GitPlainIndex.parse(extended([], signature: signature, payload: []))
            }
        }
        #expect(throws: GitPlainIndexError.truncated) { try GitPlainIndex.parse(extended([], signature: "TREE", payload: [], declaredSize: 1)) }
        #expect(throws: GitPlainIndexError.truncated) { try GitPlainIndex.parse(extended([], signature: "TREE", payload: [], declaredSize: UInt32.max)) }
        let frame = Array("TREE".utf8) + uint32(0)
        #expect(throws: GitPlainIndexError.unsupportedExtension) { try GitPlainIndex.parse(sealed(body([]) + frame + frame)) }
    }

    @Test("Truncation, missing terminators, nonzero padding and trailing garbage cannot parse")
    func truncationAndPadding() {
        let validBody = body([FixtureEntry("file")])
        for length in 0..<validBody.count {
            #expect(throws: (any Error).self) { try GitPlainIndex.parse(sealed(Array(validBody.prefix(length)))) }
        }
        var nonzeroPadding = validBody
        nonzeroPadding[nonzeroPadding.count - 1] = 1
        #expect(throws: GitPlainIndexError.invalidPadding) { try GitPlainIndex.parse(sealed(nonzeroPadding)) }
        var noTerminator = validBody
        for offset in (12 + 62)..<noTerminator.count { noTerminator[offset] = 1 }
        #expect(throws: GitPlainIndexError.truncated) { try GitPlainIndex.parse(sealed(noTerminator)) }
        for trailingCount in 1...7 {
            #expect(throws: GitPlainIndexError.truncated) {
                try GitPlainIndex.parse(sealed(validBody + Array(repeating: 0, count: trailingCount)))
            }
        }
    }

    @Test("Input, entry count, path bytes and depth have explicit budgets")
    func budgets() {
        #expect(throws: GitPlainIndexError.oversized) {
            try GitPlainIndex.parse(Data(repeating: 0, count: GitPlainIndex.maximumBytes + 1))
        }
        let tooMany = Array("DIRC".utf8) + uint32(2) + uint32(UInt32(GitPlainIndex.maximumEntries + 1))
        #expect(throws: GitPlainIndexError.oversized) { try GitPlainIndex.parse(sealed(tooMany)) }
        #expect(throws: GitPlainIndexError.oversized) {
            try GitPlainIndex.parse(index([FixtureEntry(String(repeating: "a", count: GitPlainIndex.maximumPathBytes + 1))]))
        }
        let tooDeep = Array(repeating: "a", count: GitPlainIndex.maximumDepth + 1).joined(separator: "/")
        #expect(throws: GitPlainIndexError.oversized) { try GitPlainIndex.parse(index([FixtureEntry(tooDeep)])) }
        // File/byte caps alone do not bound a wide, deeply nested trie.
        let manyDirectories = (0..<(GitPlainIndex.maximumTreeNodes / 2 + 1)).map {
            FixtureEntry(String(format: "%06d/file", $0))
        }
        #expect(throws: GitPlainIndexError.oversized) { try GitPlainIndex.parse(index(manyDirectories)) }
    }
}
