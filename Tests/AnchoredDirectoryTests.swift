import Foundation
import Darwin
import Testing
@testable import MoeKit

@Suite("Pinned directory reads")
struct AnchoredDirectoryTests {
    @Test("Pinned roots and their ancestors cannot switch to replacement content", arguments: [false, true])
    func replacedRoot(aboveRoot: Bool) throws {
        let fixture = try AnchorFixture()
        defer { fixture.remove() }
        let root = try fixture.directory("parent/selected")
        try fixture.write("parent/selected/value", "selected")
        try fixture.write("outside/selected/value", "outside")
        let anchor = try AnchoredDirectory.selected(root)
        let replaced = aboveRoot ? root.deletingLastPathComponent() : root
        let target = fixture.root.appendingPathComponent(aboveRoot ? "outside" : "outside/selected")
        try FileManager.default.moveItem(at: replaced, to: fixture.root.appendingPathComponent("old"))
        try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: target)

        #expect(throws: AnchoredDirectory.AccessError.changed) { try anchor.readFile("value", maximumBytes: 100) }
        #expect(try String(contentsOf: target.appendingPathComponent(aboveRoot ? "selected/value" : "value"), encoding: .utf8) == "outside")
    }

    @Test("A directory replaced after opening cannot redirect the final file open", arguments: [false, true])
    func replacedMetadataAncestor(symbolic: Bool) throws {
        let fixture = try AnchorFixture()
        defer { fixture.remove() }
        try fixture.write("selected/metadata/value", "selected")
        try fixture.write("outside/value", "outside")
        let root = try AnchoredDirectory.selected(fixture.root.appendingPathComponent("selected"))
        let metadata = try root.openDirectory("metadata")
        #expect(throws: AnchoredDirectory.AccessError.changed) {
            try metadata.readFile("value", maximumBytes: 100) {
                let old = fixture.root.appendingPathComponent("selected/metadata")
                try FileManager.default.moveItem(at: old, to: fixture.root.appendingPathComponent("old"))
                if symbolic {
                    try FileManager.default.createSymbolicLink(at: old, withDestinationURL: fixture.root.appendingPathComponent("outside"))
                } else {
                    try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("outside"), to: old)
                }
            }
        }
    }

    @Test("Pinned enumeration rejects a root renamed and replaced during the scan")
    func replacedEnumerationRoot() throws {
        let fixture = try AnchorFixture()
        defer { fixture.remove() }
        try fixture.write("selected/inside", "fixture")
        try fixture.write("outside/private-name", "fixture")
        let selected = fixture.root.appendingPathComponent("selected")
        let anchor = try AnchoredDirectory.selected(selected)
        let entries = try anchor.entries()
        try FileManager.default.moveItem(at: selected, to: fixture.root.appendingPathComponent("old"))
        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("outside"), to: selected)
        #expect(throws: AnchoredDirectory.AccessError.changed) { try entries.next() }
    }

    @Test("A final FIFO or symbolic-link replacement remains nonblocking and unread", arguments: [false, true])
    func finalReplacement(symbolic: Bool) throws {
        let fixture = try AnchorFixture()
        defer { fixture.remove() }
        try fixture.write("selected/value", "inside")
        try fixture.write("outside", "outside")
        let anchor = try AnchoredDirectory.selected(fixture.root.appendingPathComponent("selected"))
        let expected: BoundedRegularFileReader.ReadError = symbolic ? .symbolicLink : .notRegularFile
        #expect(throws: expected) {
            try anchor.readFile("value", maximumBytes: 100) {
                let file = fixture.root.appendingPathComponent("selected/value")
                try FileManager.default.removeItem(at: file)
                if symbolic {
                    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.root.appendingPathComponent("outside"))
                } else {
                    guard file.withUnsafeFileSystemRepresentation({ Darwin.mkfifo($0!, 0o600) }) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
            }
        }
    }

    @Test("A directory URL trailing slash cannot hide a selected final symlink", arguments: [false, true])
    func selectedSymbolicDirectoryURL(directoryURL: Bool) throws {
        let fixture = try AnchorFixture()
        defer { fixture.remove() }
        let target = try fixture.directory("target")
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: AnchoredDirectory.AccessError.notDirectory) {
            try AnchoredDirectory.selected(URL(fileURLWithPath: link.path, isDirectory: directoryURL))
        }
    }

    @Test("Dot, parent, slash and NUL components never reach relative opens", arguments: ["", ".", "..", "child/other", "nul\u{0}suffix"])
    func invalidComponents(name: String) throws {
        let fixture = try AnchorFixture()
        defer { fixture.remove() }
        let anchor = try AnchoredDirectory.selected(fixture.root)
        #expect(throws: AnchoredDirectory.AccessError.invalidComponent) { try anchor.openDirectory(name) }
        #expect(throws: AnchoredDirectory.AccessError.invalidComponent) { try anchor.readFile(name, maximumBytes: 100) }
    }

    @Test("All directory handles and streams share a cap and release ownership")
    func descriptorBudget() throws {
        let fixture = try AnchorFixture()
        defer { fixture.remove() }
        let budget = AnchoredDirectory.Budget()
        var anchor: AnchoredDirectory? = try AnchoredDirectory.selected(fixture.root, budget: budget)
        var entries: [AnchoredDirectory.Entries] = []
        let remaining = AnchoredDirectory.Budget.maximumDescriptors - budget.openDescriptors
        for _ in 0..<remaining { entries.append(try #require(anchor).entries()) }
        #expect(budget.openDescriptors == AnchoredDirectory.Budget.maximumDescriptors)
        #expect(throws: AnchoredDirectory.AccessError.descriptorLimit) { try #require(anchor).entries() }
        entries.removeAll()
        anchor = nil
        #expect(budget.openDescriptors == 0)
    }

    @Test("Cancellation after pinning releases the chain and does not read")
    func cancelledPinnedRead() async throws {
        let fixture = try AnchorFixture()
        defer { fixture.remove() }
        try fixture.write("value", "fixture")
        let task = Task {
            let budget = AnchoredDirectory.Budget()
            do {
                let anchor = try AnchoredDirectory.selected(fixture.root, budget: budget)
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try anchor.readFile("value", maximumBytes: 100)
            } catch {
                #expect(budget.openDescriptors == 0)
                throw error
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private struct AnchorFixture: Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-anchor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func write(_ path: String, _ value: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
