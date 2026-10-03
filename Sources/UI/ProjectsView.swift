import SwiftUI

struct ProjectsView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var sortOrder = [KeyPathComparator(\ProjectRecord.sortDate, order: .reverse)]

    var body: some View {
        @Bindable var store = store
        let rows = store.projectRows(sortedBy: sortOrder)
        VStack(spacing: 0) {
            HStack {
                Text(store.projectFilter.title).fontWeight(.medium)
                Spacer()
                Text("\(rows.count) rows").foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(height: 32)
            Divider()
            Table(rows, selection: $store.selectedProjectID, sortOrder: $sortOrder) {
                TableColumn("Project / working directory", value: \.name) { project in
                    HStack(spacing: 7) {
                        if project.kind == .group {
                            Button { store.toggleExpansion(project.id) } label: {
                                Image(systemName: store.expandedProjectIDs.contains(project.id) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                            }.buttonStyle(.plain).accessibilityLabel("Expand or collapse working directories")
                        } else { Color.clear.frame(width: project.parentID == nil ? 10 : 26) }
                        Image(systemName: project.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                        Text(project.name).lineLimit(1)
                        if project.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }.frame(minHeight: 23)
                }.width(min: 180, ideal: 240, max: 340)
                TableColumn("Path", value: \.path) { project in
                    Text(project.kind == .group ? String(localized: "Working directories") : project.path)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(project.path)
                }.width(min: 150, ideal: 320, max: 600)
                TableColumn("Branch", value: \.branchLabel) { Text($0.branchLabel).foregroundStyle(.secondary).lineLimit(1) }
                    .width(min: 90, ideal: 130, max: 220)
                TableColumn("Status", value: \.status) { project in
                    HStack(spacing: 4) {
                        if project.demoUnavailable || (project.demoChangeCount ?? 0) > 0 {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                        Text(project.status).foregroundStyle(.secondary)
                    }.lineLimit(1)
                }.width(min: 95, ideal: 120, max: 160)
                TableColumn("Last opened", value: \.sortDate) { project in
                    if let date = project.lastOpened { Text(date, style: .relative).foregroundStyle(.secondary) }
                    else { Text("—").foregroundStyle(.tertiary) }
                }.width(min: 95, ideal: 110, max: 150)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label(store.displayedProjects.isEmpty ? "Your projects, in one place" : "No matching projects", systemImage: "folder")
                    } description: {
                        Text(store.displayedProjects.isEmpty ? "Add a folder or discover Git repositories in a location you choose." : "Try a different search or filter.")
                    } actions: {
                        if store.displayedProjects.isEmpty {
                            Button("Add project…") { store.chooseProject(scanChildren: false) }.disabled(store.isScanning)
                            Button("Explore demo") { store.isDemoEnabled = true }
                        }
                    }
                }
            }
            Divider()
            projectActions
            StatusBar(leading: String(localized: "\(store.displayedProjects.filter { $0.kind != .group }.count) working directories"),
                      trailing: store.isDemoEnabled ? String(localized: "Example data") : String(localized: "Git working-tree status not checked"))
        }
        .inspector(isPresented: $store.isInspectorPresented) { ProjectInspector().inspectorColumnWidth(min: 260, ideal: 280, max: 340) }
    }

    private var projectActions: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.selectedProject?.name ?? String(localized: "Select a project")).fontWeight(.semibold)
                Text(store.selectedProject?.path ?? String(localized: "Select a working directory to reveal it in Finder"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Finder", systemImage: "folder") { store.revealSelectedProject() }
                .disabled(store.isDemoEnabled || store.selectedProject == nil || store.selectedProject?.kind == .group)
            Button("Related processes", systemImage: "terminal") {
                guard !store.isDemoEnabled, let project = store.selectedProject, project.kind != .group else { return }
                store.processes.openProject(project, projects: store.projects)
                store.selectedToolID = ProcessModule.id
                store.section = .tools
            }
            .disabled(store.isDemoEnabled || store.selectedProject == nil || store.selectedProject?.kind == .group)
            Button("Open tools", systemImage: "briefcase") {
                store.selectedToolID = MoleModule.id
                store.section = .tools
            }
                .disabled(store.selectedProject == nil)
        }.padding(.horizontal, 16).frame(height: 64).background(MoeStyle.secondarySurface)
    }
}

private struct ProjectInspector: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        if let project = store.selectedProject {
            Form {
                Section("Project") {
                    LabeledContent("Name", value: project.name)
                    LabeledContent("Kind", value: project.kind.title)
                    if !project.path.isEmpty { Text(project.path).textSelection(.enabled).font(.caption) }
                }
                Section("Git metadata") {
                    LabeledContent("Branch", value: project.branchLabel)
                    LabeledContent("Status", value: project.status)
                    Text("Discovery reads Git metadata only. It does not run git status, hooks, fetch, or project scripts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if project.kind != .group {
                    Section("Processes & Ports") {
                        if store.isDemoEnabled {
                            Text("Unavailable in Demo").foregroundStyle(.secondary)
                        } else if let snapshot = store.processes.snapshot {
                            let count = snapshot.records.filter { store.processes.association(for: $0).projectID == project.id }.count
                            Text("\(count) inferred processes")
                            LabeledContent("Snapshot") {
                                Text(snapshot.capturedAt, format: .dateTime.month().day().hour().minute().second())
                            }.font(.caption).foregroundStyle(.secondary)
                            if snapshot.isPartial {
                                Label("Partial snapshot", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        } else {
                            Text("Not scanned").foregroundStyle(.secondary)
                        }
                        Text("Association is inferred from the working directory. Opening this view does not scan.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open related processes", systemImage: "terminal") {
                            guard !store.isDemoEnabled else { return }
                            store.processes.openProject(project, projects: store.projects)
                            store.selectedToolID = ProcessModule.id
                            store.section = .tools
                        }.disabled(store.isDemoEnabled)
                    }
                    Button(project.isPinned ? "Unpin project" : "Pin project", systemImage: "pin") { store.togglePin(project.id) }
                        .disabled(store.isDemoEnabled)
                }
            }.formStyle(.grouped)
        } else { ContentUnavailableView("Select a project", systemImage: "sidebar.right") }
    }
}
