import SwiftUI
import AppKit
import UniformTypeIdentifiers

// "Get Info" for the selected file(s) or folder(s), in the spirit of Finder's
// ⌘I panel. A folder's size has to be measured, so it arrives asynchronously
// while the rest of the panel is already on screen.
struct InfoView: View {
    let urls: [URL]
    var onClose: () -> Void

    @State private var facts: [Fact] = []
    @State private var totalBytes: Int64 = -1
    @State private var fileCount = 0
    @State private var folderCount = 0
    @State private var measuring = false

    struct Fact: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    private var single: URL? { urls.count == 1 ? urls[0] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(facts) { fact in
                    HStack(alignment: .top, spacing: 10) {
                        Text(fact.label)
                            .frame(width: 92, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(fact.value)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 16)
            HStack {
                if let single {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([single])
                    }
                }
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(sizeLine)
                        .foregroundStyle(.secondary)
                    if measuring {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                }
                .font(.callout)
            }
            Spacer()
        }
    }

    private var icon: NSImage {
        guard let single else { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(forFile: single.path)
    }

    private var title: String {
        single?.lastPathComponent ?? "\(urls.count) items"
    }

    private var sizeLine: String {
        if totalBytes < 0 { return measuring ? "Measuring…" : "Size unavailable" }
        let bytes = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let exact = NumberFormatter.localizedString(from: NSNumber(value: totalBytes), number: .decimal)
        return "\(bytes) (\(exact) bytes)"
    }

    private func load() {
        var rows: [Fact] = []
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .tagNamesKey, .isSymbolicLinkKey, .contentTypeKey,
        ]

        if let single {
            let values = try? single.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory ?? false
            rows.append(Fact(label: "Kind", value: kindText(single, values: values, isDirectory: isDirectory)))
            rows.append(Fact(label: "Where", value: single.deletingLastPathComponent().path))
            if let created = values?.creationDate {
                rows.append(Fact(label: "Created", value: FileItem.dateFormatter.string(from: created)))
            }
            if let modified = values?.contentModificationDate {
                rows.append(Fact(label: "Modified", value: FileItem.dateFormatter.string(from: modified)))
            }
            let tags = values?.tagNames ?? []
            if !tags.isEmpty {
                rows.append(Fact(label: "Tags", value: tags.joined(separator: ", ")))
            }
            if let attributes = try? fm.attributesOfItem(atPath: single.path),
               let permissions = attributes[.posixPermissions] as? NSNumber {
                let owner = attributes[.ownerAccountName] as? String ?? "—"
                rows.append(Fact(label: "Permissions",
                                 value: String(format: "%@  %o", owner, permissions.uint16Value)))
            }
            if isDirectory {
                measuring = true
                countContents(of: single)
                FolderSizeCache.shared.measure(single) { bytes in
                    totalBytes = bytes
                    measuring = false
                }
            } else {
                totalBytes = Int64(values?.fileSize ?? 0)
            }
        } else {
            // Several items selected: report the combined picture.
            let directories = urls.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            rows.append(Fact(label: "Selection",
                             value: "\(urls.count - directories.count) files, \(directories.count) folders"))
            rows.append(Fact(label: "Where", value: urls[0].deletingLastPathComponent().path))
            measuring = true
            measureAll()
        }
        facts = rows
    }

    private func kindText(_ url: URL, values: URLResourceValues?, isDirectory: Bool) -> String {
        if values?.isSymbolicLink == true { return "Alias / symbolic link" }
        if url.pathExtension.lowercased() == "app" { return "Application" }
        if isDirectory { return "Folder" }
        if let type = values?.contentType?.localizedDescription { return type }
        return url.pathExtension.isEmpty ? "Document" : "\(url.pathExtension.uppercased()) document"
    }

    // Counts what is inside a folder, for the "Contains" line Finder shows.
    private func countContents(of url: URL) {
        DispatchQueue.global(qos: .utility).async {
            var files = 0
            var folders = 0
            if let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let child as URL in walker {
                    if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        folders += 1
                    } else {
                        files += 1
                    }
                }
            }
            let (f, d) = (files, folders)
            Task { @MainActor in
                fileCount = f
                folderCount = d
                facts.insert(Fact(label: "Contains", value: "\(f) files, \(d) folders"), at: 1)
            }
        }
    }

    private func measureAll() {
        let targets = urls
        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = 0
            for url in targets {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    let bytes = FolderSizeCache.total(of: url)
                    if bytes > 0 { total += bytes }
                } else {
                    total += Int64(values?.fileSize ?? 0)
                }
            }
            let sum = total
            Task { @MainActor in
                totalBytes = sum
                measuring = false
            }
        }
    }
}
