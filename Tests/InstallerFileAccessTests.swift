import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Installer descriptor and durable journal boundaries", .serialized)
struct InstallerFileAccessTests {
    private func fixture() throws -> URL {
        let parent = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)
        let root = parent.appendingPathComponent("MoeKit-Installer-Guards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    @Test("Strict anchors reject a symbolic-link ancestor and keep sibling sentinel unchanged")
    func ancestorLinks() throws {
        let root = try fixture(), real = root.appendingPathComponent("real"), linkURL = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: real)
        #expect(throws: (any Error).self) { try InstallerDirectoryAnchor.open(linkURL) }
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        let old = try InstallerDirectoryAnchor.open(real)
        let moved = root.appendingPathComponent("retained-directory")
        try FileManager.default.moveItem(at: real, to: moved)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        #expect(throws: InstallerTrashFailure.changed) { try old.validate() }
        #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
    }
    @Test("Darwin ACL empty succeeds; a real extended entry refuses")
    func nativeACLPolarity() throws {
        let root = try fixture(), directory = try InstallerDirectoryAnchor.open(root)
        try InstallerFileAccess.validatePrivate(directory.fd, directory: true)
        // No ACL on disk is accepted only through a successful filesec query.
        // A synthetic empty ACL is valid and Darwin returns -1/EINVAL.
        let acl = try #require(acl_init(0))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        #expect(acl_valid(acl) == 0)
        var entry: acl_entry_t?
        errno = 0
        #expect(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1)
        #expect(errno == EINVAL)
        // Use the public text parser for a fixture-only harmless deny ACL.
        let nonempty = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::deny:delete\n"))
        defer { acl_free(UnsafeMutableRawPointer(nonempty)) }
        try #require(acl_set_fd_np(directory.fd, nonempty, ACL_TYPE_EXTENDED) == 0)
        #expect(throws: InstallerTrashFailure.unsafeRecovery) { try InstallerFileAccess.validatePrivate(directory.fd, directory: true) }
    }
    @Test("Mutation boundaries accept deny-only/read-only ACLs and reject write or delete-child grants")
    func mutationACLPolicy() throws {
        let root = try fixture(), directory = try InstallerDirectoryAnchor.open(root)
        let file = root.appendingPathComponent("owned.dmg")
        try Data("owned ACL fixture".utf8).write(to: file, options: .withoutOverwriting)
        let held = try InstallerFileDescriptor(parent: directory, name: file.lastPathComponent)
        for descriptor in [directory.fd, held.fd] {
            try InstallerFileAccess.rejectMutationGrantingACL(descriptor)
            for permissions in ["deny:delete", "allow:read,readattr,readextattr,readsecurity"] {
                let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::\(permissions)\n"))
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                try #require(acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0)
                try InstallerFileAccess.rejectMutationGrantingACL(descriptor)
            }
            for permissions in ["write", "append", "delete", "delete_child", "writeattr", "writeextattr", "writesecurity", "chown"] {
                let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::allow:\(permissions)\n"))
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                try #require(acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0)
                #expect(throws: InstallerTrashFailure.unsupported) { try InstallerFileAccess.rejectMutationGrantingACL(descriptor) }
            }
        }
        #expect(try Data(contentsOf: file) == Data("owned ACL fixture".utf8))
    }
    @Test("No-overwrite rename preserves both names")
    func exclusiveCollision() throws {
        let root = try fixture(), a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("first".utf8).write(to: a); try Data("second".utf8).write(to: b)
        let directory = try InstallerDirectoryAnchor.open(root)
        #expect(throws: InstallerTrashFailure.collision) { try InstallerFileAccess.exclusiveMove(from: directory, name: "a", to: directory, destinationName: "b") }
        #expect(try Data(contentsOf: a) == Data("first".utf8)); #expect(try Data(contentsOf: b) == Data("second".utf8))
    }
    @Test("Private storage lock is single-link and never replaced")
    func journalLockContention() throws {
        let root = try fixture(), recovery = root.appendingPathComponent("MoeKit/InstallerRecovery")
        let journal = try InstallerRecoveryJournal(rootURL: recovery, create: true, exclusive: true)
        try journal.validate()
        #expect(throws: InstallerTrashFailure.busy) { try InstallerRecoveryJournal(rootURL: recovery, create: true, exclusive: true) }
        #expect(try InstallerFileAccess.snapshotAt(journal.root.fd, "operations.lock").mode & 0o777 == 0o600)
    }
    @Test("Empty crash operation is visible and doesn't hide a valid peer")
    func incompleteRecoveryRows() throws {
        let root = try fixture(), recovery = root.appendingPathComponent("MoeKit/InstallerRecovery")
        let journal = try InstallerRecoveryJournal(rootURL: recovery, create: true, exclusive: true)
        let empty = UUID(), valid = UUID()
        _ = try journal.createOperation(empty)
        let op = try journal.createOperation(valid)
        let identity = op.identity
        let receipt = InstallerTrashReceipt(policy: InstallerTrashReceipt.policyVersion, id: valid, sequence: 0,
            originalURL: root.appendingPathComponent("owned.dmg"), originalParent: identity, originalFile: identity,
            operationURL: op.url, operationDirectory: identity, state: .captureIntent, recordedAt: Date(),
            payloadName: "owned.dmg", trashURL: nil, trashFile: nil)
        try journal.append(receipt, operation: op)
        let items = try journal.receipts()
        #expect(items.count == 2)
        #expect(items.first(where: { $0.id == empty })?.receipt == nil)
        #expect(items.first(where: { $0.id == empty })?.issue != nil)
        #expect(items.first(where: { $0.id == valid })?.receipt == receipt)
        // A torn latest state hides no older actionable state.
        try Data("{".utf8).write(to: op.url.appendingPathComponent("000001.json"))
        let after = try journal.receipts()
        #expect(after.first(where: { $0.id == valid })?.receipt == nil)
        #expect(FileManager.default.fileExists(atPath: op.url.appendingPathComponent("000000.json").path))
    }
    @Test("Metadata comparison permits only rename ctime change")
    func capturedMetadata() throws {
        let root = try fixture(), file = root.appendingPathComponent("file")
        try Data("bytes".utf8).write(to: file)
        let parent = try InstallerDirectoryAnchor.open(root), fd = try InstallerFileDescriptor(parent: parent, name: "file")
        let before = try InstallerFileAccess.snapshot(fd.fd)
        try InstallerFileAccess.exclusiveMove(from: parent, name: "file", to: parent, destinationName: "moved")
        let after = try InstallerFileAccess.snapshot(fd.fd)
        #expect(before.matchesCaptured(after))
        #expect(before.device <= UInt64(UInt32.max))
        try Data("different size".utf8).write(to: root.appendingPathComponent("moved"))
        #expect(!before.matchesCaptured(try InstallerFileAccess.snapshot(fd.fd)))
    }
}
