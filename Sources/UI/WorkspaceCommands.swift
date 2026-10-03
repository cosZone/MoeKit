import SwiftUI

/// The Find command follows the active workspace window, never a hidden control.
struct WorkspaceSearchAction {
    let isEnabled: Bool
    let focus: @MainActor () -> Void
}

private struct WorkspaceSearchActionKey: FocusedValueKey {
    typealias Value = WorkspaceSearchAction
}

extension FocusedValues {
    var workspaceSearchAction: WorkspaceSearchAction? {
        get { self[WorkspaceSearchActionKey.self] }
        set { self[WorkspaceSearchActionKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceSearchAction) private var searchAction

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search workspace") { searchAction?.focus() }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(searchAction?.isEnabled != true)
        }
    }
}
