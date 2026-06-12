import Foundation
import AppKit

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let icon: NSImage
    let labelColor: NSColor?

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
final class PaneModel: ObservableObject {
    @Published var directory: URL
    @Published var items: [FileItem] = []
    @Published var selection = Set<URL>()
    @Published var pathText: String
    @Published var showHidden = false {
        didSet { reload() }
    }
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [
        KeyPathComparator(\FileItem.name, comparator: .localizedStandard)
    ] {
        didSet { applySort() }
    }

    private var history: [URL] = []

    init(directory: URL) {
        self.directory = directory
        self.pathText = directory.path
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey, .labelNumberKey]
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: options)) ?? []
        items = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast,
                icon: NSWorkspace.shared.icon(forFile: url.path),
                labelColor: FileItem.labelColor(forNumber: values?.labelNumber)
            )
        }
        applySort()
        pathText = directory.path
        selection = selection.filter { sel in items.contains { $0.url == sel } }
    }

    private func applySort() {
        let dirs = items.filter(\.isDirectory).sorted(using: sortOrder)
        let files = items.filter { !$0.isDirectory }.sorted(using: sortOrder)
        items = dirs + files
    }

    func navigate(to url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        history.append(directory)
        directory = url.standardizedFileURL
        selection.removeAll()
        reload()
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
        reload()
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
        if item.isDirectory {
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
        if !selection.isEmpty {
            let bytes = selectedItems.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            text += "  •  \(selection.count) selected (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
        }
        return text
    }
}
