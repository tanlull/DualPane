import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Native NSTableView-backed file list: instant selection, native drag & drop,
// responder-chain copy/cut/paste.
struct FileTableView: NSViewRepresentable {
    @ObservedObject var model: PaneModel
    let onActivate: () -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onDrop: ([URL]) -> Bool

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
        sizeCol.minWidth = 60
        sizeCol.maxWidth = 120
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)

        let dateCol = NSTableColumn(identifier: .init("modified"))
        dateCol.title = "Modified"
        dateCol.width = 150
        dateCol.minWidth = 110
        dateCol.maxWidth = 190
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: true)

        table.addTableColumn(nameCol)
        table.addTableColumn(sizeCol)
        table.addTableColumn(dateCol)
        table.sortDescriptors = [nameCol.sortDescriptorPrototype!]

        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menu = context.coordinator.buildMenu()

        let coordinator = context.coordinator
        table.onCopy = { coordinator.parent.onCopy() }
        table.onCut = { coordinator.parent.onCut() }
        table.onPaste = { coordinator.parent.onPaste() }
        table.onFocus = { coordinator.parent.onActivate() }
        table.onReturn = { coordinator.openSelection() }

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

        let directoryChanged = coordinator.lastDirectory != model.directory
        coordinator.lastDirectory = model.directory

        if coordinator.items != model.items {
            coordinator.items = model.items
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
        if table.selectedRowIndexes != desired {
            coordinator.isSyncingSelection = true
            table.selectRowIndexes(desired, byExtendingSelection: false)
            coordinator.isSyncingSelection = false
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FileTableView
        var items: [FileItem] = []
        var isSyncingSelection = false
        var lastDirectory: URL?
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
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            let order: SortOrder = descriptor.ascending ? .forward : .reverse
            MainActor.assumeIsolated {
                switch key {
                case "name":
                    parent.model.sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: order)]
                case "size":
                    parent.model.sortOrder = [KeyPathComparator(\FileItem.size, order: order)]
                case "modified":
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

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation: NSTableView.DropOperation) -> NSDragOperation {
            if let source = info.draggingSource as? NSTableView, source === tableView { return [] }
            guard info.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
            return parent.onDrop(urls)
        }

        // MARK: Context menu

        func buildMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            menu.addItem(makeMenuItem("Open", #selector(menuOpen)))
            menu.addItem(makeMenuItem("Reveal in Finder", #selector(menuReveal)))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("Copy", #selector(menuCopy)))
            menu.addItem(makeMenuItem("Cut", #selector(menuCut)))
            menu.addItem(makeMenuItem("Paste", #selector(menuPaste)))
            return menu
        }

        private func makeMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table = tableView else { return }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes([clicked], byExtendingSelection: false)
            }
            let hasSelection = !table.selectedRowIndexes.isEmpty
            let canPaste = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
            for item in menu.items {
                switch item.action {
                case #selector(menuOpen), #selector(menuReveal), #selector(menuCopy), #selector(menuCut):
                    item.isEnabled = hasSelection
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

        @objc func menuCopy(_ sender: Any?) { parent.onCopy() }
        @objc func menuCut(_ sender: Any?) { parent.onCut() }
        @objc func menuPaste(_ sender: Any?) { parent.onPaste() }
    }
}

// MARK: - NSTableView subclass

final class PaneTableView: NSTableView {
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onFocus: (() -> Void)?
    var onReturn: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
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
