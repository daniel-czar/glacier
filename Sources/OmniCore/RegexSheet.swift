import Foundation

/// The typed view of a Regex sheet row. On disk, rows use Recall's
/// category/title/command/note shape so a future sheet browser can read both.
public struct RegexSheetEntry: Hashable, Sendable {
    public let name: String
    public let pattern: String
    public let note: String
    public let intentAliases: [String]

    public init(name: String, pattern: String, note: String = "", intentAliases: [String] = []) {
        self.name = name
        self.pattern = pattern
        self.note = note
        self.intentAliases = intentAliases
    }
}

public struct RegexSheetMatch: Equatable, Sendable {
    public let sheet: [RegexSheetEntry]
    public let shouldGenerate: Bool
    public let strongHit: Bool

    public init(sheet: [RegexSheetEntry], shouldGenerate: Bool, strongHit: Bool) {
        self.sheet = sheet
        self.shouldGenerate = shouldGenerate
        self.strongHit = strongHit
    }
}

/// Search names and saved intent phrases only. Pattern syntax is deliberately
/// absent from scoring: prose cannot accidentally match a metacharacter.
public enum RegexSheetMatcher {
    public static func search(_ query: String, in entries: [RegexSheetEntry]) -> RegexSheetMatch {
        let phrase = normalize(query)
        guard !phrase.isEmpty else { return RegexSheetMatch(sheet: entries, shouldGenerate: false, strongHit: false) }
        let terms = meaningfulWords(phrase)
        let scored = entries.enumerated().compactMap { offset, entry -> (score: Int, offset: Int, strong: Bool, entry: RegexSheetEntry)? in
            let name = normalize(entry.name)
            let aliases = entry.intentAliases.map(normalize)
            if name == phrase || aliases.contains(phrase) { return (100, offset, true, entry) }
            let titleWords = Set(meaningfulWords(name))
            let aliasWords = Set(aliases.flatMap(meaningfulWords))
            let score = terms.reduce(0) { value, term in
                if titleWords.contains(term) { return value + 4 }
                if titleWords.contains(where: { near(term, $0) }) { return value + 3 }
                if aliasWords.contains(term) { return value + 2 }
                if name.contains(term) { return value + 1 }
                return value
            } + (name.contains(phrase) ? 8 : 0)
            guard score >= 3 else { return nil }
            // Full name coverage is a sheet answer only if the query does not
            // contain an unsatisfied concrete qualifier or another pattern.
            let nameCovers = terms.allSatisfy { term in
                titleWords.contains(term) || titleWords.contains(where: { near(term, $0) })
            }
            let aliasCovers = aliases.contains { alias in
                let words = Set(meaningfulWords(alias))
                return terms.allSatisfy { words.contains($0) }
            }
            let strong = !terms.isEmpty && (nameCovers || aliasCovers)
            return (score, offset, strong, entry)
        }.sorted { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }
        let strong = scored.first?.strong == true
        return RegexSheetMatch(sheet: scored.map(\.entry), shouldGenerate: !strong, strongHit: strong)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func meaningfulWords(_ text: String) -> [String] {
        let stop: Set<String> = ["a", "an", "the", "to", "for", "of", "in", "on", "is", "are", "what", "how", "can", "i", "want", "need", "regex", "pattern", "match", "matches", "matching", "that", "all", "me", "my"]
        return text.split(separator: " ").map(String.init).filter { !stop.contains($0) }.map { word in
            if word.hasSuffix("es"), word.count > 4 { return String(word.dropLast(2)) }
            if word.hasSuffix("s"), word.count > 3 { return String(word.dropLast()) }
            return word
        }
    }

    private static func near(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count >= 4, rhs.count >= 4,
              lhs.utf8.allSatisfy({ (97...122).contains($0) }),
              rhs.utf8.allSatisfy({ (97...122).contains($0) }) else { return false }
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
