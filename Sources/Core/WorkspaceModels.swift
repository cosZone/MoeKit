import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case projects, tools, tasks
    var id: Self { self }
    var title: String {
        switch self {
        case .projects: String(localized: "Projects")
        case .tools: String(localized: "Tools")
        case .tasks: String(localized: "Tasks")
        }
    }
    var symbol: String {
        switch self {
        case .projects: "folder"
        case .tools: "briefcase"
        case .tasks: "list.bullet.rectangle"
        }
    }
}

enum ProjectFilter: String, CaseIterable, Identifiable {
    case all, recent, pinned
    var id: Self { self }
    var title: String {
        switch self {
        case .all: String(localized: "All projects")
        case .recent: String(localized: "Recently opened")
        case .pinned: String(localized: "Pinned")
        }
    }
}

enum ProjectKind: String, Codable, Sendable {
    case folder, repository, worktree, linkedGitDirectory, group
    var symbol: String { self == .folder ? "folder" : "arrow.triangle.branch" }
    var title: String {
        switch self {
        case .folder: String(localized: "Folder")
        case .repository: String(localized: "Git repository")
        case .worktree: String(localized: "Worktree")
        case .linkedGitDirectory: String(localized: "Git working directory")
        case .group: String(localized: "Repository group")
        }
    }
}

struct ProjectRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var kind: ProjectKind
    var branch: String?
    var lastOpened: Date?
    var isPinned: Bool
    var parentID: UUID?
    var demoChangeCount: Int?
    var demoUnavailable: Bool

    init(id: UUID = UUID(), name: String, path: String, kind: ProjectKind,
         branch: String? = nil, lastOpened: Date? = nil, isPinned: Bool = false,
         parentID: UUID? = nil, demoChangeCount: Int? = nil, demoUnavailable: Bool = false) {
        self.id = id; self.name = name; self.path = path; self.kind = kind
        self.branch = branch; self.lastOpened = lastOpened; self.isPinned = isPinned
        self.parentID = parentID; self.demoChangeCount = demoChangeCount
        self.demoUnavailable = demoUnavailable
    }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var sortDate: Date { lastOpened ?? .distantPast }
    var branchLabel: String { branch ?? "—" }
    var status: String {
        if demoUnavailable { return String(localized: "Unavailable") }
        if kind == .folder { return String(localized: "Folder") }
        if kind == .group { return "" }
        if let count = demoChangeCount {
            return count == 0 ? String(localized: "Clean") : String(localized: "\(count) changes")
        }
        return String(localized: "Not checked")
    }
    func matches(_ query: String) -> Bool {
        query.isEmpty || [name, path, branch ?? ""].contains { $0.localizedStandardContains(query) }
    }
}

enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case running, completed, partial, cancelled, failed
    var title: String {
        switch self {
        case .running: String(localized: "Running")
        case .completed: String(localized: "Completed")
        case .partial: String(localized: "Partial result")
        case .cancelled: String(localized: "Cancelled")
        case .failed: String(localized: "Failed")
        }
    }
    var symbol: String {
        switch self {
        case .running: "clock"
        case .completed: "checkmark.circle"
        case .partial: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case all, running, attention
    var id: Self { self }
    var title: String {
        switch self {
        case .all: String(localized: "All tasks")
        case .running: String(localized: "In progress")
        case .attention: String(localized: "Needs attention")
        }
    }
}

struct TaskItemResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let path: String
    let outcome: String
    let detail: String
    let hasIssue: Bool
}

struct TaskRecord: Identifiable, Sendable {
    let id: UUID
    let title: String
    let target: String
    let tool: String
    let startedAt: Date
    var endedAt: Date?
    var status: TaskStatus
    var summary: String
    var items: [TaskItemResult]
    var diagnostics: String
    let isDemo: Bool

    init(id: UUID = UUID(), title: String, target: String, tool: String = "MoeKit",
         startedAt: Date = .now, endedAt: Date? = nil, status: TaskStatus,
         summary: String = "", items: [TaskItemResult] = [], diagnostics: String = "", isDemo: Bool = false) {
        self.id = id; self.title = title; self.target = target; self.tool = tool
        self.startedAt = startedAt; self.endedAt = endedAt; self.status = status
        self.summary = summary; self.items = items; self.diagnostics = diagnostics; self.isDemo = isDemo
    }
    var duration: String {
        guard let endedAt else { return "—" }
        let seconds = max(0, Int(endedAt.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
