import SwiftUI
import AppKit

// Central undo stack for file operations (copy, move, rename, trash, create).
//
// Undo of a *file* operation can't use NSUndoManager closures alone — the app
// may reload panes in between, so each action records concrete URLs and the
// reverse operation is re-derived from the file system at undo time.
//
// Safety rules (same spirit as runTransfer):
// - Undo never overwrites: if the restore destination is now occupied, the
//   undo stops with an error instead of replacing anything.
// - Undo of a copy/new-item moves the created item to the Trash (recoverable),
//   never a hard delete.
@MainActor
final class UndoStore: ObservableObject {
    static let shared = UndoStore()

    enum Action {
        case transfer(move: Bool, pairs: [(src: URL, dst: URL)])
        case rename(from: URL, to: URL)
        case trash(pairs: [(original: URL, trash: URL)])
        case create(URL)
    }

    @Published private(set) var actions: [Action] = []

    /// Called after every undo so panes can reload.
    var onDidUndo: (() -> Void)?
    /// Reports a human-readable failure.
    var onError: ((String) -> Void)?

    private let maxDepth = 30

    var canUndo: Bool { !actions.isEmpty }

    var undoTitle: String {
        switch actions.last {
        case .transfer(let move, _): return move ? "Undo Move" : "Undo Copy"
        case .rename: return "Undo Rename"
        case .trash: return "Undo Move to Trash"
        case .create: return "Undo New Item"
        case nil: return "Undo"
        }
    }

    func record(_ action: Action) {
        actions.append(action)
        if actions.count > maxDepth { actions.removeFirst(actions.count - maxDepth) }
    }

    func undo() {
        guard let action = actions.popLast() else { return }
        let fm = FileManager.default
        var failure: String?

        // Restore by moving `from` back to `to`, refusing to overwrite.
        func restore(_ from: URL, to: URL) {
            guard failure == nil else { return }
            guard fm.fileExists(atPath: from.path) else {
                failure = "Can’t undo — “\(from.lastPathComponent)” no longer exists."
                return
            }
            guard !fm.fileExists(atPath: to.path) else {
                failure = "Can’t undo — an item named “\(to.lastPathComponent)” already exists at the original location."
                return
            }
            do { try fm.moveItem(at: from, to: to) }
            catch { failure = error.localizedDescription }
        }

        switch action {
        case .transfer(let move, let pairs):
            for pair in pairs.reversed() {
                if move {
                    restore(pair.dst, to: pair.src)
                } else if fm.fileExists(atPath: pair.dst.path) {
                    // Undo copy: send the copy to the Trash (recoverable).
                    do { try fm.trashItem(at: pair.dst, resultingItemURL: nil) }
                    catch { failure = error.localizedDescription }
                }
            }
        case .rename(let from, let to):
            restore(to, to: from)
        case .trash(let pairs):
            for pair in pairs.reversed() {
                restore(pair.trash, to: pair.original)
            }
        case .create(let url):
            if fm.fileExists(atPath: url.path) {
                do { try fm.trashItem(at: url, resultingItemURL: nil) }
                catch { failure = error.localizedDescription }
            }
        }

        if let failure { onError?(failure) }
        onDidUndo?()
    }
}
