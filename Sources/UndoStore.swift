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
    /// Operations that were undone and can be re-applied with Redo. Cleared as
    /// soon as a new operation is recorded (standard undo/redo semantics).
    @Published private(set) var redoOps: [RedoOp] = []

    /// How to re-apply an undone operation. Each case also carries the Action
    /// that goes back onto the undo stack once the redo succeeds.
    enum RedoOp {
        /// Plain moves (from → to), e.g. redo of a Move or a Rename.
        case moveItems(pairs: [(from: URL, to: URL)], undo: Action, title: String)
        /// Trash the given items again (redo of a Move to Trash).
        case retrash(originals: [URL])
    }

    /// Called after every undo so panes can reload.
    var onDidUndo: (() -> Void)?
    /// Reports a human-readable failure.
    var onError: ((String) -> Void)?

    private let maxDepth = 30

    var canUndo: Bool { !actions.isEmpty }
    var canRedo: Bool { !redoOps.isEmpty }

    var redoTitle: String {
        switch redoOps.last {
        case .moveItems(_, _, let title): return title
        case .retrash: return "Redo Move to Trash"
        case nil: return "Redo"
        }
    }

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
        redoOps.removeAll()
        if actions.count > maxDepth { actions.removeFirst(actions.count - maxDepth) }
    }

    func undo() {
        guard let action = actions.popLast() else { return }
        let fm = FileManager.default
        var failure: String?
        // Items this undo moved to the Trash, paired with where they came
        // from, so Redo can put them back instead of re-copying.
        var trashed: [(from: URL, to: URL)] = []

        // Trash an item, remembering its Trash URL for Redo.
        func trash(_ url: URL) {
            guard failure == nil else { return }
            var resulting: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &resulting)
                if let restored = resulting as URL? {
                    trashed.append((from: restored, to: url))
                }
            } catch { failure = error.localizedDescription }
        }

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
                    trash(pair.dst)
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
                trash(url)
            }
        }

        if let failure {
            onError?(failure)
        } else {
            switch action {
            case .transfer(let move, let pairs) where move:
                redoOps.append(.moveItems(pairs: pairs.map { (from: $0.src, to: $0.dst) },
                                          undo: action, title: "Redo Move"))
            case .transfer:
                redoOps.append(.moveItems(pairs: trashed, undo: action, title: "Redo Copy"))
            case .rename(let from, let to):
                redoOps.append(.moveItems(pairs: [(from: from, to: to)],
                                          undo: action, title: "Redo Rename"))
            case .trash(let pairs):
                redoOps.append(.retrash(originals: pairs.map(\.original)))
            case .create:
                redoOps.append(.moveItems(pairs: trashed, undo: action, title: "Redo New Item"))
            }
        }
        onDidUndo?()
    }

    /// Re-apply the most recently undone operation.
    func redo() {
        guard let op = redoOps.popLast() else { return }
        let fm = FileManager.default
        var failure: String?

        switch op {
        case .moveItems(let pairs, let undoAction, _):
            for pair in pairs {
                guard failure == nil else { break }
                guard fm.fileExists(atPath: pair.from.path) else {
                    failure = "Can’t redo — “\(pair.from.lastPathComponent)” no longer exists."
                    break
                }
                guard !fm.fileExists(atPath: pair.to.path) else {
                    failure = "Can’t redo — an item named “\(pair.to.lastPathComponent)” already exists."
                    break
                }
                do { try fm.moveItem(at: pair.from, to: pair.to) }
                catch { failure = error.localizedDescription }
            }
            if failure == nil { actions.append(undoAction) }
        case .retrash(let originals):
            var pairs: [(original: URL, trash: URL)] = []
            for url in originals {
                guard failure == nil else { break }
                guard fm.fileExists(atPath: url.path) else { continue }
                var resulting: NSURL?
                do {
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                    if let t = resulting as URL? { pairs.append((original: url, trash: t)) }
                } catch { failure = error.localizedDescription }
            }
            if failure == nil, !pairs.isEmpty { actions.append(.trash(pairs: pairs)) }
        }

        if let failure { onError?(failure) }
        onDidUndo?()
    }
}
