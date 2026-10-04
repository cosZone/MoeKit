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
                let store = scenario == "disabled" ? InstallerTrashStore() : InstallerTrashStore(executor: executor, downloadsURL: downloads)
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
                let view = ScrollView { InstallerTrashView().padding(20) }.environment(workspace)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: view)
                hosting.sizingOptions = []; hosting.frame = NSRect(origin: .zero, size: size); hosting.appearance = appearance
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = hosting
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                // A hidden NSWindow need not populate SwiftUI's accessibility
                // hierarchy. Order only this synthetic owned window.
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
                let frameEvidence = try await verifyRequiredFrames(in: hosting, window: window, scenario: scenario, store: store, name: name)
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
                These images are review evidence, not native interaction, keyboard or accessibility acceptance.
                """)
                metadata.name = name + "-scope.txt"
                metadata.lifetime = .keepAlways; add(metadata)
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

    /// Read metadata from this owned view only. Exact identifiers, displayed
    /// escaped paths and viewport containment are affirmative capture evidence;
    /// this does not establish keyboard navigation or VoiceOver acceptance.
    @MainActor private func verifyRequiredFrames(in hosting: NSView, window: NSWindow, scenario: String, store: InstallerTrashStore, name: String) async throws -> [String] {
        let requirements = captureRequirements(scenario: scenario, store: store)
        var elements: [any NSAccessibilityProtocol] = []
        var wasTruncated = false
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            let snapshot = accessibleElements(in: hosting)
            elements = snapshot.elements; wasTruncated = snapshot.truncated
            if requirements.allSatisfy({ requirement in elements.contains { $0.accessibilityIdentifier() == requirement.id && validCaptureFrame($0.accessibilityFrame()) } }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let captured = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
        let tree = elements.map { element in
            let content = captureText(element).map { InstallerPathDisplay.quoted(String($0.prefix(1_024))) }.joined(separator: " | ")
            return "\(String(describing: type(of: element))) | id=\(element.accessibilityIdentifier() ?? "") | role=\(element.accessibilityRole()?.rawValue ?? "") | text=\(content) | frame=\(NSStringFromRect(element.accessibilityFrame()))"
        }
        let diagnostic = XCTAttachment(string: "Owned synthetic window visible: \(window.isVisible)\nCapture frame: \(NSStringFromRect(captured))\nTree truncated: \(wasTruncated)\n" + tree.joined(separator: "\n"))
        diagnostic.name = name + "-ax-tree.txt"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        XCTAssertFalse(wasTruncated, "Owned accessibility tree exceeded the capture-check bound")
        var evidence: [String] = []
        for requirement in requirements {
            let matches = elements.filter { $0.accessibilityIdentifier() == requirement.id && validCaptureFrame($0.accessibilityFrame()) }
            guard let first = matches.first else {
                // Fail affirmatively while keeping all screenshots and tree
                // diagnostics, including the remaining mandatory scenarios.
                XCTFail("Required capture identifier missing: \(requirement.id); inspect \(name)-ax-tree.txt")
                continue
            }
            // An identifier can be exposed by a Label and its text/icon peers.
            // Require their entire geometry, never just the smallest child.
            let frame = matches.dropFirst().reduce(first.accessibilityFrame()) { $0.union($1.accessibilityFrame()) }
            guard captured.insetBy(dx: -0.5, dy: -0.5).contains(frame) else {
                XCTFail("Required content outside captured viewport: \(requirement.id), frame \(frame), capture \(captured)")
                continue
            }
            let text = matches.flatMap { captureText($0) }
            guard text.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                XCTFail("Required captured content is empty: \(requirement.id)")
                continue
            }
            if let path = requirement.exactPath, !text.contains(where: { $0.contains(path) }) {
                XCTFail("Exact escaped path missing from \(requirement.id): \(path)")
                continue
            }
            evidence.append("Captured identifier: \(requirement.id) · screen frame: \(NSStringFromRect(frame))" + (requirement.exactPath.map { " · exact path: " + $0 } ?? ""))
        }
        XCTAssertEqual(evidence.count, requirements.count, "Every mandatory content/control must be visible in this capture")
        return evidence
    }

    private func validCaptureFrame(_ frame: NSRect) -> Bool {
        !frame.isEmpty && frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
    }

    @MainActor private func captureText(_ element: any NSAccessibilityProtocol) -> [String] {
        [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String,
         (element.accessibilityValue() as? NSAttributedString)?.string].compactMap { $0 }
    }

    @MainActor private func accessibleElements(in hosting: NSView) -> (elements: [any NSAccessibilityProtocol], truncated: Bool) {
        var queue: [Any] = [hosting]
        var seen: Set<ObjectIdentifier> = []
        var elements: [any NSAccessibilityProtocol] = []
        while !queue.isEmpty, seen.count < 1_024 {
            let next = queue.removeFirst()
            guard let object = next as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let view = object as? NSView { queue += view.subviews }
            guard let element = object as? any NSAccessibilityProtocol else { continue }
            elements.append(element)
            queue += element.accessibilityChildren() ?? []
            queue += (element.accessibilityChildrenInNavigationOrder() ?? []).map { $0 as Any }
        }
        return (elements, !queue.isEmpty)
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
