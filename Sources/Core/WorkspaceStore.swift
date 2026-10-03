import AppKit
import Foundation
import Observation

@MainActor @Observable
final class WorkspaceStore {
    var section: WorkspaceSection = .projects
    var projectFilter: ProjectFilter = .all
    var taskFilter: TaskFilter = .all
    var selectedCapability: MoleCapability = .space
    var projectSearch = ""
    var taskSearch = ""
    var toolSearch = ""
    var selectedProjectID: ProjectRecord.ID?
    var selectedTaskID: TaskRecord.ID?
    var expandedProjectIDs: Set<UUID> = [DemoData.projects[0].id]
    var isInspectorPresented = false
    var isDemoEnabled: Bool {
        didSet {
            if isDemoEnabled { scanTask?.cancel(); importTask?.cancel() }
            selectedProjectID = nil
            selectedTaskID = nil
            pendingDiscovery = nil
        }
    }
    var projects: [ProjectRecord] = []
    var tasks: [TaskRecord] = []
    var pendingDiscovery: RepositoryScanResult?
    var importSelection: Set<String> = []
    var importedReport: MoleAnalyzeReport?
    var importedAt: Date?
    var errorMessage: String?
    private(set) var isScanning = false
    private(set) var isImporting = false
    let registry = ToolModuleRegistry.builtIn
    @ObservationIgnored private let scanner = RepositoryScanner()
    @ObservationIgnored private let reportImporter = MoleReportImporter()
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private let persistence: CatalogPersistence
    @ObservationIgnored private var catalogIsWritable = true
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(isDemoEnabled: Bool = ProcessInfo.processInfo.arguments.contains("--demo"), persistence: CatalogPersistence = .init()) {
        self.isDemoEnabled = isDemoEnabled
        self.persistence = persistence
        do { projects = try persistence.load() }
        catch {
            catalogIsWritable = false
            errorMessage = String(localized: "The project catalog could not be read. Existing data was not replaced.")
        }
    }

    var displayedProjects: [ProjectRecord] { isDemoEnabled ? DemoData.projects : projects }
    var displayedTasks: [TaskRecord] { isDemoEnabled ? DemoData.tasks : tasks }
    var selectedProject: ProjectRecord? { displayedProjects.first { $0.id == selectedProjectID } }
    var selectedTask: TaskRecord? { displayedTasks.first { $0.id == selectedTaskID } }
    var runningTaskCount: Int { tasks.filter { $0.status == .running }.count }
    var filteredTasks: [TaskRecord] {
        displayedTasks.filter { task in
            let filterMatches = taskFilter == .all || (taskFilter == .running && task.status == .running)
                || (taskFilter == .attention && [.partial, .failed].contains(task.status))
            return filterMatches && (taskSearch.isEmpty || [task.title, task.target, task.tool].contains { $0.localizedStandardContains(taskSearch) })
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func projectRows(sortedBy order: [KeyPathComparator<ProjectRecord>]) -> [ProjectRecord] {
        let all = displayedProjects
        let query = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = all.filter { item in
            let filterMatches = projectFilter == .all || (projectFilter == .pinned && item.isPinned)
                || (projectFilter == .recent && item.lastOpened != nil)
            return filterMatches && item.matches(query)
        }
        let matchingIDs = Set(matching.map(\.id))
        let roots = all.filter { item in
            item.parentID == nil && (matchingIDs.contains(item.id) || all.contains { $0.parentID == item.id && matchingIDs.contains($0.id) })
        }.sorted(using: order)
        return roots.flatMap { root in
            let children = all.filter { $0.parentID == root.id }
            if children.isEmpty { return [root] }
            let expand = expandedProjectIDs.contains(root.id) || !query.isEmpty
            return [root] + (expand ? children.filter { matchingIDs.contains($0.id) }.sorted(using: order) : [])
        }
    }

    func toggleExpansion(_ id: UUID) {
        if expandedProjectIDs.contains(id) { expandedProjectIDs.remove(id) } else { expandedProjectIDs.insert(id) }
    }

    func chooseProject(scanChildren: Bool) {
        guard !isDemoEnabled, !isScanning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = scanChildren ? String(localized: "Discover") : String(localized: "Add project")
        panel.message = scanChildren
            ? String(localized: "Discover repositories in this folder, up to 4 levels. Dependencies and symbolic links are skipped.")
            : String(localized: "Add this folder to MoeKit. Project files will not be changed.")
        guard panel.runModal() == .OK, let root = panel.url else { return }
        startDiscovery(root: root, scanChildren: scanChildren)
    }

    func startDiscovery(root: URL, scanChildren: Bool) {
        guard !isDemoEnabled, !isScanning else { return }
        isScanning = true
        let taskID = UUID()
        tasks.insert(TaskRecord(id: taskID, title: String(localized: "Discover projects"), target: root.path, status: .running), at: 0)
        scanTask = Task { [weak self, scanner] in
            guard let self else { return }
            defer { self.isScanning = false; self.scanTask = nil }
            do {
                let result: RepositoryScanResult
                if scanChildren {
                    result = try await scanner.scan(root: root, options: ScanOptions())
                } else {
                    result = try await scanner.inspectFolder(root)
                }
                try Task.checkCancellation()
                guard !self.isDemoEnabled else { throw CancellationError() }
                if scanChildren {
                    self.pendingDiscovery = result
                    self.importSelection = Set(result.items.map(\.id))
                } else {
                    self.addDiscovered(result.items)
                }
                self.finishTask(taskID, status: result.issues.isEmpty && !result.wasLimited ? .completed : .partial,
                                summary: String(localized: "Found \(result.items.count) projects in the selected scope."),
                                items: result.issues.map { TaskItemResult(path: $0.url.path, outcome: String(localized: "Not fully read"), detail: $0.message, hasIssue: true) },
                                diagnostics: "Visited directories: \(result.visitedDirectories)\nLimit reached: \(result.wasLimited)\nRead-only. No Git status, scripts, hooks or processes were run.")
            } catch is CancellationError {
                self.finishTask(taskID, status: .cancelled, summary: String(localized: "Discovery cancelled. No files were changed."))
            } catch {
                self.finishTask(taskID, status: .failed, summary: error.localizedDescription)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelScan() { scanTask?.cancel() }
    func importDiscoveredProjects() {
        guard let result = pendingDiscovery, !isDemoEnabled else { return }
        addDiscovered(result.items.filter { importSelection.contains($0.id) })
        pendingDiscovery = nil
    }
    private func addDiscovered(_ items: [DiscoveredRepository]) {
        for item in items where !projects.contains(where: { $0.path == item.url.path }) {
            let kind: ProjectKind
            switch item.kind {
            case .folder: kind = .folder
            case .gitRepository: kind = .repository
            case .gitWorktree: kind = .linkedGitDirectory
            }
            let record = ProjectRecord(name: item.name, path: item.url.path, kind: kind, branch: item.branch)
            projects.append(record)
            selectedProjectID = record.id
        }
        saveCatalog()
    }
    func togglePin(_ id: UUID) {
        guard !isDemoEnabled, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].isPinned.toggle(); saveCatalog()
    }
    func revealSelectedProject() {
        guard !isDemoEnabled, let project = selectedProject, project.kind != .group else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].lastOpened = .now; saveCatalog()
        }
    }
    private func saveCatalog() {
        guard catalogIsWritable else {
            errorMessage = String(localized: "The existing catalog could not be read. Changes are temporary until the catalog is recovered; the original file was not overwritten.")
            return
        }
        do { try persistence.save(projects) }
        catch { errorMessage = String(localized: "Changes could not be saved: \(error.localizedDescription)") }
    }
    private func finishTask(_ id: UUID, status: TaskStatus, summary: String, items: [TaskItemResult] = [], diagnostics: String = "") {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = status; tasks[index].endedAt = .now
        tasks[index].summary = summary; tasks[index].items = items; tasks[index].diagnostics = diagnostics
    }
    func chooseMoleReport() {
        guard !isDemoEnabled, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Import report")
        panel.message = String(localized: "Choose a Mole analyze --json report. Importing does not execute Mole or modify the reported files.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        importTask = Task { [weak self, reportImporter] in
            guard let self else { return }
            defer { self.isImporting = false; self.importTask = nil }
            do {
                let report = try await reportImporter.load(url)
                try Task.checkCancellation()
                guard !self.isDemoEnabled else { return }
                self.importedReport = report
                self.importedAt = .now
            } catch is CancellationError {
                // Preserve the previous report when an import is cancelled.
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
}
