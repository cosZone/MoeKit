import Darwin
import Foundation

/// The sole irreversible sink. Every approved leaf/empty directory is captured
/// into a fresh private operation slot and verified again before unlinking. An
/// ordinary cache writer with an old directory FD cannot replace that slot.
/// This is not protection against hostile same-UID access to private storage.
enum CleanupPermanentRemoval {
    static let maximumDirectories = 96
    static func preflight(_ manifest: CleanupManifest) throws {
        let count = manifest.entries.filter { $0.kind == .directory }.count
        var limits = rlimit()
        guard count <= maximumDirectories, getrlimit(RLIMIT_NOFILE, &limits) == 0,
              limits.rlim_cur > rlim_t(count + 96) else {
            throw CleanupFailure.refused(String(localized: "This tree exceeds the bounded directory-descriptor budget for permanent removal. Restore it or manage it in Finder; no deletion was authorized."))
        }
    }
    // Explicit caller isolation keeps borrowed descriptors and synchronous
    // checkpoint captures on the same actor (Swift 6 SE-0420). No suspension,
    // unchecked Sendable conformance or cross-actor descriptor transfer occurs.
    static func remove(manifest: CleanupManifest, directory: InstallerDirectoryAnchor,
                       parent: InstallerDirectoryAnchor, name: String, environment: CleanupEnvironment,
                       isolation: isolated (any Actor)? = #isolation,
                       checkpoint: (CleanupCheckpoint) throws -> Void = { _ in }) throws {
        try preflight(manifest)
        try InstallerFileAccess.validatePrivate(parent.fd, directory: true)
        try CleanupFiles.validateNamespace(parent, environment: environment)
        guard let root = manifest.entries.first, root.relativePath.isEmpty,
              root.identity == (try InstallerFileAccess.snapshot(directory.fd)),
              root.identity == (try InstallerFileAccess.snapshotAt(parent.fd, name)) else { throw CleanupFailure.changed }
        var directories: [String: InstallerDirectoryAnchor] = ["": directory]
        for entry in manifest.entries where entry.kind == .directory && !entry.relativePath.isEmpty {
            try Task.checkCancellation()
            let parts = split(entry.relativePath)
            guard let owner = directories[parts.parent] else { throw CleanupFailure.changed }
            let child = try owner.child(parts.name)
            guard entry.identity == (try InstallerFileAccess.snapshot(child.fd)) else { throw CleanupFailure.changed }
            directories[entry.relativePath] = child
        }
        var removedLinks: [String: UInt64] = [:]
        for (index, entry) in manifest.entries.enumerated().reversed() where !entry.relativePath.isEmpty {
            try Task.checkCancellation()
            let parts = split(entry.relativePath)
            guard let owner = directories[parts.parent] else { throw CleanupFailure.changed }
            let current = try InstallerFileAccess.snapshotAt(owner.fd, parts.name)
            let key = "\(entry.identity.device):\(entry.identity.inode)"
            let count = removedLinks[key, default: 0]
            if entry.kind == .directory {
                guard entry.identity.matchesDirectory(current), let child = directories[entry.relativePath],
                      current.matchesDirectory(try InstallerFileAccess.snapshot(child.fd)),
                      try CleanupFiles.names(child).isEmpty else { throw CleanupFailure.changed }
            } else {
                guard matchesLeaf(entry.identity, current, removedLinks: count) else { throw CleanupFailure.changed }
                try checkLink(entry, parent: owner, name: parts.name)
            }
            try checkpoint(.beforeLeafCapture); try Task.checkCancellation()
            try CleanupFiles.validateNamespace(owner, environment: environment)
            try CleanupFiles.validateNamespace(parent, environment: environment)
            try InstallerFileAccess.validatePrivate(parent.fd, directory: true)
            // The durable deleteIntent manifest binds each retained slot to its original path.
            let slot = String(format: "delete-entry-%06d", index)
            try InstallerFileAccess.exclusiveMove(from: owner, name: parts.name, to: parent, destinationName: slot)
            try checkpoint(.afterLeafCapture)
            let captured = try InstallerFileAccess.snapshotAt(parent.fd, slot)
            // A substituted file/link/directory is preserved at the private slot,
            // never traversed or unlinked. Its source may have been moved, but
            // no unreviewed bytes are destroyed and no rollback overwrites.
            guard current.matchesCaptured(captured) else { throw CleanupFailure.changed }
            try checkLink(entry, parent: parent, name: slot)
            if entry.kind == .directory {
                let child = try parent.child(slot)
                guard captured == (try InstallerFileAccess.snapshot(child.fd)), try CleanupFiles.names(child).isEmpty else { throw CleanupFailure.changed }
                directories[entry.relativePath] = nil
            } else if entry.kind == .file {
                let held = try InstallerFileDescriptor(parent: parent, name: slot)
                guard captured == (try InstallerFileAccess.snapshot(held.fd)) else { throw CleanupFailure.changed }
                try InstallerFileAccess.rejectMutationGrantingACL(held.fd)
                try InstallerFileAccess.rejectCloudAttributes(held.fd)
            }
            try Task.checkCancellation()
            try CleanupFiles.validateNamespace(parent, environment: environment)
            try InstallerFileAccess.validatePrivate(parent.fd, directory: true)
            guard captured == (try InstallerFileAccess.snapshotAt(parent.fd, slot)) else { throw CleanupFailure.changed }
            guard unlinkat(parent.fd, slot, entry.kind == .directory ? AT_REMOVEDIR : 0) == 0 else { throw CleanupFailure.changed }
            removedLinks[key] = count + 1
            guard fsync(owner.fd) == 0, fsync(parent.fd) == 0 else { throw CleanupFailure.journal }
        }
        try Task.checkCancellation(); try parent.validate(); try directory.validate()
        let beforeRoot = try InstallerFileAccess.snapshotAt(parent.fd, name)
        guard root.identity.matchesDirectory(beforeRoot), try CleanupFiles.names(directory).isEmpty else { throw CleanupFailure.changed }
        try checkpoint(.beforeLeafCapture); try Task.checkCancellation()
        try CleanupFiles.validateNamespace(parent, environment: environment)
        let rootSlot = "delete-entry-000000"
        try InstallerFileAccess.exclusiveMove(from: parent, name: name, to: parent, destinationName: rootSlot)
        try checkpoint(.afterLeafCapture)
        let capturedRoot = try InstallerFileAccess.snapshotAt(parent.fd, rootSlot)
        guard beforeRoot.matchesCaptured(capturedRoot), try CleanupFiles.names(parent.child(rootSlot)).isEmpty else { throw CleanupFailure.changed }
        try CleanupFiles.validateNamespace(parent, environment: environment)
        guard capturedRoot == (try InstallerFileAccess.snapshotAt(parent.fd, rootSlot)),
              unlinkat(parent.fd, rootSlot, AT_REMOVEDIR) == 0 else { throw CleanupFailure.changed }
    }
    /// File/link-root variant, used only after a new Trash removal confirmation
    /// and durable capture into an operation-owned private directory.
    static func remove(manifest: CleanupManifest, parent: InstallerDirectoryAnchor, name: String,
                       environment: CleanupEnvironment,
                       isolation: isolated (any Actor)? = #isolation,
                       checkpoint: (CleanupCheckpoint) throws -> Void = { _ in }) throws {
        guard let entry = manifest.entries.first, entry.relativePath.isEmpty else { throw CleanupFailure.changed }
        if entry.kind == .directory {
            try remove(manifest: manifest, directory: parent.child(name), parent: parent,
                       name: name, environment: environment, isolation: isolation, checkpoint: checkpoint)
            return
        }
        guard manifest.entries.count == 1 else { throw CleanupFailure.changed }
        try Task.checkCancellation()
        try CleanupFiles.validateNamespace(parent, environment: environment)
        try InstallerFileAccess.validatePrivate(parent.fd, directory: true)
        guard entry.identity == (try InstallerFileAccess.snapshotAt(parent.fd, name)) else { throw CleanupFailure.changed }
        try checkLink(entry, parent: parent, name: name)
        try checkpoint(.beforeLeafCapture); try Task.checkCancellation()
        let slot = "delete-entry-000000"
        try InstallerFileAccess.exclusiveMove(from: parent, name: name, to: parent, destinationName: slot)
        try checkpoint(.afterLeafCapture)
        let captured = try InstallerFileAccess.snapshotAt(parent.fd, slot)
        guard entry.identity.matchesCaptured(captured) else { throw CleanupFailure.changed }
        try checkLink(entry, parent: parent, name: slot)
        if entry.kind == .file {
            let file = try InstallerFileDescriptor(parent: parent, name: slot)
            guard captured == (try InstallerFileAccess.snapshot(file.fd)) else { throw CleanupFailure.changed }
            try InstallerFileAccess.rejectMutationGrantingACL(file.fd)
            try InstallerFileAccess.rejectCloudAttributes(file.fd)
        }
        try Task.checkCancellation()
        try CleanupFiles.validateNamespace(parent, environment: environment)
        try InstallerFileAccess.validatePrivate(parent.fd, directory: true)
        guard captured == (try InstallerFileAccess.snapshotAt(parent.fd, slot)),
              unlinkat(parent.fd, slot, 0) == 0 else { throw CleanupFailure.changed }
        guard fsync(parent.fd) == 0 else { throw CleanupFailure.journal }
    }
    private static func checkLink(_ entry: CleanupEntry, parent: InstallerDirectoryAnchor, name: String) throws {
        guard entry.kind == .symbolicLink else { return }
        var buffer = [UInt8](repeating: 0, count: 4097)
        let capacity = buffer.count
        let count = buffer.withUnsafeMutableBytes { bytes in
            readlinkat(parent.fd, name, bytes.baseAddress, capacity)
        }
        guard count >= 0, count < buffer.count, Data(buffer.prefix(count)) == entry.linkDestination else { throw CleanupFailure.changed }
    }
    private static func split(_ path: String) -> (parent: String, name: String) {
        let parts = path.split(separator: "/").map(String.init)
        return (parts.dropLast().joined(separator: "/"), parts.last!)
    }
    private static func matchesLeaf(_ expected: InstallerFileSnapshot, _ actual: InstallerFileSnapshot, removedLinks: UInt64) -> Bool {
        if removedLinks == 0 { return expected == actual }
        return expected.device == actual.device && expected.inode == actual.inode && expected.mode == actual.mode
            && expected.uid == actual.uid && expected.gid == actual.gid && expected.flags == actual.flags
            && expected.bytes == actual.bytes && expected.modifiedSeconds == actual.modifiedSeconds
            && expected.modifiedNanoseconds == actual.modifiedNanoseconds && expected.links > removedLinks
            && actual.links == expected.links - removedLinks
    }
}
