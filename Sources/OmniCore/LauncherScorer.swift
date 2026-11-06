import Foundation

/// fzy/fzf-style subsequence scoring (handoff §4): consecutive-match bonus,
/// word-boundary bonus (space, `-`, `_`, `/`, `.`, camelCase), gap penalty,
/// exact and prefix bonuses, normalised to 0…1 against the best achievable
/// score for the query length. Case- and diacritic-insensitive.
///
/// Fields are folded and their boundary bonuses precomputed once at index
/// build (spike finding: never per query). The scoring core works on raw
/// pointers into flat storage so a per-keystroke pass over ~4k rows stays
/// within budget even in an unoptimised test build.
public enum LauncherFuzzy {
    public static let bonusBoundary = 0.9
    public static let bonusCamel = 0.7
    public static let bonusConsecutive = 1.0
    public static let gapPenalty = -0.01
    public static let leadingPenaltyPerCharacter = 0.005
    public static let bonusExact = 2.0
    public static let bonusPrefix = 1.0
    /// Added to a multi-word score when the words occur in order in the title.
    public static let inOrderBonus = 0.03
    /// Added instead when the query, spaces included, is a contiguous run of the title.
    public static let phraseBonus = 0.08
    /// A word matched only through kind or tags counts at this fraction, so a
    /// title match of the same quality still wins.
    public static let keywordWeight = 0.85

    /// Case- and diacritic-folds one scalar, keeping positions aligned: a
    /// fold that would expand (ß → ss) keeps the lowercase scalar instead.
    @inline(__always)
    public static func fold(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        if value < 0x80 {
            return (value >= 0x41 && value <= 0x5A) ? value + 0x20 : value
        }
        let folded = String(scalar).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars
        if folded.count == 1, let first = folded.first { return first.value }
        return scalar.properties.lowercaseMapping.unicodeScalars.first?.value ?? value
    }

    public static func foldedScalars(_ text: String) -> [UInt32] {
        text.precomposedStringWithCanonicalMapping.unicodeScalars.map(fold)
    }

    @inline(__always)
    static func isSeparator(_ value: UInt32) -> Bool {
        value == 0x2F || value == 0x2D || value == 0x5F || value == 0x20 || value == 0x2E
    }

    /// Boundary bonus per position, computed from the original (unfolded)
    /// scalars so camelCase edges survive folding.
    public static func boundaryBonuses(_ text: String) -> [Double] {
        let scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        var bonus = [Double](repeating: 0, count: scalars.count)
        for index in scalars.indices {
            if index == 0 {
                bonus[index] = bonusBoundary
                continue
            }
            let previous = scalars[index - 1]
            if isSeparator(previous.value) {
                bonus[index] = bonusBoundary
            } else if previous.properties.isLowercase && scalars[index].properties.isUppercase {
                bonus[index] = bonusCamel
            }
        }
        return bonus
    }

    public static func bestPossible(queryLength: Int) -> Double {
        bonusBoundary + Double(max(0, queryLength - 1)) * bonusConsecutive + bonusExact
    }

    /// Letters and digits present, one bit each: a cheap necessary condition
    /// for a subsequence match, checked before any per-field work.
    @inline(__always)
    static func maskBit(_ value: UInt32) -> UInt64 {
        if value >= 0x61 && value <= 0x7A { return 1 << UInt64(value - 0x61) }
        if value >= 0x30 && value <= 0x39 { return 1 << UInt64(26 + value - 0x30) }
        return 0
    }

    static func mask<S: Sequence>(_ scalars: S) -> UInt64 where S.Element == UInt32 {
        scalars.reduce(0) { $0 | maskBit($1) }
    }

    @inline(__always)
    static func isSubsequence(_ query: UnsafeBufferPointer<UInt32>, in haystack: UnsafePointer<UInt32>, count m: Int) -> Bool {
        let n = query.count
        if n == 0 { return true }
        var qi = 0
        var j = 0
        while j < m {
            if haystack[j] == query[qi] {
                qi += 1
                if qi == n { return true }
            }
            j += 1
        }
        return false
    }

    @inline(__always)
    static func containsContiguous(_ needle: UnsafeBufferPointer<UInt32>, in haystack: UnsafePointer<UInt32>, count m: Int) -> Bool {
        let n = needle.count
        guard n > 0, n <= m else { return n == 0 }
        var start = 0
        while start + n <= m {
            var offset = 0
            while offset < n, haystack[start + offset] == needle[offset] { offset += 1 }
            if offset == n { return true }
            start += 1
        }
        return false
    }

    /// Reusable DP rows (four rows in one flat buffer) so scoring allocates
    /// nothing per candidate.
    public struct Scratch {
        var buffer: [Double] = []

        public init() {}

        mutating func reserve(_ count: Int) {
            if buffer.count < count * 4 { buffer = [Double](repeating: 0, count: count * 4) }
        }
    }

    /// Raw DP score over one field, or nil when `query` is not a subsequence.
    /// `rows` must hold at least `4 * m` doubles.
    static func rawScore(
        query: UnsafeBufferPointer<UInt32>,
        haystack: UnsafePointer<UInt32>,
        bonus: UnsafePointer<Double>,
        count m: Int,
        rows: UnsafeMutablePointer<Double>
    ) -> Double? {
        let n = query.count
        guard n > 0, m > 0, n <= m, isSubsequence(query, in: haystack, count: m) else { return nil }
        let negativeInfinity = -Double.infinity
        var prevM = rows
        var prevD = rows + m
        var curM = rows + 2 * m
        var curD = rows + 3 * m
        var i = 0
        while i < n {
            let character = query[i]
            var runningGap = negativeInfinity
            var j = 0
            while j < m {
                var diagonal = negativeInfinity
                if haystack[j] == character {
                    if i == 0 {
                        diagonal = bonus[j] - Double(j) * leadingPenaltyPerCharacter
                    } else if j > 0 {
                        let fromM = prevM[j - 1]
                        let fromD = prevD[j - 1]
                        if fromM > negativeInfinity { diagonal = fromM + bonus[j] }
                        if fromD > negativeInfinity, fromD + bonusConsecutive > diagonal { diagonal = fromD + bonusConsecutive }
                    }
                }
                curD[j] = diagonal
                let gapped = runningGap + gapPenalty
                let value = diagonal > gapped ? diagonal : gapped
                curM[j] = value
                runningGap = value
                j += 1
            }
            if i < n - 1 {
                swap(&prevM, &curM)
                swap(&prevD, &curD)
            }
            i += 1
        }
        let raw = curM[m - 1]
        return raw > negativeInfinity ? raw : nil
    }

    /// One word against one field, normalised to 0…1, with the exact (+2)
    /// and prefix (+1) bonuses read off the folded scalars. The kind/tags
    /// field scores without them: it is a joined bag of words, so "the whole
    /// field equals the word" only means the doc has no tags.
    static func score(
        word: UnsafeBufferPointer<UInt32>,
        haystack: UnsafePointer<UInt32>,
        bonus: UnsafePointer<Double>,
        count m: Int,
        rows: UnsafeMutablePointer<Double>,
        affixBonuses: Bool = true
    ) -> Double? {
        guard var raw = rawScore(query: word, haystack: haystack, bonus: bonus, count: m, rows: rows) else { return nil }
        var prefix = affixBonuses
        var index = 0
        while index < word.count {
            if haystack[index] != word[index] {
                prefix = false
                break
            }
            index += 1
        }
        if prefix { raw += word.count == m ? bonusExact : bonusPrefix }
        let normalised = raw / bestPossible(queryLength: word.count)
        return normalised < 0 ? 0 : (normalised > 1 ? 1 : normalised)
    }

    /// Convenience for a prepared field (tests, one-off scoring).
    public static func score(word: [UInt32], field: LauncherSearchField, scratch: inout Scratch) -> Double? {
        let m = field.scalars.count
        guard m > 0 else { return nil }
        scratch.reserve(m)
        return word.withUnsafeBufferPointer { query in
            field.scalars.withUnsafeBufferPointer { haystack in
                field.bonus.withUnsafeBufferPointer { bonus in
                    scratch.buffer.withUnsafeMutableBufferPointer { rows in
                        score(word: query, haystack: haystack.baseAddress!, bonus: bonus.baseAddress!, count: m, rows: rows.baseAddress!)
                    }
                }
            }
        }
    }
}

/// A field prepared for scoring: folded scalars and boundary bonuses.
public struct LauncherSearchField: Sendable {
    public let scalars: [UInt32]
    public let bonus: [Double]

    public init(_ text: String) {
        let scalars = LauncherFuzzy.foldedScalars(text)
        self.scalars = scalars
        var bonus = LauncherFuzzy.boundaryBonuses(text)
        if bonus.count != scalars.count { bonus = [Double](repeating: 0, count: scalars.count) }
        self.bonus = bonus
    }
}

/// A normalised query: trimmed, whitespace collapsed, split into folded words.
public struct LauncherQuery: Sendable, Equatable {
    public let text: String
    public let folded: String
    public let words: [[UInt32]]

    public init(_ raw: String) {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = collapsed
        words = collapsed.split(separator: " ").map { LauncherFuzzy.foldedScalars(String($0)) }
        folded = words.map { String(String.UnicodeScalarView($0.compactMap(Unicode.Scalar.init))) }.joined(separator: " ")
    }

    public var isEmpty: Bool { words.isEmpty }
    /// Characters excluding spaces: the one-character rule reads this.
    public var characterCount: Int { words.reduce(0) { $0 + $1.count } }
}
