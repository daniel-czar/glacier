import Foundation

public struct OmniMapParsedInput: Sendable, Equatable {
    public let query: String
    public let pinnedForm: OmniMapForm?
    public let candidateForms: [OmniMapForm]
    /// A phrase heuristic is advice, never an explicit user mode.
    public let suggestedForm: OmniMapForm?
    /// UTF-16 range of the explicit `as <form>` mode token in the original input.
    public let modeRange: NSRange?
    public let refusal: String?

    public init(query: String, pinnedForm: OmniMapForm?, candidateForms: [OmniMapForm], modeRange: NSRange?, refusal: String?, suggestedForm: OmniMapForm? = nil) {
        self.query = query
        self.pinnedForm = pinnedForm
        self.candidateForms = candidateForms
        self.suggestedForm = suggestedForm
        self.modeRange = modeRange
        self.refusal = refusal
    }
}

public enum OmniMapInput {
    private static let nativeAliases: [(String, OmniMapForm)] = [
        ("causal loop", .loop), ("mind map", .radial),
        ("analogy", .bridge), ("continuum", .spectrum), ("process", .flow),
        ("table", .matrix), ("tree", .tree), ("radial", .radial),
        ("bridge", .bridge), ("matrix", .matrix), ("spectrum", .spectrum),
        ("loop", .loop), ("flow", .flow)
    ]

    private static let refusedAliases: [(String, String, OmniMapForm)] = [
        ("stock-and-flow", "stock-and-flow", .loop),
        ("stock and flow", "stock-and-flow", .loop),
        ("entity-relationship", "entity–relationship", .tree),
        ("entity relationship", "entity–relationship", .tree),
        ("er diagram", "entity–relationship", .tree),
        ("er", "entity–relationship", .tree),
        ("venn diagram", "Venn", .matrix),
        ("venn", "Venn", .matrix),
        ("ontology", "ontology", .tree),
        ("nested", "nested", .tree),
        ("affinity", "affinity", .radial)
    ]

    public static func parse(_ text: String, pinnedForm: OmniMapForm? = nil) -> OmniMapParsedInput {
        let original = text
        let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `as <form>` is a terminal mode token, not a subject mention.
        for (alias, name, suggestion) in refusedAliases {
            if let range = terminalMode(alias, in: original) {
                let query = original.replacingCharacters(in: Range(range, in: original)!, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(query: query, pinnedForm: nil, candidateForms: [], modeRange: range,
                             refusal: "Map · no native form for \(article(name)) \(name) · try \(suggestion.title)")
            }
        }
        // Also refuse direct commands that name a requested non-native diagram.
        let lower = bare.lowercased()
        for (alias, name, suggestion) in refusedAliases {
            let requested = #"^(?:(?:please\s+)?(?:(?:can|could|would)\s+you\s+(?:please\s+)?)?(?:draw|make|create|show|map)\s+(?:me\s+)?(?:a|an|the)?\s*|i\s+(?:need|want)\s+(?:a|an|the)?\s*)"#
                + NSRegularExpression.escapedPattern(for: alias) + #"(?![\p{L}\p{N}])"#
            if lower.range(of: requested, options: .regularExpression) != nil {
                return .init(query: bare, pinnedForm: nil, candidateForms: [], modeRange: nil,
                             refusal: "Map · no native form for \(article(name)) \(name) · try \(suggestion.title)")
            }
        }
        for (alias, name, suggestion) in refusedAliases {
            if lower == alias || lower.hasPrefix(alias + " of ") || lower.hasPrefix(alias + " for ") {
                return .init(query: bare, pinnedForm: nil, candidateForms: [], modeRange: nil,
                             refusal: "Map · no native form for \(article(name)) \(name) · try \(suggestion.title)")
            }
        }
        for (alias, form) in nativeAliases {
            if let range = terminalMode(alias, in: original) {
                let query = original.replacingCharacters(in: Range(range, in: original)!, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(query: query, pinnedForm: form, candidateForms: [], modeRange: range, refusal: nil)
            }
        }
        if let pinnedForm { return .init(query: bare, pinnedForm: pinnedForm, candidateForms: [], modeRange: nil, refusal: nil) }
        if lower.range(of: #"\b(explain\s+.+\s+to\s+.+|.+\s+for\s+a[n]?\s+.+)\b"#, options: .regularExpression) != nil {
            return .init(query: bare, pinnedForm: nil, candidateForms: [], modeRange: nil, refusal: nil, suggestedForm: .bridge)
        }
        if lower.range(of: #"^\s*(why|should)\b"#, options: .regularExpression) != nil {
            return .init(query: bare, pinnedForm: nil, candidateForms: [], modeRange: nil, refusal: nil, suggestedForm: .tree)
        }
        if lower.range(of: #"\bvs\.?\b"#, options: .regularExpression) != nil {
            return .init(query: bare, pinnedForm: nil, candidateForms: [.matrix, .bridge], modeRange: nil, refusal: nil)
        }
        return .init(query: bare, pinnedForm: nil, candidateForms: [], modeRange: nil, refusal: nil)
    }

    private static func terminalMode(_ alias: String, in text: String) -> NSRange? {
        let escaped = NSRegularExpression.escapedPattern(for: alias).replacingOccurrences(of: "\\ ", with: #"[ -]"#)
        guard let regex = try? NSRegularExpression(pattern: "\\bas\\s+(?:a|an)?\\s*" + escaped + "[?.!,;:]*\\s*$", options: [.caseInsensitive]) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range
    }

    private static func article(_ name: String) -> String {
        name.lowercased().hasPrefix("ontology") || name.lowercased().hasPrefix("affinity") || name.lowercased().hasPrefix("entity") ? "an" : "a"
    }
}
