import Foundation
import Darwin
import Testing
@testable import MoeKit

struct CatalogPersistenceTests {
    @Test("A missing catalog starts empty")
    func missingCatalog() throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        #expect(try fixture.persistence().load().isEmpty)
    }

    @Test("Project metadata round trips without touching its project directory")
    func roundTrip() throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        let persistence = fixture.persistence()
        let project = fixture.project()
        try persistence.save([project])
        #expect(try persistence.load() == [project])
        #expect(!FileManager.default.fileExists(atPath: project.path))
        var changed = project
        changed.isPinned = false
        try persistence.save([changed])
        #expect(try fixture.persistence().load() == [changed])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["projects.json"])
    }

    @Test("Corrupt, truncated and unsupported future catalogs are never replaced", arguments: [
        "bad json", "", "[", "[{\"id\":", "{\"version\":999,\"projects\":[]}"
    ])
    func malformedCatalog(bytes: String) throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        let original = Data(bytes.utf8)
        try fixture.write(original)
        let persistence = fixture.persistence()
        #expect(throws: DecodingError.self) { try persistence.load() }
        #expect(throws: CatalogPersistence.CatalogError.recoveryRequired) { try persistence.save([]) }
        // A fresh persistence object cannot bypass recovery by saving first.
        #expect(throws: DecodingError.self) { try fixture.persistence().save([]) }
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test("Unknown project and nested metadata fields are preserved for a newer reader", arguments: [false, true])
    func futureFields(nested: Bool) throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.project())) as? [String: Any])
        if nested {
            object["gitMetadata"] = ["observedAt": 0, "gitDirectoryPath": "/fixture/.git",
                "commonDirectoryPath": "/fixture/.git", "isLinkedWorktree": false, "isLocked": false,
                "futureMetadata": "must be preserved"]
        } else {
            object["futureSetting"] = "must be preserved"
        }
        let bytes = try JSONSerialization.data(withJSONObject: [object])
        try fixture.write(bytes)
        let persistence = fixture.persistence()
        #expect(throws: CatalogPersistence.CatalogError.unsupportedFields) { try persistence.load() }
        #expect(throws: CatalogPersistence.CatalogError.recoveryRequired) { try persistence.save([]) }
        #expect(try Data(contentsOf: fixture.file) == bytes)
    }

    @Test("Duplicate IDs, normalized paths and hidden invalid relationships fail without repair", arguments: 0..<8)
    func invalidRecords(variant: Int) throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        let first = fixture.project()
        var second = ProjectRecord(name: "Second", path: first.path + "-second", kind: .folder)
        switch variant {
        case 0: second = ProjectRecord(id: first.id, name: "Duplicate ID", path: second.path, kind: .folder)
        case 1: second.path = first.path + "/child/.."
        case 2: second.path = "relative/project"
        case 3: second.parentID = UUID()
        case 4: second.parentID = second.id
        case 5: second.demoChangeCount = 0
        case 6: second.demoUnavailable = true
        default: second.kind = .group
        }
        let original = try JSONEncoder().encode([first, second])
        try fixture.write(original)
        let persistence = fixture.persistence()
        #expect(throws: CatalogPersistence.CatalogError.invalidRecords) { try persistence.load() }
        #expect(throws: CatalogPersistence.CatalogError.recoveryRequired) { try persistence.save([first]) }
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test("External replacement or removal after load cannot lose saved pins", arguments: 0..<4)
    func changedAfterLoad(variant: Int) throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        let persistence = fixture.persistence()
        let project = fixture.project()
        try persistence.save([project])
        switch variant {
        case 0: try fixture.write(Data("[".utf8))
        case 1: try fixture.write(Data("{\"version\":999,\"projects\":[]}".utf8))
        case 2: try fixture.write(try JSONEncoder().encode([project, ProjectRecord(name: "Other window", path: project.path + "-other", kind: .folder)]))
        default: try FileManager.default.removeItem(at: fixture.file)
        }
        let expected = try? Data(contentsOf: fixture.file)
        #expect(throws: CatalogPersistence.CatalogError.changedSinceLoad) { try persistence.save([]) }
        #expect((try? Data(contentsOf: fixture.file)) == expected)
    }

    @Test("A catalog appearing after an empty load is not overwritten")
    func appearedAfterLoad() throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        let persistence = fixture.persistence()
        #expect(try persistence.load().isEmpty)
        let original = try JSONEncoder().encode([fixture.project()])
        try fixture.write(original)
        #expect(throws: CatalogPersistence.CatalogError.changedSinceLoad) { try persistence.save([]) }
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test("FIFO and symbolic-link catalogs fail without blocking or following their targets", arguments: 0..<3)
    func notRegular(variant: Int) throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let target = fixture.root.appendingPathComponent("target")
        let bytes = try JSONEncoder().encode([fixture.project()])
        if variant == 0 {
            #expect(fixture.file.withUnsafeFileSystemRepresentation { Darwin.mkfifo($0!, 0o600) } == 0)
        } else {
            if variant == 1 { try bytes.write(to: target) }
            try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
        }
        let persistence = fixture.persistence()
        let expected: BoundedRegularFileReader.ReadError = variant == 0 ? .notRegularFile : .symbolicLink
        #expect(throws: expected) { try persistence.load() }
        #expect(throws: CatalogPersistence.CatalogError.recoveryRequired) { try persistence.save([]) }
        if variant == 1 { #expect(try Data(contentsOf: target) == bytes) }
        if variant == 2 { #expect(!FileManager.default.fileExists(atPath: target.path)) }
    }

    @Test("Oversized sparse catalogs are rejected without reading their full length")
    func oversizedCatalog() throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        try fixture.write(Data())
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.truncate(atOffset: UInt64(CatalogPersistence.maximumBytes + 1))
        try handle.close()
        let persistence = fixture.persistence()
        #expect(throws: BoundedRegularFileReader.ReadError.tooLarge) { try persistence.load() }
        #expect(throws: CatalogPersistence.CatalogError.recoveryRequired) { try persistence.save([]) }
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect((attributes[.size] as? NSNumber)?.intValue == CatalogPersistence.maximumBytes + 1)
    }

    @Test("A failed atomic write preserves the original and can be retried", arguments: [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError])
    func failedWrite(code: Int) throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        let project = fixture.project()
        let original = try JSONEncoder().encode([project])
        try fixture.write(original)
        var fails = true
        let persistence = CatalogPersistence(directory: fixture.root) { data, url in
            if fails { throw NSError(domain: NSCocoaErrorDomain, code: code) }
            try data.write(to: url, options: .atomic)
        }
        #expect(try persistence.load() == [project])
        var updated = project
        updated.isPinned = false
        #expect(throws: NSError.self) { try persistence.save([updated]) }
        #expect(try Data(contentsOf: fixture.file) == original)
        fails = false
        try persistence.save([updated])
        #expect(try fixture.persistence().load() == [updated])
    }

    @Test("Read-only fixture directories report real atomic-write failures")
    func readOnlyDirectory() throws {
        // The native CI runner is unprivileged; root can bypass mode restrictions.
        guard Darwin.geteuid() != 0 else { return }
        let fixture = CatalogFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
            fixture.remove()
        }
        let persistence = fixture.persistence()
        let project = fixture.project()
        try persistence.save([project])
        let original = try Data(contentsOf: fixture.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path)
        #expect(throws: NSError.self) { try persistence.save([]) }
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test("Access-denied catalogs do not become an empty successful load")
    func unreadableCatalog() throws {
        guard Darwin.geteuid() != 0 else { return }
        let fixture = CatalogFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
            fixture.remove()
        }
        let original = try JSONEncoder().encode([fixture.project()])
        try fixture.write(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.file.path)
        let persistence = fixture.persistence()
        #expect(throws: NSError.self) { try persistence.load() }
        #expect(throws: CatalogPersistence.CatalogError.recoveryRequired) { try persistence.save([]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        #expect(try Data(contentsOf: fixture.file) == original)
    }
}

private struct CatalogFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-catalog-\(UUID().uuidString)")
    var file: URL { root.appendingPathComponent("projects.json") }
    func persistence() -> CatalogPersistence { CatalogPersistence(directory: root) }
    func project() -> ProjectRecord {
        ProjectRecord(name: "Custom name", path: root.appendingPathComponent("not-created-project").path,
                      kind: .folder, lastOpened: Date(timeIntervalSince1970: 50), isPinned: true)
    }
    func write(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
