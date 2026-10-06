import SwiftUI

struct WorkspaceView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 178, ideal: MoeStyle.sidebarWidth, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if store.isDemoEnabled {
                    HStack(spacing: 8) {
                        Label("Demo mode · example data", systemImage: "eye")
                        Spacer()
                        Button("Exit demo") { store.isDemoEnabled = false }
                            .buttonStyle(.borderless)
                    }
                    .font(.system(size: 11)).padding(.horizontal, 16).frame(height: 28)
                    .background(MoeStyle.lavender.opacity(0.2))
                    Divider()
                }
                switch store.section {
                case .projects: ProjectsView()
                case .tools:
                    if store.selectedToolID == ProcessModule.id { ProcessWorkspaceView() }
                    else { MoleWorkspaceView() }
                case .tasks: TasksView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(store.section == .tools ? (store.registry.descriptor(id: store.selectedToolID)?.title ?? store.section.title) : store.section.title)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField(store.workspaceSearchPrompt, text: searchBinding)
                            .textFieldStyle(.plain).focused($isSearchFocused)
                            .accessibilityLabel(store.workspaceSearchPrompt)
                            .disabled(!store.canSearchWorkspace)
                            .onKeyPress(.escape) {
                                guard isSearchFocused else { return .ignored }
                                if searchBinding.wrappedValue.isEmpty { isSearchFocused = false }
                                else { searchBinding.wrappedValue = "" }
                                return .handled
                            }
                        if !searchBinding.wrappedValue.isEmpty {
                            Button { searchBinding.wrappedValue = ""; isSearchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel("Clear search")
                                .disabled(!store.canSearchWorkspace)
                        }
                    }
                    .padding(.horizontal, 8).frame(width: 230, height: 26)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
                }
                ToolbarItemGroup(placement: .automatic) {
                    switch store.section {
                    case .projects:
                        Menu {
                            Picker("Project filter", selection: $store.projectFilter) {
                                ForEach(ProjectFilter.allCases) { Text($0.title).tag($0) }
                            }
                        } label: { Label("Filter", systemImage: "line.3.horizontal.decrease") }
                        Menu {
                            Button("Add project…") { store.chooseProject(scanChildren: false) }
                            Button("Discover in folder…") { store.chooseProject(scanChildren: true) }
                        } label: { Label("Add project", systemImage: "plus") }
                            .disabled(store.isDemoEnabled || store.isScanning)
                        Button { store.isInspectorPresented.toggle() } label: {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                        .help("Show or hide project details")
                        .accessibilityValue(store.isInspectorPresented ? Text("Shown") : Text("Hidden"))
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    case .tools:
                        if store.selectedToolID == ProcessModule.id {
                            if store.processes.isScanning && !store.isDemoEnabled {
                                Button("Cancel scan", systemImage: "stop.circle") { store.processes.cancel() }
                            } else {
                                Button(store.isDemoEnabled || store.processes.snapshot == nil ? "Start scan" : "Refresh", systemImage: "arrow.clockwise") {
                                    guard !store.isDemoEnabled else { return }
                                    store.processes.startScan(projects: store.projects)
                                }
                                .disabled(store.isDemoEnabled || store.processes.isScanning)
                                .help("Read a bounded snapshot of the current user’s processes and TCP listening ports")
                            }
                        } else {
                            Button("Import report…", systemImage: "square.and.arrow.down") { store.chooseMoleReport() }
                                .disabled(store.isDemoEnabled || store.isImporting || store.selectedCapability != .space)
                        }
                    case .tasks:
                        Menu {
                            Picker("Task filter", selection: $store.taskFilter) {
                                ForEach(TaskFilter.allCases) { Text($0.title).tag($0) }
                            }
                        } label: { Label("Filter", systemImage: "line.3.horizontal.decrease") }
                        if store.isScanning {
                            Button("Cancel discovery", systemImage: "stop.circle") { store.cancelScan() }
                        }
                        if store.processes.isScanning && !store.isDemoEnabled {
                            Button("Cancel process scan", systemImage: "stop.circle") { store.processes.cancel() }
                        }
                    }
                }
            }
        }
        .focusedSceneValue(\.workspaceSearchAction, WorkspaceSearchAction(isEnabled: store.canSearchWorkspace) { isSearchFocused = true })
        .onChange(of: store.section) { isSearchFocused = false }
        .onChange(of: store.selectedToolID) { isSearchFocused = false }
        .onChange(of: store.selectedCapability) { isSearchFocused = false }
        .onChange(of: store.isDemoEnabled) { isSearchFocused = false }
        .font(.system(size: 13))
        .controlSize(.small)
        .sheet(isPresented: Binding(get: { store.pendingDiscovery != nil }, set: { if !$0 { store.pendingDiscovery = nil } })) {
            DiscoveryReviewView().environment(store)
        }
        .alert("MoeKit", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var searchBinding: Binding<String> {
        Binding(get: {
            switch store.section {
            case .projects: store.projectSearch
            case .tools: store.selectedToolID == ProcessModule.id ? store.processes.search : store.toolSearch
            case .tasks: store.taskSearch
            }
        }, set: { value in
            switch store.section {
            case .projects: store.projectSearch = value
            case .tools:
                if store.selectedToolID == ProcessModule.id { store.processes.search = value }
                else { store.toolSearch = value }
            case .tasks: store.taskSearch = value
            }
        })
    }
}

private struct SidebarView: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<WorkspaceSection?>(get: { store.section }, set: { if let value = $0 { store.section = value } })) {
                Section {
                    ForEach(WorkspaceSection.allCases) { section in
                        HStack {
                            Label(section.title, systemImage: section.symbol)
                            Spacer()
                            if section == .tasks && store.runningTaskCount > 0 {
                                Text(store.runningTaskCount.formatted()).foregroundStyle(.secondary)
                            }
                        }.tag(section)
                    }
                }
                switch store.section {
                case .projects:
                    Section("Browse") {
                        ForEach(ProjectFilter.allCases) { filter in
                            Button { store.projectFilter = filter } label: {
                                HStack { Text(filter.title); Spacer(); if store.projectFilter == filter { Image(systemName: "checkmark").font(.caption).accessibilityHidden(true) } }
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(store.projectFilter == filter ? [.isSelected] : [])
                        }
                    }
                    Section("Discovery") {
                        Label("Chosen folders", systemImage: "folder.badge.gearshape").foregroundStyle(.secondary)
                        Button("Add location…") { store.chooseProject(scanChildren: true) }
                            .disabled(store.isDemoEnabled || store.isScanning)
                    }
                case .tools:
                    Section("Tools") {
                        ForEach(store.registry.descriptors) { module in
                            Button { store.selectedToolID = module.id } label: {
                                HStack {
                                    Label(module.title, systemImage: module.systemImage)
                                    Spacer()
                                    if store.selectedToolID == module.id { Image(systemName: "checkmark").font(.caption).accessibilityHidden(true) }
                                }
                                .fontWeight(.medium)
                                .foregroundStyle(store.selectedToolID == module.id ? Color.accentColor : Color.primary)
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(store.selectedToolID == module.id ? [.isSelected] : [])
                            if module.id == MoleModule.id && store.selectedToolID == MoleModule.id {
                                ForEach(MoleCapability.allCases) { capability in
                                    Button { store.selectedCapability = capability } label: {
                                        HStack {
                                            Label(capability.title, systemImage: capability.systemImage)
                                            Spacer()
                                            if store.selectedCapability == capability { Image(systemName: "checkmark").font(.caption).accessibilityHidden(true) }
                                        }
                                        .foregroundStyle(store.selectedCapability == capability ? Color.accentColor : Color.primary)
                                    }.buttonStyle(.plain).padding(.leading, 12)
                                        .accessibilityAddTraits(store.selectedCapability == capability ? [.isSelected] : [])
                                }
                            }
                        }
                    }
                case .tasks:
                    Section("Records") {
                        ForEach(TaskFilter.allCases) { filter in
                            Button { store.taskFilter = filter } label: {
                                HStack { Text(filter.title); Spacer(); if store.taskFilter == filter { Image(systemName: "checkmark").font(.caption).accessibilityHidden(true) } }
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(store.taskFilter == filter ? [.isSelected] : [])
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Spacer(minLength: 0)
            if store.isScanning {
                HStack { ProgressView().controlSize(.mini); Text("Discovering…").font(.caption) }
                    .padding(.bottom, 10)
            }
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.plain)
                Spacer()
                Text("⌘ ,").font(.caption).foregroundStyle(.tertiary)
            }.padding(16)
        }
    }
}

struct StatusBar: View {
    let leading: String
    var trailing: String = ""
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(leading).lineLimit(1)
                Spacer()
                Text(trailing).lineLimit(1)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).frame(height: 24)
        }
    }
}
