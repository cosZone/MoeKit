import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Git cleanup bounded inspection")
struct GitCleanupInspectionTests {
    @Test("Local branch components preserve ordinary nested names", arguments: ["feature", "fix/issue-42", "topic/日本語", "feature_name"])
    func validBranchNames(_ branch: String) throws {
        #expect(try GitCleanupInspection.branchComponents(branch).joined(separator: "/") == branch)
    }

    @Test("Ref syntax, traversal and unbounded branch names fail closed", arguments: [
        "", "HEAD", "/feature", "feature/", "feature//topic", ".hidden", "-option", "feature/.hidden",
        "feature/-option", "feature.lock", "feature/topic.lock", "feature.", "a..b", "a@{1}",
        "a\\b", "a b", "a\tb", "a\nb", "a\u{7f}b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b",
        String(repeating: "a", count: 201), Array(repeating: "a", count: 13).joined(separator: "/")
    ])
    func invalidBranchNames(_ branch: String) {
        #expect(throws: GitCleanupFailure.unsupported) { try GitCleanupInspection.branchComponents(branch) }
    }

    @Test("Only a newline-terminated, lowercase, nonzero SHA-1 ref is accepted")
    func objectIDFraming() throws {
        let value = "0123456789abcdef0123456789abcdef01234567"
        #expect(try GitCleanupInspection.oid(Data((value + "\n").utf8)) == value)
        let invalid: [Data?] = [nil, Data(), Data(value.utf8), Data((value + "\r\n").utf8),
            Data((value.uppercased() + "\n").utf8), Data((String(repeating: "0", count: 40) + "\n").utf8),
            Data((String(repeating: "g", count: 40) + "\n").utf8), Data((value + "\nextra").utf8), Data([0xff])]
        for data in invalid {
            #expect(throws: GitCleanupFailure.unsupported) { try GitCleanupInspection.oid(data) }
        }
        #expect(GitCleanupInspection.blobOID(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    @Test("Conventional repository config and inert remote metadata are readable")
    func ordinaryConfiguration() throws {
        try GitCleanupInspection.strictConfig(Data("""
        # Fixture-only configuration
        [core]
            repositoryformatversion = 0
            filemode = true
            bare = false
            logallrefupdates = true
            ignorecase = true
            precomposeunicode = true
            autocrlf = false
            symlinks = true
        [remote "origin"]
            url = https://invalid.example/never-contacted.git
            fetch = +refs/heads/*:refs/remotes/origin/*
        [branch "feature"]
            remote = origin
            merge = refs/heads/feature
        """.utf8))
    }

    @Test("Executable, include, alternate-format and malformed configuration is unsupported", arguments: [
        "[include]\npath = /never/read\n", "[includeIf \"gitdir:/never/\"]\npath = /never/read\n",
        "[filter \"fixture\"]\nclean = do-not-run\n", "[extensions]\nobjectformat = sha256\n",
        "[core]\nrepositoryformatversion = 1\n", "[core]\nbare = true\n", "[core]\nautocrlf = true\n",
        "[core]\nhooksPath = /never/run\n", "[core]\nfsmonitor = do-not-run\n",
        "[core]\nworktree = /elsewhere\n", "[core]\nattributesFile = /never/read\n",
        "[core]\nunknown = true\n", "[remote \"origin\"]\npromisor = true\n",
        "[remote \"origin\"]\npartialclonefilter = blob:none\n", "bare = false\n",
        "[core\nfilemode = true\n", "[core]\nfilemode\n", "[core]\nfilemode = true\\\n"
    ])
    func unsupportedConfiguration(_ config: String) {
        #expect(throws: GitCleanupFailure.unsupported) { try GitCleanupInspection.strictConfig(Data(config.utf8)) }
    }

    @Test("Config presence, UTF-8 and byte budget are required")
    func configurationBudgets() {
        let invalid: [Data?] = [nil, Data([0xff]), Data(repeating: 32, count: 128 * 1_024 + 1)]
        for data in invalid {
            #expect(throws: GitCleanupFailure.unsupported) { try GitCleanupInspection.strictConfig(data) }
        }
    }

    @Test("The isolated helper accepts the Apple Git security baseline or a newer supported version", arguments: [
        "git version 2.39.5 (Apple Git-154)\n", "git version 2.39.6 (Apple Git-154)\n",
        "git version 2.40.0 (Apple Git-155)\n", "git version 2.50.1 (Apple Git-160)\n"
    ])
    func supportedAppleGitVersion(_ text: String) throws {
        #expect(try GitObjectSnapshot.validateVersion(Data(text.utf8)) == String(text.dropLast()))
    }

    @Test("Old, non-Apple, malformed and multi-line Git versions fail closed", arguments: [
        "", "git version 2.39.4 (Apple Git-154)\n", "git version 2.38.9 (Apple Git-200)\n",
        "git version 2.40.0 (Apple Git-153)\n", "git version 2.39.5\n", "git version 2.50.1 (Homebrew)\n",
        "git version 3.0.0 (Apple Git-200)\n", "git version 2.39 (Apple Git-154)\n",
        "git version 2.39.5 (Apple Git-154)", "git version 2.39.5 (Apple Git-154)\r\n",
        "git version 2.39.5 (Apple Git-154)\nextra\n", "git version 2.39.5 (Apple Git-154)\n\n",
        "prefix git version 2.39.5 (Apple Git-154)\n", "git version 2.39.5 (Apple Git-154) suffix\n",
        "git version 2.999999999999999999999999999999.0 (Apple Git-154)\n"
    ])
    func unsupportedGitVersion(_ text: String) {
        #expect(throws: GitCleanupFailure.helper) { try GitObjectSnapshot.validateVersion(Data(text.utf8)) }
    }

    @Test("Git version output has a strict byte limit and must decode as UTF-8")
    func gitVersionEncodingBudget() {
        for data in [Data([0xff]), Data(repeating: 97, count: 129)] {
            #expect(throws: GitCleanupFailure.helper) { try GitObjectSnapshot.validateVersion(data) }
        }
    }

    @Test("Scope membership uses path components rather than a string prefix")
    func scopeComponents() {
        let root = URL(fileURLWithPath: "/fixture/project")
        #expect(GitCleanupInspection.within(root.appendingPathComponent("child"), scope: root))
        #expect(!GitCleanupInspection.within(URL(fileURLWithPath: "/fixture/project-other"), scope: root))
        #expect(!GitCleanupInspection.within(URL(fileURLWithPath: "/fixture"), scope: root))
    }

    private func fixture() throws -> URL {
        let parent = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)
        let root = parent.appendingPathComponent("MoeKit-GitCapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test("Capture keeps exact bytes and skipped names apply only at its root")
    func captureContentsAndFingerprint() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("root metadata".utf8).write(to: root.appendingPathComponent("skip"))
        try Data("nested data".utf8).write(to: root.appendingPathComponent("nested/skip"))
        let anchor = try InstallerDirectoryAnchor.open(root)
        let first = GitCleanupCapture(); try first.collect(anchor, skip: ["skip"])
        #expect(Set(first.files.keys) == ["nested/skip"])
        #expect(Set(first.directories.keys) == ["", "nested"])
        #expect(first.files["nested/skip"]?.data == Data("nested data".utf8))
        #expect(first.bytes == Data("nested data".utf8).count)
        let second = GitCleanupCapture(); try second.collect(anchor, skip: ["skip"])
        #expect(second.fingerprint == first.fingerprint)
        try Data("changed data".utf8).write(to: root.appendingPathComponent("nested/skip"))
        let third = GitCleanupCapture(); try third.collect(anchor, skip: ["skip"])
        #expect(third.fingerprint != first.fingerprint)
        #expect(try Data(contentsOf: root.appendingPathComponent("skip")) == Data("root metadata".utf8))
    }

    @Test("Capture refuses symlinks, hardlinks, writable entries and special files", arguments: 0..<5)
    func unsafeCaptureEntries(_ variant: Int) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("sentinel")
        let entry = root.appendingPathComponent("entry")
        let data = Data("must remain unchanged".utf8)
        try data.write(to: sentinel)
        switch variant {
        case 0: try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: sentinel)
        case 1: try FileManager.default.linkItem(at: sentinel, to: entry)
        case 2:
            try Data("unsafe".utf8).write(to: entry)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: entry.path)
        case 3:
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: entry.path)
        default: try #require(mkfifo(entry.path, 0o600) == 0)
        }
        let anchor = try InstallerDirectoryAnchor.open(root)
        #expect(throws: (any Error).self) { try GitCleanupCapture().collect(anchor) }
        #expect(try Data(contentsOf: sentinel) == data)
    }

    @Test("Capture enforces directory depth before traversal can escape its budget")
    func captureDepthBudget() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var child = root
        for _ in 0..<48 {
            child.appendPathComponent("nested")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let anchor = try InstallerDirectoryAnchor.open(root)
        #expect(throws: GitCleanupFailure.budget) { try GitCleanupCapture().collect(anchor) }
    }

    @Test("Unexpected files fail before reading and total capture bytes have a small testable budget")
    func captureAllowlistAndByteBudget() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("unexpected")
        try Data("12345".utf8).write(to: file, options: .withoutOverwriting)
        let anchor = try InstallerDirectoryAnchor.open(root)
        #expect(throws: GitCleanupFailure.dirty) { try GitCleanupCapture(allowedFiles: []).collect(anchor) }
        #expect(throws: GitCleanupFailure.budget) { try GitCleanupCapture(maximumBytes: 4).collect(anchor) }
        let captured = GitCleanupCapture(maximumBytes: 5, allowedFiles: ["unexpected"])
        try captured.collect(anchor)
        #expect(captured.bytes == 5)
    }

    @Test("Cancellation stops capture before reading a fixture")
    func cancelledCapture() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try GitCleanupCapture().collect(InstallerDirectoryAnchor.open(root))
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }

    @Test("Nested file and directory ACL write grants are rejected despite private POSIX modes", arguments: [false, true])
    func nestedACL(_ directory: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("nested")
        if directory { try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        else { try Data("retained".utf8).write(to: child) }
        let fd = open(child.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0); defer { close(fd) }
        let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::allow:write\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0)
        #expect(throws: (any Error).self) { try GitCleanupCapture().collect(InstallerDirectoryAnchor.open(root)) }
    }
}
