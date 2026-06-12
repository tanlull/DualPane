import SwiftUI
import AppKit

enum AppInfo {
    static let name = "DualPane"
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3"
    static let author = "Tanya S. (tanlull)"
    static let repoURL = URL(string: "https://github.com/tanlull/DualPane")!

    struct Release {
        let version: String
        let date: String
        let changes: [String]
    }

    static let changelog: [Release] = [
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
