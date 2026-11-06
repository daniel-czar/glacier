import Foundation

/// The blend (handoff §4), an agent-owned default:
/// `0.55 fuzzy + 0.25 frecency + 0.10 recency + 0.10 kind priority`.
public struct LauncherRankingWeights: Sendable, Equatable {
    public let fuzzy: Double
    public let frecency: Double
    public let recency: Double
    public let kind: Double
    /// Content age halves the recency component every 30 days.
    public let recencyHalfLife: TimeInterval
    /// Apps have no content age (a bundle's modification date is its
    /// install or update time, not a use signal), so they take the neutral
    /// midpoint instead of being boosted or penalised against dated rows.
    public let appRecency: Double

    public init(fuzzy: Double = 0.55, frecency: Double = 0.25, recency: Double = 0.10, kind: Double = 0.10, recencyHalfLife: TimeInterval = 30 * 86_400, appRecency: Double = 0.5) {
        self.fuzzy = fuzzy
        self.frecency = frecency
        self.recency = recency
        self.kind = kind
        self.recencyHalfLife = recencyHalfLife
        self.appRecency = appRecency
    }

    public static let seed = LauncherRankingWeights()
    /// C72: added today contributes 0.20, decaying to zero at day 30.
    /// The larger term makes a newly added file beat an older comparable
    /// name match; this value is never used for curated ranking.
    public static let everywhere = LauncherRankingWeights(fuzzy: 0.50, frecency: 0.20, recency: 0.20, kind: 0.10)
}

/// The ready rule (handoff §2), offline: the top row is ready when its
/// normalised fuzzy score is ≥ τ₁ and its blended margin over the second
/// row is ≥ τ₂, or when it is an exact or prefix title match with frecency.
/// "With frecency" has a floor: decay never reaches zero, so a launch from
/// a year ago must not make a near-tie Enter-safe. One plain launch scores
/// ≈ 0.4 on the day and falls below the floor after about three weeks; a
/// launch for this very prefix stays above it for about six weeks. τ₁/τ₂ and the floor are
/// agent-owned seeds to be tuned from the launch log.
public struct LauncherReadyRule: Sendable, Equatable {
    public let minimumFuzzy: Double
    public let minimumMargin: Double
    public let minimumFrecency: Double

    public init(minimumFuzzy: Double = 0.60, minimumMargin: Double = 0.15, minimumFrecency: Double = 0.2) {
        self.minimumFuzzy = minimumFuzzy
        self.minimumMargin = minimumMargin
        self.minimumFrecency = minimumFrecency
    }

    public static let seed = LauncherReadyRule()
}

public struct LauncherScoredRow: Sendable, Equatable, Identifiable {
    public let candidate: LauncherCandidate
    /// Normalised fuzzy score 0…1 (the confidence bar); 0 for one-character rows.
    public let fuzzy: Double
    public let frecency: Double
    public let recency: Double
    public let kindPriority: Double
    /// The blended score rows are ordered by.
    public let score: Double

    public var id: String { candidate.id }

    public init(candidate: LauncherCandidate, fuzzy: Double, frecency: Double, recency: Double, kindPriority: Double, score: Double) {
        self.candidate = candidate
        self.fuzzy = fuzzy
        self.frecency = frecency
        self.recency = recency
        self.kindPriority = kindPriority
        self.score = score
    }

    /// An exact-id hit (D1): not scored, so no confidence bar is drawn.
    public static func exact(_ candidate: LauncherCandidate) -> LauncherScoredRow {
        LauncherScoredRow(candidate: candidate, fuzzy: 0, frecency: 0, recency: 0, kindPriority: 0, score: 1)
    }
}

/// The exact-id lane's answer for an id-shaped query (D1). A hit lists the
/// lane that holds each row, since an id can name a curated document or an
/// agent-output row only the everywhere lane carries; a miss has no rows,
/// and Enter does nothing. Neither ever becomes a proposal.
public enum LauncherIDLookup: Sendable, Equatable {
    case hit(lanes: [String: LauncherLane])
    case miss

    /// The lane to launch a hit row through.
    public func lane(for candidateID: String) -> LauncherLane? {
        if case .hit(let lanes) = self { return lanes[candidateID] }
        return nil
    }
}

/// What one keystroke produced: at most 15 distinct rows, and whether the
/// top one may be opened by Enter without looking.
public struct LauncherResults: Sendable, Equatable {
    /// The normalised query text these rows answer.
    public let query: String
    public let lane: LauncherLane
    /// Capped count for the curated footer, when requested by the service.
    public let everywhereMatchCount: Int?
    public let rows: [LauncherScoredRow]
    public let ready: Bool
    /// Blended top-1 minus top-2 (top-1 alone when only one row matched).
    public let margin: Double?
    /// Set when the query is an id address (D1); nil for every other query.
    public let idLookup: LauncherIDLookup?

    public init(query: String, rows: [LauncherScoredRow], ready: Bool, margin: Double?, lane: LauncherLane = .curated, everywhereMatchCount: Int? = nil, idLookup: LauncherIDLookup? = nil) {
        self.query = query
        self.lane = lane
        self.everywhereMatchCount = everywhereMatchCount
        self.rows = rows
        self.ready = ready
        self.margin = margin
        self.idLookup = idLookup
    }

    public static func empty(_ query: String, lane: LauncherLane = .curated) -> LauncherResults {
        LauncherResults(query: query, rows: [], ready: false, margin: nil, lane: lane)
    }

    public var top: LauncherScoredRow? { rows.first }
}

/// The immutable, search-optimised candidate array. Built off the main
/// actor, published whole; a query never mutates it. Hot per-keystroke data
/// lives in flat primitive arrays (folded scalars, bonuses, letter masks) so
/// one query touches no strings until the top rows are materialised.
public struct LauncherIndex: Sendable {
    public static let candidateCap = 15

    public let candidates: [LauncherCandidate]
    public let lane: LauncherLane
    private let scalarStore: [UInt32]
    private let bonusStore: [Double]
    private let titleStart: [Int]
    private let titleCount: [Int]
    /// -1 when the basename folds to the title (folders, apps).
    private let basenameStart: [Int]
    private let basenameCount: [Int]
    /// Kind and tags as one field: the docs index's second key (handoff §3),
    /// so `orbit spec` finds the Orbit doc whose kind is `spec`.
    private let keywordStart: [Int]
    private let keywordCount: [Int]
    /// Only the everywhere index stores the immediate parent folder field.
    private let parentStart: [Int]
    private let parentCount: [Int]
    private let masks: [UInt64]
    private let kindPriorities: [Double]
    private let isApp: [Bool]
    private let isMedia: [Bool]
    /// NaN when undated.
    private let dates: [Double]
    private let positionByID: [String: Int]
    private let longestField: Int

    public var count: Int { candidates.count }

    public static let empty = LauncherIndex(candidates: [])

    public init(candidates: [LauncherCandidate], lane: LauncherLane = .curated) {
        self.candidates = candidates
        self.lane = lane
        var scalarStore: [UInt32] = []
        var bonusStore: [Double] = []
        var titleStart: [Int] = []
        var titleCount: [Int] = []
        var basenameStart: [Int] = []
        var basenameCount: [Int] = []
        var keywordStart: [Int] = []
        var keywordCount: [Int] = []
        var parentStart: [Int] = []
        var parentCount: [Int] = []
        var masks: [UInt64] = []
        var positionByID: [String: Int] = [:]
        var longest = 0
        for (position, candidate) in candidates.enumerated() {
            let title = LauncherSearchField(candidate.title)
            titleStart.append(scalarStore.count)
            titleCount.append(title.scalars.count)
            scalarStore.append(contentsOf: title.scalars)
            bonusStore.append(contentsOf: title.bonus)
            var mask = LauncherFuzzy.mask(title.scalars)
            let basenameText = candidate.source == .apps ? (candidate.basename as NSString).deletingPathExtension : candidate.basename
            let basename = LauncherSearchField(basenameText)
            if basename.scalars == title.scalars || basename.scalars.isEmpty {
                basenameStart.append(-1)
                basenameCount.append(0)
            } else {
                basenameStart.append(scalarStore.count)
                basenameCount.append(basename.scalars.count)
                scalarStore.append(contentsOf: basename.scalars)
                bonusStore.append(contentsOf: basename.bonus)
                mask |= LauncherFuzzy.mask(basename.scalars)
            }
            let keywords = LauncherSearchField(([LauncherRowText.kindLabel(candidate)] + candidate.tags).joined(separator: " "))
            keywordStart.append(scalarStore.count)
            keywordCount.append(keywords.scalars.count)
            scalarStore.append(contentsOf: keywords.scalars)
            bonusStore.append(contentsOf: keywords.bonus)
            mask |= LauncherFuzzy.mask(keywords.scalars)
            if lane == .everywhere {
                let parentPath = (candidate.path as NSString).deletingLastPathComponent
                let parentName = (parentPath as NSString).lastPathComponent
                let parent = LauncherSearchField(parentName)
                parentStart.append(scalarStore.count)
                parentCount.append(parent.scalars.count)
                scalarStore.append(contentsOf: parent.scalars)
                bonusStore.append(contentsOf: parent.bonus)
                mask |= LauncherFuzzy.mask(parent.scalars)
                longest = max(longest, parent.scalars.count)
            } else {
                parentStart.append(-1)
                parentCount.append(0)
            }
            longest = max(longest, title.scalars.count, basename.scalars.count, keywords.scalars.count)
            masks.append(mask)
            if positionByID[candidate.id] == nil { positionByID[candidate.id] = position }
        }
        self.scalarStore = scalarStore
        self.bonusStore = bonusStore
        self.titleStart = titleStart
        self.titleCount = titleCount
        self.basenameStart = basenameStart
        self.basenameCount = basenameCount
        self.keywordStart = keywordStart
        self.keywordCount = keywordCount
        self.parentStart = parentStart
        self.parentCount = parentCount
        self.masks = masks
        kindPriorities = candidates.map { candidate in
            guard lane == .everywhere else { return LauncherKindClass.of(candidate).priority }
            let ext = (candidate.path as NSString).pathExtension.lowercased()
            if EverywhereScope.mediaExtensions.contains(ext) { return 0.15 }
            if candidate.path.contains("/agent-output/") {
                return candidate.source == .roots ? 0.30 : 0.25
            }
            if EverywhereScope.plainTextExtensions.contains(ext) { return 0.35 }
            if EverywhereScope.revealExtensions.contains(ext) { return 0.20 }
            return LauncherKindClass.of(candidate).priority
        }
        isApp = candidates.map { $0.source == .apps }
        isMedia = candidates.map { EverywhereScope.mediaExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
        dates = candidates.map { candidate in
            let date = lane == .everywhere ? candidate.added : (candidate.modified ?? candidate.added)
            return date?.timeIntervalSinceReferenceDate ?? .nan
        }
        self.positionByID = positionByID
        longestField = longest
    }

    public func candidate(id: String) -> LauncherCandidate? {
        positionByID[id].map { candidates[$0] }
    }

    private struct Hit {
        let position: Int
        let fuzzy: Double
        let frecency: Double
        let recency: Double
        let score: Double
    }

    /// Row order: blended score, then fuzzy, kind priority, shorter title, path.
    private func precedes(_ lhs: Hit, _ rhs: Hit) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.fuzzy != rhs.fuzzy { return lhs.fuzzy > rhs.fuzzy }
        let left = kindPriorities[lhs.position], right = kindPriorities[rhs.position]
        if left != right { return left > right }
        let leftCount = titleCount[lhs.position], rightCount = titleCount[rhs.position]
        if leftCount != rightCount { return leftCount < rightCount }
        return candidates[lhs.position].path < candidates[rhs.position].path
    }

    /// One-character order: frecency first, then the same order as above.
    private func precedesByFrecency(_ lhs: Hit, _ rhs: Hit) -> Bool {
        if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
        return precedes(lhs, rhs)
    }

    /// One keystroke. Pure: same inputs, same rows.
    public func query(
        _ raw: String,
        frecency: LauncherFrecency = .empty,
        now: Date,
        weights: LauncherRankingWeights? = nil,
        rule: LauncherReadyRule = .seed,
        limit: Int = LauncherIndex.candidateCap
    ) -> LauncherResults {
        let query = LauncherQuery(raw)
        guard !query.isEmpty, limit > 0, !candidates.isEmpty,
              lane == .curated || query.characterCount >= 3 else { return .empty(query.text, lane: lane) }
        let weights = weights ?? (lane == .everywhere ? .everywhere : .seed)
        let nowInterval = now.timeIntervalSinceReferenceDate

        // Frecency is sparse: resolve the few launched candidates once.
        var frecencyByPosition: [Int: Double] = [:]
        if !frecency.isEmpty {
            for id in frecency.candidateIDs {
                guard let position = positionByID[id] else { continue }
                let value = frecency.score(candidateID: id, foldedQuery: query.folded, now: now)
                if value > 0 { frecencyByPosition[position] = value }
            }
        }

        func recency(_ position: Int) -> Double {
            if isApp[position] { return weights.appRecency }
            let date = dates[position]
            guard !date.isNaN else { return 0 }
            if lane == .everywhere {
                return max(0, 1 - max(0, nowInterval - date) / (30 * 86_400))
            }
            return pow(0.5, max(0, nowInterval - date) / weights.recencyHalfLife)
        }

        var top: [Hit] = []
        top.reserveCapacity(limit + 1)
        func offer(_ hit: Hit, by order: (Hit, Hit) -> Bool) {
            if top.count == limit, let last = top.last, !order(hit, last) { return }
            var index = top.count
            while index > 0, order(hit, top[index - 1]) { index -= 1 }
            top.insert(hit, at: index)
            if lane == .everywhere, isMedia[hit.position],
               top.reduce(0, { $0 + (isMedia[$1.position] ? 1 : 0) }) > 3,
               let worstMedia = top.lastIndex(where: { isMedia[$0.position] }) {
                top.remove(at: worstMedia)
            }
            if top.count > limit { top.removeLast() }
        }

        let oneCharacter = query.characterCount == 1
        let queryMask = LauncherFuzzy.mask(query.words.flatMap { $0 })
        let concatenated = query.words.flatMap { $0 }
        let phrase = Array(query.folded.unicodeScalars.map(\.value))
        var rowsBuffer = [Double](repeating: 0, count: max(1, longestField) * 4)

        scalarStore.withUnsafeBufferPointer { scalarBuffer in
            bonusStore.withUnsafeBufferPointer { bonusBuffer in
                rowsBuffer.withUnsafeMutableBufferPointer { rowBuffer in
                    guard let scalars = scalarBuffer.baseAddress, let bonuses = bonusBuffer.baseAddress, let rows = rowBuffer.baseAddress else { return }
                    for position in 0..<candidates.count {
                        // A newer keystroke cancels this one's task; stop early.
                        if position & 1_023 == 0, position > 0, Task.isCancelled { return }
                        if masks[position] & queryMask != queryMask { continue }
                        let tStart = titleStart[position], tCount = titleCount[position]
                        let bStart = basenameStart[position], bCount = basenameCount[position]
                        let kStart = keywordStart[position], kCount = keywordCount[position]
                        let pStart = parentStart[position], pCount = parentCount[position]

                        if oneCharacter {
                            // Frecency-ordered word-start rows without scoring
                            // (handoff §4 default); never ready.
                            let character = concatenated[0]
                            var found = false
                            for offset in 0..<tCount where scalars[tStart + offset] == character && bonuses[tStart + offset] > 0 {
                                found = true
                                break
                            }
                            if !found, bStart >= 0 {
                                for offset in 0..<bCount where scalars[bStart + offset] == character && bonuses[bStart + offset] > 0 {
                                    found = true
                                    break
                                }
                            }
                            guard found else { continue }
                            let frecencyScore = frecencyByPosition[position] ?? 0
                            let recencyScore = recency(position)
                            let score = weights.frecency * frecencyScore + weights.recency * recencyScore + weights.kind * kindPriorities[position]
                            offer(Hit(position: position, fuzzy: 0, frecency: frecencyScore, recency: recencyScore, score: score), by: precedesByFrecency)
                            continue
                        }

                        var total = 0.0
                        var matched = true
                        for word in query.words {
                            let best: Double? = word.withUnsafeBufferPointer { wordBuffer in
                                var best = LauncherFuzzy.score(word: wordBuffer, haystack: scalars + tStart, bonus: bonuses + tStart, count: tCount, rows: rows)
                                if bStart >= 0, let basename = LauncherFuzzy.score(word: wordBuffer, haystack: scalars + bStart, bonus: bonuses + bStart, count: bCount, rows: rows) {
                                    best = max(best ?? 0, basename)
                                }
                                if let keyword = LauncherFuzzy.score(word: wordBuffer, haystack: scalars + kStart, bonus: bonuses + kStart, count: kCount, rows: rows, affixBonuses: false) {
                                    best = max(best ?? 0, keyword * LauncherFuzzy.keywordWeight)
                                }
                                if pStart >= 0, let parent = LauncherFuzzy.score(word: wordBuffer, haystack: scalars + pStart, bonus: bonuses + pStart, count: pCount, rows: rows) {
                                    best = max(best ?? 0, parent * LauncherFuzzy.keywordWeight)
                                }
                                return best
                            }
                            guard let best else {
                                matched = false
                                break
                            }
                            total += best
                        }
                        guard matched else { continue }
                        var fuzzy = total / Double(query.words.count)
                        if query.words.count > 1 {
                            // The words as typed, contiguous in the title, beat the
                            // same words scattered through it.
                            if phrase.withUnsafeBufferPointer({ LauncherFuzzy.containsContiguous($0, in: scalars + tStart, count: tCount) }) {
                                fuzzy += LauncherFuzzy.phraseBonus
                            } else if concatenated.withUnsafeBufferPointer({ LauncherFuzzy.isSubsequence($0, in: scalars + tStart, count: tCount) }) {
                                fuzzy += LauncherFuzzy.inOrderBonus
                            }
                        }
                        fuzzy = min(1, fuzzy)
                        let frecencyScore = frecencyByPosition[position] ?? 0
                        let recencyScore = recency(position)
                        let score = weights.fuzzy * fuzzy + weights.frecency * frecencyScore + weights.recency * recencyScore + weights.kind * kindPriorities[position]
                        offer(Hit(position: position, fuzzy: fuzzy, frecency: frecencyScore, recency: recencyScore, score: score), by: precedes)
                    }
                }
            }
        }

        let rows = top.map {
            LauncherScoredRow(candidate: candidates[$0.position], fuzzy: $0.fuzzy, frecency: $0.frecency, recency: $0.recency, kindPriority: kindPriorities[$0.position], score: $0.score)
        }
        guard let first = rows.first else { return .empty(query.text, lane: lane) }
        if oneCharacter { return LauncherResults(query: query.text, rows: rows, ready: false, margin: nil, lane: lane) }
        let margin = first.score - (rows.count > 1 ? rows[1].score : 0)
        if lane == .everywhere {
            return LauncherResults(query: query.text, rows: rows, ready: false, margin: margin, lane: lane)
        }
        let titleFolded = LauncherQuery(first.candidate.title).folded
        let titleMatch = titleFolded.hasPrefix(query.folded)
        let ready = (first.fuzzy >= rule.minimumFuzzy && margin >= rule.minimumMargin)
            || (titleMatch && first.frecency >= rule.minimumFrecency)
        return LauncherResults(query: query.text, rows: rows, ready: ready, margin: margin, lane: lane)
    }

    /// Count the same multi-field subsequence matches used by everywhere
    /// ranking, stopping at the display cap. No DP or row materialisation is
    /// needed because ranking score cannot change whether a word matches.
    public func matchCount(_ text: String, cap: Int = 100) -> Int {
        let query = LauncherQuery(text)
        guard cap > 0, query.characterCount >= 3, !candidates.isEmpty else { return 0 }
        let queryMask = LauncherFuzzy.mask(query.words.flatMap { $0 })
        return scalarStore.withUnsafeBufferPointer { buffer in
            guard let scalars = buffer.baseAddress else { return 0 }
            var count = 0
            for position in candidates.indices {
                if position & 1_023 == 0, position > 0, Task.isCancelled { return count }
                if masks[position] & queryMask != queryMask { continue }
                let matched = query.words.allSatisfy { word in
                    word.withUnsafeBufferPointer { needle in
                        LauncherFuzzy.isSubsequence(needle, in: scalars + titleStart[position], count: titleCount[position])
                            || (basenameStart[position] >= 0 && LauncherFuzzy.isSubsequence(needle, in: scalars + basenameStart[position], count: basenameCount[position]))
                            || LauncherFuzzy.isSubsequence(needle, in: scalars + keywordStart[position], count: keywordCount[position])
                            || (parentStart[position] >= 0 && LauncherFuzzy.isSubsequence(needle, in: scalars + parentStart[position], count: parentCount[position]))
                    }
                }
                if matched {
                    count += 1
                    if count >= cap { return count }
                }
            }
            return count
        }
    }
}
