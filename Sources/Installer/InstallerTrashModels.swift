import Foundation

struct InstallerFileSnapshot: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let uid: UInt32
    let gid: UInt32
    let links: UInt64
    let flags: UInt32
    let bytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    /// Our own rename can change ctime. No other approved field may change.
    func matchesCaptured(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode && uid == other.uid && gid == other.gid
            && links == other.links && flags == other.flags && bytes == other.bytes
            && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
    func matchesDirectory(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode && uid == other.uid && gid == other.gid && flags == other.flags
    }
}

struct InstallerTrashScope: Equatable, Sendable {
    let generation: UUID
    let liveAnalysisID: UUID
    let liveDirectory: URL
    let liveEntryPaths: Set<String>
    let protectedPaths: [String]
    let catalogIsKnown: Bool
}

/// Display data only. The executor separately holds the original descriptors and
/// one-use authorization state. A decoded report/receipt cannot construct that state.
struct InstallerTrashPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let scope: InstallerTrashScope
    let originalURL: URL
    let downloadsURL: URL
    let recoveryURL: URL
    let file: InstallerFileSnapshot
    let preparedAt: Date
    let expiresAt: Date
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file) }
}

enum InstallerReceiptState: String, Codable, Hashable, Sendable {
    case captureIntent, captured, trashIntent, trashed, rollbackIntent, rolledBack, retained, uncertain
    case restoreCaptureIntent, restoreCaptured, restoreIntent, restored
}

struct InstallerTrashReceipt: Identifiable, Codable, Equatable, Sendable {
    static let policyVersion = 1
    let policy: Int
    let id: UUID
    let sequence: Int
    let originalURL: URL
    let originalParent: InstallerFileSnapshot
    let originalFile: InstallerFileSnapshot
    let operationURL: URL
    let operationDirectory: InstallerFileSnapshot
    let state: InstallerReceiptState
    let recordedAt: Date
    let payloadName: String?
    let trashURL: URL?
    let trashFile: InstallerFileSnapshot?
    /// Exact post-mutation snapshot, distinct from the immutable approved file.
    /// Kept as a value field with a default for old/incomplete records; absence
    /// is never authority to restore.
    var payloadFile: InstallerFileSnapshot? = nil

    var canOfferRestore: Bool {
        if state == .trashed { return trashFile != nil }
        guard state == .captured || state == .retained || state == .restoreCaptured,
              let payloadFile else { return false }
        return originalFile.matchesCaptured(payloadFile)
    }
}

struct InstallerRecoveryItem: Identifiable, Sendable {
    let id: UUID
    let operationURL: URL
    let receipt: InstallerTrashReceipt?
    let issue: String?
}

struct InstallerRecoveryContext: Equatable, Sendable {
    let generation: UUID
    let protectedPaths: [String]
    let catalogIsKnown: Bool
}

struct InstallerRestorePlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let receipt: InstallerTrashReceipt
    let sourceURL: URL
    let context: InstallerRecoveryContext
    let preparedAt: Date
    let expiresAt: Date
}

struct InstallerTrashOutcome: Sendable {
    let receipt: InstallerTrashReceipt?
    let message: String
    let movedToTrash: Bool
    let requiresRecovery: Bool
}

protocol InstallerTrashExecuting: Sendable {
    func prepare(selection: URL, scope: InstallerTrashScope) async throws -> InstallerTrashPlan
    func discardPlans() async
    func moveToTrash(planID: UUID, scope: InstallerTrashScope) async throws -> InstallerTrashOutcome
    func recoveryReceipts() async throws -> [InstallerRecoveryItem]
    func validatedRecoveryLocation(receiptID: UUID) async throws -> URL
    func prepareRestore(receiptID: UUID, context: InstallerRecoveryContext) async throws -> InstallerRestorePlan
    func restore(planID: UUID, context: InstallerRecoveryContext) async throws -> InstallerTrashOutcome
}

enum InstallerTrashFailure: Error, Equatable, LocalizedError, Sendable {
    case unsupported, changed, protected, unavailable(String), expired, busy, unsafeRecovery, journal, collision, unsupportedRename, cancelled
    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Choose one regular .dmg directly inside your local Downloads folder. Folders, .pkg files, links, cloud storage and external volumes are unsupported.")
        case .changed: String(localized: "The selected file or a containing folder changed. Review a new plan; no replacement is authorized.")
        case .protected: String(localized: "Project, worktree and Git metadata locations are protected. A readable project catalog is required.")
        case .unavailable(let reason): reason
        case .expired: String(localized: "This confirmation expired or was already used. Review a new plan.")
        case .busy: String(localized: "Another MoeKit file operation is active. Nothing was replaced.")
        case .unsafeRecovery: String(localized: "Private recovery storage could not be validated. Existing files and permissions were left unchanged.")
        case .journal: String(localized: "A durable recovery record could not be saved. Any captured file is retained; review recovery before trying again.")
        case .collision: String(localized: "The destination already exists. MoeKit will not replace it.")
        case .unsupportedRename: String(localized: "This filesystem did not support the required same-device, no-overwrite move. There is no copy or deletion fallback.")
        case .cancelled: String(localized: "The operation was cancelled. Review the receipt for the file's actual location.")
        }
    }
}
