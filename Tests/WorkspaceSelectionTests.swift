import Foundation
import Testing
@testable import MoeKit

@MainActor
struct WorkspaceSelectionTests {
    private func store(isDemoEnabled: Bool = false) -> WorkspaceStore {
        WorkspaceStore(isDemoEnabled: isDemoEnabled, persistence: CatalogPersistence(directory:
            FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-selection-\(UUID().uuidString)")))
    }

    @Test("Hidden project selection is cleared before any view update or action")
    func projectSearchHidesSelection() {
        let store = store()
        let project = ProjectRecord(name: "alpha", path: "/fixture/alpha", kind: .repository)
        store.projects = [project]
        store.selectedProjectID = project.id
        store.projectSearch = "no match"
        #expect(store.selectedProjectID == nil)
        #expect(store.selectedProject == nil)
        store.presentCleanupReview()
        #expect(store.cleanupReviewProject == nil)
        store.clearProjectFilters()
        #expect(store.selectedProjectID == nil)
        // A stale ID supplied later still cannot bypass visible-row selection.
        store.projectSearch = "no match"
        store.selectedProjectID = project.id
        #expect(store.selectedProject == nil)
        store.presentCleanupReview()
        #expect(store.cleanupReviewProject == nil)
    }

    @Test("Collapsing a parent clears selected hidden children; filtering exposes them")
    func collapsedChildren() {
        let store = store()
        let parent = ProjectRecord(name: "main", path: "/fixture/main", kind: .repository)
        let child = ProjectRecord(name: "work", path: "/fixture/work", kind: .worktree, parentID: parent.id)
        store.projects = [parent, child]
        store.expandedProjectIDs = [parent.id]
        store.selectedProjectID = child.id
        store.toggleExpansion(parent.id)
        #expect(store.selectedProjectID == nil)
        store.projectSearch = "work"
        #expect(store.isProjectExpanded(parent.id))
        store.selectedProjectID = child.id
        #expect(store.selectedProject?.id == child.id)
        store.clearProjectFilters()
        #expect(store.selectedProjectID == nil)
        #expect(!store.isProjectExpanded(parent.id))
    }

    @Test("Project removal and pin filters reconcile selection without a mounted view")
    func projectChanges() {
        let store = store()
        let project = ProjectRecord(name: "alpha", path: "/fixture/alpha", kind: .repository)
        store.projects = [project]
        store.selectedProjectID = project.id
        store.projectFilter = .pinned
        #expect(store.selectedProjectID == nil)
        store.clearProjectFilters()
        store.selectedProjectID = project.id
        store.projects = []
        #expect(store.selectedProjectID == nil)
    }

    @Test("Task search and filters never retain invisible details")
    func taskFilters() {
        let store = store()
        let task = TaskRecord(title: "Discover projects", target: "/fixture/alpha", status: .completed)
        store.tasks = [task]
        store.selectedTaskID = task.id
        store.taskFilter = .attention
        #expect(store.selectedTaskID == nil)
        #expect(store.selectedTask == nil)
        store.clearTaskFilters()
        store.selectedTaskID = task.id
        store.taskSearch = "missing"
        #expect(store.selectedTaskID == nil)
        store.clearTaskFilters()
        #expect(store.selectedTaskID == nil)
        store.taskSearch = "missing"
        store.selectedTaskID = task.id
        #expect(store.selectedTask == nil)
    }

    @Test("A task leaving the active Running filter clears its selected details")
    func taskCompletion() {
        let store = store()
        let task = TaskRecord(title: "Read", target: "/fixture", status: .running)
        store.tasks = [task]
        store.taskFilter = .running
        store.selectedTaskID = task.id
        store.tasks[0].status = .completed
        #expect(store.selectedTaskID == nil)
        #expect(store.filteredTasks.isEmpty)
    }

    @Test("Whitespace is not an active filter and normalized task search matches")
    func normalizedSearch() {
        let store = store()
        let task = TaskRecord(title: "Discover projects", target: "/fixture/alpha", status: .completed)
        store.tasks = [task]
        store.taskSearch = "  Discover \n"
        #expect(store.filteredTasks.map(\.id) == [task.id])
        store.taskSearch = " \n "
        store.projectSearch = " \n "
        #expect(!store.hasTaskFilters)
        #expect(!store.hasProjectFilters)
        #expect(store.filteredTasks.count == 1)
    }

    @Test("Mode boundaries reset filters and Demo counts never reveal real tasks")
    func demoIsolation() {
        let store = store()
        store.tasks = (0..<10).map { TaskRecord(title: "Real \($0)", target: "/fixture", status: .running) }
        store.projectSearch = "private query"
        store.taskSearch = "private task"
        store.toolSearch = "private report"
        store.projectFilter = .pinned
        store.taskFilter = .attention
        store.isDemoEnabled = true
        #expect(store.runningTaskCount == DemoData.tasks.filter { $0.status == .running }.count)
        #expect(store.projectSearch.isEmpty)
        #expect(store.taskSearch.isEmpty)
        #expect(store.toolSearch.isEmpty)
        #expect(!store.hasProjectFilters)
        #expect(!store.hasTaskFilters)
        store.taskSearch = "Demo query"
        store.isDemoEnabled = false
        #expect(store.runningTaskCount == 10)
        #expect(store.taskSearch.isEmpty)
    }

    @Test("Search is contextual and unavailable tool workspaces cannot receive it")
    func contextualSearch() {
        let store = store()
        #expect(store.workspaceSearchPrompt == String(localized: "Search projects"))
        #expect(store.canSearchWorkspace)
        store.section = .tasks
        #expect(store.workspaceSearchPrompt == String(localized: "Search tasks"))
        store.section = .tools
        store.selectedCapability = .clean
        #expect(!store.canSearchWorkspace)
        store.selectedCapability = .space
        #expect(store.canSearchWorkspace)
        #expect(store.workspaceSearchPrompt == String(localized: "Search report entries"))
        store.selectedToolID = ProcessModule.id
        #expect(store.canSearchWorkspace)
        #expect(store.workspaceSearchPrompt == String(localized: "Search processes and ports"))
        store.isDemoEnabled = true
        #expect(!store.canSearchWorkspace)
    }
}
