import Foundation

public struct CharacterRepresentation: Hashable, Sendable {
    public let label: String
    public let displayText: String
    public let insertionText: String

    public init(label: String, displayText: String, insertionText: String) {
        self.label = label
        self.displayText = displayText
        self.insertionText = insertionText
    }
}

public struct CharacterEntry: Hashable, Sendable {
    public let scalar: UInt32
    public let glyph: String
    public let name: String
    public let aliases: [String]
    public let block: String
    public let category: String
    public let since: String
    public let htmlName: String?
    public let confusables: [UInt32]

    public init(scalar: UInt32, name: String, aliases: [String], block: String,
                category: String, since: String, htmlName: String?, confusables: [UInt32]) {
        self.scalar = scalar
        self.glyph = Unicode.Scalar(scalar).map { String($0) } ?? ""
        let parts = name.split(separator: "-", maxSplits: 1)
        let base = String(parts[0])
        let sentence = base.hasPrefix("CJK ") ? "CJK " + base.dropFirst(4).lowercased()
                                             : base.prefix(1).uppercased() + base.dropFirst().lowercased()
        if parts.count == 2 {
            let suffix = parts[1].count >= 4 && parts[1].allSatisfy(\.isHexDigit)
                ? parts[1].uppercased() : parts[1].lowercased()
            self.name = sentence + "-" + suffix
        } else {
            self.name = sentence
        }
        self.aliases = aliases
        self.block = block
        self.category = category
        self.since = since
        self.htmlName = htmlName
        self.confusables = confusables
    }

    public var codePoint: String { String(format: "U+%04X", scalar) }
    public var displayGlyph: String {
        category.hasPrefix("Mark,") ? "\u{25CC}" + glyph : glyph
    }

    public var representations: [CharacterRepresentation] {
        let decimal = "&#\(scalar);"
        let named = htmlName.map { "&" + $0 }
        let code = String(format: "%04X", scalar)
        let brace = "\\u{\(code)}"
        let escape: String
        if scalar <= 0xFFFF {
            escape = "\\u\(code)"
        } else {
            let value = scalar - 0x10000
            escape = String(format: "\\u%04X\\u%04X", 0xD800 + value / 0x400, 0xDC00 + value % 0x400)
        }
        let bytes = glyph.utf8.map { String(format: "%02X", $0) }.joined(separator: " ")
        var result = [
            CharacterRepresentation(label: "Glyph", displayText: displayGlyph, insertionText: glyph),
            CharacterRepresentation(label: "Code point", displayText: codePoint, insertionText: codePoint),
            CharacterRepresentation(label: "HTML", displayText: named.map { "\($0) · \(decimal)" } ?? decimal,
                                    insertionText: named ?? decimal),
            CharacterRepresentation(label: "Escape", displayText: "\(escape) · \(brace)", insertionText: escape),
            CharacterRepresentation(label: "UTF-8", displayText: bytes, insertionText: bytes)
        ]
        let visible = confusables.prefix(3).compactMap { code -> String? in
            guard let scalar = Unicode.Scalar(code) else { return nil }
            let glyph: String
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: glyph = "\u{25CC}" + String(scalar)
            default: glyph = String(scalar)
            }
            return "\(glyph) U+\(String(format: "%04X", code))"
        }
        if let first = confusables.first, let scalar = Unicode.Scalar(first), !visible.isEmpty {
            result.append(CharacterRepresentation(label: "Looks like", displayText: visible.joined(separator: " · "),
                                                  insertionText: String(scalar)))
        }
        return result
    }
}

public enum CharacterCorpusError: Error, Equatable {
    case missingResource
    case invalid(String)
}

public enum CharacterIdentification: Hashable, Sendable {
    case character(CharacterEntry)
    case emoji
    case unavailable
}

/// Unicode 17.0 assigned non-Emoji_Presentation scalars, bundled for offline use.
public struct CharacterCorpus: Sendable {
    public static let resourceName = "character-corpus-en"
    public let entries: [CharacterEntry]
    private let byScalar: [UInt32: Int]
    private let byName: [String: Int]
    private let emojiPresentation: Set<UInt32>
    fileprivate let index: [CharacterIndexRow]
    fileprivate let postings: [String: [Int]]
    fileprivate let searchWords: [String]

    public init(entries: [CharacterEntry], emojiPresentation: Set<UInt32> = []) {
        self.entries = entries
        self.emojiPresentation = emojiPresentation
        self.byScalar = Dictionary(entries.enumerated().map { ($0.element.scalar, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var names: [String: Int] = [:]
        for (position, entry) in entries.enumerated() {
            let nameKey = EmojiText.nameKey(entry.name)
            if names[nameKey] == nil { names[nameKey] = position }
        }
        for (position, entry) in entries.enumerated() {
            for alias in entry.aliases {
                let aliasKey = EmojiText.nameKey(alias)
                if names[aliasKey] == nil { names[aliasKey] = position }
            }
        }
        self.byName = names
        let blockWords = Dictionary(uniqueKeysWithValues: Set(entries.map(\.block)).map { block in
            (block, Set(EmojiText.words(EmojiText.normalize(block))))
        })
        let index = entries.enumerated().map {
            CharacterIndexRow($0.element, position: $0.offset, blockWords: blockWords[$0.element.block] ?? [])
        }
        self.index = index
        var postings: [String: [Int]] = [:]
        for row in index {
            for word in Set(row.nameWords).union(row.aliasWords).union(row.blockWords) {
                // Algorithmic names end in the code point, which direct identify handles.
                // Keeping all of those hex words would dominate the vocabulary.
                if word == row.hex && row.name.hasSuffix(word) { continue }
                postings[word, default: []].append(row.position)
            }
        }
        self.postings = postings
        self.searchWords = Array(postings.keys)
    }

    public init(data: Data) throws {
        struct Payload: Decodable {
            let version: Int
            let unicodeVersion: String
            let blocks: [String]
            let categories: [String]
            let emojiPresentation: [[UInt32]]
            let rows: [Row]
        }
        struct Row: Decodable {
            let scalar: UInt32
            let name: String
            let aliases: [String]
            let block: Int
            let category: Int
            let since: String
            let htmlName: String?
            let confusables: [UInt32]

            init(from decoder: Decoder) throws {
                var row = try decoder.unkeyedContainer()
                scalar = try row.decode(UInt32.self)
                name = try row.decode(String.self)
                aliases = try row.decode([String].self)
                block = try row.decode(Int.self)
                category = try row.decode(Int.self)
                since = try row.decode(String.self)
                htmlName = try row.decodeIfPresent(String.self)
                confusables = try row.decode([UInt32].self)
                guard row.isAtEnd else { throw CharacterCorpusError.invalid("extra row fields") }
            }
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw CharacterCorpusError.invalid("\(error)") }
        guard payload.version == 1, payload.unicodeVersion == "17.0.0" else {
            throw CharacterCorpusError.invalid("unsupported corpus version")
        }
        var previous: UInt32 = 0
        let entries = try payload.rows.enumerated().map { offset, row -> CharacterEntry in
            guard payload.blocks.indices.contains(row.block), payload.categories.indices.contains(row.category),
                  Unicode.Scalar(row.scalar) != nil, !row.name.isEmpty, !row.since.isEmpty,
                  (offset == 0 || row.scalar > previous) else {
                throw CharacterCorpusError.invalid("row \(offset)")
            }
            previous = row.scalar
            return CharacterEntry(scalar: row.scalar, name: row.name, aliases: row.aliases,
                                  block: payload.blocks[row.block], category: payload.categories[row.category],
                                  since: row.since, htmlName: row.htmlName, confusables: row.confusables)
        }
        var emojiPresentation: Set<UInt32> = []
        for range in payload.emojiPresentation {
            guard range.count == 2, range[0] <= range[1], range[1] <= 0x10FFFF else {
                throw CharacterCorpusError.invalid("emoji presentation range")
            }
            emojiPresentation.formUnion(range[0]...range[1])
        }
        self.init(entries: entries, emojiPresentation: emojiPresentation)
    }

    public static let shared: Result<CharacterCorpus, CharacterCorpusError> = {
        do { return .success(try bundled()) }
        catch let error as CharacterCorpusError { return .failure(error) }
        catch { return .failure(.invalid("\(error)")) }
    }()

    public static func bundled() throws -> CharacterCorpus {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json") else {
            throw CharacterCorpusError.missingResource
        }
        return try CharacterCorpus(data: Data(contentsOf: url))
    }

    public func entry(for scalar: UInt32) -> CharacterEntry? { byScalar[scalar].map { entries[$0] } }
    public func entry(named name: String) -> CharacterEntry? {
        byName[EmojiText.nameKey(name)].map { entries[$0] }
    }

    /// Accept an exact U+ or 0x code point (4–6 hex digits) or one glyph.
    /// A recognized emoji sequence returns `.emoji`; other multi-scalar input is not identification.
    public func identify(_ input: String) -> CharacterIdentification? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pattern = #"^(?:U\+|0x)?[0-9A-Fa-f]{4,6}$"#
        if text.range(of: pattern, options: .regularExpression) != nil {
            let digits = text.hasPrefix("U+") || text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
            guard let value = UInt32(digits, radix: 16), Unicode.Scalar(value) != nil else { return .unavailable }
            if let entry = entry(for: value) { return .character(entry) }
            if emojiPresentation.contains(value) { return .emoji }
            if case .success(let emoji) = EmojiCorpus.shared,
               emoji.entry(for: String(Unicode.Scalar(value)!)) != nil { return .emoji }
            return .unavailable
        }
        guard text.count == 1 else { return nil }
        if text.unicodeScalars.count == 1, let value = text.unicodeScalars.first?.value {
            if let entry = entry(for: value) { return .character(entry) }
            if emojiPresentation.contains(value) { return .emoji }
            if case .success(let emoji) = EmojiCorpus.shared, emoji.entry(for: text) != nil { return .emoji }
            return .unavailable
        }
        if text.unicodeScalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x200D }) { return .emoji }
        if case .success(let emoji) = EmojiCorpus.shared, emoji.entry(for: text) != nil { return .emoji }
        return .unavailable
    }
}

public struct CharacterMatch: Sendable, Equatable {
    public let strong: [CharacterEntry]
    public let weak: [CharacterEntry]
    public let hasQuery: Bool
    public var rows: [CharacterEntry] { strong + weak }
    public var isThin: Bool { hasQuery && strong.count < CharacterMatcher.thinThreshold }
}

public enum CharacterMatcher {
    public static let thinThreshold = 3
    public static let resultLimit = 200
    public static let weakLimit = 10

    public static func search(_ query: String, in corpus: CharacterCorpus) -> CharacterMatch {
        if let identified = corpus.identify(query) {
            switch identified {
            case .character(let entry):
                return CharacterMatch(strong: [entry], weak: [], hasQuery: true)
            case .emoji, .unavailable:
                return CharacterMatch(strong: [], weak: [], hasQuery: true)
            }
        }
        let phrase = EmojiText.normalize(query)
        let terms = EmojiText.terms(phrase)
        guard !terms.isEmpty else { return CharacterMatch(strong: [], weak: [], hasQuery: false) }
        var strong: [(score: Int, words: Int, position: Int)] = []
        var weak: [(hits: Int, score: Int, position: Int)] = []
        var candidates: Set<Int> = []
        for term in terms {
            var matchingWords = corpus.searchWords.filter { $0.hasPrefix(term) }
            if matchingWords.isEmpty {
                matchingWords = corpus.searchWords.filter { EmojiText.near(term, $0) }
            }
            for word in matchingWords {
                candidates.formUnion(corpus.postings[word] ?? [])
            }
        }
        // Partial hex prefixes are useful while typing U+2191.
        if terms.count == 1, terms[0].allSatisfy(\.isHexDigit), terms[0].count >= 2 {
            for row in corpus.index where row.hex.hasPrefix(terms[0]) { candidates.insert(row.position) }
        }
        for position in candidates {
            let row = corpus.index[position]
            var score = 0
            var hits = 0
            for term in terms {
                let value = row.score(term)
                if value > 0 { hits += 1; score += value }
            }
            guard hits > 0 else { continue }
            if hits == terms.count {
                if row.name == phrase { score += 20 }
                else if terms.count > 1, row.name.hasPrefix(phrase) { score += 6 }
                strong.append((score, row.nameWords.count, row.position))
            } else {
                weak.append((hits, score, row.position))
            }
        }
        strong.sort { ($1.score, $0.words, $0.position) < ($0.score, $1.words, $1.position) }
        let found = strong.prefix(resultLimit).map { corpus.entries[$0.position] }
        guard found.count < thinThreshold, terms.count > 1 else {
            return CharacterMatch(strong: found, weak: [], hasQuery: true)
        }
        weak.sort { ($1.hits, $1.score, $0.position) < ($0.hits, $0.score, $1.position) }
        return CharacterMatch(strong: found,
                              weak: weak.prefix(weakLimit).map { corpus.entries[$0.position] }, hasQuery: true)
    }
}

fileprivate struct CharacterIndexRow: Sendable {
    let position: Int
    let name: String
    let nameWords: [String]
    let aliasWords: Set<String>
    let blockWords: Set<String>
    let hex: String

    init(_ entry: CharacterEntry, position: Int, blockWords: Set<String>) {
        self.position = position
        name = EmojiText.normalize(entry.name)
        nameWords = EmojiText.words(name)
        aliasWords = Set(entry.aliases.flatMap { EmojiText.words(EmojiText.normalize($0)) })
        self.blockWords = blockWords
        hex = String(entry.codePoint.dropFirst(2)).lowercased()
    }

    func score(_ term: String) -> Int {
        if term == hex || term == "u" + hex { return 20 }
        if nameWords.contains(term) { return 8 }
        if nameWords.contains(where: { $0.hasPrefix(term) }) { return 5 }
        if aliasWords.contains(term) { return 6 }
        if aliasWords.contains(where: { $0.hasPrefix(term) }) { return 4 }
        if blockWords.contains(term) { return 3 }
        if blockWords.contains(where: { term.count >= 3 && $0.hasPrefix(term) }) { return 2 }
        if nameWords.contains(where: { EmojiText.near(term, $0) }) { return 1 }
        return 0
    }
}
