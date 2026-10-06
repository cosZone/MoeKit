import Foundation

struct TrashEnvironment: Sendable {
    let home: URL
    let trash: URL
    let recovery: URL
    let enforceProductionPolicy: Bool
    static var user: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return .init(home: home, trash: home.appendingPathComponent(".Trash"),
            recovery: home.appendingPathComponent("Library/Application Support/MoeKit/TrashRemovalRecords"),
            enforceProductionPolicy: true)
    }
    var files: CleanupEnvironment {
        .init(home: home, caches: trash, recovery: recovery, trash: trash, enforceProductionPolicy: enforceProductionPolicy)
    }
}

struct TrashContext: Equatable, Sendable {
    let generation: UUID
}

struct TrashItem: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    let manifest: CleanupManifest?
    let modifiedAt: Date?
    let blocker: String?
    var sizeEstimate: DiskUsageEstimate? = nil
    var isEligible: Bool { manifest != nil && blocker == nil }
    var logicalBytes: Int64? { manifest?.logicalBytes ?? sizeEstimate?.logicalBytes }
    var displayedSize: String {
        if let manifest { return ByteCountFormatter.string(fromByteCount: manifest.logicalBytes, countStyle: .file) }
        return sizeEstimate?.formattedSize ?? String(localized: "Unknown")
    }
    // Finder's private put-back metadata is not a supported original-path API.
    // Neither the last modified date nor scan time is represented as deletion time.
}

struct TrashInspection: Identifiable, Equatable, Sendable {
    let id: UUID
    let rootURL: URL
    let items: [TrashItem]
    let context: TrashContext
    let observedAt: Date
    let rootExists: Bool
    var listingIsComplete = true
    var issues: [String] = []
    var canClearSnapshot: Bool { listingIsComplete && !items.isEmpty && items.allSatisfy(\.isEligible) }
}

struct TrashRemovalPlan: Identifiable, Equatable, Sendable {
    enum Action: String, Sendable { case selectedItems, clearSnapshot }
    let id: UUID
    let inspectionID: UUID
    let action: Action
    let rootURL: URL
    let items: [TrashItem]
    let context: TrashContext
    let recoveryURL: URL
    let expiresAt: Date
    var logicalBytes: Int64 { items.reduce(0) { $0 + ($1.logicalBytes ?? 0) } }
    // Fixed token is deliberately unlocalized, shown verbatim beside the field.
    static let clearConfirmation = "EMPTY"
}

struct TrashItemOutcome: Identifiable, Sendable {
    enum Status: String, Sendable { case deleted, retained, notAttempted }
    var id: String { originalURL.path }
    let originalURL: URL
    let status: Status
    let message: String
    let operationURL: URL?
}

struct TrashOutcome: Sendable {
    let items: [TrashItemOutcome]
}

struct TrashProgress: Sendable {
    let finished: Int
    let total: Int
    let currentPath: String?
}

struct TrashRecord: Codable, Equatable, Sendable, Identifiable {
    enum State: String, Codable, Sendable { case captureIntent, captured, deleting, deleted, retained }
    let id: UUID
    let sequence: Int
    let originalURL: URL
    let originalParent: InstallerFileSnapshot
    let operationURL: URL
    let operationIdentity: InstallerFileSnapshot
    let approvedManifest: CleanupManifest
    let capturedManifest: CleanupManifest?
    let state: State
    let recordedAt: Date
    func advancing(_ state: State, captured: CleanupManifest? = nil) -> Self {
        .init(id: id, sequence: sequence + 1, originalURL: originalURL, originalParent: originalParent,
              operationURL: operationURL, operationIdentity: operationIdentity, approvedManifest: approvedManifest,
              capturedManifest: captured ?? capturedManifest, state: state, recordedAt: Date())
    }
}

struct TrashRecoverySummary: Sendable {
    let originalURL: URL
    let state: TrashRecord.State
    let recordedAt: Date
}

struct TrashRecoveryItem: Identifiable, Sendable {
    let id: UUID
    let operationURL: URL
    let record: TrashRecoverySummary?
    let issue: String?
}

protocol TrashExecuting: Sendable {
    func inspect(context: TrashContext) async throws -> TrashInspection
    func inspect(context: TrashContext, progress: @escaping @Sendable (DirectoryScanProgress) -> Void) async throws -> TrashInspection
    func prepare(inspectionID: UUID, selectedPaths: Set<String>, action: TrashRemovalPlan.Action, context: TrashContext) async throws -> TrashRemovalPlan
    func discardPlan() async
    func remove(planID: UUID, context: TrashContext, progress: @escaping @Sendable (TrashProgress) -> Void) async throws -> TrashOutcome
    func readRecords() async throws -> [TrashRecoveryItem]
}

extension TrashExecuting {
    func inspect(context: TrashContext, progress: @escaping @Sendable (DirectoryScanProgress) -> Void) async throws -> TrashInspection {
        try await inspect(context: context)
    }
}

enum TrashFailure: Error, LocalizedError, Sendable {
    case changed, expired, unsupported, unavailable, limit, busy, records
    var errorDescription: String? {
        switch self {
        case .changed: String(localized: "Trash contents or their containing folders changed. Scan again and review a new confirmation.")
        case .expired: String(localized: "This Trash confirmation expired or was already used. Review a new plan.")
        case .unsupported: String(localized: "Ownership, permissions, file flags, cloud metadata, or this volume make this item unsupported. No permissions were changed.")
        case .unavailable: String(localized: "Your home Trash could not be read. Check macOS privacy permissions or inspect it in Finder, then scan again.")
        case .limit: String(localized: "This Trash inventory exceeds the bounded safety budget. Manage larger items in Finder; unknown contents cannot be confirmed here.")
        case .busy: String(localized: "Another Trash operation is still running. Wait for its actual result.")
        case .records: String(localized: "Trash operation records could not be verified. Any retained data is preserved; nothing is retried automatically.")
        }
    }
    static func message(_ error: any Error) -> String {
        if error is CancellationError { return String(localized: "Trash operation cancelled. Already completed deletions cannot be undone; review every item’s actual outcome.") }
        if let error = error as? TrashFailure { return error.errorDescription! }
        if let error = error as? CleanupFailure {
            switch error {
            case .refused(let reason): return reason
            case .limit: return TrashFailure.limit.errorDescription!
            case .changed: return TrashFailure.changed.errorDescription!
            default: return TrashFailure.records.errorDescription!
            }
        }
        return TrashFailure.unsupported.errorDescription!
    }
}
