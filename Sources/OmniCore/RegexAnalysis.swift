import Foundation

public enum RegexInputClassification: Sendable, Equatable {
    case pattern
    case prose
    case invalidPattern(reason: String)

    public static func classify(_ input: String) -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .prose }
        let metacharacters = CharacterSet(charactersIn: "\\[](){}*+?|^$.")
        let hasMetacharacter = input.unicodeScalars.contains { metacharacters.contains($0) }
        guard hasMetacharacter else { return .prose }
        guard input.count <= 4096 else { return .invalidPattern(reason: "Pattern exceeds 4096 characters") }
        do {
            _ = try NSRegularExpression(pattern: input)
            return .pattern
        } catch {
            return .invalidPattern(reason: error.localizedDescription)
        }
    }
}

public struct RegexAnalysis: Sendable, Equatable {
    public enum DiagramStatus: Sendable, Equatable { case available, tooLong, unparsable }

    public let pattern: String
    public let groupCount: Int
    public let anchored: Bool
    public let flagsSummary: [String]
    public let metadataIsReliable: Bool
    public let ast: RegexNode?
    public let parseFailure: String?
    public let compileFailure: String?
    public let diagramStatus: DiagramStatus

    public init(pattern: String) {
        self.pattern = pattern
        let expression: NSRegularExpression?
        let compilationError: String?
        do { expression = try NSRegularExpression(pattern: pattern); compilationError = nil }
        catch { expression = nil; compilationError = error.localizedDescription }
        compileFailure = compilationError
        groupCount = expression?.numberOfCaptureGroups ?? 0
        if let compilationError {
            ast = nil
            parseFailure = compilationError
            diagramStatus = .unparsable
            anchored = false
            flagsSummary = []
            metadataIsReliable = false
            return
        }

        if pattern.count > 200 {
            ast = nil
            parseFailure = nil
            diagramStatus = .tooLong
            var parser = RegexSyntaxParser(pattern: pattern)
            if let parsed = try? parser.parse() {
                anchored = parsed.anchored
                flagsSummary = Array(Set(parsed.flagsSummary)).sorted()
                metadataIsReliable = true
            } else {
                let fallback = Self.prefixMetadata(pattern)
                anchored = fallback.anchored
                flagsSummary = fallback.flags
                metadataIsReliable = false
            }
            return
        }
        do {
            var parser = RegexSyntaxParser(pattern: pattern)
            let parsed = try parser.parse()
            ast = parsed.root
            parseFailure = nil
            diagramStatus = .available
            anchored = parsed.anchored
            flagsSummary = Array(Set(parsed.flagsSummary)).sorted()
            metadataIsReliable = true
        } catch {
            ast = nil
            parseFailure = (error as? RegexParseFailure)?.reason ?? error.localizedDescription
            diagramStatus = .unparsable
            let fallback = Self.prefixMetadata(pattern)
            anchored = fallback.anchored
            flagsSummary = fallback.flags
            metadataIsReliable = false
        }
    }

    private static func prefixMetadata(_ pattern: String) -> (anchored: Bool, flags: [String]) {
        let characters = Array(pattern)
        var branchStarts = [0]
        var depth = 0
        var inClass = false
        var escaped = false
        for (index, character) in characters.enumerated() {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "[" { inClass = true; continue }
            if character == "]" && inClass { inClass = false; continue }
            if inClass { continue }
            if character == "(" { depth += 1; continue }
            if character == ")" { depth -= 1; continue }
            if character == "|" && depth == 0 { branchStarts.append(index + 1) }
        }
        func flagLabel(_ flag: Character) -> String? {
            switch flag {
            case "i": "case-insensitive"
            case "m": "multiline"
            case "s": "dot matches newline"
            case "x": "comments and spacing"
            default: nil
            }
        }
        var activeFlags: Set<String> = []
        var leadingCursor = 0
        while leadingCursor + 3 < characters.count && characters[leadingCursor] == "("
                && characters[leadingCursor + 1] == "?" {
            let flagStart = leadingCursor + 2
            var end = flagStart
            while end < characters.count && "imsxU-".contains(characters[end]) { end += 1 }
            guard end > flagStart && end < characters.count && characters[end] == ")" else { break }
            let parts = String(characters[flagStart..<end]).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { break }
            for flag in parts[0] { if let label = flagLabel(flag) { activeFlags.insert(label) } }
            if parts.count == 2 {
                for flag in parts[1] { if let label = flagLabel(flag) { activeFlags.remove(label) } }
            }
            leadingCursor = end + 1
        }
        let anchored = branchStarts.allSatisfy { start in
            var cursor = start == 0 ? leadingCursor : start
            while cursor + 3 < characters.count && characters[cursor] == "("
                    && characters[cursor + 1] == "?" {
                let flagStart = cursor + 2
                var end = flagStart
                while end < characters.count && "imsU-".contains(characters[end]) { end += 1 }
                guard end > flagStart && end < characters.count && characters[end] == ")" else { break }
                cursor = end + 1
            }
            return cursor < characters.count && characters[cursor] == "^"
        }
        return (anchored, activeFlags.sorted())
    }

}

public struct RegexSelectionMatches: Sendable, Equatable {
    public struct Match: Sendable, Equatable {
        /// UTF-16 range in `Line.text`, ready for NSAttributedString highlighting.
        public let range: NSRange
        public let text: String
        public let captures: [String]
    }

    public struct Line: Sendable, Equatable {
        public let text: String
        public let matches: [Match]
        public var matched: Bool { !matches.isEmpty }
        public var captures: [String] { matches.first?.captures ?? [] }
    }

    public let lines: [Line]
    public let totalLineCount: Int
    public let matchingLineCount: Int
    public let compileFailure: String?
    /// Set if matching stopped early; counts must not be treated as complete.
    public let matchFailure: String?

    public static func evaluate(pattern: String, selection: String, visibleLimit: Int = 12,
                                deadlineSeconds: TimeInterval = 0.15) -> Self {
        guard pattern.count <= 4096 else {
            return .init(lines: [], totalLineCount: 0, matchingLineCount: 0,
                         compileFailure: "Pattern exceeds 4096 characters", matchFailure: nil)
        }
        let expression: NSRegularExpression
        do { expression = try NSRegularExpression(pattern: pattern) }
        catch {
            return .init(lines: [], totalLineCount: 0, matchingLineCount: 0,
                         compileFailure: error.localizedDescription, matchFailure: nil)
        }
        guard (selection as NSString).length <= 100_000 else {
            return .init(lines: [], totalLineCount: 0, matchingLineCount: 0,
                         compileFailure: nil, matchFailure: "Selection exceeds 100,000 UTF-16 units")
        }
        let sourceLines = selection.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.001, deadlineSeconds)
        var visible: [Line] = []
        var matchedLineCount = 0
        var timedOut = false
        for line in sourceLines {
            if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; break }
            let nsLine = line as NSString
            var lineMatches: [Match] = []
            expression.enumerateMatches(in: line, options: [.reportProgress],
                                        range: NSRange(location: 0, length: nsLine.length)) { result, _, stop in
                if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; stop.pointee = true; return }
                guard let result else { return }
                var captures: [String] = []
                if result.numberOfRanges > 1 {
                    for index in 1..<result.numberOfRanges {
                        let range = result.range(at: index)
                        captures.append(range.location == NSNotFound ? "" : nsLine.substring(with: range))
                    }
                }
                lineMatches.append(.init(range: result.range, text: nsLine.substring(with: result.range),
                                         captures: captures))
            }
            if timedOut { break }
            if !lineMatches.isEmpty { matchedLineCount += 1 }
            if visible.count < max(0, visibleLimit) { visible.append(.init(text: line, matches: lineMatches)) }
        }
        return .init(lines: visible, totalLineCount: sourceLines.count,
                     matchingLineCount: matchedLineCount, compileFailure: nil,
                     matchFailure: timedOut ? "Matching stopped after time limit" : nil)
    }
}
