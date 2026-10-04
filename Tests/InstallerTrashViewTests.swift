import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

/// Synthetic native-view evidence only. No native executor, real analysis,
/// filesystem mutation, process inspection or user-path access occurs.
final class InstallerTrashViewTests: XCTestCase {
    @MainActor
    func testInstallerConfirmationRenders() async throws {
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
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
                attachment.name = "installer-\(scenario)-\(language)-\(dark ? "dark" : "light")-720x1600.png"
                attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertGreaterThan(png.count, 1000)
                XCTAssertFalse(store.isBusy)
                let mutationCount = await executor.mutationCount
                XCTAssertEqual(mutationCount, 0)
            }
        }
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
               issue: incomplete ? "Synthetic incomplete journal; no file operation is authorized" : nil)]
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
