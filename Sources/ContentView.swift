import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Side { case left, right }

// MARK: - Safe-transfer helpers
//
// A copy must never be able to delete its own source. Comparing destination
// and source by *path strings* is not enough: symlinks, firmlinks, case-
// insensitive volumes and the iCloud/OneDrive path aliases your files live
// behind can all make the same underlying folder look like two different
// paths. `dpIsSameItem` compares by the file system's own identity instead.
fileprivate func dpIsSameItem(_ a: URL, _ b: URL) -> Bool {
    let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    if let ra = (try? a.resourceValues(forKeys: key))?.fileResourceIdentifier,
       let rb = (try? b.resourceValues(forKeys: key))?.fileResourceIdentifier {
        if ra.isEqual(rb) { return true }
    }
    return a.resolvingSymlinksInPath().standardizedFileURL.path
         == b.resolvingSymlinksInPath().standardizedFileURL.path
}

// A transfer that could not be completed safely.
struct TransferError: LocalizedError {
    let message: String
    var isCancellation = false
    var errorDescription: String? { message }
    static let cancelled = TransferError(message: "Cancelled", isCancellation: true)
}

// Shared, thread-safe progress channel for one transfer: carries status text
// back to the status bar and a cancel flag forward into the file operations.
// Copying from iCloud can take minutes (every online-only file is fetched over
// the network), so the user must always be able to see what is happening and
// stop it.
final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastPost = Date.distantPast
    private var lastText = ""
    private let sink: @Sendable (String, Double?) -> Void

    init(sink: @escaping @Sendable (String, Double?) -> Void) { self.sink = sink }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func checkCancelled() throws { if isCancelled { throw TransferError.cancelled } }

    // Rate-limited: a 40,000-file folder must not post 40,000 UI updates.
    // `fraction` drives the progress bar; nil means "no total known yet", which
    // shows the indeterminate spinner instead.
    func post(_ text: String, fraction: Double? = nil, force: Bool = false) {
        lock.lock()
        let now = Date()
        // Also skip repeats: polling a slow download would otherwise post the
        // same line several times a second.
        let due = force || (now.timeIntervalSince(lastPost) > 0.15 && text != lastText)
        if due { lastPost = now; lastText = text }
        lock.unlock()
        if due { sink(text, fraction) }
    }
}

// Human-readable byte count for status messages. Plain numbers only —
// the default formatter renders 0 as "Zero KB".
fileprivate func dpBytes(_ count: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: Int64(count))
}

// Reports every file a copy touches, and lets the user stop it. FileManager
// calls the delegate once per item, which is the only progress signal a
// recursive copyItem gives us.
fileprivate final class DPCopyReporter: NSObject, FileManagerDelegate {
    let progress: TransferProgress
    let name: String
    let expected: Int      // 0 when unknown
    private(set) var copied = 0

    init(progress: TransferProgress, name: String, expected: Int) {
        self.progress = progress
        self.name = name
        self.expected = expected
    }

    private func advance() -> Bool {
        if progress.isCancelled { return false }
        copied += 1
        if expected > 0 {
            progress.post("Copying “\(name)” — \(copied) of \(expected) items…",
                          fraction: min(Double(copied) / Double(expected), 1))
        } else {
            progress.post("Copying “\(name)” — \(copied) items…")
        }
        return true
    }

    func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool {
        advance()
    }
    func fileManager(_ fileManager: FileManager, shouldLinkItemAt srcURL: URL, to dstURL: URL) -> Bool {
        advance()
    }
}

// Reading one byte of an online-only file is what actually makes macOS fetch
// it: `startDownloadingUbiquitousItem` is a no-op for the modern File Provider
// that serves an iCloud Desktop/Documents, so waiting on the download *status*
// waits forever. The read itself is uninterruptible, so it runs on its own
// thread and we wait with a timeout — when iCloud is not delivering, the thread
// stays blocked in the kernel but the app stays responsive and can give up.
fileprivate enum DPFetchOutcome { case ok, failed(Error), timedOut }

fileprivate func dpFetch(_ url: URL, timeout: TimeInterval) -> DPFetchOutcome {
    let box = DPOutcomeBox()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            _ = try handle.read(upToCount: 1)
            try? handle.close()
            box.value = .ok
        } catch {
            box.value = .failed(error)
        }
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut { return .timedOut }
    return box.value
}

fileprivate final class DPOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DPFetchOutcome = .timedOut
    var value: DPFetchOutcome {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// Shared counters for the parallel fetch below.
fileprivate final class DPFetchState: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var _done = 0
    private var _doneBytes = 0
    private var _stopped = false
    private var _blockedOn: URL?
    private var _slow = 0
    private var _lastAdvance = Date()

    func take() -> Int? {
        lock.lock(); defer { lock.unlock() }
        if _stopped { return nil }
        defer { next += 1 }
        return next
    }
    func finished(bytes: Int) {
        lock.lock(); _done += 1; _doneBytes += bytes; _lastAdvance = Date(); lock.unlock()
    }
    func stop(blockedOn url: URL?) {
        lock.lock(); _stopped = true; if _blockedOn == nil { _blockedOn = url }; lock.unlock()
    }
    // A file that did not arrive in time. One slow file must not sink a
    // transfer that is otherwise moving: note it and carry on with the rest.
    func giveUp(on url: URL) {
        lock.lock(); _slow += 1; _blockedOn = url; lock.unlock()
    }
    var snapshot: (done: Int, bytes: Int, slow: Int, stopped: Bool, blockedOn: URL?, idle: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (_done, _doneBytes, _slow, _stopped, _blockedOn, Date().timeIntervalSince(_lastAdvance))
    }
}

// Fetches every online-only file in `pending`, in parallel, reporting progress
// and honouring the Stop button. Split out from dpMaterialize so this logic can
// be tested with a stand-in for `fetch`.
fileprivate func dpFetchAll(_ pending: [URL], sizes: [Int], label name: String, bytes pendingBytes: Int,
                            fm: FileManager, progress: TransferProgress,
                            fileTimeout: TimeInterval, stallTimeout: TimeInterval,
                            fetch: @escaping @Sendable (URL, TimeInterval) -> DPFetchOutcome = dpFetch) throws {
    let total = pending.count
    let totalBytes = dpBytes(pendingBytes)
    progress.post("“\(name)”: \(total) files (\(totalBytes)) are online-only — downloading from iCloud…", force: true)

    // Legacy iCloud Drive still honours this; the File Provider ignores it.
    // Harmless either way, so ask nicely before falling back to reading.
    for u in pending.prefix(500) { try? fm.startDownloadingUbiquitousItem(at: u) }

    // Fetch in parallel — one blocked file must not hold up the rest.
    let state = DPFetchState()
    let workers = min(6, total)
    let group = DispatchGroup()
    for _ in 0..<workers {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            while let i = state.take(), i < total {
                switch fetch(pending[i], fileTimeout) {
                case .ok, .failed:
                    // A file that errors (a broken iCloud entry, say) is not a
                    // stall — let the copy itself report it properly.
                    state.finished(bytes: sizes[i])
                case .timedOut:
                    // macOS keeps fetching this one in the background; move on
                    // to the others rather than stopping everything.
                    state.giveUp(on: pending[i])
                }
            }
        }
    }

    func stalled(_ now: (done: Int, bytes: Int, slow: Int, stopped: Bool, blockedOn: URL?, idle: TimeInterval)) -> TransferError {
        let blocked = now.blockedOn?.lastPathComponent ?? "its files"
        let remaining = total - now.done
        return TransferError(message: """
            “\(name)” was not copied — the original is untouched.

            Still online-only in iCloud: \(remaining) of its \(total) files \
            (\(totalBytes) total). iCloud is not sending them — “\(blocked)” did not answer in time.

            macOS keeps fetching them in the background, so whatever arrives meanwhile \
            makes the next attempt quicker. Open the folder in Finder, let it finish \
            downloading (or right-click it and choose Download Now), then copy again.
            """)
    }

    // Wait on the workers, surfacing progress until they finish, the user stops
    // them, or nothing at all arrives for a while.
    while group.wait(timeout: .now() + 0.2) == .timedOut {
        let now = state.snapshot
        if progress.isCancelled {
            state.stop(blockedOn: nil)
            throw TransferError.cancelled
        }
        // Fail only when the *whole* fetch has gone quiet — individual slow
        // files are tolerated for as long as anything else is still arriving.
        if now.idle > stallTimeout {
            state.stop(blockedOn: nil)
            throw stalled(now)
        }
        let slow = now.slow > 0 ? " (\(now.slow) still waiting on iCloud)" : ""
        let fraction = pendingBytes > 0 ? Double(now.bytes) / Double(pendingBytes)
                                        : Double(now.done) / Double(total)
        progress.post("Downloading “\(name)” from iCloud — \(now.done) of \(total) files (\(dpBytes(now.bytes)) of \(totalBytes))…\(slow)",
                      fraction: min(fraction, 1))
    }
    let outcome = state.snapshot
    // Anything that never arrived means the copy would be incomplete: refuse.
    if outcome.slow > 0 || outcome.done < total { throw stalled(outcome) }
}

// How many items a folder holds, for the copy progress bar. Bounded by a time
// budget: on a huge tree, an exact total is not worth making the user wait for,
// so we fall back to the indeterminate spinner instead.
fileprivate func dpCountItems(_ url: URL, fm: FileManager, budget: TimeInterval = 1.5) -> Int {
    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return 1 }
    guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                options: [.skipsPackageDescendants]) else { return 0 }
    let deadline = Date().addingTimeInterval(budget)
    var count = 1
    for case _ as URL in e {
        count += 1
        if count % 500 == 0 && Date() > deadline { return 0 }
    }
    return count
}

// Online-only iCloud items must be materialized before they're copied,
// otherwise the copy is silently incomplete. Three things matter here:
//
//  * Only `.notDownloaded` items need fetching. `.downloaded` means the real
//    data is already on disk (just possibly not the newest version), and
//    treating that as "needs downloading" made this wait on tens of thousands
//    of files that were already local — the transfer looked frozen forever.
//  * Fetching is done by reading, not by `startDownloadingUbiquitousItem`,
//    which does nothing for File-Provider-backed iCloud folders.
//  * Giving up must *throw*. Falling through would copy 0-byte placeholders,
//    and on a move the source is only removed after this returns, so throwing
//    here is what keeps the original safe.
//
// Returns the number of items in the tree, used as the copy progress total.
@discardableResult
fileprivate func dpMaterialize(_ url: URL, fm: FileManager, progress: TransferProgress,
                               fileTimeout: TimeInterval = 60,
                               stallTimeout: TimeInterval = 120) throws -> Int {
    let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey]

    // Fast path: only iCloud (ubiquitous) items can need materializing, and
    // they only live under ~/Library/Mobile Documents (which is where an
    // iCloud-synced Desktop and Documents live too). For everything else,
    // return immediately — walking every file inside ordinary local folders
    // made plain moves and copies noticeably slow.
    let isUbiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    if !isUbiquitous,
       !url.resolvingSymlinksInPath().path.contains("/Mobile Documents/") {
        return 0
    }

    let name = url.lastPathComponent
    var pending: [URL] = []
    var sizes: [Int] = []
    var pendingBytes = 0
    var scanned = 0

    func consider(_ u: URL) {
        guard let v = try? u.resourceValues(forKeys: keys), v.isUbiquitousItem == true else { return }
        if v.ubiquitousItemDownloadingStatus == .notDownloaded {
            pending.append(u)
            sizes.append(v.fileSize ?? 0)
            pendingBytes += v.fileSize ?? 0
        }
    }

    // Counting first is cheap (well under a second even for 40,000 items) and
    // it turns the slow part — reading each item's iCloud status — into a real
    // progress bar rather than an endless spinner.
    let expected = dpCountItems(url, fm: fm)
    progress.post("Checking “\(name)” for online-only files…", force: true)
    consider(url)
    if let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
        for case let child as URL in e {
            scanned += 1
            if scanned % 200 == 0 {
                try progress.checkCancelled()
                progress.post("Checking “\(name)” for online-only files — \(scanned) of \(expected > 0 ? "\(expected)" : "?") items…",
                              fraction: expected > 0 ? min(Double(scanned) / Double(expected), 1) : nil)
            }
            consider(child)
        }
    }
    let itemCount = scanned + 1
    guard !pending.isEmpty else { return itemCount }

    try dpFetchAll(pending, sizes: sizes, label: name, bytes: pendingBytes, fm: fm,
                   progress: progress, fileTimeout: fileTimeout, stallTimeout: stallTimeout)
    progress.post("Downloaded \(pending.count) files from iCloud.", force: true)
    return itemCount
}

struct ContentView: View {
    @StateObject private var leftTabs = PaneTabsModel(
        initialDirectory: PaneModel.restoredDirectory(
            key: "leftPaneDirectory",
            fallback: FileManager.default.homeDirectoryForCurrentUser),
        persistKey: "leftPane"
    )
    @StateObject private var rightTabs = PaneTabsModel(
        initialDirectory: PaneModel.restoredDirectory(
            key: "rightPaneDirectory",
            fallback: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser),
        persistKey: "rightPane"
    )
    @StateObject private var favorites = FavoritesStore()
    @ObservedObject private var undoStore = UndoStore.shared
    @ObservedObject private var appActions = AppActions.shared
    @FocusState private var filterFocused: Bool
    @State private var activeSide: Side = .left
    @State private var errorMessage: String?
    @State private var newItemPrompt = false
    @State private var newItemName = "New Folder"
    @State private var newItemIsFile = false
    @State private var confirmDelete = false
    @State private var cutURLs = Set<URL>()
    @AppStorage("showTagColors") private var showTagColors = true
    // Left pane's share of the width (0…1), draggable via the transfer strip.
    @AppStorage("paneSplitFraction") private var paneSplitFraction = 0.5
    @State private var liveSplitFraction: Double? // transient value while dragging, to avoid AppStorage churn per-pixel
    @State private var splitDragBase: CGFloat? // left width when a drag began
    @State private var transferring: Side?
    // True for the whole duration of *any* transfer (toolbar, ⌘D/⌘M, paste,
    // drag & drop), not just the centre arrow buttons.
    @State private var transferBusy = false
    @State private var transferStatus: String?
    @State private var transferProgress: TransferProgress?
    @State private var transferFraction: Double?
    @State private var pendingConflict: TransferRequest?
    @Environment(\.openWindow) private var openWindow

    enum ConflictChoice { case replace, keepBoth }

    struct TransferRequest {
        var sources: [URL]
        var destDir: URL
        var move: Bool
        var touchDates = false
        var highlightIn: PaneModel?
        var side: Side?
    }

    private var leftPane: PaneModel { leftTabs.current }
    private var rightPane: PaneModel { rightTabs.current }
    private var active: PaneModel { activeSide == .left ? leftPane : rightPane }
    private var inactive: PaneModel { activeSide == .left ? rightPane : leftPane }
    private func tabs(for side: Side) -> PaneTabsModel { side == .left ? leftTabs : rightTabs }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let available = max(geo.size.width - Self.transferStripWidth, 0)
                let leftWidth = leftPaneWidth(available: available)
                HStack(spacing: 0) {
                PaneView(
                    model: leftPane,
                    tabs: leftTabs,
                    favorites: favorites,
                    paneID: "leftPane",
                    isActive: activeSide == .left,
                    showTagColors: showTagColors,
                    onActivate: { activeSide = .left },
                    onRename: { startRename(in: leftPane) },
                    onCommitRename: { commitRename($0, to: $1) },
                    onDropFiles: { copyDropped($0, into: leftPane) },
                    onDropInto: { dropInto($0, folder: $1, move: $2) },
                    onCopyItems: { copyProviders(from: leftPane, cut: $0) },
                    onPasteItems: { paste($0, into: leftPane) },
                    onDelete: { requestDelete(side: .left) },
                    onNewFolder: { presentNewItem(in: .left, isFile: false) },
                    onNewFile: { presentNewItem(in: .left, isFile: true) }
                )
                .frame(width: leftWidth)
                transferStrip(available: available, leftWidth: leftWidth)
                PaneView(
                    model: rightPane,
                    tabs: rightTabs,
                    favorites: favorites,
                    paneID: "rightPane",
                    isActive: activeSide == .right,
                    showTagColors: showTagColors,
                    onActivate: { activeSide = .right },
                    onRename: { startRename(in: rightPane) },
                    onCommitRename: { commitRename($0, to: $1) },
                    onDropFiles: { copyDropped($0, into: rightPane) },
                    onDropInto: { dropInto($0, folder: $1, move: $2) },
                    onCopyItems: { copyProviders(from: rightPane, cut: $0) },
                    onPasteItems: { paste($0, into: rightPane) },
                    onDelete: { requestDelete(side: .right) },
                    onNewFolder: { presentNewItem(in: .right, isFile: false) },
                    onNewFile: { presentNewItem(in: .right, isFile: true) }
                )
                .frame(maxWidth: .infinity)
                }
            }
            Divider()
            statusBar
        }
        .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Items already exist", isPresented: Binding(
            get: { pendingConflict != nil },
            set: { if !$0 { pendingConflict = nil } }
        )) {
            Button("Keep Both") {
                if let request = pendingConflict { runTransfer(request, choice: .keepBoth) }
                pendingConflict = nil
            }
            Button("Replace", role: .destructive) {
                if let request = pendingConflict { runTransfer(request, choice: .replace) }
                pendingConflict = nil
            }
            Button("Cancel", role: .cancel) { pendingConflict = nil }
        } message: {
            Text("One or more items with the same name already exist in the destination folder.\n\n“Replace” moves the existing items to the Trash. “Keep Both” gives the new copies a numbered name.")
        }
        .alert("Delete \(active.selection.count) item(s)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items will be moved to the Trash.")
        }
        .sheet(isPresented: $newItemPrompt) {
            namePrompt(title: newItemIsFile ? "New File" : "New Folder", text: $newItemName, confirm: "Create") {
                performNewItem()
            }
        }
        .onChange(of: active.selection) { newValue in
            AppActions.shared.selectionCount = newValue.count
        }
        .onChange(of: activeSide) { _ in
            AppActions.shared.selectionCount = active.selection.count
        }
        .onAppear {
            AppActions.shared.deleteRequested = { confirmDelete = true }
            AppActions.shared.selectionCount = active.selection.count
            UndoStore.shared.onDidUndo = {
                leftPane.reload()
                rightPane.reload()
            }
            UndoStore.shared.onError = { errorMessage = $0 }
        }
        // Belt and braces for the directory watchers: network shares and cloud
        // folders don't always deliver kernel events, so re-read both panes
        // whenever the user comes back to the app.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            leftPane.reload()
            rightPane.reload()
        }
        .background {
            Button("") { tabs(for: activeSide).addTab() }
                .keyboardShortcut("t", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            Button("") {
                let model = tabs(for: activeSide)
                model.closeTab(model.selectedIndex)
            }
            .keyboardShortcut("w", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    // MARK: - Toolbar

    // Name filter for the pane you are working in. Each pane keeps its own
    // filter, so the field follows the active pane and shows what that pane is
    // filtered by. ⌘F (View > Filter Files) focuses it.
    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(activeSide == .left ? "Filter left pane" : "Filter right pane",
                      text: Binding(
                          get: { active.searchText },
                          set: { active.searchText = $0 }
                      ))
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($filterFocused)
            .onSubmit { filterFocused = false }
            if !active.searchText.isEmpty {
                Button {
                    active.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor))
                )
        )
        .help("Filter the active pane by name (⌘F)")
        .onChange(of: appActions.focusFilterRequest) { requested in
            guard requested else { return }
            filterFocused = true
            appActions.focusFilterRequest = false
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            toolButton("doc.on.doc", "Copy", help: "Copy selection to other pane (⌘D)") { transfer(move: false) }
                .keyboardShortcut("d")
                .disabled(transferBusy)
            toolButton("arrow.right.doc.on.clipboard", "Move", help: "Move selection to other pane (⌘M)") { transfer(move: true) }
                .keyboardShortcut("m")
                .disabled(transferBusy)
            Divider().frame(height: 22)
            toolButton("folder.badge.plus", "New Folder", help: "Create folder in active pane (⌘N)") {
                presentNewItem(in: activeSide, isFile: false)
            }
            .keyboardShortcut("n")
            toolButton("pencil", "Rename", help: "Rename selected item (⌘R)") {
                startRename(in: active)
            }
            .keyboardShortcut("r")
            .disabled(active.selection.count != 1)
            toolButton("trash", "Delete", help: "Move selection to Trash (⌘⌫)") { confirmDelete = true }
                .disabled(active.selection.isEmpty)
            toolButton("arrow.uturn.backward", "Undo", help: "\(undoStore.undoTitle) (⌘Z)") {
                undoStore.undo()
            }
            .disabled(!undoStore.canUndo)
            toolButton("arrow.uturn.forward", "Redo", help: "\(undoStore.redoTitle) (⇧⌘Z)") {
                undoStore.redo()
            }
            .disabled(!undoStore.canRedo)
            Divider().frame(height: 22)
            toolButton("arrow.left.arrow.right", "Swap", help: "Swap pane directories") { swapPanes() }
            filterField
            Spacer()
            Menu {
                Section("Tag selected items") {
                    ForEach(Self.tagOptions, id: \.number) { option in
                        Button {
                            applyTag(option.number)
                        } label: {
                            Label {
                                Text(option.name)
                            } icon: {
                                Image(nsImage: Self.tagSwatch(option.color))
                            }
                        }
                    }
                    Button {
                        applyTag(0)
                    } label: {
                        Label("None (remove tag)", systemImage: "circle.slash")
                    }
                }
                Divider()
                Toggle("Show Tag Colors", isOn: $showTagColors)
            } label: {
                Label("Tags", systemImage: "tag")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Tag the selected files with a color (like Finder)")
            Toggle(isOn: Binding(
                get: { active.showHidden },
                set: { leftPane.showHidden = $0; rightPane.showHidden = $0 }
            )) {
                Label("Hidden",
                      systemImage: active.showHidden ? "eye.fill" : "eye.slash")
            }
            .toggleStyle(.button)
            .help(active.showHidden
                  ? "Hiding hidden files (dotfiles and system items)"
                  : "Show hidden files (dotfiles and system items)")
            Button {
                openWindow(id: "about")
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("About DualPane — version, changelog, and help")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func toolButton(_ icon: String, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .help(help)
    }

    static let transferStripWidth: CGFloat = 34
    private static let minPaneWidth: CGFloat = 380

    // Left pane width for the current split fraction, keeping both panes at
    // their minimum width whenever the window is wide enough to allow it.
    private func leftPaneWidth(available: CGFloat) -> CGFloat {
        guard available > Self.minPaneWidth * 2 else { return available / 2 }
        let raw = available * CGFloat(liveSplitFraction ?? paneSplitFraction)
        return min(max(raw, Self.minPaneWidth), available - Self.minPaneWidth)
    }

    // The strip between the panes doubles as a splitter: drag it to resize
    // the panes, double-click to reset to 50/50.
    private func transferStrip(available: CGFloat, leftWidth: CGFloat) -> some View {
        VStack(spacing: 14) {
            Spacer()
            transferButton(side: .left, icon: "arrow.right.circle.fill",
                           source: leftPane, dest: rightPane,
                           help: "Copy selected files from left pane to right pane")
            transferButton(side: .right, icon: "arrow.left.circle.fill",
                           source: rightPane, dest: leftPane,
                           help: "Copy selected files from right pane to left pane")
            Spacer()
        }
        .buttonStyle(.borderless)
        .frame(width: Self.transferStripWidth)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let base = splitDragBase ?? leftWidth
                    if splitDragBase == nil { splitDragBase = leftWidth }
                    guard available > 0 else { return }
                    let proposed = base + value.translation.width
                    liveSplitFraction = Double(min(max(proposed / available, 0.1), 0.9))
                }
                .onEnded { _ in
                    if let liveSplitFraction { paneSplitFraction = liveSplitFraction }
                    liveSplitFraction = nil
                    splitDragBase = nil
                }
        )
        .onTapGesture(count: 2) { paneSplitFraction = 0.5 }
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .help("Drag to resize the panes; double-click to reset to 50/50")
    }

    @ViewBuilder
    private func transferButton(side: Side, icon: String, source: PaneModel, dest: PaneModel, help: String) -> some View {
        if transferring == side {
            ProgressView()
                .controlSize(.small)
                .frame(height: 22)
        } else {
            Button {
                copyBetween(from: source, to: dest, side: side)
            } label: {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(source.selection.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)
                    .scaleEffect(source.selection.isEmpty ? 1.0 : 1.08)
                    .animation(.spring(duration: 0.25), value: source.selection.isEmpty)
            }
            .disabled(source.selection.isEmpty || transferring != nil)
            .help(help)
        }
    }

    private var statusBar: some View {
        HStack {
            if transferBusy {
                if let fraction = transferFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 110)
                        .animation(.linear(duration: 0.2), value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                }
                Text(transferStatus ?? "Working…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Button("Stop") { transferProgress?.cancel() }
                    .controlSize(.small)
                    .help("Stop this transfer — anything not yet copied is left alone")
                Spacer()
            } else {
            Text(leftPane.statusText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().frame(height: 14)
            Text(rightPane.statusText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption)
        .animation(.default, value: transferBusy)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func namePrompt(title: String, text: Binding<String>, confirm: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            TextField("Name", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { action() }
            HStack {
                Button("Cancel") {
                    newItemPrompt = false
                }
                .keyboardShortcut(.cancelAction)
                Button(confirm) { action() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    // MARK: - Operations

    private func transfer(move: Bool) {
        let sources = active.selectedItems.map(\.url)
        guard !sources.isEmpty else { return }
        submitTransfer(TransferRequest(sources: sources, destDir: inactive.directory, move: move))
    }

    // Entry point for every copy/move: shows the conflict dialog first if
    // any destination names already exist.
    private func submitTransfer(_ request: TransferRequest) {
        let fm = FileManager.default
        let hasConflict = request.sources.contains {
            fm.fileExists(atPath: request.destDir.appendingPathComponent($0.lastPathComponent).path)
        }
        if hasConflict {
            pendingConflict = request
        } else {
            runTransfer(request, choice: .keepBoth)
        }
    }

    private func runTransfer(_ request: TransferRequest, choice: ConflictChoice) {
        guard !transferBusy else { return }
        if let side = request.side { transferring = side }
        transferBusy = true
        transferStatus = request.move ? "Moving…" : "Copying…"
        let resolveDestination = uniqueDestination
        let total = request.sources.count

        // Progress arrives from the background task, so hop to the main actor
        // to publish it. The same object carries the Cancel button's flag back.
        let progress = TransferProgress { text, fraction in
            Task { @MainActor in
                transferStatus = text
                transferFraction = fraction
            }
        }
        transferProgress = progress

        Task.detached(priority: .userInitiated) {
            // A private FileManager: the copy delegate must not be attached to
            // the shared .default instance the rest of the app uses.
            let fm = FileManager()
            var results: [(src: URL, dst: URL)] = []
            var failures: [String] = []      // every failure, not just the last
            var cancelled = false
            let started = Date()

            for (index, url) in request.sources.enumerated() {
                let name = url.lastPathComponent
                let counter = total > 1 ? " (\(index + 1) of \(total))" : ""
                do {
                    try progress.checkCancelled()

                    // Download online-only iCloud contents first so the copy is
                    // complete. This throws rather than silently proceeding, so a
                    // half-downloaded folder can never be copied as placeholders —
                    // and on a move the source is still intact when it does.
                    let itemCount = try dpMaterialize(url, fm: fm, progress: progress)

                    let reporter = DPCopyReporter(progress: progress, name: name,
                                                  expected: itemCount > 0 ? itemCount
                                                                          : dpCountItems(url, fm: fm))
                    fm.delegate = request.move ? nil : reporter
                    progress.post("\(request.move ? "Moving" : "Copying") “\(name)”…\(counter)", force: true)
                    defer { fm.delegate = nil }

                    // A cancelled copy leaves a half-written destination behind:
                    // remove it, so cancelling never leaves a partial folder that
                    // looks like a finished one.
                    func finish(_ target: URL) throws {
                        if progress.isCancelled {
                            try? fm.removeItem(at: target)
                            throw TransferError.cancelled
                        }
                        if request.touchDates {
                            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                        }
                        results.append((src: url, dst: target))
                    }

                    let plain = request.destDir.appendingPathComponent(url.lastPathComponent)
                    let destExists = fm.fileExists(atPath: plain.path)

                    // Safety guard: if the destination is the *same underlying item*
                    // as the source (even via a symlink / firmlink / iCloud alias),
                    // never replace it — that would trash the source. Copy beside it
                    // with a numbered name; a move onto itself is a no-op.
                    if destExists && dpIsSameItem(url, plain) {
                        if request.move { continue }
                        let target = resolveDestination(url, request.destDir)
                        try fm.copyItem(at: url, to: target)
                        try finish(target)
                        continue
                    }

                    if destExists && choice == .replace {
                        // Replace safely: copy/move into a temporary name FIRST, and
                        // only trash the old item and swap the new one in once that has
                        // fully succeeded. If anything fails, nothing is lost.
                        let temp = resolveDestination(url, request.destDir)
                        if request.move {
                            try fm.moveItem(at: url, to: temp)
                        } else {
                            try fm.copyItem(at: url, to: temp)
                        }
                        if progress.isCancelled {
                            try? fm.removeItem(at: temp)
                            throw TransferError.cancelled
                        }
                        // Never trash something that is actually the source.
                        if !dpIsSameItem(plain, url) {
                            try? fm.trashItem(at: plain, resultingItemURL: nil)
                        }
                        try fm.moveItem(at: temp, to: plain)
                        try finish(plain)
                    } else {
                        // No conflict, or "Keep Both": copy/move to a fresh name.
                        let target = destExists ? resolveDestination(url, request.destDir) : plain
                        if request.move {
                            try fm.moveItem(at: url, to: target)
                        } else {
                            try fm.copyItem(at: url, to: target)
                        }
                        try finish(target)
                    }
                } catch let error as TransferError where error.isCancellation {
                    cancelled = true
                } catch {
                    if progress.isCancelled {
                        cancelled = true
                    } else {
                        failures.append("“\(name)”: \(error.localizedDescription)")
                    }
                }
                if cancelled { break }
            }

            if request.side != nil {
                // Keep the spinner visible long enough to register
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < 0.4 {
                    try? await Task.sleep(nanoseconds: UInt64((0.4 - elapsed) * 1_000_000_000))
                }
            }
            let copied = results
            let wasCancelled = cancelled
            let failureResult = failures.isEmpty ? nil : failures.joined(separator: "\n\n")
            await MainActor.run {
                transferring = nil
                transferBusy = false
                transferStatus = nil
                transferProgress = nil
                transferFraction = nil
                // Cancelling is a choice, not an error — say what survived instead.
                if wasCancelled && failureResult == nil {
                    let kept = copied.count
                    errorMessage = kept == 0
                        ? "Stopped. Nothing was copied."
                        : "Stopped after \(kept) of \(total) item\(total == 1 ? "" : "s")."
                } else {
                    errorMessage = failureResult
                }
                if !copied.isEmpty {
                    UndoStore.shared.record(.transfer(move: request.move, pairs: copied))
                }
                leftPane.reload()
                rightPane.reload()
                request.highlightIn?.selection = Set(copied.map { $0.dst })
            }
        }
    }

    private func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        var dest = directory.appendingPathComponent(source.lastPathComponent)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var counter = 2
        while fm.fileExists(atPath: dest.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            dest = directory.appendingPathComponent(name)
            counter += 1
        }
        return dest
    }

    // Finder label numbers in Finder's menu order
    static let tagOptions: [(name: String, color: NSColor, number: Int)] = [
        ("Red", .systemRed, 6),
        ("Orange", .systemOrange, 7),
        ("Yellow", .systemYellow, 5),
        ("Green", .systemGreen, 2),
        ("Blue", .systemBlue, 4),
        ("Purple", .systemPurple, 3),
        ("Gray", .systemGray, 1),
    ]

    static func tagSwatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func applyTag(_ number: Int) {
        let items = active.selectedItems
        guard !items.isEmpty else { return }
        do {
            for item in items {
                // Write both the modern tag name (what Spotlight/Finder index)
                // and the legacy label number, exactly like Finder does.
                let names: [String] = number == 0 ? [] : [PaneModel.tagNames[number] ?? ""]
                try (item.url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
                var url = item.url
                var values = URLResourceValues()
                values.labelNumber = number
                try url.setResourceValues(values)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        active.reload()
        showTagColors = true
    }

    private func copyBetween(from source: PaneModel, to dest: PaneModel, side: Side) {
        let sources = source.selectedItems.map(\.url)
        guard !sources.isEmpty, !transferBusy else { return }
        submitTransfer(TransferRequest(
            sources: sources, destDir: dest.directory, move: false,
            touchDates: true, highlightIn: dest, side: side))
    }

    private func copyProviders(from pane: PaneModel, cut: Bool) -> [NSItemProvider] {
        let items = pane.selectedItems
        guard !items.isEmpty else { return [] }
        cutURLs = cut ? Set(items.map(\.url)) : []
        return items.map { NSItemProvider(object: $0.url as NSURL) }
    }

    private func paste(_ providers: [NSItemProvider], into pane: PaneModel) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            performPaste(urls, into: pane)
        }
    }

    private func performPaste(_ urls: [URL], into pane: PaneModel) {
        let destDir = pane.directory.standardizedFileURL
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        let isMove = fileURLs.contains { cutURLs.contains($0) }
        var sources = fileURLs
        if isMove {
            // Moving into the folder the file is already in is a no-op
            sources = sources.filter { $0.deletingLastPathComponent().standardizedFileURL.path != destDir.path }
            cutURLs.removeAll()
            guard !sources.isEmpty else { return }
        }
        submitTransfer(TransferRequest(sources: sources, destDir: destDir, move: isMove))
    }

    // Drop onto a folder row: move (same-pane drag) or copy (from the other
    // pane / another app) the items into that folder. The table already
    // pre-filtered impossible targets; re-check here with real file identity.
    private func dropInto(_ urls: [URL], folder: URL, move: Bool) -> Bool {
        let folderPath = folder.standardizedFileURL.path
        let sources = urls.filter(\.isFileURL).filter { url in
            !dpIsSameItem(url, folder)
                && !folderPath.hasPrefix(url.standardizedFileURL.path + "/")
                && url.deletingLastPathComponent().standardizedFileURL.path != folderPath
        }
        guard !sources.isEmpty else { return false }
        submitTransfer(TransferRequest(sources: sources, destDir: folder, move: move))
        return true
    }

    private func copyDropped(_ urls: [URL], into pane: PaneModel) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
            .filter { $0.deletingLastPathComponent().standardizedFileURL.path != pane.directory.standardizedFileURL.path }
        guard !fileURLs.isEmpty else { return false }
        submitTransfer(TransferRequest(sources: fileURLs, destDir: pane.directory, move: false))
        return true
    }

    // Context-menu delete: make the pane active first so the confirmation
    // alert counts and deletes the right pane's selection.
    private func requestDelete(side: Side) {
        activeSide = side
        guard !active.selection.isEmpty else { return }
        confirmDelete = true
    }

    private func deleteSelection() {
        let fm = FileManager.default
        var trashed: [(original: URL, trash: URL)] = []
        do {
            for item in active.selectedItems {
                var result: NSURL?
                try fm.trashItem(at: item.url, resultingItemURL: &result)
                if let trashURL = result as URL? {
                    trashed.append((original: item.url, trash: trashURL))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        if !trashed.isEmpty {
            UndoStore.shared.record(.trash(pairs: trashed))
        }
        leftPane.reload()
        rightPane.reload()
    }

    // Asks the pane's table to begin in-cell editing of the selected row.
    private func startRename(in pane: PaneModel) {
        guard let item = pane.selectedItems.first else { return }
        pane.renameRequest = item.url
    }

    // Called by the table when in-cell editing commits with a new name.
    private func commitRename(_ url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            UndoStore.shared.record(.rename(from: url, to: dest))
        } catch {
            errorMessage = error.localizedDescription
        }
        leftPane.reload()
        rightPane.reload()
    }

    private func presentNewItem(in side: Side, isFile: Bool) {
        activeSide = side
        newItemIsFile = isFile
        newItemName = isFile ? "New File.txt" : "New Folder"
        newItemPrompt = true
    }

    private func performNewItem() {
        defer { newItemPrompt = false }
        let trimmed = newItemName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let dest = active.directory.appendingPathComponent(trimmed)
        var created = false
        do {
            if newItemIsFile {
                guard !FileManager.default.fileExists(atPath: dest.path) else {
                    errorMessage = "An item named “\(trimmed)” already exists."
                    return
                }
                guard FileManager.default.createFile(atPath: dest.path, contents: Data()) else {
                    errorMessage = "Couldn’t create the file."
                    return
                }
                UndoStore.shared.record(.create(dest))
                created = true
            } else {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
                UndoStore.shared.record(.create(dest))
                created = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        active.reload()
        guard created else { return }
        // New items can sort anywhere in a long list; scroll to the new item
        // and select it. The name came from the dialog, so don't re-open
        // in-cell editing on top of it. Look up the freshly-reloaded item's
        // own URL rather than reusing `dest` — a constructed URL can fail
        // `==` against the one FileManager's directory enumeration hands back
        // for the same path.
        guard let createdItem = active.items.first(where: { $0.url.path == dest.path }) else { return }
        active.selection = [createdItem.url]
        active.revealRequest = createdItem.url
    }

    private func swapPanes() {
        let leftDir = leftPane.directory
        leftPane.navigate(to: rightPane.directory)
        rightPane.navigate(to: leftDir)
    }
}

// MARK: - Pane

private struct TabsContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct TabsContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PaneView: View {
    @ObservedObject var model: PaneModel
    @ObservedObject var tabs: PaneTabsModel
    @ObservedObject var favorites: FavoritesStore
    /// Stable identifier ("leftPane"/"rightPane") for remembering column layout.
    let paneID: String
    let isActive: Bool
    let showTagColors: Bool
    let onActivate: () -> Void
    let onRename: () -> Void
    let onCommitRename: (URL, String) -> Void
    let onDropFiles: ([URL]) -> Bool
    let onDropInto: ([URL], URL, Bool) -> Bool
    let onCopyItems: (Bool) -> [NSItemProvider]
    let onPasteItems: ([NSItemProvider]) -> Void
    let onDelete: () -> Void
    let onNewFolder: () -> Void
    let onNewFile: () -> Void

    @State private var tabScrollCursor = 0
    @State private var tabsContentWidth: CGFloat = 0
    @State private var tabsContainerWidth: CGFloat = 0
    private var tabsOverflow: Bool { tabsContentWidth > tabsContainerWidth + 1 }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            pathBar
            Divider()
            FileTableView(
                model: model,
                showTagColors: showTagColors,
                autosaveName: paneID,
                onActivate: onActivate,
                onCopy: { writeToPasteboard(cut: false) },
                onCut: { writeToPasteboard(cut: true) },
                onPaste: { pasteFromPasteboard() },
                onRename: onRename,
                onCommitRename: onCommitRename,
                onDelete: onDelete,
                onDrop: onDropFiles,
                onDropInto: onDropInto,
                onNewFolder: onNewFolder,
                onNewFile: onNewFile
            )
            .overlay {
                if let error = model.loadError {
                    loadErrorBanner(error)
                }
            }
        }
        .frame(minWidth: 380)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private func loadErrorBanner(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.icloud")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Couldn’t read this folder")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("iCloud Drive and OneDrive live under ~/Library and are protected by macOS. Grant DualPane access in System Settings → Privacy & Security → Full Disk Access, then click Refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Full Disk Access Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(28)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var filterTint: Color {
        guard let filter = model.tagFilter,
              let option = ContentView.tagOptions.first(where: { $0.number == filter }) else {
            return .secondary
        }
        return Color(nsColor: option.color)
    }

    // Standard + cloud locations that exist on this Mac. iCloud Drive and the
    // CloudStorage providers (OneDrive, Dropbox, …) live under the hidden
    // ~/Library, so this menu is the easy way to reach them.
    static func locations() -> [(name: String, icon: String, url: URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var result: [(String, String, URL)] = []

        func add(_ name: String, _ icon: String, _ url: URL) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                result.append((name, icon, url))
            }
        }

        add("Desktop", "menubar.dock.rectangle", home.appendingPathComponent("Desktop"))
        add("Documents", "doc", home.appendingPathComponent("Documents"))
        add("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads"))
        // Shown unconditionally: the existence check is itself blocked by macOS
        // until Full Disk Access is granted, which would otherwise hide iCloud.
        result.append(("iCloud Drive", "icloud",
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")))

        // Each subfolder of CloudStorage is a provider like "OneDrive-Personal".
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let providers = try? fm.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) {
            for provider in providers.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                add(provider.lastPathComponent, "externaldrive.badge.icloud", provider)
            }
        }
        return result.map { (name: $0.0, icon: $0.1, url: $0.2) }
    }

    private func writeToPasteboard(cut: Bool) {
        let providers = onCopyItems(cut)
        guard !providers.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(model.selectedItems.map { $0.url as NSURL })
    }

    private func pasteFromPasteboard() {
        guard let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil),
              !objects.isEmpty else { return }
        let providers = objects.compactMap { ($0 as? NSURL).map { NSItemProvider(object: $0) } }
        onPasteItems(providers)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            // Slide horizontally through all tabs; the selected tab is always
            // scrolled into view when tabs are switched, opened, or closed.
            // When the strip overflows its width, chevrons appear so tabs can
            // be stepped through without a trackpad's horizontal swipe.
            ScrollViewReader { proxy in
                HStack(spacing: 2) {
                    if tabsOverflow {
                        Button {
                            stepTabScroll(-1, proxy)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .help("Scroll tabs left")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                                tabChip(tab: tab, index: index)
                                    .id(tab.id)
                            }
                        }
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: TabsContentWidthKey.self, value: geo.size.width)
                        })
                    }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: TabsContainerWidthKey.self, value: geo.size.width)
                    })
                    .onPreferenceChange(TabsContentWidthKey.self) { tabsContentWidth = $0 }
                    .onPreferenceChange(TabsContainerWidthKey.self) { tabsContainerWidth = $0 }
                    if tabsOverflow {
                        Button {
                            stepTabScroll(1, proxy)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .help("Scroll tabs right")
                    }
                }
                .onChange(of: tabs.selectedIndex) { _ in
                    tabScrollCursor = tabs.selectedIndex
                    scrollToSelected(proxy)
                }
                .onChange(of: tabs.tabs.count) { _ in scrollToSelected(proxy) }
            }
            Button {
                onActivate()
                tabs.addTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .help("New Tab (⌘T)")
            Spacer(minLength: 8)
            Button {
                onActivate()
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .help("Refresh this tab")
            Button {
                onActivate()
                onNewFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .help("New Folder in this tab")
            Button {
                onActivate()
                onNewFile()
            } label: {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .help("New File in this tab")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isActive ? Color.accentColor.opacity(0.05) : Color.clear)
    }

    private func stepTabScroll(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard !tabs.tabs.isEmpty else { return }
        tabScrollCursor = max(0, min(tabs.tabs.count - 1, tabScrollCursor + delta))
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(tabs.tabs[tabScrollCursor].id, anchor: delta < 0 ? .leading : .trailing)
        }
    }

    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        guard tabs.tabs.indices.contains(tabs.selectedIndex) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(tabs.tabs[tabs.selectedIndex].id, anchor: nil)
        }
    }

    private func tabChip(tab: PaneModel, index: Int) -> some View {
        let isSelected = index == tabs.selectedIndex
        return HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
            // Long names truncate so many tabs stay visible; full path in tooltip
            Text(tab.directory.lastPathComponent.isEmpty ? "/" : tab.directory.lastPathComponent)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tabs.tabs.count > 1 {
                Button {
                    tabs.closeTab(index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 90, maxWidth: 160)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onActivate()
            tabs.select(index)
        }
        .help(tab.directory.path)
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .help("Back")
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .help("Up one level")
            Button { model.navigate(to: FileManager.default.homeDirectoryForCurrentUser) } label: {
                Image(systemName: "house")
            }
            .help("Home")
            Menu {
                ForEach(Self.locations(), id: \.url) { location in
                    Button {
                        model.navigate(to: location.url)
                    } label: {
                        Label(location.name, systemImage: location.icon)
                    }
                }
                Divider()
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Grant Full Disk Access…", systemImage: "lock.open")
                }
            } label: {
                Image(systemName: "cloud")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Jump to iCloud Drive, OneDrive, and other locations")
            Menu {
                if favorites.folders.isEmpty {
                    Text("No favorites yet — click ★ to add the current folder")
                }
                ForEach(favorites.folders, id: \.self) { url in
                    Button {
                        model.navigate(to: url)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "folder")
                    }
                }
                if !favorites.folders.isEmpty {
                    Divider()
                    Menu("Remove Favorite") {
                        ForEach(favorites.folders, id: \.self) { url in
                            Button(url.lastPathComponent) { favorites.remove(url) }
                        }
                    }
                }
            } label: {
                Image(systemName: "bookmark")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Go to a favorite folder")
            Button {
                favorites.toggle(model.directory)
            } label: {
                Image(systemName: favorites.contains(model.directory) ? "star.fill" : "star")
                    .foregroundStyle(favorites.contains(model.directory) ? .yellow : .secondary)
            }
            .help(favorites.contains(model.directory) ? "Remove this folder from favorites" : "Add this folder to favorites")
            Menu {
                Picker("Filter by tag", selection: $model.tagFilter) {
                    Label("All Items", systemImage: "circle.grid.2x2")
                        .tag(Int?.none)
                    ForEach(ContentView.tagOptions, id: \.number) { option in
                        Label {
                            Text(option.name)
                        } icon: {
                            Image(nsImage: ContentView.tagSwatch(option.color))
                        }
                        .tag(Int?.some(option.number))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: model.tagFilter == nil
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(filterTint)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show all items with this tag color from your whole Home folder")
            TextField("Path", text: $model.pathText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit { model.submitPath() }
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}
