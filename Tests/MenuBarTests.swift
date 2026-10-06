import AppKit
import Testing
import Observation
@testable import MoeKit

@MainActor
struct MenuBarTests {
    @Test func truthfulTaskStatesAndModeIsolation() {
        let now = Date()
        let completed = TaskRecord(title: "Synthetic discovery", target: "/Synthetic", startedAt: now,
                                   endedAt: now.addingTimeInterval(1), status: .completed)
        let partial = TaskRecord(title: "Synthetic partial scan", target: "/Synthetic", startedAt: now,
                                 endedAt: now.addingTimeInterval(2), status: .partial)
        let running = TaskRecord(title: "Synthetic process scan", target: "/Synthetic", startedAt: now,
                                 status: .running)
        let demo = TaskRecord(title: "Example", target: "/Example", status: .running, isDemo: true)
        #expect(MenuBarSnapshot.summarize(tasks: [], isDemo: false, isBusy: false, hasIssue: false).activity == .idle)
        #expect(MenuBarSnapshot.summarize(tasks: [completed], isDemo: false, isBusy: false, hasIssue: false).activity == .completed)
        #expect(MenuBarSnapshot.summarize(tasks: [partial, completed], isDemo: false, isBusy: false, hasIssue: false).activity == .attention)
        #expect(MenuBarSnapshot.summarize(tasks: [completed], isDemo: false, isBusy: false, hasIssue: true).activity == .attention)
        #expect(MenuBarSnapshot.summarize(tasks: [completed], isDemo: false, isBusy: true, hasIssue: true).activity == .busy)
        #expect(MenuBarSnapshot.summarize(tasks: [running, partial], isDemo: false, isBusy: false, hasIssue: true).taskTitle == running.title)
        #expect(MenuBarSnapshot.summarize(tasks: [running], isDemo: true, isBusy: true, hasIssue: true) == .init(activity: .demo))
        #expect(MenuBarSnapshot.summarize(tasks: [demo], isDemo: false, isBusy: false, hasIssue: false).activity == .idle)
        for status in [TaskStatus.failed, .partial, .cancelled] {
            let task = TaskRecord(title: "Synthetic", target: "/Synthetic", status: status)
            let snapshot = MenuBarSnapshot.summarize(tasks: [task], isDemo: false, isBusy: false, hasIssue: false)
            #expect(snapshot.activity == (status == .cancelled ? .cancelled : .attention))
        }
        // Finishing a generic busy operation does not manufacture a success.
        #expect(MenuBarSnapshot.summarize(tasks: [], isDemo: false, isBusy: false, hasIssue: false).activity != .completed)
    }

    @Test func persistentMutationOutcomesNeverLookLikeSuccess() {
        let url = URL(fileURLWithPath: "/Synthetic/Retained")
        for status in [TrashItemOutcome.Status.retained, .notAttempted] {
            let result = TrashOutcome(items: [.init(originalURL: url, status: status, message: "Fixture", operationURL: nil)])
            #expect(MenuBarOutcomeEvidence.needsAttention(result))
        }
        #expect(!MenuBarOutcomeEvidence.needsAttention(TrashOutcome(items: [.init(originalURL: url, status: .deleted, message: "Fixture", operationURL: nil)])))
        for recovery in [false, true] {
            let result = CleanupOutcome(items: [.init(id: UUID(), originalURL: url, receipt: nil, message: "Fixture", succeeded: !recovery, requiresRecovery: true)])
            #expect(MenuBarOutcomeEvidence.needsAttention(result))
        }
        #expect(MenuBarOutcomeEvidence.needsAttention(InstallerTrashOutcome(receipt: nil, message: "Unknown", movedToTrash: false, requiresRecovery: false)))
        let daemon = DockerDaemonIdentity(endpoint: .engine,
            socket: .init(path: "/Synthetic/engine.sock", device: 1, inode: 2, owner: 501),
            peer: .init(pid: 1, uid: 501, gid: 20, processToken: [1]), id: "fixture", name: "Fixture", version: "1", operatingSystem: "Fixture", rootless: true)
        let inventory = DockerInventory(id: UUID(), capturedAt: .now, daemon: daemon, images: [], containers: [], volumes: [], buildCache: [])
        for state in [DockerCleanupResult.State.failed, .retained, .uncertain, .skipped] {
            #expect(MenuBarOutcomeEvidence.needsAttention(DockerCleanupResult(daemon: daemon,
                items: [.init(id: "fixture", state: state, detail: "Fixture")], inventory: inventory, cancelled: false, reclaimedCacheBytes: nil)))
        }
        #expect(MenuBarOutcomeEvidence.needsAttention(DockerCleanupResult(daemon: daemon, items: [], inventory: inventory, cancelled: true, reclaimedCacheBytes: nil)))
        #expect(MenuBarOutcomeEvidence.needsAttention(DockerCleanupResult(daemon: daemon, items: [], inventory: nil, cancelled: false, reclaimedCacheBytes: nil)))
        #expect(!MenuBarOutcomeEvidence.needsAttention(DockerCleanupResult(daemon: daemon,
            items: [.init(id: "fixture", state: .removed, detail: "Fixture")], inventory: inventory, cancelled: false, reclaimedCacheBytes: nil)))
    }

    @Test func sharedCacheBusyAndPartialOutcomeReachTheMenuBar() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-menubar-cache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = CleanupStoreFixture(holdMutation: true, partialOutcome: true)
        let cleanup = CleanupStore(executor: fixture)
        let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory), cleanup: cleanup)
        let root = URL(fileURLWithPath: "/Synthetic/Caches")
        cleanup.selectRoot(root, ticket: try #require(cleanup.selectionTicket()))
        cleanup.inspect()
        for _ in 0..<1000 { if !cleanup.isBusy { break }; await Task.yield() }
        cleanup.select(paths: [root.appendingPathComponent("one").path, root.appendingPathComponent("two").path])
        cleanup.prepare()
        for _ in 0..<1000 { if !cleanup.isBusy { break }; await Task.yield() }
        let plan = try #require(cleanup.plan)
        cleanup.attestWorkloadsStopped(true, planID: plan.id)
        cleanup.attestContentRegenerable(true, planID: plan.id)
        cleanup.confirm(planID: plan.id)
        await fixture.waitForMutation()
        #expect(workspace.menuBarSnapshot.activity == .busy)
        await fixture.releaseMutation()
        for _ in 0..<1000 { if !cleanup.isBusy { break }; await Task.yield() }
        #expect(!cleanup.isBusy && cleanup.lastOutcome != nil)
        #expect(workspace.menuBarSnapshot.activity == .attention)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func updateAvailabilityChangesWithoutAnActivityChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-menubar-updates-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory))
        let updates = MenuBarAvailabilityFixture()
        _ = NSApplication.shared
        let controller = MoeMenuBarController(openWorkspace: {}, openSettings: {}, checkUpdates: {}, quit: {},
            makeMenu: { NSMenu() }, canCheckUpdates: { updates.available }, reduceMotion: { true }, observeSystem: false)
        defer { controller.uninstall() }
        controller.bind(to: store)
        #expect(controller.presentation.canCheckUpdates)
        updates.available = false
        for _ in 0..<100 { if !controller.presentation.canCheckUpdates { break }; await Task.yield() }
        #expect(!controller.presentation.canCheckUpdates)
        updates.available = true
        for _ in 0..<100 { if controller.presentation.canCheckUpdates { break }; await Task.yield() }
        #expect(controller.presentation.canCheckUpdates)
        #expect(controller.presentation.snapshot.activity == .idle)
    }

    @Test func clickResponseIsBoundedAndReturnsToRest() {
        #expect(MenuBarIcon.pose(frame: 0) == .init())
        #expect(MenuBarIcon.pose(frame: MenuBarIcon.frameCount) == .init())
        #expect(MenuBarIcon.pose(frame: -1) == .init())
        #expect(MenuBarIcon.pose(frame: 100) == .init())
        for frame in 0...MenuBarIcon.frameCount {
            let pose = MenuBarIcon.pose(frame: frame)
            #expect(abs(pose.tilt) <= 5 && abs(pose.rise) <= 0.8)
        }
        #expect(MenuBarIcon.frameCount * MenuBarIcon.frameMilliseconds <= 900)
        for kind in MenuBarActivity.allCases {
            let image = MenuBarIcon.image(activity: kind)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 22, height: 22))
            #expect(image.accessibilityDescription == "MoeKit")
        }
    }

    @Test func lifecycleStopsMotionAndIgnoresLateStateChanges() async throws {
        _ = NSApplication.shared
        var reduced = true
        let controller = makeController(reduceMotion: { reduced })
        defer { controller.uninstall() }
        controller.playResponse()
        #expect(!controller.isAnimating)
        #expect(!controller.popover.animates)
        reduced = false
        controller.refreshAppearance()
        #expect(controller.popover.animates)
        controller.playResponse()
        #expect(controller.isAnimating)
        controller.playResponse() // repeated activation stays one response
        controller.update(.init(activity: .attention))
        #expect(!controller.isAnimating)
        #expect(controller.presentation.snapshot.activity == .attention)
        controller.playResponse()
        reduced = true
        controller.refreshAppearance()
        #expect(!controller.isAnimating)
        reduced = false
        controller.playResponse()
        controller.uninstall()
        #expect(!controller.isInstalled && !controller.isAnimating)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!controller.isAnimating)
        #expect(controller.popover.contentViewController == nil)
        controller.playResponse()
        #expect(!controller.isAnimating)
    }

    @Test func oneResponseFinishesWithoutIdleTicker() async throws {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.uninstall() }
        controller.playResponse()
        try await Task.sleep(for: .seconds(1.2))
        #expect(!controller.isAnimating)
        #expect(controller.statusItem.button?.image?.isTemplate == true)
        #expect(controller.presentation.snapshot.activity == .idle)
    }

    @Test func observationContinuesWithWindowsClosedAndDoesNotStartWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-menubar-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory))
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.uninstall() }
        controller.bind(to: store)
        #expect(controller.presentation.snapshot.activity == .idle)
        store.tasks = [.init(title: "Only a fixture", target: "/Synthetic", status: .running)]
        for _ in 0..<100 { if controller.presentation.snapshot.activity == .busy { break }; await Task.yield() }
        #expect(controller.presentation.snapshot.activity == .busy)
        store.tasks[0].status = .completed
        for _ in 0..<100 { if controller.presentation.snapshot.activity == .completed { break }; await Task.yield() }
        #expect(controller.presentation.snapshot.activity == .completed)
        store.isDemoEnabled = true
        for _ in 0..<100 { if controller.presentation.snapshot.activity == .demo { break }; await Task.yield() }
        #expect(controller.presentation.snapshot == .init(activity: .demo))
        controller.uninstall()
        store.isDemoEnabled = false
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.presentation.snapshot.activity == .demo)
        #expect(!store.isScanning && !store.isImporting && !store.processes.isScanning && !store.moleAnalysis.isBusy)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func windowReopenUsesCurrentSpaceWithoutJoiningEverySpace() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let view = WorkspaceWindowPlacement.PlacementView()
        window.collectionBehavior = [.canJoinAllSpaces]
        window.contentView = view
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
    }

    private func makeController(reduceMotion: @escaping () -> Bool = { false }) -> MoeMenuBarController {
        MoeMenuBarController(openWorkspace: {}, openSettings: {}, checkUpdates: {}, quit: {},
                             makeMenu: { NSMenu() }, canCheckUpdates: { true },
                             reduceMotion: reduceMotion, observeSystem: false)
    }
}

@MainActor @Observable
private final class MenuBarAvailabilityFixture { var available = true }
