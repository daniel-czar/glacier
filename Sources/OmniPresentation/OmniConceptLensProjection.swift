import Foundation

public struct OmniConceptLensNearMiss: Sendable, Equatable {
    public let name: String
    public let distinction: String

    public init(name: String, distinction: String) {
        self.name = name
        self.distinction = distinction
    }
}

/// Display-ready values. Projection validates provider output before constructing a map.
public struct OmniConceptLensMap: Sendable, Equatable {
    public let name: String
    public let field: String?
    public let definition: String?
    public let parents: [String]
    public let siblings: [String]
    public let children: [String]
    public let related: [String]
    public let nearMisses: [OmniConceptLensNearMiss]

    public init(
        name: String, field: String? = nil, definition: String? = nil,
        parents: [String] = [], siblings: [String] = [], children: [String] = [],
        related: [String] = [], nearMisses: [OmniConceptLensNearMiss] = []
    ) {
        self.name = name
        self.field = field
        self.definition = definition
        self.parents = parents
        self.siblings = siblings
        self.children = children
        self.related = related
        self.nearMisses = nearMisses
    }
}

/// One completed Concept Lens response, with copyable text even when the JSON is unusable.
public struct OmniConceptLensProjection: Sendable, Equatable {
    public let map: OmniConceptLensMap?
    public let text: String
    public let failureReason: String?

    public static func project(_ response: String, input: String) -> Self {
        let fallbackName = term(response: input) ?? "Concept"
        let received = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !received.isEmpty else {
            return fallback(name: fallbackName, reason: "Concept Lens returned an empty result.")
        }

        let candidate = unfencedJSON(received)
        guard let data = candidate.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if looksLikeJSON(received) {
                return Self(map: nil, text: received, failureReason: "Concept Lens returned invalid JSON; showing the received text.")
            }
            return Self(map: nil, text: received, failureReason: "Concept Lens returned plain text.")
        }

        let map = OmniConceptLensMap(
            name: term(value: object["name"]) ?? fallbackName,
            field: nonemptyString(object["field"]),
            definition: validDefinition(object["definition"]),
            parents: terms(object["parents"], limit: 3),
            siblings: terms(object["siblings"], limit: 4),
            children: terms(object["children"], limit: 5),
            related: terms(object["related"], limit: 5),
            nearMisses: nearMisses(object["nearMisses"])
        )
        guard term(value: object["name"]) != nil || map.field != nil || map.definition != nil || !map.parents.isEmpty ||
                !map.siblings.isEmpty || !map.children.isEmpty || !map.related.isEmpty ||
                !map.nearMisses.isEmpty else {
            return Self(map: nil, text: received, failureReason: "Concept Lens returned no usable map fields; showing the received text.")
        }
        return Self(map: map, text: projectedText(map), failureReason: nil)
    }

    private static func fallback(name: String, reason: String) -> Self {
        Self(map: nil, text: "Name: \(name)\n\(reason)", failureReason: reason)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func term(value: Any?) -> String? {
        guard let value = nonemptyString(value) else { return nil }
        return term(response: value)
    }

    private static func term(response: String) -> String? {
        guard let value = nonemptyString(response) else { return nil }
        return value.split(separator: " ").count <= 3 ? value : nil
    }

    private static func validDefinition(_ value: Any?) -> String? {
        guard let value = nonemptyString(value),
              value.split(separator: " ").count <= 25,
              let last = value.last, ".!?".contains(last) else { return nil }
        // A sentence boundary followed by more text means the provider supplied
        // multiple sentences. Internal punctuation without a space remains valid.
        guard value.range(of: #"[.!?]+\s+\S"#, options: .regularExpression) == nil else { return nil }
        return value
    }

    private static func terms(_ value: Any?, limit: Int) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return Array(values.compactMap { term(value: $0) }.prefix(limit))
    }

    private static func nearMisses(_ value: Any?) -> [OmniConceptLensNearMiss] {
        guard let values = value as? [Any] else { return [] }
        return Array(values.compactMap { entry -> OmniConceptLensNearMiss? in
            guard let entry = entry as? [String: Any],
                  let name = term(value: entry["name"]),
                  let distinction = nonemptyString(entry["distinction"]),
                  distinction.split(separator: " ").count <= 6 else { return nil }
            return OmniConceptLensNearMiss(name: name, distinction: distinction)
        }.prefix(4))
    }

    /// The same concise order used for copy and the drawn view's accessibility text.
    public static func projectedText(_ map: OmniConceptLensMap) -> String {
        var lines = ["Name: \(map.name)"]
        if let field = map.field { lines.append("Field: \(field)") }
        if let definition = map.definition { lines.append("Definition: \(definition)") }
        if !map.parents.isEmpty { lines.append("Parents: \(map.parents.joined(separator: ", "))") }
        if !map.siblings.isEmpty {
            lines.append("Siblings: \(map.siblings.prefix(2).joined(separator: ", "))")
        }
        if !map.children.isEmpty { lines.append("Children: \(map.children.joined(separator: ", "))") }
        if !map.nearMisses.isEmpty {
            lines.append("Near misses:")
            lines.append(contentsOf: map.nearMisses.map { "\($0.name) — \($0.distinction)" })
        }
        if !map.related.isEmpty { lines.append("Related: \(map.related.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    private static func unfencedJSON(_ response: String) -> String {
        guard response.hasPrefix("```"), response.hasSuffix("```"),
              let firstNewline = response.firstIndex(of: "\n") else { return response }
        return String(response[response.index(after: firstNewline)..<response.index(response.endIndex, offsetBy: -3)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeJSON(_ response: String) -> Bool {
        response.hasPrefix("{") || response.hasPrefix("[") || response.hasPrefix("```")
    }
}
