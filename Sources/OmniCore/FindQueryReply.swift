import Foundation

/// The model's whole contribution to `/find` in words (D2, tier 3): a query
/// in the filter grammar plus free-text terms, nothing else. Both broker
/// validators and the module use this one parser, so a reply that carries
/// anything more (rows, paths, prose, extra keys) is invalid everywhere and
/// no row can originate from the model.
///
/// Shape: `{"filters":"kind:review in:helios","terms":"adversarial ml"}`.
public struct FindQueryReply: Sendable, Equatable {
    public static let maximumFilterCharacters = 300
    public static let maximumTermCharacters = 200
    public static let keys: Set<String> = ["filters", "terms"]

    public let filters: [FindFilter]
    public let terms: [String]

    /// The query the reply asks for, before the typed filters constrain it.
    public var query: FindQuery { FindQuery(filters: filters, terms: terms) }

    public static func parse(_ text: String) -> FindQueryReply? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { return nil }
        // Nothing outside the object but whitespace or a code fence.
        let outside = (String(text[..<start]) + String(text[text.index(after: end)...]))
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard outside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard Set(object.keys).isSubset(of: keys), let filterText = (object["filters"] ?? "") as? String else { return nil }
        let termText = (object["terms"] ?? "") as? String
        guard let termText,
              filterText.count <= maximumFilterCharacters, termText.count <= maximumTermCharacters,
              !filterText.contains(where: \.isNewline), !termText.contains(where: \.isNewline),
              // No control or format characters (bidi overrides, zero-width
              // joiners): the query is shown on the route line as written.
              !(filterText + termText).unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) })
        else { return nil }
        var filters: [FindFilter] = []
        for word in filterText.split(whereSeparator: \.isWhitespace) {
            // Every word of the filters line is a complete, known filter.
            guard let filter = FindFilter(word: word) else { return nil }
            if !filters.contains(filter) { filters.append(filter) }
        }
        let terms = termText.split(whereSeparator: \.isWhitespace).map(String.init)
        // A filter hidden among the terms is not a term.
        guard !terms.contains(where: { FindFilter(word: $0) != nil }) else { return nil }
        // An empty object is still only a query: "nothing to add", which the
        // prompt asks for when the typed filters say it all. The module never
        // runs it as an empty query.
        return FindQueryReply(filters: filters, terms: terms)
    }
}
