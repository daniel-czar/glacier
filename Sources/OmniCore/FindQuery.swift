import Foundation

// `/find` as the descriptive surface (D2, decision surface 569d5a7cf925cbd7):
// an exact id, picked `key:value` filters, and free words. Everything here is
// visible text; filters are plain words, never a new token (the token
// grammar's "UI helpers insert visible text only").

/// The three facets the completion menu offers after `/find`. Their keys
/// and matching mirror `retrieve docs` (`~/Tooling/retrieval/frontmatter.py`).
public enum FindFacet: String, CaseIterable, Sendable, Codable, Hashable {
    case kind
    /// `in:X` is `retrieve`'s sugar for `projects:project_X`.
    case project = "in"
    case tags

    /// The text the person types or picks: `kind:`, `in:`, `tags:`.
    public var prefix: String { rawValue + ":" }
}

public struct FindFilter: Sendable, Equatable, Hashable, Codable {
    public let facet: FindFacet
    public let value: String

    public init(facet: FindFacet, value: String) {
        self.facet = facet
        self.value = value
    }

    /// `kind:review`, the stored, copied and re-run form.
    public var text: String { facet.prefix + value }

    /// A whole word that is a complete filter: a known key, a colon and a
    /// non-empty value. Keys are case-sensitive, as in `retrieve`.
    public init?(word: some StringProtocol) {
        guard let colon = word.firstIndex(of: ":") else { return nil }
        let key = String(word[..<colon])
        let value = String(word[word.index(after: colon)...])
        guard let facet = FindFacet(rawValue: key), !value.isEmpty else { return nil }
        self.init(facet: facet, value: value)
    }
}

/// What `/find` was asked, parsed from its payload (the text after the token).
public struct FindQuery: Sendable, Equatable {
    /// Which tier answers: an exact id resolves locally (tier 1), filters
    /// alone run locally (tier 2), free words go to the model for a query
    /// unless `/offline` (tier 3).
    public enum Tier: String, Sendable, Codable, Equatable {
        case id
        case filters
        case words
    }

    /// Set when the whole payload is one id address (D1); tier 1.
    public let address: OmniIDAddress?
    public let filters: [FindFilter]
    /// Free words, in order.
    public let terms: [String]
    /// Why this payload is refused before any tier runs, or nil: an id
    /// beside other words (an id is found on its own and never reaches a
    /// model, D1), or a facet key with no value yet (`kind:`).
    public let refusal: String?

    public init(payload: String) {
        // An id pasted in quotes or backticks is still an id: tier 1 (the
        // one normaliser unwraps it, as the launcher and the service do).
        if let address = OmniIDAddress(payload) {
            self.address = address
            filters = []
            terms = []
            refusal = nil
            return
        }
        address = nil
        var filters: [FindFilter] = []
        var terms: [String] = []
        var refusal: String?
        for word in payload.split(whereSeparator: \.isWhitespace) {
            if Self.containsID(word) {
                // Beside words, wrapped, or as a filter value: never a term or
                // a filter a model would see.
                refusal = refusal ?? "An id is found on its own · remove the other words"
            } else if let filter = FindFilter(word: word) {
                filters.append(filter)
            } else if word.hasSuffix(":"), let facet = FindFacet(rawValue: String(word.dropLast())) {
                refusal = refusal ?? "Pick a value for \(facet.prefix)"
            } else {
                terms.append(String(word))
            }
        }
        self.filters = filters
        self.terms = terms
        self.refusal = refusal
    }

    public init(filters: [FindFilter], terms: [String]) {
        address = nil
        self.filters = filters
        self.terms = terms
        refusal = nil
    }

    private static let idRun = try! NSRegularExpression(pattern: "(?<![0-9A-Za-z])[0-9A-Fa-f]{16}(?![0-9A-Za-z])")

    /// Whether a word holds a 16-hex run, in either case, with no letter or
    /// digit on either side: an id however it is wrapped.
    static func containsID(_ word: some StringProtocol) -> Bool {
        let text = String(word)
        return idRun.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    public var tier: Tier {
        if address != nil { return .id }
        return terms.isEmpty ? .filters : .words
    }

    /// Whether running this payload online asks a model: words, and nothing
    /// refused.
    public var asksModel: Bool { tier == .words && refusal == nil }

    public var isEmpty: Bool { address == nil && filters.isEmpty && terms.isEmpty }

    /// The plain text this query reads as, filters first: what is stored,
    /// shown on the route line and re-run.
    public var text: String {
        if let address { return (address.namespace.map { $0.rawValue + ":" } ?? "") + address.id }
        return (filters.map(\.text) + terms).joined(separator: " ")
    }

    /// The query with `typed` filters as hard constraints (D2, tier 3): every
    /// typed filter stays; a model filter on a key the person typed is
    /// dropped rather than ANDed into an empty result; the model's terms
    /// replace the typed words it translated.
    public static func constrained(typed: FindQuery, translated: FindQuery) -> FindQuery {
        let typedKeys = Set(typed.filters.map(\.facet))
        var filters = typed.filters
        for filter in translated.filters where !typedKeys.contains(filter.facet) && !filters.contains(filter) {
            filters.append(filter)
        }
        return FindQuery(filters: filters, terms: translated.terms)
    }
}

/// A complete, index-known filter span inside `/find`'s visible text: the
/// pills of D2 are drawn over exactly these ranges (rendering only).
public struct FindFilterSpan: Sendable, Equatable {
    public let filter: FindFilter
    /// UTF-16 range of the whole `key:value` word in the visible text.
    public let range: NSRange
    /// UTF-16 length of `key:` within it.
    public let keyLength: Int

    /// Every whole `key:value` word after the `/find` (or `/retrieve`) token
    /// whose value the index knows. A half-typed value (`kind:rev`), an
    /// unknown key or value, and anything before the token are not spans, so
    /// they read as plain text.
    public static func spans(in text: String, facets: FindFacets) -> [FindFilterSpan] {
        guard text.contains("/find") || text.contains("/retrieve") else { return [] }
        let source = text as NSString
        var spans: [FindFilterSpan] = []
        var afterToken = false
        for match in wordPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let word = source.substring(with: match.range)
            guard afterToken else {
                afterToken = word == "/find" || word == "/retrieve"
                continue
            }
            guard let filter = FindFilter(word: word), facets.knows(filter) else { continue }
            // The last word, still being typed, whose value begins a longer
            // known value (`note` on the way to `notebook`): no pill until a
            // space ends it, so it never flickers on and off.
            if match.range.upperBound == source.length,
               facets.values(for: filter.facet).contains(where: { $0.value.count > filter.value.count && $0.value.hasPrefix(filter.value) }) {
                continue
            }
            spans.append(FindFilterSpan(filter: filter, range: match.range, keyLength: (filter.facet.prefix as NSString).length))
        }
        return spans
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\S+"#)
}
