import Darwin
import Foundation

/// Persistent private recovery records. There is deliberately no deletion or
/// automatic cleanup API, including for empty, partial or retained operations.
final class InstallerRecoveryJournal {
    static let maximumRecordBytes = 32 * 1024
    static let maximumRecords = 64
    static let maximumOperations = 256
    let root: InstallerDirectoryAnchor
    let appParent: InstallerDirectoryAnchor
    private(set) var mutationJournalIsHealthy = true
    private var lockFD: Int32 = -1
    private var lockIdentity: InstallerFileSnapshot?

    init(rootURL: URL, create: Bool, exclusive: Bool) throws {
        let base = try InstallerDirectoryAnchor.open(rootURL.deletingLastPathComponent().deletingLastPathComponent())
        let appName = rootURL.deletingLastPathComponent().lastPathComponent
        if create { try Self.makeDirectory(base, appName) }
        let app = try base.child(appName)
        appParent = app
        try InstallerFileAccess.validatePrivate(app.fd, directory: true)
        if create { try Self.makeDirectory(app, rootURL.lastPathComponent) }
        root = try app.child(rootURL.lastPathComponent)
        try InstallerFileAccess.validatePrivate(root.fd, directory: true)
        if exclusive {
            if create {
                let created = openat(root.fd, "operations.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if created >= 0 { close(created) }
                else if errno != EEXIST { throw InstallerTrashFailure.unsafeRecovery }
            }
            let descriptor = openat(root.fd, "operations.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw InstallerTrashFailure.unsafeRecovery }
            do {
                try InstallerFileAccess.validatePrivate(descriptor, directory: false)
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw InstallerTrashFailure.busy }
                let identity = try InstallerFileAccess.snapshot(descriptor)
                guard identity == (try InstallerFileAccess.snapshotAt(root.fd, "operations.lock")) else { throw InstallerTrashFailure.changed }
                lockFD = descriptor; lockIdentity = identity
                try validate()
            } catch {
                // Relinquish stored ownership before the initializer unwinds.
                lockFD = -1; lockIdentity = nil; close(descriptor); throw error
            }
        }
    }
    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
    func validate() throws {
        try appParent.validate(); try InstallerFileAccess.validatePrivate(appParent.fd, directory: true)
        try root.validate(); try InstallerFileAccess.validatePrivate(root.fd, directory: true)
        if let lockIdentity {
            try InstallerFileAccess.validatePrivate(lockFD, directory: false)
            guard lockIdentity == (try InstallerFileAccess.snapshotAt(root.fd, "operations.lock")) else { throw InstallerTrashFailure.changed }
        }
    }
    private static func makeDirectory(_ parent: InstallerDirectoryAnchor, _ name: String) throws {
        try parent.validate(); try InstallerFileAccess.basename(name)
        guard mkdirat(parent.fd, name, 0o700) == 0 || errno == EEXIST else { throw InstallerTrashFailure.unsafeRecovery }
        guard fsync(parent.fd) == 0 else { throw InstallerTrashFailure.journal }
    }
    func createOperation(_ id: UUID) throws -> InstallerDirectoryAnchor {
        try validate()
        guard try Self.names(root).filter({ UUID(uuidString: $0) != nil }).count < Self.maximumOperations else { throw InstallerTrashFailure.unsafeRecovery }
        guard mkdirat(root.fd, id.uuidString, 0o700) == 0 else { throw InstallerTrashFailure.unsafeRecovery }
        let operation = try root.child(id.uuidString)
        try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
        guard fsync(root.fd) == 0 else { throw InstallerTrashFailure.journal }
        return operation
    }
    func operation(_ id: UUID) throws -> InstallerDirectoryAnchor {
        try validate()
        let op = try root.child(id.uuidString)
        try InstallerFileAccess.validatePrivate(op.fd, directory: true)
        return op
    }
    func append(_ receipt: InstallerTrashReceipt, operation: InstallerDirectoryAnchor) throws {
        guard mutationJournalIsHealthy else { throw InstallerTrashFailure.journal }
        mutationJournalIsHealthy = false
        try validate(); try operation.validate()
        try InstallerFileAccess.validatePrivate(operation.fd, directory: true)
        guard receipt.id.uuidString == operation.url.lastPathComponent, receipt.operationURL == operation.url,
              receipt.operationDirectory.matchesDirectory(operation.identity), (0..<Self.maximumRecords).contains(receipt.sequence) else { throw InstallerTrashFailure.journal }
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= Self.maximumRecordBytes else { throw InstallerTrashFailure.journal }
        let name = Self.recordName(receipt.sequence)
        let fd = openat(operation.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InstallerTrashFailure.journal }
        defer { close(fd) }
        try InstallerFileAccess.validatePrivate(fd, directory: false)
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw InstallerTrashFailure.journal }
            offset += amount
        }
        // Persist data, namespace, then a device flush. Failure leaves the partial
        // record in place; recovery never falls back past it to an older action.
        guard fsync(fd) == 0, fsync(operation.fd) == 0, fsync(root.fd) == 0,
              fcntl(fd, F_FULLFSYNC) == 0 else { throw InstallerTrashFailure.journal }
        try validate(); try operation.validate()
        guard try InstallerFileAccess.snapshot(fd) == InstallerFileAccess.snapshotAt(operation.fd, name) else { throw InstallerTrashFailure.journal }
        mutationJournalIsHealthy = true
    }
    func latest(_ id: UUID) throws -> InstallerTrashReceipt {
        let op = try operation(id)
        let names = try Self.names(op)
        let recordNames = names.filter { $0.hasSuffix(".json") }.sorted()
        guard !recordNames.isEmpty, recordNames.count <= Self.maximumRecords else { throw InstallerTrashFailure.journal }
        var receipt: InstallerTrashReceipt?
        for (index, name) in recordNames.enumerated() {
            guard name == Self.recordName(index) else { throw InstallerTrashFailure.journal }
            let fd = try InstallerFileDescriptor(parent: op, name: name)
            try InstallerFileAccess.validatePrivate(fd.fd, directory: false)
            let before = try InstallerFileAccess.snapshot(fd.fd)
            guard before.bytes > 0, before.bytes <= Self.maximumRecordBytes else { throw InstallerTrashFailure.journal }
            var data = Data(count: Int(before.bytes))
            let count = data.withUnsafeMutableBytes { read(fd.fd, $0.baseAddress, $0.count) }
            guard count == before.bytes, before == (try InstallerFileAccess.snapshot(fd.fd)),
                  before == (try InstallerFileAccess.snapshotAt(op.fd, name)) else { throw InstallerTrashFailure.journal }
            let row = try JSONDecoder().decode(InstallerTrashReceipt.self, from: data)
            guard row.policy == InstallerTrashReceipt.policyVersion, row.id == id, row.sequence == index,
                  row.operationURL == op.url, row.operationDirectory.matchesDirectory(op.identity),
                  row.originalURL.path.utf8.count <= 4096 else { throw InstallerTrashFailure.journal }
            try Self.validateState(row, previous: receipt)
            if let previous = receipt {
                guard previous.originalURL == row.originalURL, previous.originalFile == row.originalFile,
                      previous.originalParent == row.originalParent, previous.operationDirectory == row.operationDirectory else { throw InstallerTrashFailure.journal }
            }
            receipt = row
        }
        try op.validate()
        guard let receipt else { throw InstallerTrashFailure.journal }
        return receipt
    }
    func receipts() throws -> [InstallerRecoveryItem] {
        let names = try Self.names(root)
        let ids = names.filter { $0 != "operations.lock" }.compactMap(UUID.init(uuidString:))
        guard ids.count <= Self.maximumOperations else { throw InstallerTrashFailure.journal }
        // Non-operation entries (for example Finder metadata) confer no authority
        // and cannot hide validated operation directories. Never open or remove them.
        return ids.map { id in
            let location = root.url.appendingPathComponent(id.uuidString)
            do {
                let receipt = try latest(id)
                return InstallerRecoveryItem(id: id, operationURL: location, receipt: receipt, issue: nil)
            } catch {
                return InstallerRecoveryItem(id: id, operationURL: location, receipt: nil,
                    issue: String(localized: "This recovery record is incomplete or unreadable. Its contents were retained; no operation will be retried automatically."))
            }
        }
    }
    private static func validateState(_ row: InstallerTrashReceipt, previous: InstallerTrashReceipt?) throws {
        if let previous {
            let allowed: Set<InstallerReceiptState>
            switch previous.state {
            case .captureIntent: allowed = [.captured, .rollbackIntent, .retained, .uncertain]
            case .captured: allowed = [.trashIntent, .rollbackIntent, .retained, .uncertain, .restoreCaptureIntent]
            case .trashIntent: allowed = [.trashed, .rollbackIntent, .retained, .uncertain]
            case .trashed: allowed = [.restoreCaptureIntent]
            case .rollbackIntent: allowed = [.rolledBack, .retained, .uncertain]
            case .retained, .restoreCaptured: allowed = [.restoreCaptureIntent, .restoreIntent, .rollbackIntent, .retained, .uncertain]
            case .restoreCaptureIntent: allowed = [.restoreCaptured, .rollbackIntent, .retained, .uncertain]
            case .restoreIntent: allowed = [.restored, .rollbackIntent, .retained, .uncertain]
            case .restored, .rolledBack, .uncertain: allowed = []
            }
            guard allowed.contains(row.state) else { throw InstallerTrashFailure.journal }
        } else {
            guard row.state == .captureIntent, row.sequence == 0 else { throw InstallerTrashFailure.journal }
        }
        switch row.state {
        case .captureIntent, .captured, .trashIntent, .rollbackIntent, .retained, .restoreCaptureIntent, .restoreCaptured, .restoreIntent:
            guard let name = row.payloadName else { throw InstallerTrashFailure.journal }
            try InstallerFileAccess.basename(name)
        case .trashed:
            guard row.trashURL != nil, let file = row.trashFile, row.originalFile.matchesCaptured(file) else { throw InstallerTrashFailure.journal }
        case .rolledBack, .restored, .uncertain: break
        }
    }
    static func recordName(_ sequence: Int) -> String { String(format: "%06d.json", sequence) }
    static func names(_ directory: InstallerDirectoryAnchor) throws -> [String] {
        try directory.validate()
        let copy = dup(directory.fd)
        guard copy >= 0 else { throw InstallerTrashFailure.journal }
        guard let stream = fdopendir(copy) else { close(copy); throw InstallerTrashFailure.journal }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw InstallerTrashFailure.journal }
                break
            }
            let name: String
            do { name = try DarwinDirectoryEntry.name(entry) }
            catch { throw InstallerTrashFailure.journal }
            if name == "." || name == ".." { continue }
            guard names.count < 512 else { throw InstallerTrashFailure.journal }
            try InstallerFileAccess.basename(name); names.append(name)
        }
        try directory.validate(); return names
    }
}

extension InstallerTrashReceipt {
    func advancing(to state: InstallerReceiptState, payloadName: String? = nil, trashURL: URL? = nil, trashFile: InstallerFileSnapshot? = nil, payloadFile: InstallerFileSnapshot? = nil) -> InstallerTrashReceipt {
        .init(policy: policy, id: id, sequence: sequence + 1, originalURL: originalURL, originalParent: originalParent,
              originalFile: originalFile, operationURL: operationURL, operationDirectory: operationDirectory, state: state,
              recordedAt: Date(), payloadName: payloadName, trashURL: trashURL ?? self.trashURL, trashFile: trashFile ?? self.trashFile, payloadFile: payloadFile ?? self.payloadFile)
    }
}
