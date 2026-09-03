import SwiftUI

// Bridge between the main menu (AppCommands) and ContentView's state.
//
// SwiftUI `.keyboardShortcut` attached to a toolbar button inside the window
// is unreliable once the AppKit table view is first responder — the table's
// responder chain swallows the key before the button's key equivalent runs.
// Menu commands go through the main menu instead, which always gets first
// crack at key equivalents, so window-level shortcuts (⌘⌫, ⌘Z, ⇧⌘Z) live
// here. ContentView installs the handlers in `onAppear` and keeps the
// enabled flags in sync.
@MainActor
final class AppActions: ObservableObject {
    static let shared = AppActions()

    /// Number of items selected in the active pane; drives the menu title and
    /// whether "Move to Trash" is enabled.
    @Published var selectionCount = 0

    var canDelete: Bool { selectionCount > 0 }

    /// Asks ContentView to present the delete confirmation.
    var deleteRequested: (() -> Void)?

    /// Asks ContentView to focus the active pane's search filter (⌘F).
    var findRequested: (() -> Void)?
}
