import Foundation

/// Evidence read from bounded local Git administrative files, never a Git status.
public struct GitDiscoveryMetadata: Codable, Hashable, Sendable {
    public let observedAt: Date
    public let gitDirectoryPath: String
    public let commonDirectoryPath: String
    public let isLinkedWorktree: Bool
    public let isLocked: Bool
}

public struct RepositoryScanProgress: Sendable, Hashable {
    public let root: URL
    public let completedRoots: Int
    public let totalRoots: Int
    public let visitedDirectories: Int
    public let enumeratedEntries: Int
    public let discoveredRepositories: Int
}

/// Read-only review deliberately cannot produce an executable or eligible plan.
/// HEAD, a missing lock file, and a stale discovery snapshot do not prove safety.
struct ProjectCleanupPreview: Sendable, Equatable {
    let path: String
    let reasons: [String]
    let isEligible = false

    init(project: ProjectRecord) {
        path = project.path
        var reasons: [String] = []
        if project.kind != .worktree {
            reasons.append(String(localized: "This is not a verified linked worktree. Repository and folder removal is protected."))
        }
        if project.gitMetadata?.isLocked == true {
            reasons.append(String(localized: "Git marks this worktree as locked. Preserve it until the lock is reviewed."))
        }
        if project.gitMetadata == nil {
            reasons.append(String(localized: "The Git relationship is unknown or unreadable."))
        }
        reasons.append(String(localized: "Uncommitted changes and untracked files have not been checked."))
        reasons.append(String(localized: "Unpushed commits, upstream tracking and remote reachability have not been checked."))
        reasons.append(String(localized: "Active use and ownership have not been verified. A process snapshot cannot prove a directory is unused."))
        reasons.append(String(localized: "Discovery is a snapshot. All safety checks would need to be repeated before any future cleanup."))
        self.reasons = reasons
    }
}

/// Refresh preserves user-managed identity, pinning, display names and history.
/// Relationship parents are derived only from validated common-directory evidence.
enum ProjectCatalog {
    static func merging(_ discovered: [DiscoveredRepository], into existing: [ProjectRecord]) -> [ProjectRecord] {
        var records = existing
        for item in discovered {
            let kind: ProjectKind
            switch item.kind {
            case .folder: kind = .folder
            case .gitRepository: kind = .repository
            case .gitWorktree: kind = item.metadata?.isLinkedWorktree == true ? .worktree : .linkedGitDirectory
            }
            if let index = records.firstIndex(where: { $0.path == item.url.path }) {
                records[index].kind = kind
                records[index].branch = item.branch
                records[index].gitMetadata = item.metadata
            } else {
                records.append(ProjectRecord(name: item.name, path: item.url.path, kind: kind,
                    branch: item.branch, gitMetadata: item.metadata))
            }
        }
        let mainDirectories = records.filter {
            $0.kind == .repository && $0.gitMetadata?.isLinkedWorktree == false
        }
        for index in records.indices where records[index].kind != .group {
            let record = records[index]
            records[index].parentID = nil
            if record.gitMetadata?.isLinkedWorktree == true,
               let common = record.gitMetadata?.commonDirectoryPath,
               let parent = mainDirectories.first(where: { $0.gitMetadata?.gitDirectoryPath == common && $0.id != record.id }) {
                records[index].parentID = parent.id
            }
        }
        return records
    }
}
