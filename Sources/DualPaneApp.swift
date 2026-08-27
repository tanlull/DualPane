import SwiftUI
import AppKit

@main
struct DualPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("\(AppInfo.name) \(AppInfo.version)") {
            ContentView()
                .frame(minWidth: 960, minHeight: 540)
        }
        .commands {
            AppCommands()
        }

        Window("About \(AppInfo.name)", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var undoStore = UndoStore.shared
    @ObservedObject private var actions = AppActions.shared

    var body: some Commands {
        // File-operation undo (⌘Z): replaces the default text-undo menu item so
        // the shortcut reaches UndoStore instead of an empty NSUndoManager.
        CommandGroup(replacing: .undoRedo) {
            Button(undoStore.undoTitle) {
                undoStore.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!undoStore.canUndo)
            Button(undoStore.redoTitle) {
                undoStore.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!undoStore.canRedo)
        }
        // File > Move to Trash (⌘⌫), same shortcut as Finder.
        CommandGroup(after: .newItem) {
            Divider()
            Button("Move to Trash") {
                actions.deleteRequested?()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!actions.canDelete)
        }
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppInfo.name)") {
                openWindow(id: "about")
            }
        }
        CommandGroup(replacing: .help) {
            Button("\(AppInfo.name) Help") {
                openWindow(id: "about")
            }
            .keyboardShortcut("?", modifiers: .command)
            Button("What's New (Changelog)") {
                openWindow(id: "about")
            }
            Divider()
            Button("\(AppInfo.name) on GitHub") {
                NSWorkspace.shared.open(AppInfo.repoURL)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Debug helper: DUALPANE_SNAPSHOT=/path.png renders the window to a PNG.
        if let path = ProcessInfo.processInfo.environment["DUALPANE_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let window = NSApp.windows.first(where: { $0.isVisible }),
                      let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
