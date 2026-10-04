import SwiftUI

/// A short, optional guide. Its actions navigate; existing workspace controls
/// remain the only entry points to file pickers and process scans.
struct GettingStartedView: View {
    @Environment(WorkspaceStore.self) private var store
    let close: () -> Void
    var openWorkspace: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 27)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to MoeKit").font(.title2).fontWeight(.semibold)
                    Text("Your projects, tools and task results, together.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let goal = store.gettingStarted.selectedGoal {
                        Label(goal.title, systemImage: goal.symbol).font(.title3).fontWeight(.semibold)
                        guidanceSection("Your first step", symbol: "1.circle", text: goal.firstStep)
                        guidanceSection("Before you start", symbol: "hand.raised", text: goal.privacy)
                        if goal == .projects {
                            Text("After discovery, Tasks shows progress, cancellation and actual results. Git working-tree changes are not checked yet.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Text("This button opens the workspace. It does not start a scan or ask for folder access.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("What would you like to do first?").font(.headline)
                        ForEach(GettingStartedGoal.allCases) { goal in
                            Button { store.gettingStarted.selectedGoal = goal } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: goal.symbol).font(.title3).frame(width: 24)
                                        .foregroundStyle(Color.accentColor).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(goal.title).fontWeight(.semibold)
                                        Text(goal.summary).foregroundStyle(.secondary).font(.callout)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                                }.padding(14).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(MoeStyle.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
                            .accessibilityElement(children: .combine)
                        }
                        Text("Mole Space supports reports and confirmed analysis with the official V1.57.0 analyzer. Native cache cleanup and stopping exact unprotected processes each require separate confirmation. Uninstall remains unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            Divider()
            HStack {
                if store.gettingStarted.selectedGoal != nil {
                    Button("Back", systemImage: "chevron.left") { store.gettingStarted.back() }
                }
                Button("Skip for now") { finish() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let goal = store.gettingStarted.selectedGoal {
                    Button(goal.buttonTitle) {
                        store.openGettingStartedGoal(goal)
                        finish()
                        openWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canNavigateFromGettingStarted)
                }
            }.padding(.horizontal, 24).padding(.top, 14)
            Text("You can reopen this guide from Help or Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)
        }
        .font(.system(size: 13))
        .frame(minWidth: 520, idealWidth: 620, minHeight: 480, idealHeight: 580)
        .onDisappear { store.gettingStarted.dismiss() }
    }

    private func guidanceSection(_ title: LocalizedStringKey, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).fontWeight(.semibold)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func finish() {
        store.gettingStarted.dismiss()
        close()
    }
}

/// Reusable contextual entry point, including empty workspaces.
struct GettingStartedButton: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Quick guide", systemImage: "questionmark.circle") {
            if store.showGettingStarted() { openWindow(id: "getting-started") }
        }.disabled(!store.canNavigateFromGettingStarted)
    }
}
