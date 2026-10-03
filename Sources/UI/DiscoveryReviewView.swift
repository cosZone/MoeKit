import SwiftUI

struct DiscoveryReviewView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var search = ""
    @State private var sortByPath = false

    private var visibleItems: [DiscoveredRepository] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (store.pendingDiscovery?.items ?? []).filter { item in
            query.isEmpty || [item.name, item.url.path, item.branch ?? ""].contains { $0.localizedStandardContains(query) }
        }.sorted {
            let left = sortByPath ? $0.url.path : $0.name
            let right = sortByPath ? $1.url.path : $1.name
            let comparison = left.localizedStandardCompare(right)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review discovered projects").font(.title2).fontWeight(.semibold)
            if let result = store.pendingDiscovery {
                Text("\(result.items.count) projects found. Existing paths update metadata without changing pins or history.")
                    .foregroundStyle(.secondary)
                if !result.issues.isEmpty || result.wasLimited {
                    Label("Partial discovery. Open Tasks to inspect skipped paths and scan limits.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                }
                HStack {
                    TextField("Filter by name, path or branch", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Picker("Sort", selection: $sortByPath) {
                        Text("Name").tag(false)
                        Text("Path").tag(true)
                    }.frame(width: 150)
                }
                HStack {
                    Button("Select visible") { store.importSelection.formUnion(visibleItems.map(\.id)) }
                        .disabled(visibleItems.isEmpty)
                    Button("Clear selection") { store.importSelection = [] }
                        .disabled(store.importSelection.isEmpty)
                    Spacer()
                    Text("\(store.importSelection.count) selected · \(visibleItems.count) visible").foregroundStyle(.secondary)
                }.font(.caption)
                List(visibleItems) { item in
                    Toggle(isOn: Binding(get: { store.importSelection.contains(item.id) }, set: { included in
                        if included { store.importSelection.insert(item.id) } else { store.importSelection.remove(item.id) }
                    })) {
                        HStack(spacing: 8) {
                            Image(systemName: item.metadata?.isLinkedWorktree == true ? "arrow.triangle.branch" : "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.name).fontWeight(.medium)
                                    if store.projects.contains(where: { $0.path == item.url.path }) {
                                        Text("Update existing").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if item.metadata?.isLocked == true { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                                }
                                Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(item.branch ?? String(localized: "Unknown branch")).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).frame(maxWidth: 150, alignment: .trailing)
                        }
                    }
                }.listStyle(.inset).frame(minHeight: 220)
                .overlay {
                    if visibleItems.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "No repositories found" : "No matching projects", systemImage: "magnifyingglass")
                    }
                }
            }
            HStack {
                Text("No project files were changed.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.pendingDiscovery = nil; store.importSelection = [] }.keyboardShortcut(.cancelAction)
                Button("Add or update selected") { store.importDiscoveredProjects() }
                    .keyboardShortcut(.defaultAction).disabled(store.importSelection.isEmpty)
            }
        }.padding(24).frame(width: 760, height: 550)
    }
}
