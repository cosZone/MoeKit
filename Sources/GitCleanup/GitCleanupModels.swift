import Foundation

enum GitCleanupFailure: Error, LocalizedError, Equatable {
    case unsupported, scope, dirty, uniqueCommits, locked, changed, expired, helper, budget, occupied, partial(String), inspectionChanged(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: "This Git layout or configuration is not supported. No force option is available."
        case .scope: "Choose one folder containing both the main repository and the linked worktree. Links and unrelated project boundaries are protected."
        case .dirty: "The worktree has staged, modified, untracked, ignored, or unsupported files. Preserve them before retiring it."
        case .uniqueCommits: "The selected branch is not fully contained in the selected local base branch. No remote fetch was attempted."
        case .locked: "A Git lock, operation in progress, or checked-out branch protects this target."
        case .changed: "The repository changed since review. Nothing further will be moved; inspect again."
        case .expired: "This confirmation expired or was already used. Inspect again."
        case .helper: "The Apple Git object inspector is unavailable or failed. Install Apple Command Line Tools or Xcode, then inspect again."
        case .budget: "This repository exceeds the bounded inspection budget. Use Git directly for this repository."
        case .occupied: "The destination already exists. Nothing will be overwritten."
        case .partial(let path): "The operation stopped with data retained at \(path). Do not delete that recovery folder."
        case .inspectionChanged(let stage): "Inspection stopped because a filesystem identity changed during \(stage). Inspect again."
        }
    }
}

enum GitCleanupInspectionStage {
    /// Stable stage labels only; never serialize repository bytes or stderr.
    static func check<Value>(_ name: String, _ operation: () throws -> Value) throws -> Value {
        do { return try operation() }
        catch InstallerTrashFailure.changed { throw GitCleanupFailure.inspectionChanged(name) }
    }
}

enum GitCleanupAction: String, Sendable, CaseIterable, Identifiable {
    case retireWorktree, deleteBranch
    var id: Self { self }
    var title: String { self == .retireWorktree ? "Retire linked worktree" : "Delete merged local branch" }
}

struct GitCleanupRequest: Equatable, Sendable {
    let scope: URL
    let project: ProjectRecord
    let baseBranch: String
    let branch: String
    let action: GitCleanupAction
    var protectedPaths: [String] = []
}

struct GitCleanupPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: GitCleanupRequest
    let commonDirectory: URL
    let registration: URL?
    let recovery: URL
    let targetOID: String
    let baseOID: String
    let fingerprint: String
    let preparedAt: Date
    let bytes: Int64
    let gitVersion: String
}

struct GitCleanupReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    let plan: GitCleanupPlan
    let recoveryIdentity: InstallerFileSnapshot
    let payloadIdentity: InstallerFileSnapshot
    let registrationIdentity: InstallerFileSnapshot?
    let commonIdentity: InstallerFileSnapshot
    let scopeIdentity: InstallerFileSnapshot
    let destinationParentIdentity: InstallerFileSnapshot
    let registrationParentIdentity: InstallerFileSnapshot?
}

/// Session-bound cancellation/one-use authority. Display models are never authority.
final class GitCleanupPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
    func consume() throws {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw GitCleanupFailure.expired }
        valid = false
    }
}
