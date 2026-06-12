import Foundation

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var folders: [URL] = []
    private let defaultsKey = "favoriteFolders"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        folders = paths.map { URL(fileURLWithPath: $0) }
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return folders.contains { $0.path == path }
    }

    func toggle(_ url: URL) {
        let standardized = url.standardizedFileURL
        if let index = folders.firstIndex(where: { $0.path == standardized.path }) {
            folders.remove(at: index)
        } else {
            folders.append(standardized)
        }
        save()
    }

    func remove(_ url: URL) {
        folders.removeAll { $0.path == url.standardizedFileURL.path }
        save()
    }

    private func save() {
        UserDefaults.standard.set(folders.map(\.path), forKey: defaultsKey)
    }
}
