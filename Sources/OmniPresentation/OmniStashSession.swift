import Foundation
import OmniCore

/// A stash entry with its place in the stack: the place, not the row's
/// index in a filtered list, names its `/stash:N` token.
public struct OmniStashRow: Equatable, Sendable {
    public let entry: OmniStashEntry
    public let position: Int

    public var token: String { position == 1 ? OmniStashCommand.token : "\(OmniStashCommand.token):\(position)" }
}

/// The `st` tool's state (C93–C94): the stack read from the store, a
/// deterministic filter, a selection, a notice that clears on the next
/// keystroke, and an undo manager that holds drop and clear until the tool
/// closes. Nothing here generates; the store is the only state it touches.
@MainActor
public final class OmniStashSession {
    public var onChange: (@MainActor () -> Void)?
    public private(set) var isOpen = false
    public private(set) var query = ""
    public private(set) var entries: [OmniStashEntry] = []
    public private(set) var rows: [OmniStashRow] = []
    public private(set) var selectedIndex: Int?
    public private(set) var notice: String?
    public private(set) var error: String?
    /// One manager for the field's typing and the stack's changes, so ⌘Z
    /// undoes whichever came last.
    public let undoManager = UndoManager()

    private let stack: OmniStashStack?
    private var observer: NSObjectProtocol?

    public init(stack: OmniStashStack?) {
        self.stack = stack
    }

    public var selectedRow: OmniStashRow? {
        guard isOpen, let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    /// `N of 5`: the stack's depth, whatever the filter shows. Empty, it
    /// also names the chord that fills it (D6).
    public var summary: String {
        entries.isEmpty ? Self.emptySummary : "\(entries.count) of \(OmniStashStack.capacity)"
    }
    public static let emptySummary = "0 of \(OmniStashStack.capacity) · ⌘Y in Glacier or Clipboard stashes"
    public var canUndo: Bool { isOpen && undoManager.canUndo }

    public func open(input: String = "") {
        isOpen = true
        notice = nil
        error = nil
        undoManager.removeAllActions()
        if let stack, observer == nil {
            observer = NotificationCenter.default.addObserver(forName: OmniStashStack.didChange, object: nil, queue: .main) { [weak self] note in
                let path = note.userInfo?["path"] as? String
                MainActor.assumeIsolated {
                    guard let self, path == stack.url.path else { return }
                    self.reload()
                }
            }
        }
        query = input
        reload(selectFirst: true)
    }

    public func close() {
        isOpen = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query = ""
        entries = []
        rows = []
        selectedIndex = nil
        notice = nil
        error = nil
        undoManager.removeAllActions()
        onChange?()
    }

    public func inputChanged(_ next: String) {
        guard isOpen, next != query else { return }
        query = next
        refilter(keeping: nil)
        onChange?()
    }

    /// Notices clear on the next keystroke, never by timer (H17).
    public func noteKeystroke() {
        guard notice != nil || error != nil else { return }
        notice = nil
        error = nil
        onChange?()
    }

    public func moveSelection(by offset: Int) {
        guard isOpen, !rows.isEmpty else { return }
        selectedIndex = max(0, min(rows.count - 1, (selectedIndex ?? 0) + offset))
        onChange?()
    }

    public func select(_ index: Int) {
        guard isOpen, rows.indices.contains(index) else { return }
        selectedIndex = index
        onChange?()
    }

    // MARK: Drop and clear, undoable

    @discardableResult
    public func dropSelected() -> Bool {
        guard let row = selectedRow, let stack else { return false }
        do {
            guard let removed = try stack.remove(id: row.entry.id) else { return false }
            registerRestore(removed.entry, at: removed.index)
            reload()
            notice = "Dropped · \(OmniStashText.excerpt(removed.entry.text.isEmpty ? "Image" : removed.entry.text, limit: 32))"
        } catch {
            self.error = "The stash could not be changed."
        }
        onChange?()
        return true
    }

    @discardableResult
    public func clearAll() -> Bool {
        guard isOpen, let stack, !entries.isEmpty else { return false }
        do {
            let removed = try stack.clear()
            registerRestoreAll(removed)
            reload()
            notice = "Cleared · \(removed.count) \(removed.count == 1 ? "entry" : "entries")"
        } catch {
            self.error = "The stash could not be changed."
        }
        onChange?()
        return true
    }

    public func undo() {
        guard isOpen, undoManager.canUndo else { return }
        undoManager.undo()
        onChange?()
    }

    public func redo() {
        guard isOpen, undoManager.canRedo else { return }
        undoManager.redo()
        onChange?()
    }

    private func registerRestore(_ entry: OmniStashEntry, at index: Int) {
        undoManager.registerUndo(withTarget: self) { session in
            session.restore(entry, at: index)
        }
        undoManager.setActionName("Drop")
    }

    private func restore(_ entry: OmniStashEntry, at index: Int) {
        guard let stack else { return }
        do {
            if try stack.restore(entry, at: index) {
                undoManager.registerUndo(withTarget: self) { session in session.redoDrop(entry) }
                reload(keeping: entry.id)
                notice = nil
            } else {
                notice = "The stash is full · nothing restored"
            }
        } catch { self.error = "The stash could not be changed." }
    }

    private func redoDrop(_ entry: OmniStashEntry) {
        guard let stack, let removed = try? stack.remove(id: entry.id) else { return }
        registerRestore(removed.entry, at: removed.index)
        reload()
    }

    private func registerRestoreAll(_ removed: [OmniStashEntry]) {
        undoManager.registerUndo(withTarget: self) { session in
            guard let stack = session.stack else { return }
            let restored = (try? stack.restoreAll(removed)) ?? 0
            session.undoManager.registerUndo(withTarget: session) { again in
                guard let cleared = try? again.stack?.clear() else { return }
                again.registerRestoreAll(cleared)
                again.reload()
            }
            session.reload(selectFirst: true)
            let missing = removed.count - restored
            session.notice = missing == 0 ? nil : "The stash filled since · \(missing) not restored"
        }
        undoManager.setActionName("Clear")
    }

    // MARK: Reading

    public func reload() { reload(keeping: selectedRow?.entry.id) }

    private func reload(keeping id: String? = nil, selectFirst: Bool = false) {
        guard isOpen else { return }
        do {
            entries = try stack?.entries() ?? []
            if stack == nil { error = "The stash is unavailable here." }
        } catch {
            entries = []
            self.error = "The stash could not be read."
        }
        refilter(keeping: selectFirst ? nil : id)
        onChange?()
    }

    private func refilter(keeping id: String?) {
        let positioned = entries.enumerated().map { OmniStashRow(entry: $0.element, position: $0.offset + 1) }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        rows = terms.isEmpty ? positioned : positioned.filter { row in
            let haystack = (row.entry.text + " " + row.entry.source).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        if let id, let index = rows.firstIndex(where: { $0.entry.id == id }) {
            selectedIndex = index
        } else if let selectedIndex, !rows.isEmpty {
            self.selectedIndex = min(selectedIndex, rows.count - 1)
        } else {
            selectedIndex = rows.isEmpty ? nil : 0
        }
    }
}
