import SwiftUI

struct DiscoveryReviewView: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            Text("Review discovered projects").font(.title2).fontWeight(.semibold)
            if let result = store.pendingDiscovery {
                Text("\(result.items.count) projects found. Choose which ones to add to your catalog.")
                    .foregroundStyle(.secondary)
                if !result.issues.isEmpty || result.wasLimited {
                    Label("Partial discovery. Open Tasks to inspect skipped paths and scan limits.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                }
                List(result.items) { item in
                    Toggle(isOn: Binding(get: { store.importSelection.contains(item.id) }, set: { included in
                        if included { store.importSelection.insert(item.id) } else { store.importSelection.remove(item.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                            Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }.listStyle(.inset).frame(minHeight: 240)
            }
            HStack {
                Text("No project files were changed.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.pendingDiscovery = nil }.keyboardShortcut(.cancelAction)
                Button("Add selected") { store.importDiscoveredProjects() }
                    .keyboardShortcut(.defaultAction).disabled(store.importSelection.isEmpty)
            }
        }.padding(24).frame(width: 680, height: 470)
    }
}
