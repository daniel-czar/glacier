import Foundation
import OmniCore

/// Ratio (C117): the reference grid on an empty field, a drawing and rows
/// for a ratio, size or ratio at a dimension, presets for a name. The
/// session holds only the tables, so it has no way to reach a model, the
/// network or a store; every keystroke is answered synchronously.
@MainActor
public final class OmniRatioSession {
    public var onChange: (@MainActor () -> Void)?
    public private(set) var input = ""
    public private(set) var isOpen = false
    public private(set) var result: RatioResult = .empty
    public private(set) var selectedIndex: Int?
    /// Route-line notice when the bundled tables did not load.
    public var notice: String? { isOpen && tables == nil ? "Ratio tables are unavailable in this build." : nil }

    private let tables: RatioTables?

    public init(tables: RatioTables?) {
        self.tables = tables
    }

    /// What Enter (and ⌘C with no text selected) copies.
    public var copyText: String? {
        guard isOpen, let selectedIndex else { return nil }
        return result.copyText(at: selectedIndex)
    }

    /// The summary line: always shows what Enter will copy (C120), or the
    /// dimmed `no ratio in "…"` (C121).
    public var summary: String? { isOpen ? result.summary(at: selectedIndex) : nil }

    public var isMiss: Bool { result.miss != nil }

    public func open(input: String = "") {
        isOpen = true
        inputChanged(input)
    }

    public func close() {
        isOpen = false
        input = ""
        result = .empty
        selectedIndex = nil
        onChange?()
    }

    public func inputChanged(_ next: String) {
        guard isOpen else { return }
        input = next
        result = tables.map { RatioCalculator.evaluate(next, tables: $0) } ?? .empty
        selectedIndex = result.initialSelection
        onChange?()
    }

    /// ↑↓ through rows; false when there are none (the grid moves by frame).
    @discardableResult
    public func moveSelection(by offset: Int) -> Bool {
        guard isOpen, result.itemCount > 0 else { return false }
        let current = selectedIndex ?? 0
        selectedIndex = max(0, min(result.itemCount - 1, current + offset))
        onChange?()
        return true
    }

    public func select(_ index: Int) {
        guard isOpen, (0..<result.itemCount).contains(index) else { return }
        selectedIndex = index
        onChange?()
    }
}
