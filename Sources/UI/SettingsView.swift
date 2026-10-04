import SwiftUI

struct SettingsView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }

            AboutView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 600)
    }

    @ViewBuilder
    private var generalSettings: some View {
        @Bindable var store = store
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("BrandMark").resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MoeKit").font(.title2).fontWeight(.semibold)
                        Text("A native home for your personal CLI toolbox").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Getting started") {
                Button("Open getting started") {
                    if store.showGettingStarted() { openWindow(id: "getting-started") }
                }.disabled(!store.canNavigateFromGettingStarted)
                Text("Choose a first step and learn what this preview can read and do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                Toggle("Use demo data", isOn: $store.isDemoEnabled)
                Text("Demo mode uses example projects and results. Changing modes cancels current discovery and report imports. It never starts a process or changes project files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Project discovery") {
                LabeledContent("Maximum depth", value: "4")
                LabeledContent("Maximum directories", value: "2,000")
                Text("Hidden directories, symbolic links, dependency folders and build outputs are skipped. Discovery stops at a Git repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tools") {
                Button("Tool preparation…") { openWindow(id: "tool-preparation") }
                ForEach(store.registry.descriptors) { module in
                    LabeledContent(module.title, value: module.id == MoleModule.id ? String(localized: "Verify analyzer before use") : (module.readiness.canExecute ? String(localized: "Available") : String(localized: "Adapter not connected")))
                }
                Text("Space supports report import and separately confirmed analysis with a verified official analyzer. Cleanup, uninstall, maintenance and live status remain unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                Text("Your project list and pins are stored in MoeKit’s Application Support folder. Task records and imported reports last for the current session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
