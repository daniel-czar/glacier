import Foundation

/// The durable W2 index. `last_event_id` is a checkpoint only for changes
/// already applied to these candidates; replay after a crash is therefore safe.
public struct EverywhereSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let builtAt: Date
    public let docsGeneration: String?
    public let lastEventID: UInt64?
    public let stats: EverywhereWalkStats
    public let candidates: [LauncherCandidate]
    /// True when its agent-output docs rows were read with their document
    /// ids (the exact-id lane, D1). Nil on snapshots written before it; the
    /// service then re-reads agent-output once. Older binaries ignore the key.
    public let carriesDocumentIDs: Bool?
    /// A history gap is still unresolved. The stored cursor remains the last
    /// safe checkpoint even when newer hot patches have been published.
    public let recoveryRequired: Bool?
    public let recoveryNotBefore: Date?

    public init(builtAt: Date, docsGeneration: String?, lastEventID: UInt64?, stats: EverywhereWalkStats, candidates: [LauncherCandidate], carriesDocumentIDs: Bool? = true, recoveryRequired: Bool? = nil, recoveryNotBefore: Date? = nil) {
        schemaVersion = Self.schemaVersion
        self.builtAt = builtAt
        self.docsGeneration = docsGeneration
        self.lastEventID = lastEventID
        self.stats = stats
        self.candidates = candidates
        self.carriesDocumentIDs = carriesDocumentIDs
        self.recoveryRequired = recoveryRequired
        self.recoveryNotBefore = recoveryNotBefore
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case builtAt = "built_at"
        case docsGeneration = "docs_generation"
        case lastEventID = "last_event_id"
        case stats, candidates
        case carriesDocumentIDs = "document_ids"
        case recoveryRequired = "recovery_required"
        case recoveryNotBefore = "recovery_not_before"
    }

    public func withEventID(_ eventID: UInt64?) -> EverywhereSnapshot {
        EverywhereSnapshot(builtAt: builtAt, docsGeneration: docsGeneration, lastEventID: eventID, stats: stats, candidates: candidates, carriesDocumentIDs: carriesDocumentIDs, recoveryRequired: recoveryRequired, recoveryNotBefore: recoveryNotBefore)
    }

    public func withRecovery(required: Bool, notBefore: Date?) -> EverywhereSnapshot {
        EverywhereSnapshot(builtAt: builtAt, docsGeneration: docsGeneration, lastEventID: lastEventID,
                           stats: stats, candidates: candidates, carriesDocumentIDs: carriesDocumentIDs,
                           recoveryRequired: required, recoveryNotBefore: notBefore)
    }

    /// Replace only the affected subtree. A zero-row patch removes rows for
    /// a deletion, new opt-out marker, package or linked worktree.
    public func applying(_ patch: EverywhereIndexPatch, home: String, at date: Date, eventID: UInt64?) -> EverywhereSnapshot {
        let prefix = patch.root + "/"
        let isHomeLoosePatch = patch.root == home && !patch.replaceDescendants
        var rows = candidates.filter { candidate in
            if isHomeLoosePatch { return (candidate.path as NSString).deletingLastPathComponent != home }
            return candidate.path != patch.root && !candidate.path.hasPrefix(prefix)
        }
        var seen = Set(rows.map(\.path))
        for candidate in patch.result.candidates where seen.insert(candidate.path).inserted {
            rows.append(candidate)
        }
        var updated = stats
        updated.rowsByArea = [:]
        updated.rowsBySource = [:]
        updated.documentRowsOutsideAgentOutput = 0
        for candidate in rows {
            updated.rowsByArea[Self.areaLabel(candidate, home: home), default: 0] += 1
            updated.rowsBySource[Self.sourceLabel(candidate), default: 0] += 1
            if candidate.source == .files,
               !candidate.path.contains("/agent-output/"),
               !EverywhereScope.mediaExtensions.contains((candidate.path as NSString).pathExtension.lowercased()),
               !EverywhereScope.revealExtensions.contains((candidate.path as NSString).pathExtension.lowercased()) {
                updated.documentRowsOutsideAgentOutput += 1
            }
        }
        if !isHomeLoosePatch {
            updated.collapsedDirectoryPaths.removeAll { $0 == patch.root || $0.hasPrefix(prefix) }
        }
        updated.collapsedDirectoryPaths.append(contentsOf: patch.result.stats.collapsedDirectoryPaths)
        updated.collapsedDirectoryPaths = Array(Set(updated.collapsedDirectoryPaths)).sorted()
        updated.collapsedFolders = updated.collapsedDirectoryPaths.count
        if isHomeLoosePatch {
            updated.unreadableRoots.removeAll { $0 == home }
        } else {
            updated.unreadableRoots.removeAll { $0 == patch.root || $0.hasPrefix(prefix) }
        }
        updated.unreadableRoots.append(contentsOf: patch.result.stats.unreadableRoots)
        updated.unreadableRoots = Array(Set(updated.unreadableRoots)).sorted()
        if patch.root.hasSuffix("/agent-output") || patch.root.hasSuffix("/Tooling") {
            updated.docsIndexRaw = patch.result.stats.docsIndexRaw
            updated.docsIndexMissing = patch.result.stats.docsIndexMissing
        }
        // A patch that re-read agent-output (or an ancestor) carries ids; any
        // other patch keeps the base's answer.
        let agentOutput = home + "/Tooling/agent-output"
        let rereadAgentOutput = !isHomeLoosePatch && (patch.root == agentOutput || agentOutput.hasPrefix(prefix))
        return EverywhereSnapshot(builtAt: date, docsGeneration: patch.updatesDocsGeneration ? patch.docsGeneration : docsGeneration,
                                  lastEventID: eventID, stats: updated, candidates: rows,
                                  carriesDocumentIDs: rereadAgentOutput ? true : carriesDocumentIDs,
                                  recoveryRequired: recoveryRequired, recoveryNotBefore: recoveryNotBefore)
    }

    private static func areaLabel(_ candidate: LauncherCandidate, home: String) -> String {
        let path = candidate.path
        if path.contains("/Library/Mobile Documents/") { return "iCloud Drive" }
        if path.contains("/Tooling/agent-output/") { return "agent-output" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return "outside home" }
        let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let first = components.first else { return "~ root" }
        if components.count == 1 { return "~ root" }
        if ["Projects", "Lab", "Tooling"].contains(first),
           components.count >= 3 || (components.count == 2 && candidate.source == .roots) {
            return first + "/" + components[1]
        }
        return EverywhereScope.Area.topLevel(first).label
    }

    private static func sourceLabel(_ candidate: LauncherCandidate) -> String {
        if candidate.source == .docsIndex { return "docs-index" }
        if candidate.source == .roots { return candidate.kind == "mass-folder" ? "mass-folder" : "run-folder" }
        let ext = (candidate.path as NSString).pathExtension.lowercased()
        if EverywhereScope.mediaExtensions.contains(ext) { return "media" }
        if EverywhereScope.revealExtensions.contains(ext) { return "reveal" }
        if EverywhereScope.plainTextExtensions.contains(ext) { return "plain-text" }
        return "document"
    }
}

/// One independently scanned subtree. Applying it to the latest snapshot is
/// safe even when another subtree finished scanning first.
public struct EverywhereIndexPatch: Sendable, Equatable {
    public let root: String
    public let result: EverywhereWalkResult
    /// The ordinary home patch replaces loose files only. A home-level
    /// opt-out marker instead invalidates the entire home subtree at once.
    public let replaceDescendants: Bool
    /// The docs generation read before scanning agent-output rows. A later
    /// generation change requires another narrow agent-output patch.
    public let updatesDocsGeneration: Bool
    public let docsGeneration: String?

    public init(root: String, result: EverywhereWalkResult, replaceDescendants: Bool = false,
                updatesDocsGeneration: Bool = false, docsGeneration: String? = nil) {
        self.root = root
        self.result = result
        self.replaceDescendants = replaceDescendants
        self.updatesDocsGeneration = updatesDocsGeneration
        self.docsGeneration = docsGeneration
    }
}

public protocol EverywhereIndexBuilding: Sendable {
    func build() throws -> EverywhereSnapshot
    /// Cheap lexical classification; nil means this event cannot affect rows.
    func affectedRoot(for eventPath: String) -> String?
    /// FSEvents retains directory identity on removed/renamed paths.
    func affectedRoot(for eventPath: String, isDirectory: Bool) -> String?
    func patch(root: String) throws -> EverywhereIndexPatch
    func currentDocsGeneration() -> String?
}

public extension EverywhereIndexBuilding {
    func affectedRoot(for eventPath: String, isDirectory: Bool) -> String? {
        affectedRoot(for: eventPath)
    }
}

public protocol EverywhereSnapshotStoring: Sendable {
    func load() throws -> EverywhereSnapshot?
    func save(_ snapshot: EverywhereSnapshot) throws
}
