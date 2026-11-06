import Foundation
@testable import OmniApplication
import OmniCore
import Testing

// M1 review fixes in the launcher service (D1): loading state, folded README
// ids, filename-id files, and the launch-log marker.

private let home = "/Users/fixture"

private final class FixSnapshots: LauncherSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: LauncherSnapshot?
    init(_ value: LauncherSnapshot?) { self.value = value }
    func load() throws -> LauncherSnapshot? { lock.withLock { value } }
    func save(_ snapshot: LauncherSnapshot) throws { lock.withLock { value = snapshot } }
}

private final class FixLog: LaunchLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LaunchLogEntry] = []
    func append(_ entry: LaunchLogEntry) throws { lock.withLock { stored.append(entry) } }
    func readAll() throws -> [LaunchLogEntry] { lock.withLock { stored } }
    var entries: [LaunchLogEntry] { lock.withLock { stored } }
}

private struct FixBuilder: LauncherIndexBuilding {
    let snapshot: LauncherSnapshot
    func build() async throws -> LauncherSnapshot { snapshot }
    func currentDocsGeneration() -> String? { snapshot.docsGeneration }
}

private actor FixOpener: LauncherTargetOpening {
    private(set) var opened: [String] = []
    func open(_ candidate: LauncherCandidate, action: LauncherOpenAction) async throws -> String {
        opened.append(candidate.path)
        return "recorded"
    }
}

private final class FixEverywhereStore: EverywhereSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: EverywhereSnapshot?
    init(_ value: EverywhereSnapshot?) { self.value = value }
    func load() throws -> EverywhereSnapshot? { lock.withLock { value } }
    func save(_ snapshot: EverywhereSnapshot) throws { lock.withLock { value = snapshot } }
}

private final class FixWatcher: EverywhereChangeWatching, @unchecked Sendable {
    func currentEventID() -> UInt64 { 100 }
    func start(after eventID: UInt64?, handler: @escaping @Sendable (EverywhereFileChanges) -> Void) throws {}
    func stop() {}
}

private final class FixEverywhereBuilder: EverywhereIndexBuilding, @unchecked Sendable {
    let full: EverywhereSnapshot
    init(_ full: EverywhereSnapshot) { self.full = full }
    func currentDocsGeneration() -> String? { full.docsGeneration }
    func build() throws -> EverywhereSnapshot { full }
    func affectedRoot(for eventPath: String) -> String? { nil }
    func affectedRoot(for eventPath: String, isDirectory: Bool) -> String? { nil }
    func patch(root: String) throws -> EverywhereIndexPatch { throw CocoaError(.fileReadUnknown) }
}

private func snapshot(_ candidates: [LauncherCandidate], addressOnly: [LauncherCandidate]? = nil, marker: Bool? = true) -> LauncherSnapshot {
    LauncherSnapshot(builtAt: Date(), docsGeneration: "g1", buildMilliseconds: 1, stats: LauncherIndexStats(), candidates: candidates, carriesDocumentIDs: marker, addressOnly: addressOnly)
}

private func eventually(_ condition: @escaping () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while await !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await condition())
}

@Test func anIDMissIsPendingWhileTheIndexLoadsOrUpgrades() async throws {
    let empty = LauncherService(builder: FixBuilder(snapshot: snapshot([])), snapshots: FixSnapshots(nil), log: FixLog(), opener: FixOpener(), home: home)
    #expect(empty.idLookupPending, "nothing published yet")
    let old = snapshot([LauncherCandidate(title: "A", path: "\(home)/Base/a.md", kind: "note", source: .docsIndex)], marker: nil)
    let fresh = snapshot([LauncherCandidate(title: "A", path: "\(home)/Base/a.md", kind: "note", source: .docsIndex, documentID: "569d5a7cf925cbd7")])
    let upgrading = LauncherService(builder: FixBuilder(snapshot: fresh), snapshots: FixSnapshots(old), log: FixLog(), opener: FixOpener(), home: home)
    upgrading.loadPersisted()
    #expect(upgrading.idLookupPending, "a pre-id snapshot until its rebuild")
    await upgrading.refreshIfDue()?.value
    #expect(!upgrading.idLookupPending)
    // The everywhere lane reports its own pending ids (no snapshot, or a pre-id one).
    let stale = EverywhereSnapshot(builtAt: Date(), docsGeneration: "g1", lastEventID: 100, stats: EverywhereWalkStats(), candidates: [], carriesDocumentIDs: nil)
    let everywhere = EverywhereService(builder: FixEverywhereBuilder(stale), snapshots: FixEverywhereStore(stale), watcher: FixWatcher(), home: home)
    let both = LauncherService(builder: FixBuilder(snapshot: fresh), snapshots: FixSnapshots(fresh), log: FixLog(), opener: FixOpener(), home: home, everywhere: everywhere)
    both.loadPersisted()
    #expect(both.idLookupPending, "agent-output ids not re-read yet")
}

@Test func aFailedAgentOutputReReadIsRetriedNotForgotten() async throws {
    // The patch keeps failing: the marker stays unset, so the next refresh
    // (after the docs-failure throttle) selects agent-output again.
    let stale = EverywhereSnapshot(builtAt: Date(), docsGeneration: "g1", lastEventID: 100, stats: EverywhereWalkStats(), candidates: [], carriesDocumentIDs: nil)
    let clock = FixClock()
    let everywhere = EverywhereService(builder: FixEverywhereBuilder(stale), snapshots: FixEverywhereStore(stale), watcher: FixWatcher(), home: home, clock: { clock.now })
    await everywhere.refreshIfDue()?.value
    #expect(everywhere.documentIDsPending)
    #expect(everywhere.refreshIfDue() == nil, "throttled after a failure")
    clock.advance(61)
    #expect(everywhere.refreshIfDue() != nil, "retried")
}

private final class FixClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@Test func aFoldedReadmeIDOpensTheReadmeThroughTheCuratedOpener() async throws {
    let folder = LauncherCandidate(title: "ambervale", path: "\(home)/Lab/ambervale", kind: "folder", source: .roots, summary: "Ambervale")
    let readme = LauncherCandidate(title: "Ambervale", path: "\(home)/Lab/ambervale/README.md", kind: "readme", source: .docsIndex, documentID: "fc5ae9afc0eac361")
    let built = snapshot([folder], addressOnly: [readme])
    let opener = FixOpener()
    let log = FixLog()
    let launcher = LauncherService(builder: FixBuilder(snapshot: built), snapshots: FixSnapshots(built), log: log, opener: opener, home: home)
    launcher.loadPersisted()
    let results = launcher.query("fc5ae9afc0eac361")
    #expect(results.rows.map(\.candidate.path) == [readme.path])
    #expect(launcher.query("ambervale").rows.map(\.candidate.path) == [folder.path], "never listed by the scorer")
    let context = LaunchContext(query: "fc5ae9afc0eac361", rank: 1, top1ID: readme.id, ready: true, selection: .ready, candidateCount: 1, elapsedMilliseconds: nil, lane: .curated)
    try await launcher.launch(candidateID: readme.id, action: .open, context: context)
    #expect(await opener.opened == [readme.path])
    #expect(log.entries.last?.addressed == true)
    // An ordinary launch carries no marker.
    try await launcher.launch(candidateID: folder.id, action: .open, context: LaunchContext(query: "amber", rank: 1, top1ID: folder.id, ready: true, selection: .ready, candidateCount: 1, elapsedMilliseconds: nil))
    #expect(log.entries.last?.addressed == nil)
}

@Test func aFreshFileNamedWithAnIDOpensThroughTheEverywhereLane() async throws {
    let id = "569d5a7cf925cbd7"
    let fresh = LauncherCandidate(title: "surface", path: "\(home)/Documents/surface_\(id).md", kind: "md", source: .files, modified: Date())
    let wide = EverywhereSnapshot(builtAt: Date(), docsGeneration: "g1", lastEventID: 100, stats: EverywhereWalkStats(), candidates: [fresh])
    let everywhere = EverywhereService(builder: FixEverywhereBuilder(wide), snapshots: FixEverywhereStore(wide), watcher: FixWatcher(), home: home)
    let curatedOpener = FixOpener()
    let wideOpener = FixOpener()
    let empty = snapshot([LauncherCandidate(title: "Ghostty", path: "/Applications/Ghostty.app", kind: "app", source: .apps)])
    let launcher = LauncherService(builder: FixBuilder(snapshot: empty), snapshots: FixSnapshots(empty), log: FixLog(), opener: curatedOpener, home: home, everywhere: everywhere, everywhereOpener: wideOpener)
    launcher.loadPersisted()
    try await eventually { launcher.idCount == 1 }
    let results = launcher.query(id)
    #expect(results.rows.map(\.candidate.path) == [fresh.path])
    let lane = try #require(results.idLookup?.lane(for: fresh.id))
    try await launcher.launch(candidateID: fresh.id, action: .open, context: LaunchContext(query: id, rank: 1, top1ID: fresh.id, ready: true, selection: .ready, candidateCount: 1, elapsedMilliseconds: nil, lane: lane))
    #expect(await wideOpener.opened == [fresh.path])
    #expect(await curatedOpener.opened.isEmpty)
}

private actor ExcludingOpener: LauncherTargetOpening {
    private(set) var tried: [String] = []
    func open(_ candidate: LauncherCandidate, action: LauncherOpenAction) async throws -> String {
        tried.append(candidate.path)
        if candidate.path.contains("/agent-output/") { throw LauncherError.excludedTarget(candidate.path) }
        return "recorded"
    }
}

@Test func aFindRowOpensThroughTheLauncherOpenersAndNeverEntersTheLog() async throws {
    let curated = ExcludingOpener()
    let wide = FixOpener()
    let log = FixLog()
    let empty = snapshot([])
    let launcher = LauncherService(builder: FixBuilder(snapshot: empty), snapshots: FixSnapshots(empty), log: log, opener: curated, home: home, everywhereOpener: wide)
    try await launcher.openFound(path: "\(home)/Base/a.md", title: "A", kind: "note", action: .open)
    #expect(await curated.tried == ["\(home)/Base/a.md"])
    #expect(await wide.opened.isEmpty)
    // A path only the everywhere lane admits goes through its opener.
    let run = "\(home)/Tooling/agent-output/0c0af4acc2caeaed_x/report.md"
    try await launcher.openFound(path: run, title: "R", kind: "report", action: .reveal)
    #expect(await wide.opened == [run])
    #expect(log.entries.isEmpty, "a picker row is not a launch")
}

private struct FailingBuilder: LauncherIndexBuilding {
    func build() async throws -> LauncherSnapshot { throw CocoaError(.fileReadUnknown) }
    func currentDocsGeneration() -> String? { "g1" }
}

@Test func aFailedUpgradeRebuildStaysPendingAndIsRetried() async throws {
    let old = snapshot([LauncherCandidate(title: "A", path: "\(home)/Base/a.md", kind: "note", source: .docsIndex)], marker: nil)
    let clock = FixClock()
    let launcher = LauncherService(builder: FailingBuilder(), snapshots: FixSnapshots(old), log: FixLog(), opener: FixOpener(), home: home, clock: { clock.now })
    launcher.loadPersisted()
    #expect(launcher.idLookupPending)
    await launcher.refreshIfDue()?.value
    #expect(launcher.idLookupPending, "a failed rebuild is still not a real miss")
    // Not retried within the minute, retried after it.
    clock.advance(10)
    let soon = launcher.refreshIfDue()
    await soon?.value
    clock.advance(61)
    await launcher.refreshIfDue()?.value
    #expect(launcher.idLookupPending)
}
