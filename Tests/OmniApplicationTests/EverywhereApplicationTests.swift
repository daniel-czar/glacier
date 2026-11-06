import Foundation
@testable import OmniApplication
import OmniCore
import Testing

private let h = "/Users/fixture"
private let t = Date(timeIntervalSince1970: 1_790_000_000)

private func row(_ relative: String) -> LauncherCandidate {
    let path = h + "/" + relative
    return LauncherCandidate(title: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                             path: path, kind: (path as NSString).pathExtension, source: .files, added: t)
}

private func snapshot(_ rows: [LauncherCandidate], generation: String? = "g1", eventID: UInt64? = nil, unreadable: [String] = [], builtAt: Date = t) -> EverywhereSnapshot {
    var stats = EverywhereWalkStats()
    stats.unreadableRoots = unreadable
    return EverywhereSnapshot(builtAt: builtAt, docsGeneration: generation, lastEventID: eventID, stats: stats, candidates: rows)
}

private final class MemoryEverywhereStore: EverywhereSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: EverywhereSnapshot?
    private var count = 0
    init(_ value: EverywhereSnapshot? = nil) { self.value = value }
    func load() throws -> EverywhereSnapshot? { lock.withLock { value } }
    func save(_ snapshot: EverywhereSnapshot) throws { lock.withLock { value = snapshot; count += 1 } }
    var stored: EverywhereSnapshot? { lock.withLock { value } }
    var saves: Int { lock.withLock { count } }
}

private final class FakeEverywhereWatcher: EverywhereChangeWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (EverywhereFileChanges) -> Void)?
    private var current: UInt64
    private var after: UInt64?
    init(current: UInt64 = 100) { self.current = current }
    func currentEventID() -> UInt64 { lock.withLock { current } }
    func start(after eventID: UInt64?, handler: @escaping @Sendable (EverywhereFileChanges) -> Void) throws {
        lock.withLock { self.after = eventID; self.handler = handler }
    }
    func stop() { lock.withLock { handler = nil } }
    var startedAfter: UInt64? { lock.withLock { after } }
    func emit(_ changes: EverywhereFileChanges) {
        let callback = lock.withLock { () -> (@Sendable (EverywhereFileChanges) -> Void)? in
            current = max(current, changes.eventID)
            return handler
        }
        callback?(changes)
    }
}

private final class FakeEverywhereBuilder: EverywhereIndexBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var full: EverywhereSnapshot
    private var generation: String?
    private var patchRows: [String: [LauncherCandidate]] = [:]
    private var patchGates: [String: DispatchSemaphore] = [:]
    private var replacingRoots: Set<String> = []
    private var failingRoots: Set<String> = []
    private var patchCounts: [String: Int] = [:]
    private var builds = 0
    private var fullFailuresRemaining = 0
    var gate: DispatchSemaphore?
    var captureBeforeGate = false
    var capturePatchBeforeGate = false
    init(_ snapshot: EverywhereSnapshot, generation: String? = "g1") {
        full = snapshot
        self.generation = generation
    }
    func currentDocsGeneration() -> String? { lock.withLock { generation } }
    func build() throws -> EverywhereSnapshot {
        lock.withLock { builds += 1 }
        let captured = captureBeforeGate ? lock.withLock { full } : nil
        gate?.wait()
        let fail = lock.withLock { () -> Bool in
            guard fullFailuresRemaining > 0 else { return false }
            fullFailuresRemaining -= 1
            return true
        }
        if fail { throw CocoaError(.fileReadUnknown) }
        return captured ?? lock.withLock { full }
    }
    func affectedRoot(for eventPath: String) -> String? {
        guard eventPath.hasPrefix(h + "/") else { return nil }
        if eventPath.contains("/.build/") { return nil }
        if eventPath.hasPrefix(h + "/Tooling/agent-output/") { return h + "/Tooling/agent-output" }
        let parts = eventPath.dropFirst(h.count + 1).split(separator: "/")
        if parts.count == 1, (eventPath as NSString).pathExtension.isEmpty == false { return h }
        return h + "/" + (parts.first.map(String.init) ?? "")
    }
    func affectedRoot(for eventPath: String, isDirectory: Bool) -> String? {
        if eventPath.hasSuffix("/Project.v1") || eventPath.hasSuffix("/Project.v2") {
            return isDirectory ? eventPath : nil
        }
        return affectedRoot(for: eventPath)
    }
    func patch(root: String) throws -> EverywhereIndexPatch {
        let (gate, generation, capturedRows) = lock.withLock { () -> (DispatchSemaphore?, String?, [LauncherCandidate]?) in
            patchCounts[root, default: 0] += 1
            return (patchGates[root], self.generation, capturePatchBeforeGate ? patchRows[root] ?? [] : nil)
        }
        gate?.wait()
        if lock.withLock({ failingRoots.contains(root) }) { throw CocoaError(.fileReadUnknown) }
        let rows: [LauncherCandidate]
        if let capturedRows { rows = capturedRows }
        else { rows = lock.withLock { patchRows[root] ?? [] } }
        let updatesDocs = root.hasSuffix("/agent-output")
        let replaceDescendants = lock.withLock { replacingRoots.contains(root) }
        return EverywhereIndexPatch(root: root, result: EverywhereWalkResult(candidates: rows, stats: EverywhereWalkStats()),
                                    replaceDescendants: replaceDescendants, updatesDocsGeneration: updatesDocs,
                                    docsGeneration: updatesDocs ? generation : nil)
    }
    func setPatch(_ root: String, rows: [LauncherCandidate]) { lock.withLock { patchRows[root] = rows } }
    func setPatchGate(_ root: String, gate: DispatchSemaphore?) { lock.withLock { patchGates[root] = gate } }
    func setReplaceDescendants(_ root: String) { _ = lock.withLock { replacingRoots.insert(root) } }
    func failPatch(_ root: String) { _ = lock.withLock { failingRoots.insert(root) } }
    func setFull(_ snapshot: EverywhereSnapshot, generation: String?) { lock.withLock { full = snapshot; self.generation = generation } }
    func failNextFullBuilds(_ count: Int) { lock.withLock { fullFailuresRemaining = count } }
    var buildCount: Int { lock.withLock { builds } }
    func patchCount(_ root: String) -> Int { lock.withLock { patchCounts[root, default: 0] } }
}

private func eventually(_ condition: @escaping () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

private final class RecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private var sleeps = 0
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    var sleepCount: Int { lock.withLock { sleeps } }
    func sleep(_ seconds: TimeInterval) async throws {
        let deadline = lock.withLock { () -> Date in
            sleeps += 1
            return value.addingTimeInterval(seconds)
        }
        while now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
    }
}

@Test func homeLoosePatchPreservesDownloadsAndAgentOutputRows() {
    let loose = row("old.pdf")
    let download = row("Downloads/receipt.pdf")
    let agent = row("Tooling/agent-output/1234567890abcdef_run/working-memory.md")
    let before = snapshot([loose, download, agent])
    let patch = EverywhereIndexPatch(root: h, result: EverywhereWalkResult(candidates: [row("new.pdf")], stats: EverywhereWalkStats()))
    let after = before.applying(patch, home: h, at: t, eventID: 10)
    #expect(Set(after.candidates.map(\.path)) == [row("new.pdf").path, download.path, agent.path])
}

@Test func coldFullWalkCannotOverwriteAHotDownloadPatch() async throws {
    let builder = FakeEverywhereBuilder(snapshot([]))
    let gate = DispatchSemaphore(value: 0)
    builder.gate = gate
    let watcher = FakeEverywhereWatcher(current: 100)
    let store = MemoryEverywhereStore()
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    let fullTask = try #require(service.refreshIfDue())
    #expect(watcher.startedAfter == 100)
    #expect(!service.isReady)
    #expect(service.refreshIfDue() == nil) // activation during cold walk is idempotent
    let recent = row("Downloads/recent.pdf")
    builder.setPatch(h + "/Downloads", rows: [recent])
    watcher.emit(EverywhereFileChanges(paths: [recent.path], eventID: 101))
    try await eventually { service.candidates.map(\.path).contains(recent.path) }
    #expect(store.saves == 0) // A partial cold index cannot become durable.
    gate.signal()
    await fullTask.value
    #expect(service.isReady)
    #expect(builder.buildCount == 1)
    #expect(service.candidates.map(\.path).contains(recent.path))
    try await eventually { store.stored?.lastEventID == 101 }
    service.stop()
}

@Test func persistedCursorReplaysAndRenameDeletionReplaceSubtree() async throws {
    let old = row("Downloads/old.pdf")
    let store = MemoryEverywhereStore(snapshot([old], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([old]))
    let watcher = FakeEverywhereWatcher(current: 51)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    #expect(service.refreshIfDue() == nil)
    #expect(watcher.startedAfter == 50)
    let renamed = row("Downloads/renamed.pdf")
    builder.setPatch(h + "/Downloads", rows: [renamed])
    watcher.emit(EverywhereFileChanges(paths: [old.path, renamed.path], eventID: 52))
    try await eventually { service.candidates.map(\.path) == [renamed.path] }
    try await eventually { store.stored?.lastEventID == 52 }
    builder.setPatch(h + "/Downloads", rows: [])
    watcher.emit(EverywhereFileChanges(paths: [renamed.path], eventID: 53))
    try await eventually { service.candidates.isEmpty }
    try await eventually { store.stored?.lastEventID == 53 }
    #expect(builder.buildCount == 0)
    service.stop()
}

@Test func directoryFlagReachesBuilderForMissingDottedRenamePath() async throws {
    let old = row("Projects/Project.v1/paper.pdf")
    let renamed = row("Projects/Project.v2/paper.pdf")
    let store = MemoryEverywhereStore(snapshot([old], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([old]))
    builder.setPatch(h + "/Projects/Project.v1", rows: [])
    builder.setPatch(h + "/Projects/Project.v2", rows: [renamed])
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()
    let oldDirectory = h + "/Projects/Project.v1"
    watcher.emit(EverywhereFileChanges(paths: [oldDirectory], eventID: 51, directoryPaths: [oldDirectory]))
    try await eventually { service.candidates.isEmpty }
    let newDirectory = h + "/Projects/Project.v2"
    watcher.emit(EverywhereFileChanges(paths: [newDirectory], eventID: 52, directoryPaths: [newDirectory]))
    try await eventually { service.candidates.map(\.path) == [renamed.path] }
    try await eventually { store.stored?.lastEventID == 52 }
    #expect(builder.buildCount == 0)
    service.stop()
}

@Test func hotDownloadPublishesWhileAnotherEventRootIsSlowButCursorWaitsForBoth() async throws {
    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([]))
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()
    let slow = row("Documents/large.pdf")
    let hot = row("Downloads/new.pdf")
    let gate = DispatchSemaphore(value: 0)
    builder.setPatch(h + "/Documents", rows: [slow])
    builder.setPatchGate(h + "/Documents", gate: gate)
    builder.setPatch(h + "/Downloads", rows: [hot])
    watcher.emit(EverywhereFileChanges(paths: [slow.path, hot.path], eventID: 51))
    try await eventually { service.candidates.map(\.path).contains(hot.path) }
    #expect(!service.candidates.map(\.path).contains(slow.path))
    #expect(store.stored?.lastEventID == 50)
    gate.signal()
    try await eventually { Set(service.candidates.map(\.path)) == [hot.path, slow.path] }
    try await eventually { store.stored?.lastEventID == 51 }
    service.stop()
}

@Test func sameRootBurstRunsOnlyOneDirtyFollowupAndCheckpointsAfterIt() async throws {
    let root = h + "/Documents"
    let old = row("Documents/old.pdf")
    let latest = row("Documents/latest.pdf")
    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([]))
    builder.capturePatchBeforeGate = true
    builder.setPatch(root, rows: [old])
    let gate = DispatchSemaphore(value: 0)
    builder.setPatchGate(root, gate: gate)
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()

    watcher.emit(EverywhereFileChanges(paths: [old.path], eventID: 51))
    try await eventually { builder.patchCount(root) == 1 }
    builder.setPatch(root, rows: [latest])
    for eventID in 52...151 {
        watcher.emit(EverywhereFileChanges(paths: [latest.path], eventID: UInt64(eventID)))
    }
    #expect(builder.patchCount(root) == 1)
    #expect(store.stored?.lastEventID == 50)
    gate.signal()
    gate.signal()
    try await eventually { builder.patchCount(root) == 2 && service.candidates.map(\.path) == [latest.path] }
    try await eventually { store.stored?.lastEventID == 151 }
    #expect(builder.patchCount(root) == 2)
    service.stop()
}

@Test func overlappingPendingRootsMergeIntoOneBroaderScan() async throws {
    let child = h + "/Projects/Project.v1"
    let parent = h + "/Projects"
    let old = row("Projects/Project.v1/old.pdf")
    let newest = row("Projects/Project.v1/new.pdf")
    let sibling = row("Projects/sibling.pdf")
    let hot = row("Downloads/hot.pdf")
    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([]))
    builder.capturePatchBeforeGate = true
    builder.setPatch(child, rows: [old])
    let gate = DispatchSemaphore(value: 0)
    builder.setPatchGate(child, gate: gate)
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()

    watcher.emit(EverywhereFileChanges(paths: [child], eventID: 51, directoryPaths: [child]))
    try await eventually { builder.patchCount(child) == 1 }
    builder.setPatch(parent, rows: [newest, sibling])
    builder.setPatch(h + "/Downloads", rows: [hot])
    watcher.emit(EverywhereFileChanges(paths: [sibling.path], eventID: 52))
    watcher.emit(EverywhereFileChanges(paths: [child], eventID: 53, directoryPaths: [child]))
    watcher.emit(EverywhereFileChanges(paths: [hot.path], eventID: 54))
    try await eventually { service.candidates.map(\.path).contains(hot.path) }
    #expect(builder.patchCount(parent) == 0)
    #expect(store.stored?.lastEventID == 50)
    gate.signal()
    try await eventually { builder.patchCount(parent) == 1 }
    try await eventually { Set(service.candidates.map(\.path)) == [newest.path, sibling.path, hot.path] }
    try await eventually { store.stored?.lastEventID == 54 }
    #expect(builder.patchCount(child) == 1)
    #expect(builder.patchCount(parent) == 1)
    service.stop()
}

@Test func homeLoosePatchDoesNotConsumePendingDescendantEvents() async throws {
    let documents = h + "/Documents"
    let old = row("Documents/old.pdf")
    let latest = row("Documents/latest.pdf")
    let loose = row("loose.pdf")
    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([]))
    builder.capturePatchBeforeGate = true
    builder.setPatch(documents, rows: [old])
    builder.setPatch(h, rows: [loose])
    let gate = DispatchSemaphore(value: 0)
    builder.setPatchGate(documents, gate: gate)
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()

    watcher.emit(EverywhereFileChanges(paths: [old.path], eventID: 51))
    try await eventually { builder.patchCount(documents) == 1 }
    builder.setPatch(documents, rows: [latest])
    watcher.emit(EverywhereFileChanges(paths: [loose.path], eventID: 52))
    watcher.emit(EverywhereFileChanges(paths: [latest.path], eventID: 53))
    #expect(builder.patchCount(h) == 0)
    gate.signal()
    gate.signal()
    try await eventually { builder.patchCount(h) == 1 && builder.patchCount(documents) == 2 }
    try await eventually { Set(service.candidates.map(\.path)) == [loose.path, latest.path] }
    try await eventually { store.stored?.lastEventID == 53 }
    service.stop()
}

@Test func newerHomeLoosePatchCannotSuppressOlderPendingDocumentsScan() async throws {
    let documents = h + "/Documents"
    let old = row("Documents/old.pdf")
    let latest = row("Documents/latest.pdf")
    let loose = row("loose.pdf")
    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([]))
    builder.capturePatchBeforeGate = true
    builder.setPatch(documents, rows: [old])
    builder.setPatch(h, rows: [loose])
    let gate = DispatchSemaphore(value: 0)
    builder.setPatchGate(documents, gate: gate)
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()

    watcher.emit(EverywhereFileChanges(paths: [old.path], eventID: 51))
    try await eventually { builder.patchCount(documents) == 1 }
    builder.setPatch(documents, rows: [latest])
    watcher.emit(EverywhereFileChanges(paths: [latest.path], eventID: 52))
    watcher.emit(EverywhereFileChanges(paths: [loose.path], eventID: 53))
    gate.signal()
    gate.signal()
    try await eventually { builder.patchCount(documents) == 2 && builder.patchCount(h) == 1 }
    try await eventually { Set(service.candidates.map(\.path)) == [loose.path, latest.path] }
    try await eventually { store.stored?.lastEventID == 53 }
    service.stop()
}

@Test func newerHomeOptOutPatchSuppressesOlderDescendantScan() async throws {
    let documents = h + "/Documents"
    let old = row("Documents/old.pdf")
    let latest = row("Documents/latest.pdf")
    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([]))
    builder.capturePatchBeforeGate = true
    builder.setPatch(documents, rows: [old])
    builder.setPatch(h, rows: [])
    builder.setReplaceDescendants(h)
    let gate = DispatchSemaphore(value: 0)
    builder.setPatchGate(documents, gate: gate)
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()

    watcher.emit(EverywhereFileChanges(paths: [old.path], eventID: 51))
    try await eventually { builder.patchCount(documents) == 1 }
    builder.setPatch(documents, rows: [latest])
    watcher.emit(EverywhereFileChanges(paths: [latest.path], eventID: 52))
    watcher.emit(EverywhereFileChanges(paths: [h + "/loose.pdf"], eventID: 53))
    gate.signal()
    gate.signal()
    try await eventually { builder.patchCount(documents) == 2 && builder.patchCount(h) == 1 }
    try await eventually { service.candidates.isEmpty && store.stored?.lastEventID == 53 }
    service.stop()
}

@Test func stoppingDuringBurstDiscardsPendingScanAndCheckpoint() async throws {
    let root = h + "/Documents"
    let document = row("Documents/new.pdf")
    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([]))
    builder.setPatch(root, rows: [document])
    let gate = DispatchSemaphore(value: 0)
    builder.setPatchGate(root, gate: gate)
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()
    watcher.emit(EverywhereFileChanges(paths: [document.path], eventID: 51))
    try await eventually { builder.patchCount(root) == 1 }
    watcher.emit(EverywhereFileChanges(paths: [document.path], eventID: 52))
    service.stop()
    gate.signal()
    try await Task.sleep(for: .milliseconds(50))
    #expect(builder.patchCount(root) == 1)
    #expect(store.stored?.lastEventID == 50)
}

@Test func ignoredEventAdvancesMemoryCursorWithoutSnapshotWriteFeedback() async throws {
    let existing = row("Downloads/existing.pdf")
    let store = MemoryEverywhereStore(snapshot([existing], eventID: 90))
    let watcher = FakeEverywhereWatcher(current: 90)
    let service = EverywhereService(builder: FakeEverywhereBuilder(snapshot([existing])), snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()
    watcher.emit(EverywhereFileChanges(paths: [h + "/Tooling/.build/object.o"], eventID: 91))
    try await eventually { service.snapshot?.lastEventID == 91 }
    #expect(store.saves == 0)
    service.stop()
}

@Test func failedPatchKeepsCursorGapUntilFullRecovery() async throws {
    let recovered = row("Downloads/recovered.pdf")
    let store = MemoryEverywhereStore(snapshot([], eventID: 60))
    let builder = FakeEverywhereBuilder(snapshot([recovered]))
    builder.failPatch(h + "/Downloads")
    let watcher = FakeEverywhereWatcher(current: 60)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    _ = service.refreshIfDue()
    watcher.emit(EverywhereFileChanges(paths: [recovered.path], eventID: 61))
    try await eventually { builder.buildCount == 1 }
    try await eventually { service.candidates.map(\.path) == [recovered.path] }
    try await eventually { store.stored?.lastEventID == 61 }
    service.stop()
}

@Test func docsGenerationAndDeniedRootRecoveryUsePatchesWithoutFullWalks() async throws {
    let oldDoc = row("Tooling/agent-output/1234567890abcdef_run/old.md")
    let newDoc = row("Tooling/agent-output/1234567890abcdef_run/new.md")
    let persisted = snapshot([oldDoc], generation: "g1", eventID: 40)
    let builder = FakeEverywhereBuilder(snapshot([oldDoc], generation: "g2"), generation: "g2")
    builder.setPatch(h + "/Tooling/agent-output", rows: [newDoc])
    let service = EverywhereService(builder: builder, snapshots: MemoryEverywhereStore(persisted), watcher: FakeEverywhereWatcher(current: 41), home: h, clock: { t })
    service.loadPersisted()
    await service.refreshIfDue()?.value
    #expect(builder.buildCount == 0)
    #expect(builder.patchCount(h + "/Tooling/agent-output") == 1)
    #expect(service.candidates.map(\.path) == [newDoc.path])
    #expect(service.refreshIfDue() == nil)
    service.stop()

    let denied = snapshot([], generation: "g1", eventID: 40, unreadable: [h + "/Documents"], builtAt: t.addingTimeInterval(-601))
    let recoveryBuilder = FakeEverywhereBuilder(snapshot([row("Documents/recovered.pdf")]))
    recoveryBuilder.setPatch(h + "/Documents", rows: [row("Documents/recovered.pdf")])
    let recovery = EverywhereService(builder: recoveryBuilder, snapshots: MemoryEverywhereStore(denied), watcher: FakeEverywhereWatcher(current: 41), home: h, clock: { t })
    recovery.loadPersisted()
    await recovery.refreshIfDue()?.value
    #expect(recoveryBuilder.buildCount == 0)
    #expect(recoveryBuilder.patchCount(h + "/Documents") == 1)
    #expect(recovery.candidates.map(\.path) == [row("Documents/recovered.pdf").path])
    recovery.stop()
}

@Test func deniedHomeGetsOneRecoveryCensusWhileHotDownloadsStillPublish() async throws {
    let denied = snapshot([], eventID: nil, unreadable: [h])
    let builder = FakeEverywhereBuilder(denied)
    let watcher = FakeEverywhereWatcher(current: 100)
    let clock = RecoveryClock(t)
    let service = EverywhereService(builder: builder, snapshots: MemoryEverywhereStore(), watcher: watcher, home: h, clock: { clock.now })
    await service.refreshIfDue()?.value
    #expect(builder.buildCount == 1)
    #expect(service.stats?.unreadableRoots == [h])
    #expect(service.refreshIfDue() == nil)

    clock.advance(601)
    let descendant = row("Projects/Foo/recovered.pdf")
    let hot = row("Downloads/arriving.pdf")
    builder.setFull(snapshot([descendant]), generation: "g1")
    builder.setPatch(h + "/Downloads", rows: [hot])
    let gate = DispatchSemaphore(value: 0)
    builder.gate = gate
    let recovery = try #require(service.refreshIfDue())
    #expect(service.refreshIfDue() == nil)
    watcher.emit(EverywhereFileChanges(paths: [hot.path], eventID: 101))
    try await eventually { service.candidates.map(\.path).contains(hot.path) }
    gate.signal()
    await recovery.value
    #expect(Set(service.candidates.map(\.path)) == [hot.path, descendant.path])
    #expect(builder.buildCount == 2)
    #expect(service.refreshIfDue() == nil)
    service.stop()
}

@Test func staleMaintenanceCannotEraseNewerFullWalkDuringOrAfterCompletion() async throws {
    for completeDuringFull in [true, false] {
        let documents = h + "/Documents"
        let restored = row("Documents/restored.pdf")
        let persisted = snapshot([], eventID: 50, unreadable: [documents], builtAt: t.addingTimeInterval(-601))
        let builder = FakeEverywhereBuilder(snapshot([restored]))
        builder.setPatch(documents, rows: []) // old scan result is stale
        let patchGate = DispatchSemaphore(value: 0)
        builder.setPatchGate(documents, gate: patchGate)
        let fullGate = DispatchSemaphore(value: 0)
        if completeDuringFull { builder.gate = fullGate }
        let watcher = FakeEverywhereWatcher(current: 50)
        let store = MemoryEverywhereStore(persisted)
        let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
        service.loadPersisted()
        let oldMaintenance = try #require(service.refreshIfDue())
        try await eventually { builder.patchCount(documents) == 1 }
        watcher.emit(EverywhereFileChanges(paths: [], eventID: 51, requiresFullScan: true))
        try await eventually { builder.buildCount == 1 }
        if completeDuringFull {
            patchGate.signal()
            await oldMaintenance.value
            #expect(!service.candidates.map(\.path).contains(restored.path))
            fullGate.signal()
        } else {
            try await eventually { service.candidates.map(\.path).contains(restored.path) }
            patchGate.signal()
            await oldMaintenance.value
        }
        try await eventually { store.stored?.lastEventID == 51 && store.stored?.candidates.map(\.path) == [restored.path] }
        #expect(service.candidates.map(\.path) == [restored.path])
        service.stop()
    }
}

@Test func olderEventScanCannotPersistPastGapOrOverwriteNewerCensus() async throws {
    for completeDuringFull in [true, false] {
        let old = row("Documents/old.pdf")
        let restored = row("Documents/restored.pdf")
        let persisted = snapshot([old], eventID: 50)
        let builder = FakeEverywhereBuilder(snapshot([restored]))
        builder.setPatch(h + "/Documents", rows: [old])
        let patchGate = DispatchSemaphore(value: 0)
        builder.setPatchGate(h + "/Documents", gate: patchGate)
        let fullGate = DispatchSemaphore(value: 0)
        if completeDuringFull { builder.gate = fullGate }
        let watcher = FakeEverywhereWatcher(current: 50)
        let store = MemoryEverywhereStore(persisted)
        let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h, clock: { t })
        service.loadPersisted()
        _ = service.refreshIfDue()
        watcher.emit(EverywhereFileChanges(paths: [old.path], eventID: 51))
        try await eventually { builder.patchCount(h + "/Documents") == 1 }
        watcher.emit(EverywhereFileChanges(paths: [], eventID: 52, requiresFullScan: true))
        try await eventually { builder.buildCount == 1 }
        if completeDuringFull {
            patchGate.signal()
            try await eventually { service.snapshot?.lastEventID == 52 }
            #expect(store.stored?.lastEventID == 50)
            fullGate.signal()
        } else {
            try await eventually { service.candidates.map(\.path) == [restored.path] }
            patchGate.signal()
        }
        try await eventually { store.stored?.lastEventID == 52 && store.stored?.candidates.map(\.path) == [restored.path] }
        #expect(service.candidates.map(\.path) == [restored.path])
        service.stop()
    }
}

@Test func docsGenerationChangingDuringFullWalkSchedulesOneFollowUp() async throws {
    let oldDoc = row("Tooling/agent-output/1234567890abcdef_run/old.md")
    let newDoc = row("Tooling/agent-output/1234567890abcdef_run/new.md")
    let old = snapshot([oldDoc], generation: "g1", eventID: 40)
    let newer = snapshot([newDoc], generation: "g2")
    let builder = FakeEverywhereBuilder(old)
    let gate = DispatchSemaphore(value: 0)
    builder.gate = gate
    builder.captureBeforeGate = true
    let service = EverywhereService(builder: builder, snapshots: MemoryEverywhereStore(old), watcher: FakeEverywhereWatcher(current: 41), home: h, clock: { t })
    service.loadPersisted()
    let first = try #require(service.refreshIfDue(force: true))
    try await eventually { builder.buildCount == 1 }
    builder.setFull(newer, generation: "g2")
    builder.setPatch(h + "/Tooling/agent-output", rows: [newDoc])
    // Even if the docs-index event arrives after publication, the builder's
    // start generation exposes the change and schedules a follow-up.
    gate.signal()
    await first.value
    try await eventually { builder.patchCount(h + "/Tooling/agent-output") == 1 && service.candidates.map(\.path) == [newDoc.path] }
    #expect(builder.buildCount == 1)
    service.stop()
}

@Test func docsGenerationChangingDuringAgentOutputPatchSchedulesAnotherPatch() async throws {
    let old = row("Tooling/agent-output/1234567890abcdef_run/old.md")
    let newest = row("Tooling/agent-output/1234567890abcdef_run/newest.md")
    let persisted = snapshot([old], generation: "g1", eventID: 70)
    let builder = FakeEverywhereBuilder(persisted, generation: "g2")
    let gate = DispatchSemaphore(value: 0)
    builder.setPatchGate(h + "/Tooling/agent-output", gate: gate)
    builder.setPatch(h + "/Tooling/agent-output", rows: [old])
    let service = EverywhereService(builder: builder, snapshots: MemoryEverywhereStore(persisted), watcher: FakeEverywhereWatcher(current: 70), home: h, clock: { t })
    service.loadPersisted()
    let first = try #require(service.refreshIfDue())
    try await eventually { builder.patchCount(h + "/Tooling/agent-output") == 1 }
    builder.setFull(persisted, generation: "g3")
    builder.setPatch(h + "/Tooling/agent-output", rows: [newest])
    gate.signal()
    gate.signal()
    await first.value
    try await eventually {
        builder.patchCount(h + "/Tooling/agent-output") == 2 &&
            service.snapshot?.docsGeneration == "g3" && service.candidates.map(\.path) == [newest.path]
    }
    #expect(builder.buildCount == 0)
    service.stop()
}

@Test func docsGenerationChangingDuringRunFolderEventAlsoReconcilesAgentOutput() async throws {
    let old = row("Tooling/agent-output/1234567890abcdef_run/old.md")
    let new = row("Tooling/agent-output/1234567890abcdef_run/new.md")
    let persisted = snapshot([old], generation: "g1", eventID: 80)
    let builder = FakeEverywhereBuilder(persisted, generation: "g2")
    let gate = DispatchSemaphore(value: 0)
    builder.setPatchGate(h + "/Tooling/agent-output", gate: gate)
    builder.setPatch(h + "/Tooling/agent-output", rows: [old])
    let watcher = FakeEverywhereWatcher(current: 80)
    let service = EverywhereService(builder: builder, snapshots: MemoryEverywhereStore(persisted), watcher: watcher, home: h, clock: { t })
    service.loadPersisted()
    // Start monitoring directly through the ordinary refresh, which also
    // queues the initial g2 AO maintenance; let it finish before the event.
    let first = try #require(service.refreshIfDue())
    gate.signal()
    await first.value
    builder.setPatch(h + "/Tooling/agent-output", rows: [new])
    watcher.emit(EverywhereFileChanges(paths: [h + "/Tooling/agent-output/1234567890abcdef_run"], eventID: 81))
    try await eventually { builder.patchCount(h + "/Tooling/agent-output") == 2 }
    builder.setFull(persisted, generation: "g3")
    gate.signal()
    gate.signal()
    try await eventually { builder.patchCount(h + "/Tooling/agent-output") == 3 && service.snapshot?.docsGeneration == "g3" }
    #expect(service.candidates.map(\.path) == [new.path])
    #expect(builder.buildCount == 0)
    service.stop()
}

@Test func recoveryStormCoalescesAndTimerRunsWithoutActivation() async throws {
    let clock = RecoveryClock(t)
    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([]))
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h,
                                    clock: { clock.now }, recoverySleep: { try await clock.sleep($0) })
    _ = service.refreshIfDue()
    await service.refreshIfDue(force: true)?.value
    try await eventually { store.stored?.recoveryRequired == false }
    for id in UInt64(51)...150 {
        watcher.emit(EverywhereFileChanges(paths: [], eventID: id, requiresFullScan: true))
    }
    try await eventually { clock.sleepCount == 1 && store.stored?.recoveryRequired == true }
    #expect(builder.buildCount == 1)
    #expect(service.recoveryDiagnostics.lossBatches == 100)
    #expect(service.recoveryDiagnostics.coalescedRecoveryRequests == 99)
    #expect(store.stored?.lastEventID == 50)
    // Hot patches remain visible and persist safely during the cooldown.
    let hot = row("Downloads/cooldown.pdf")
    builder.setPatch(h + "/Downloads", rows: [hot])
    watcher.emit(EverywhereFileChanges(paths: [hot.path], eventID: 151))
    try await eventually { store.stored?.candidates.map(\.path) == [hot.path] }
    #expect(store.stored?.lastEventID == 50)
    builder.setFull(snapshot([hot]), generation: "g1")
    clock.advance(119)
    #expect(builder.buildCount == 1)
    clock.advance(1)
    try await eventually { builder.buildCount == 2 && store.stored?.recoveryRequired == false }
    #expect(store.stored?.lastEventID == 151)
    #expect(service.recoveryDiagnostics.fullFinishes == 2)
    service.stop()
}

@Test func lossDuringCensusKeepsSafeCheckpointUntilLaterScheduledCensus() async throws {
    let clock = RecoveryClock(t)
    let old = row("Documents/old.pdf")
    let hot = row("Downloads/hot.pdf")
    let store = MemoryEverywhereStore(snapshot([old], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([old]))
    let gate = DispatchSemaphore(value: 0)
    builder.gate = gate
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h,
                                    clock: { clock.now }, recoverySleep: { try await clock.sleep($0) })
    _ = service.refreshIfDue()
    watcher.emit(EverywhereFileChanges(paths: [], eventID: 51, requiresFullScan: true))
    try await eventually { builder.buildCount == 1 }
    watcher.emit(EverywhereFileChanges(paths: [], eventID: 52, requiresFullScan: true))
    builder.setPatch(h + "/Downloads", rows: [hot])
    watcher.emit(EverywhereFileChanges(paths: [hot.path], eventID: 53))
    try await eventually { service.candidates.contains(hot) }
    gate.signal()
    try await eventually { service.recoveryDiagnostics.fullFinishes == 1 && clock.sleepCount == 1 }
    try await eventually { store.stored?.candidates.contains(hot) == true }
    #expect(store.stored?.lastEventID == 50)
    #expect(store.stored?.recoveryRequired == true)
    #expect(builder.buildCount == 1)
    builder.setFull(snapshot([old, hot]), generation: "g1")
    gate.signal()
    clock.advance(120)
    try await eventually { store.stored?.lastEventID == 53 && store.stored?.recoveryRequired == false }
    #expect(builder.buildCount == 2)
    service.stop()
}

@Test func dirtySnapshotRestartRetainsCooldownAndRetriesAutonomously() async throws {
    let clock = RecoveryClock(t)
    let dirty = snapshot([row("Documents/cached.pdf")], eventID: 40)
        .withRecovery(required: true, notBefore: t.addingTimeInterval(120))
    let store = MemoryEverywhereStore(dirty)
    let builder = FakeEverywhereBuilder(snapshot([row("Documents/recovered.pdf")]))
    let watcher = FakeEverywhereWatcher(current: 99)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h,
                                    clock: { clock.now }, recoverySleep: { try await clock.sleep($0) })
    _ = service.refreshIfDue()
    try await eventually { clock.sleepCount == 1 }
    #expect(watcher.startedAfter == 40)
    #expect(builder.buildCount == 0)
    #expect(service.candidates == dirty.candidates)
    clock.advance(120)
    try await eventually { store.stored?.recoveryRequired == false && builder.buildCount == 1 }
    #expect(service.recoveryDiagnostics.pendingReason == nil)
    service.stop()
}

@Test func transientFullFailureBacksOffAndRetriesWithoutEvents() async throws {
    let clock = RecoveryClock(t)
    let builder = FakeEverywhereBuilder(snapshot([row("Documents/recovered.pdf")]))
    builder.failNextFullBuilds(2)
    let store = MemoryEverywhereStore()
    let service = EverywhereService(builder: builder, snapshots: store, watcher: FakeEverywhereWatcher(), home: h,
                                    clock: { clock.now }, recoverySleep: { try await clock.sleep($0) })
    await service.refreshIfDue()?.value
    try await eventually { clock.sleepCount == 1 }
    #expect(builder.buildCount == 1)
    #expect(service.recoveryDiagnostics.fullFailures == 1)
    clock.advance(120)
    try await eventually { clock.sleepCount == 2 }
    #expect(builder.buildCount == 2)
    #expect(service.recoveryDiagnostics.nextEligibleRecoveryAt == t.addingTimeInterval(360))
    clock.advance(240)
    try await eventually { builder.buildCount == 3 && store.stored?.recoveryRequired == false }
    #expect(service.recoveryDiagnostics.fullFailures == 2)
    #expect(service.recoveryDiagnostics.fullFinishes == 1)
    service.stop()
}

@Test func stoppingCancelsRecoveryTimerAndInFlightCensusPublication() async throws {
    let clock = RecoveryClock(t)
    let builder = FakeEverywhereBuilder(snapshot([]))
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: MemoryEverywhereStore(snapshot([], eventID: 50)),
                                    watcher: watcher, home: h, clock: { clock.now },
                                    recoverySleep: { try await clock.sleep($0) })
    await service.refreshIfDue(force: true)?.value
    watcher.emit(EverywhereFileChanges(paths: [], eventID: 51, requiresFullScan: true))
    try await eventually { clock.sleepCount == 1 }
    service.stop()
    clock.advance(1_000)
    try await Task.sleep(for: .milliseconds(25))
    #expect(builder.buildCount == 1)
    #expect(service.recoveryDiagnostics.state == "stopped")

    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let blockedBuilder = FakeEverywhereBuilder(snapshot([row("Documents/should-not-publish.pdf")]))
    let gate = DispatchSemaphore(value: 0)
    blockedBuilder.gate = gate
    let blocked = EverywhereService(builder: blockedBuilder, snapshots: store, watcher: FakeEverywhereWatcher(), home: h)
    let task = try #require(blocked.refreshIfDue(force: true))
    try await eventually { blockedBuilder.buildCount == 1 }
    blocked.stop()
    gate.signal()
    await task.value
    #expect(blocked.candidates.isEmpty)
    #expect(blocked.recoveryDiagnostics.fullFinishes == 0)
    #expect(store.stored?.lastEventID == 50)
}

@Test func oldSnapshotDecodesAndDirtyMetadataSurvivesPatchAndRoundTrip() throws {
    let original = snapshot([row("Documents/old.pdf")], eventID: 40)
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(EverywhereSnapshot.self, from: encoded)
    #expect(decoded.recoveryRequired == nil)
    let dirty = original.withRecovery(required: true, notBefore: t.addingTimeInterval(120))
    let patch = EverywhereIndexPatch(root: h + "/Downloads", result: EverywhereWalkResult(candidates: [row("Downloads/new.pdf")], stats: EverywhereWalkStats()))
    let updated = dirty.applying(patch, home: h, at: t, eventID: 40)
    let roundTrip = try JSONDecoder().decode(EverywhereSnapshot.self, from: JSONEncoder().encode(updated))
    #expect(roundTrip.recoveryRequired == true)
    #expect(roundTrip.recoveryNotBefore == t.addingTimeInterval(120))
    #expect(roundTrip.lastEventID == 40)
}

@Test func coldGapCannotPersistHotPatchBeforeFirstCensusCompletes() async throws {
    let clock = RecoveryClock(t)
    let builder = FakeEverywhereBuilder(snapshot([]))
    let gate = DispatchSemaphore(value: 0)
    builder.gate = gate
    let watcher = FakeEverywhereWatcher(current: 100)
    let store = MemoryEverywhereStore()
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h,
                                    clock: { clock.now }, recoverySleep: { try await clock.sleep($0) })
    let census = try #require(service.refreshIfDue())
    try await eventually { builder.buildCount == 1 }
    let hot = row("Downloads/cold-gap.pdf")
    builder.setPatch(h + "/Downloads", rows: [hot])
    watcher.emit(EverywhereFileChanges(paths: [hot.path], eventID: 101))
    try await eventually { service.candidates.contains(hot) }
    watcher.emit(EverywhereFileChanges(paths: [], eventID: 102, requiresFullScan: true))
    try await Task.sleep(for: .milliseconds(25))
    #expect(store.saves == 0)
    #expect(!service.isReady)
    gate.signal()
    await census.value
    try await eventually { store.stored?.recoveryRequired == true }
    #expect(store.stored?.candidates.contains(hot) == true)
    #expect(store.stored?.lastEventID == 101)
    service.stop()
}

@Test func failedColdCensusAndRetryCannotPersistPartialHotPublication() async throws {
    let clock = RecoveryClock(t)
    let builder = FakeEverywhereBuilder(snapshot([]))
    builder.failNextFullBuilds(1)
    let gate = DispatchSemaphore(value: 0)
    builder.gate = gate
    let watcher = FakeEverywhereWatcher(current: 100)
    let store = MemoryEverywhereStore()
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h,
                                    clock: { clock.now }, recoverySleep: { try await clock.sleep($0) })
    let census = try #require(service.refreshIfDue())
    try await eventually { builder.buildCount == 1 }
    let hot = row("Downloads/cold-failure.pdf")
    builder.setPatch(h + "/Downloads", rows: [hot])
    watcher.emit(EverywhereFileChanges(paths: [hot.path], eventID: 101))
    try await eventually { service.candidates.contains(hot) }
    gate.signal()
    await census.value
    try await eventually { clock.sleepCount == 1 }
    #expect(store.saves == 0)
    #expect(!service.isReady)
    clock.advance(120)
    try await eventually { builder.buildCount == 2 }
    // The retry's start marker also must not save the partial publication.
    #expect(store.saves == 0)
    builder.setFull(snapshot([hot]), generation: "g1")
    gate.signal()
    try await eventually { store.stored?.recoveryRequired == false }
    #expect(service.isReady)
    #expect(store.stored?.candidates == [hot])
    service.stop()
}

@Test func nativeExclusionRemovalAtExistingCheckpointRetainsRecoveryObligation() async throws {
    let clock = RecoveryClock(t)
    let store = MemoryEverywhereStore(snapshot([], eventID: 50))
    let builder = FakeEverywhereBuilder(snapshot([]))
    let watcher = FakeEverywhereWatcher(current: 50)
    let service = EverywhereService(builder: builder, snapshots: store, watcher: watcher, home: h,
                                    clock: { clock.now }, recoverySleep: { try await clock.sleep($0) })
    await service.refreshIfDue(force: true)?.value
    try await eventually { store.stored?.recoveryRequired == false }
    let root = h + "/Documents"
    let restored = row("Documents/restored-after-marker-removal.pdf")
    builder.setPatch(root, rows: [restored])
    builder.setFull(snapshot([restored]), generation: "g1")
    // Native exclusions can hide the removal event itself, so the watcher
    // re-enrolls the scope with its last known ID and an explicit recovery gap.
    watcher.emit(EverywhereFileChanges(paths: [root], eventID: 50, requiresFullScan: true, directoryPaths: [root]))
    try await eventually { clock.sleepCount == 1 && store.stored?.recoveryRequired == true }
    #expect(store.stored?.lastEventID == 50)
    #expect(service.recoveryDiagnostics.recoveryRequired)
    #expect(builder.buildCount == 1)
    clock.advance(120)
    try await eventually { store.stored?.recoveryRequired == false && store.stored?.candidates == [restored] }
    #expect(builder.buildCount == 2)
    #expect(store.stored?.lastEventID == 50)
    service.stop()
}
