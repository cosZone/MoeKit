import Darwin
import Foundation

/// Darwin readdir returns packed, variable-length records. The imported Swift
/// d_name tuple has 1,024 bytes, but those bytes are NOT all present in each
/// record. Never load/copy that tuple (or the entire dirent value).
/// Layout contract: Apple xnu bsd/sys/dirent.h, d_reclen and d_namlen.
enum DarwinDirectoryEntry {
    enum InvalidName: Error { case malformed }

    static func name(_ entry: UnsafePointer<dirent>) throws -> String {
        try decode(UnsafeRawPointer(entry))
    }

    static func decode(_ raw: UnsafeRawPointer) throws -> String {
        guard let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name),
              let recordOffset = MemoryLayout<dirent>.offset(of: \.d_reclen),
              let lengthOffset = MemoryLayout<dirent>.offset(of: \.d_namlen) else { throw InvalidName.malformed }
        let recordLength = Int(raw.load(fromByteOffset: recordOffset, as: UInt16.self))
        let nameLength = Int(raw.load(fromByteOffset: lengthOffset, as: UInt16.self))
        // macOS 15's 64-bit dirent permits names up to MAXPATHLEN - 1.
        // Subtraction avoids overflow; the terminator must fit the record too.
        guard recordLength > nameOffset, nameLength > 0, nameLength < 1_024,
              nameLength < recordLength - nameOffset else { throw InvalidName.malformed }
        let bytes = UnsafeRawBufferPointer(start: raw.advanced(by: nameOffset), count: nameLength + 1)
        guard bytes[nameLength] == 0, !bytes.prefix(nameLength).contains(0),
              let name = String(bytes: bytes.prefix(nameLength), encoding: .utf8),
              !name.contains("/") else { throw InvalidName.malformed }
        return name
    }
}
