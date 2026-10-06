import Foundation

struct GitWorktreeFinishRequest: Equatable, Sendable {
    let scope: URL
    let project: ProjectRecord
    let targetBranch: String
    var protectedPaths: [String] = []
}

struct GitFinishStatus: Equatable, Sendable {
    let stagedChanges: Bool
    let modifiedCount: Int
    /// No ignore rules execute. All extra files, whether ignored or untracked,
    /// are protected; ignored status is explicitly unknown in the interface.
    let untrackedOrIgnoredCount: Int
    let extraDirectoryCount: Int
    var clean: Bool { !stagedChanges && modifiedCount == 0 && untrackedOrIgnoredCount == 0 && extraDirectoryCount == 0 }
}

struct GitWorktreeFinishPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: GitWorktreeFinishRequest
    let sourceBranch: String
    let sourceOID: String
    let targetOID: String
    let targetWorktree: URL?
    let sourceStatus: GitFinishStatus
    let targetStatus: GitFinishStatus?
    let uniqueCommitCount: Int
    let blockers: [String]
    let recovery: URL
    let fingerprint: String
    let preparedAt: Date
    let gitVersion: String
    var canMerge: Bool { blockers.isEmpty && uniqueCommitCount > 0 }
}

struct GitWorktreeFinishResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let plan: GitWorktreeFinishPlan
    let verifiedOID: String
    let recovery: URL
}

protocol GitWorktreeFinishExecuting: Sendable {
    func prepare(_ request: GitWorktreeFinishRequest) async throws -> GitWorktreeFinishPlan
    func merge(_ id: UUID, permit: GitCleanupPermit) async throws -> GitWorktreeFinishResult
}

enum GitWorktreeFinishCheckpoint: Sendable, Equatable {
    case beforeMutation, afterTargetFilesRetained, beforeIndexCommit, beforeRefCommit, afterRefCommit
}
