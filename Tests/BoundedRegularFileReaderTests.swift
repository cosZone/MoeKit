import Foundation
import Darwin
import Testing
@testable import MoeKit

@Suite("Bounded descriptor reads")
struct BoundedRegularFileReaderTests {
    @Test("Reads exact bounds, including empty files and multiple chunks")
    func exactBounds() throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        for size in [0, 1, 16_384, 131_073] {
            let bytes = Data(repeating: 0x61, count: size)
            try bytes.write(to: fixture.file)
            #expect(try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: size) == bytes)
        }
    }

    @Test("A FIFO replacing a previously checked regular file never waits for a writer")
    func replacedByFIFO() throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        try Data("previously regular".utf8).write(to: fixture.file)
        let checked = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect(checked[.type] as? FileAttributeType == .typeRegular)
        try FileManager.default.removeItem(at: fixture.file)
        let created = fixture.file.withUnsafeFileSystemRepresentation { Darwin.mkfifo($0!, 0o600) }
        try #require(created == 0)

        // No writer is opened. This exercises the post-check open boundary directly;
        // a blocking FileHandle/open implementation would never reach the assertion.
        #expect(throws: BoundedRegularFileReader.ReadError.notRegularFile) {
            try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: 16_384)
        }
    }

    @Test("A symlink replacing a previously checked file is never followed")
    func replacedBySymbolicLink() throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        try Data("previously regular".utf8).write(to: fixture.file)
        _ = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        let target = fixture.root.appendingPathComponent("other")
        try Data("must not be read".utf8).write(to: target)
        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)

        #expect(throws: BoundedRegularFileReader.ReadError.symbolicLink) {
            try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: 16_384)
        }
    }

    @Test("Rejects a directory opened in place of a file")
    func directory() throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        #expect(throws: BoundedRegularFileReader.ReadError.notRegularFile) {
            try BoundedRegularFileReader.read(at: fixture.root, maximumBytes: 16_384)
        }
    }

    @Test("Rejects oversized sparse files without allocating their declared length")
    func sparseOversize() throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.file)
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.truncate(atOffset: 1_073_741_824)
        try handle.close()
        #expect(throws: BoundedRegularFileReader.ReadError.tooLarge) {
            try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: 16_384)
        }
    }

    @Test("Rejects a file one byte above its bound")
    func overBound() throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        try Data(repeating: 0x61, count: 16_385).write(to: fixture.file)
        #expect(throws: BoundedRegularFileReader.ReadError.tooLarge) {
            try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: 16_384)
        }
    }

    @Test("Growth after descriptor inspection stays bounded")
    func growthAfterOpen() throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        try Data("small".utf8).write(to: fixture.file)
        #expect(throws: BoundedRegularFileReader.ReadError.tooLarge) {
            try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: 16_384) {
                let writer = try FileHandle(forWritingTo: fixture.file)
                defer { try? writer.close() }
                try writer.truncate(atOffset: 1_073_741_824)
            }
        }
    }

    @Test("Truncation after opening is an unknown snapshot, not partial success")
    func truncationAfterOpen() throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.file)
        #expect(throws: BoundedRegularFileReader.ReadError.changedDuringRead) {
            try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: 16_384) {
                let writer = try FileHandle(forWritingTo: fixture.file)
                defer { try? writer.close() }
                try writer.truncate(atOffset: 1)
            }
        }
    }

    @Test("Cancellation after opening aborts before reading contents")
    func cancellationAfterOpen() async throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        try Data("small".utf8).write(to: fixture.file)
        let task = Task {
            try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: 16_384) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Cancellation is checked before opening even a missing path")
    func cancellation() async throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: 16_384)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Read errors preserve missing-file POSIX information")
    func missingFile() throws {
        let fixture = try ReaderFixture()
        defer { fixture.remove() }
        do {
            _ = try BoundedRegularFileReader.read(at: fixture.file, maximumBytes: 16_384)
            Issue.record("A missing path was accepted")
        } catch {
            let error = error as NSError
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOENT))
        }
    }
}

private struct ReaderFixture: Sendable {
    let root: URL
    var file: URL { root.appendingPathComponent("metadata") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
