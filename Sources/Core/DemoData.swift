import Foundation

/// These fixtures are visible only in explicitly enabled Demo mode.
/// No task here represents an executed operation or a discovered user file.
enum DemoData {
    static let projects: [ProjectRecord] = {
        let group = UUID(uuidString: "CDA5D7C2-CBE0-4B48-BECA-954D6122E552")!
        var records = [
            ProjectRecord(id: group, name: "MoeKit", path: "", kind: .group, lastOpened: .now, isPinned: true),
            ProjectRecord(name: "Main working directory", path: "/Users/demo/Code/MoeKit", kind: .repository,
                          branch: "main", lastOpened: .now.addingTimeInterval(-180), parentID: group, demoChangeCount: 0),
            ProjectRecord(name: "feature-menu", path: "/Users/demo/Code/MoeKit-menu", kind: .worktree,
                          branch: "feature-menu", lastOpened: .now, parentID: group, demoChangeCount: 3),
        ]
        let names = ["prompt-lab", "motion-playground", "Art assets", "docs-site", "mac-scripts", "notes-exporter",
                     "playground", "image-toolbox", "tiny-api", "Client assets", "dotfiles", "swift-notes", "video-utils",
                     "layout-study", "archive-tools", "Sound library", "website-v2"]
        records += names.enumerated().map { index, name in
            ProjectRecord(name: name, path: "/Users/demo/Code/\(name)",
                          kind: name.contains(" ") ? .folder : .repository,
                          branch: name.contains(" ") ? nil : (index == 1 ? "feat/timeline" : "main"),
                          lastOpened: .now.addingTimeInterval(-Double(index + 1) * 1800),
                          isPinned: index == 0, demoChangeCount: index == 1 ? 2 : 0, demoUnavailable: name == "archive-tools")
        }
        return records
    }()

    static let tasks: [TaskRecord] = (0..<12).map { index in
        TaskRecord(title: index == 1 ? String(localized: "Review project outputs") : String(localized: "Discover projects"),
                   target: index.isMultiple(of: 2) ? "/Users/demo/Code" : "MoeKit / feature-menu",
                   tool: index == 1 ? "Mole" : "MoeKit",
                   startedAt: .now.addingTimeInterval(-Double(index + 1) * 600),
                   endedAt: .now.addingTimeInterval(-Double(index + 1) * 600 + 6),
                   status: index == 1 ? .partial : (index == 8 ? .cancelled : .completed),
                   summary: String(localized: "Example result. No files were changed."),
                   items: [
                       TaskItemResult(path: "/Users/demo/Code/MoeKit/.build", outcome: String(localized: "Review only"), detail: String(localized: "Example data"), hasIssue: false),
                       TaskItemResult(path: "/Users/demo/Code/demo/dist", outcome: String(localized: "Review only"), detail: String(localized: "Example data"), hasIssue: false),
                       TaskItemResult(path: "/Users/demo/Code/demo/node_modules", outcome: String(localized: "Not read"), detail: String(localized: "Example permission issue"), hasIssue: true),
                   ], diagnostics: String(localized: "Demo fixture. No process was started."), isDemo: true)
    }
}
