import Darwin
import Foundation

/// Durable evidence for manual inspection after interruption. Records never
/// authorize deletion, replay, rollback, or an automatic recovery operation.
final class TrashJournal {
    let storage: InstallerRecoveryJournal
    private let environment: TrashEnvironment
    private var healthy = true
    init(environment: TrashEnvironment, create: Bool, exclusive: Bool) throws {
        self.environment = environment
        if environment.enforceProductionPolicy {
            let base = try InstallerDirectoryAnchor.open(environment.recovery.deletingLastPathComponent().deletingLastPathComponent())
            try base.validateTrustedMutationAncestry()
        }
        storage = try InstallerRecoveryJournal(rootURL: environment.recovery, create: create, exclusive: exclusive)
    }
    func append(_ record: TrashRecord, operation: InstallerDirectoryAnchor) throws {
        guard healthy, record.id.uuidString == operation.url.lastPathComponent,
              record.operationURL == operation.url, record.operationIdentity.matchesDirectory(operation.identity),
              (0..<8).contains(record.sequence) else { throw TrashFailure.records }
        try storage.validate(); try operation.validate()
        try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
        if record.sequence == 0 {
            guard try CleanupFiles.names(operation, honorCancellation: false).isEmpty else { throw TrashFailure.records }
            try validate(record, previous: nil)
        } else {
            let previous = try latest(record.id)
            guard previous.sequence + 1 == record.sequence else { throw TrashFailure.records }
            try validate(record, previous: previous)
        }
        healthy = false
        let data = try JSONEncoder().encode(record)
        guard data.count <= CleanupJournal.maximumBytes else { throw TrashFailure.records }
        let name = Self.name(record.sequence)
        let fd = openat(operation.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TrashFailure.records }
        defer { close(fd) }
        try InstallerFileAccess.validatePrivate(fd, directory: false)
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw TrashFailure.records }
            offset += amount
        }
        guard fsync(fd) == 0, fsync(operation.fd) == 0, fsync(storage.root.fd) == 0,
              fcntl(fd, F_FULLFSYNC) == 0 else { throw TrashFailure.records }
        try storage.validate(); try operation.validate()
        guard try InstallerFileAccess.snapshot(fd) == InstallerFileAccess.snapshotAt(operation.fd, name) else { throw TrashFailure.records }
        try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
        healthy = true
    }
    /// Separate bounded Trash history, without reducing the existing installer
    /// and cache adapters' narrower lifetime budgets or deleting old evidence.
    func createOperation(_ id: UUID) throws -> InstallerDirectoryAnchor {
        try storage.validate()
        guard try CleanupFiles.names(storage.root, limit: 4_098, honorCancellation: false)
            .filter({ UUID(uuidString: $0) != nil }).count < 4_096 else { throw TrashFailure.records }
        guard mkdirat(storage.root.fd, id.uuidString, 0o700) == 0 else { throw TrashFailure.records }
        let operation = try storage.root.child(id.uuidString)
        try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
        guard fsync(storage.root.fd) == 0 else { throw TrashFailure.records }
        return operation
    }
    func records() throws -> [TrashRecoveryItem] {
        let names = try CleanupFiles.names(storage.root, limit: 4_098).compactMap(UUID.init(uuidString:))
        let recent = try names.map { id in
            (id, try InstallerFileAccess.snapshotAt(storage.root.fd, id.uuidString).modifiedSeconds)
        }.sorted { $0.1 > $1.1 }.prefix(128)
        // Display summaries, not thousands of retained full manifest copies.
        return try recent.map { id, _ in
            try Task.checkCancellation()
            let url = storage.root.url.appendingPathComponent(id.uuidString)
            do {
                let record = try latest(id)
                return .init(id: id, operationURL: url,
                    record: .init(originalURL: record.originalURL, state: record.state, recordedAt: record.recordedAt), issue: nil)
            } catch is CancellationError { throw CancellationError() }
            catch { return .init(id: id, operationURL: url, record: nil, issue: TrashFailure.records.errorDescription) }
        }
    }
    private func latest(_ id: UUID) throws -> TrashRecord {
        let operation = try storage.operation(id)
        let names = try CleanupFiles.names(operation, limit: CleanupFiles.maximumEntries + 16, honorCancellation: false)
            .filter { $0.hasSuffix(".trash.json") }
        guard !names.isEmpty, names.count <= 8 else { throw TrashFailure.records }
        var previous: TrashRecord?
        for (index, name) in names.enumerated() {
            guard name == Self.name(index) else { throw TrashFailure.records }
            let file = try InstallerFileDescriptor(parent: operation, name: name)
            try InstallerFileAccess.validatePrivate(file.fd, directory: false)
            let identity = try InstallerFileAccess.snapshot(file.fd)
            let data = try BoundedRegularFileReader.read(descriptor: file.fd, maximumBytes: CleanupJournal.maximumBytes)
            guard identity == (try InstallerFileAccess.snapshotAt(operation.fd, name)) else { throw TrashFailure.records }
            let value = try JSONDecoder().decode(TrashRecord.self, from: data)
            guard value.id == id, value.sequence == index, value.operationURL == operation.url,
                  value.operationIdentity.matchesDirectory(operation.identity) else { throw TrashFailure.records }
            try validate(value, previous: previous); previous = value
        }
        guard let previous else { throw TrashFailure.records }
        return previous
    }
    private func validate(_ row: TrashRecord, previous: TrashRecord?) throws {
        guard row.originalURL.deletingLastPathComponent().path == environment.trash.path,
              row.operationURL.path == environment.recovery.appendingPathComponent(row.id.uuidString).path,
              !row.approvedManifest.entries.isEmpty,
              row.approvedManifest.entries.first?.relativePath == "",
              row.approvedManifest.entries.count <= CleanupFiles.maximumEntries else { throw TrashFailure.records }
        _ = try InstallerFileAccess.components(row.originalURL)
        for entry in row.approvedManifest.entries where !entry.relativePath.isEmpty {
            guard !entry.relativePath.hasPrefix("/") else { throw TrashFailure.records }
            for part in entry.relativePath.split(separator: "/", omittingEmptySubsequences: false) {
                try InstallerFileAccess.basename(String(part))
            }
        }
        if let captured = row.capturedManifest {
            guard CleanupFiles.matchesAfterMove(row.approvedManifest, captured) else { throw TrashFailure.records }
        }
        if [.captured, .deleting, .deleted].contains(row.state), row.capturedManifest == nil { throw TrashFailure.records }
        if let previous {
            guard row.originalURL == previous.originalURL, row.originalParent == previous.originalParent,
                  row.operationIdentity == previous.operationIdentity, row.approvedManifest == previous.approvedManifest else { throw TrashFailure.records }
            let allowed: Set<TrashRecord.State>
            switch previous.state {
            case .captureIntent: allowed = [.captured, .retained]
            case .captured: allowed = [.deleting, .retained]
            case .deleting: allowed = [.deleted, .retained]
            case .deleted, .retained: allowed = []
            }
            guard allowed.contains(row.state) else { throw TrashFailure.records }
        } else {
            guard row.sequence == 0, row.state == .captureIntent, row.capturedManifest == nil else { throw TrashFailure.records }
        }
    }
    private static func name(_ sequence: Int) -> String { String(format: "%06d.trash.json", sequence) }
}
