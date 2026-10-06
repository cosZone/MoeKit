import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Packed Darwin directory records")
struct DarwinDirectoryEntryTests {
    /// Allocate only the actual record bytes, not sizeof(dirent). ASan catches
    /// any future return to copying the imported 1,024-byte d_name tuple.
    private func decode(_ bytes: [UInt8], declaredLength: Int? = nil, recordLength: Int? = nil,
                        terminator: UInt8 = 0) throws -> String {
        let offset = try #require(MemoryLayout<dirent>.offset(of: \.d_name))
        let recordOffset = try #require(MemoryLayout<dirent>.offset(of: \.d_reclen))
        let lengthOffset = try #require(MemoryLayout<dirent>.offset(of: \.d_namlen))
        let allocation = offset + bytes.count + 1
        let raw = UnsafeMutableRawPointer.allocate(byteCount: allocation, alignment: MemoryLayout<dirent>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: allocation)
        raw.storeBytes(of: UInt16(recordLength ?? allocation), toByteOffset: recordOffset, as: UInt16.self)
        raw.storeBytes(of: UInt16(declaredLength ?? bytes.count), toByteOffset: lengthOffset, as: UInt16.self)
        for (index, byte) in bytes.enumerated() { raw.storeBytes(of: byte, toByteOffset: offset + index, as: UInt8.self) }
        raw.storeBytes(of: terminator, toByteOffset: offset + bytes.count, as: UInt8.self)
        return try DarwinDirectoryEntry.decode(UnsafeRawPointer(raw))
    }

    @Test("Short, Unicode, and maximum names decode from exact packed records",
           arguments: ["a", ".", "..", "空格 name\\n", String(repeating: "x", count: 255), String(repeating: "x", count: 1_023)])
    func exactRecord(_ name: String) throws {
        #expect(try decode(Array(name.utf8)) == name)
    }
    @Test("Malformed lengths, missing terminators, invalid UTF-8 and embedded NUL are rejected")
    func malformedRecords() throws {
        #expect(throws: DarwinDirectoryEntry.InvalidName.self) { try decode([97], declaredLength: 1_024) }
        #expect(throws: DarwinDirectoryEntry.InvalidName.self) { try decode([97], recordLength: 0) }
        #expect(throws: DarwinDirectoryEntry.InvalidName.self) { try decode([97], declaredLength: 2) }
        #expect(throws: DarwinDirectoryEntry.InvalidName.self) { try decode([], declaredLength: 0) }
        #expect(throws: DarwinDirectoryEntry.InvalidName.self) { try decode([97], terminator: 1) }
        #expect(throws: DarwinDirectoryEntry.InvalidName.self) { try decode([0xff]) }
        #expect(throws: DarwinDirectoryEntry.InvalidName.self) { try decode([97, 0, 98]) }
        #expect(throws: DarwinDirectoryEntry.InvalidName.self) { try decode([47]) }
    }
    @Test("Shared discovery and cleanup readers safely cross packed readdir buffer boundaries")
    func manyShortNames() throws {
        let base = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)
            .appendingPathComponent("MoeKit-Packed-Directory-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var expected: Set<String> = []
        for index in 0..<400 {
            let name = "f\(index)"
            expected.insert(name)
            try Data("owned-\(index)".utf8).write(to: base.appendingPathComponent(name), options: .withoutOverwriting)
        }
        let directory = try AnchoredDirectory.selected(base), entries = try directory.entries()
        var names: Set<String> = []
        while let name = try entries.next() { names.insert(name) }
        #expect(names == expected)
        let cleanup = try InstallerDirectoryAnchor.open(base)
        #expect(Set(try CleanupFiles.names(cleanup)) == expected)
        #expect(Set(try InstallerRecoveryJournal.names(cleanup)) == expected)
        // Unique fixture is retained. No real-user paths or cleanup mutation.
    }
}
