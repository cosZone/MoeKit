import Foundation
import Darwin
import Testing
@testable import MoeKit

struct CatalogWriteCoordinatorTests {
    @Test("Overlapping writers fail busy, then conflict without losing the winner")
    func overlappingSaves() throws {
        let fixture = WriterFixture()
        defer { fixture.remove() }
        let first = fixture.project("First")
        let second = fixture.project("Second")
        let loser = CatalogPersistence(directory: fixture.root)
        #expect(try loser.load().isEmpty)
        let winner = CatalogPersistence(directory: fixture.root) {
            #expect(throws: CatalogPersistence.CatalogError.writerBusy) { try loser.save([second]) }
            #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        }
        try winner.save([first])
        let bytes = try Data(contentsOf: fixture.file)
        #expect(throws: CatalogPersistence.CatalogError.changedSinceLoad) { try loser.save([second]) }
        #expect(try Data(contentsOf: fixture.file) == bytes)
        #expect(try loser.load() == [first])
        try loser.save([first, second])
        #expect(try CatalogPersistence(directory: fixture.root).load() == [first, second])
    }

    @Test("Busy does not poison the loaded snapshot, and releasing a lock permits retry")
    func busyRetry() throws {
        let fixture = WriterFixture()
        defer { fixture.remove() }
        let persistence = CatalogPersistence(directory: fixture.root)
        #expect(try persistence.load().isEmpty)
        try CatalogWriteCoordinator.withExclusiveAccess(at: fixture.root) { _ in
            #expect(throws: CatalogPersistence.CatalogError.writerBusy) { try persistence.save([]) }
        }
        try persistence.save([])
        let first = try fixture.identity(fixture.lock)
        try persistence.save([fixture.project("Retry")])
        #expect(try fixture.identity(fixture.lock) == first)
    }

    @Test("Unsafe lock objects are never followed, truncated, chmod-ed or replaced", arguments: 0..<5)
    func unsafeLock(variant: Int) throws {
        let fixture = WriterFixture()
        defer { fixture.remove() }
        try fixture.createRoot()
        let target = fixture.root.appendingPathComponent("target")
        let bytes = Data("preserve target bytes".utf8)
        try bytes.write(to: target)
        switch variant {
        case 0: try FileManager.default.createSymbolicLink(at: fixture.lock, withDestinationURL: target)
        case 1: #expect(fixture.lock.withUnsafeFileSystemRepresentation { Darwin.mkfifo($0!, 0o600) } == 0)
        case 2: try FileManager.default.createDirectory(at: fixture.lock, withIntermediateDirectories: false)
        case 3: try FileManager.default.linkItem(at: target, to: fixture.lock)
        default:
            try bytes.write(to: fixture.lock)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.lock.path)
        }
        let originalIdentity = try fixture.identity(fixture.lock)
        #expect(throws: (any Error).self) { try CatalogPersistence(directory: fixture.root).save([]) }
        #expect(try fixture.identity(fixture.lock) == originalIdentity)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        if variant == 4 {
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.lock.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
            #expect(try Data(contentsOf: fixture.lock) == bytes)
        }
    }

    @Test("Lock-name replacement is rejected before catalog replacement")
    func replacedLock() throws {
        let fixture = WriterFixture()
        defer { fixture.remove() }
        let displaced = fixture.root.appendingPathComponent("displaced-lock")
        let persistence = CatalogPersistence(directory: fixture.root) {
            try FileManager.default.moveItem(at: fixture.lock, to: displaced)
            #expect(FileManager.default.createFile(atPath: fixture.lock.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        }
        #expect(throws: CatalogPersistence.CatalogError.changedSinceLoad) { try persistence.save([]) }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) == ["projects.json.lock", "displaced-lock"])
    }

    @Test("Final catalog directory symlinks fail with or without a trailing slash", arguments: [false, true])
    func symbolicLinkDirectory(isDirectory: Bool) throws {
        let fixture = WriterFixture()
        defer { fixture.remove() }
        try fixture.createRoot()
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let original = Data("[]".utf8)
        let catalog = target.appendingPathComponent("projects.json")
        try original.write(to: catalog)
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let directory = URL(fileURLWithPath: link.path, isDirectory: isDirectory)
        #expect(throws: NSError.self) { try CatalogPersistence(directory: directory).save([fixture.project("Changed")]) }
        #expect(try Data(contentsOf: catalog) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["projects.json"])
    }

    @Test("Replacing the catalog directory cannot redirect or silently detach the commit")
    func replacedDirectory() throws {
        let fixture = WriterFixture()
        let moved = fixture.root.appendingPathExtension("moved")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: moved)
        }
        let persistence = CatalogPersistence(directory: fixture.root) {
            try FileManager.default.moveItem(at: fixture.root, to: moved)
            try fixture.createRoot()
        }
        #expect(throws: CatalogPersistence.CatalogError.changedSinceLoad) { try persistence.save([]) }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path) == ["projects.json.lock"])
    }

    @Test("A failed rename removes its temporary file, keeps the lock and allows retry")
    func renameFailure() throws {
        let fixture = WriterFixture()
        defer { fixture.remove() }
        try CatalogWriteCoordinator.withExclusiveAccess(at: fixture.root) { writer in
            #expect(throws: NSError.self) {
                try writer.replace(with: Data("[]".utf8)) {
                    try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
                }
            }
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) == ["projects.json", "projects.json.lock"])
        try FileManager.default.removeItem(at: fixture.file)
        try CatalogPersistence(directory: fixture.root).save([])
        #expect(try Data(contentsOf: fixture.file) == Data("[]".utf8))
    }

    @Test("An error after temporary-file IO preserves original bytes and releases the lock")
    func failedPreparedWrite() throws {
        let fixture = WriterFixture()
        defer { fixture.remove() }
        try CatalogPersistence(directory: fixture.root).save([fixture.project("Original")])
        let original = try Data(contentsOf: fixture.file)
        try CatalogWriteCoordinator.withExclusiveAccess(at: fixture.root) { writer in
            #expect(throws: NSError.self) {
                try writer.replace(with: Data("[]".utf8)) {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
            }
        }
        #expect(try Data(contentsOf: fixture.file) == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) == ["projects.json", "projects.json.lock"])
        let persistence = CatalogPersistence(directory: fixture.root)
        _ = try persistence.load()
        try persistence.save([])
        #expect(try Data(contentsOf: fixture.file) == Data("[]".utf8))
    }

    @Test("Replacing a prepared temporary pathname cannot commit or delete the replacement", arguments: [false, true])
    func replacedTemporary(symbolicLink: Bool) throws {
        let fixture = WriterFixture()
        defer { fixture.remove() }
        try CatalogPersistence(directory: fixture.root).save([fixture.project("Original")])
        let original = try Data(contentsOf: fixture.file)
        let target = fixture.root.appendingPathComponent("unrelated")
        let replacement = Data("unrelated replacement bytes".utf8)
        try replacement.write(to: target)
        var temporary: URL?
        try CatalogWriteCoordinator.withExclusiveAccess(at: fixture.root) { writer in
            #expect(throws: CatalogPersistence.CatalogError.changedSinceLoad) {
                try writer.replace(with: Data("[]".utf8)) {
                    let name = try #require(FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                        .first(where: { $0.hasPrefix(".projects-") }))
                    let file = fixture.root.appendingPathComponent(name)
                    temporary = file
                    try FileManager.default.moveItem(at: file, to: fixture.root.appendingPathComponent("moved-temporary"))
                    if symbolicLink {
                        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
                    } else {
                        try replacement.write(to: file)
                    }
                }
            }
        }
        #expect(try Data(contentsOf: fixture.file) == original)
        let temporaryURL = try #require(temporary)
        #expect(try Data(contentsOf: temporaryURL) == replacement)
        #expect(try Data(contentsOf: target) == replacement)
    }

    @Test("Short writes and EINTR preserve every byte; zero progress and other errors fail")
    func shortWrites() throws {
        let data = Data("catalog bytes".utf8)
        var actual = Data()
        var calls = 0
        try CatalogWriteCoordinator.writeAll(data, descriptor: -1) { _, bytes, count in
            calls += 1
            if calls == 2 { errno = EINTR; return -1 }
            let written = min(3, count)
            actual.append(bytes.assumingMemoryBound(to: UInt8.self), count: written)
            return written
        }
        #expect(actual == data)
        #expect(calls > 2)
        #expect(throws: NSError.self) { try CatalogWriteCoordinator.writeAll(data, descriptor: -1) { _, _, _ in 0 } }
        #expect(throws: NSError.self) {
            try CatalogWriteCoordinator.writeAll(data, descriptor: -1) { _, _, _ in errno = ENOSPC; return -1 }
        }
    }

    @Test("New catalog files are private and existing directory permissions stay unchanged")
    func privateCreation() throws {
        let fixture = WriterFixture()
        defer { fixture.remove() }
        let persistence = CatalogPersistence(directory: fixture.root)
        try persistence.save([])
        for (url, expected) in [(fixture.root, 0o700), (fixture.file, 0o600), (fixture.lock, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == expected)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: fixture.root.path)
        try persistence.save([fixture.project("Private")])
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o750)
    }

    @Test("macOS tmp aliases coordinate on the same sidecar inode")
    func temporaryDirectoryAlias() throws {
        // Both paths are synthetic and point at one macOS-owned /tmp alias.
        let fixture = WriterFixture(root: URL(fileURLWithPath: "/tmp/MoeKit-writer-\(UUID().uuidString)"))
        defer { fixture.remove() }
        try fixture.createRoot()
        let canonical = fixture.root.resolvingSymlinksInPath()
        let other = CatalogPersistence(directory: canonical)
        #expect(try other.load().isEmpty)
        try CatalogWriteCoordinator.withExclusiveAccess(at: fixture.root) { _ in
            #expect(throws: CatalogPersistence.CatalogError.writerBusy) { try other.save([]) }
        }
        try other.save([])
        #expect(try CatalogPersistence(directory: fixture.root).load().isEmpty)
    }
}

private struct WriterFixture {
    var root = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-writer-\(UUID().uuidString)")
    var file: URL { root.appendingPathComponent("projects.json") }
    var lock: URL { root.appendingPathComponent("projects.json.lock") }
    func project(_ name: String) -> ProjectRecord {
        ProjectRecord(name: name, path: root.appendingPathComponent(name).path, kind: .folder)
    }
    func createRoot() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func identity(_ url: URL) throws -> String {
        var status = stat()
        guard url.withUnsafeFileSystemRepresentation({ Darwin.lstat($0!, &status) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return "\(status.st_dev):\(status.st_ino)"
    }
}
