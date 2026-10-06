import Foundation

/// Native cache operations are independent of Mole's external analysis process.
/// Display values and decoded receipts are never executable authorization.
struct CleanupContext: Equatable, Sendable {
    let generation: UUID
    let protectedPaths: [String]
    let catalogIsKnown: Bool
}

struct CleanupEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case directory, file, symbolicLink }
    let relativePath: String
    let kind: Kind
    let identity: InstallerFileSnapshot
    let linkDestination: Data?
}

struct CleanupManifest: Codable, Equatable, Sendable {
    let entries: [CleanupEntry]
    let logicalBytes: Int64
    var itemCount: Int { entries.count }
}

struct CleanupCandidate: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    let evidence: String
    let manifest: CleanupManifest?
    let blocker: String?
    var sizeEstimate: DiskUsageEstimate? = nil
    var isEligible: Bool { manifest != nil && blocker == nil }
    var displayedSize: String {
        if let manifest { return ByteCountFormatter.string(fromByteCount: manifest.logicalBytes, countStyle: .file) }
        return sizeEstimate?.formattedSize ?? String(localized: "Unknown")
    }
}

struct CleanupInspection: Equatable, Sendable {
    let id: UUID
    let rootURL: URL
    let candidates: [CleanupCandidate]
    let context: CleanupContext
    let observedAt: Date
    var listingIsComplete = true
    var issues: [String] = []
}

struct CleanupTarget: Codable, Equatable, Sendable {
    let originalURL: URL
    let evidence: String
    let manifest: CleanupManifest
}

struct CleanupPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let inspectionID: UUID
    let rootURL: URL
    let targets: [CleanupTarget]
    let context: CleanupContext
    let recoveryRoot: URL
    let preparedAt: Date
    let expiresAt: Date
    var logicalBytes: Int64 { targets.reduce(0) { $0 + $1.manifest.logicalBytes } }
}

enum CleanupReceiptState: String, Codable, Sendable {
    case captureIntent, staged, trashIntent, trashed, restoreIntent, restored
    case restoreCaptureIntent, restoreStaged
    case deleteCaptureIntent, deleteStaged, deleteIntent, deleted, retained, uncertain
}

struct CleanupReceipt: Identifiable, Codable, Equatable, Sendable {
    var policy: Int = 1
    let id: UUID
    let sequence: Int
    let target: CleanupTarget
    let originalParent: InstallerFileSnapshot
    let operationURL: URL
    let operationIdentity: InstallerFileSnapshot
    let state: CleanupReceiptState
    let payloadURL: URL?
    let manifest: CleanupManifest
    let recordedAt: Date
    var canRestore: Bool { state == .trashed || state == .staged || state == .retained || state == .deleteStaged || state == .restoreStaged }
    /// Only a verified completed Trash receipt, never arbitrary Trash contents.
    var canDeletePermanently: Bool { state == .trashed }
}

struct CleanupItemOutcome: Identifiable, Sendable {
    let id: UUID
    let originalURL: URL
    let receipt: CleanupReceipt?
    let message: String
    let succeeded: Bool
    let requiresRecovery: Bool
}

struct CleanupOutcome: Sendable {
    let items: [CleanupItemOutcome]
}

struct CleanupRecoveryItem: Identifiable, Sendable {
    let id: UUID
    let operationURL: URL
    let receipt: CleanupReceipt?
    let issue: String?
}

struct CleanupRecoveryPlan: Identifiable, Equatable, Sendable {
    enum Action: String, Sendable { case restore, deletePermanently }
    let id: UUID
    let action: Action
    let receipt: CleanupReceipt
    let sourceURL: URL
    let context: CleanupContext
    let preparedAt: Date
    let expiresAt: Date
}

protocol CleanupExecuting: Sendable {
    func inspect(root: URL, context: CleanupContext) async throws -> CleanupInspection
    func inspect(root: URL, context: CleanupContext, progress: @escaping @Sendable (DirectoryScanProgress) -> Void) async throws -> CleanupInspection
    func prepare(inspectionID: UUID, selectedPaths: Set<String>, context: CleanupContext) async throws -> CleanupPlan
    func discardPlans() async
    func moveToTrash(planID: UUID, context: CleanupContext) async throws -> CleanupOutcome
    func recoveryRecords() async throws -> [CleanupRecoveryItem]
    func prepareRecovery(receiptID: UUID, action: CleanupRecoveryPlan.Action, context: CleanupContext) async throws -> CleanupRecoveryPlan
    func applyRecovery(planID: UUID, context: CleanupContext) async throws -> CleanupOutcome
}

extension CleanupExecuting {
    func inspect(root: URL, context: CleanupContext, progress: @escaping @Sendable (DirectoryScanProgress) -> Void) async throws -> CleanupInspection {
        try await inspect(root: root, context: context)
    }
}

enum CleanupFailure: Error, LocalizedError, Sendable {
    case refused(String), changed, expired, busy, limit, journal
    var errorDescription: String? {
        switch self {
        case .refused(let reason): reason
        case .changed: String(localized: "The selected cache, contents, or containing folder changed. Inspect again; the old confirmation cannot be reused.")
        case .expired: String(localized: "This cleanup confirmation expired or was already used. Review a new plan.")
        case .busy: String(localized: "Another cleanup operation is active. Wait for its actual result.")
        case .limit: String(localized: "The complete cache inventory exceeded its safety budget. Nothing was authorized; choose a smaller cache folder.")
        case .journal: String(localized: "Cleanup recovery records could not be verified. Retained data will not be removed automatically.")
        }
    }
}
