import Foundation
@testable import OmniApplication
import OmniCore
import Testing

// The file-finder fast lane's service and per-keystroke pipeline (H10).

final class LauncherMemorySnapshots: LauncherSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LauncherSnapshot?
    private(set) var saves = 0
    init(_ snapshot: LauncherSnapshot? = nil) { stored = snapshot }
    func load() throws -> LauncherSnapshot? { lock.withLock { stored } }
    func save(_ snapshot: LauncherSnapshot) throws { lock.withLock { stored = snapshot; saves += 1 } }
}

final class LauncherMemoryLog: LaunchLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LaunchLogEntry]
    init(_ entries: [LaunchLogEntry] = []) { stored = entries }
    func append(_ entry: LaunchLogEntry) throws { lock.withLock { stored.append(entry) } }
    func readAll() throws -> [LaunchLogEntry] { lock.withLock { stored } }
    var entries: [LaunchLogEntry] { lock.withLock { stored } }
}

final class LauncherCountingBuilder: LauncherIndexBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: LauncherSnapshot
    private var generation: String?
    private(set) var builds = 0
    init(_ snapshot: LauncherSnapshot, generation: String? = nil) {
        self.snapshot = snapshot
        self.generation = generation
    }
    func build() async throws -> LauncherSnapshot { lock.withLock { builds += 1; return snapshot } }
    func currentDocsGeneration() -> String? { lock.withLock { generation } }
    func set(generation: String?, snapshot: LauncherSnapshot) { lock.withLock { self.generation = generation; self.snapshot = snapshot } }
    var buildCount: Int { lock.withLock { builds } }
}

actor LauncherRecordingOpener: LauncherTargetOpening {
    private(set) var opened: [(id: String, action: LauncherOpenAction)] = []
    var failure: LauncherError?
    func open(_ candidate: LauncherCandidate, action: LauncherOpenAction) async throws -> String {
        if let failure { throw failure }
        opened.append((candidate.id, action))
        return "recorded-\(opened.count)"
    }
    func fail(with error: LauncherError?) { failure = error }
}

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func snapshot(_ titles: [String], generation: String? = "g1", builtAt: Date = now) -> LauncherSnapshot {
    let candidates = titles.map { LauncherCandidate(title: $0, path: "/Users/fixture/Base/\($0.lowercased().replacingOccurrences(of: " ", with: "-")).md", kind: "note", source: .docsIndex) }
    var stats = LauncherIndexStats()
    stats.docs = candidates.count
    return LauncherSnapshot(builtAt: builtAt, docsGeneration: generation, buildMilliseconds: 1, stats: stats, candidates: candidates)
}

private func service(builder: LauncherCountingBuilder, snapshots: LauncherMemorySnapshots = LauncherMemorySnapshots(), log: LauncherMemoryLog = LauncherMemoryLog(), opener: LauncherRecordingOpener = LauncherRecordingOpener(), clock: @escaping @Sendable () -> Date = { now }) -> LauncherService {
    LauncherService(builder: builder, snapshots: snapshots, log: log, opener: opener, home: "/Users/fixture", rebuildInterval: 600, clock: clock)
}

@Test func loadPersistedPublishesTheSnapshotAndDerivesFrecencyFromTheLog() async throws {
    let persisted = snapshot(["Elevator Escape Tracking", "Elevator Notes"])
    let target = persisted.candidates[0].id
    let log = LauncherMemoryLog([LaunchLogEntry(timestamp: now.addingTimeInterval(-60), event: .launch, query: "elev", candidateID: target, ready: false, top1Chosen: false, fellThrough: false)])
    let launcher = service(builder: LauncherCountingBuilder(persisted), snapshots: LauncherMemorySnapshots(persisted), log: log)
    #expect(launcher.indexCount == 0)
    launcher.loadPersisted()
    #expect(launcher.indexCount == 2)
    let results = launcher.query("elev")
    #expect(results.top?.id == target)
    #expect((results.top?.frecency ?? 0) > 0)
}

@Test func refreshBuildsWhenEmptyThenOnlyWhenStaleOrTheDocsGenerationChanges() async throws {
    let builder = LauncherCountingBuilder(snapshot(["One"]), generation: "g1")
    let snapshots = LauncherMemorySnapshots()
    let clock = MutableClock(now)
    let launcher = service(builder: builder, snapshots: snapshots, clock: { clock.now })
    await launcher.refreshIfDue()?.value
    #expect(builder.buildCount == 1)
    #expect(snapshots.saves == 1)
    #expect(launcher.indexCount == 1)
    // Fresh and unchanged: not due.
    clock.advance(60)
    await launcher.refreshIfDue()?.value
    #expect(builder.buildCount == 1)
    // The docs index moved on: due even inside the interval.
    builder.set(generation: "g2", snapshot: snapshot(["One", "Two"], generation: "g2"))
    await launcher.refreshIfDue()?.value
    #expect(builder.buildCount == 2)
    #expect(launcher.indexCount == 2)
    // Stale after the interval.
    clock.advance(601)
    await launcher.refreshIfDue()?.value
    #expect(builder.buildCount == 3)
    // Forced.
    await launcher.refreshIfDue(force: true)?.value
    #expect(builder.buildCount == 4)
}

@Test func aRecentPersistedSnapshotIsNotRebuiltAtStartup() async throws {
    let persisted = snapshot(["One"], generation: "g1", builtAt: now.addingTimeInterval(-30))
    let builder = LauncherCountingBuilder(persisted, generation: "g1")
    let launcher = service(builder: builder, snapshots: LauncherMemorySnapshots(persisted))
    launcher.loadPersisted()
    await launcher.refreshIfDue()?.value
    #expect(builder.buildCount == 0)
}

@Test func launchResolvesByIDOnlyOpensAndLogsAndTeachesFrecency() async throws {
    let persisted = snapshot(["Elevator Escape Tracking", "Elevator Notes"])
    let log = LauncherMemoryLog()
    let opener = LauncherRecordingOpener()
    let launcher = service(builder: LauncherCountingBuilder(persisted), log: log, opener: opener)
    launcher.publish(persisted)
    let cold = launcher.query("elev")
    let target = cold.rows[1].id
    #expect(cold.top?.id != target)

    let context = LaunchContext(query: "elev", rank: 2, top1ID: persisted.candidates[0].id, ready: false, selection: .manual, candidateCount: 2, elapsedMilliseconds: 900)
    try await launcher.launch(candidateID: target, action: .open, context: context)
    let opened = await opener.opened
    #expect(opened.map(\.id) == [target] && opened.first?.action == .open)
    let entry = try #require(log.entries.last)
    #expect(entry.event == .launch && entry.candidateID == target && entry.rank == 2 && !entry.top1Chosen && entry.selection == .manual && entry.gesture == .open && entry.elapsedMilliseconds == 900)
    // Frecency: the picked row now leads for its prefix.
    #expect(launcher.query("elev").top?.id == target)

    // A path or unknown id is never opened.
    await #expect(throws: LauncherError.unknownCandidate("/etc/passwd")) {
        try await launcher.launch(candidateID: "/etc/passwd", action: .open, context: context)
    }
    #expect(await opener.opened.count == 1)

    // A failed open writes nothing.
    await opener.fail(with: .missingTarget(target))
    await #expect(throws: LauncherError.missingTarget(target)) {
        try await launcher.launch(candidateID: target, action: .reveal, context: context)
    }
    #expect(log.entries.count == 1)
}

@Test func fallthroughAndUndoAreLoggedAndUndoForgetsTheLaunch() async throws {
    let persisted = snapshot(["Elevator Escape Tracking", "Elevator Notes"])
    let log = LauncherMemoryLog()
    let launcher = service(builder: LauncherCountingBuilder(persisted), log: log)
    launcher.publish(persisted)
    let target = launcher.query("elev").rows[1].id
    try await launcher.launch(candidateID: target, action: .open, context: LaunchContext(query: "elev", rank: 2, top1ID: nil, ready: false, selection: .manual, candidateCount: 2, elapsedMilliseconds: nil))
    #expect(launcher.query("elev").top?.id == target)
    launcher.recordUndo(candidateID: target, query: "elev")
    #expect(launcher.query("elev").top?.id != target)
    launcher.recordFallthrough(LaunchContext(query: "elev", rank: nil, top1ID: persisted.candidates[0].id, ready: false, selection: nil, candidateCount: 2, elapsedMilliseconds: 1_200, afterUndo: true))
    #expect(log.entries.map(\.event) == [.launch, .undo, .fellThrough])
    let last = try #require(log.entries.last)
    #expect(last.fellThrough && last.afterUndo == true && last.candidateID == nil && last.candidateCount == 2)
}

@Test @MainActor func thePipelineDeliversOnlyTheNewestKeystroke() async throws {
    let persisted = snapshot(["Elevator Escape Tracking", "Elevator Notes", "Lethe Prereg"])
    let launcher = service(builder: LauncherCountingBuilder(persisted))
    launcher.publish(persisted)
    let pipeline = LauncherQueryPipeline(service: launcher)
    var delivered: [String] = []
    for prefix in ["e", "el", "ele", "elev"] {
        pipeline.submit(prefix) { delivered.append($0.query) }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while delivered.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(delivered == ["elev"])
    pipeline.submit("lethe") { delivered.append($0.query) }
    pipeline.cancel()
    try await Task.sleep(for: .milliseconds(50))
    #expect(delivered == ["elev"])
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@Test func theHealthLineNamesALoadingOrEmptyIndexAndClearsOncePublished() async throws {
    // S1: an empty index must not read as "Nothing matches".
    let launcher = service(builder: LauncherCountingBuilder(snapshot([])))
    #expect(launcher.healthLine == "Launcher index is loading")
    await launcher.refreshIfDue()?.value
    #expect(launcher.healthLine == "Launcher index is empty")
    launcher.publish(snapshot(["One"]))
    #expect(launcher.healthLine == nil)
}
