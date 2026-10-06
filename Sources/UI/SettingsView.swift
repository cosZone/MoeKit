import SwiftUI

struct SettingsView: View {
    var checkForUpdates: () -> Void = {}
    var automaticUpdates: SparkleUpdateStore? = nil
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppVisibilityPreferences.self) private var visibility
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
        @Bindable var visibility = visibility
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("BrandMark").resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MoeKit").font(.title2).fontWeight(.semibold)
                        Text("Projects and tools, in one place").foregroundStyle(.secondary)
                    }
                }
            }
            Section("App icons") {
                Toggle("Show Dock icon", isOn: $visibility.showDockIcon)
                    .installerCaptureIdentity("icons.dock", text: String(localized: "Show Dock icon"))
                Toggle("Show menu bar icon", isOn: $visibility.showMenuBarIcon)
                    .installerCaptureIdentity("icons.menu", text: String(localized: "Show menu bar icon"))
                Text("Closing a window may cancel its work. MoeKit stays open until you quit.")
                    .font(.caption).foregroundStyle(.secondary)
                if visibility.hasNoPersistentIcon {
                    Label("Both icons are hidden. Open MoeKit from Finder or Spotlight to return to the workspace and settings.", systemImage: "info.circle")
                        .font(.caption)
                        .installerCaptureIdentity("icons.recovery", text: String(localized: "Both icons are hidden. Open MoeKit from Finder or Spotlight to return to the workspace and settings."))
                }
            }
            if let automaticUpdates {
                AutomaticUpdateSettings(updates: automaticUpdates, openManualReleases: checkForUpdates)
            } else {
                Section("Updates") {
                    Button("Check for updates…", action: checkForUpdates)
                    Text("Review newer releases and download them from GitHub. Automatic installation is not enabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Getting started") {
                Button("Open getting started") {
                    if store.showGettingStarted() { openWindow(id: "getting-started") }
                }.disabled(!store.canNavigateFromGettingStarted)
                Text("Find a first step.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                Toggle("Use demo data", isOn: $store.isDemoEnabled)
                Text("Use built-in examples. Switching modes cancels discovery and report imports; project files stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Project discovery") {
                DisclosureGroup("Discovery limits") {
                    LabeledContent("Maximum depth", value: "4")
                    LabeledContent("Maximum directories", value: "2,000")
                    Text("Hidden directories, symbolic links, dependency folders and build outputs are skipped. Discovery stops at a Git repository.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Tools") {
                Button("Tool preparation…") { openWindow(id: "tool-preparation") }
                ForEach(store.registry.descriptors) { module in
                    LabeledContent(module.title, value: module.id == MoleModule.id ? String(localized: "Verify analyzer before use") : (module.readiness.canExecute ? String(localized: "Available") : String(localized: "Not available yet")))
                }
                Text("Analysis, cleanup and process stopping are reviewed before they run. Uninstall, maintenance and live status are not available yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                DisclosureGroup("What is saved locally") {
                    Text("Your project list, pins and private recovery receipts are stored in MoeKit’s Application Support folder. Task records and imported reports last for the current session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}
