import SwiftUI
import AppKit

enum AppInfo {
    static let name = "DualPane"
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.21"
    static let author = "Tanya S. (tanlull)"
    static let repoURL = URL(string: "https://github.com/tanlull/DualPane")!

    struct Release {
        let version: String
        let date: String
        let changes: [String]
    }

    static let changelog: [Release] = [
        Release(version: "3.21", date: "5 Sep 2026", changes: [
            "Files in OneDrive, iCloud Drive and other cloud folders now show their status next to the name: a green check when the file is stored on this Mac, a cloud with an arrow when it is still online-only",
            "The badge updates after Keep on This Device (Download Now) finishes",
        ]),
        Release(version: "3.20", date: "5 Sep 2026", changes: [
            "New right-click item for files in OneDrive, iCloud Drive, Dropbox and other cloud folders: Keep on This Device (Download Now) fetches online-only items, including everything inside a folder",
            "Opening an online-only cloud file now downloads it first, instead of handing an empty placeholder to the app",
        ]),
        Release(version: "3.19", date: "5 Sep 2026", changes: [
            "The hover label that shows a name too long for the column is now a couple of points larger and a little roomier, so the full name is easier to read",
        ]),
        Release(version: "3.18", date: "5 Sep 2026", changes: [
            "After renaming, a long name goes back to being cut off with an ellipsis on one line instead of wrapping onto a second line inside the row",
        ]),
        Release(version: "3.17", date: "5 Sep 2026", changes: [
            "While renaming, a name longer than the edit box now scrolls along with the cursor, so you can drag or arrow your way to the end of it",
        ]),
        Release(version: "3.16", date: "5 Sep 2026", changes: [
            "Fixed renaming long names: the hover label that shows a name too long for the column was sitting on top of the edit box and eating the click, so text could not be selected — and the drag turned into a file drag whose path was dropped into the name",
            "Files can no longer be dropped into the name while you are renaming",
            "A name containing / or : is now refused with a clear message instead of failing as a move to a folder that does not exist",
        ]),
        Release(version: "3.15", date: "5 Sep 2026", changes: [
            "Renaming is much easier to edit in: the name now becomes a real, visible text box that fills the Name column, so you can press and drag anywhere in it to select part of the name",
            "A drag that starts near the name while renaming no longer begins a file drag and cancels the rename",
            "Right-click a tab for a small menu: go to the same folder as the other pane, jump to a tag colour, or add the tab's folder to favourites",
        ]),
        Release(version: "3.14", date: "4 Sep 2026", changes: [
            "Hovering a file whose name is too long for the Name column now shows the full name straight away, continuing on the same line past the column edge; names that already fit are left alone",
        ]),
        Release(version: "3.13", date: "4 Sep 2026", changes: [
            "“Get Info” moved to the bottom of the right-click menu, so the items you use most stay at the top",
        ]),
        Release(version: "3.12", date: "4 Sep 2026", changes: [
            "Folders now show their real size in the Size column instead of a dash — measured in the background, so the pane stays responsive and sizes fill in as they are worked out",
            "Sizes are remembered, so going back to a folder shows them instantly; they are re-measured when the folder changes",
            "Turn it off with “Calculate Folder Sizes” in the menu you get by right-clicking a column header",
            "New “Get Info” in the right-click menu (and ⌘I): kind, full path, size in bytes, what a folder contains, created and modified dates, tags, and permissions",
        ]),
        Release(version: "3.11", date: "4 Sep 2026", changes: [
            "Copying and moving now show a proper progress dialog — what is being copied, where to, a progress bar with a percentage, and a Stop button — instead of only a line in the status bar",
            "The dialog waits half a second before appearing, so quick copies still finish without a window flashing on screen",
            "Esc stops the transfer; the status bar keeps showing progress as well",
        ]),
        Release(version: "3.10", date: "4 Sep 2026", changes: [
            "Transfers now show a real progress bar with a percentage, not just a spinner: it fills as the folder is checked, as online-only files come down from iCloud, and as files are copied",
            "The iCloud download bar tracks megabytes, so it moves at the speed the data actually arrives",
            "The spinner is still used for the few cases where no total is known yet",
        ]),
        Release(version: "3.9", date: "4 Sep 2026", changes: [
            "One slow file from iCloud no longer cancels the whole copy: DualPane keeps fetching everything else and only gives up when nothing at all has arrived for two minutes",
            "The status line now says how many files are still waiting on iCloud while the rest come down",
            "If it does give up, the message explains that macOS keeps downloading in the background, so trying again later gets further",
        ]),
        Release(version: "3.8", date: "4 Sep 2026", changes: [
            "Copying a folder from an iCloud Desktop no longer freezes at “Copying…” forever: DualPane now shows what it is doing at every step — checking the folder, downloading each online-only file, then copying — and a Stop button cancels at any point",
            "When iCloud will not hand over online-only files, the copy now stops with a plain explanation (how many files, how big, which one is stuck) instead of hanging, and your original is left untouched",
            "Files that iCloud already has on disk are no longer treated as needing a download — that alone was making DualPane wait on tens of thousands of files that were already there",
            "Online-only files are now fetched by reading them, several at a time, which is what actually makes macOS download them",
        ]),
        Release(version: "3.7", date: "4 Sep 2026", changes: [
            "Copy and Move (and paste, and drag & drop) now show a progress spinner and what they are working on in the status bar — before, only the ← / → arrow buttons did",
            "Copying from an iCloud folder (Desktop and Documents are iCloud folders) no longer copies half-empty placeholder files when a download does not finish in time: the transfer stops and tells you what is still downloading, leaving the original untouched",
            "iCloud downloads now get 10 minutes instead of 1 before giving up, and show which file they are waiting for",
            "When several items fail, the error now lists all of them instead of just the last one",
        ]),
        Release(version: "3.6", date: "3 Sep 2026", changes: [
            "The toolbar filter now applies to the pane you are working in, not both at once",
            "Each pane remembers its own filter: click the other pane and the box shows that pane's filter",
        ]),
        Release(version: "3.5", date: "3 Sep 2026", changes: [
            "The name filter now lives in the main toolbar next to Swap, and filters both panes at once instead of one",
            "It stays on as you move between folders — click the × (or empty the box) to see everything again",
        ]),
        Release(version: "3.4", date: "3 Sep 2026", changes: [
            "Each pane now has its own search box — type to filter the current folder by name as you go",
            "⌘F jumps straight to the filter box of the pane you are working in; the × button clears it",
            "The filter clears itself when you open another folder, and the status line shows how many of the folder's items match",
        ]),
        Release(version: "3.3", date: "29 Aug 2026", changes: [
            "Dragging several selected files onto a folder now moves all of them — the list could collapse to just one file mid-drag, so only that one arrived",
        ]),
        Release(version: "3.2", date: "29 Aug 2026", changes: [
            "Rename like Finder: click a file or folder that is already selected, pause, and its name becomes editable in place",
            "Renaming now pre-selects just the name and leaves the extension alone, so typing replaces “report” in “report.pdf” without touching “.pdf”",
            "Moved Delete to the bottom of the right-click menu, just above Refresh, so it is not next to Rename…",
        ]),
        Release(version: "3.1", date: "27 Aug 2026", changes: [
            "Fixed the real reason ⌘⌫, Rename, Copy and Move often did nothing: the toolbar and menu were not being told when your selection changed, so the commands stayed greyed out even with a file clearly highlighted",
            "Clicking a file name now always selects the row — the name field no longer swallows the click and starts renaming by accident (renaming still works from the toolbar, the menu and the right-click menu)",
            "Files changed today show just the time in the Modified column, like Finder; older items keep the full date",
        ]),
        Release(version: "3.0", date: "27 Aug 2026", changes: [
            "⌘⌫ (Delete) now really works: it moved to the File menu as “Move to Trash”, so the shortcut is caught by the menu bar instead of being swallowed by the file list",
            "Undo (⌘Z) and Redo (⇧⌘Z) now live in the Edit menu together, so both shortcuts work no matter which pane has focus",
        ]),
        Release(version: "2.9", date: "27 Aug 2026", changes: [
            "Undo now has its Finder keyboard shortcut: press ⌘Z to take back the last copy, move, rename, delete or new item",
            "Added Redo (⇧⌘Z, and a new toolbar button) to put back whatever you just undid",
            "Delete keeps its Finder shortcut, ⌘⌫, for moving the selection to the Trash",
            "After naming a new file or folder in the dialog, the name is no longer opened for editing a second time — the item is just created, selected and scrolled into view",
        ]),
        Release(version: "2.8", date: "27 Aug 2026", changes: [
            "The Hidden button in the toolbar now remembers your choice across launches — it still starts off (hidden files stay out of sight) until you turn it on",
            "The button's icon now shows the current state at a glance: a crossed-out eye when hidden files are hidden, a filled eye when they are shown",
        ]),
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
