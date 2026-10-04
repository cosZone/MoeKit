import Darwin
import Foundation

/// Read-only preparation snapshot. The native operation later holds the same
/// permanent sidecar lock used by CatalogWriteCoordinator before comparing it.
struct InstallerCatalogSnapshot: Equatable {
    let bytes: Data?
    var protectedPaths: [String] {
        get throws {
            guard let bytes else { return [] }
            let projects = try CatalogPersistence.decodedProjectsForReadOnlyProtection(bytes)
            return projects.flatMap { project in
                [project.path] + (project.gitMetadata.map { [$0.gitDirectoryPath, $0.commonDirectoryPath] } ?? [])
            }
        }
    }
    static func read(recoveryRoot: URL) throws -> Self {
        let appURL = recoveryRoot.deletingLastPathComponent()
        let base = try InstallerDirectoryAnchor.open(appURL.deletingLastPathComponent())
        var status = stat()
        let exists = fstatat(base.fd, appURL.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW)
        if exists != 0, errno == ENOENT { return Self(bytes: nil) }
        guard exists == 0 else { throw InstallerTrashFailure.protected }
        let app = try base.child(appURL.lastPathComponent)
        try InstallerFileAccess.validatePrivate(app.fd, directory: true)
        return try read(app: app)
    }
    static func read(app: InstallerDirectoryAnchor) throws -> Self {
        try app.validate()
        var status = stat()
        let exists = fstatat(app.fd, CatalogWriteCoordinator.catalogName, &status, AT_SYMLINK_NOFOLLOW)
        if exists != 0, errno == ENOENT { return Self(bytes: nil) }
        guard exists == 0 else { throw InstallerTrashFailure.protected }
        let file = try InstallerFileDescriptor(parent: app, name: CatalogWriteCoordinator.catalogName)
        // Keep the owner alive through every borrowed-fd read/snapshot, including
        // optimized inlining at the new Git cleanup call sites.
        defer { withExtendedLifetime(file) {} }
        let before = try InstallerFileAccess.snapshot(file.fd)
        guard before.mode & UInt32(S_IFMT) == UInt32(S_IFREG), before.uid == geteuid(), before.links == 1, before.mode & 0o022 == 0,
              before.bytes >= 0, before.bytes <= CatalogPersistence.maximumBytes else { throw InstallerTrashFailure.protected }
        let data = try BoundedRegularFileReader.read(descriptor: file.fd, maximumBytes: CatalogPersistence.maximumBytes)
        guard before == (try InstallerFileAccess.snapshot(file.fd)), before == (try InstallerFileAccess.snapshotAt(app.fd, CatalogWriteCoordinator.catalogName)) else {
            throw InstallerTrashFailure.changed
        }
        try app.validate()
        _ = try CatalogPersistence.decodedProjectsForReadOnlyProtection(data)
        return Self(bytes: data)
    }
}

/// Acquired only AFTER exact confirmation. Shared catalog lock prevents a
/// cooperating writer from replacing the protection scope during our operation.
/// Lock order is operations.lock then projects.json.lock, both nonblocking.
final class InstallerCatalogLease {
    let app: InstallerDirectoryAnchor
    private let fd: Int32
    private let identity: InstallerFileSnapshot
    init(app: InstallerDirectoryAnchor) throws {
        self.app = app
        try app.validate(); try InstallerFileAccess.validatePrivate(app.fd, directory: true)
        let descriptor = openat(app.fd, CatalogWriteCoordinator.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw InstallerTrashFailure.protected }
        do {
            try InstallerFileAccess.validatePrivate(descriptor, directory: false)
            guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { throw InstallerTrashFailure.busy }
            let saved = try InstallerFileAccess.snapshot(descriptor)
            guard saved == (try InstallerFileAccess.snapshotAt(app.fd, CatalogWriteCoordinator.lockName)) else { throw InstallerTrashFailure.changed }
            guard fsync(descriptor) == 0, fsync(app.fd) == 0 else { throw InstallerTrashFailure.journal }
            fd = descriptor; identity = saved
        } catch { close(descriptor); throw error }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
    func validate() throws {
        try app.validate(); try InstallerFileAccess.validatePrivate(app.fd, directory: true)
        try InstallerFileAccess.validatePrivate(fd, directory: false)
        guard identity == (try InstallerFileAccess.snapshotAt(app.fd, CatalogWriteCoordinator.lockName)) else { throw InstallerTrashFailure.changed }
    }
    func requireSnapshot(_ expected: InstallerCatalogSnapshot) throws {
        try validate()
        guard try InstallerCatalogSnapshot.read(app: app) == expected else { throw InstallerTrashFailure.changed }
    }
}
