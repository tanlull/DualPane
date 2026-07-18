import SwiftUI
import AppKit

enum AppInfo {
    static let name = "DualPane"
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7"
    static let author = "Tanya S. (tanlull)"
    static let repoURL = URL(string: "https://github.com/tanlull/DualPane")!

    struct Release {
        let version: String
        let date: String
        let changes: [String]
    }

    static let changelog: [Release] = [
        Release(version: "2.7", date: "18 Jul 2026", changes: [
            "Each pane now refreshes itself when files change on disk — save a file in another app, unzip something in Terminal, or copy into a folder from the other pane, and the list updates on its own instead of waiting for a manual refresh",
            "Both panes also re-read their folders when you switch back to DualPane, which covers network shares and cloud folders that don't always announce changes",
            "Auto-refresh stays out of the way: it holds off while you are renaming a file in place, and leaves the list untouched when nothing has actually changed, so your scroll position and selection survive",
        ]),
        Release(version: "2.6", date: "14 Jul 2026", changes: [
            "New File/New Folder now scrolls the new item into view and offers to rename it right away — previously it was created correctly but could land far down an alphabetically-sorted list, off-screen, making it look like nothing happened",
        ]),
        Release(version: "2.5", date: "14 Jul 2026", changes: [
            "Fixed janky, stuttery pane resizing — dragging the splitter no longer writes to disk on every pixel of movement, so it now tracks the mouse smoothly",
        ]),
        Release(version: "2.4", date: "14 Jul 2026", changes: [
            "Adjustable pane split: drag the strip between the panes to resize them (double-click it to reset to 50/50) — the split is remembered across launches",
            "Column widths can be resized by dragging the dividers between column headers, remembered separately for each pane",
            "Right-click (or Control-click) a column header to show or hide the Size and Modified columns per pane",
        ]),
        Release(version: "2.3", date: "8 Jul 2026", changes: [
            "Right-click menu and delete confirmation now say \"Delete\" instead of \"Move to Trash\" — the action still moves items to the Trash, just a shorter label",
        ]),
        Release(version: "2.2", date: "8 Jul 2026", changes: [
            "Tab bar now shows left/right arrow buttons when there are too many tabs to fit, so you can step through them without a trackpad's horizontal swipe",
        ]),
        Release(version: "2.1", date: "8 Jul 2026", changes: [
            "Move to Trash added to the right-click menu",
            "File moves and copies are much faster: the iCloud download check no longer scans every file inside local folders, and dragging over the list no longer re-reads the dragged items on every mouse move",
            "Better tab bar: tabs have a tidy uniform width with long names truncated, the bar slides horizontally when there are many tabs, and the selected tab always scrolls into view — click a tab to switch, click ✕ to close",
        ]),
        Release(version: "2.0", date: "2 Jul 2026", changes: [
            "iCloud Drive now shows app folders (Obsidian, Numbers, Keynote, Pages, …) like Finder does — they are separate app containers that live outside the iCloud Drive folder, and are now merged into the view with their proper names",
        ]),
        Release(version: "1.9", date: "2 Jul 2026", changes: [
            "iCloud Drive now shows the Desktop and Documents folders (macOS stores them as hidden symlinks; they are shown like Finder does and open as folders)",
        ]),
        Release(version: "1.8", date: "2 Jul 2026", changes: [
            "Undo (⌘Z, also in the toolbar and Edit menu) for file operations: move, copy, rename, delete, and new file/folder — deletes are restored from the Trash, and undo never overwrites existing items",
            "New Folder and New File added to the right-click menu",
            "Drag & drop within the same pane: drop files or folders onto a folder row to move them into it (dropping from the other pane or another app copies them in)",
        ]),
        Release(version: "1.7", date: "30 Jun 2026", changes: [
            "Fixed a serious data-loss bug where copying a folder between panes could send the original to the Trash — copies now compare source and destination by real file identity (not path text), so iCloud/OneDrive path aliases, symlinks and firmlinks can never make a copy delete its own source",
            "Replace-on-conflict is now safe: the new item is copied in fully before the old one is moved to the Trash, so a failed copy never loses data",
            "Online-only iCloud items are downloaded before copying, so copies are complete instead of empty placeholders",
            "iCloud/OneDrive access now sticks: the app is signed with a stable identity (build-app.sh) instead of ad-hoc, so the Full Disk Access grant no longer breaks on every rebuild",
        ]),
        Release(version: "1.6", date: "27 Jun 2026", changes: [
            "Multiple tabs per pane: open, switch, and close tabs independently in each pane (⌘T new tab, ⌘W close tab)",
            "Each pane's tab bar has its own Refresh, New Folder, and New File buttons that act on that tab",
            "Tabs and the active tab are remembered per pane across launches",
        ]),
        Release(version: "1.5", date: "23 Jun 2026", changes: [
            "Inline rename: rename in place by typing in the cell (Return to commit, Esc to cancel) — no more dialog",
            "Open in Terminal added to the right-click menu",
            "Locations menu (☁️) for quick access to iCloud Drive, OneDrive and other CloudStorage providers, Desktop, Documents and Downloads",
            "Folders no longer pinned to the top when sorting by Size or Date — the real order is shown",
            "Clearer error when a folder can't be read (iCloud/OneDrive need Full Disk Access), with a button to open the setting",
            "Cloud folders open inside DualPane instead of bouncing to Finder",
        ]),
        Release(version: "1.4", date: "12 Jun 2026", changes: [
            "Copy conflict dialog: when a file already exists at the destination, choose Replace (old file goes to Trash), Keep Both (numbered name), or Cancel — applies to toolbar copy/move, transfer arrows, drag & drop, and paste",
            "Rename… and Refresh added to the right-click menu",
        ]),
        Release(version: "1.3", date: "12 Jun 2026", changes: [
            "Tag colors now come from the real Finder tag names, so the display always matches the tag filter results",
            "Items with multiple tags show stacked color dots like Finder; folders tint with the first tag and show extra tags as dots",
        ]),
        Release(version: "1.2", date: "12 Jun 2026", changes: [
            "Remembers the last folder of each pane and reopens there on next launch",
            "About / Help / changelog added to the macOS menu bar (About DualPane, Help ⌘?)",
        ]),
        Release(version: "1.1", date: "12 Jun 2026", changes: [
            "Finder tag support: tag files/folders with colors from the Tags menu, just like Finder",
            "Tagged folders show tinted folder icons; tagged files show a color dot",
            "Tag filter in each pane searches your whole Home folder via Spotlight",
            "Transfer arrows (→ / ←) between panes with progress spinner; copied files are highlighted and bumped to top when sorted by date",
            "Favorites: bookmark folders with ★ and jump to them from the 🔖 menu",
            "Faster clicking and folder loading (native table, icon caching)",
            "Version, Help / About page with changelog",
        ]),
        Release(version: "1.0", date: "12 Jun 2026", changes: [
            "First release: two-pane file manager with native macOS look",
            "Copy / Move between panes (⌘D / ⌘M)",
            "Drag & drop between panes and with Finder",
            "System clipboard: ⌘C copy, ⌘X cut, ⌘V paste",
            "New Folder, Rename, Delete to Trash",
            "Sortable columns, hidden files toggle, editable path bar",
        ]),
    ]
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(AppInfo.name) \(AppInfo.version)")
                        .font(.title2.bold())
                    Text("A simple two-pane file manager for macOS")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("By \(AppInfo.author)")
                            .foregroundStyle(.secondary)
                        Link("GitHub", destination: AppInfo.repoURL)
                    }
                    .font(.callout)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("What's New")
                        .font(.headline)
                    ForEach(AppInfo.changelog, id: \.version) { release in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Version \(release.version)")
                                    .font(.subheadline.bold())
                                Text(release.date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(release.changes, id: \.self) { change in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                    Text(change)
                                }
                                .font(.callout)
                                .foregroundStyle(.primary.opacity(0.85))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack {
                Text("Built with Swift, SwiftUI & AppKit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 460, height: 480)
    }
}
