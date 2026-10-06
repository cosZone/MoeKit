import SwiftUI
import Observation

/// Self-contained cleanup category. Opening the view never connects to Docker.
@MainActor
struct DockerCleanupView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var store: DockerCleanupStore
    init(store: DockerCleanupStore) { _store = State(initialValue: store) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(d("Docker cleanup"), systemImage: "shippingbox").fontWeight(.semibold)
                    .installerCaptureIdentity("docker.heading", text: d("Docker cleanup"))
                Spacer()
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    Button(d("Stop remaining actions")) { store.cancel() }
                }
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connection
                    if store.isDemoEnabled {
                        Text(d("Docker is unavailable in Demo. No daemon connection is made.")).foregroundStyle(.secondary)
                            .installerCaptureIdentity("docker.demo", text: d("Docker is unavailable in Demo. No daemon connection is made."))
                    }
                    if !store.isDemoEnabled, let error = store.errorMessage { Label(d(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if !store.isDemoEnabled, let inventory = store.inventory {
                        DockerDaemonIdentityView(daemon: inventory.daemon)
                        inventoryRows(inventory)
                        Button(d("Review selection…")) { store.prepare() }.disabled(!store.canPrepare)
                            .accessibilityIdentifier("docker.review")
                            .installerCaptureIdentity("docker.review", text: d("Review selection…"))
                    }
                    if !store.isDemoEnabled {
                        ForEach(store.reports) { result in results(result) }
                    }
                }.padding(18)
            }
        }
        .onAppear { store.bindContext { [weak workspace] in workspace?.isDemoEnabled ?? true } }
        .onChange(of: workspace.isDemoEnabled) { _, value in store.updateDemo(value) }
        .onDisappear { store.leave() }
        .sheet(item: Binding(get: { store.plan }, set: { if $0 == nil { store.dismissPlan() } })) { plan in
            DockerCleanupConfirmationView(plan: plan, onCancel: { store.dismissPlan() }, onConfirm: { store.confirm(planID: plan.id) })
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(d("Choose Docker Desktop or a local Engine, then scan its contents. Start Docker yourself first."))
                .foregroundStyle(.secondary)
            HStack {
                Picker(d("Local endpoint"), selection: Binding(get: { store.endpoint == .desktop ? 0 : 1 }, set: {
                    store.chooseEndpoint($0 == 0 ? .desktop : .engine)
                })) {
                    Text("Docker Desktop").tag(0)
                    Text(d("Local Docker Engine")).tag(1)
                }.frame(maxWidth: 330).disabled(!store.canInspect)
                Button(d("Connect and scan")) { store.inspect() }.disabled(!store.canInspect)
                    .accessibilityIdentifier("docker.connect")
                    .installerCaptureIdentity("docker.connect", text: d("Connect and scan"))
            }
            Text(store.endpoint.socketPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            DisclosureGroup(d("Connection details")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(d("MoeKit ignores Docker CLI contexts and does not read credentials or start Docker."))
                    Text(d("Only local Unix sockets are supported. Remote contexts, automatic installation, permission changes and network pulls are unavailable."))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
    }

    private func inventoryRows(_ inventory: DockerInventory) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(d("Images")).font(.headline)
            Text(d("Only images unused by every container can be selected, including stopped containers. Sizes are estimates, not guaranteed savings."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(inventory.images) { image in
                HStack(alignment: .top) {
                    Toggle(isOn: imageBinding(image.id)) { EmptyView() }.labelsHidden()
                        .disabled(store.isBusy || !inventory.imageIsEligible(image))
                        .accessibilityLabel(safe(image.title))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(safe(image.title)).lineLimit(2)
                        Text(image.id).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        Text(image.dangling ? d("Dangling image") : d("Tagged image; all listed tags belong to this image ID"))
                            .font(.caption).foregroundStyle(.secondary)
                        projectLabels(image.labels)
                        if !inventory.imageIsEligible(image) {
                            Text(d("Protected: referenced by a container or usage is unknown")).font(.caption).foregroundStyle(.orange)
                            ForEach(inventory.references(to: image)) { reference in
                                Text("↳ \(safe(reference.title)) · \(safe(reference.state))").font(.caption)
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(size(image.size))
                        Text(d("Unique estimate") + ": " + (image.uniqueBytes.map(size) ?? d("Unknown"))).font(.caption)
                    }.foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                Divider()
            }
            if inventory.images.isEmpty { Text(d("No images")).foregroundStyle(.secondary) }
            Text(d("Containers")).font(.headline)
            Text(d("Only selected created or exited containers can be deleted. Their writable data is permanently lost; volumes stay. All other states are protected."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(inventory.containers) { container in
                HStack(alignment: .top) {
                    Toggle(isOn: containerBinding(container.id)) { EmptyView() }.labelsHidden()
                        .disabled(store.isBusy || !container.isStopped).accessibilityLabel(safe(container.title))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(safe(container.title))
                        Text(container.id).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        Text(safe(container.state) + " · " + container.imageID).font(.caption).foregroundStyle(.secondary)
                        projectLabels(container.labels)
                    }
                }
            }
            if inventory.containers.isEmpty { Text(d("No containers")).foregroundStyle(.secondary) }
            Text(d("Build cache")).font(.headline)
            Toggle(d("Remove all unused build cache on this daemon"), isOn: Binding(get: { store.selection.allUnusedBuildCache }, set: {
                var value = store.selection; value.allUnusedBuildCache = $0; store.select(value)
            })).disabled(store.isBusy || !inventory.buildCache.contains { !$0.inUse })
            Text(d("This separate operation covers the entire local daemon’s unused build cache, including internal/frontend cache. It is not an exact-row deletion. Builds may take longer afterward. In-use cache is protected by Docker; other builders and remote contexts are not accessed."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(inventory.buildCache) { cache in
                HStack {
                    Text(safe(cache.id)).font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text(cache.inUse ? d("In use · protected") : d("Unused"))
                    Text(cache.shared ? d("Shared") : d("Unshared"))
                    Text(size(cache.size))
                }.font(.caption)
            }
            if inventory.buildCache.isEmpty { Text(d("No build cache")).foregroundStyle(.secondary) }
            Text(d("Volumes · always protected")).font(.headline)
            Text(d("Volumes are shown for reference and cannot be deleted here."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(inventory.volumes) { volume in
                Label("\(safe(volume.name)) · \(safe(volume.driver))", systemImage: "lock.fill").font(.caption)
            }
            if inventory.volumes.isEmpty { Text(d("No volumes")).foregroundStyle(.secondary) }
        }
    }

    private func results(_ result: DockerCleanupResult) -> some View {
        GroupBox(d("Operation results")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(d("Operation daemon") + ": " + safe(result.daemon.name) + " · " + safe(result.daemon.id)).font(.caption)
                if result.cancelled { Text(d("Cancelled. Already-sent Docker operations may still complete; cancellation does not undo them.")) }
                if result.hasUncertainty { Text(d("Some results remain uncertain. Refresh the inventory before making a new selection.")).foregroundStyle(.orange) }
                ForEach(result.items) { item in
                    Text("\(d(item.state.rawValue)) · \(item.id)").fontWeight(.medium)
                    Text(d(item.detail)).font(.caption).foregroundStyle(.secondary)
                }
                if let reclaimed = result.reclaimedCacheBytes {
                    Text(d("Docker-reported cache bytes reclaimed") + ": \(reclaimed)")
                }
                Text(d("Engine-reported reclamation does not guarantee the same physical space is returned to macOS or Docker Desktop’s disk image."))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.installerCaptureIdentity("docker.results", text: d("Operation results"))
    }
    private func projectLabels(_ labels: [String: String]) -> some View {
        ForEach(labels.keys.sorted(), id: \.self) { key in
            Text("\(key): \(safe(labels[key] ?? ""))").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func imageBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { store.selection.imageIDs.contains(id) }, set: { selected in
            var value = store.selection
            if selected { value.imageIDs.insert(id) } else { value.imageIDs.remove(id) }
            store.select(value)
        })
    }
    private func containerBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { store.selection.containerIDs.contains(id) }, set: { selected in
            var value = store.selection
            if selected { value.containerIDs.insert(id) } else { value.containerIDs.remove(id) }
            store.select(value)
        })
    }
    private func d(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "DockerCleanup") }
    private func safe(_ text: String) -> String { DockerValidation.safeDisplay(text) }
    private func size(_ value: Int64) -> String { value < 0 ? d("Unknown") : ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

@MainActor
struct DockerCleanupConfirmationView: View {
    let plan: DockerCleanupPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var acknowledgement: DockerConfirmationAcknowledgement
    init(plan: DockerCleanupPlan, acknowledgement: DockerConfirmationAcknowledgement? = nil,
         onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.plan = plan; self.onCancel = onCancel; self.onConfirm = onConfirm
        _acknowledgement = State(initialValue: acknowledgement ?? DockerConfirmationAcknowledgement())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(d("Confirm permanent Docker cleanup")).font(.title2.bold())
            DockerDaemonIdentityView(daemon: plan.inventory.daemon)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.selection.containerIDs.sorted(), id: \.self) { id in
                        Text(d("Remove container") + ": " + id).textSelection(.enabled)
                        if let item = plan.inventory.containers.first(where: { $0.id == id }) { Text(safe(item.title)).font(.caption) }
                    }
                    ForEach(plan.selection.imageIDs.sorted(), id: \.self) { id in
                        Text(d("Remove image") + ": " + id).textSelection(.enabled)
                        if let item = plan.inventory.images.first(where: { $0.id == id }) { Text(safe(item.tags.joined(separator: ", "))).font(.caption) }
                    }
                    if plan.selection.allUnusedBuildCache { Text(d("Remove all unused build cache on this daemon")).fontWeight(.semibold) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
            Text(d("These Docker deletions cannot be undone by MoeKit. Images may need to be rebuilt or pulled manually. Stopped-container writable data is lost. Volumes and running containers are preserved. No network pull is performed."))
            Toggle(d("I understand this permanently removes the listed Docker objects"), isOn: $acknowledgement.irreversible)
                .installerCaptureIdentity("docker.confirm.attestation", text: d("I understand this permanently removes the listed Docker objects"))
            if plan.selection.allUnusedBuildCache {
                Toggle(d("I also approve the entire daemon-wide unused build-cache scope"), isOn: $acknowledgement.wholeCache)
                    .installerCaptureIdentity("docker.confirm.cache", text: d("I also approve the entire daemon-wide unused build-cache scope"))
            }
            Text(d("The confirmation expires after 60 seconds. Docker identity and object usage are checked again before execution."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(d("Cancel")) { acknowledgement.cancel(onCancel) }.keyboardShortcut(.cancelAction)
                    .installerCaptureIdentity("docker.confirm.cancel", text: d("Cancel"))
                Button(d("Permanently remove"), role: .destructive) { acknowledgement.submit(plan: plan, action: onConfirm) }
                    .disabled(!acknowledgement.canSubmit(plan))
                    .accessibilityIdentifier("docker.confirm")
                    .installerCaptureIdentity("docker.confirm.submit", text: d("Permanently remove"))
            }
        }.padding(24).frame(width: 680)
            .onAppear { acknowledgement.reset(for: plan.id) }
            .onChange(of: plan.id) { _, id in acknowledgement.reset(for: id) }
            .onDisappear { acknowledgement.invalidate() }
    }

    private func d(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "DockerCleanup") }
    private func safe(_ text: String) -> String { DockerValidation.safeDisplay(text) }
}

private struct DockerDaemonIdentityView: View {
    let daemon: DockerDaemonIdentity
    var body: some View {
        GroupBox(d("Connected daemon")) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(safe(daemon.name)) · Docker \(safe(daemon.version)) · \(safe(daemon.operatingSystem))")
                Text("ID: \(safe(daemon.id))").textSelection(.enabled)
                    .installerCaptureIdentity("docker.daemon", text: daemon.id)
                Text(d("Kernel peer") + ": PID \(daemon.peer.pid) · UID \(daemon.peer.uid)").textSelection(.enabled)
                Text(daemon.socket.path).textSelection(.enabled)
                Text(daemon.rootless ? d("Rootless daemon") : d("Rootless mode not reported by daemon"))
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func d(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "DockerCleanup") }
    private func safe(_ text: String) -> String { DockerValidation.safeDisplay(text) }
}

@MainActor @Observable
final class DockerConfirmationAcknowledgement {
    var irreversible = false
    var wholeCache = false
    private(set) var planID: UUID?
    private(set) var consumed = false
    func reset(for id: UUID) { planID = id; consumed = false; irreversible = false; wholeCache = false }
    func invalidate() { consumed = true; irreversible = false; wholeCache = false }
    func canSubmit(_ plan: DockerCleanupPlan) -> Bool {
        !consumed && planID == plan.id && irreversible && (!plan.selection.allUnusedBuildCache || wholeCache) && plan.expiresAt > Date()
    }
    func submit(plan: DockerCleanupPlan, action: () -> Void) {
        guard canSubmit(plan) else { return }
        consumed = true
        action()
    }
    func cancel(_ action: () -> Void) { invalidate(); action() }
}
