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
                if store.hasProjectFilters {
                    Button("Clear filters") { store.clearProjectFilters() }.buttonStyle(.borderless)
                }
                Text("\(rows.count) rows").foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(height: 32)
            if store.isScanning {
                Divider()
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        if let progress = store.scanProgress {
                            Text("\(progress.visitedDirectories) directories inspected · \(progress.completedRoots)/\(progress.totalRoots) folders finished")
                            Text(progress.root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        } else { Text("Preparing discovery…") }
                    }
                    Spacer()
                    Button("Cancel discovery", systemImage: "stop.circle") { store.cancelScan() }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider()
            Table(rows, selection: $store.selectedProjectID, sortOrder: $sortOrder) {
                TableColumn("Project", value: \.name) { project in
                    HStack(spacing: 7) {
                        if store.hasProjectChildren(project.id) {
                            Button { store.toggleExpansion(project.id) } label: {
                                Image(systemName: store.isProjectExpanded(project.id) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(Text("Working directories for \(project.name)"))
                                .accessibilityValue(store.isProjectExpanded(project.id) ? Text("Expanded") : Text("Collapsed"))
                                .disabled(store.hasProjectFilters)
                                .help("Matching working directories stay expanded while filtering")
                        } else { Color.clear.frame(width: project.parentID == nil ? 10 : 26) }
                        Image(systemName: project.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                        Text(project.name).lineLimit(1)
                        if project.gitMetadata?.isLocked == true {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange)
                                .accessibilityLabel("Git worktree lock observed").help("Git worktree lock observed")
                        }
                        if project.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
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
            .accessibilityLabel("Projects")
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label(store.isScanning ? "Discovering projects…" : (store.displayedProjects.isEmpty ? "Your projects, in one place" : "No matching projects"), systemImage: store.isScanning ? "hourglass" : "folder")
                    } description: {
                        Text(store.isScanning ? "Reading only the folders you selected. You can cancel discovery at any time." : (store.displayedProjects.isEmpty ? "Add a project or find Git projects in a folder. Only folders you choose are read; your files stay unchanged." : "Try a different search or filter."))
                    } actions: {
                        if !store.isScanning && store.displayedProjects.isEmpty {
                            Button("Add project…") { store.chooseProject(scanChildren: false) }.disabled(store.isDemoEnabled)
                            Button("Discover in folder…") { store.chooseProject(scanChildren: true) }.disabled(store.isDemoEnabled)
                            GettingStartedButton()
                        } else if !store.isScanning && store.hasProjectFilters {
                            Button("Clear filters") { store.clearProjectFilters() }
                        }
                    }
                }
            }
            Divider()
            projectActions
            StatusBar(leading: String(localized: "\(store.displayedProjects.filter { $0.kind != .group }.count) working directories"),
                      trailing: store.isDemoEnabled ? String(localized: "Example data") : String(localized: "Git working-tree status not checked"))
        }
        .onChange(of: rows.map(\.id)) { _, visibleIDs in
            if let selected = store.selectedProjectID, !visibleIDs.contains(selected) { store.selectedProjectID = nil }
        }
        .sheet(item: Binding(get: { store.cleanupReviewProject }, set: { store.cleanupReviewProjectID = $0?.id })) { project in
            if !store.isDemoEnabled { GitCleanupView(project: project) }
        }
        .inspector(isPresented: $store.isInspectorPresented) { ProjectInspector().inspectorColumnWidth(min: 260, ideal: 280, max: 340) }
    }

    private var projectActions: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.selectedProject?.name ?? String(localized: "Select a project")).fontWeight(.semibold)
                    .lineLimit(1)
                Text(store.selectedProject?.path ?? String(localized: "Select a project to see its location"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Finder", systemImage: "folder") { store.revealSelectedProject() }
                .disabled(store.isDemoEnabled || store.selectedProject == nil || store.selectedProject?.kind == .group)
            Menu {
                Button(store.selectedProject?.isPinned == true ? "Unpin project" : "Pin project", systemImage: "pin") {
                    if let project = store.selectedProject { store.togglePin(project.id) }
                }.disabled(store.isDemoEnabled || store.selectedProject?.kind == .group)
                Button("Related processes", systemImage: "terminal") {
                    guard !store.isDemoEnabled, let project = store.selectedProject, project.kind != .group else { return }
                    store.processes.openProject(project, projects: store.projects)
                    store.selectedToolID = ProcessModule.id
                    store.section = .tools
                }.disabled(store.isDemoEnabled || store.selectedProject?.kind == .group)
                Button("Git cleanup…", systemImage: "shield.lefthalf.filled") { store.presentCleanupReview() }
                    .disabled(store.isDemoEnabled || store.selectedProject?.kind == .group)
                Divider()
                Button("Open tools", systemImage: "briefcase") {
                    store.selectedToolID = MoleModule.id
                    store.section = .tools
                }
            } label: { Label("Project actions", systemImage: "ellipsis.circle") }
                .fixedSize().disabled(store.selectedProject == nil)
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
                    if let metadata = project.gitMetadata {
                        LabeledContent("Observed") { Text(metadata.observedAt, format: .dateTime.month().day().hour().minute()) }
                        if metadata.isLinkedWorktree {
                            Label("Verified worktree relationship", systemImage: "arrow.triangle.branch")
                            LabeledContent("Lock", value: metadata.isLocked ? String(localized: "Locked when scanned") : String(localized: "No lock observed"))
                        }
                        Text(metadata.commonDirectoryPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Shared Git metadata directory").font(.caption).foregroundStyle(.secondary)
                    }
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


private struct ProjectCleanupReview: View {
    let project: ProjectRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let preview = ProjectCleanupPreview(project: project)
        VStack(alignment: .leading, spacing: 16) {
            Label("Cleanup safety review", systemImage: "shield.lefthalf.filled").font(.title2).fontWeight(.semibold)
            Text(project.name).font(.headline)
            Text(preview.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Label("Protected · not eligible for cleanup", systemImage: "lock.fill").foregroundStyle(.orange)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "exclamationmark.circle").fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Review only. No deletion is available and no reclaimable space has been measured.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600, height: 490)
            .onExitCommand { dismiss() }
    }
}
