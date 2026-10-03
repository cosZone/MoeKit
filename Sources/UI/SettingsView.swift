import SwiftUI

struct SettingsView: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
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
            Section("Preview") {
                Toggle("Use demo data", isOn: $store.isDemoEnabled).disabled(store.isScanning)
                Text("Demo mode uses example projects and results. It never starts a process or changes project files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Project discovery") {
                LabeledContent("Maximum depth", value: "4")
                LabeledContent("Maximum directories", value: "2,000")
                Text("Hidden directories, symbolic links, dependency folders and build outputs are skipped. Discovery stops at a Git repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tools") {
                ForEach(store.registry.descriptors) { module in
                    LabeledContent(module.title, value: module.readiness.canExecute ? String(localized: "Available") : String(localized: "Adapter not connected"))
                }
                Text("Mole JSON reports can be imported into Space. Cleanup, uninstall, maintenance and live status execution are not connected in this milestone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                Text("Your project list and pins are stored in MoeKit’s Application Support folder. Task records and imported reports last for the current session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 520, height: 600)
    }
}
