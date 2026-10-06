import Foundation

/// Busy mutating adapters register weakly. An update must never terminate the
/// process in the middle of a Trash/restore journal, Git mutation or signal flow.
@MainActor
protocol AppUpdateBlocking: AnyObject {
    var blocksAppUpdate: Bool { get }
}

@MainActor
final class UpdateInstallationSafety {
    static let shared = UpdateInstallationSafety()
    private final class Entry {
        weak var operation: (any AppUpdateBlocking)?
        init(_ operation: any AppUpdateBlocking) { self.operation = operation }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    func changed(_ operation: any AppUpdateBlocking) {
        let key = ObjectIdentifier(operation)
        if operation.blocksAppUpdate { entries[key] = Entry(operation) }
        else { entries.removeValue(forKey: key) }
    }

    var canTerminate: Bool {
        entries = entries.filter { $0.value.operation != nil }
        return !entries.values.contains { $0.operation?.blocksAppUpdate == true }
    }
}

extension CleanupStore: AppUpdateBlocking { var blocksAppUpdate: Bool { isBusy } }
extension InstallerTrashStore: AppUpdateBlocking { var blocksAppUpdate: Bool { isBusy } }
extension GitCleanupStore: AppUpdateBlocking { var blocksAppUpdate: Bool { isBusy } }
extension ProcessTerminationStore: AppUpdateBlocking { var blocksAppUpdate: Bool { isBusy } }
extension MoleAnalysisStore: AppUpdateBlocking { var blocksAppUpdate: Bool { isBusy } }
