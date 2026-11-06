import Foundation
import OmniCore

public enum OmniEmojiOrigin: Sendable, Equatable {
    case corpus
    case suggested
}

/// Recall with a grid: the frequent set on an empty field, instant local
/// search while typing, and the model only for a thin result. Each edit
/// invalidates the debounce and any late reply, even one that cannot cancel.
@MainActor
public final class OmniEmojiSession {
    public typealias Suggest = @Sendable (String) async throws -> [EmojiEntry]
    public static let columns = 10
    public static let maximumInputCharacters = 512
    /// Model picks shown below the hairline (the handoff's ≤ 5).
    public static let maximumSuggestions = 5

    public var onChange: (@MainActor () -> Void)?
    public private(set) var input = ""
    public private(set) var isOpen = false
    /// Frequent set (empty field) or local matches, strong before weak.
    public private(set) var localRows: [EmojiEntry] = []
    /// Model picks, validated against the corpus, below the hairline.
    public private(set) var suggestedRows: [EmojiEntry] = []
    public private(set) var selectedIndex: Int?
    public private(set) var isSuggesting = false
    /// Route-line notice (an unavailable corpus), cleared on the next keystroke.
    public private(set) var notice: String?
    public private(set) var error: String?
    /// Settings → Tools: applied to what the grid draws and what Enter copies.
    public let skinTone: OmniSkinTone

    public var rows: [EmojiEntry] { localRows + suggestedRows }
    public var isManualMode: Bool { !automaticRequestsEnabled() }
    public var canSuggestManually: Bool {
        guard isOpen, isManualMode, !isSuggesting, let corpus,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.count <= Self.maximumInputCharacters else { return false }
        return EmojiMatcher.search(input, in: corpus).isThin
    }

    /// The selection as it is drawn and copied, in the chosen skin tone.
    public var selectedText: String? { selectedEntry.map { skinTone.apply(to: $0.emoji) } }

    public var selectedEntry: EmojiEntry? {
        guard isOpen, let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    public var selectedOrigin: OmniEmojiOrigin? {
        guard selectedEntry != nil, let selectedIndex else { return nil }
        return selectedIndex >= localRows.count ? .suggested : .corpus
    }

    /// The summary line after `Emoji`: the selected name, and Provider when
    /// the selection is a model pick.
    public var routeDetail: String? {
        guard let entry = selectedEntry else { return nil }
        return selectedOrigin == .suggested ? "Provider · \(entry.displayName)" : entry.displayName
    }

    /// Rows of global indices, ten to a row, sections kept apart, for 2-D moves.
    public var gridRows: [[Int]] {
        var result: [[Int]] = []
        for (start, count) in [(0, localRows.count), (localRows.count, suggestedRows.count)] where count > 0 {
            for offset in stride(from: 0, to: count, by: Self.columns) {
                result.append(Array((start + offset)..<(start + min(count, offset + Self.columns))))
            }
        }
        return result
    }

    private let corpus: EmojiCorpus?
    private let frequentSet: @MainActor () -> [EmojiEntry]
    private let record: @MainActor (EmojiEntry) -> Void
    private let suggest: Suggest
    private let automaticRequestsEnabled: @MainActor () -> Bool
    private var lastAutomaticRequestsEnabled: Bool
    private let debounce: Duration
    private let initialNotice: String?
    private var revision: UInt64 = 0
    private var work: Task<Void, Never>?

    public init(
        corpus: EmojiCorpus?,
        skinTone: OmniSkinTone = .none,
        debounce: Duration = .milliseconds(350),
        initialNotice: String? = nil,
        frequentSet: @escaping @MainActor () -> [EmojiEntry],
        record: @escaping @MainActor (EmojiEntry) -> Void = { _ in },
        automaticRequestsEnabled: @escaping @MainActor () -> Bool = { true },
        suggest: @escaping Suggest
    ) {
        self.corpus = corpus
        self.skinTone = skinTone
        self.debounce = debounce
        self.initialNotice = initialNotice
        self.frequentSet = frequentSet
        self.record = record
        self.automaticRequestsEnabled = automaticRequestsEnabled
        lastAutomaticRequestsEnabled = automaticRequestsEnabled()
        self.suggest = suggest
    }

    /// A copied emoji counts toward the frequent set.
    public func recordPick(_ entry: EmojiEntry) { record(entry) }

    public func open(input: String = "", notice: String? = nil) {
        invalidate()
        isOpen = true
        self.input = ""
        localRows = []
        suggestedRows = []
        selectedIndex = nil
        self.notice = notice ?? initialNotice
        error = nil
        inputChanged(input, preservingNotice: true)
    }

    public func close() {
        invalidate()
        isOpen = false
        input = ""
        localRows = []
        suggestedRows = []
        selectedIndex = nil
        notice = nil
        error = nil
        onChange?()
    }

    public func inputChanged(_ next: String) {
        inputChanged(next, preservingNotice: false)
    }

    private func inputChanged(_ next: String, preservingNotice: Bool, forceSuggestion: Bool = false) {
        guard isOpen else { return }
        invalidate()
        input = next
        if !preservingNotice { notice = nil }
        error = nil
        suggestedRows = []
        guard let corpus else {
            localRows = []
            selectedIndex = nil
            onChange?()
            return
        }
        guard next.count <= Self.maximumInputCharacters else {
            localRows = []
            selectedIndex = nil
            error = "Input is too long. Type less text."
            onChange?()
            return
        }
        guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localRows = frequentSet()
            selectedIndex = localRows.isEmpty ? nil : 0
            onChange?()
            return
        }
        let match = EmojiMatcher.search(next, in: corpus)
        localRows = match.rows
        selectedIndex = localRows.isEmpty ? nil : 0
        guard match.isThin else {
            onChange?()
            return
        }
        if !forceSuggestion && isManualMode { onChange?(); return }
        isSuggesting = true
        let requestRevision = revision
        onChange?()
        work = Task { [weak self, suggest, debounce] in
            do {
                if !forceSuggestion { try await Task.sleep(for: debounce) }
                guard !Task.isCancelled, let self, self.isCurrent(requestRevision) else { return }
                let picks = try await suggest(next)
                guard !Task.isCancelled, self.isCurrent(requestRevision) else { return }
                let shown = Set(self.localRows.map(\.emoji))
                self.suggestedRows = Array(picks.filter { !shown.contains($0.emoji) }.prefix(Self.maximumSuggestions))
                self.isSuggesting = false
                if !self.suggestedRows.isEmpty { self.selectedIndex = self.localRows.count }
                self.onChange?()
            } catch is CancellationError {
                // Editing and dismissal intentionally abandon older requests.
            } catch {
                guard let self, self.isCurrent(requestRevision) else { return }
                self.isSuggesting = false
                self.error = self.localRows.isEmpty
                    ? "Could not suggest emoji. Edit the description to try again."
                    : "Could not suggest emoji · local matches shown"
                self.onChange?()
            }
        }
    }

    public func suggestNow() {
        guard canSuggestManually else { return }
        inputChanged(input, preservingNotice: true, forceSuggestion: true)
    }

    public func refreshAutomaticRequestMode() {
        guard isOpen else { return }
        let enabled = automaticRequestsEnabled()
        guard enabled != lastAutomaticRequestsEnabled else { return }
        lastAutomaticRequestsEnabled = enabled
        if !enabled {
            if isSuggesting { invalidate(); suggestedRows = [] }
            onChange?()
        } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputChanged(input, preservingNotice: true)
        }
    }

    /// ←→ step through cells; ↑↓ keep the column and cross the hairline.
    public func moveSelection(columns dx: Int, rows dy: Int) {
        guard isOpen, !rows.isEmpty else { return }
        notice = nil
        let current = selectedIndex ?? 0
        if dx != 0 {
            selectedIndex = max(0, min(rows.count - 1, current + dx))
        } else if dy != 0 {
            let grid = gridRows
            if let row = grid.firstIndex(where: { $0.contains(current) }),
               let column = grid[row].firstIndex(of: current),
               grid.indices.contains(row + dy) {
                let target = grid[row + dy]
                selectedIndex = target[min(column, target.count - 1)]
            } else {
                selectedIndex = current
            }
        }
        onChange?()
    }

    public func select(_ index: Int) {
        guard isOpen, rows.indices.contains(index) else { return }
        notice = nil
        selectedIndex = index
        onChange?()
    }

    private func isCurrent(_ candidate: UInt64) -> Bool { isOpen && revision == candidate }

    private func invalidate() {
        revision &+= 1
        work?.cancel()
        work = nil
        isSuggesting = false
    }
}
