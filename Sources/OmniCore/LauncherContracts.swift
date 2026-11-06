import Foundation

/// The persisted index (handoff §3): loaded at launch so the pad never waits
/// for a crawl, replaced atomically after each background build. Written to
/// the app's support directory; never committed.
public struct LauncherSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let builtAt: Date
    /// `generation_id` of the docs index this build read, for re-read on change.
    public let docsGeneration: String?
    public let buildMilliseconds: Int?
    public let stats: LauncherIndexStats
    public let candidates: [LauncherCandidate]
    /// True when the build read document ids (the exact-id lane, D1). Nil on
    /// snapshots written before it; those are rebuilt once. Older binaries
    /// ignore the key.
    public let carriesDocumentIDs: Bool?
    /// Docs rows the build folded into folder rows (project READMEs) that
    /// carry an id: addresses for the exact-id lane only, never scored.
    public let addressOnly: [LauncherCandidate]?

    public init(builtAt: Date, docsGeneration: String?, buildMilliseconds: Int?, stats: LauncherIndexStats, candidates: [LauncherCandidate], carriesDocumentIDs: Bool? = true, addressOnly: [LauncherCandidate]? = nil) {
        schemaVersion = Self.schemaVersion
        self.builtAt = builtAt
        self.docsGeneration = docsGeneration
        self.buildMilliseconds = buildMilliseconds
        self.stats = stats
        self.candidates = candidates
        self.carriesDocumentIDs = carriesDocumentIDs
        self.addressOnly = addressOnly
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case builtAt = "built_at"
        case docsGeneration = "docs_generation"
        case buildMilliseconds = "build_ms"
        case stats
        case candidates
        case carriesDocumentIDs = "document_ids"
        case addressOnly = "address_only"
    }
}

/// Crawls the roots and reads the docs index, then applies the C51 rules.
/// Runs off the main actor; its duration never blocks the pad.
public protocol LauncherIndexBuilding: Sendable {
    func build() async throws -> LauncherSnapshot
    /// The docs index generation currently on disk (cheap), or nil.
    func currentDocsGeneration() -> String?
}

public protocol LauncherSnapshotStoring: Sendable {
    func load() throws -> LauncherSnapshot?
    func save(_ snapshot: LauncherSnapshot) throws
}

public protocol LaunchLogging: Sendable {
    func append(_ entry: LaunchLogEntry) throws
    func readAll() throws -> [LaunchLogEntry]
}

/// What the pad knew when Enter was pressed: the launch log's evidence.
public struct LaunchContext: Sendable, Equatable {
    /// The normalised query text.
    public let query: String
    public let lane: LauncherLane
    /// 1-based rank of the chosen row; nil for a fallthrough.
    public let rank: Int?
    public let top1ID: String?
    /// Whether the top row was ready.
    public let ready: Bool
    /// nil for a fallthrough.
    public let selection: LaunchLogEntry.Selection?
    public let candidateCount: Int
    public let elapsedMilliseconds: Int?
    /// A fallthrough chosen from *Ask for a proposal instead* after ⌘Z.
    public let afterUndo: Bool

    public init(query: String, rank: Int?, top1ID: String?, ready: Bool, selection: LaunchLogEntry.Selection?, candidateCount: Int, elapsedMilliseconds: Int?, afterUndo: Bool = false, lane: LauncherLane = .curated) {
        self.query = query
        self.lane = lane
        self.rank = rank
        self.top1ID = top1ID
        self.ready = ready
        self.selection = selection
        self.candidateCount = candidateCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.afterUndo = afterUndo
    }
}

/// Enter opens; Cmd+Enter reveals (handoff §6).
public enum LauncherOpenAction: String, Sendable, Equatable {
    case open
    case reveal

    /// The owner-operation identity a launch is gated by. A launch is a
    /// deterministic open (C4): no run, no receipt, no notification.
    public var operation: OwnerOperation {
        switch self {
        case .open: .openResolvedTarget
        case .reveal: .revealResolvedTarget
        }
    }

    public var gesture: LaunchLogEntry.Gesture {
        switch self {
        case .open: .open
        case .reveal: .reveal
        }
    }

    /// Everywhere reveals potentially executable or compressed downloads.
    /// The curated launcher's open gesture keeps its existing behavior.
    public func effective(for candidate: LauncherCandidate, lane: LauncherLane) -> LauncherOpenAction {
        guard lane == .everywhere, self == .open else { return self }
        let ext = (candidate.path as NSString).pathExtension.lowercased()
        return EverywhereScope.revealExtensions.contains(ext) ? .reveal : self
    }
}

/// Opens a candidate the index produced. Implementations must resolve the
/// target from the candidate (never from UI text), re-check it, and use only
/// non-network platform actions.
public protocol LauncherTargetOpening: Sendable {
    /// Returns a short acknowledgement for diagnostics.
    func open(_ candidate: LauncherCandidate, action: LauncherOpenAction) async throws -> String
}

public enum LauncherError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The id is not in the published index (stale row, or not a candidate).
    case unknownCandidate(String)
    /// The installed policy does not grant the open/reveal operation.
    case operationNotAllowed(OwnerOperation)
    /// The target now falls under an exclusion (Downloads, agent-output, …).
    case excludedTarget(String)
    case missingTarget(String)
    /// The path no longer canonicalises to the indexed path (a symlink moved).
    case targetMoved(String)

    public var description: String {
        switch self {
        case .unknownCandidate(let id): "not in the launcher index: \(id)"
        case .operationNotAllowed(let operation): "installed policy does not allow \(operation.rawValue)"
        case .excludedTarget(let path): "excluded from the launcher: \(path)"
        case .missingTarget(let path): "no longer exists: \(path)"
        case .targetMoved(let path): "moved since indexing: \(path)"
        }
    }
}
