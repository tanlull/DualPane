import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Side { case left, right }

struct ContentView: View {
    @StateObject private var leftPane = PaneModel(directory: FileManager.default.homeDirectoryForCurrentUser)
    @StateObject private var rightPane = PaneModel(
        directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    )
    @StateObject private var favorites = FavoritesStore()
    @State private var activeSide: Side = .left
    @State private var errorMessage: String?
    @State private var renameTarget: FileItem?
    @State private var renameText = ""
    @State private var newFolderPrompt = false
    @State private var newFolderName = "New Folder"
    @State private var confirmDelete = false
    @State private var cutURLs = Set<URL>()
    @AppStorage("showTagColors") private var showTagColors = true
    @State private var transferring: Side?
    @Environment(\.openWindow) private var openWindow

    private var active: PaneModel { activeSide == .left ? leftPane : rightPane }
    private var inactive: PaneModel { activeSide == .left ? rightPane : leftPane }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                PaneView(
                    model: leftPane,
                    favorites: favorites,
                    isActive: activeSide == .left,
                    showTagColors: showTagColors,
                    onActivate: { activeSide = .left },
                    onDropFiles: { copyDropped($0, into: leftPane) },
                    onCopyItems: { copyProviders(from: leftPane, cut: $0) },
                    onPasteItems: { paste($0, into: leftPane) }
                )
                transferStrip
                PaneView(
                    model: rightPane,
                    favorites: favorites,
                    isActive: activeSide == .right,
                    showTagColors: showTagColors,
                    onActivate: { activeSide = .right },
                    onDropFiles: { copyDropped($0, into: rightPane) },
                    onCopyItems: { copyProviders(from: rightPane, cut: $0) },
                    onPasteItems: { paste($0, into: rightPane) }
                )
            }
            Divider()
            statusBar
        }
        .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Delete \(active.selection.count) item(s)?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items will be moved to the Trash.")
        }
        .sheet(item: $renameTarget) { item in
            namePrompt(title: "Rename “\(item.name)”", text: $renameText, confirm: "Rename") {
                performRename(item)
            }
        }
        .sheet(isPresented: $newFolderPrompt) {
            namePrompt(title: "New Folder", text: $newFolderName, confirm: "Create") {
                performNewFolder()
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            toolButton("doc.on.doc", "Copy", help: "Copy selection to other pane (⌘D)") { transfer(move: false) }
                .keyboardShortcut("d")
            toolButton("arrow.right.doc.on.clipboard", "Move", help: "Move selection to other pane (⌘M)") { transfer(move: true) }
                .keyboardShortcut("m")
            Divider().frame(height: 22)
            toolButton("folder.badge.plus", "New Folder", help: "Create folder in active pane (⌘N)") {
                newFolderName = "New Folder"
                newFolderPrompt = true
            }
            .keyboardShortcut("n")
            toolButton("pencil", "Rename", help: "Rename selected item (⌘R)") {
                if let item = active.selectedItems.first {
                    renameText = item.name
                    renameTarget = item
                }
            }
            .keyboardShortcut("r")
            .disabled(active.selection.count != 1)
            toolButton("trash", "Delete", help: "Move selection to Trash (⌘⌫)") { confirmDelete = true }
                .keyboardShortcut(.delete)
                .disabled(active.selection.isEmpty)
            Divider().frame(height: 22)
            toolButton("arrow.left.arrow.right", "Swap", help: "Swap pane directories") { swapPanes() }
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
                Label("Hidden", systemImage: "eye")
            }
            .toggleStyle(.button)
            .help("Show hidden files")
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

    private var transferStrip: some View {
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
        .frame(width: 34)
        .background(.bar)
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
            Text(leftPane.statusText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().frame(height: 14)
            Text(rightPane.statusText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
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
                    renameTarget = nil
                    newFolderPrompt = false
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
        let sources = active.selectedItems
        guard !sources.isEmpty else { return }
        let destDir = inactive.directory
        let fm = FileManager.default
        do {
            for item in sources {
                let dest = uniqueDestination(for: item.url, in: destDir)
                if move {
                    try fm.moveItem(at: item.url, to: dest)
                } else {
                    try fm.copyItem(at: item.url, to: dest)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        leftPane.reload()
        rightPane.reload()
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
        let items = source.selectedItems
        guard !items.isEmpty, transferring == nil else { return }
        transferring = side
        let sourceURLs = items.map(\.url)
        let destDir = dest.directory
        let resolveDestination = uniqueDestination

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var copied: [URL] = []
            var failure: String?
            let started = Date()
            for url in sourceURLs {
                do {
                    let target = resolveDestination(url, destDir)
                    try fm.copyItem(at: url, to: target)
                    // Touch the copy so date-sorted panes show it on top
                    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                    copied.append(target)
                } catch {
                    failure = error.localizedDescription
                }
            }
            // Keep the spinner visible long enough to register
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.4 {
                try? await Task.sleep(nanoseconds: UInt64((0.4 - elapsed) * 1_000_000_000))
            }
            let copiedResult = copied
            let failureResult = failure
            await MainActor.run {
                transferring = nil
                errorMessage = failureResult
                leftPane.reload()
                rightPane.reload()
                // Highlight the new files in the destination pane
                dest.selection = Set(copiedResult)
            }
        }
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
        let fm = FileManager.default
        let destDir = pane.directory.standardizedFileURL
        var consumedCut = false
        do {
            for url in urls where url.isFileURL {
                let isCut = cutURLs.contains(url)
                let sameDir = url.deletingLastPathComponent().standardizedFileURL.path == destDir.path
                if isCut {
                    consumedCut = true
                    guard !sameDir else { continue }
                    try fm.moveItem(at: url, to: uniqueDestination(for: url, in: destDir))
                } else {
                    try fm.copyItem(at: url, to: uniqueDestination(for: url, in: destDir))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        if consumedCut { cutURLs.removeAll() }
        leftPane.reload()
        rightPane.reload()
    }

    private func copyDropped(_ urls: [URL], into pane: PaneModel) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
            .filter { $0.deletingLastPathComponent().standardizedFileURL.path != pane.directory.standardizedFileURL.path }
        guard !fileURLs.isEmpty else { return false }
        do {
            for url in fileURLs {
                let dest = uniqueDestination(for: url, in: pane.directory)
                try FileManager.default.copyItem(at: url, to: dest)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        leftPane.reload()
        rightPane.reload()
        return true
    }

    private func deleteSelection() {
        let fm = FileManager.default
        do {
            for item in active.selectedItems {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        leftPane.reload()
        rightPane.reload()
    }

    private func performRename(_ item: FileItem) {
        defer { renameTarget = nil }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
        } catch {
            errorMessage = error.localizedDescription
        }
        leftPane.reload()
        rightPane.reload()
    }

    private func performNewFolder() {
        defer { newFolderPrompt = false }
        let trimmed = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let dest = active.directory.appendingPathComponent(trimmed)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            errorMessage = error.localizedDescription
        }
        active.reload()
    }

    private func swapPanes() {
        let leftDir = leftPane.directory
        leftPane.navigate(to: rightPane.directory)
        rightPane.navigate(to: leftDir)
    }
}

// MARK: - Pane

struct PaneView: View {
    @ObservedObject var model: PaneModel
    @ObservedObject var favorites: FavoritesStore
    let isActive: Bool
    let showTagColors: Bool
    let onActivate: () -> Void
    let onDropFiles: ([URL]) -> Bool
    let onCopyItems: (Bool) -> [NSItemProvider]
    let onPasteItems: ([NSItemProvider]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            FileTableView(
                model: model,
                showTagColors: showTagColors,
                onActivate: onActivate,
                onCopy: { writeToPasteboard(cut: false) },
                onCut: { writeToPasteboard(cut: true) },
                onPaste: { pasteFromPasteboard() },
                onDrop: onDropFiles
            )
        }
        .frame(minWidth: 380)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
    }

    private var filterTint: Color {
        guard let filter = model.tagFilter,
              let option = ContentView.tagOptions.first(where: { $0.number == filter }) else {
            return .secondary
        }
        return Color(nsColor: option.color)
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
