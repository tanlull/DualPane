import Foundation

/// Downloading online-only cloud files (OneDrive, Dropbox, Google Drive, Box …
/// under ~/Library/CloudStorage, and iCloud Drive under ~/Library/Mobile
/// Documents) so they are present on this Mac.
///
/// Note on Finder's "Always Keep on This Device": that checkbox sets the File
/// Provider *download policy*, which a third-party app cannot set on this
/// macOS SDK — it belongs to the provider's own Finder extension. What we can
/// do, and what this does, is materialize the items now: the provider fetches
/// the contents and leaves a real local copy behind.
enum CloudDownload {

    /// Cheap, synchronous test used to decide whether to show the menu item —
    /// asking the provider is slow and the menu is built up front.
    static func isCloudLocation(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home + "/Library/CloudStorage/")
            || path.hasPrefix(home + "/Library/Mobile Documents/")
    }

    /// A placeholder: the file has a size but no blocks allocated on disk.
    /// iCloud reports it directly; File Provider items are spotted by the
    /// missing allocation.
    static func isOnlineOnly(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey, .fileAllocatedSizeKey, .isDirectoryKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys), v.isDirectory != true else { return false }
        if v.isUbiquitousItem == true {
            return v.ubiquitousItemDownloadingStatus != .current
        }
        return (v.fileSize ?? 0) > 0 && (v.fileAllocatedSize ?? 0) == 0
    }

    /// Fetch the contents of every online-only file in `urls` (recursing into
    /// folders). Returns how many files were downloaded and the first error.
    static func download(_ urls: [URL]) -> (count: Int, error: Error?) {
        let fm = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                      options: [.skipsHiddenFiles])
                while let child = e?.nextObject() as? URL { files.append(child) }
            } else {
                files.append(url)
            }
        }

        var count = 0
        var failure: Error?
        for file in files where isOnlineOnly(file) {
            do {
                // iCloud has an explicit request; every other provider
                // materializes on first read, so reading a byte is enough.
                if (try? file.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
                    try fm.startDownloadingUbiquitousItem(at: file)
                } else {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    _ = try handle.read(upToCount: 1)
                }
                count += 1
            } catch {
                if failure == nil { failure = error }
            }
        }
        return (count, failure)
    }
}
