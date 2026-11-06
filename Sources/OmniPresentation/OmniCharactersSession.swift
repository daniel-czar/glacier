import Foundation
import OmniCore

public enum OmniCharactersOrigin: Sendable, Equatable {
    case corpus
    case suggested
}

/// Local Unicode search and identify state. Each edit and dismissal invalidates
/// any late suggestion, including a request that ignores cancellation.
@MainActor
public final class OmniCharactersSession {
    public typealias Suggest = @Sendable (String) async throws -> [CharacterEntry]
    public static let columns = 10
    public static let maximumInputCharacters = 512
    public static let maximumSuggestions = 5

    public var onChange: (@MainActor () -> Void)?
    public private(set) var input = ""
    public private(set) var isOpen = false
    public private(set) var localRows: [CharacterEntry] = []
    public private(set) var suggestedRows: [CharacterEntry] = []
    public private(set) var identifiedEntry: CharacterEntry?
    public private(set) var selectedIndex: Int?
    public private(set) var selectedRepresentationIndex = 0
    public private(set) var isSuggesting = false
    public private(set) var notice: String?
    public private(set) var error: String?

    public var rows: [CharacterEntry] { localRows + suggestedRows }
    public var representations: [CharacterRepresentation] { identifiedEntry?.representations ?? [] }
    public var selectedRepresentation: CharacterRepresentation? {
        guard isOpen, identifiedEntry != nil, representations.indices.contains(selectedRepresentationIndex) else { return nil }
        return representations[selectedRepresentationIndex]
    }
    public var selectedEntry: CharacterEntry? {
        guard isOpen else { return nil }
        if let identifiedEntry { return identifiedEntry }
        guard let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }
    public var selectedText: String? {
        guard let entry = selectedEntry else { return nil }
        return identifiedEntry == nil ? entry.glyph : selectedRepresentation?.insertionText
    }
    public var selectedOrigin: OmniCharactersOrigin? {
        guard identifiedEntry == nil, selectedEntry != nil, let selectedIndex else { return nil }
        return selectedIndex >= localRows.count ? .suggested : .corpus
    }
    public var routeDetail: String? {
        guard let entry = selectedEntry, let selectedText else { return nil }
        let source = selectedOrigin == .suggested ? "Provider · " : ""
        let block = identifiedEntry == nil ? " · \(entry.block)" : ""
        return "\(source)\(selectedText) · \(entry.name) · \(entry.codePoint)\(block)"
    }
    public var gridRows: [[Int]] {
        var result: [[Int]] = []
        for (start, count) in [(0, localRows.count), (localRows.count, suggestedRows.count)] where count > 0 {
            for offset in stride(from: 0, to: count, by: Self.columns) {
                result.append(Array((start + offset)..<(start + min(count, offset + Self.columns))))
            }
        }
        return result
    }

    private let corpus: CharacterCorpus?
    private let frequentSet: @MainActor () -> [CharacterEntry]
    private let record: @MainActor (CharacterEntry) -> Void
    private let suggest: Suggest?
    private let debounce: Duration
    private let initialNotice: String?
    private var revision: UInt64 = 0
    private var work: Task<Void, Never>?

    public init(corpus: CharacterCorpus?, debounce: Duration = .milliseconds(350), initialNotice: String? = nil,
                frequentSet: @escaping @MainActor () -> [CharacterEntry],
                record: @escaping @MainActor (CharacterEntry) -> Void = { _ in },
                suggest: Suggest? = nil) {
        self.corpus = corpus
        self.debounce = debounce
        self.initialNotice = initialNotice
        self.frequentSet = frequentSet
        self.record = record
        self.suggest = suggest
    }

    public func recordPick(_ entry: CharacterEntry) { record(entry) }

    public func open(input: String = "", notice: String? = nil) {
        invalidate()
        isOpen = true
        self.input = ""
        localRows = []
        suggestedRows = []
        identifiedEntry = nil
        selectedIndex = nil
        selectedRepresentationIndex = 0
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
        identifiedEntry = nil
        selectedIndex = nil
        selectedRepresentationIndex = 0
        notice = nil
        error = nil
        onChange?()
    }

    public func inputChanged(_ next: String) { inputChanged(next, preservingNotice: false) }

    private func inputChanged(_ next: String, preservingNotice: Bool) {
        guard isOpen else { return }
        invalidate()
        input = next
        if !preservingNotice { notice = nil }
        error = nil
        localRows = []
        suggestedRows = []
        identifiedEntry = nil
        selectedIndex = nil
        selectedRepresentationIndex = 0
        guard let corpus else { onChange?(); return }
        guard next.count <= Self.maximumInputCharacters else {
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
        if let identification = corpus.identify(next) {
            switch identification {
            case .character(let entry):
                identifiedEntry = entry
                onChange?()
                return
            case .emoji:
                notice = "that's an emoji · try em"
                onChange?()
                return
            case .unavailable:
                notice = "No character for this input."
                onChange?()
                return
            }
        }
        let match = CharacterMatcher.search(next, in: corpus)
        localRows = match.rows
        selectedIndex = localRows.isEmpty ? nil : 0
        guard match.isThin, let suggest else { onChange?(); return }
        isSuggesting = true
        let requestRevision = revision
        onChange?()
        work = Task { [weak self, debounce] in
            do {
                try await Task.sleep(for: debounce)
                guard !Task.isCancelled, let self, self.isCurrent(requestRevision) else { return }
                let picks = try await suggest(next)
                guard !Task.isCancelled, self.isCurrent(requestRevision) else { return }
                let shown = Set(self.localRows.map(\.scalar))
                var seen = shown
                self.suggestedRows = Array(picks.compactMap { corpus.entry(for: $0.scalar) }
                    .filter { seen.insert($0.scalar).inserted }.prefix(Self.maximumSuggestions))
                self.isSuggesting = false
                if !self.suggestedRows.isEmpty { self.selectedIndex = self.localRows.count }
                self.onChange?()
            } catch is CancellationError {
                // Editing and dismissal intentionally abandon older requests.
            } catch {
                guard let self, self.isCurrent(requestRevision) else { return }
                self.isSuggesting = false
                self.error = self.localRows.isEmpty
                    ? "Could not suggest characters. Edit the description to try again."
                    : "Could not suggest characters · local matches shown"
                self.onChange?()
            }
        }
    }

    /// In identify mode only vertical arrows step through representation rows.
    public func moveSelection(columns dx: Int, rows dy: Int) {
        guard isOpen else { return }
        notice = nil
        if identifiedEntry != nil {
            guard dy != 0, !representations.isEmpty else { return }
            selectedRepresentationIndex = max(0, min(representations.count - 1, selectedRepresentationIndex + dy))
            onChange?()
            return
        }
        guard !rows.isEmpty else { return }
        let current = selectedIndex ?? 0
        if dx != 0 {
            selectedIndex = max(0, min(rows.count - 1, current + dx))
        } else if dy != 0 {
            let grid = gridRows
            if let row = grid.firstIndex(where: { $0.contains(current) }),
               let column = grid[row].firstIndex(of: current), grid.indices.contains(row + dy) {
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

    public func selectRepresentation(_ index: Int) {
        guard isOpen, identifiedEntry != nil, representations.indices.contains(index) else { return }
        notice = nil
        selectedRepresentationIndex = index
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
