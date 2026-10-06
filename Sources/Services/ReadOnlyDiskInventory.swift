import Darwin
import Foundation

/// Display-only metadata. Never used as a mutation manifest or proof of free space.
struct DiskUsageEstimate: Equatable, Sendable {
    let logicalBytes: Int64?
    let isComplete: Bool
    let visitedEntries: Int
    let issues: [String]

    var formattedSize: String {
        guard let logicalBytes else { return String(localized: "Unknown") }
        let value = ByteCountFormatter.string(fromByteCount: logicalBytes, countStyle: .file)
        return isComplete ? value : String(localized: "\(value) (partial)")
    }
}

struct DirectoryScanProgress: Sendable {
    enum Phase: Sendable { case sizing, checkingEligibility }
    let phase: Phase
    let finished: Int
    let total: Int
    let currentPath: String?
}

/// Bounded, descriptor-relative, no-follow metadata discovery. Reading a size
/// does not require permission to delete the object, a clean Git ancestry, a
/// private ACL, an app catalog, or opening any regular file's contents.
enum ReadOnlyDiskInventory {
    struct Listing {
        let names: [String]
        let isComplete: Bool
        let issue: String?
    }
    struct Limits: Sendable {
        var totalEntries = 250_000
        var entriesPerItem = 25_000
        var maximumDepth = 48
        var seconds = 45.0
        var secondsPerItem = 2.0
    }
    final class Budget {
        let limits: Limits
        let deadline: Date
        var remaining: Int
        init(_ limits: Limits = .init()) {
            self.limits = limits
            deadline = Date().addingTimeInterval(limits.seconds)
            remaining = limits.totalEntries
        }
    }

    static func list(_ directory: AnchoredDirectory, limit: Int) throws -> Listing {
        var names: [String] = []
        do {
            let entries = try directory.entries()
            while let name = try entries.next() {
                guard names.count < limit else {
                    return .init(names: names.sorted(), isComplete: false,
                        issue: String(localized: "Only the first \(limit) items are listed. Inspect the remaining items in Finder."))
                }
                names.append(name)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            return .init(names: names.sorted(), isComplete: false, issue: issue(error, at: directory.url))
        }
        return .init(names: names.sorted(), isComplete: true, issue: nil)
    }

    static func estimate(parent: AnchoredDirectory, name: String, budget: Budget,
                         beforeEntry: (URL) throws -> Void = { _ in }) throws -> DiskUsageEstimate {
        var bytes: Int64 = 0, visited = 0
        var complete = true, issues: [String] = []
        let deadline = min(budget.deadline, Date().addingTimeInterval(budget.limits.secondsPerItem))
        func record(_ message: String) {
            complete = false
            if issues.count < 3, !issues.contains(message) { issues.append(message) }
        }
        func available() -> Bool {
            budget.remaining > 0 && visited < budget.limits.entriesPerItem && Date() < deadline
        }
        func visit(_ parent: AnchoredDirectory, _ name: String, depth: Int) throws {
            try Task.checkCancellation()
            let url = parent.url.appendingPathComponent(name)
            guard available() else {
                record(String(localized: "Size is partial because the read-only scan reached its time, entry, or depth limit."))
                return
            }
            // Charge attempts too: a failing subtree cannot consume an unbounded
            // amount of work or starve every later row of its own item budget.
            budget.remaining -= 1; visited += 1
            guard depth <= budget.limits.maximumDepth else {
                record(String(localized: "Size is partial because the read-only scan reached its time, entry, or depth limit.")); return
            }
            do {
                try beforeEntry(url)
                let value = try parent.status(name)
                switch value.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFREG):
                    guard value.st_size >= 0 else { throw InventoryError.invalidSize }
                    let sum = bytes.addingReportingOverflow(value.st_size)
                    guard !sum.overflow else { throw InventoryError.invalidSize }
                    bytes = sum.partialValue
                case mode_t(S_IFDIR):
                    var parentValue = stat()
                    guard fstat(parent.descriptor, &parentValue) == 0 else { throw AnchoredDirectory.AccessError.changed }
                    guard value.st_dev == parentValue.st_dev else { throw InventoryError.otherVolume }
                    let child = try parent.openDirectory(name)
                    var opened = stat()
                    guard fstat(child.descriptor, &opened) == 0,
                          value.st_dev == opened.st_dev, value.st_ino == opened.st_ino else { throw AnchoredDirectory.AccessError.changed }
                    let entries = try child.entries()
                    while let next = try entries.next() {
                        guard available() else {
                            record(String(localized: "Size is partial because the read-only scan reached its time, entry, or depth limit.")); break
                        }
                        try visit(child, next, depth: depth + 1)
                    }
                    let after = try parent.status(name)
                    guard value.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                          value.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                          value.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                          value.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw AnchoredDirectory.AccessError.changed }
                case mode_t(S_IFLNK):
                    break // Link target and target contents are never read or counted.
                default:
                    record(String(localized: "A special filesystem item has no regular-file size: \(InstallerPathDisplay.quoted(url.path))"))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { record(issue(error, at: url)) }
        }
        try visit(parent, name, depth: 0)
        // A denied/limited read is unknown, not a fabricated zero-byte item.
        return .init(logicalBytes: complete || bytes > 0 ? bytes : nil,
                     isComplete: complete, visitedEntries: visited, issues: issues)
    }

    private enum InventoryError: Error, Equatable { case invalidSize, otherVolume }
    static func issue(_ error: any Error, at url: URL) -> String {
        let path = InstallerPathDisplay.quoted(url.path)
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain, value.code == Int(EACCES) || value.code == Int(EPERM) {
            return String(localized: "macOS denied read access to \(path). Readable sizes are retained; inspect this location in Finder if needed.")
        }
        if let error = error as? AnchoredDirectory.AccessError {
            switch error {
            case .symbolicLink: return String(localized: "A symbolic link was skipped at \(path). Its target was not followed.")
            case .changed: return String(localized: "The folder changed during the scan: \(path). Scan again for a current size.")
            case .descriptorLimit: return String(localized: "The open-folder limit was reached at \(path). The size is partial.")
            default: break
            }
        }
        if let error = error as? InventoryError, error == .otherVolume {
            return String(localized: "A different volume was skipped at \(path). Its contents are not included.")
        }
        return String(localized: "Metadata could not be completely read at \(path): \(value.localizedDescription)")
    }
}
