import Foundation
import OmniCore

/// The file-finder fast lane's application service (H10, C50–C52).
///
/// Holds the published index and the frecency derived from the launch log.
/// Queries are synchronous, pure and a few milliseconds long; index builds
/// run detached at utility priority from the persisted snapshot and publish
/// whole replacements, so a crawl never blocks the pad. Nothing here touches
/// the network, and no slow-lane judge is constructed or called (C52).
///
/// A launch is a deterministic open (C4), not a run: it creates no run, no
/// receipt and no notification. It is recorded in the launch log instead.
public final class LauncherService: @unchecked Sendable {
    /// Display root for row subtitles (`~/…`), from the one launcher
    /// configuration built at startup.
    public let home: String
    /// A background re-crawl runs at most this often (agent-owned default).
    public let rebuildInterval: TimeInterval

    private let builder: any LauncherIndexBuilding
    private let snapshots: any LauncherSnapshotStoring
    private let log: any LaunchLogging
    private let opener: any LauncherTargetOpening
    private let everywhereOpener: any LauncherTargetOpening
    private let everywhere: EverywhereService?
    private let widenedCuratedFilter: @Sendable ([LauncherCandidate]) -> [LauncherCandidate]
    private let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var index = LauncherIndex.empty
    private var frecency = LauncherFrecency.empty
    private var entries: [LaunchLogEntry] = []
    private var snapshotBuiltAt: Date?
    private var snapshotDocsGeneration: String?
    private var snapshotStats: LauncherIndexStats?
    private var lastBuildStarted: Date?
    private var building = false
    private var loadedPersisted = false
    private var lastErrorValue: String?
    private var everywhereCandidates: [LauncherCandidate] = []
    private var widenedIndex = LauncherIndex(candidates: [], lane: .everywhere)
    /// The exact-id lane (D1), rebuilt with the widened index from both
    /// lanes' loaded candidates.
    private var idMap = LauncherIDMap.empty
    /// Folded project READMEs: id-lane addresses only (D1).
    private var addressOnly: [String: LauncherCandidate] = [:]
    /// The published curated snapshot was written before the id lane (D1)
    /// and carries no document ids: refreshes rebuild until one that does is
    /// published (retried at most once a minute after a failed build).
    private var lacksDocumentIDs = false
    static let idRebuildRetry: TimeInterval = 60
    private var publishedEverywhereSourceCount = 0
    private var unionRevision: UInt64 = 0
    private var onIndexChange: (@Sendable () -> Void)?

    public init(
        builder: any LauncherIndexBuilding,
        snapshots: any LauncherSnapshotStoring,
        log: any LaunchLogging,
        opener: any LauncherTargetOpening,
        home: String,
        rebuildInterval: TimeInterval = 600,
        clock: @escaping @Sendable () -> Date = Date.init,
        everywhere: EverywhereService? = nil,
        everywhereOpener: (any LauncherTargetOpening)? = nil,
        widenedCuratedFilter: @escaping @Sendable ([LauncherCandidate]) -> [LauncherCandidate] = { $0 }
    ) {
        self.builder = builder
        self.snapshots = snapshots
        self.log = log
        self.opener = opener
        self.home = home
        self.rebuildInterval = rebuildInterval
        self.clock = clock
        self.everywhere = everywhere
        self.everywhereOpener = everywhereOpener ?? opener
        self.widenedCuratedFilter = widenedCuratedFilter
        everywhere?.setOnChange { [weak self] candidates in self?.publishEverywhere(candidates) }
    }

    // MARK: Index lifecycle

    /// Loads the persisted snapshot and the launch log. Cheap (tens of
    /// milliseconds); callers run it off the main actor. Idempotent.
    public func loadPersisted() {
        lock.lock()
        let alreadyLoaded = loadedPersisted
        loadedPersisted = true
        lock.unlock()
        guard !alreadyLoaded else { return }
        do {
            if let snapshot = try snapshots.load() { publish(snapshot) }
        } catch {
            recordError("snapshot unreadable: \(error)")
        }
        do {
            let loaded = try log.readAll()
            let derived = LauncherFrecency(entries: loaded)
            lock.withLock {
                entries = loaded + entries
                frecency = entries.count == loaded.count ? derived : LauncherFrecency(entries: entries)
            }
        } catch {
            recordError("launch log unreadable: \(error)")
        }
        everywhere?.loadPersisted()
    }

    /// Replaces the index atomically.
    public func publish(_ snapshot: LauncherSnapshot) {
        let replacement = LauncherIndex(candidates: snapshot.candidates)
        let readmes = Dictionary((snapshot.addressOnly ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        lock.withLock {
            index = replacement
            addressOnly = readmes
            lacksDocumentIDs = snapshot.carriesDocumentIDs != true
            snapshotBuiltAt = snapshot.builtAt
            snapshotDocsGeneration = snapshot.docsGeneration
            snapshotStats = snapshot.stats
        }
        rebuildWidenedIndex()
    }

    /// Starts a background rebuild when one is due: nothing indexed yet, the
    /// last build (or the persisted snapshot) is older than
    /// `rebuildInterval`, or the docs index generation changed. Returns the
    /// task so tests can await it; nil while a build is already in flight.
    /// This throttled re-crawl on activation is the freshness strategy
    /// (handoff §3 fallback): the measured build is ~8 s in the background,
    /// which does not justify an FSEvents stream yet.
    @discardableResult
    public func refreshIfDue(force: Bool = false) -> Task<Void, Never>? {
        everywhere?.refreshIfDue(force: force)
        let started: Bool = lock.withLock {
            guard !building else { return false }
            building = true
            return true
        }
        guard started else { return nil }
        let now = clock()
        return Task.detached(priority: .utility) { [self] in
            defer { lock.withLock { building = false } }
            let generation = force ? nil : builder.currentDocsGeneration()
            let due: Bool = lock.withLock {
                if force || index.count == 0 { return true }
                if lacksDocumentIDs { return lastBuildStarted.map { now.timeIntervalSince($0) >= Self.idRebuildRetry } ?? true }
                if let last = lastBuildStarted ?? snapshotBuiltAt, now.timeIntervalSince(last) < rebuildInterval {
                    return generation != nil && generation != snapshotDocsGeneration
                }
                return true
            }
            guard due else { return }
            lock.withLock { lastBuildStarted = now }
            do {
                let snapshot = try await builder.build()
                try Task.checkCancellation()
                do {
                    try snapshots.save(snapshot)
                } catch {
                    recordError("snapshot not saved: \(error)")
                }
                publish(snapshot)
            } catch {
                recordError("index build failed: \(error)")
            }
        }
    }

    /// The service's clock (tests inject one).
    public func now() -> Date { clock() }

    /// Why the launcher cannot answer yet, for the pad's route line; nil when
    /// an index is published. Without it an empty index would read as
    /// "Nothing matches" and every Enter would quietly become a proposal.
    public var healthLine: String? {
        lock.withLock {
            guard index.count == 0 else { return nil }
            if building || lastBuildStarted == nil { return "Launcher index is loading" }
            return lastErrorValue == nil ? "Launcher index is empty" : "Launcher index unavailable"
        }
    }

    public var indexCount: Int { lock.withLock { index.count } }
    public var stats: LauncherIndexStats? { lock.withLock { snapshotStats } }
    public var builtAt: Date? { lock.withLock { snapshotBuiltAt } }
    public var lastError: String? { lock.withLock { lastErrorValue } }
    public var logEntries: [LaunchLogEntry] { lock.withLock { entries } }
    public var everywhereStats: EverywhereWalkStats? { everywhere?.stats }
    public var everywhereCount: Int { lock.withLock { widenedIndex.count } }
    public var everywhereSourceCount: Int { lock.withLock { publishedEverywhereSourceCount } }
    public var everywhereSnapshot: EverywhereSnapshot? { everywhere?.snapshot }
    public var everywhereRecoveryDiagnostics: EverywhereRecoveryDiagnostics? { everywhere?.recoveryDiagnostics }
    public var everywhereWatcherDiagnostics: EverywhereWatcherDiagnostics? { everywhere?.watcherDiagnostics }

    public func healthLine(lane: LauncherLane) -> String? {
        lane == .curated ? healthLine : everywhere?.healthLine
    }

    public func setIndexChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onIndexChange = handler }
    }

    private func publishEverywhere(_ candidates: [LauncherCandidate]) {
        lock.withLock { everywhereCandidates = candidates }
        rebuildWidenedIndex()
    }

    private func rebuildWidenedIndex() {
        let (curated, extra, readmes, revision) = lock.withLock {
            unionRevision &+= 1
            return (index.candidates, everywhereCandidates, Array(addressOnly.values), unionRevision)
        }
        let union = LauncherIndexAssembler.union(curated: widenedCuratedFilter(curated), everywhere: extra)
        let replacement = LauncherIndex(candidates: union, lane: .everywhere)
        let ids = LauncherIDMap(curated: curated, everywhere: extra, addressOnly: readmes)
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard unionRevision == revision else { return nil }
            widenedIndex = replacement
            idMap = ids
            publishedEverywhereSourceCount = extra.count
            return onIndexChange
        }
        handler?()
    }

    // MARK: Queries

    /// One keystroke against the published index. Synchronous and pure; the
    /// pad calls it through `LauncherQueryPipeline` per keystroke and
    /// directly at Enter, so Enter always decides on the current text.
    public func query(_ text: String, lane: LauncherLane = .curated) -> LauncherResults {
        let (index, widened, frecency, ids) = lock.withLock { (self.index, widenedIndex, self.frecency, idMap) }
        // An id is an address, looked up before any scoring and in both
        // lanes alike (D1): a hit is ready, a miss has no rows, and neither
        // ever falls through to a proposal.
        if let address = OmniIDAddress(text) {
            return ids.results(for: address, query: LauncherQuery(text).text, lane: lane)
        }
        if lane == .everywhere { return widened.query(text, frecency: frecency, now: clock()) }
        let result = index.query(text, frecency: frecency, now: clock())
        guard !result.ready, LauncherQuery(text).characterCount >= 3 else { return result }
        let count = everywhere == nil || everywhere?.snapshot != nil ? widened.matchCount(text) : nil
        return LauncherResults(query: result.query, rows: result.rows, ready: result.ready, margin: result.margin, everywhereMatchCount: count)
    }

    public var idCount: Int { lock.withLock { idMap.count } }

    public func candidate(id: String, lane: LauncherLane = .curated) -> LauncherCandidate? {
        lock.withLock { (lane == .curated ? index : widenedIndex).candidate(id: id) ?? (lane == .curated ? addressOnly[id] : nil) }
    }

    /// Whether an id miss could be the index still loading or upgrading
    /// (D1): the pad then says so instead of "No document with this id".
    public var idLookupPending: Bool {
        // Until a snapshot with ids is published (a rebuild in flight, or one
        // that failed and will be retried); and while nothing has been built
        // yet. A curated index that failed for good says so through its
        // health line instead.
        let curatedPending = lock.withLock { lacksDocumentIDs || (index.count == 0 && (building || lastBuildStarted == nil)) }
        return curatedPending || everywhere?.documentIDsPending == true
    }

    // MARK: Launches

    /// Opens or reveals the candidate with `candidateID` from the published
    /// index. The id is the only thing the pad supplies: a path typed in the
    /// field never reaches the opener.
    @discardableResult
    public func launch(candidateID: String, action: LauncherOpenAction, context: LaunchContext) async throws -> LauncherCandidate {
        guard let candidate = candidate(id: candidateID, lane: context.lane) else { throw LauncherError.unknownCandidate(candidateID) }
        let effective = action.effective(for: candidate, lane: context.lane)
        let chosenOpener = context.lane == .everywhere ? everywhereOpener : opener
        _ = try await chosenOpener.open(candidate, action: effective)
        append(LaunchLogEntry(
            timestamp: clock(),
            event: .launch,
            query: context.query,
            candidateID: candidate.id,
            path: candidate.path,
            rank: context.rank,
            top1ID: context.top1ID,
            ready: context.ready,
            top1Chosen: context.rank == 1,
            fellThrough: false,
            elapsedMilliseconds: context.elapsedMilliseconds,
            gesture: effective.gesture,
            selection: context.selection,
            candidateCount: context.candidateCount,
            lane: context.lane,
            addressed: OmniIDAddress(context.query) != nil ? true : nil
        ))
        return candidate
    }

    /// Opens or reveals a `/find` picker row (D2): a docs-index path no
    /// launcher row named, through the same openers and checks as a launch,
    /// the curated lane's first, then the everywhere lane's for a path only
    /// it admits (agent-output). Not a launch: nothing is logged or learned.
    public func openFound(path: String, title: String, kind: String, action: LauncherOpenAction) async throws {
        let candidate = LauncherCandidate(title: title, path: path, kind: kind, source: .docsIndex)
        do {
            _ = try await opener.open(candidate, action: action)
        } catch LauncherError.excludedTarget {
            _ = try await everywhereOpener.open(candidate, action: action)
        }
    }

    /// Enter went to the Tier 2 proposal request instead of a row.
    public func recordFallthrough(_ context: LaunchContext) {
        guard context.lane == .curated else { return }
        append(LaunchLogEntry(
            timestamp: clock(),
            event: .fellThrough,
            query: context.query,
            top1ID: context.top1ID,
            ready: context.ready,
            top1Chosen: false,
            fellThrough: true,
            elapsedMilliseconds: context.elapsedMilliseconds,
            candidateCount: context.candidateCount,
            afterUndo: context.afterUndo ? true : nil
        ))
    }

    /// ⌘Z after a launch: that launch was wrong, so frecency forgets it.
    public func recordUndo(candidateID: String, query: String, lane: LauncherLane = .curated) {
        append(LaunchLogEntry(
            timestamp: clock(),
            event: .undo,
            query: query,
            candidateID: candidateID,
            ready: false,
            top1Chosen: false,
            fellThrough: false,
            lane: lane
        ))
    }

    private func append(_ entry: LaunchLogEntry) {
        do {
            try log.append(entry)
        } catch {
            recordError("launch log not written: \(error)")
        }
        lock.withLock {
            entries.append(entry)
            frecency = LauncherFrecency(entries: entries)
        }
    }

    private func recordError(_ message: String) {
        lock.withLock { lastErrorValue = message }
    }

    deinit { everywhere?.stop() }
}

/// Per-keystroke queries with cancellation (the `Task` pattern the service
/// uses for per-run work): each keystroke cancels the previous query's task
/// and bumps a sequence number; a result is delivered only if it is still
/// the newest, so a late batch can never overwrite a newer one.
@MainActor
public final class LauncherQueryPipeline {
    private let service: LauncherService
    private var sequence: UInt64 = 0
    private var task: Task<Void, Never>?

    public init(service: LauncherService) {
        self.service = service
    }

    public var latestSequence: UInt64 { sequence }

    public func submit(_ text: String, lane: LauncherLane = .curated, deliver: @escaping @MainActor (LauncherResults) -> Void) {
        sequence &+= 1
        let current = sequence
        task?.cancel()
        let service = service
        task = Task { [weak self] in
            let results = await Self.query(service, text, lane: lane)
            guard !Task.isCancelled, let self, self.sequence == current else { return }
            deliver(results)
        }
    }

    /// Runs off the main actor (a nonisolated async function executes on
    /// the global executor); the caller's task carries the cancellation.
    nonisolated private static func query(_ service: LauncherService, _ text: String, lane: LauncherLane) async -> LauncherResults {
        service.query(text, lane: lane)
    }

    public func cancel() {
        sequence &+= 1
        task?.cancel()
        task = nil
    }
}
