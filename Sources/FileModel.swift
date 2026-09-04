import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

// Caches icons by file type instead of asking NSWorkspace per file —
// icon(forFile:) is the slowest part of listing a directory.
@MainActor
enum IconProvider {
    private static var cache: [String: NSImage] = [:]
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let genericIcon = NSWorkspace.shared.icon(for: .data)

    static func icon(for url: URL, isDirectory: Bool, tintColor: NSColor? = nil, tintKey: String = "") -> NSImage {
        let ext = url.pathExtension.lowercased()
        if isDirectory {
            // Apps and bundles have unique icons worth the per-file cost
            if ext == "app" { return NSWorkspace.shared.icon(forFile: url.path) }
            // Tagged folders are tinted with their first Finder tag color
            if let color = tintColor {
                let key = "folder-tint-\(tintKey)"
                if let cached = cache[key] { return cached }
                let tinted = tintedFolder(color)
                cache[key] = tinted
                return tinted
            }
            return folderIcon
        }
        if ext.isEmpty { return genericIcon }
        if let cached = cache[ext] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = icon
        return icon
    }

    private static func tintedFolder(_ color: NSColor) -> NSImage {
        let base = folderIcon
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            base.draw(in: rect)
            color.withAlphaComponent(0.72).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

// Folder sizes are not something the file system knows: they have to be
// measured by walking the tree. That is fast (36,000 files in ~0.7s) but not
// free, so results are cached per folder and only recomputed when the folder
// itself changes. Measuring happens on a serial background queue so a pane
// full of folders streams its sizes in rather than stalling the UI.
@MainActor
final class FolderSizeCache {
    static let shared = FolderSizeCache()

    private struct Entry { let size: Int64; let measured: Date }
    private var entries: [String: Entry] = [:]
    private var waiting: [String: [(Int64) -> Void]] = [:]
    private let queue = DispatchQueue(label: "dualpane.folder-size", qos: .utility)

    /// A previously measured size, if the folder has not been touched since.
    func cached(_ url: URL) -> Int64? {
        guard let entry = entries[url.path] else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let modified, modified > entry.measured { return nil }
        return entry.size
    }

    func measure(_ url: URL, completion: @escaping (Int64) -> Void) {
        if let size = cached(url) { completion(size); return }
        let path = url.path
        // Already being measured: wait for that result rather than starting a
        // second walk — and rather than dropping this caller, which used to
        // leave a folder's size blank when the pane re-sorted mid-measurement.
        if waiting[path] != nil {
            waiting[path]?.append(completion)
            return
        }
        waiting[path] = [completion]
        let started = Date()
        queue.async {
            let bytes = Self.total(of: url)
            Task { @MainActor in
                let callbacks = self.waiting.removeValue(forKey: path) ?? []
                if bytes >= 0 { self.entries[path] = Entry(size: bytes, measured: started) }
                for callback in callbacks { callback(bytes) }
            }
        }
    }

    /// After a copy, move or delete, any cached size may be wrong.
    func invalidateAll() { entries.removeAll() }

    /// Sum of every regular file inside. Returns -1 if the folder is so large
    /// that measuring it would keep the disk busy for longer than `budget`.
    nonisolated static func total(of url: URL, budget: TimeInterval = 20) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)) else { return -1 }
        let deadline = Date().addingTimeInterval(budget)
        var total: Int64 = 0
        var seen = 0
        for case let child as URL in walker {
            seen += 1
            if seen % 2000 == 0 && Date() > deadline { return -1 }
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Bytes. For a folder this is -1 until its size has been measured.
    var size: Int64
    let modified: Date
    let icon: NSImage
    let tagColors: [NSColor]

    var id: URL { url }

    // Finder label numbers → their standard colors
    static func labelColor(forNumber number: Int?) -> NSColor? {
        switch number {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return nil
        }
    }

    // Standard Finder tag names → colors (tag names are what Spotlight indexes)
    static let tagNameColors: [String: NSColor] = [
        "Red": .systemRed, "Orange": .systemOrange, "Yellow": .systemYellow,
        "Green": .systemGreen, "Blue": .systemBlue, "Purple": .systemPurple,
        "Gray": .systemGray, "Grey": .systemGray,
    ]

    var sizeText: String {
        if size < 0 { return "—" }              // folder not measured (yet)
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Today's items show just the time, like Finder does.
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var modifiedText: String {
        Calendar.current.isDateInToday(modified)
            ? Self.timeFormatter.string(from: modified)
            : Self.dateFormatter.string(from: modified)
    }
}

@MainActor
final class PaneModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var directory: URL {
        didSet {
            persistDirectory()
            watcher.start(directory)
        }
    }
    // Everything read from disk (or Spotlight), before the search filter.
    private var allItems: [FileItem] = []
    // What the table shows: `allItems` narrowed by `searchText`, sorted.
    @Published var items: [FileItem] = []
    @Published var selection = Set<URL>()
    @Published var pathText: String
    // Set when the current directory couldn't be read (e.g. a TCC-protected
    // iCloud/CloudStorage folder without Full Disk Access). nil when fine.
    @Published var loadError: String?
    // Set to a row's URL to begin inline (in-cell) renaming of that item.
    // The table view consumes it and clears it back to nil.
    @Published var renameRequest: URL?
    // Set to a row's URL to scroll it into view and select it, without
    // starting a rename. The table view consumes it and clears it to nil.
    @Published var revealRequest: URL?
    // Default off (like Finder); remembered across launches, shared by both panes.
    /// Measure and show folder sizes in the Size column (Finder leaves these
    /// blank; here it is on by default because measuring is quick).
    @Published var showFolderSizes = UserDefaults.standard.object(forKey: "showFolderSizes") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showFolderSizes, forKey: "showFolderSizes")
            if showFolderSizes {
                requestFolderSizes()
            } else {
                for index in allItems.indices where allItems[index].isDirectory {
                    allItems[index].size = -1
                }
                applySort()
            }
        }
    }
    private var folderSizeRefreshScheduled = false

    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHiddenFiles") {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "showHiddenFiles")
            reload()
        }
    }
    // Live name filter for this pane. Empty shows everything. Filtering is
    // done in memory, so it costs no directory re-read.
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            applySort()
        }
    }
    // Finder label number to filter by; nil shows everything
    @Published var tagFilter: Int? {
        didSet { reload() }
    }
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [
        KeyPathComparator(\FileItem.name, comparator: .localizedStandard)
    ] {
        didSet { applySort() }
    }
    // Keep folders on top only when sorting by name. When sorting by size or
    // date, sort every item together so the real order shows.
    var foldersFirst = true

    // Bumped whenever items actually change, so the table view can skip
    // expensive array comparisons on selection-only updates.
    private(set) var revision = 0

    private var history: [URL] = []
    private let persistKey: String?

    // True while a row is being renamed in-cell. Refreshing the table under an
    // open field editor would drop what the user has typed, so auto-refresh
    // holds off until the rename is committed or cancelled.
    var isRenaming = false

    /// Watches the current directory so the pane refreshes itself when files
    /// change on disk — from Finder, the Terminal, the other pane, or sync.
    private lazy var watcher = DirectoryWatcher { [weak self] in
        self?.autoRefresh()
    }

    init(directory: URL, persistKey: String? = nil) {
        self.persistKey = persistKey
        self.directory = directory
        self.pathText = directory.path
        reload()
        watcher.start(directory)
    }

    /// Called from the directory watcher. Skips the reload in the cases where it
    /// would fight the user instead of helping.
    private func autoRefresh() {
        guard !isRenaming else { return }
        // Tag filtering shows Spotlight results, not this directory's contents,
        // so a directory event says nothing useful about them.
        guard tagFilter == nil else { return }
        reload()
    }

    // Restores the directory saved under `key`, falling back if it no longer exists
    static func restoredDirectory(key: String, fallback: URL) -> URL {
        guard let path = UserDefaults.standard.string(forKey: key) else { return fallback }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return fallback
        }
        return URL(fileURLWithPath: path)
    }

    private func persistDirectory() {
        guard let persistKey else { return }
        UserDefaults.standard.set(directory.path, forKey: persistKey)
    }

    func reload() {
        if let filter = tagFilter {
            runTagSearch(filter)
            return
        }
        // Kept so an auto-refresh that finds nothing new can leave the table
        // alone — reloading it would cost a redraw and interrupt the user.
        let previousItems = items
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        do {
            var urls = try fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(Self.itemKeys), options: options)
            // The iCloud Drive root holds Desktop/Documents as symlinks that
            // macOS flags hidden; Finder shows them anyway — match that.
            if !showHidden, directory.lastPathComponent == "com~apple~CloudDocs" {
                for name in ["Desktop", "Documents"] {
                    let link = directory.appendingPathComponent(name)
                    if !urls.contains(where: { $0.lastPathComponent == name }),
                        fm.fileExists(atPath: link.path) {
                        urls.append(link)
                    }
                }
            }
            allItems = urls.map { makeItem(url: $0) }
            if directory.lastPathComponent == "com~apple~CloudDocs" {
                allItems += appLibraryItems()
            }
            loadError = nil
        } catch {
            // Surface the failure instead of silently showing an empty pane —
            // this is what users hit on iCloud Drive / OneDrive folders.
            allItems = []
            loadError = error.localizedDescription
        }
        applySort(previous: previousItems)
        pathText = directory.path
        selection = selection.filter { sel in items.contains { $0.url == sel } }
    }

    private static let itemKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
        .labelNumberKey, .tagNamesKey, .isSymbolicLinkKey,
    ]

    // Finder's "iCloud Drive" is a merged view: app folders (Obsidian, Pages,
    // Numbers, …) are not inside com~apple~CloudDocs but are sibling
    // containers under ~/Library/Mobile Documents, each presented by the
    // localized name of its Documents folder. macOS marks the containers of
    // apps that opted out of showing in iCloud Drive as hidden, so listing
    // the visible ones reproduces Finder's set exactly.
    private func appLibraryItems() -> [FileItem] {
        let fm = FileManager.default
        let base = directory.deletingLastPathComponent()
        guard base.lastPathComponent == "Mobile Documents",
            let containers = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }

        var result: [FileItem] = []
        for container in containers where container.lastPathComponent != "com~apple~CloudDocs" {
            let docs = container.appendingPathComponent("Documents")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: docs.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            let name = (try? docs.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
                ?? container.lastPathComponent
            result.append(makeItem(url: docs, displayName: name))
        }
        return result
    }

    private func makeItem(url: URL, displayName: String? = nil) -> FileItem {
        let values = try? url.resourceValues(forKeys: Self.itemKeys)
        var isDirectory = values?.isDirectory ?? false
        // A symlink reports isDirectory=false for the link itself; when it
        // resolves to a folder (e.g. iCloud Drive's Desktop/Documents),
        // treat it as one so it can be navigated into.
        if !isDirectory, values?.isSymbolicLink == true {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                isDirectory = isDir.boolValue
            }
        }
        // Colors come from the tag names (the source of truth Finder and
        // Spotlight use); legacy label number is only a fallback.
        let names = values?.tagNames ?? []
        var colors = names.compactMap { FileItem.tagNameColors[$0] }
        var tagKey = names.first(where: { FileItem.tagNameColors[$0] != nil }) ?? ""
        if colors.isEmpty, let legacy = FileItem.labelColor(forNumber: values?.labelNumber) {
            colors = [legacy]
            tagKey = "label\(values?.labelNumber ?? 0)"
        }
        return FileItem(
            url: url,
            name: displayName ?? url.lastPathComponent,
            isDirectory: isDirectory,
            // A folder's size is unknown (-1) until measured; a cached
            // measurement is used straight away so revisiting is instant.
            size: isDirectory ? (FolderSizeCache.shared.cached(url) ?? -1)
                              : Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate ?? .distantPast,
            icon: IconProvider.icon(for: url, isDirectory: isDirectory,
                                    tintColor: colors.first, tintKey: tagKey),
            tagColors: colors
        )
    }

    // Finder's standard tag names as stored in the Spotlight index
    static let tagNames: [Int: String] = [
        1: "Gray", 2: "Green", 3: "Purple", 4: "Blue", 5: "Yellow", 6: "Red", 7: "Orange",
    ]

    private var searchToken = 0

    // Searches the whole home folder for items with the given Finder tag
    // via the Spotlight index (like Finder's tag sidebar).
    private func runTagSearch(_ label: Int) {
        guard let tagName = Self.tagNames[label] else { return }
        searchToken += 1
        let token = searchToken
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        pathText = directory.path

        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["kMDItemUserTags == \"\(tagName)\"", "-onlyin", home]
            let pipe = Pipe()
            process.standardOutput = pipe
            var paths: [String] = []
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                paths = (String(data: data, encoding: .utf8) ?? "")
                    .split(separator: "\n")
                    .prefix(1000)
                    .map(String.init)
            } catch {
                // mdfind unavailable: fall through with empty results
            }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            await MainActor.run { [weak self] in
                guard let self, token == self.searchToken, self.tagFilter == label else { return }
                self.allItems = urls.map { self.makeItem(url: $0) }
                self.applySort()
                self.selection = self.selection.filter { sel in self.items.contains { $0.url == sel } }
            }
        }
    }

    // Asks for the size of every folder on screen that hasn't got one yet.
    // Cheap to call repeatedly: measured folders are skipped, and the cache
    // answers immediately for ones seen before.
    private func requestFolderSizes() {
        guard showFolderSizes else { return }
        for item in items where item.isDirectory && item.size < 0 {
            let url = item.url
            FolderSizeCache.shared.measure(url) { [weak self] bytes in
                guard let self, bytes >= 0 else { return }
                // Navigated away, or the folder is gone: nothing to update.
                guard let index = self.allItems.firstIndex(where: { $0.url == url }),
                      self.allItems[index].size < 0 else { return }
                self.allItems[index].size = bytes
                self.scheduleFolderSizeRefresh()
            }
        }
    }

    // Coalesced: a folder of 200 subfolders must not re-sort the pane 200 times.
    private func scheduleFolderSizeRefresh() {
        guard !folderSizeRefreshScheduled else { return }
        folderSizeRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.folderSizeRefreshScheduled = false
            self.applySort()
        }
    }

    private func applySort(previous: [FileItem]? = nil) {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let visible = query.isEmpty
            ? allItems
            : allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let sorted: [FileItem]
        if foldersFirst {
            let dirs = visible.filter(\.isDirectory).sorted(using: sortOrder)
            let files = visible.filter { !$0.isDirectory }.sorted(using: sortOrder)
            sorted = dirs + files
        } else {
            sorted = visible.sorted(using: sortOrder)
        }
        items = sorted
        requestFolderSizes()
        // The table view reloads on a revision bump, so only bump when the list
        // really differs — otherwise a watcher event on an unrelated file would
        // redraw the pane for nothing.
        if let previous, previous == sorted { return }
        revision += 1
    }

    func navigate(to url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        history.append(directory)
        directory = url.standardizedFileURL
        selection.removeAll()
        if tagFilter != nil {
            tagFilter = nil // didSet reloads with the new directory
        } else {
            reload()
        }
    }

    func goUp() {
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return }
        navigate(to: parent)
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        directory = previous
        selection.removeAll()
        if tagFilter != nil {
            tagFilter = nil
        } else {
            reload()
        }
    }

    func submitPath() {
        let expanded = (pathText as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            navigate(to: url)
        } else {
            pathText = directory.path
        }
    }

    func open(_ item: FileItem) {
        // Re-check directory status at open time. For cloud placeholders the
        // cached isDirectory flag can be wrong, which would otherwise hand the
        // folder to Finder instead of navigating into it here.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: item.url.path, isDirectory: &isDir)
        if item.isDirectory || (exists && isDir.boolValue) {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.url) }
    }

    var statusText: String {
        let dirCount = items.filter(\.isDirectory).count
        let fileCount = items.count - dirCount
        var text = "\(dirCount) folders, \(fileCount) files"
        if let filter = tagFilter, let name = Self.tagNames[filter] {
            text = "Tag “\(name)” in Home  •  " + text
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            text = "Filter “\(query)”  •  " + text + " of \(allItems.count)"
        }
        if !selection.isEmpty {
            let bytes = selectedItems.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            text += "  •  \(selection.count) selected (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
        }
        return text
    }
}

// Manages a row of tabs for one pane. Each tab is its own PaneModel with its
// own directory, history, selection, etc.
@MainActor
final class PaneTabsModel: ObservableObject {
    @Published var tabs: [PaneModel]
    @Published var selectedIndex: Int

    private let persistKey: String?
    private var cancellables = Set<AnyCancellable>()

    var current: PaneModel { tabs[selectedIndex] }

    init(initialDirectory: URL, persistKey: String?) {
        self.persistKey = persistKey
        if let persistKey, let restored = Self.restoredState(key: persistKey) {
            self.tabs = restored.paths.map { PaneModel(directory: $0) }
            self.selectedIndex = restored.selected
        } else {
            self.tabs = [PaneModel(directory: initialDirectory)]
            self.selectedIndex = 0
        }
        tabs.forEach(observe)
    }

    func addTab(startingAt url: URL? = nil) {
        let tab = PaneModel(directory: url ?? current.directory)
        observe(tab)
        tabs.append(tab)
        selectedIndex = tabs.count - 1
        persist()
    }

    func closeTab(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if selectedIndex >= tabs.count {
            selectedIndex = tabs.count - 1
        } else if selectedIndex > index {
            selectedIndex -= 1
        }
        persist()
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        persist()
    }

    private func observe(_ tab: PaneModel) {
        // Forward each tab's changes to this container. ContentView observes
        // the tabs model, not the individual PaneModel behind `current`, so
        // without this its toolbar, File menu and status bar keep whatever
        // state they last rendered — a freshly selected row never enables
        // Delete/Rename, and ⌘⌫ looks broken because the command is disabled.
        tab.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        tab.$directory
            .dropFirst()
            .sink { [weak self] _ in self?.persist() }
            .store(in: &cancellables)
    }

    private struct SavedState: Codable {
        var paths: [String]
        var selected: Int
    }

    private static func restoredState(key: String) -> (paths: [URL], selected: Int)? {
        guard let data = UserDefaults.standard.data(forKey: key + "Tabs"),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return nil }
        let fm = FileManager.default
        let valid = saved.paths.filter { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !valid.isEmpty else { return nil }
        return (valid.map { URL(fileURLWithPath: $0) }, min(max(saved.selected, 0), valid.count - 1))
    }

    private func persist() {
        guard let persistKey else { return }
        let saved = SavedState(paths: tabs.map { $0.directory.path }, selected: selectedIndex)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: persistKey + "Tabs")
        }
    }
}
