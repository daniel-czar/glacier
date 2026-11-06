import Foundation

/// One line of the launch log (handoff §4): every launch, every fallthrough
/// to Tier 2 and every ⌘Z of a launch. The lane distinguishes curated
/// fallthrough and ready-rule evidence from widened search use; launches
/// across both lanes remain the shared frecency source. It lives in the
/// app's support directory and never leaves the machine.
public struct LaunchLogEntry: Codable, Sendable, Equatable {
    public enum Event: String, Codable, Sendable, Equatable {
        /// A candidate row was opened or revealed.
        case launch
        /// Enter went to the Tier 2 proposal request instead of a row.
        case fellThrough = "fallthrough"
        /// ⌘Z restored the query after a launch: that launch was wrong.
        case undo
    }

    public enum Gesture: String, Codable, Sendable, Equatable {
        case open
        case reveal
    }

    /// How the launched row was chosen.
    public enum Selection: String, Codable, Sendable, Equatable {
        /// Enter on the ready top row.
        case ready
        /// ↑/↓ then Enter, or a click: the selection is the judgment.
        case manual
    }

    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let lane: LauncherLane
    public let timestamp: Date
    public let event: Event
    public let query: String
    public let candidateID: String?
    public let path: String?
    /// 1-based rank of the chosen row among the rows shown.
    public let rank: Int?
    public let top1ID: String?
    /// Whether the top row was ready when Enter was pressed.
    public let ready: Bool
    public let top1Chosen: Bool
    public let fellThrough: Bool
    /// Milliseconds from the query's first keystroke to the decision.
    public let elapsedMilliseconds: Int?
    public let gesture: Gesture?
    public let selection: Selection?
    /// Rows shown when the decision was taken (≤ 15).
    public let candidateCount: Int?
    /// A fallthrough chosen from the *Ask for a proposal instead* row after ⌘Z.
    public let afterUndo: Bool?
    /// A launch from the exact-id lane (D1): the query was an address, so
    /// rank and ready say nothing about the scorer. Nil otherwise.
    public let addressed: Bool?

    public init(
        timestamp: Date,
        event: Event,
        query: String,
        candidateID: String? = nil,
        path: String? = nil,
        rank: Int? = nil,
        top1ID: String? = nil,
        ready: Bool,
        top1Chosen: Bool,
        fellThrough: Bool,
        elapsedMilliseconds: Int? = nil,
        gesture: Gesture? = nil,
        selection: Selection? = nil,
        candidateCount: Int? = nil,
        afterUndo: Bool? = nil,
        lane: LauncherLane = .curated,
        addressed: Bool? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.lane = lane
        self.timestamp = timestamp
        self.event = event
        self.query = query
        self.candidateID = candidateID
        self.path = path
        self.rank = rank
        self.top1ID = top1ID
        self.ready = ready
        self.top1Chosen = top1Chosen
        self.fellThrough = fellThrough
        self.elapsedMilliseconds = elapsedMilliseconds
        self.gesture = gesture
        self.selection = selection
        self.candidateCount = candidateCount
        self.afterUndo = afterUndo
        self.addressed = addressed
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case lane
        case timestamp = "ts"
        case event
        case query
        case candidateID = "candidate_id"
        case path
        case rank
        case top1ID = "top1_id"
        case ready
        case top1Chosen = "top1_chosen"
        case fellThrough = "fell_through"
        case elapsedMilliseconds = "elapsed_ms"
        case gesture
        case selection
        case candidateCount = "candidate_count"
        case afterUndo = "after_undo"
        case addressed
    }

    /// A v1 line has no lane. It remains curated for historical metrics and
    /// frecency, while every newly written line carries the v2 lane.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        lane = try container.decodeIfPresent(LauncherLane.self, forKey: .lane) ?? .curated
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        event = try container.decode(Event.self, forKey: .event)
        query = try container.decode(String.self, forKey: .query)
        candidateID = try container.decodeIfPresent(String.self, forKey: .candidateID)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        rank = try container.decodeIfPresent(Int.self, forKey: .rank)
        top1ID = try container.decodeIfPresent(String.self, forKey: .top1ID)
        ready = try container.decode(Bool.self, forKey: .ready)
        top1Chosen = try container.decode(Bool.self, forKey: .top1Chosen)
        fellThrough = try container.decode(Bool.self, forKey: .fellThrough)
        elapsedMilliseconds = try container.decodeIfPresent(Int.self, forKey: .elapsedMilliseconds)
        gesture = try container.decodeIfPresent(Gesture.self, forKey: .gesture)
        selection = try container.decodeIfPresent(Selection.self, forKey: .selection)
        candidateCount = try container.decodeIfPresent(Int.self, forKey: .candidateCount)
        afterUndo = try container.decodeIfPresent(Bool.self, forKey: .afterUndo)
        addressed = try container.decodeIfPresent(Bool.self, forKey: .addressed)
    }

    /// One JSON line, keys sorted, ISO 8601 timestamps with milliseconds.
    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(LaunchLogEntry.timestampFormatter.string(from: date))
        }
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(line: String) throws -> LaunchLogEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = LaunchLogEntry.timestampFormatter.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad timestamp \(value)"))
            }
            return date
        }
        return try decoder.decode(LaunchLogEntry.self, from: Data(line.utf8))
    }

    nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Frecency from the launch log (handoff §4): a decayed count of launches
/// per candidate (half-life about two weeks) plus a per-query-prefix
/// association, so `elev` learns the row Daniel picks for it. A launch that
/// was undone with ⌘Z is removed: a wrong launch must not teach the ranker.
public struct LauncherFrecency: Sendable {
    public static let defaultHalfLife: TimeInterval = 14 * 86_400
    /// A prefix association counts this many times a plain launch.
    public static let prefixWeight = 2.0
    /// sat(x) = x / (x + k): one plain launch today ≈ 0.4, one launch for
    /// this very prefix ≈ 0.67, a daily habit → 1.
    public static let saturation = 1.5

    struct Launch: Sendable {
        let timestamp: Date
        let query: String
    }

    let launchesByCandidate: [String: [Launch]]
    public let halfLife: TimeInterval

    public static let empty = LauncherFrecency(entries: [])

    public init(entries: [LaunchLogEntry], halfLife: TimeInterval = LauncherFrecency.defaultHalfLife) {
        self.halfLife = halfLife
        var launches: [String: [Launch]] = [:]
        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let id = entry.candidateID else { continue }
            switch entry.event {
            case .launch:
                // An id launch (D1) counts as a launch, but its query is an
                // address, not a prefix habit worth teaching the scorer.
                let query = entry.addressed == true ? "" : LauncherQuery(entry.query).folded
                launches[id, default: []].append(Launch(timestamp: entry.timestamp, query: query))
            case .undo:
                if var list = launches[id], let index = list.lastIndex(where: { $0.timestamp <= entry.timestamp }) {
                    list.remove(at: index)
                    launches[id] = list.isEmpty ? nil : list
                }
            case .fellThrough:
                break
            }
        }
        launchesByCandidate = launches
    }

    public var isEmpty: Bool { launchesByCandidate.isEmpty }
    public var candidateIDs: [String] { Array(launchesByCandidate.keys) }

    public func decayedCount(candidateID: String, now: Date) -> Double {
        (launchesByCandidate[candidateID] ?? []).reduce(0) { $0 + decay($1.timestamp, now: now) }
    }

    /// 0…1 component for the blend. `query` is the folded query text.
    public func score(candidateID: String, foldedQuery: String, now: Date) -> Double {
        guard let launches = launchesByCandidate[candidateID] else { return 0 }
        var total = 0.0
        for launch in launches {
            let weight = decay(launch.timestamp, now: now)
            total += weight
            if Self.associates(launch.query, foldedQuery) { total += Self.prefixWeight * weight }
        }
        return total / (total + Self.saturation)
    }

    /// Two queries of at least two characters where one is a prefix of the other.
    static func associates(_ logged: String, _ current: String) -> Bool {
        guard logged.count >= 2, current.count >= 2 else { return false }
        return logged.hasPrefix(current) || current.hasPrefix(logged)
    }

    private func decay(_ timestamp: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(timestamp))
        return pow(0.5, age / halfLife)
    }
}
