import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Native NSTableView-backed file list: instant selection, native drag & drop,
// responder-chain copy/cut/paste.
struct FileTableView: NSViewRepresentable {
    @ObservedObject var model: PaneModel
    let showTagColors: Bool
    /// Stable per-pane key (e.g. "leftPane" / "rightPane") used to remember
    /// column widths and which columns are hidden across launches.
    let autosaveName: String
    let onActivate: () -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onRename: () -> Void
    let onCommitRename: (URL, String) -> Void
    let onDelete: () -> Void
    let onGetInfo: ([URL]) -> Void
    let onDrop: ([URL]) -> Bool
    let onDropInto: ([URL], URL, Bool) -> Bool // urls, destination folder, move
    let onNewFolder: () -> Void
    let onNewFile: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = PaneTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 160
        nameCol.sortDescriptorPrototype = NSSortDescriptor(
            key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 50
        sizeCol.maxWidth = 240
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)

        let dateCol = NSTableColumn(identifier: .init("modified"))
        dateCol.title = "Modified"
        dateCol.width = 150
        dateCol.minWidth = 90
        dateCol.maxWidth = 320
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: true)

        table.addTableColumn(nameCol)
        table.addTableColumn(sizeCol)
        table.addTableColumn(dateCol)
        table.sortDescriptors = [nameCol.sortDescriptorPrototype!]

        // Remember column widths per pane across launches. Setting autosaveName
        // after the columns exist makes the table restore any saved widths now.
        table.autosaveName = autosaveName
        table.autosaveTableColumns = true

        // Right-click (or Control-click) on the column header: show/hide columns.
        // Hidden state is persisted separately — autosave only covers order/width.
        table.headerView?.menu = context.coordinator.buildHeaderMenu()
        for id in Coordinator.hiddenColumns(autosaveName: autosaveName) {
            table.tableColumn(withIdentifier: .init(id))?.isHidden = true
        }

        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.menu = context.coordinator.buildMenu()

        let coordinator = context.coordinator
        table.onCopy = { coordinator.parent.onCopy() }
        table.onCut = { coordinator.parent.onCut() }
        table.onPaste = { coordinator.parent.onPaste() }
        table.onFocus = { coordinator.parent.onActivate() }
        table.onReturn = { coordinator.openSelection() }
        table.onSlowClickRename = { [weak table] row in
            guard let table else { return }
            coordinator.beginEditing(table: table, row: row)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        coordinator.tableView = table
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = scrollView.documentView as? PaneTableView else { return }

        let modelChanged = coordinator.lastModelID != model.id
        let directoryChanged = modelChanged || coordinator.lastDirectory != model.directory
        coordinator.lastDirectory = model.directory
        coordinator.lastModelID = model.id

        var needsReload = false
        if modelChanged || coordinator.lastRevision != model.revision {
            coordinator.lastRevision = model.revision
            coordinator.items = model.items
            needsReload = true
        }
        if coordinator.showTagColors != showTagColors {
            coordinator.showTagColors = showTagColors
            needsReload = true
        }
        if needsReload {
            table.reloadData()
        }
        if directoryChanged {
            table.scrollRowToVisible(0)
        }

        let desired = IndexSet(
            model.items.enumerated()
                .filter { model.selection.contains($0.element.url) }
                .map(\.offset)
        )
        if table.selectedRowIndexes != desired, !table.isTrackingMouse {
            coordinator.isSyncingSelection = true
            table.selectRowIndexes(desired, byExtendingSelection: false)
            coordinator.isSyncingSelection = false
        }

        // A reveal was requested (e.g. a just-created item): scroll it into
        // view but leave its name alone.
        if let target = model.revealRequest,
           let row = coordinator.items.firstIndex(where: { $0.url == target }) {
            DispatchQueue.main.async {
                model.revealRequest = nil
                guard row < table.numberOfRows else { return }
                table.scrollRowToVisible(row)
            }
        }

        // A rename was requested (toolbar/menu): begin in-cell editing of that row.
        if let target = model.renameRequest,
           let row = coordinator.items.firstIndex(where: { $0.url == target }) {
            DispatchQueue.main.async {
                model.renameRequest = nil
                guard row < table.numberOfRows else { return }
                table.scrollRowToVisible(row)
                coordinator.beginEditing(table: table, row: row)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: FileTableView
        var items: [FileItem] = []
        var lastRevision = -1
        var showTagColors = true
        var isSyncingSelection = false
        var lastDirectory: URL?
        var lastModelID: UUID?
        weak var tableView: NSTableView?

        init(_ parent: FileTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < items.count, let column = tableColumn else { return nil }
            let item = items[row]
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView)
                ?? makeCell(identifier: column.identifier)
            switch column.identifier.rawValue {
            case "name":
                cell.imageView?.image = item.icon
                cell.textField?.stringValue = item.name
                cell.textField?.textColor = .labelColor
                if let dot = cell.subviews.first(where: { $0 is TagDotView }) as? TagDotView {
                    // Folders show their first tag via the tinted icon; extra tags
                    // appear as dots. Files show all tag colors as dots.
                    let colors = showTagColors ? item.tagColors : []
                    dot.colors = item.isDirectory ? Array(colors.dropFirst()) : colors
                }
            case "size":
                cell.textField?.stringValue = item.sizeText
                cell.textField?.textColor = .secondaryLabelColor
            case "modified":
                cell.textField?.stringValue = item.modifiedText
                cell.textField?.textColor = .secondaryLabelColor
            default:
                break
            }
            return cell
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small) + 1)
            cell.addSubview(text)
            cell.textField = text

            if identifier.rawValue == "name" {
                // NOT editable by default. An always-editable field swallows
                // clicks meant for the row: the field editor takes first
                // responder, the table never reports a selection change, and
                // every selection-driven command (Delete/⌘⌫, Rename, Copy,
                // Move) stays disabled. Editing is switched on only for the
                // row we are about to edit, in `beginEditing(row:)`, and
                // switched back off in controlTextDidEndEditing.
                text.isEditable = false
                text.isSelectable = false
                text.focusRingType = .none
                text.delegate = self
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                let dot = TagDotView()
                dot.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(dot)
                text.setContentHuggingPriority(.defaultHigh, for: .horizontal)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -16),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    dot.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 5),
                    dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    dot.heightAnchor.constraint(equalToConstant: 9),
                ])
            } else {
                if identifier.rawValue == "size" { text.alignment = .right }
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            return cell
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let table = notification.object as? NSTableView else { return }
            let urls = Set(table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil })
            MainActor.assumeIsolated {
                if parent.model.selection != urls {
                    parent.model.selection = urls
                }
            }
        }

        // MARK: Open

        @objc func doubleClicked(_ sender: Any?) {
            guard let table = tableView else { return }
            let row = table.clickedRow
            guard row >= 0, row < items.count else { return }
            let item = items[row]
            MainActor.assumeIsolated { parent.model.open(item) }
        }

        func openSelection() {
            guard let table = tableView, let row = table.selectedRowIndexes.first, row < items.count else { return }
            let item = items[row]
            MainActor.assumeIsolated { parent.model.open(item) }
        }

        // MARK: Inline rename

        /// Make just this row's name field editable, then start editing it.
        func beginEditing(table: NSTableView, row: Int) {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
            cell?.textField?.isEditable = true
            cell?.textField?.isSelectable = true
            table.editColumn(0, row: row, with: nil, select: true)
            selectBaseName(of: cell?.textField, in: table)
        }

        /// Finder behaviour: pre-select only the part of the name before the
        /// extension, so typing replaces "report" in "report.pdf" and leaves
        /// ".pdf" intact.
        private func selectBaseName(of field: NSTextField?, in table: NSTableView) {
            guard let field,
                  let editor = table.window?.fieldEditor(false, for: field) as? NSTextView
            else { return }
            let name = field.stringValue as NSString
            let base = name.deletingPathExtension as NSString
            guard base.length > 0, base.length < name.length else { return }
            editor.setSelectedRange(NSRange(location: 0, length: base.length))
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            // Hold off auto-refresh: reloading the table would close the field
            // editor and lose what the user has typed.
            MainActor.assumeIsolated { parent.model.isRenaming = true }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            MainActor.assumeIsolated { parent.model.isRenaming = false }
            guard let field = obj.object as? NSTextField, let table = tableView else { return }
            // Lock the field again so it stops intercepting row clicks.
            field.isEditable = false
            field.isSelectable = false
            let row = table.row(for: field)
            guard row >= 0, row < items.count else { return }
            let item = items[row]
            // Esc cancels: revert the text and don't rename.
            let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
            if movement == NSTextMovement.cancel.rawValue {
                field.stringValue = item.name
                return
            }
            let newName = field.stringValue
            MainActor.assumeIsolated { parent.onCommitRename(item.url, newName) }
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            let order: SortOrder = descriptor.ascending ? .forward : .reverse
            MainActor.assumeIsolated {
                switch key {
                case "name":
                    parent.model.foldersFirst = true
                    parent.model.sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: order)]
                case "size":
                    parent.model.foldersFirst = false
                    parent.model.sortOrder = [KeyPathComparator(\FileItem.size, order: order)]
                case "modified":
                    parent.model.foldersFirst = false
                    parent.model.sortOrder = [KeyPathComparator(\FileItem.modified, order: order)]
                default:
                    break
                }
            }
        }

        // MARK: Drag source

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < items.count else { return nil }
            return items[row].url as NSURL
        }

        // MARK: Drop target

        // validateDrop fires on every mouse move during a drag; re-reading the
        // pasteboard each time is slow with many items and made drags lag.
        // Cache the URLs once per drag session (keyed by its sequence number).
        private var dragCacheSequence = -1
        private var dragCacheURLs: [URL] = []

        private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
            let sequence = info.draggingSequenceNumber
            if sequence != dragCacheSequence {
                dragCacheSequence = sequence
                dragCacheURLs = (info.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            }
            return dragCacheURLs
        }

        // A folder row can accept `urls` only if none of them *is* that folder,
        // contains it, or already lives directly inside it. Path-prefix checks
        // are a conservative pre-filter; the transfer itself re-validates with
        // real file identity (dpIsSameItem) before touching anything.
        private func canDrop(_ urls: [URL], into folder: URL) -> Bool {
            let folderPath = folder.standardizedFileURL.path
            for url in urls {
                let path = url.standardizedFileURL.path
                if path == folderPath { return false }                       // folder onto itself
                if folderPath.hasPrefix(path + "/") { return false }        // into its own subfolder
                if url.deletingLastPathComponent().standardizedFileURL.path == folderPath { return false } // already there
            }
            return true
        }

        private func folderTarget(for urls: [URL], row: Int) -> FileItem? {
            guard row >= 0, row < items.count else { return nil }
            let item = items[row]
            guard item.isDirectory, canDrop(urls, into: item.url) else { return nil }
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let urls = draggedURLs(info)
            guard !urls.isEmpty else { return [] }
            let sameTable = (info.draggingSource as? NSTableView) === tableView

            // Hovering over a folder row: drop *into* that folder — a move when
            // the drag started in this same pane, a copy when it came from the
            // other pane or another app.
            if let target = folderTarget(for: urls, row: row) {
                if let targetRow = items.firstIndex(of: target) {
                    tableView.setDropRow(targetRow, dropOperation: .on)
                }
                return sameTable ? .move : .copy
            }

            // Anywhere else in the same pane is a no-op (the items are already here).
            if sameTable { return [] }

            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = draggedURLs(info)
            guard !urls.isEmpty else { return false }
            let sameTable = (info.draggingSource as? NSTableView) === tableView
            if dropOperation == .on, let target = folderTarget(for: urls, row: row) {
                return parent.onDropInto(urls, target.url, sameTable)
            }
            if sameTable { return false }
            return parent.onDrop(urls)
        }

        // MARK: Header menu (show/hide columns)

        private weak var headerMenu: NSMenu?
        // Name is the anchor column and can't be hidden — only these can.
        private static let toggleableColumns: [(id: String, title: String)] = [
            ("size", "Size"),
            ("modified", "Modified"),
        ]

        private static func hiddenColumnsKey(_ autosaveName: String) -> String {
            "hiddenColumns.\(autosaveName)"
        }

        static func hiddenColumns(autosaveName: String) -> [String] {
            UserDefaults.standard.stringArray(forKey: hiddenColumnsKey(autosaveName)) ?? []
        }

        func buildHeaderMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            for column in Self.toggleableColumns {
                let item = NSMenuItem(title: column.title,
                                      action: #selector(toggleColumnVisibility(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = column.id
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let sizes = NSMenuItem(title: "Calculate Folder Sizes",
                                   action: #selector(toggleFolderSizes), keyEquivalent: "")
            sizes.target = self
            sizes.representedObject = "folderSizes"
            menu.addItem(sizes)
            headerMenu = menu
            return menu
        }

        @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
            guard let table = tableView,
                  let id = sender.representedObject as? String,
                  let column = table.tableColumn(withIdentifier: .init(id)) else { return }
            column.isHidden.toggle()
            var hidden = Set(Self.hiddenColumns(autosaveName: parent.autosaveName))
            if column.isHidden { hidden.insert(id) } else { hidden.remove(id) }
            UserDefaults.standard.set(Array(hidden).sorted(),
                                      forKey: Self.hiddenColumnsKey(parent.autosaveName))
        }

        // MARK: Context menu

        func buildMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            menu.addItem(makeMenuItem("Open", #selector(menuOpen)))
            menu.addItem(makeMenuItem("Reveal in Finder", #selector(menuReveal)))
            menu.addItem(makeMenuItem("Open in Terminal", #selector(menuTerminal)))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("Rename…", #selector(menuRename)))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("New Folder", #selector(menuNewFolder)))
            menu.addItem(makeMenuItem("New File", #selector(menuNewFile)))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("Copy", #selector(menuCopy)))
            menu.addItem(makeMenuItem("Cut", #selector(menuCut)))
            menu.addItem(makeMenuItem("Paste", #selector(menuPaste)))
            menu.addItem(.separator())
            // Delete sits just above Refresh, away from Rename…, so a stray
            // click near the top of the menu can't trash the selection.
            menu.addItem(makeMenuItem("Delete", #selector(menuDelete)))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("Refresh", #selector(menuRefresh)))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("Get Info", #selector(menuGetInfo), key: "i"))
            return menu
        }

        private func makeMenuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }

        @objc private func menuGetInfo() {
            guard let table = tableView else { return }
            let urls = table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil }
            guard !urls.isEmpty else { return }
            parent.onGetInfo(urls)
        }

        @objc private func toggleFolderSizes() {
            let model = parent.model
            Task { @MainActor in model.showFolderSizes.toggle() }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table = tableView else { return }
            if menu === headerMenu {
                for item in menu.items {
                    guard let id = item.representedObject as? String else { continue }
                    if id == "folderSizes" {
                        item.state = parent.model.showFolderSizes ? .on : .off
                        continue
                    }
                    guard let column = table.tableColumn(withIdentifier: .init(id)) else { continue }
                    item.state = column.isHidden ? .off : .on
                }
                return
            }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes([clicked], byExtendingSelection: false)
            }
            let hasSelection = !table.selectedRowIndexes.isEmpty
            let canPaste = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
            for item in menu.items {
                switch item.action {
                case #selector(menuOpen), #selector(menuReveal), #selector(menuCopy),
                     #selector(menuCut), #selector(menuDelete), #selector(menuGetInfo):
                    item.isEnabled = hasSelection
                case #selector(menuRename):
                    item.isEnabled = table.selectedRowIndexes.count == 1
                case #selector(menuPaste):
                    item.isEnabled = canPaste
                default:
                    break
                }
            }
        }

        @objc func menuOpen(_ sender: Any?) { openSelection() }

        @objc func menuReveal(_ sender: Any?) {
            guard let table = tableView else { return }
            let urls = table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        @objc func menuTerminal(_ sender: Any?) {
            MainActor.assumeIsolated {
                // Open the clicked folder if one folder is selected, else the
                // pane's current directory ("open terminal here").
                let folders = (tableView?.selectedRowIndexes ?? [])
                    .compactMap { $0 < items.count ? items[$0] : nil }
                    .filter(\.isDirectory)
                let dir = folders.count == 1 ? folders[0].url : parent.model.directory
                guard let term = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.apple.Terminal") else { return }
                NSWorkspace.shared.open([dir], withApplicationAt: term,
                                        configuration: NSWorkspace.OpenConfiguration())
            }
        }

        @objc func menuRename(_ sender: Any?) { parent.onRename() }

        @objc func menuDelete(_ sender: Any?) {
            MainActor.assumeIsolated { parent.onActivate(); parent.onDelete() }
        }

        @objc func menuNewFolder(_ sender: Any?) {
            MainActor.assumeIsolated { parent.onActivate(); parent.onNewFolder() }
        }

        @objc func menuNewFile(_ sender: Any?) {
            MainActor.assumeIsolated { parent.onActivate(); parent.onNewFile() }
        }

        @objc func menuRefresh(_ sender: Any?) {
            MainActor.assumeIsolated { parent.model.reload() }
        }

        @objc func menuCopy(_ sender: Any?) { parent.onCopy() }
        @objc func menuCut(_ sender: Any?) { parent.onCut() }
        @objc func menuPaste(_ sender: Any?) { parent.onPaste() }
    }
}

// MARK: - Finder tag color dot

final class TagDotView: NSView {
    private static let dotSize: CGFloat = 9
    private static let dotStep: CGFloat = 5 // overlap like Finder

    var colors: [NSColor] = [] {
        didSet {
            isHidden = colors.isEmpty
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        guard !colors.isEmpty else { return .zero }
        let width = Self.dotSize + Self.dotStep * CGFloat(colors.count - 1)
        return NSSize(width: width, height: Self.dotSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = (bounds.height - Self.dotSize) / 2
        for (index, color) in colors.enumerated() {
            let rect = NSRect(x: CGFloat(index) * Self.dotStep, y: y,
                              width: Self.dotSize, height: Self.dotSize)
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            path.fill()
            NSColor.controlBackgroundColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - NSTableView subclass

final class PaneTableView: NSTableView {
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onFocus: (() -> Void)?
    var onReturn: (() -> Void)?
    /// Finder-style "click an already-selected row again to rename it".
    var onSlowClickRename: ((Int) -> Void)?
    private var pendingRename: DispatchWorkItem?

    func cancelPendingRename() {
        pendingRename?.cancel()
        pendingRename = nil
    }

    /// True while a click/drag gesture is in flight. AppKit's mouse-tracking
    /// loop keeps the run loop spinning, so SwiftUI can push an update — and
    /// re-apply `model.selection` to the table — *in the middle* of a drag.
    /// If that model selection is even briefly behind (a pane that just became
    /// active, a reload that pruned it), the table collapses to a single row
    /// before AppKit reads the selection to build the drag, and only one file
    /// gets dropped. The view layer skips its selection sync while this is set.
    private(set) var isTrackingMouse = false

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        defer { isTrackingMouse = false }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let hadFocus = window?.firstResponder === self
        let wasOnlySelection = selectedRowIndexes.count == 1 && selectedRow == row
        cancelPendingRename()
        super.mouseDown(with: event)
        // Only a plain second click on the one row that was already selected,
        // in a pane that already had focus, starts a rename. A double-click
        // arrives as its own mouseDown and cancels the pending work first.
        let modifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        guard event.clickCount == 1, row >= 0, hadFocus, wasOnlySelection,
              event.modifierFlags.intersection(modifiers).isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.selectedRowIndexes.count == 1, self.selectedRow == row else { return }
            self.onSlowClickRename?(row)
        }
        pendingRename = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.1, execute: work)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        cancelPendingRename()
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func cut(_ sender: Any?) { onCut?() }
    @objc func paste(_ sender: Any?) { onPaste?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return !selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
