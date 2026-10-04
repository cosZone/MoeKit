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
                defer { window.contentView = nil; window.close() }
                for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)); window.setContentSize(size) }
                // The last setContentSize above can leave layout/display
                // invalidated. Flush that final size before raster capture.
                hosting.layoutSubtreeIfNeeded()
                XCTAssertEqual(hosting.bounds.size, size)
                resetScrollOrigins(in: hosting)
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                let frameEvidence = try verifyRequiredFrames(in: hosting, window: window, scenario: scenario)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                let name = "installer-\(scenario)-\(language)-\(dark ? "dark" : "light")-720x1600"
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
                Required heading/action frames inside capture: \(frameEvidence.count)
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

    /// Read frame metadata from this owned view only. This is a geometric
    /// capture check, not keyboard navigation or VoiceOver acceptance.
    @MainActor private func verifyRequiredFrames(in hosting: NSView, window: NSWindow, scenario: String) throws -> [String] {
        var labels = [String(localized: "Downloaded disk image"), String(localized: "Read recovery records")]
        switch scenario {
        case "trash-confirmation":
            labels += [String(localized: "Confirm native macOS Trash"), String(localized: "I have finished installing and using this disk image"),
                       String(localized: "Move this file to Trash"), String(localized: "Cancel plan")]
        case "restore-confirmation":
            labels += [String(localized: "Confirm original-path restore"), String(localized: "Restore to original path"), String(localized: "Cancel plan")]
        case "incomplete-recovery":
            labels += [String(localized: "Recovery record unavailable; outcome unknown"), String(localized: "Reveal validated recovery location")]
        default: break
        }
        var queue: [Any] = [hosting]
        var seen: Set<ObjectIdentifier> = []
        var elements: [any NSAccessibilityProtocol] = []
        while !queue.isEmpty, seen.count < 1_024 {
            let next = queue.removeFirst()
            guard let element = next as? any NSAccessibilityProtocol else { continue }
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            elements.append(element)
            queue += element.accessibilityChildren() ?? []
        }
        XCTAssertTrue(queue.isEmpty, "Owned accessibility tree exceeded the capture-check bound")
        let captured = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
        var evidence: [String] = []
        for label in labels {
            let matches = elements.filter { element in
                [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].contains(label)
            }.map { $0.accessibilityFrame() }.filter { !$0.isEmpty && $0.width.isFinite && $0.height.isFinite }
            let frame = try XCTUnwrap(matches.min(by: { $0.width * $0.height < $1.width * $1.height }), "Required capture element missing: \(label)")
            XCTAssertTrue(captured.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Required element outside the captured viewport: \(label), frame \(frame), capture \(captured)")
            evidence.append("Captured element: \(label) · screen frame: \(NSStringFromRect(frame))")
        }
        return evidence
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
