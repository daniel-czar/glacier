import Foundation

/// A command to copy into a terminal. Recall never executes it.
public struct RecallCommand: Codable, Hashable, Sendable {
    public let category: String
    public let command: String
    public let label: String
    public let note: String
    public let destructive: Bool
    /// Intent phrases saved when a generated command is accepted into the sheet.
    public let intentAliases: [String]

    public init(category: String, command: String, label: String, note: String = "", destructive: Bool = false, intentAliases: [String] = []) {
        self.category = category
        self.command = command
        self.label = label
        self.note = note
        self.destructive = destructive || Self.isConservativelyDestructive(command)
        self.intentAliases = intentAliases
    }

    /// Only unmistakably destructive forms are labelled automatically. A
    /// model's explicit flag is kept even if its command is unfamiliar.
    public static func isConservativelyDestructive(_ command: String) -> Bool {
        let text = " " + command.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) + " "
        if text.range(of: #"\brm\s+-(?:[a-z]*r[a-z]*f|[a-z]*f[a-z]*r)\b"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\bgit\s+push\b[^\n]*\s--force(?:-with-lease)?\b"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\bgit\s+reset\s+--hard\b"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\bgit\s+clean\s+-(?:[a-z]*f[a-z]*d|[a-z]*d[a-z]*f)\b"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\bkill\s+-(?:9|KILL)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }
}

public struct RecallMatch: Sendable, Equatable {
    public let sheet: [RecallCommand]
    public let shouldGenerate: Bool
    public let strongHit: Bool

    public init(sheet: [RecallCommand], shouldGenerate: Bool, strongHit: Bool) {
        self.sheet = sheet
        self.shouldGenerate = shouldGenerate
        self.strongHit = strongHit
    }
}

/// Stable local search. A strong result ends the cascade even when fewer than
/// three rows match; otherwise fewer than three qualifying rows ask the model.
public enum RecallMatcher {
    public static func search(_ query: String, in commands: [RecallCommand]) -> RecallMatch {
        let phrase = normalize(query)
        guard !phrase.isEmpty else {
            let categories = Array(NSOrderedSet(array: commands.map(\.category))) as? [String] ?? []
            let grouped = categories.flatMap { category in commands.filter { $0.category == category } }
            return RecallMatch(sheet: grouped, shouldGenerate: false, strongHit: false)
        }
        var terms = meaningfulWords(phrase)
        if phrase.contains("branch am i on") || phrase.contains("branch i am on") { terms = ["current", "branch"] }
        let scored = commands.enumerated().compactMap { offset, command -> (Int, Int, Bool, RecallCommand)? in
            let aliases = command.intentAliases.map(normalize)
            if aliases.contains(phrase) { return (100, offset, true, command) }
            let label = normalize(command.label)
            let line = normalize(command.command)
            let note = normalize(command.note)
            let category = normalize(command.category)
            let titleWords = Set(meaningfulWords(label))
            let commandWords = Set(meaningfulWords(line))
            let noteWords = Set(meaningfulWords(note))
            let categoryWords = Set(meaningfulWords(category))
            let hits = terms.reduce(into: 0) { score, word in
                if titleWords.contains(word) { score += 4 }
                else if commandWords.contains(word) { score += 3 }
                else if noteWords.contains(word) { score += 2 }
                else if categoryWords.contains(word) { score += 1 }
                else if titleWords.contains(where: { near(word, $0) }) { score += 3 }
                else if commandWords.contains(where: { near(word, $0) }) { score += 2 }
                else if label.contains(word) || line.contains(word) { score += 1 }
            }
            let phraseBonus = label == phrase || line == phrase ? 20 : (label.contains(phrase) || line.contains(phrase) ? 8 : 0)
            let score = hits + phraseBonus
            // Preserve one or two weak anchors under a long natural-language
            // request, then let the thin tier ask the generator.
            let minimum = 3
            guard score >= minimum else { return nil }
            let isStrong = (label == phrase || line == phrase) ||
                (terms.count >= 2 && terms.allSatisfy { word in titleWords.contains(word) || titleWords.contains(where: { near(word, $0) }) } && score >= 7)
            return (score, offset, isStrong, command)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }
        // A high score can still omit a concrete value such as a port or PID.
        // Only an exact command/label, saved alias, or fully covered title is
        // a sheet answer complete enough to stop generation.
        let strong = scored.first?.2 == true
        let rows = scored.map(\.3)
        // Keep weak anchors visible, but only reasonably specific matches
        // count toward the three-row threshold that suppresses generation.
        let qualifyingCount = scored.filter { $0.0 >= 6 }.count
        return RecallMatch(sheet: rows, shouldGenerate: !strong && qualifyingCount < 3, strongHit: strong)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func meaningfulWords(_ text: String) -> [String] {
        let stop: Set<String> = ["a", "an", "the", "i", "am", "is", "are", "on", "in", "to", "for", "of", "do", "how", "what", "whats", "s", "which", "show", "me", "my", "with", "all", "but", "and", "including", "can", "get", "list"]
        return text.split(separator: " ").map(String.init).filter { !stop.contains($0) }.map { word in
            switch word {
            case "current", "now", "active": "current"
            case "branches": "branch"
            case "files": "file"
            case "commits": "commit"
            case "listening", "listeners": "listener"
            case "ports": "port"
            default: word
            }
        }
    }

    /// One typo (including an adjacent swap), limited to alphabetic words of
    /// four or more characters so flags, numbers and short command names stay
    /// exact.
    private static func near(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count >= 4, rhs.count >= 4,
              lhs.utf8.allSatisfy({ (97...122).contains($0) }),
              rhs.utf8.allSatisfy({ (97...122).contains($0) })
        else { return false }
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count == 1 { return true }
            if differences.count == 2 {
                let first = differences[0]
                let second = differences[1]
                return second == first + 1 && a[first] == b[second] && a[second] == b[first]
            }
            return false
        }
        guard abs(a.count - b.count) == 1 else { return false }
        let longer = a.count > b.count ? a : b
        let shorter = a.count > b.count ? b : a
        var index = 0
        for character in longer where index < shorter.count {
            if character == shorter[index] { index += 1 }
        }
        return index == shorter.count
    }
}
