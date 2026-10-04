import AppKit
import SwiftUI

@MainActor
struct ToolPreparationView: View {
    let homeDirectory: URL
    @State private var preparation: ToolPreparationStore
    @State private var tool = PreparedTool.mole
    @State private var copiedCommand: String?
    @State private var selectingFile = false
    @State private var selectionGeneration = UUID()

    init(preparation: ToolPreparationStore,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        _preparation = State(initialValue: preparation)
    }

    private var canInspect: Bool { !preparation.isDemoEnabled && !preparation.isInspecting && !selectingFile }
    private var locations: [URL] { tool.conventionalLocations(home: homeDirectory) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Tool preparation", systemImage: "wrench.and.screwdriver").font(.title2).fontWeight(.semibold)
                Text("Check file locations and find official installation instructions. Finding a file does not verify a working or trusted tool.")
                    .foregroundStyle(.secondary)
                Picker("Tool", selection: $tool) {
                    ForEach(PreparedTool.allCases) { item in Text(item.title).tag(item) }
                }.pickerStyle(.segmented)
                    .disabled(preparation.isInspecting || selectingFile)
                if preparation.isDemoEnabled {
                    Label("Tool inspection is disabled in Demo. No example installation is shown.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Location checks").font(.headline)
                        Text("Only metadata is inspected. No version command, shell, installer or tool is started.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Check common locations") { preparation.inspect(tool, locations: locations) }
                                .disabled(!canInspect)
                            Button("Inspect another file…") { chooseFile() }.disabled(!canInspect)
                        }
                        DisclosureGroup("Locations checked by this button") {
                            ForEach(locations, id: \.path) { location in
                                Text(location.path).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.font(.callout)
                        if preparation.isInspecting {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(preparation.isCancelling ? "Cancelling inspection…" : "Inspecting file metadata…")
                                Spacer()
                                Button("Cancel") { preparation.cancel() }.disabled(preparation.isCancelling)
                            }
                        }
                        if let error = preparation.errorMessage { Text(error).foregroundStyle(.orange) }
                        if let observations = preparation.observations[tool] {
                            ForEach(observations) { observation in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(observation.path).font(.callout.monospaced()).textSelection(.enabled)
                                    Text(observation.state.title).fontWeight(.medium)
                                    Text(observation.state.explanation).font(.caption).foregroundStyle(.secondary)
                                    Text(observation.observedAt, format: .dateTime.month().day().hour().minute().second())
                                        .font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if observation.id != observations.last?.id { Divider() }
                            }
                        } else if !preparation.isInspecting {
                            Text("Not checked").foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Install or review manually").font(.headline)
                        Link("Official installation instructions", destination: tool.documentationURL)
                        Text("If you already use Homebrew, its documented install command is:")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Text(tool.installCommand).font(.body.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button(copiedCommand == tool.installCommand ? "Copied" : "Copy command") {
                                let command = tool.installCommand
                                NSPasteboard.general.clearContents()
                                if NSPasteboard.general.setString(command, forType: .string) { copiedCommand = command }
                            }
                        }
                        Text("Copying only changes the clipboard. Running this command yourself can install dependencies, access the network and update Homebrew. Review the official instructions first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                Text(tool == .mole
                     ? "Mole execution remains unavailable. Space can import a JSON report without installing or running Mole. No cleanup command is connected."
                     : "Project discovery reads Git metadata without running Git. A file at /usr/bin/git may be an Apple launcher; it does not prove Command Line Tools are installed. Git status execution remains unavailable.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 520, idealHeight: 720)
        .onDisappear {
            selectionGeneration = UUID()
            preparation.cancel()
        }
    }

    private func chooseFile() {
        guard canInspect else { return }
        let selectedTool = tool
        let mode = preparation.modeGeneration
        let request = UUID()
        selectionGeneration = request
        selectingFile = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.message = String(localized: "Choose a candidate file to inspect its metadata. It will not be run.")
        panel.prompt = String(localized: "Inspect metadata")
        panel.begin { response in
            selectingFile = false
            guard response == .OK, selectionGeneration == request, let url = panel.url else { return }
            preparation.inspect(selectedTool, locations: [url], expectedMode: mode)
        }
    }
}
