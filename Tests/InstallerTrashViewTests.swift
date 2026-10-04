import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

/// Synthetic native-view evidence only. No native executor, real analysis,
/// filesystem mutation, process inspection or user-path access occurs.
final class InstallerTrashViewTests: XCTestCase {
    @MainActor
    func testInstallerConfirmationRenders() async throws {
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        XCTAssertTrue(["en", "zh-Hans"].contains(language))
        if language == "zh-Hans" { verifyChineseSafetyCopy() }
        let downloads = URL(fileURLWithPath: "/Synthetic/Downloads", isDirectory: true)
        let selected = downloads.appendingPathComponent("Long installer name with quotes \" and newline\nplus direction marker \u{202E}dmg.dmg")
        for scenario in ["disabled", "trash-confirmation", "restore-confirmation", "incomplete-recovery"] {
            for dark in [false, true] {
                let owned = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-installer-render-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: owned) }
                let executor = RenderInstallerExecutor(downloads: downloads, selected: selected, incomplete: scenario == "incomplete-recovery")
                let store = scenario == "disabled" ? InstallerTrashStore(executor: nil) : InstallerTrashStore(executor: executor, downloadsURL: downloads)
                let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: owned), installerTrash: store)
                if scenario == "trash-confirmation" {
                    let data = try JSONSerialization.data(withJSONObject: ["path": downloads.path, "overview": false, "scan_status": "complete", "total_size": 4096,
                        "entries": [["name": selected.lastPathComponent, "path": selected.path, "is_dir": false, "size": 4096, "scan_status": "complete"]]])
                    let result = MoleAnalysisResult(report: try JSONDecoder().decode(MoleAnalyzeReport.self, from: data), directory: downloads,
                        release: .native, startedAt: Date(), finishedAt: Date())
                    store.updateContext(liveAnalysisID: UUID(), result: result, isDemoEnabled: false, protectedPaths: [], catalogIsKnown: true)
                    store.select(path: selected.path); store.prepare()
                    await settle(store)
                    XCTAssertNotNil(store.plan)
                } else if scenario != "disabled" {
                    store.loadRecovery(); await settle(store)
                    if scenario == "restore-confirmation" {
                        store.prepareRestore(receiptID: try XCTUnwrap(store.receipts.first?.id)); await settle(store)
                        XCTAssertNotNil(store.restorePlan)
                    } else { XCTAssertEqual(store.recoveryItems.filter { $0.receipt == nil }.count, 1) }
                }
                _ = NSApplication.shared
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let size = NSSize(width: 720, height: 1600)
                let capture = InstallerRenderCapture()
                XCTAssertNil(EnvironmentValues().installerCaptureCollector)
                let makeView = { (canvas: NSSize) in
                    ScrollView { InstallerTrashView().padding(20) }.environment(workspace)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.locale, Locale.current)
                        .frame(width: canvas.width, height: canvas.height)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .installerCaptureViewport()
                        .environment(\.installerCaptureCollector, { capture.record($0) })
                }
                let hosting = NSHostingView(rootView: makeView(size))
                hosting.sizingOptions = []; hosting.frame = NSRect(origin: .zero, size: size); hosting.appearance = appearance
                let window = InstallerCaptureWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = hosting
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                // Order only this synthetic owned window; its test-only
                // subclass preserves the requested offscreen capture canvas.
                window.orderFront(nil)
                for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)); window.setContentSize(size) }
                // The last setContentSize above can leave layout/display
                // invalidated. Flush that final size before raster capture.
                hosting.layoutSubtreeIfNeeded()
                XCTAssertEqual(hosting.bounds.size, size)
                resetScrollOrigins(in: hosting)
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                XCTAssertTrue(window.isVisible)
                let name = "installer-\(scenario)-\(language)-\(dark ? "dark" : "light")-720x1600"
                let frameEvidence = try await verifyRequiredFrames(in: hosting, capture: capture, scenario: scenario, store: store, name: name)
                hosting.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name + ".png"
                attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertGreaterThan(png.count, 1000)
                XCTAssertFalse(store.isBusy)
                let mutationCount = await executor.mutationCount
                XCTAssertEqual(mutationCount, 0)
                let metadata = XCTAttachment(string: """
                Content size: \(Int(size.width)) × \(Int(size.height)) points
                Process locale: \(Locale.current.identifier)
                Bundle language: \(language)
                Projects title: \(WorkspaceSection.projects.title)
                Partial-result title: \(TaskStatus.partial.title)
                Trash action title: \(String(localized: "Move this file to Trash"))
                Restore action title: \(String(localized: "Restore to original path"))
                Attestation title: \(String(localized: "I have finished installing and using this disk image"))
                Unknown recovery title: \(String(localized: "Recovery record unavailable; outcome unknown"))
                Mutation calls: \(mutationCount)
                Required identified content/control frames inside capture: \(frameEvidence.count)
                \(frameEvidence.joined(separator: "\n"))
                Scope: owned installer view with synthetic paths and receipts only.
                Scenario: \(scenario). No native executor, process inspection, disk-image inventory or real file moves.
                The scroll container keeps controls reachable beyond the captured viewport.
                Evidence source: public SwiftUI bounds anchors on displayed views
                No keyboard or VoiceOver interaction performed.
                These images are review evidence, not native interaction, keyboard or accessibility acceptance.
                """)
                metadata.name = name + "-scope.txt"
                metadata.lifetime = .keepAlways; add(metadata)
                if scenario == "trash-confirmation" || scenario == "restore-confirmation" {
                    let compactSize = NSSize(width: 720, height: 560)
                    capture.regions = []
                    hosting.rootView = makeView(compactSize)
                    window.setContentSize(compactSize)
                    for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
                    XCTAssertEqual(hosting.bounds.size, compactSize)
                    resetScrollOrigins(in: hosting)
                    hosting.layoutSubtreeIfNeeded()
                    let prefix = scenario == "trash-confirmation" ? "installer.trash" : "installer.restore"
                    let controls = [CaptureRequirement(id: prefix + ".confirm"), CaptureRequirement(id: prefix + ".cancel")]
                    let didScroll = await scrollToControls(controls, in: hosting, capture: capture)
                    let compactName = "installer-\(scenario)-compact-\(language)-\(dark ? "dark" : "light")-720x560"
                    let compactEvidence = try await verifyRequiredFrames(in: hosting, capture: capture, scenario: scenario, store: store,
                                                                         name: compactName, requirements: controls)
                    hosting.displayIfNeeded()
                    let compactBitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: compactBitmap) }
                    let compactPNG = try XCTUnwrap(compactBitmap.representation(using: .png, properties: [:]))
                    let compactImage = XCTAttachment(data: compactPNG, uniformTypeIdentifier: "public.png")
                    compactImage.name = compactName + ".png"; compactImage.lifetime = .keepAlways; add(compactImage)
                    let compactMutations = await executor.mutationCount
                    XCTAssertEqual(compactMutations, 0)
                    let compactScope = XCTAttachment(string: """
                    Content size: 720 × 560 points
                    Process locale: \(Locale.current.identifier)
                    Bundle language: \(language)
                    Projects title: \(WorkspaceSection.projects.title)
                    Partial-result title: \(TaskStatus.partial.title)
                    Trash action title: \(String(localized: "Move this file to Trash"))
                    Restore action title: \(String(localized: "Restore to original path"))
                    Attestation title: \(String(localized: "I have finished installing and using this disk image"))
                    Unknown recovery title: \(String(localized: "Recovery record unavailable; outcome unknown"))
                    Mutation calls: \(compactMutations)
                    Scope: owned installer view with synthetic paths and receipts only.
                    Capture mode: compact confirmation controls after explicit scroll
                    Scrollable content exceeds viewport: \(didScroll)
                    Scrolled confirmation/cancel inside capture: \(compactEvidence.count)
                    \(compactEvidence.joined(separator: "\n"))
                    Evidence source: public SwiftUI bounds anchors on displayed views
                    No keyboard or VoiceOver interaction performed.
                    """)
                    compactScope.name = compactName + "-scope.txt"; compactScope.lifetime = .keepAlways; add(compactScope)
                }
            }
        }
    }

    private struct CaptureRequirement {
        let id: String
        var exactPath: String? = nil
    }

    /// Identifiers refer to existing displayed content, not localized Label
    /// composition. These requirements are identical in en and zh-Hans runs.
    @MainActor private func captureRequirements(scenario: String, store: InstallerTrashStore) -> [CaptureRequirement] {
        var requirements = [CaptureRequirement(id: "installer.heading"), .init(id: "installer.recovery.read")]
        func require(_ prefix: String, _ suffixes: [String]) {
            requirements += suffixes.map { .init(id: prefix + "." + $0) }
        }
        func requirePath(_ id: String, _ url: URL) {
            requirements.append(.init(id: id, exactPath: InstallerPathDisplay.quoted(url.path)))
        }
        func requireStorage(_ prefix: String, _ operation: URL) {
            let root = operation.deletingLastPathComponent()
            requirePath(prefix + ".parent-path", root.deletingLastPathComponent())
            requirePath(prefix + ".recovery-root-path", root)
            requirePath(prefix + ".operation-lock-path", root.appendingPathComponent("operations.lock"))
            requirePath(prefix + ".catalog-lock-path", root.deletingLastPathComponent().appendingPathComponent("projects.json.lock"))
            requirePath(prefix + ".journal-path", operation)
        }
        switch scenario {
        case "trash-confirmation":
            require("installer.trash", ["heading", "effects", "lock-effects", "journal-effects", "inventory-effects", "scope-effects",
                                        "attestation", "confirm", "cancel"])
            if let plan = store.plan {
                requirePath("installer.trash.original-path", plan.originalURL)
                requirePath("installer.trash.staging-path", plan.recoveryURL.appendingPathComponent(plan.originalURL.lastPathComponent))
                requireStorage("installer.trash", plan.recoveryURL)
                requirePath("installer.trash.record-path", plan.recoveryURL.appendingPathComponent("000000.json"))
            } else { XCTFail("Trash render must retain its confirmation plan") }
            XCTAssertEqual(requirements.count, 19)
        case "restore-confirmation":
            require("installer.restore", ["heading", "effects", "lock-effects", "confirm", "cancel"])
            if let plan = store.restorePlan {
                requirePath("installer.restore.source-path", plan.sourceURL)
                requirePath("installer.restore.destination-path", plan.receipt.originalURL)
                requirePath("installer.restore.staging-path", plan.receipt.operationURL.appendingPathComponent("restore.dmg"))
                requireStorage("installer.restore", plan.receipt.operationURL)
                requirePath("installer.restore.record-path", plan.receipt.operationURL.appendingPathComponent(String(format: "%06d.json", plan.receipt.sequence + 1)))
            } else { XCTFail("Restore render must retain its confirmation plan") }
            XCTAssertEqual(requirements.count, 16)
        case "incomplete-recovery":
            require("installer.recovery", ["unknown", "effects", "reveal"])
            if let item = store.recoveryItems.first { requirePath("installer.recovery.operation-path", item.operationURL) }
            else { XCTFail("Incomplete recovery render must retain its record") }
            XCTAssertEqual(requirements.count, 6)
        default: XCTAssertEqual(requirements.count, 2)
        }
        return requirements
    }

    /// Preferences come from the actual displayed views and are resolved in
    /// the captured viewport. This verifies layout/content, not VoiceOver.
    @MainActor private func verifyRequiredFrames(in hosting: NSView, capture: InstallerRenderCapture, scenario: String, store: InstallerTrashStore, name: String, requirements explicitRequirements: [CaptureRequirement]? = nil) async throws -> [String] {
        let requirements = explicitRequirements ?? captureRequirements(scenario: scenario, store: store)
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            if requirements.allSatisfy({ requirement in capture.regions.contains { $0.id == requirement.id && validCaptureFrame($0.bounds) } }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let captured = CGRect(origin: .zero, size: hosting.bounds.size)
        let regions = capture.regions
        let tree = regions.prefix(256).map { region in
            "id=\(region.id) | displayed content=\(InstallerPathDisplay.quoted(region.text)) | viewport bounds=\(NSStringFromRect(region.bounds))"
        }
        let diagnostic = XCTAttachment(string: "Evidence source: public SwiftUI bounds anchors on displayed views\nCapture viewport: \(NSStringFromRect(captured))\nCoordinates: viewport top-left origin\nReported regions: \(regions.count)\nCollector revision: \(capture.revision)\n" + tree.joined(separator: "\n"))
        diagnostic.name = name + "-geometry.txt"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        XCTAssertLessThanOrEqual(regions.count, 256, "Owned geometry evidence exceeded the capture-check bound")
        var evidence: [String] = []
        for requirement in requirements {
            let matches = regions.filter { $0.id == requirement.id }
            guard matches.count == 1, let region = matches.first, validCaptureFrame(region.bounds) else {
                XCTFail("Required displayed-view anchor missing, duplicate or empty: \(requirement.id); inspect \(name)-geometry.txt")
                continue
            }
            guard captured.insetBy(dx: -0.5, dy: -0.5).contains(region.bounds) else {
                XCTFail("Required content outside captured viewport: \(requirement.id), bounds \(region.bounds), capture \(captured)")
                continue
            }
            guard !region.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                XCTFail("Required displayed content is empty: \(requirement.id)")
                continue
            }
            if let path = requirement.exactPath, region.text != path {
                XCTFail("Exact displayed escaped path differs for \(requirement.id): \(region.text), expected \(path)")
                continue
            }
            evidence.append("Captured identifier: \(requirement.id) · viewport bounds: \(NSStringFromRect(region.bounds)) · displayed content: \(InstallerPathDisplay.quoted(region.text))")
        }
        XCTAssertEqual(evidence.count, requirements.count, "Every mandatory content/control must be visible in this capture")
        return evidence
    }

    private func validCaptureFrame(_ frame: NSRect) -> Bool {
        !frame.isEmpty && frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
    }

    /// Use actual control anchors to position the compact viewport. Poll fresh
    /// post-scroll geometry; the initial target coordinates cannot prove that
    /// scrolling succeeded. Recovery content below the controls is irrelevant.
    @MainActor private func scrollToControls(_ controls: [CaptureRequirement], in hosting: NSView, capture: InstallerRenderCapture) async -> Bool {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
        }
        guard let scroll = scrollViews(hosting).first, let document = scroll.documentView else {
            XCTFail("Compact confirmation must have a native scroll container")
            return false
        }
        guard document.bounds.height > scroll.contentView.bounds.height else {
            XCTFail("Compact confirmation must genuinely exceed its viewport")
            return false
        }
        let before = scroll.contentView.bounds.origin
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            let targets = controls.compactMap { control in capture.regions.first { $0.id == control.id && validCaptureFrame($0.bounds) }?.bounds }
            if targets.count == controls.count, let first = targets.first {
                let target = targets.dropFirst().reduce(first) { $0.union($1) }
                // SwiftUI anchor coordinates are top-left based. Convert only
                // when an AppKit hosting view uses bottom-left coordinates.
                let hostingTarget = hosting.isFlipped ? target : CGRect(x: target.minX, y: hosting.bounds.height - target.maxY, width: target.width, height: target.height)
                let documentTarget = document.convert(hostingTarget, from: hosting)
                let viewportHeight = scroll.contentView.bounds.height
                let maximumY = max(document.bounds.minY, document.bounds.maxY - viewportHeight)
                let centeredY = min(max(documentTarget.midY - viewportHeight / 2, document.bounds.minY), maximumY)
                let beforeRevision = capture.revision
                document.scroll(NSPoint(x: document.bounds.minX, y: centeredY))
                scroll.reflectScrolledClipView(scroll.contentView)
                for _ in 0..<20 {
                    hosting.layoutSubtreeIfNeeded()
                    let viewport = CGRect(origin: .zero, size: hosting.bounds.size).insetBy(dx: -0.5, dy: -0.5)
                    let current = controls.compactMap { control in capture.regions.first { $0.id == control.id }?.bounds }
                    if capture.revision > beforeRevision, current.count == controls.count,
                       current.allSatisfy({ validCaptureFrame($0) && viewport.contains($0) }) {
                        XCTAssertNotEqual(scroll.contentView.bounds.origin, before, "Compact confirmation controls must require a real scroll")
                        return scroll.contentView.bounds.origin != before
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                XCTFail("Fresh control anchors did not enter the compact viewport after scrolling")
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Compact confirmation control anchors not reported")
        return false
    }

    /// An initially focused action button can cause an AppKit scroll view to
    /// retain an offset while the synthetic window grows to its capture size.
    /// Capture the first viewport consistently; this is test setup, not a claim
    /// about keyboard navigation in the application.
    @MainActor private func resetScrollOrigins(in view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let y = document.isFlipped ? document.frame.minY
                : max(document.frame.minY, document.frame.maxY - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: document.frame.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for child in view.subviews { resetScrollOrigins(in: child) }
    }

    /// Runs in the existing zh-Hans render invocation. Assertions catch a
    /// missing catalog entry or a changed interpolation signature before the
    /// synthetic screenshots are attached; they do not verify native behavior.
    @MainActor private func verifyChineseSafetyCopy() {
        XCTAssertEqual(String(localized: "Move this file to Trash"), "将此文件移到废纸篓")
        XCTAssertEqual(String(localized: "Restore to original path"), "恢复到原路径")
        XCTAssertEqual(String(localized: "I have finished installing and using this disk image"), "我已完成此磁盘映像的安装和使用")
        XCTAssertEqual(String(localized: "Recovery record unavailable; outcome unknown"), "恢复记录不可用；结果未知")
        XCTAssertEqual(String(localized: "The destination already exists. MoeKit will not replace it."), "目标位置已存在条目。MoeKit 不会将其替换。")
        XCTAssertEqual(String(localized: "This version requires a complete, empty disk-image inventory. You may eject images you opened yourself, then check again. Leave system-managed images alone; they can keep this action unavailable. MoeKit does not classify or eject images."),
                       "此版本要求完整的磁盘映像清单为空。你可以推出自己打开的映像，然后重新检查。请勿处理系统管理的映像；它们的存在可能使此操作持续不可用。MoeKit 不会对映像进行分类或代为推出。")
        XCTAssertEqual(InstallerUseEvidence.attachedImageLimitation, "此版本要求完整的磁盘映像清单为空，无法排除通过任何已连接映像使用文件的情况。请仅推出你自己打开的映像，然后重新检查。请勿处理系统管理的映像；它们的存在可能使此操作持续不可用。MoeKit 不会对映像进行分类或代为推出。")
        let size = "4 KB", bytes: Int64 = 4096
        let localizedBytes = bytes.formatted(.number.locale(Locale.current))
        XCTAssertEqual(String(localized: "1 file · \(size) (\(bytes) bytes)"), "1 个文件 · 4 KB（\(localizedBytes) 字节）")
        let receipt = "synthetic-receipt", sequence = 3
        XCTAssertEqual(String(localized: "Receipt \(receipt) · record \(sequence)"), "凭据 synthetic-receipt · 第 3 条记录")
        let pid: Int32 = 17, code: Int32 = 13, stage = "PROC_PIDINFO"
        XCTAssertEqual(String(localized: "Current-user process \(pid) could not be completely checked at \(stage) (system error \(code)). It may have exited, changed, exceeded a limit, or denied access."),
                       "无法完整检查当前用户的进程 17，检查阶段为 PROC_PIDINFO（系统错误 13）。该进程可能已退出、发生变化、超出限制或拒绝访问。")
        let path = "\"/Synthetic/Downloads/line\\nname.dmg\""
        XCTAssertEqual(String(localized: "Full path, escaped: \(path)"), "完整路径（已转义）：\(path)")
    }

    @MainActor private func settle(_ store: InstallerTrashStore) async {
        for _ in 0..<2000 { if !store.isBusy { return }; await Task.yield() }
        XCTFail("Synthetic store did not settle")
    }
}

private actor RenderInstallerExecutor: InstallerTrashExecuting {
    let downloads: URL
    let selected: URL
    let incomplete: Bool
    var mutationCount = 0
    let id = UUID()
    init(downloads: URL, selected: URL, incomplete: Bool) { self.downloads = downloads; self.selected = selected; self.incomplete = incomplete }
    func prepare(selection: URL, scope: InstallerTrashScope) async throws -> InstallerTrashPlan {
        .init(id: id, scope: scope, originalURL: selection, downloadsURL: downloads,
              recoveryURL: operationURL, file: Self.file, preparedAt: Date(), expiresAt: Date().addingTimeInterval(120))
    }
    func discardPlans() async {}
    func moveToTrash(planID: UUID, scope: InstallerTrashScope) async throws -> InstallerTrashOutcome {
        mutationCount += 1; throw InstallerTrashFailure.unsupported
    }
    func recoveryReceipts() async throws -> [InstallerRecoveryItem] {
        [.init(id: id, operationURL: operationURL, receipt: incomplete ? nil : receipt,
               issue: incomplete ? String(localized: "This recovery record is incomplete or unreadable. Its contents were retained; no operation will be retried automatically.") : nil)]
    }
    func validatedRecoveryLocation(receiptID: UUID) async throws -> URL { operationURL }
    func prepareRestore(receiptID: UUID, context: InstallerRecoveryContext) async throws -> InstallerRestorePlan {
        .init(id: UUID(), receipt: receipt, sourceURL: receipt.trashURL!, context: context,
              preparedAt: Date(), expiresAt: Date().addingTimeInterval(120))
    }
    func restore(planID: UUID, context: InstallerRecoveryContext) async throws -> InstallerTrashOutcome {
        mutationCount += 1; throw InstallerTrashFailure.unsupported
    }
    private var operationURL: URL { URL(fileURLWithPath: "/Synthetic/Library/Application Support/MoeKit/InstallerRecovery/\(id)") }
    private var receipt: InstallerTrashReceipt {
        .init(policy: InstallerTrashReceipt.policyVersion, id: id, sequence: 3, originalURL: selected,
              originalParent: Self.file, originalFile: Self.file, operationURL: operationURL, operationDirectory: Self.file,
              state: .trashed, recordedAt: Date(), payloadName: nil,
              trashURL: URL(fileURLWithPath: "/Synthetic/Trash").appendingPathComponent(selected.lastPathComponent), trashFile: Self.file)
    }
    private static let file = InstallerFileSnapshot(device: 1, inode: 2, mode: 0o100600, uid: 501, gid: 20, links: 1, flags: 0,
        bytes: 4096, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
}

/// The artifact canvas intentionally exceeds the hosted CI display. AppKit
/// normally constrains a titled resizable window to that display when ordered.
/// Preserve the owned capture size without changing application window policy.
@MainActor private final class InstallerCaptureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private final class InstallerRenderCapture {
    var regions: [InstallerCaptureRegion] = []
    private(set) var revision = 0

    func record(_ value: [InstallerCaptureRegion]) {
        regions = value
        revision += 1
    }
}
