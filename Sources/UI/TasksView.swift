import SwiftUI

struct TasksView: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Text(store.taskFilter.title).fontWeight(.medium)
                Spacer()
                Text(store.isDemoEnabled ? "Example records" : "This session").foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(height: 32)
            Divider()
            VSplitView {
                Table(store.filteredTasks, selection: $store.selectedTaskID) {
                    TableColumn("Task") { task in
                        Label(task.title, systemImage: task.status.symbol).frame(minHeight: 23)
                    }.width(min: 170, ideal: 240, max: 380)
                    TableColumn("Target") { Text($0.target).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        .width(min: 130, ideal: 250, max: 500)
                    TableColumn("Tool") { Text($0.tool).foregroundStyle(.secondary) }.width(80)
                    TableColumn("Status") { task in
                        Text(task.status.title).foregroundStyle(task.status == .partial || task.status == .failed ? Color.orange : Color.secondary)
                    }.width(min: 100, ideal: 120, max: 150)
                    TableColumn("Started") { Text($0.startedAt, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary) }
                        .width(100)
                    TableColumn("Duration") { Text($0.duration).monospacedDigit().foregroundStyle(.secondary) }.width(70)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 200)
                .overlay {
                    if store.filteredTasks.isEmpty {
                        ContentUnavailableView("No tasks yet", systemImage: "list.bullet.rectangle", description: Text("Folder discovery appears here with its actual result and any unreadable paths."))
                    }
                }
                if let task = store.selectedTask {
                    TaskDetailView(task: task).frame(minHeight: 180, idealHeight: 260, maxHeight: 450)
                }
            }
            StatusBar(leading: String(localized: "\(store.filteredTasks.count) records"),
                      trailing: store.isDemoEnabled ? String(localized: "Example data") : String(localized: "Task records are kept for this session"))
        }
    }
}

private struct TaskDetailView: View {
    let task: TaskRecord
    @State private var showDiagnostics = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(task.title).fontWeight(.semibold)
                Label(task.status.title, systemImage: task.status.symbol).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if task.isDemo { Text("Example record").font(.caption).foregroundStyle(.secondary) }
                Toggle("Diagnostics", isOn: $showDiagnostics).toggleStyle(.button)
            }.padding(.horizontal, 16).frame(height: 44).background(MoeStyle.secondarySurface)
            Text(task.summary).font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 10)
            if showDiagnostics {
                ScrollView {
                    Text(task.diagnostics.isEmpty ? String(localized: "No diagnostic output") : task.diagnostics)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            } else {
                Table(task.items) {
                    TableColumn("Path") { Text($0.path).lineLimit(1).truncationMode(.middle) }.width(min: 200, ideal: 420, max: 700)
                    TableColumn("Actual result") { item in
                        Label(item.outcome, systemImage: item.hasIssue ? "exclamationmark.triangle" : "info.circle")
                            .foregroundStyle(item.hasIssue ? Color.orange : Color.secondary)
                    }.width(min: 130, ideal: 170, max: 230)
                    TableColumn("Detail") { Text($0.detail).foregroundStyle(.secondary).lineLimit(2) }
                }.tableStyle(.inset)
            }
        }
    }
}
