import Foundation

/// The exact-id lane's map (D1, decision surface 569d5a7cf925cbd7), built
/// from the candidates the lanes already loaded, so a hit is always something
/// the launcher can open, and nothing on the keystroke path starts a process
/// or reads a file. Three keys, in this precedence per id:
///
/// 1. a docs-index row's `frontmatter.id` (either lane, and the project
///    READMEs folded into their folder rows), authoritative;
/// 2. a run folder's 16-hex name prefix;
/// 3. a loaded file's `_<16hex>.<ext>` filename suffix (the filename ADR's
///    id), only for a path no docs-index row claims: it covers a document
///    written since the last docs-index refresh (steering, 2026-10-10).
///
/// Staleness is the docs-index refresh plus the everywhere watcher.
public struct LauncherIDMap: Sendable {
    public struct Hit: Sendable, Equatable {
        public let candidate: LauncherCandidate
        /// The lane that holds the row; its opener launches it.
        public let lane: LauncherLane
        public let namespace: OmniIDAddress.Namespace
        public let key: Key
    }

    /// Where a hit's id came from, in precedence order.
    public enum Key: Int, Sendable, Equatable, Comparable {
        case documentIndex
        case runFolder
        case filename

        public static func < (lhs: Key, rhs: Key) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The pad's launcher body shows at most this many rows (C50).
    public static let rowCap = LauncherIndex.candidateCap

    public static let empty = LauncherIDMap(curated: [], everywhere: [])

    private let hitsByID: [String: [Hit]]

    public init(curated: [LauncherCandidate], everywhere: [LauncherCandidate], addressOnly: [LauncherCandidate] = []) {
        var hits: [String: [Hit]] = [:]
        var seenPaths: Set<String> = []
        // A docs-index row claims its path in either lane: a filename id never
        // overrides it, even when the two disagree.
        let claimed = Set((curated + everywhere + addressOnly).filter { $0.source == .docsIndex }.map(\.path))
        // Curated first: where both lanes hold a path, the curated row (and
        // its opener) wins, as in the widened union (C70).
        for (lane, candidates) in [(LauncherLane.curated, curated + addressOnly), (.everywhere, everywhere)] {
            for candidate in candidates where !seenPaths.contains(candidate.path) {
                let entry: (String, OmniIDAddress.Namespace, Key)?
                if candidate.source == .docsIndex {
                    entry = candidate.documentID.map { ($0, .doc, .documentIndex) }
                } else if candidate.kind == "run-folder", let id = OmniIDAddress.runFolderID(candidate.basename) {
                    entry = (id, .run, .runFolder)
                } else if candidate.source == .files, !claimed.contains(candidate.path), let id = OmniIDAddress.filenameID(candidate.basename) {
                    entry = (id, .doc, .filename)
                } else {
                    entry = nil
                }
                guard let (id, namespace, key) = entry else { continue }
                seenPaths.insert(candidate.path)
                hits[id, default: []].append(Hit(candidate: candidate, lane: lane, namespace: namespace, key: key))
            }
        }
        hitsByID = hits
    }

    public var count: Int { hitsByID.count }

    /// Docs-index documents, then the run folder, then filename-id files; a
    /// namespace prefix narrows. Copies of one id (the same document in two
    /// run folders, worktree duplicates) order most recent first, then
    /// curated before everywhere, then by path, so Enter's row is stable.
    /// At most fifteen rows, as for every launcher query.
    public func hits(for address: OmniIDAddress) -> [Hit] {
        let all = hitsByID[address.id] ?? []
        let narrowed = address.namespace.map { namespace in all.filter { $0.namespace == namespace } } ?? all
        let order: (Hit, Hit) -> Bool = { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            let left = lhs.candidate.modified ?? .distantPast
            let right = rhs.candidate.modified ?? .distantPast
            if left != right { return left > right }
            if lhs.lane != rhs.lane { return lhs.lane == .curated }
            return lhs.candidate.path < rhs.candidate.path
        }
        let ordered = narrowed.sorted(by: order)
        var kept = Array(ordered.prefix(Self.rowCap))
        // Many copies never crowd out the run folder (D1: both appear).
        if kept.count == Self.rowCap, !kept.contains(where: { $0.key == .runFolder }), let run = ordered.first(where: { $0.key == .runFolder }) {
            kept[kept.count - 1] = run
            kept.sort(by: order)
        }
        return kept
    }

    /// The launcher's answer for an id-shaped query: hit rows are ready (the
    /// address is the judgment), a miss has none. `lane` is the pad's lane.
    public func results(for address: OmniIDAddress, query: String, lane: LauncherLane) -> LauncherResults {
        let hits = hits(for: address)
        guard !hits.isEmpty else {
            return LauncherResults(query: query, rows: [], ready: false, margin: nil, lane: lane, idLookup: .miss)
        }
        var lanes: [String: LauncherLane] = [:]
        for hit in hits { lanes[hit.candidate.id] = hit.lane }
        return LauncherResults(
            query: query,
            rows: hits.map { LauncherScoredRow.exact($0.candidate) },
            ready: true,
            margin: nil,
            lane: lane,
            idLookup: .hit(lanes: lanes)
        )
    }
}
