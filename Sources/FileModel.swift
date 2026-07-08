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

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
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
        if isDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var modifiedText: String { Self.dateFormatter.string(from: modified) }
}

@MainActor
final class PaneModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var directory: URL {
        didSet { persistDirectory() }
    }
    @Published var items: [FileItem] = []
    @Published var selection = Set<URL>()
    @Published var pathText: String
    // Set when the current directory couldn't be read (e.g. a TCC-protected
    // iCloud/CloudStorage folder without Full Disk Access). nil when fine.
    @Published var loadError: String?
    // Set to a row's URL to begin inline (in-cell) renaming of that item.
    // The table view consumes it and clears it back to nil.
    @Published var renameRequest: URL?
    @Published var showHidden = false {
        didSet { reload() }
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

    init(directory: URL, persistKey: String? = nil) {
        self.persistKey = persistKey
        self.directory = directory
        self.pathText = directory.path
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
            items = urls.map { makeItem(url: $0) }
            if directory.lastPathComponent == "com~apple~CloudDocs" {
                items += appLibraryItems()
            }
            loadError = nil
        } catch {
            // Surface the failure instead of silently showing an empty pane —
            // this is what users hit on iCloud Drive / OneDrive folders.
            items = []
            loadError = error.localizedDescription
        }
        applySort()
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
            size: Int64(values?.fileSize ?? 0),
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
                self.items = urls.map { self.makeItem(url: $0) }
                self.applySort()
                self.selection = self.selection.filter { sel in self.items.contains { $0.url == sel } }
            }
        }
    }

    private func applySort() {
        if foldersFirst {
            let dirs = items.filter(\.isDirectory).sorted(using: sortOrder)
            let files = items.filter { !$0.isDirectory }.sorted(using: sortOrder)
            items = dirs + files
        } else {
            items = items.sorted(using: sortOrder)
        }
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
