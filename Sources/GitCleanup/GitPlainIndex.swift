import CryptoKit
import Foundation

/// The deliberately small, plain SHA-1 index subset supported by native cleanup.
/// Parsing is pure: the checksum checks the supplied bytes, not their
/// provenance, freshness, the working tree, or the existence of any Git object.
struct GitPlainIndex: Sendable {
    struct Entry: Equatable, Sendable {
        let path: String
        let oid: String
        let executable: Bool
    }

    let entries: [Entry]
    let treeOID: String

    static let maximumBytes = 16 * 1_024 * 1_024
    static let maximumEntries = 100_000
    static let maximumPathBytes = 4_096
    static let maximumDepth = 64

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw GitPlainIndexError.oversized }
        guard data.count >= 32 else { throw GitPlainIndexError.truncated }
        let bodySize = data.count - 20
        let digest = Insecure.SHA1.hash(data: data.prefix(bodySize))
        guard Array(digest) == Array(data.suffix(20)) else { throw GitPlainIndexError.invalidChecksum }

        // Reset offsets even when the caller supplies a Data slice.
        var cursor = Cursor(bytes: Array(data), end: bodySize)
        guard try cursor.read(4) == Array("DIRC".utf8) else { throw GitPlainIndexError.invalidHeader }
        guard try cursor.uint32() == 2 else { throw GitPlainIndexError.unsupportedVersion }
        let count = Int(try cursor.uint32())
        guard count <= maximumEntries else { throw GitPlainIndexError.oversized }
        // Every nonempty v2 entry takes at least 64 bytes. Check before reserving.
        guard count <= (bodySize - 12) / 64 else { throw GitPlainIndexError.truncated }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var previousPath: [UInt8]?
        let root = Directory()
        for _ in 0..<count {
            let start = cursor.offset
            try cursor.skip(24) // ctime, mtime, device and inode; never trusted.
            let mode = try cursor.uint32()
            guard mode == 0o100644 || mode == 0o100755 else { throw GitPlainIndexError.unsupportedMode }
            try cursor.skip(12) // uid, gid and size; never a cleanliness shortcut.
            let oid = try cursor.read(20)
            guard oid.contains(where: { $0 != 0 }) else { throw GitPlainIndexError.invalidObjectID }
            let flags = try cursor.uint16()
            // No assume-valid, extended, or conflict-stage entries.
            guard flags & 0xf000 == 0 else { throw GitPlainIndexError.unsupportedFlags }

            let pathBytes = try cursor.path()
            guard Int(flags & 0x0fff) == min(pathBytes.count, 0x0fff) else {
                throw GitPlainIndexError.invalidPath
            }
            let components = try pathComponents(pathBytes)
            if let previousPath, !previousPath.lexicographicallyPrecedes(pathBytes) {
                throw GitPlainIndexError.invalidEntryOrder
            }
            previousPath = pathBytes

            // Alignment is relative to THIS entry, not byte zero of the file:
            // the 12-byte header leaves every v2 entry start at 4 modulo 8.
            let padding = (8 - ((cursor.offset - start) % 8)) % 8
            guard try cursor.read(padding).allSatisfy({ $0 == 0 }) else {
                throw GitPlainIndexError.invalidPadding
            }
            let executable = mode == 0o100755
            try root.insert(components: components, oid: oid, executable: executable)
            entries.append(Entry(path: components.joined(separator: "/"), oid: hex(oid), executable: executable))
        }

        var sawTree = false
        while cursor.offset < bodySize {
            let signature = try cursor.read(4)
            let size = Int(try cursor.uint32())
            guard signature == Array("TREE".utf8), !sawTree else {
                throw GitPlainIndexError.unsupportedExtension
            }
            sawTree = true
            // TREE is only a dispensable cache. Its contents and claimed OIDs
            // never contribute to the result. Only its bounded frame is used.
            try cursor.skip(size)
        }
        return Self(entries: entries, treeOID: hex(root.objectID()))
    }

    private static func pathComponents(_ bytes: [UInt8]) throws -> [String] {
        guard !bytes.isEmpty,
              !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f || $0 == 0x5c || $0 == 0x3a }),
              let path = String(bytes: bytes, encoding: .utf8) else { throw GitPlainIndexError.invalidPath }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count <= maximumDepth else { throw GitPlainIndexError.oversized }
        for component in components {
            let key = collisionKey(component)
            guard !component.isEmpty, component.utf8.count <= 255,
                  !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  component != ".", component != "..",
                  !component.hasSuffix("."), !component.hasSuffix(" "),
                  key != ".git", key != ".gitattributes" else { throw GitPlainIndexError.invalidPath }
        }
        return components
    }

    private static func collisionKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }

    private struct Cursor {
        let bytes: [UInt8]
        let end: Int
        var offset = 0

        mutating func skip(_ size: Int) throws {
            guard size >= 0, size <= end - offset else { throw GitPlainIndexError.truncated }
            offset += size
        }

        mutating func read(_ size: Int) throws -> [UInt8] {
            let start = offset
            try skip(size)
            return Array(bytes[start..<offset])
        }

        mutating func uint16() throws -> UInt16 {
            let bytes = try read(2)
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }

        mutating func uint32() throws -> UInt32 {
            let bytes = try read(4)
            return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        }

        mutating func path() throws -> [UInt8] {
            let start = offset
            while offset < end, offset - start <= GitPlainIndex.maximumPathBytes {
                if bytes[offset] == 0 {
                    let result = Array(bytes[start..<offset])
                    offset += 1
                    return result
                }
                offset += 1
            }
            if offset - start > GitPlainIndex.maximumPathBytes { throw GitPlainIndexError.oversized }
            throw GitPlainIndexError.truncated
        }
    }

    /// A local trie catches file/directory conflicts and aliases at EVERY level,
    /// including `A/one` with `a/two`, before constructing any tree object.
    private final class Directory {
        private enum Content {
            case blob(oid: [UInt8], executable: Bool)
            case directory(Directory)
        }

        private struct Child {
            let name: [UInt8]
            let content: Content

            var sortKey: [UInt8] {
                switch content {
                case .blob: name
                case .directory: name + [0x2f]
                }
            }
        }

        private var children: [String: Child] = [:]

        func insert(components: [String], oid: [UInt8], executable: Bool) throws {
            var directory = self
            for (index, name) in components.enumerated() {
                let key = GitPlainIndex.collisionKey(name)
                let bytes = Array(name.utf8)
                let isFile = index == components.count - 1
                if let existing = directory.children[key] {
                    guard existing.name == bytes, !isFile,
                          case .directory(let nested) = existing.content else {
                        throw GitPlainIndexError.ambiguousPath
                    }
                    directory = nested
                } else if isFile {
                    directory.children[key] = Child(name: bytes, content: .blob(oid: oid, executable: executable))
                } else {
                    let nested = Directory()
                    directory.children[key] = Child(name: bytes, content: .directory(nested))
                    directory = nested
                }
            }
        }

        func objectID() -> [UInt8] {
            let sorted = children.values.sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }
            var body = Data()
            for child in sorted {
                let mode: String
                let oid: [UInt8]
                switch child.content {
                case .blob(let blobOID, let executable):
                    mode = executable ? "100755" : "100644"
                    oid = blobOID
                case .directory(let nested):
                    mode = "40000"
                    oid = nested.objectID()
                }
                body.append(contentsOf: (mode + " ").utf8)
                body.append(contentsOf: child.name)
                body.append(0)
                body.append(contentsOf: oid)
            }
            var hash = Insecure.SHA1()
            hash.update(data: Data("tree \(body.count)\0".utf8))
            hash.update(data: body)
            return Array(hash.finalize())
        }
    }
}

enum GitPlainIndexError: Error, Equatable {
    case oversized
    case truncated
    case invalidHeader
    case unsupportedVersion
    case invalidChecksum
    case unsupportedFlags
    case unsupportedMode
    case invalidObjectID
    case invalidPath
    case ambiguousPath
    case invalidEntryOrder
    case invalidPadding
    case unsupportedExtension
}
