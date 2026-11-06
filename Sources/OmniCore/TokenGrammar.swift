import Foundation

/// One slash token `/<name>[:<value>]`. The name is a manifest identifier;
/// the value, when present, is glued with `:` and may itself contain colons.
public struct SlashAtom: Sendable, Equatable {
    public let name: String
    public let value: String?
    public let literal: String

    public var token: String { "/\(name)" }

    public static func parse(_ raw: String) -> SlashAtom? {
        guard raw.count > 1, raw.first == "/" else { return nil }
        let rest = raw.dropFirst()
        if let colon = rest.firstIndex(of: ":") {
            let name = String(rest[..<colon])
            guard isTokenName(name) else { return nil }
            let value = String(rest[rest.index(after: colon)...])
            return SlashAtom(name: name, value: value, literal: raw)
        }
        let name = String(rest)
        guard isTokenName(name) else { return nil }
        return SlashAtom(name: name, value: nil, literal: raw)
    }

    public static func isTokenName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

public enum LengthUnit: String, Codable, Sendable, Equatable {
    case percent = "%"
    case words = "w"
    case sentences = "s"
}

public struct LengthValue: Sendable, Equatable {
    public let magnitude: Decimal
    public let unit: LengthUnit

    public init(magnitude: Decimal, unit: LengthUnit) {
        self.magnitude = magnitude
        self.unit = unit
    }

    public var canonical: String { "\(Self.render(magnitude))\(unit.rawValue)" }

    /// Accepts only the literal shapes the grammar names: `[0-9]+` or
    /// `[0-9]+.[0-9]+`, optionally unit-suffixed. `Decimal(string:)` is only
    /// consulted after that check because it parses a numeric prefix and
    /// silently ignores the rest (`0.5abc` → 0.5).
    public static func parse(_ raw: String) -> LengthValue? {
        guard let last = raw.last else { return nil }
        if let unit = LengthUnit(rawValue: String(last)) {
            return parseNumber(String(raw.dropLast()), as: unit)
        }
        if isStrictDecimal(raw) {
            guard let value = Decimal(string: raw), value > 0, value <= 1 else { return nil }
            return LengthValue(magnitude: value * 100, unit: .percent)
        }
        guard isStrictInteger(raw), let integer = Int(raw) else { return nil }
        return LengthValue(magnitude: Decimal(integer), unit: .percent)
    }

    private static func parseNumber(_ raw: String, as unit: LengthUnit) -> LengthValue? {
        guard isStrictInteger(raw) || isStrictDecimal(raw), let value = Decimal(string: raw) else { return nil }
        return LengthValue(magnitude: value, unit: unit)
    }

    /// `[0-9]+` in ASCII digits only.
    static func isStrictInteger(_ raw: String) -> Bool {
        !raw.isEmpty && raw.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `[0-9]+.[0-9]+`: exactly one point with digits on both sides.
    static func isStrictDecimal(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { isStrictInteger(String($0)) }
    }

    private static func render(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        if value == Decimal(number.intValue) {
            return String(number.intValue)
        }
        return number.stringValue
    }
}

public enum TokenValue: Sendable, Equatable {
    case enumMember(String)
    case length(LengthValue)
    case int(Int)
    case langcode(String)

    public var canonical: String {
        switch self {
        case .enumMember(let value), .langcode(let value): value
        case .length(let value): value.canonical
        case .int(let value): String(value)
        }
    }
}

extension TokenValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value, unit, magnitude
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "enum":
            self = .enumMember(try container.decode(String.self, forKey: .value))
        case "langcode":
            self = .langcode(try container.decode(String.self, forKey: .value))
        case "int":
            self = .int(try container.decode(Int.self, forKey: .value))
        case "length":
            let magnitude = try container.decode(Decimal.self, forKey: .magnitude)
            let unit = try container.decode(LengthUnit.self, forKey: .unit)
            self = .length(LengthValue(magnitude: magnitude, unit: unit))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown token value type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .enumMember(let value):
            try container.encode("enum", forKey: .type)
            try container.encode(value, forKey: .value)
        case .langcode(let value):
            try container.encode("langcode", forKey: .type)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode("int", forKey: .type)
            try container.encode(value, forKey: .value)
        case .length(let value):
            try container.encode("length", forKey: .type)
            try container.encode(value.magnitude, forKey: .magnitude)
            try container.encode(value.unit, forKey: .unit)
        }
    }
}

public struct TokenValueSpec: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case length
        case langcode
        case int
        case enumRegistry = "enum"
        case time
    }

    public let type: Kind
    public let registry: String?
    public let required: Bool

    public init(type: Kind, registry: String? = nil, required: Bool) {
        self.type = type
        self.registry = registry
        self.required = required
    }
}

public struct ManifestValueTypes: Codable, Sendable, Equatable {
    public struct LengthType: Codable, Sendable, Equatable {
        public let units: [String]
        public let defaultUnit: String
        enum CodingKeys: String, CodingKey {
            case units
            case defaultUnit = "default_unit"
        }
    }

    public struct LangcodeType: Codable, Sendable, Equatable {
        public let codes: [String]
    }

    public let length: LengthType?
    public let langcode: LangcodeType?
    public let enums: [String: [String]]

    public static let empty = ManifestValueTypes(length: nil, langcode: nil, enums: [:])

    enum CodingKeys: String, CodingKey {
        case length, langcode
        case enums = "enum"
    }

    public init(length: LengthType?, langcode: LangcodeType?, enums: [String: [String]]) {
        self.length = length
        self.langcode = langcode
        self.enums = enums
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        length = try container.decodeIfPresent(LengthType.self, forKey: .length)
        langcode = try container.decodeIfPresent(LangcodeType.self, forKey: .langcode)
        enums = try container.decodeIfPresent([String: [String]].self, forKey: .enums) ?? [:]
    }
}

public enum TokenValueValidation: Sendable, Equatable {
    case omitted
    case accepted(TokenValue)
    case invalid
}

public enum TokenValueNormalizer {
    public static func canonicalizeLangcode(_ raw: String) -> String {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let language = parts.first, !language.isEmpty else { return raw.lowercased() }
        if parts.count == 1 { return language.lowercased() }
        return language.lowercased() + "-" + parts.dropFirst().joined(separator: "-").uppercased()
    }

    public static func validate(
        raw: String?,
        spec: TokenValueSpec,
        types: ManifestValueTypes
    ) -> TokenValueValidation {
        guard let raw else { return .omitted }
        if raw.isEmpty { return .invalid }
        switch spec.type {
        case .length:
            guard let length = LengthValue.parse(raw) else { return .invalid }
            if let allowed = types.length?.units, !allowed.contains(length.unit.rawValue) {
                return .invalid
            }
            return .accepted(.length(length))
        case .langcode:
            let canonical = canonicalizeLangcode(raw)
            guard let codes = types.langcode?.codes, codes.contains(canonical) else { return .invalid }
            return .accepted(.langcode(canonical))
        case .int:
            guard let value = Int(raw), String(value) == raw else { return .invalid }
            return .accepted(.int(value))
        case .enumRegistry:
            guard let registry = spec.registry, let members = types.enums[registry], members.contains(raw) else {
                return .invalid
            }
            return .accepted(.enumMember(raw))
        case .time:
            return .invalid
        }
    }
}

public enum SlashTokenSyntax {
    public static func payloadText(from text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { atom in
                atom != "✓" && atom != "✗" && SlashAtom.parse(atom) == nil
            }
            .joined(separator: " ")
    }
}
