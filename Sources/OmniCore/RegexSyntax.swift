import Foundation

public struct RegexNode: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case sequence
        case alternation
        case literal(String)
        case characterClass(String)
        case anchor(String)
        case quantified(label: String, minimum: Int, maximum: Int?)
        case group(String?)
        case lookaround(String)
        case backreference(Int)
        case namedBackreference(String)
        case flags(String)
    }

    public let kind: Kind
    /// The exact pattern fragment represented by this node, for hover help.
    public let raw: String
    public let children: [RegexNode]

    public init(kind: Kind, raw: String, children: [RegexNode] = []) {
        self.kind = kind
        self.raw = raw
        self.children = children
    }
}

public struct RegexParseResult: Sendable, Equatable {
    public let root: RegexNode
    public let groupCount: Int
    public let flagsSummary: [String]
    public let anchored: Bool
}

public struct RegexParseFailure: Error, Sendable, Equatable, LocalizedError {
    public let reason: String
    public let characterOffset: Int

    public var errorDescription: String? { reason }
}

/// Parses the documented diagram subset. Compilation remains NSRegularExpression's authority.
public struct RegexSyntaxParser {
    private let characters: [Character]
    private var offset = 0
    private var groupCount = 0
    private var flags: [String] = []
    private var nestingDepth = 0

    public init(pattern: String) { characters = Array(pattern) }

    public mutating func parse() throws -> RegexParseResult {
        let root = try expression(until: nil)
        if offset < characters.count { throw fail("Unexpected token") }
        return .init(root: root, groupCount: groupCount, flagsSummary: flags,
                     anchored: Self.startsAnchored(root))
    }

    private mutating func expression(until terminator: Character?) throws -> RegexNode {
        let start = offset
        var branches: [RegexNode] = []
        var items: [RegexNode] = []
        var branchStart = start
        while let character = peek(), character != terminator {
            if character == "|" {
                branches.append(.init(kind: .sequence, raw: raw(start: branchStart, end: offset), children: items))
                items = []
                offset += 1
                branchStart = offset
                continue
            }
            if character == ")" { throw fail("Unmatched closing parenthesis") }
            let item = try atom()
            items.append(try quantifier(after: item))
        }
        branches.append(.init(kind: .sequence, raw: raw(start: branchStart, end: offset), children: items))
        if branches.count == 1 { return branches[0] }
        return .init(kind: .alternation, raw: raw(start: start, end: offset), children: branches)
    }

    private mutating func atom() throws -> RegexNode {
        let start = offset
        guard let character = take() else { throw fail("Expected a pattern item") }
        switch character {
        case "[":
            var escaped = false
            while let next = take() {
                if escaped { escaped = false; continue }
                if next == "\\" { escaped = true; continue }
                if next == "]" {
                    let token = raw(start: start, end: offset)
                    return .init(kind: .characterClass(Self.classLabel(token)), raw: token)
                }
                if next == "[" { throw fail("Nested character classes are not diagrammed") }
            }
            throw RegexParseFailure(reason: "Unclosed character class", characterOffset: start)
        case "(": return try group(start: start)
        case "^", "$": return .init(kind: .anchor(character == "^" ? "start" : "end"), raw: String(character))
        case ".": return .init(kind: .characterClass("any"), raw: ".")
        case "\\": return try escape(start: start)
        case "*", "+", "?", "{": throw RegexParseFailure(reason: "Quantifier has no item", characterOffset: start)
        case "}": throw RegexParseFailure(reason: "Unexpected closing brace", characterOffset: start)
        default: return .init(kind: .literal(String(character)), raw: String(character))
        }
    }

    private mutating func escape(start: Int) throws -> RegexNode {
        guard let next = take() else { throw RegexParseFailure(reason: "Trailing backslash", characterOffset: start) }
        let token = raw(start: start, end: offset)
        switch next {
        case "d": return .init(kind: .characterClass("digit"), raw: token)
        case "D": return .init(kind: .characterClass("not digit"), raw: token)
        case "w": return .init(kind: .characterClass("word"), raw: token)
        case "W": return .init(kind: .characterClass("not word"), raw: token)
        case "s": return .init(kind: .characterClass("space"), raw: token)
        case "S": return .init(kind: .characterClass("not space"), raw: token)
        case "b": return .init(kind: .anchor("word boundary"), raw: token)
        case "B": return .init(kind: .anchor("not boundary"), raw: token)
        case "1"..."9":
            while let digit = peek(), digit.isNumber { offset += 1 }
            return .init(kind: .backreference(Int(raw(start: start + 1, end: offset)) ?? 0),
                         raw: raw(start: start, end: offset))
        case "k":
            guard take() == "<" else { throw RegexParseFailure(reason: "Unsupported escape \(token)", characterOffset: start) }
            let nameStart = offset
            while let character = peek(), character != ">" { offset += 1 }
            guard offset > nameStart, take() == ">" else {
                throw RegexParseFailure(reason: "Unclosed named backreference", characterOffset: start)
            }
            return .init(kind: .namedBackreference(raw(start: nameStart, end: offset - 1)),
                         raw: raw(start: start, end: offset))
        case "n": return .init(kind: .literal("newline"), raw: token)
        case "r": return .init(kind: .literal("return"), raw: token)
        case "t": return .init(kind: .literal("tab"), raw: token)
        case "f": return .init(kind: .literal("form feed"), raw: token)
        case "v": return .init(kind: .literal("vertical tab"), raw: token)
        default:
            if next.isLetter || next.isNumber { throw RegexParseFailure(reason: "Unsupported escape \(token)", characterOffset: start) }
            return .init(kind: .literal(String(next)), raw: token)
        }
    }

    private mutating func group(start: Int) throws -> RegexNode {
        guard nestingDepth < 16 else {
            throw RegexParseFailure(reason: "Nesting is too deep to diagram", characterOffset: start)
        }
        nestingDepth += 1
        var label: String? = nil
        var kind: RegexNode.Kind? = nil
        if peek() == "?" {
            offset += 1
            if peek() == ":" { offset += 1 }
            else if peek() == "=" { offset += 1; kind = .lookaround("followed by") }
            else if peek() == "!" { offset += 1; kind = .lookaround("not followed by") }
            else if peek() == "<" {
                offset += 1
                if peek() == "=" { offset += 1; kind = .lookaround("preceded by") }
                else if peek() == "!" { offset += 1; kind = .lookaround("not preceded by") }
                else {
                    let nameStart = offset
                    while let character = peek(), character != ">" { offset += 1 }
                    guard peek() == ">", offset > nameStart else { throw fail("Unclosed named group") }
                    let name = raw(start: nameStart, end: offset)
                    guard name.first?.isLetter == true,
                          name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                        throw fail("Invalid group name")
                    }
                    offset += 1
                    groupCount += 1
                    label = "group \(name)"
                }
            } else if let character = peek(), "imsxU-d".contains(character) {
                let flagStart = offset
                while let flag = peek(), "imsxU-d".contains(flag) { offset += 1 }
                let token = raw(start: flagStart, end: offset)
                guard !token.isEmpty else { throw fail("Invalid flags") }
                let parts = token.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count <= 2 else { throw fail("Invalid flags") }
                let enabled = Self.flagLabels(String(parts[0]))
                let disabled = parts.count == 2 ? Self.flagLabels(String(parts[1])) : []
                if enabled.contains("comments and spacing") {
                    throw RegexParseFailure(reason: "Extended-spacing mode is not diagrammed", characterOffset: start)
                }
                if peek() == ")" {
                    offset += 1
                    flags.removeAll { disabled.contains($0) }
                    for flag in enabled where !flags.contains(flag) { flags.append(flag) }
                    nestingDepth -= 1
                    return .init(kind: .flags(token), raw: raw(start: start, end: offset))
                }
                guard peek() == ":" else { throw fail("Unsupported inline flag syntax") }
                offset += 1
                for flag in enabled where !flags.contains("scoped \(flag)") {
                    flags.append("scoped \(flag)")
                }
                label = "flags \(token)"
            } else { throw fail("Unsupported group syntax") }
        } else {
            groupCount += 1
            label = "group \(groupCount)"
        }
        let content = try expression(until: ")")
        guard take() == ")" else { throw RegexParseFailure(reason: "Unclosed group", characterOffset: start) }
        nestingDepth -= 1
        return .init(kind: kind ?? .group(label), raw: raw(start: start, end: offset), children: [content])
    }

    private mutating func quantifier(after item: RegexNode) throws -> RegexNode {
        guard let character = peek(), "*+?{".contains(character) else { return item }
        let start = offset
        var label: String
        var minimum: Int
        var maximum: Int?
        if character == "{" {
            offset += 1
            let countStart = offset
            while let digit = peek(), digit.isNumber { offset += 1 }
            guard offset > countStart else { throw fail("Invalid count quantifier") }
            let lower = raw(start: countStart, end: offset)
            minimum = Int(lower) ?? 0
            if peek() == "," {
                offset += 1
                let upperStart = offset
                while let digit = peek(), digit.isNumber { offset += 1 }
                let upper = raw(start: upperStart, end: offset)
                if let first = Int(lower), let last = Int(upper), last < first { throw fail("Count range is reversed") }
                maximum = upper.isEmpty ? nil : Int(upper)
                label = upper.isEmpty ? "\(lower)+" : "\(lower)–\(upper)×"
            } else { maximum = minimum; label = "\(lower)×" }
            guard take() == "}" else { throw fail("Unclosed count quantifier") }
        } else {
            offset += 1
            switch character {
            case "*": label = "0 or more"; minimum = 0; maximum = nil
            case "+": label = "1 or more"; minimum = 1; maximum = nil
            default: label = "optional"; minimum = 0; maximum = 1
            }
        }
        if peek() == "?" { offset += 1; label += " · lazy" }
        if let next = peek(), "*+?{".contains(next) { throw fail("Unsupported or repeated quantifier") }
        return .init(kind: .quantified(label: label, minimum: minimum, maximum: maximum),
                     raw: item.raw + raw(start: start, end: offset), children: [item])
    }

    private func peek() -> Character? { offset < characters.count ? characters[offset] : nil }
    private mutating func take() -> Character? {
        guard let next = peek() else { return nil }
        offset += 1
        return next
    }
    private func raw(start: Int, end: Int) -> String { String(characters[start..<end]) }
    private func fail(_ reason: String) -> RegexParseFailure { .init(reason: reason, characterOffset: offset) }

    private static func startsAnchored(_ node: RegexNode) -> Bool {
        if case .alternation = node.kind {
            return !node.children.isEmpty && node.children.allSatisfy(startsAnchored)
        }
        if case .sequence = node.kind {
            for child in node.children {
                if case .flags = child.kind { continue }
                if case .anchor("start") = child.kind { return true }
                if case .group = child.kind, let content = child.children.first {
                    return startsAnchored(content)
                }
                return false
            }
        }
        return false
    }

    private static func flagLabels(_ token: String) -> [String] {
        token.compactMap { character in
            switch character {
            case "i": "case-insensitive"
            case "m": "multiline"
            case "s": "dot matches newline"
            case "x": "comments and spacing"
            case "U": "Unicode word boundaries"
            default: nil
            }
        }
    }

    private static func classLabel(_ raw: String) -> String {
        var content = String(raw.dropFirst().dropLast())
        let negated = content.hasPrefix("^")
        if negated { content.removeFirst() }
        let named: [(String, String)] = [("A-Z", "A–Z"), ("a-z", "a–z"), ("0-9", "0–9"),
                                         (#"\d"#, "digit"), (#"\w"#, "word"), (#"\s"#, "space")]
        var parts: [String] = []
        while !content.isEmpty {
            guard let found = named.first(where: { content.hasPrefix($0.0) }) else { return raw }
            parts.append(found.1)
            content.removeFirst(found.0.count)
        }
        guard !parts.isEmpty else { return raw }
        let label = parts.joined(separator: ", ")
        return negated ? "not \(label)" : label
    }
}
