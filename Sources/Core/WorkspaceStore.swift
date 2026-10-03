import AppKit
import Foundation
import Observation

@MainActor @Observable
final class WorkspaceStore {
    var section: WorkspaceSection = .projects
    var projectFilter: ProjectFilter = .all { didSet { reconcileProjectSelection() } }
    var taskFilter: TaskFilter = .all { didSet { reconcileTaskSelection() } }
    var selectedCapability: MoleCapability = .space
    var selectedToolID = MoleModule.id
    let processes = ProcessInventoryStore()
    var projectSearch = "" { didSet { reconcileProjectSelection() } }
    var taskSearch = "" { didSet { reconcileTaskSelection() } }
    var toolSearch = ""
    var selectedProjectID: ProjectRecord.ID?
    var selectedTaskID: TaskRecord.ID?
    var cleanupReviewProjectID: ProjectRecord.ID?
    var expandedProjectIDs: Set<UUID> = [DemoData.projects[0].id] { didSet { reconcileProjectSelection() } }
    var isInspectorPresented = false
    var isDemoEnabled: Bool {
        didSet {
            processes.resetForModeChange()
            if isDemoEnabled { scanTask?.cancel(); importTask?.cancel() }
            selectedProjectID = nil
            cleanupReviewProjectID = nil
            selectedTaskID = nil
            pendingDiscovery = nil
            importSelection = []
            scanProgress = nil
            clearProjectFilters()
            clearTaskFilters()
            toolSearch = ""
        }
    }
    var projects: [ProjectRecord] = [] { didSet { reconcileProjectSelection() } }
    var tasks: [TaskRecord] = [] { didSet { reconcileTaskSelection() } }
    var pendingDiscovery: RepositoryScanResult?
    var importSelection: Set<String> = []
    var importedReport: MoleAnalyzeReport?
    var importedAt: Date?
    var errorMessage: String?
    private(set) var scanProgress: RepositoryScanProgress?
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
        processes.onEvent = { [weak self] event in self?.recordProcessEvent(event) }
        do { projects = try persistence.load() }
        catch {
            catalogIsWritable = false
            errorMessage = String(localized: "The project catalog could not be read. Existing data was not replaced.")
        }
    }

    private func recordProcessEvent(_ event: ProcessInventoryEvent) {
        switch event {
        case let .started(id, at):
            tasks.insert(TaskRecord(id: id, title: String(localized: "Inspect processes"),
                                    target: String(localized: "Current user · read-only"), tool: String(localized: "Processes & Ports"),
                                    startedAt: at, status: .running), at: 0)
        case let .finished(id, status, count):
            let summary: String
            switch status {
            case .completed, .partial: summary = String(localized: "Observed \(count) processes. No processes were changed.")
            case .cancelled: summary = String(localized: "Process scan cancelled. No processes were changed.")
            default: summary = String(localized: "The process snapshot could not be read. No processes were changed.")
            }
            finishTask(id, status: status, summary: summary,
                       diagnostics: "Read-only native snapshot. No argv, environment, process paths or process history stored in this task.")
        }
    }

    var displayedProjects: [ProjectRecord] { isDemoEnabled ? DemoData.projects : projects }
    var displayedTasks: [TaskRecord] { isDemoEnabled ? DemoData.tasks : tasks }
    var selectedProject: ProjectRecord? { projectRows(sortedBy: []).first { $0.id == selectedProjectID } }
    var hasProjectFilters: Bool { projectFilter != .all || !projectSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasTaskFilters: Bool { taskFilter != .all || !taskSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSearchWorkspace: Bool {
        guard pendingDiscovery == nil else { return false }
        return section != .tools || (selectedToolID == ProcessModule.id ? !isDemoEnabled : selectedCapability == .space)
    }
    var workspaceSearchPrompt: String {
        switch section {
        case .projects: String(localized: "Search projects")
        case .tasks: String(localized: "Search tasks")
        case .tools: selectedToolID == ProcessModule.id ? String(localized: "Search processes and ports") : String(localized: "Search report entries")
        }
    }
    func clearProjectFilters() { projectSearch = ""; projectFilter = .all }
    func clearTaskFilters() { taskSearch = ""; taskFilter = .all }
    private func reconcileProjectSelection() {
        if let id = selectedProjectID, !projectRows(sortedBy: []).contains(where: { $0.id == id }) { selectedProjectID = nil }
    }
    private func reconcileTaskSelection() {
        if let id = selectedTaskID, !filteredTasks.contains(where: { $0.id == id }) { selectedTaskID = nil }
    }
    var cleanupReviewProject: ProjectRecord? {
        guard !isDemoEnabled else { return nil }
        return projects.first { $0.id == cleanupReviewProjectID && $0.kind != .group }
    }
    func presentCleanupReview() {
        guard !isDemoEnabled, let project = selectedProject, project.kind != .group else { return }
        cleanupReviewProjectID = project.id
    }
    var selectedTask: TaskRecord? { filteredTasks.first { $0.id == selectedTaskID } }
    var runningTaskCount: Int { displayedTasks.filter { $0.status == .running }.count }
    var filteredTasks: [TaskRecord] {
        let query = taskSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayedTasks.filter { task in
            let filterMatches = taskFilter == .all || (taskFilter == .running && task.status == .running)
                || (taskFilter == .attention && [.partial, .failed].contains(task.status))
            return filterMatches && (query.isEmpty || [task.title, task.target, task.tool].contains { $0.localizedStandardContains(query) })
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
            let expand = expandedProjectIDs.contains(root.id) || !query.isEmpty || projectFilter != .all
            return [root] + (expand ? children.filter { matchingIDs.contains($0.id) }.sorted(using: order) : [])
        }
    }

    func hasProjectChildren(_ id: UUID) -> Bool { displayedProjects.contains { $0.parentID == id } }
    func isProjectExpanded(_ id: UUID) -> Bool { expandedProjectIDs.contains(id) || hasProjectFilters }

    func toggleExpansion(_ id: UUID) {
        if expandedProjectIDs.contains(id) { expandedProjectIDs.remove(id) } else { expandedProjectIDs.insert(id) }
    }

    func chooseProject(scanChildren: Bool) {
        guard !isDemoEnabled, !isScanning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = scanChildren
        panel.prompt = scanChildren ? String(localized: "Discover") : String(localized: "Add project")
        panel.message = scanChildren
            ? String(localized: "Discover repositories in up to 32 selected folders, up to 4 levels each. One shared budget applies. Dependencies and symbolic links are skipped.")
            : String(localized: "Add this folder to MoeKit. Project files will not be changed.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        startDiscovery(roots: panel.urls, scanChildren: scanChildren)
    }

    func startDiscovery(root: URL, scanChildren: Bool) {
        startDiscovery(roots: [root], scanChildren: scanChildren)
    }

    func startDiscovery(roots: [URL], scanChildren: Bool) {
        guard !isDemoEnabled, !isScanning, !roots.isEmpty else { return }
        isScanning = true
        scanProgress = nil
        pendingDiscovery = nil
        importSelection = []
        let taskID = UUID()
        tasks.insert(TaskRecord(id: taskID, title: String(localized: "Discover projects"),
            target: roots.map(\.path).joined(separator: "\n"), status: .running), at: 0)
        scanTask = Task { [weak self, scanner] in
            guard let self else { return }
            let scopedRoots = roots.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                for root in scopedRoots { root.stopAccessingSecurityScopedResource() }
                self.isScanning = false; self.scanTask = nil; self.scanProgress = nil
            }
            do {
                let result: RepositoryScanResult
                if scanChildren {
                    result = try await scanner.scan(roots: roots, options: ScanOptions(), progress: { [weak self] progress in
                        await self?.receiveDiscoveryProgress(progress)
                    })
                } else {
                    result = try await scanner.inspectFolder(roots[0])
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
                                diagnostics: "Visited directories: \(result.visitedDirectories)\nEnumerated entries: \(result.enumeratedEntries)\nSelected roots: \(roots.count)\nLimit reached: \(result.wasLimited)\nRead-only. No Git status, scripts, hooks or processes were run.")
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
    private func receiveDiscoveryProgress(_ progress: RepositoryScanProgress) {
        guard isScanning, !isDemoEnabled, !Task.isCancelled else { return }
        scanProgress = progress
    }

    private func addDiscovered(_ items: [DiscoveredRepository]) {
        projects = ProjectCatalog.merging(items, into: projects)
        for item in items {
            if let record = projects.first(where: { $0.path == item.url.path }) {
                selectedProjectID = record.id
                if let parentID = record.parentID { expandedProjectIDs.insert(parentID) }
            }
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
