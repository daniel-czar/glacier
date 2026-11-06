import Foundation
@testable import OmniApplication
import OmniCore
import Testing

// The exact-id lane in the launcher service (D1, decision surface
// 569d5a7cf925cbd7): the map comes from both lanes' loaded rows, the query
// is answered before any scoring, and refresh is the only staleness story.

private let home = "/Users/fixture"
private let surfaceID = "569d5a7cf925cbd7"
private let reviewID = "1111222233334444"

private final class IDSnapshots: LauncherSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: LauncherSnapshot?
    init(_ value: LauncherSnapshot?) { self.value = value }
    func load() throws -> LauncherSnapshot? { lock.withLock { value } }
    func save(_ snapshot: LauncherSnapshot) throws { lock.withLock { value = snapshot } }
}

private final class IDLog: LaunchLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LaunchLogEntry] = []
    func append(_ entry: LaunchLogEntry) throws { lock.withLock { stored.append(entry) } }
    func readAll() throws -> [LaunchLogEntry] { lock.withLock { stored } }
    var entries: [LaunchLogEntry] { lock.withLock { stored } }
}

private final class IDBuilder: LauncherIndexBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var next: LauncherSnapshot
    private var builds = 0
    init(_ next: LauncherSnapshot) { self.next = next }
    func build() async throws -> LauncherSnapshot { lock.withLock { builds += 1; return next } }
    func currentDocsGeneration() -> String? { lock.withLock { next.docsGeneration } }
    func set(_ snapshot: LauncherSnapshot) { lock.withLock { next = snapshot } }
    var buildCount: Int { lock.withLock { builds } }
}

private actor IDOpener: LauncherTargetOpening {
    private(set) var opened: [(path: String, action: LauncherOpenAction)] = []
    func open(_ candidate: LauncherCandidate, action: LauncherOpenAction) async throws -> String {
        opened.append((candidate.path, action))
        return "recorded"
    }
}

private final class IDEverywhereStore: EverywhereSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: EverywhereSnapshot?
    init(_ value: EverywhereSnapshot?) { self.value = value }
    func load() throws -> EverywhereSnapshot? { lock.withLock { value } }
    func save(_ snapshot: EverywhereSnapshot) throws { lock.withLock { value = snapshot } }
}

private final class IDWatcher: EverywhereChangeWatching, @unchecked Sendable {
    func currentEventID() -> UInt64 { 100 }
    func start(after eventID: UInt64?, handler: @escaping @Sendable (EverywhereFileChanges) -> Void) throws {}
    func stop() {}
}

private final class IDEverywhereBuilder: EverywhereIndexBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private let full: EverywhereSnapshot
    private var patches: [String: [LauncherCandidate]] = [:]
    private var patchCounts: [String: Int] = [:]
    init(_ full: EverywhereSnapshot) { self.full = full }
    func currentDocsGeneration() -> String? { full.docsGeneration }
    func build() throws -> EverywhereSnapshot { full }
    func affectedRoot(for eventPath: String) -> String? { nil }
    func affectedRoot(for eventPath: String, isDirectory: Bool) -> String? { nil }
    func patch(root: String) throws -> EverywhereIndexPatch {
        let rows = lock.withLock { () -> [LauncherCandidate] in
            patchCounts[root, default: 0] += 1
            return patches[root] ?? []
        }
        return EverywhereIndexPatch(root: root, result: EverywhereWalkResult(candidates: rows, stats: EverywhereWalkStats()),
                                    updatesDocsGeneration: true, docsGeneration: full.docsGeneration)
    }
    func setPatch(_ root: String, rows: [LauncherCandidate]) { lock.withLock { patches[root] = rows } }
    func patchCount(_ root: String) -> Int { lock.withLock { patchCounts[root, default: 0] } }
}

private func curatedSnapshot(_ candidates: [LauncherCandidate], generation: String = "g1", carriesDocumentIDs: Bool? = true) -> LauncherSnapshot {
    LauncherSnapshot(builtAt: Date(), docsGeneration: generation, buildMilliseconds: 1, stats: LauncherIndexStats(), candidates: candidates, carriesDocumentIDs: carriesDocumentIDs)
}

private func surfaceDoc(id: String? = surfaceID) -> LauncherCandidate {
    LauncherCandidate(title: "Omni find id lane — decision surface", path: "\(home)/Base/surface_\(surfaceID).md", kind: "spec", source: .docsIndex, documentID: id)
}

private let runFolder = LauncherCandidate(title: "\(surfaceID)_omni_find_id_lane", path: "\(home)/Tooling/agent-output/\(surfaceID)_omni_find_id_lane", kind: "run-folder", source: .roots)
private let agentReview = LauncherCandidate(title: "Review disposition", path: "\(home)/Tooling/agent-output/aaaa000011112222_x/review.md", kind: "review", source: .docsIndex, documentID: reviewID)
private let ghostty = LauncherCandidate(title: "Ghostty", path: "/Applications/Ghostty.app", kind: "app", source: .apps)

private func eventually(_ condition: @escaping () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while await !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await condition())
}

private func service(curated: [LauncherCandidate], everywhere: [LauncherCandidate]) async throws -> (LauncherService, IDOpener, IDOpener) {
    let opener = IDOpener()
    let everywhereOpener = IDOpener()
    let everywhereSnapshot = EverywhereSnapshot(builtAt: Date(), docsGeneration: "g1", lastEventID: 100, stats: EverywhereWalkStats(), candidates: everywhere)
    let everywhereService = EverywhereService(builder: IDEverywhereBuilder(everywhereSnapshot), snapshots: IDEverywhereStore(everywhereSnapshot), watcher: IDWatcher(), home: home)
    let snapshot = curatedSnapshot(curated)
    let launcher = LauncherService(builder: IDBuilder(snapshot), snapshots: IDSnapshots(snapshot), log: IDLog(), opener: opener, home: home, everywhere: everywhereService, everywhereOpener: everywhereOpener)
    launcher.loadPersisted()
    try await eventually { launcher.idCount == 2 }
    return (launcher, opener, everywhereOpener)
}

@Test func anIDQueryAnswersFromBothLanesBeforeAnyScoring() async throws {
    let (launcher, _, _) = try await service(curated: [surfaceDoc(), ghostty], everywhere: [runFolder, agentReview])
    for lane in [LauncherLane.curated, .everywhere] {
        let hit = launcher.query(surfaceID, lane: lane)
        #expect(hit.idLookup != nil && hit.idLookup != .miss)
        #expect(hit.ready)
        #expect(hit.lane == lane)
        #expect(hit.rows.map(\.candidate.path) == [surfaceDoc().path, runFolder.path], "document first")
        #expect(hit.idLookup?.lane(for: surfaceDoc().id) == .curated)
        #expect(hit.idLookup?.lane(for: runFolder.id) == .everywhere)
    }
    #expect(launcher.query("run:\(surfaceID)").rows.map(\.candidate.path) == [runFolder.path])
    #expect(launcher.query("  doc:\(surfaceID) ").rows.map(\.candidate.path) == [surfaceDoc().path])
    // An agent-output document only the everywhere lane holds, found from curated.
    #expect(launcher.query(reviewID).idLookup?.lane(for: agentReview.id) == .everywhere)
    // A miss has no rows and no everywhere offer count.
    let miss = launcher.query("0123456789abcdef")
    #expect(miss.idLookup == .miss && miss.rows.isEmpty && miss.everywhereMatchCount == nil)
    // An uppercase id is the same address; ordinary text keeps today's
    // scored path.
    #expect(launcher.query(surfaceID.uppercased()).idLookup == launcher.query(surfaceID).idLookup)
    #expect(launcher.query("ghostty").idLookup == nil)
}

@Test func aRefreshAddsANewFilesID() async throws {
    let builder = IDBuilder(curatedSnapshot([ghostty], generation: "g1"))
    let launcher = LauncherService(builder: builder, snapshots: IDSnapshots(nil), log: IDLog(), opener: IDOpener(), home: home)
    await launcher.refreshIfDue(force: true)?.value
    #expect(launcher.query(surfaceID).idLookup == .miss)
    // The docs index learns a new file; the next refresh (generation change) maps it.
    builder.set(curatedSnapshot([ghostty, surfaceDoc()], generation: "g2"))
    await launcher.refreshIfDue()?.value
    #expect(launcher.query(surfaceID).rows.map(\.candidate.path) == [surfaceDoc().path])
}

@Test func aPersistedSnapshotWithoutIDsIsRebuiltOnce() async throws {
    // Written by the installed 2026.10.15 binary: docs rows, no ids, no marker.
    let old = curatedSnapshot([surfaceDoc(id: nil), ghostty], carriesDocumentIDs: nil)
    let builder = IDBuilder(curatedSnapshot([surfaceDoc(), ghostty]))
    let launcher = LauncherService(builder: builder, snapshots: IDSnapshots(old), log: IDLog(), opener: IDOpener(), home: home)
    launcher.loadPersisted()
    #expect(launcher.query(surfaceID).idLookup == .miss)
    await launcher.refreshIfDue()?.value
    #expect(builder.buildCount == 1, "rebuilt although the snapshot is fresh")
    #expect(launcher.query(surfaceID).rows.count == 1)
    await launcher.refreshIfDue()?.value
    #expect(builder.buildCount == 1, "only once")
}

@Test func aSnapshotBuiltWithIDsIsNotRebuiltEvenWhenNoRowHasOne() async throws {
    // The marker, not the rows, says the build read ids: an index whose
    // documents carry no ids must not rebuild at every start.
    let fresh = curatedSnapshot([surfaceDoc(id: nil), ghostty])
    let builder = IDBuilder(fresh)
    let launcher = LauncherService(builder: builder, snapshots: IDSnapshots(fresh), log: IDLog(), opener: IDOpener(), home: home)
    launcher.loadPersisted()
    await launcher.refreshIfDue()?.value
    #expect(builder.buildCount == 0)
}

@Test func snapshotsWrittenBeforeTheMarkerDecodeWithoutIt() throws {
    let launcher = #"{"schema_version":1,"built_at":0,"stats":{"apps":0,"folders":0,"docs":0,"files":0,"docs_raw":0,"docs_missing":0,"docs_excluded":0,"docs_worktree_dropped":0,"files_excluded":0,"files_covered_by_docs":0,"files_worktree_dropped":0,"readmes_absorbed":0,"duplicate_paths_dropped":0},"candidates":[]}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    #expect(try decoder.decode(LauncherSnapshot.self, from: Data(launcher.utf8)).carriesDocumentIDs == nil)
    let built = curatedSnapshot([surfaceDoc()])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    #expect(try decoder.decode(LauncherSnapshot.self, from: encoder.encode(built)).carriesDocumentIDs == true)
    // An unrelated subtree patch keeps the old answer; an agent-output patch sets it.
    let old = EverywhereSnapshot(builtAt: Date(), docsGeneration: "g1", lastEventID: 1, stats: EverywhereWalkStats(), candidates: [], carriesDocumentIDs: nil)
    let documents = EverywhereIndexPatch(root: "\(home)/Documents", result: EverywhereWalkResult(candidates: [], stats: EverywhereWalkStats()), updatesDocsGeneration: false, docsGeneration: nil)
    #expect(old.applying(documents, home: home, at: Date(), eventID: 2).carriesDocumentIDs == nil)
    let agentOutput = EverywhereIndexPatch(root: "\(home)/Tooling/agent-output", result: EverywhereWalkResult(candidates: [], stats: EverywhereWalkStats()), updatesDocsGeneration: true, docsGeneration: "g2")
    #expect(old.applying(agentOutput, home: home, at: Date(), eventID: 2).carriesDocumentIDs == true)
}

@Test func aPersistedEverywhereSnapshotWithoutIDsGetsOneAgentOutputPatch() async throws {
    let reviewWithoutID = LauncherCandidate(title: agentReview.title, path: agentReview.path, kind: agentReview.kind, source: .docsIndex)
    let stale = EverywhereSnapshot(builtAt: Date(), docsGeneration: "g1", lastEventID: 100, stats: EverywhereWalkStats(), candidates: [reviewWithoutID], carriesDocumentIDs: nil)
    let builder = IDEverywhereBuilder(stale)
    builder.setPatch("\(home)/Tooling/agent-output", rows: [agentReview])
    let service = EverywhereService(builder: builder, snapshots: IDEverywhereStore(stale), watcher: IDWatcher(), home: home)
    let launcher = LauncherService(builder: IDBuilder(curatedSnapshot([ghostty])), snapshots: IDSnapshots(curatedSnapshot([ghostty])), log: IDLog(), opener: IDOpener(), home: home, everywhere: service)
    launcher.loadPersisted()
    #expect(launcher.query(reviewID).idLookup == .miss)
    await service.refreshIfDue()?.value
    try await eventually { launcher.query(reviewID).rows.count == 1 }
    #expect(builder.patchCount("\(home)/Tooling/agent-output") == 1)
    await service.refreshIfDue()?.value
    #expect(builder.patchCount("\(home)/Tooling/agent-output") == 1, "only once")
}

@Test func anIDHitLaunchesThroughTheLaneThatHoldsItAndIsLogged() async throws {
    let (launcher, opener, everywhereOpener) = try await service(curated: [surfaceDoc(), ghostty], everywhere: [runFolder, agentReview])
    let context = LaunchContext(query: reviewID, rank: 1, top1ID: agentReview.id, ready: true, selection: .ready, candidateCount: 1, elapsedMilliseconds: 5, lane: .everywhere)
    try await launcher.launch(candidateID: agentReview.id, action: .open, context: context)
    #expect(await everywhereOpener.opened.map(\.path) == [agentReview.path])
    #expect(await opener.opened.isEmpty)
    #expect(launcher.logEntries.last?.query == reviewID)
    #expect(launcher.logEntries.last?.lane == .everywhere)
}
