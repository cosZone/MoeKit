import Foundation
import Testing
@testable import MoeKit

@MainActor
struct GettingStartedTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-guidance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Fresh real catalog offers the guide once without starting or saving anything")
    func firstLaunch() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        #expect(store.showAutomaticGettingStarted())
        #expect(!store.showAutomaticGettingStarted())
        #expect(store.gettingStarted.isPresented)
        #expect(!store.canSearchWorkspace)
        #expect(!store.isScanning && !store.processes.isScanning)
        #expect(store.processes.snapshot == nil && store.importedReport == nil)
        #expect(store.projects.isEmpty && store.tasks.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Skip, close and completion use the same idempotent version-only dismissal")
    func dismissalPersistsOnlyVersion() throws {
        let suite = "MoeKit-guidance-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let guide = GettingStartedState(defaults: defaults)
        #expect(guide.presentAutomatically(hasSavedProjects: false, hasCatalogError: false, isDemo: false))
        guide.selectedGoal = .processes
        guide.dismiss()
        guide.dismiss()
        #expect(!guide.isPresented && guide.selectedGoal == nil)
        #expect(defaults.persistentDomain(forName: suite)?.count == 1)
        #expect(defaults.integer(forKey: GettingStartedState.preferenceKey) == GettingStartedState.currentVersion)
        let nextLaunch = GettingStartedState(defaults: defaults)
        #expect(!nextLaunch.presentAutomatically(hasSavedProjects: false, hasCatalogError: false, isDemo: false))
        #expect(nextLaunch.present())
        #expect(nextLaunch.selectedGoal == nil)
    }

    @Test("An interrupted guide with no dismissal is offered again on the next launch")
    func interruptionBeforeDismissal() throws {
        let suite = "MoeKit-guidance-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let interrupted = GettingStartedState(defaults: defaults)
        #expect(interrupted.presentAutomatically(hasSavedProjects: false, hasCatalogError: false, isDemo: false))
        interrupted.selectedGoal = .demo
        #expect(defaults.object(forKey: GettingStartedState.preferenceKey) == nil)
        #expect(GettingStartedState(defaults: defaults).presentAutomatically(hasSavedProjects: false, hasCatalogError: false, isDemo: false))
    }

    @Test("Back and repeated open preserve a visible guide; reopening a dismissed guide resets it")
    func backAndReopen() {
        let guide = GettingStartedState()
        guide.present()
        guide.selectedGoal = .projects
        guide.present()
        #expect(guide.selectedGoal == .projects)
        guide.back()
        #expect(guide.isPresented && guide.selectedGoal == nil)
        guide.selectedGoal = .demo
        guide.dismiss()
        guide.present()
        #expect(guide.isPresented && guide.selectedGoal == nil)
    }

    @Test("Existing saved projects keep their data and avoid an automatic interruption")
    func existingCatalog() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = CatalogPersistence(directory: root)
        let project = ProjectRecord(name: "Pinned fixture", path: root.appendingPathComponent("project").path, kind: .folder, isPinned: true)
        try persistence.save([project])
        let file = root.appendingPathComponent("projects.json")
        let before = try Data(contentsOf: file)
        let store = WorkspaceStore(isDemoEnabled: false, persistence: persistence)
        #expect(!store.showAutomaticGettingStarted())
        #expect(store.showGettingStarted())
        for goal in GettingStartedGoal.allCases {
            store.openGettingStartedGoal(goal)
            store.gettingStarted.dismiss()
            #expect(store.showGettingStarted())
        }
        store.openGettingStartedGoal(.projects)
        #expect(store.projects == [project])
        #expect(try Data(contentsOf: file) == before)
        #expect(store.tasks.isEmpty && store.processes.snapshot == nil)
    }

    @Test("Catalog errors are never hidden or overwritten by first-run guidance")
    func corruptCatalog() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects.json")
        let before = Data("{incomplete".utf8)
        try before.write(to: file)
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        #expect(store.errorMessage != nil)
        #expect(!store.showAutomaticGettingStarted() && !store.showGettingStarted())
        store.errorMessage = nil // Equivalent to acknowledging the existing error alert.
        #expect(!store.showAutomaticGettingStarted())
        #expect(store.showGettingStarted())
        store.openGettingStartedGoal(.demo)
        store.gettingStarted.dismiss()
        store.openGettingStartedGoal(.projects)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("Explicit demo launch is undisturbed and never writes examples to the catalog")
    func demoLaunch() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(isDemoEnabled: true, persistence: CatalogPersistence(directory: root))
        #expect(!store.showAutomaticGettingStarted())
        #expect(store.isDemoEnabled)
        #expect(store.showGettingStarted())
        store.gettingStarted.dismiss()
        #expect(store.isDemoEnabled)
        #expect(store.projects.isEmpty && store.tasks.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Every guide destination navigates only, including repeated Demo and real mode changes")
    func destinationsDoNotReadOrWrite() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        for goal in [.demo, .demo, .processes, .projects, .demo, .projects] as [GettingStartedGoal] {
            #expect(store.showGettingStarted())
            store.gettingStarted.selectedGoal = goal
            store.openGettingStartedGoal(goal)
            #expect(store.isDemoEnabled == (goal == .demo))
            #expect(store.section == (goal == .processes ? .tools : .projects))
            if goal == .processes { #expect(store.selectedToolID == ProcessModule.id) }
            #expect(!store.isScanning && !store.processes.isScanning)
            #expect(store.processes.snapshot == nil && store.importedReport == nil)
            #expect(store.projects.isEmpty && store.tasks.isEmpty)
            store.gettingStarted.dismiss()
            #expect(store.canSearchWorkspace)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Navigation clears stale workspace filters without starting scans")
    func routeClearsFilters() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        store.projectSearch = "hidden"
        store.projectFilter = .pinned
        store.openGettingStartedGoal(.projects)
        #expect(!store.hasProjectFilters)
        store.processes.search = "hidden"
        store.processes.projectFilterID = UUID()
        store.processes.portFilter = .listening
        store.openGettingStartedGoal(.processes)
        #expect(!store.processes.hasActiveFilters)
        #expect(store.processes.snapshot == nil)
    }

    @Test("Other modal work blocks guide presentation and late destination clicks")
    func modalGuards() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        store.cleanupReviewProjectID = UUID()
        #expect(!store.showGettingStarted() && !store.showAutomaticGettingStarted())
        store.openGettingStartedGoal(.demo)
        #expect(!store.isDemoEnabled)
        store.cleanupReviewProjectID = nil
        #expect(store.showGettingStarted())
        store.errorMessage = "Fixture error"
        store.openGettingStartedGoal(.processes)
        #expect(store.section == .projects)
        store.gettingStarted.dismiss()
        #expect(store.errorMessage == "Fixture error")
    }
}
