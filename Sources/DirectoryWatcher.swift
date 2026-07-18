import Foundation

/// Watches one directory and reports changes, so a pane can refresh itself when
/// files appear, vanish or are renamed by Finder, the Terminal, or the other pane.
///
/// Two things matter here:
///
/// - **Coalescing.** Copying 500 files fires hundreds of kernel events. Every
///   one of them would otherwise mean a full `contentsOfDirectory` + icon pass.
///   Events are collapsed into a single callback after a short quiet period.
/// - **Re-arming.** The watch is held on a file descriptor, not a path. If the
///   directory itself is renamed or replaced (common with atomic saves and with
///   cloud sync), the descriptor goes stale, so the watcher re-opens the path.
final class DirectoryWatcher {
    private let queue = DispatchQueue(label: "com.tan.dualpane.DirectoryWatcher")
    private let debounce: DispatchTimeInterval = .milliseconds(250)
    private let onChange: @MainActor () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pending: DispatchWorkItem?
    private var watchedPath: String?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    deinit {
        pending?.cancel()
        source?.cancel()   // the cancel handler closes the descriptor
    }

    /// Starts watching `url`, replacing any previous watch.
    func start(_ url: URL) {
        queue.async { [weak self] in
            self?.arm(path: url.path)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.disarm()
        }
    }

    // MARK: - Private (all on `queue`)

    private func arm(path: String) {
        disarm()
        // O_EVTONLY asks for notifications only — it does not count as an open
        // reference, so it won't block the volume from being ejected.
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke, .extend, .attrib],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            // The directory we were watching is gone or was replaced: the old
            // descriptor is dead, so re-open the path before reporting.
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                self.arm(path: path)
            }
            self.scheduleCallback()
        }
        source.setCancelHandler { close(fd) }

        self.descriptor = fd
        self.source = source
        self.watchedPath = path
        source.resume()
    }

    private func disarm() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        descriptor = -1
        watchedPath = nil
    }

    private func scheduleCallback() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let callback = self.onChange
            DispatchQueue.main.async {
                MainActor.assumeIsolated { callback() }
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
