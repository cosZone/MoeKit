import Foundation
import Testing
@testable import MoeKit

@Suite("Read-only repository discovery")
struct RepositoryScannerTests {
    @Test("Defaults keep scans shallow and bounded")
    func defaultOptions() {
        let options = ScanOptions()
        #expect(options.maxDepth == 4)
        #expect(options.maxDirectories == 2_000)
        #expect(!options.includeHidden)
        #expect(RepositoryScanner.maximumMetadataBytes == 16_384)
    }

    @Test("Finds Git repositories and branch names without invoking Git")
    func findsRepository() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let project = try fixture.repository("projects/hello", head: "ref: refs/heads/feature/native-shell\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.count == 1)
        #expect(result.items.first?.url == project)
        #expect(result.items.first?.id == project.path)
        #expect(result.items.first?.name == "hello")
        #expect(result.items.first?.kind == .gitRepository)
        #expect(result.items.first?.branch == "feature/native-shell")
        #expect(result.visitedDirectories == 3)
        #expect(result.issues.isEmpty)
        #expect(!result.wasLimited)
    }

    @Test("A root repository is included and its descendants are not scanned")
    func rootRepositoryStopsDescent() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        _ = try fixture.repository(".")
        _ = try fixture.repository("nested/another")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.map { $0.url.path } == [fixture.root.path])
        #expect(result.items.map(\.id) == [fixture.root.path])
        #expect(result.visitedDirectories == 1)
        #expect(result.issues.isEmpty)
        #expect(!result.wasLimited)
    }

    @Test("An inner repository does not leak through a discovered outer repository")
    func nestedRepositoryStopsDescent() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let outer = try fixture.repository("outer")
        _ = try fixture.repository("outer/nested")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.map(\.url) == [outer])
        #expect(result.visitedDirectories == 2)
    }

    @Test("A plain folder is only added by explicit inspection")
    func explicitFolder() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let scanner = RepositoryScanner()

        let discovery = try await scanner.scan(root: fixture.root)
        let selection = try await scanner.inspectFolder(fixture.root)

        #expect(discovery.items.isEmpty)
        #expect(discovery.issues.isEmpty)
        #expect(selection.items.count == 1)
        #expect(selection.items.first?.kind == .folder)
        #expect(selection.items.first?.url.path == fixture.root.path)
        #expect(selection.items.first?.id == fixture.root.path)
        #expect(selection.items.first?.branch == nil)
        #expect(selection.visitedDirectories == 1)
    }

    @Test("Reads an in-scope linked-worktree pointer")
    func inScopeWorktree() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        try fixture.write("work/.git", text: "gitdir: ../metadata/work\n")
        try fixture.write("metadata/work/HEAD", text: "ref: refs/heads/worktree-topic\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.count == 1)
        #expect(result.items.first?.kind == .gitWorktree)
        #expect(result.items.first?.branch == "worktree-topic")
        #expect(result.issues.isEmpty)
    }

    @Test("Does not read a worktree target outside the selected folder")
    func outsideScopeWorktree() async throws {
        let fixture = try ScannerFixture()
        let outside = try ScannerFixture()
        defer { fixture.remove(); outside.remove() }
        try outside.write("metadata/HEAD", text: "ref: refs/heads/must-not-be-read\n")
        try fixture.write("work/.git", text: "gitdir: \(outside.root.path)/metadata\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.count == 1)
        #expect(result.items.first?.kind == .gitWorktree)
        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .outsideScope })
    }

    @Test("Path-prefix siblings are outside scope")
    func siblingWithMatchingStringPrefixIsOutsideScope() async throws {
        let fixture = try ScannerFixture()
        let sibling = URL(fileURLWithPath: fixture.root.path + "-outside", isDirectory: true)
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: sibling)
        }
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("ref: refs/heads/private\n".utf8).write(to: sibling.appendingPathComponent("HEAD"))
        try fixture.write("work/.git", text: "gitdir: \(sibling.path)\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .outsideScope })
    }

    @Test("A normalized relative pointer may stay inside scope")
    func relativePointerNormalization() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        try fixture.write("work/.git", text: "gitdir: ../metadata/unused/../actual\n")
        _ = try fixture.folder("metadata/unused")
        try fixture.write("metadata/actual/HEAD", text: "ref: refs/heads/normalized\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.first?.branch == "normalized")
        #expect(result.issues.isEmpty)
    }

    @Test("Does not follow symbolic-link folders, including cycles")
    func skipsSymbolicLinkDirectories() async throws {
        let fixture = try ScannerFixture()
        let outside = try ScannerFixture()
        defer { fixture.remove(); outside.remove() }
        let real = try fixture.repository("real")
        _ = try outside.repository("external")
        try fixture.link("duplicate", to: real)
        try fixture.link("outside", to: outside.root)
        try fixture.link("cycle", to: fixture.root)

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.map(\.url) == [real])
        #expect(result.visitedDirectories == 2)
        #expect(!result.wasLimited)
    }

    @Test("Rejects a selected symbolic-link root")
    func rejectsSymbolicLinkRoot() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let real = try fixture.folder("real")
        let link = try fixture.link("link", to: real)

        await #expect(throws: RepositoryScannerError.self) {
            try await RepositoryScanner().scan(root: link)
        }
    }

    @Test("Does not follow a symbolic-link .git marker")
    func skipsSymbolicGitMarker() async throws {
        let fixture = try ScannerFixture()
        let outside = try ScannerFixture()
        defer { fixture.remove(); outside.remove() }
        try outside.write("metadata/HEAD", text: "ref: refs/heads/private\n")
        try fixture.link("project/.git", to: outside.root.appendingPathComponent("metadata"))

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.isEmpty)
        #expect(result.issues.contains { $0.kind == .symbolicLinkSkipped })
    }

    @Test("Does not follow a symbolic-link HEAD")
    func skipsSymbolicHead() async throws {
        let fixture = try ScannerFixture()
        let outside = try ScannerFixture()
        defer { fixture.remove(); outside.remove() }
        try outside.write("private-head", text: "ref: refs/heads/private\n")
        try fixture.link("project/.git/HEAD", to: outside.root.appendingPathComponent("private-head"))

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.count == 1)
        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .symbolicLinkSkipped })
    }

    @Test("Does not follow an in-scope worktree pointer through a symbolic-link ancestor")
    func skipsSymbolicPointerAncestor() async throws {
        let fixture = try ScannerFixture()
        let outside = try ScannerFixture()
        defer { fixture.remove(); outside.remove() }
        try outside.write("metadata/HEAD", text: "ref: refs/heads/private\n")
        try fixture.link("metadata-link", to: outside.root)
        try fixture.write("work/.git", text: "gitdir: ../metadata-link/metadata\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .symbolicLinkSkipped })
    }

    @Test("An in-scope symlink target is still refused rather than silently normalized")
    func skipsInScopeSymbolicPointerAncestor() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        try fixture.write("metadata/actual/HEAD", text: "ref: refs/heads/must-not-be-read\n")
        try fixture.link("metadata-link", to: fixture.root.appendingPathComponent("metadata"))
        try fixture.write("work/.git", text: "gitdir: ../metadata-link/actual\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.count == 1)
        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .symbolicLinkSkipped })
    }

    @Test("A symlink preceding dot-dot cannot be erased before the safety check")
    func skipsSymbolicComponentBeforeParentTraversal() async throws {
        let fixture = try ScannerFixture()
        let outside = try ScannerFixture()
        defer { fixture.remove(); outside.remove() }
        try fixture.write("metadata/HEAD", text: "ref: refs/heads/must-not-be-read\n")
        try fixture.link("metadata-link", to: outside.root)
        try fixture.write("work/.git", text: "gitdir: ../metadata-link/../metadata\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.count == 1)
        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .symbolicLinkSkipped })
    }

    @Test("An absolute in-scope pointer also rejects symlink ancestors")
    func skipsAbsoluteSymbolicPointerAncestor() async throws {
        let fixture = try ScannerFixture()
        let outside = try ScannerFixture()
        defer { fixture.remove(); outside.remove() }
        try outside.write("metadata/HEAD", text: "ref: refs/heads/private\n")
        try fixture.link("metadata-link", to: outside.root)
        try fixture.write("work/.git", text: "gitdir: \(fixture.root.path)/metadata-link/metadata\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .symbolicLinkSkipped })
    }

    @Test("Depth zero includes the root but reports skipped eligible descendants")
    func depthLimit() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        _ = try fixture.repository("deeper/repository")

        let result = try await RepositoryScanner().scan(root: fixture.root, options: ScanOptions(maxDepth: 0))

        #expect(result.items.isEmpty)
        #expect(result.visitedDirectories == 1)
        #expect(result.wasLimited)
        #expect(result.issues.contains { $0.kind == .depthLimit })
    }

    @Test("An empty root at the depth boundary is complete")
    func emptyFolderIsNotLimited() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }

        let result = try await RepositoryScanner().scan(root: fixture.root, options: ScanOptions(maxDepth: 0))

        #expect(!result.wasLimited)
        #expect(result.issues.isEmpty)
    }

    @Test("Repositories exactly at the configured depth are included")
    func inclusiveDepthBoundary() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let repository = try fixture.repository("one/two")

        let result = try await RepositoryScanner().scan(root: fixture.root, options: ScanOptions(maxDepth: 2))

        #expect(result.items.map(\.url) == [repository])
        #expect(!result.wasLimited)
    }

    @Test("Directory limits produce an explicit partial result")
    func directoryLimit() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        _ = try fixture.repository("one")
        _ = try fixture.repository("two")

        let result = try await RepositoryScanner().scan(root: fixture.root, options: ScanOptions(maxDirectories: 2))

        #expect(result.visitedDirectories == 2)
        #expect(result.items.count == 1)
        #expect(result.wasLimited)
        #expect(result.issues.contains { $0.kind == .directoryLimit })
    }

    @Test("Hidden folders are opt-in")
    func hiddenFolders() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        _ = try fixture.repository(".hidden/project")
        _ = try fixture.repository("visible")
        let scanner = RepositoryScanner()

        let regular = try await scanner.scan(root: fixture.root)
        let hidden = try await scanner.scan(root: fixture.root, options: ScanOptions(includeHidden: true))

        #expect(regular.items.map(\.name) == ["visible"])
        #expect(Set(hidden.items.map(\.name)) == ["project", "visible"])
        #expect(!regular.wasLimited)
    }

    @Test("Dependency and build folders remain skipped when hidden folders are included")
    func skippedFolders() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let skipped = ["node_modules", ".build", "DerivedData", "build", "target", "dist", ".venv", "vendor"]
        for name in skipped {
            _ = try fixture.repository("\(name)/embedded")
        }
        let expected = try fixture.repository("application")

        let result = try await RepositoryScanner().scan(root: fixture.root, options: ScanOptions(includeHidden: true))

        #expect(result.items.map(\.url) == [expected])
        #expect(result.visitedDirectories == 2)
        #expect(!result.wasLimited)
    }

    @Test("Invalid UTF-8 HEAD produces an unknown branch and a warning")
    func invalidUTF8Head() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        try fixture.write("project/.git/HEAD", data: Data([0xFF, 0xFE, 0xFD]))

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.count == 1)
        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .invalidMetadata })
    }

    @Test("Oversized HEAD is not accepted or treated as clean metadata")
    func oversizedHead() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        try fixture.write("project/.git/HEAD", data: Data(repeating: 0x61, count: 16_385))

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .metadataTooLarge })
        #expect(!result.wasLimited)
    }

    @Test("The exact 16 KiB metadata bound is inclusive")
    func exactMetadataBound() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let prefix = "ref: refs/heads/"
        let branch = String(repeating: "a", count: 16_384 - prefix.utf8.count - 1)
        try fixture.write("project/.git/HEAD", text: prefix + branch + "\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.first?.branch == branch)
        #expect(result.issues.isEmpty)
    }

    @Test("Git pointer files receive the same size and encoding checks")
    func invalidPointerFiles() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        try fixture.write("oversized/.git", data: Data(repeating: 0x61, count: 16_385))
        try fixture.write("binary/.git", data: Data([0xFF, 0xFE]))
        try fixture.write("malformed/.git", text: "not a Git pointer\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.count == 3)
        #expect(result.items.allSatisfy { $0.branch == nil && $0.kind == .gitWorktree })
        #expect(result.issues.contains { $0.kind == .metadataTooLarge })
        #expect(result.issues.filter { $0.kind == .invalidMetadata }.count == 2)
    }

    @Test("HEAD references are never interpreted as filesystem paths")
    func arbitraryHeadReferenceIsRejected() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        _ = try fixture.repository("project", head: "ref: refs/heads/../../private\n")
        try fixture.write("private", text: "ref: refs/heads/must-not-be-read\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .invalidMetadata })
    }

    @Test("Detached HEAD is displayed without reading objects or references")
    func detachedHead() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        _ = try fixture.repository("project", head: String(repeating: "ab", count: 20) + "\n")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.first?.branch == "Detached @ abababa")
        #expect(result.issues.isEmpty)
    }

    @Test("A missing HEAD keeps the repository and reports unknown metadata")
    func missingHead() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        _ = try fixture.folder("project/.git")

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.count == 1)
        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .metadataUnreadable })
    }

    @Test("Explicit folder inspection preserves unreadable branch warnings")
    func inspectionPreservesIssues() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        _ = try fixture.folder(".git")

        let result = try await RepositoryScanner().inspectFolder(fixture.root)

        #expect(result.items.first?.kind == .gitRepository)
        #expect(result.items.first?.branch == nil)
        #expect(result.issues.contains { $0.kind == .metadataUnreadable })
    }

    @Test("Unreadable directories do not become successful empty results")
    func directoryPermissionFailure() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let blocked = try fixture.folder("blocked")
        _ = try fixture.repository("blocked/repository")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        // Root/privileged test runners can still read chmod(000) paths.
        guard !FileManager.default.isReadableFile(atPath: blocked.path) else { return }

        let result = try await RepositoryScanner().scan(root: fixture.root)

        #expect(result.items.isEmpty)
        #expect(result.issues.contains { $0.kind == .directoryUnreadable || $0.kind == .metadataUnreadable })
    }

    @Test("Invalid options and non-folder roots fail clearly")
    func invalidInputs() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        try fixture.write("file", text: "plain text")
        let scanner = RepositoryScanner()

        await #expect(throws: RepositoryScannerError.self) {
            try await scanner.scan(root: fixture.root, options: ScanOptions(maxDepth: -1))
        }
        await #expect(throws: RepositoryScannerError.self) {
            try await scanner.scan(root: fixture.root, options: ScanOptions(maxDirectories: 0))
        }
        await #expect(throws: RepositoryScannerError.self) {
            try await scanner.scan(root: fixture.root.appendingPathComponent("file"))
        }
        await #expect(throws: RepositoryScannerError.self) {
            try await scanner.scan(root: URL(string: "https://example.com/projects")!)
        }
    }

    @Test("A cancelled scan throws CancellationError instead of returning partial success")
    func cancellation() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        _ = try fixture.repository("project")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RepositoryScanner().scan(root: fixture.root)
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

private struct ScannerFixture: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoeKit-scanner-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func repository(_ relative: String, head: String = "ref: refs/heads/main\n") throws -> URL {
        let directory = try folder(relative)
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data(head.utf8).write(to: git.appendingPathComponent("HEAD"))
        return directory
    }

    func write(_ relative: String, text: String) throws {
        try write(relative, data: Data(text.utf8))
    }

    func write(_ relative: String, data: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @discardableResult
    func link(_ relative: String, to destination: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }
}
