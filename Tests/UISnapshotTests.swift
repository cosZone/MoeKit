import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

/// Reviewable view-render evidence, not pixel-baseline, interaction, or VoiceOver tests.
/// Only this test's owned view hierarchy is drawn. No screen capture, Accessibility
/// permission, process scan, user catalog, or third-party snapshot package is used.
final class UISnapshotTests: XCTestCase {
    @MainActor
    func testDemoProjectsRenders() throws {
        try captureVariants(named: "demo-projects-inspector") { store in
            store.section = .projects
            store.selectedProjectID = DemoData.projects.first { $0.kind == .worktree }?.id
            store.isInspectorPresented = true
        }
    }

    @MainActor
    func testDemoTasksRenders() throws {
        try captureVariants(named: "demo-tasks-result") { store in
            store.section = .tasks
            store.selectedTaskID = DemoData.tasks.first { $0.status == .partial }?.id
        }
    }

    @MainActor
    func testDemoMoleSpaceRenders() throws {
        try captureVariants(named: "demo-mole-space") { store in
            store.section = .tools
            store.selectedToolID = MoleModule.id
            store.selectedCapability = .space
        }
    }

    @MainActor
    func testDemoProcessesUnavailableRenders() throws {
        try captureVariants(named: "demo-processes-unavailable") { store in
            store.section = .tools
            store.selectedToolID = ProcessModule.id
        }
    }

    @MainActor
    func testGettingStartedWelcomeRenders() throws {
        try captureVariants(named: "getting-started-welcome", rendersGuide: true, isDemoEnabled: false) { store in
            XCTAssertTrue(store.showAutomaticGettingStarted())
        }
    }

    @MainActor
    func testGettingStartedDestinationsRender() throws {
        for goal in GettingStartedGoal.allCases {
            try captureVariants(named: "getting-started-\(goal.rawValue)", rendersGuide: true, isDemoEnabled: false) { store in
                XCTAssertTrue(store.showGettingStarted())
                store.gettingStarted.selectedGoal = goal
            }
        }
    }

    @MainActor
    func testFirstUseWorkspacesRender() throws {
        for scenario in ["projects", "processes", "tasks", "mole-space"] {
            try captureVariants(named: "first-use-\(scenario)", isDemoEnabled: false) { store in
                switch scenario {
                case "processes": store.openGettingStartedGoal(.processes)
                case "tasks": store.section = .tasks
                case "mole-space": store.section = .tools; store.selectedToolID = MoleModule.id
                default: store.section = .projects
                }
            }
        }
    }

    @MainActor
    func testSettingsModeGuidanceRenders() throws {
        for demo in [false, true] {
            try captureVariants(named: demo ? "settings-demo" : "settings-real",
                                rendersSettings: true, isDemoEnabled: demo) { _ in }
        }
    }

    @MainActor
    private func captureVariants(named scenario: String, rendersGuide: Bool = false, rendersSettings: Bool = false, isDemoEnabled: Bool = true, configure: (WorkspaceStore) -> Void) throws {
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        XCTAssertTrue(["en", "zh-Hans"].contains(language), "Render language must be explicitly supported")
        XCTAssertEqual(WorkspaceSection.projects.title, language == "zh-Hans" ? "项目" : "Projects")
        XCTAssertEqual(TaskStatus.partial.title, language == "zh-Hans" ? "部分结果" : "Partial result")
        // CI separately checks that the process locale agrees with its requested
        // language. Setting only the SwiftUI locale would leave model strings mixed.
        let sizes = rendersSettings ? [NSSize(width: 520, height: 600)] : (rendersGuide
            ? [NSSize(width: 520, height: 480), NSSize(width: 620, height: 580)]
            : [NSSize(width: 960, height: 620), NSSize(width: 1280, height: 800)])
        let appearances: [(String, NSAppearance.Name, ColorScheme)] = [
            ("light", .aqua, .light), ("dark", .darkAqua, .dark),
        ]
        for (name, appearanceName, colorScheme) in appearances {
            for size in sizes {
                try autoreleasepool {
                    let name = "\(scenario)-\(language)-\(name)-\(Int(size.width))x\(Int(size.height))"
                    try capture(named: name, size: size, appearanceName: appearanceName,
                                colorScheme: colorScheme, rendersGuide: rendersGuide, rendersSettings: rendersSettings, isDemoEnabled: isDemoEnabled, configure: configure)
                }
            }
        }
    }

    @MainActor
    private func capture(named name: String, size: NSSize, appearanceName: NSAppearance.Name,
                         colorScheme: ColorScheme, rendersGuide: Bool, rendersSettings: Bool, isDemoEnabled: Bool, configure: (WorkspaceStore) -> Void) throws {
        // Even Demo's store initializer loads its catalog. Point it exclusively at
        // a fresh, empty test directory, never the runner's Application Support.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoeKit-ui-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(isDemoEnabled: isDemoEnabled, persistence: CatalogPersistence(directory: directory))
        configure(store)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.tasks.isEmpty)

        _ = NSApplication.shared
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        let content = rendersSettings ? AnyView(SettingsView())
            : (rendersGuide ? AnyView(GettingStartedView(close: {})) : AnyView(WorkspaceView()))
        let root = content
            .environment(store)
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, Locale.current)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .transaction { $0.animation = nil }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        window.setContentSize(size)
        defer {
            window.contentView = nil
            window.close()
        }

        // Allow bounded SwiftUI/AppKit layout turns for native Table/inspector
        // subviews. SwiftUI can attach its toolbar after the initial window
        // setup, reducing the content height while preserving the outer frame.
        // Reapply the requested content size after each turn so AppKit uses the
        // current toolbar metrics; do not hardcode a titlebar/toolbar offset.
        // The window is never ordered onto the runner's desktop.
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            window.setContentSize(size)
        }
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.bounds.size, size, "Capture must retain the requested content size")
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Keep the image even on failure so a blank-render failure can be diagnosed.
        // This only rejects an empty/uniform bitmap; humans must review the pixels.
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertGreaterThan(opaqueSampleColors(in: bitmap), 4, "Owned view render is blank or uniform")
        XCTAssertFalse(store.isScanning)
        XCTAssertFalse(store.processes.isScanning)
        XCTAssertNil(store.processes.snapshot)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                      "Rendering synthetic views must not persist a catalog")

        let metadata = XCTAttachment(string: """
        \(name)
        Content size: \(Int(size.width)) × \(Int(size.height)) points
        Bitmap size: \(bitmap.pixelsWide) × \(bitmap.pixelsHigh) pixels
        Appearance: \(appearanceName.rawValue)
        Process locale: \(Locale.current.identifier)
        Preferred languages: \(Locale.preferredLanguages.joined(separator: ", "))
        Bundle language: \(Bundle.main.preferredLocalizations.first ?? "unknown")
        Projects title: \(WorkspaceSection.projects.title)
        Partial-result title: \(TaskStatus.partial.title)
        Hosting bounds: \(hosting.bounds)
        Window content layout: \(window.contentLayoutRect)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Scope: app-owned view subtree, built-in Demo fixtures or empty first-use state, empty temporary catalog.
        Guide presentation: \(rendersGuide); Settings presentation: \(rendersSettings); Demo enabled: \(isDemoEnabled).
        No screen/window-server capture. Window chrome and toolbar are outside this content render.
        These are review artifacts, not approved baselines or manual visual/accessibility acceptance.
        Fixture timestamps are relative; do not use these images as deterministic pixel baselines.
        """)
        metadata.name = "\(name)-scope.txt"
        metadata.lifetime = .keepAlways
        add(metadata)
    }

    @MainActor
    private func opaqueSampleColors(in bitmap: NSBitmapImageRep) -> Int {
        var colors: Set<Int> = []
        let xStep = max(1, bitmap.pixelsWide / 64)
        let yStep = max(1, bitmap.pixelsHigh / 48)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStep) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: xStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5 else { continue }
                let red = Int((color.redComponent * 31).rounded())
                let green = Int((color.greenComponent * 31).rounded())
                let blue = Int((color.blueComponent * 31).rounded())
                colors.insert((red << 10) | (green << 5) | blue)
            }
        }
        return colors.count
    }
}
