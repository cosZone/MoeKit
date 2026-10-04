import Darwin
import Foundation

/// Append-only receipts. No startup read, automatic replay, retention sweep, or
/// removal of recovery storage exists. Incomplete last records fail closed.
final class CleanupJournal {
    static let maximumBytes = 24 * 1024 * 1024
    private(set) var isHealthy = true
    private let environment: CleanupEnvironment
    let storage: InstallerRecoveryJournal
    var app: InstallerDirectoryAnchor { storage.appParent }
    init(environment: CleanupEnvironment, create: Bool, exclusive: Bool) throws {
        self.environment = environment
        if environment.enforceProductionPolicy {
            let base = try InstallerDirectoryAnchor.open(environment.recovery.deletingLastPathComponent().deletingLastPathComponent())
            try base.validateTrustedMutationAncestry()
        }
        storage = try InstallerRecoveryJournal(rootURL: environment.recovery, create: create, exclusive: exclusive)
    }
    func append(_ receipt: CleanupReceipt, operation: InstallerDirectoryAnchor) throws {
        guard isHealthy else { throw CleanupFailure.journal }
        try storage.validate(); try operation.validate()
        try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
        if receipt.sequence == 0 {
            guard try CleanupFiles.names(operation, honorCancellation: false).isEmpty else { throw CleanupFailure.journal }
        } else {
            let prior = try latest(receipt.id)
            guard prior.sequence + 1 == receipt.sequence else { throw CleanupFailure.journal }
            try validate(receipt, previous: prior)
        }
        isHealthy = false
        let data = try JSONEncoder().encode(receipt)
        guard receipt.sequence < 32, data.count <= Self.maximumBytes else { throw CleanupFailure.journal }
        let name = String(format: "%06d.cache.json", receipt.sequence)
        let fd = openat(operation.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CleanupFailure.journal }
        defer { close(fd) }
        try InstallerFileAccess.validatePrivate(fd, directory: false)
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw CleanupFailure.journal }
            offset += amount
        }
        guard fsync(fd) == 0, fsync(operation.fd) == 0, fsync(storage.root.fd) == 0,
              fcntl(fd, F_FULLFSYNC) == 0 else { throw CleanupFailure.journal }
        try storage.validate(); try operation.validate()
        guard try InstallerFileAccess.snapshot(fd) == InstallerFileAccess.snapshotAt(operation.fd, name) else { throw CleanupFailure.journal }
        try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
        isHealthy = true
    }
    func latest(_ id: UUID) throws -> CleanupReceipt {
        let operation = try storage.operation(id)
        try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
        let names = try CleanupFiles.names(operation, limit: CleanupFiles.maximumEntries + 40, honorCancellation: false).filter { $0.hasSuffix(".cache.json") }
        guard !names.isEmpty, names.count <= 32 else { throw CleanupFailure.journal }
        var previous: CleanupReceipt?
        for (index, name) in names.enumerated() {
            guard name == String(format: "%06d.cache.json", index) else { throw CleanupFailure.journal }
            let file = try InstallerFileDescriptor(parent: operation, name: name)
            try InstallerFileAccess.validatePrivate(file.fd, directory: false)
            let before = try InstallerFileAccess.snapshot(file.fd)
            guard before.bytes > 0, before.bytes <= Self.maximumBytes else { throw CleanupFailure.journal }
            var data = Data(count: Int(before.bytes)), offset = 0
            while offset < data.count {
                let count = data.withUnsafeMutableBytes { read(file.fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CleanupFailure.journal }
                offset += count
            }
            guard before == (try InstallerFileAccess.snapshot(file.fd)), before == (try InstallerFileAccess.snapshotAt(operation.fd, name)) else { throw CleanupFailure.changed }
            let row = try JSONDecoder().decode(CleanupReceipt.self, from: data)
            guard row.id == id, row.sequence == index, row.operationURL == operation.url,
                  row.operationIdentity.matchesDirectory(operation.identity) else { throw CleanupFailure.journal }
            try validate(row, previous: previous)
            previous = row
        }
        guard let previous else { throw CleanupFailure.journal }
        return previous
    }
    func records() throws -> [CleanupRecoveryItem] {
        let names = try CleanupFiles.names(storage.root, limit: 300)
        return names.compactMap(UUID.init(uuidString:)).map { id in
            let operation = storage.root.url.appendingPathComponent(id.uuidString)
            do { return .init(id: id, operationURL: operation, receipt: try latest(id), issue: nil) }
            catch { return .init(id: id, operationURL: operation, receipt: nil,
                                issue: String(localized: "This cleanup receipt is incomplete or unreadable. Its data is retained; no restore or deletion can be authorized from it.")) }
        }
    }
    private func validate(_ row: CleanupReceipt, previous: CleanupReceipt?) throws {
        guard row.policy == 1, row.operationURL.path == environment.recovery.appendingPathComponent(row.id.uuidString).path,
              CleanupFiles.matchesAfterMove(row.target.manifest, row.manifest) else { throw CleanupFailure.journal }
        _ = try InstallerFileAccess.components(row.target.originalURL)
        let stageNames = [row.target.originalURL.lastPathComponent, "restore-payload", "restore-payload-again", "delete-payload"]
        let isPrivatePayload = row.payloadURL.map { $0.deletingLastPathComponent().path == row.operationURL.path && stageNames.contains($0.lastPathComponent) } ?? false
        let isTrashPayload = row.payloadURL.map { $0.deletingLastPathComponent().path == environment.trash.path } ?? false
        if let payload = row.payloadURL { _ = try InstallerFileAccess.components(payload) }
        switch row.state {
        case .captureIntent, .staged, .trashIntent, .restoreStaged, .restoreIntent, .deleteStaged, .deleteIntent, .retained:
            guard isPrivatePayload else { throw CleanupFailure.journal }
        case .trashed, .deleteCaptureIntent:
            guard isTrashPayload else { throw CleanupFailure.journal }
        case .restoreCaptureIntent, .uncertain:
            guard isPrivatePayload || isTrashPayload || row.payloadURL?.path == row.target.originalURL.path else { throw CleanupFailure.journal }
        case .restored:
            guard row.payloadURL?.path == row.target.originalURL.path else { throw CleanupFailure.journal }
        case .deleted:
            guard row.payloadURL == nil else { throw CleanupFailure.journal }
        }
        guard row.manifest.entries.count <= CleanupFiles.maximumEntries, !row.manifest.entries.isEmpty,
              row.manifest.entries.first?.relativePath == "", row.manifest.entries.first?.kind == .directory else { throw CleanupFailure.journal }
        var paths: Set<String> = []
        for entry in row.manifest.entries {
            guard paths.insert(entry.relativePath).inserted, entry.relativePath.utf8.count <= 4096 else { throw CleanupFailure.journal }
            if !entry.relativePath.isEmpty {
                guard !entry.relativePath.hasPrefix("/"), !entry.relativePath.hasSuffix("/") else { throw CleanupFailure.journal }
                for part in entry.relativePath.split(separator: "/", omittingEmptySubsequences: false) { try InstallerFileAccess.basename(String(part)) }
            }
        }
        if let previous {
            guard previous.target == row.target, previous.originalParent == row.originalParent,
                  previous.operationIdentity == row.operationIdentity, previous.policy == row.policy,
                  ![CleanupReceiptState.deleted, .restored, .uncertain].contains(previous.state) else { throw CleanupFailure.journal }
            let allowed: Set<CleanupReceiptState>
            switch previous.state {
            case .captureIntent: allowed = [.staged, .retained, .uncertain]
            case .staged: allowed = [.trashIntent, .restoreCaptureIntent, .retained, .uncertain]
            case .trashIntent: allowed = [.trashed, .retained, .uncertain]
            case .trashed: allowed = [.restoreCaptureIntent, .deleteCaptureIntent]
            case .deleteCaptureIntent: allowed = [.deleteStaged, .retained, .uncertain]
            case .deleteStaged: allowed = [.deleteIntent, .restoreCaptureIntent, .retained, .uncertain]
            case .deleteIntent: allowed = [.deleted, .uncertain]
            case .retained: allowed = [.restoreCaptureIntent, .uncertain]
            case .restoreCaptureIntent: allowed = [.restoreStaged, .retained, .uncertain]
            case .restoreStaged: allowed = [.restoreIntent, .restoreCaptureIntent, .retained, .uncertain]
            case .restoreIntent: allowed = [.restored, .retained, .uncertain]
            case .deleted, .restored, .uncertain: allowed = []
            }
            guard allowed.contains(row.state) else { throw CleanupFailure.journal }
        } else {
            guard row.state == .captureIntent, row.sequence == 0 else { throw CleanupFailure.journal }
        }
    }
}

extension CleanupReceipt {
    func advancing(_ state: CleanupReceiptState, payloadURL: URL?, manifest: CleanupManifest? = nil) -> Self {
        .init(id: id, sequence: sequence + 1, target: target, originalParent: originalParent,
              operationURL: operationURL, operationIdentity: operationIdentity, state: state,
              payloadURL: payloadURL, manifest: manifest ?? self.manifest, recordedAt: Date())
    }
}
