import Foundation

/// One base emoji from the bundled CLDR corpus. Skin-tone variants are not
/// entries: they collapse into the base, which renders in the system default.
public struct EmojiEntry: Hashable, Sendable {
    public let emoji: String
    /// The CLDR short name, e.g. `waving hand`.
    public let name: String
    public let keywords: [String]
    public let group: String
    public let subgroup: String
    /// Unicode's emoji order; the stable tie-break.
    public let order: Int

    public init(emoji: String, name: String, keywords: [String], group: String, subgroup: String, order: Int) {
        self.emoji = emoji
        self.name = name
        self.keywords = keywords
        self.group = group
        self.subgroup = subgroup
        self.order = order
    }

    /// The summary line's form: `Waving hand`, `OK hand`, `Flag: Germany`.
    public var displayName: String { name.prefix(1).uppercased() + name.dropFirst() }
}

public enum EmojiCorpusError: Error, Equatable {
    case missingResource
    case invalid(String)
}

/// The bundled corpus (Unicode CLDR 47 English annotations over Emoji 16.0),
/// with its search index built once at load. Search never needs the network.
public struct EmojiCorpus: Sendable {
    public static let resourceName = "emoji-corpus-en"
    public let entries: [EmojiEntry]
    let index: [EmojiIndexRow]
    private let byName: [String: Int]
    private let byLooseName: [String: Int?]
    private let byEmoji: [String: Int]

    public init(entries: [EmojiEntry]) {
        self.entries = entries
        index = entries.enumerated().map { EmojiIndexRow($0.element, position: $0.offset) }
        byName = Dictionary(entries.enumerated().map { (EmojiText.nameKey($0.element.name), $0.offset) }, uniquingKeysWith: { first, _ in first })
        // nil marks a loose key that more than one name folds to.
        byLooseName = Dictionary(entries.enumerated().map { (EmojiText.normalize($0.element.name), Optional($0.offset)) },
                                 uniquingKeysWith: { _, _ in nil })
        byEmoji = Dictionary(entries.enumerated().map { (EmojiText.bare($0.element.emoji), $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    public init(data: Data) throws {
        struct Payload: Decodable {
            struct Row: Decodable { let e: String; let n: String; let k: [String]; let g: Int; let s: Int }
            let version: Int
            let groups: [String]
            let subgroups: [String]
            let emoji: [Row]
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch { throw EmojiCorpusError.invalid("\(error)") }
        guard payload.version == 1 else { throw EmojiCorpusError.invalid("version \(payload.version)") }
        let entries = try payload.emoji.enumerated().map { offset, row in
            guard payload.groups.indices.contains(row.g), payload.subgroups.indices.contains(row.s),
                  !row.e.isEmpty, !row.n.isEmpty else { throw EmojiCorpusError.invalid("row \(offset)") }
            return EmojiEntry(emoji: row.e, name: row.n, keywords: row.k,
                              group: payload.groups[row.g], subgroup: payload.subgroups[row.s], order: offset)
        }
        self.init(entries: entries)
    }

    /// Parsed and indexed once per process; the host touches it at launch.
    public static let shared: Result<EmojiCorpus, EmojiCorpusError> = {
        do { return .success(try bundled()) }
        catch let error as EmojiCorpusError { return .failure(error) }
        catch { return .failure(.invalid("\(error)")) }
    }()

    /// Reads the copy packaged in OmniCore's resource bundle.
    public static func bundled() throws -> EmojiCorpus {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json") else {
            throw EmojiCorpusError.missingResource
        }
        return try EmojiCorpus(data: Data(contentsOf: url))
    }

    /// A CLDR name, case-, quote- and spacing-insensitive. Model picks must
    /// pass this. A punctuation-blind match (`flag Germany`) counts only when
    /// it names one emoji, so `keycap *` cannot become `keycap #`.
    public func entry(named name: String) -> EmojiEntry? {
        if let exact = byName[EmojiText.nameKey(name)] { return entries[exact] }
        guard let loose = byLooseName[EmojiText.normalize(name)], let loose else { return nil }
        return entries[loose]
    }

    /// The base entry for an emoji string, ignoring variation selectors and tones.
    public func entry(for emoji: String) -> EmojiEntry? {
        byEmoji[EmojiText.bare(emoji)].map { entries[$0] }
    }
}

/// Result of one local search. Only `strong` rows (every meaningful term
/// matched) count toward the thin threshold; `weak` rows match some terms
/// and are shown, capped, only when the result is thin.
public struct EmojiMatch: Sendable, Equatable {
    public let strong: [EmojiEntry]
    public let weak: [EmojiEntry]
    public let hasQuery: Bool

    public var rows: [EmojiEntry] { strong + weak }
    /// Fewer than three real matches: the description goes to the model.
    public var isThin: Bool { hasQuery && strong.count < EmojiMatcher.thinThreshold }
}

/// Fuzzy, instant search over names, keywords and group names. Categories
/// are search terms (`food`, `flag`, `hand`), not tabs.
public enum EmojiMatcher {
    public static let thinThreshold = 3
    /// More cells than anyone scrolls; keeps a one-letter query cheap to draw.
    public static let resultLimit = 200
    public static let weakLimit = 10

    public static func search(_ query: String, in corpus: EmojiCorpus) -> EmojiMatch {
        let phrase = EmojiText.normalize(query)
        let terms = EmojiText.terms(phrase)
        guard !terms.isEmpty else { return EmojiMatch(strong: [], weak: [], hasQuery: false) }
        var strong: [(score: Int, words: Int, position: Int)] = []
        var weak: [(hits: Int, score: Int, position: Int)] = []
        for row in corpus.index {
            var score = 0
            var hits = 0
            for term in terms {
                let value = row.score(term)
                if value > 0 { hits += 1; score += value }
            }
            guard hits > 0 else { continue }
            if hits == terms.count {
                // The prefix bonus completes a typed phrase (`waving h`); for
                // one word it would favour `handshake` over `waving hand`.
                if row.name == phrase { score += 20 } else if terms.count > 1, row.name.hasPrefix(phrase) { score += 6 }
                if row.keywordPhrases.contains(phrase) { score += 4 }
                strong.append((score, row.nameWords.count, row.position))
            } else {
                weak.append((hits, score, row.position))
            }
        }
        // Shorter names are the more specific answer (`waving hand` before
        // `face with hand over mouth`); Unicode order breaks the rest.
        strong.sort { ($1.score, $0.words, $0.position) < ($0.score, $1.words, $1.position) }
        let strongEntries = strong.prefix(resultLimit).map { corpus.entries[$0.position] }
        guard strongEntries.count < thinThreshold, terms.count > 1 else {
            return EmojiMatch(strong: strongEntries, weak: [], hasQuery: true)
        }
        weak.sort { ($1.hits, $1.score, $0.position) < ($0.hits, $0.score, $1.position) }
        return EmojiMatch(strong: strongEntries, weak: weak.prefix(weakLimit).map { corpus.entries[$0.position] }, hasQuery: true)
    }
}

/// Precomputed, normalized search fields for one entry.
struct EmojiIndexRow: Sendable {
    /// Index into `EmojiCorpus.entries`, which is in Unicode order.
    let position: Int
    let name: String
    let nameWords: [String]
    let keywordPhrases: Set<String>
    let keywordWords: Set<String>
    let groupWords: Set<String>

    init(_ entry: EmojiEntry, position: Int) {
        self.position = position
        name = EmojiText.normalize(entry.name)
        nameWords = EmojiText.words(name)
        let phrases = entry.keywords.map(EmojiText.normalize)
        keywordPhrases = Set(phrases)
        keywordWords = Set(phrases.flatMap(EmojiText.words))
        groupWords = Set(EmojiText.words(EmojiText.normalize(entry.group + " " + entry.subgroup)))
    }

    /// Name beats keyword beats group; exact beats prefix beats one typo.
    func score(_ term: String) -> Int {
        var value = 0
        if nameWords.contains(term) { value += 6 }
        else if nameWords.contains(where: { $0.hasPrefix(term) }) { value += 4 }
        else if nameWords.contains(where: { EmojiText.near(term, $0) }) { value += 1 }
        if keywordWords.contains(term) || keywordPhrases.contains(term) { value += 5 }
        else if keywordWords.contains(where: { $0.hasPrefix(term) }) { value += 3 }
        else if keywordWords.contains(where: { EmojiText.near(term, $0) }) { value += 1 }
        if groupWords.contains(term) || term.count >= 3 && groupWords.contains(where: { $0.hasPrefix(term) }) { value += 2 }
        return value
    }
}

enum EmojiText {
    private static let stopWords: Set<String> = ["a", "an", "the", "and", "or", "but", "of", "with", "in", "on", "to", "for", "is", "it", "i", "im", "am", "my", "me", "so", "very", "bit", "kind", "sort", "really", "just", "that", "this", "at", "as", "be"]

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The exact-name key: case, diacritics, apostrophe style and spacing
    /// fold, symbols stay, so `keycap: *` and `keycap: #` remain distinct.
    static func nameKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func words(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    /// Stop words drop only while something meaningful remains, so a first
    /// typed letter (`a` on the way to `angry`) still searches.
    static func terms(_ normalized: String) -> [String] {
        let all = words(normalized)
        let meaningful = all.filter { !stopWords.contains($0) }
        return Array(NSOrderedSet(array: meaningful.isEmpty ? all : meaningful)) as? [String] ?? []
    }

    /// The emoji without variation selectors or skin-tone modifiers.
    static func bare(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { scalar in
            scalar.value != 0xFE0F && scalar.value != 0xFE0E && !(0x1F3FB...0x1F3FF).contains(scalar.value)
        }))
    }

    /// One typo (or an adjacent swap) in words of four or more letters.
    static func near(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count >= 4, rhs.count >= 4, abs(lhs.count - rhs.count) <= 1 else { return false }
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count == 1 { return true }
            guard differences.count == 2 else { return false }
            let first = differences[0]
            let second = differences[1]
            return second == first + 1 && a[first] == b[second] && a[second] == b[first]
        }
        let longer = a.count > b.count ? a : b
        let shorter = a.count > b.count ? b : a
        var index = 0
        var skipped = false
        for character in longer {
            if index < shorter.count, character == shorter[index] { index += 1 }
            else if skipped { return false }
            else { skipped = true }
        }
        return index == shorter.count
    }
}

/// The Emoji tool's only stored state: its own corpus ordering. Each pick adds
/// one to a score that halves every `halfLife`, so old favourites fade (O23).
public struct EmojiFrequency: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var score: Double
        public var updated: Date
    }

    public static let halfLife: TimeInterval = 30 * 86_400
    public static let setSize = 20
    static let retained = 200
    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    public static func decayed(_ entry: Entry, at now: Date) -> Double {
        entry.score * pow(0.5, max(0, now.timeIntervalSince(entry.updated)) / halfLife)
    }

    public mutating func record(_ emoji: String, at now: Date) {
        let key = EmojiText.bare(emoji)
        guard !key.isEmpty else { return }
        let current = entries[key].map { Self.decayed($0, at: now) } ?? 0
        entries[key] = Entry(score: current + 1, updated: now)
        guard entries.count > Self.retained else { return }
        let kept = ranked(at: now).prefix(Self.retained)
        entries = entries.filter { kept.contains($0.key) }
    }

    /// Bare emoji keys, most picked first; the more recent pick wins a tie.
    public func ranked(at now: Date) -> [String] {
        entries.map { (key: $0.key, score: Self.decayed($0.value, at: now), updated: $0.value.updated) }
            .sorted { ($1.score, $1.updated, $0.key) < ($0.score, $0.updated, $1.key) }
            .map(\.key)
    }

    /// The empty-query set: up to two rows of corpus entries.
    public func frequentSet(in corpus: EmojiCorpus, at now: Date) -> [EmojiEntry] {
        Array(ranked(at: now).lazy.compactMap { corpus.entry(for: $0) }.prefix(Self.setSize))
    }
}
