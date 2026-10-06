import SwiftUI

/// The quick panel is navigation and read-only status, never a shortcut around
/// a tool's existing confirmation, cancellation or data-access boundaries.
struct MenuBarPanelView: View {
    let presentation: MenuBarPresentation
    let openWorkspace: () -> Void
    let openSettings: () -> Void
    let checkUpdates: () -> Void
    let quit: () -> Void
    let close: () -> Void
    @FocusState private var openFocused: Bool

    static let size = CGSize(width: 328, height: 304)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(nsImage: MenuBarIcon.image(activity: .idle))
                    .resizable().frame(width: 29, height: 29).accessibilityHidden(true)
                Text("MoeKit").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(MenuBarText.localized("Close panel"))
                    .help(MenuBarText.localized("Close panel"))
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: presentation.snapshot.activity.symbol)
                    .font(.system(size: 17)).frame(width: 22).padding(.top, 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.snapshot.activity.title).font(.system(size: 13, weight: .medium))
                    Text(presentation.snapshot.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(2).help(presentation.snapshot.detail)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            Button(action: openWorkspace) {
                HStack {
                    Text(MenuBarText.localized("Open MoeKit"))
                    Spacer()
                    Text("⌘0").foregroundStyle(.secondary)
                }.frame(height: 22)
            }
            .buttonStyle(.bordered).controlSize(.regular)
            .focused($openFocused)
            .keyboardShortcut("0", modifiers: .command)
            HStack(spacing: 12) {
                Button(action: openSettings) { Label(MenuBarText.localized("Settings"), systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button(action: checkUpdates) { Label(MenuBarText.localized("Check for updates"), systemImage: "arrow.down.circle") }
                    .disabled(!presentation.canCheckUpdates)
            }.buttonStyle(.borderless).font(.system(size: 12))
            Divider()
            HStack {
                Text(MenuBarText.localized(presentation.snapshot.activity == .demo ? "Example data" : "This session"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(MenuBarText.localized("Quit MoeKit"), action: quit).keyboardShortcut("q", modifiers: .command)
            }.buttonStyle(.borderless).font(.system(size: 11))
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .onAppear { openFocused = true }
        .onExitCommand(perform: close)
        .accessibilityLabel(MenuBarText.localized("MoeKit quick panel"))
    }
}
