import CSQLite
import Foundation
import Testing
import OmniCore
@testable import OmniRun

private enum OmniRunTestRoot {
    static func make() throws -> (envelope: URL, root: URL) {
        let envelope = FileManager.default.temporaryDirectory.appendingPathComponent("omni-run-tests-\(UUID().uuidString)", isDirectory: true)
        let root = envelope.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (envelope, root)
    }

    static func remove(_ envelope: URL) { try? FileManager.default.removeItem(at: envelope) }
}

private enum ExternalIndexTouchError: Error { case open, update }

private func touchIndexFromAnotherConnection(_ url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        if database != nil { sqlite3_close(database) }
        throw ExternalIndexTouchError.open
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, "UPDATE runs SET updated_at = updated_at + 1;", nil, nil, nil) == SQLITE_OK else {
        throw ExternalIndexTouchError.update
    }
}

private final class ExternalIndexLock: @unchecked Sendable {
    private var database: OpaquePointer?

    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if database != nil { sqlite3_close(database) }
            database = nil
            throw ExternalIndexTouchError.open
        }
        guard sqlite3_exec(database, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw ExternalIndexTouchError.update
        }
    }

    func unlock() {
        guard let database else { return }
        sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
        sqlite3_close(database)
        self.database = nil
    }

    deinit { unlock() }
}

@Test func transientSQLiteReadFailureDoesNotCacheAnEmptyHistory() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let id = try await store.submit(commandText: "/todo still present")
    let baseline = try #require(await store.indexedRecentRunsIfChanged(since: nil))
    #expect(baseline.receipts.map(\.id) == [id])

    let lock = try ExternalIndexLock(paths.root.appendingPathComponent("runs.sqlite"))
    await #expect(throws: OmniRunError.self) {
        _ = try await store.indexedRecentRunsIfChanged(since: nil)
    }
    lock.unlock()

    // The exclusive transaction made no changes. data_version alone cannot
    // trigger this retry; the failed query must leave the old token stale.
    let recovered = try #require(await store.indexedRecentRunsIfChanged(since: baseline.revision))
    #expect(recovered.receipts.map(\.id) == [id])
    #expect(recovered.revision != baseline.revision)
}

@Test func runIndexRevisionSkipsUnchangedHistoryAndSeesDurableAndExternalUpdates() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let empty = try #require(await store.indexedRecentRunsIfChanged(since: nil))
    #expect(empty.receipts.isEmpty)
    #expect((try await store.indexedRecentRunsIfChanged(since: empty.revision))?.revision == nil)

    let id = try await store.submit(commandText: "/todo revision")
    let submitted = try #require(await store.indexedRecentRunsIfChanged(since: empty.revision))
    #expect(submitted.revision != empty.revision)
    #expect(submitted.receipts.map(\.id) == [id])
    #expect(submitted.receipts.first?.status == .submitted)
    #expect((try await store.indexedRecentRunsIfChanged(since: submitted.revision))?.revision == nil)

    try await store.enqueue(id)
    let queued = try #require(await store.indexedRecentRunsIfChanged(since: submitted.revision))
    #expect(queued.receipts.first?.status == .queued)
    try await store.rebuildQueryIndex()
    let rebuilt = try #require(await store.indexedRecentRunsIfChanged(since: queued.revision))
    #expect(rebuilt.receipts.first?.status == .queued)

    try touchIndexFromAnotherConnection(paths.root.appendingPathComponent("runs.sqlite"))
    let externallyChanged = try #require(await store.indexedRecentRunsIfChanged(since: rebuilt.revision))
    #expect(externallyChanged.revision != rebuilt.revision)
    #expect(externallyChanged.receipts.first?.status == .queued)
}

@Test func developmentRootRequiresContainedNonSymlinkedEnvelope() throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    #expect(throws: OmniRunError.developmentRootMustBeAbsolute) {
        _ = try OmniDevelopmentRoot(validating: URL(string: "relative")!, allowedRoot: paths.envelope)
    }
    #expect(throws: OmniRunError.developmentRootMissing) {
        _ = try OmniDevelopmentRoot(validating: paths.envelope.appendingPathComponent("missing"), allowedRoot: paths.envelope)
    }
    #expect(throws: OmniRunError.pathEscapesDevelopmentRoot) {
        _ = try OmniDevelopmentRoot(validating: paths.envelope.deletingLastPathComponent(), allowedRoot: paths.envelope)
    }
    #expect(throws: OmniRunError.forbiddenDevelopmentRoot(paths.root.path)) {
        _ = try OmniDevelopmentRoot(validating: paths.root, allowedRoot: paths.envelope, forbiddenRoots: [paths.root])
    }
    let link = paths.envelope.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.root)
    #expect(throws: OmniRunError.developmentRootIsSymlink) {
        _ = try OmniDevelopmentRoot(validating: link, allowedRoot: paths.envelope)
    }
    let outside = paths.envelope.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let nestedLink = paths.root.appendingPathComponent("nested-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: nestedLink, withDestinationURL: outside)
    let validated = try OmniDevelopmentRoot(validating: paths.root, allowedRoot: paths.envelope)
    #expect(throws: OmniRunError.pathEscapesDevelopmentRoot) {
        _ = try validated.containedURL(relativePath: "nested-link/new-file")
    }
}

@Test func submissionIsDurableBeforeReturnAndRecordsFrozenEventMetadata() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope, moduleVersion: "module-1", manifestVersion: "freeze-1.0.0")
    let id = try await store.submit(commandText: "/todo write tests")
    let receipt = try #require(await store.receipt(for: id))
    #expect(receipt.status == .submitted)
    #expect(receipt.activeLeases.count == 1)
    #expect(receipt.commandText == "/todo write tests")
    let event = try #require(await store.allEvents().first)
    #expect(event.runID == id)
    #expect(event.actor == .user)
    #expect(event.moduleVersion == "module-1")
    #expect(event.manifestVersion == "freeze-1.0.0")
    #expect(event.priorState == nil)
    #expect(event.newState == .submitted)
    #expect(event.payload.commandText == "/todo write tests")
    #expect(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("events.jsonl").path))
    let line = try #require(String(contentsOf: paths.root.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n").first)
    let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(Set(["event_id", "run_id", "timestamp", "actor", "module_version", "manifest_version", "typed_detail"]).isSubset(of: Set(object.keys)))
}

@Test func concurrentSubmissionsAllocateUniqueMonotonicULIDs() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let ids = try await withThrowingTaskGroup(of: RunID.self, returning: [RunID].self) { group in
        for index in 0..<100 { group.addTask { try await store.submit(commandText: "run \(index)") } }
        var result: [RunID] = []
        for try await id in group { result.append(id) }
        return result
    }
    #expect(Set(ids).count == 100)
    #expect(ids.allSatisfy { $0.rawValue.count == 29 && $0.rawValue.hasPrefix("oi_") })
    #expect((await store.allEvents()).count == 100)
}

@Test func aSecondWriterForTheSameRootFailsClosed() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let first = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    _ = first
    #expect(throws: OmniRunError.storeAlreadyOpen(paths.root.appendingPathComponent("writer.lock").path)) {
        _ = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    }
}

@Test func restartPreservesEventsAndAdvancesAllocator() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var first: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let firstID = try await first!.submit(commandText: "first")
    first = nil
    let second = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let secondID = try await second.submit(commandText: "second")
    #expect(secondID > firstID)
    #expect((await second.recentRuns()).count == 2)
}

@Test func restartPreservesImmutableResultVersionsAndFollowUpViewState() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var store: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let runID = try await store!.submit(commandText: "/email Original")
    try await store!.enqueue(runID)
    try await store!.beginExecution(runID)
    var context = RuntimeRunContext(resultVersions: [
        .init(number: 1, inputText: "/email Original", resultText: "Original draft", operation: .initial),
        .init(number: 2, inputText: "/shorter", resultText: "Short draft", operation: .shorter, sourceVersion: 1),
    ])
    context.followUpState = .init(
        kind: .failed,
        requestID: "request-1",
        sourceVersion: 2,
        visibleText: "/formal",
        message: "provider unavailable"
    )
    try await store!.succeed(runID, summary: "Original draft", runtimeContext: context)
    store = nil

    let restarted = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let restored = try #require(await restarted.receipt(for: runID)?.runtimeContext)
    #expect(restored.resultVersions.map(\.number) == [1, 2])
    #expect(restored.resultVersions[1].sourceVersion == 1)
    #expect(restored.followUpState?.kind == .failed)
    #expect(restored.followUpState?.visibleText == "/formal")
}

@Test func annotationEventsReopenWithVersionAndCancelledDraftRangesIntact() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var store: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let initialText = "/email Hello team"
    let initialNote = OmniTextAnnotation(range: NSRange(location: 7, length: 5), guidance: "Address warmly")
    let runID = try await store!.submit(
        commandText: initialText,
        moduleID: "draft.email",
        runtimeContext: RuntimeRunContext(annotations: [initialNote])
    )
    try await store!.enqueue(runID)
    try await store!.beginExecution(runID)
    try await store!.succeed(runID, summary: "Original")

    let followUpText = "Revised body /formal"
    let followUpNote = OmniTextAnnotation(range: NSRange(location: 0, length: 7), guidance: "Keep this word")
    try await store!.beginFollowUp(
        runID,
        sourceVersion: 1,
        visibleText: followUpText,
        requestID: "first",
        annotations: [followUpNote]
    )
    #expect((await store!.receipt(for: runID))?.runtimeContext?.followUpState?.annotations == [followUpNote])
    _ = try await store!.cancelFollowUp(runID, requestID: "first")
    store = nil

    let restarted = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let restored = try #require(await restarted.receipt(for: runID)?.runtimeContext)
    #expect(RuntimeRunContext.currentVersion == 2)
    #expect(restored.annotations == [initialNote])
    #expect(restored.resultVersions.first?.annotations == [initialNote])
    #expect(restored.followUpState?.visibleText == followUpText)
    #expect(restored.followUpState?.annotations == [followUpNote])

    try await restarted.beginFollowUp(
        runID,
        sourceVersion: 1,
        visibleText: followUpText,
        requestID: "second",
        annotations: [followUpNote]
    )
    #expect(try await restarted.completeFollowUp(runID, requestID: "second", resultText: "Revised", operation: .formal))
    let completed = try #require(await restarted.receipt(for: runID)?.runtimeContext)
    #expect(completed.resultVersions.last?.inputText == followUpText)
    #expect(completed.resultVersions.last?.annotations == [followUpNote])
}

@Test func annotationFieldsDefaultEmptyWhenDecodingOlderRuntimeShapes() throws {
    let context = try JSONDecoder().decode(RuntimeRunContext.self, from: Data("{\"version\":2}".utf8))
    #expect(context.annotations.isEmpty)
    let versionJSON = Data("{\"number\":1,\"inputText\":\"/email Hello\",\"resultText\":\"Hi\",\"operation\":\"initial\",\"createdAt\":0}".utf8)
    #expect(try JSONDecoder().decode(OmniResultVersion.self, from: versionJSON).annotations.isEmpty)
    let stateJSON = Data("{\"kind\":\"cancelled\",\"requestID\":\"r\",\"sourceVersion\":1,\"visibleText\":\"/formal Hi\",\"updatedAt\":0}".utf8)
    #expect(try JSONDecoder().decode(OmniFollowUpState.self, from: stateJSON).annotations.isEmpty)
}

@Test func followUpStoreCompareAndSetAdmitsOneRequestAndRejectsStaleCompletion() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let runID = try await store.submit(commandText: "/email Original", moduleID: "draft.email")
    try await store.enqueue(runID)
    try await store.beginExecution(runID)
    try await store.succeed(runID, summary: "Original", runtimeContext: .init(resultVersions: [
        .init(number: 1, inputText: "/email Original", resultText: "Original", operation: .initial),
    ]))

    let admissions = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for requestID in ["request-a", "request-b"] {
            group.addTask {
                do {
                    try await store.beginFollowUp(runID, sourceVersion: 1, visibleText: "Edited /shorter", requestID: requestID)
                    return true
                } catch {
                    return false
                }
            }
        }
        var values: [Bool] = []
        for await value in group { values.append(value) }
        return values
    }
    #expect(admissions.filter { $0 }.count == 1)
    let active = try #require(await store.receipt(for: runID)?.runtimeContext?.followUpState)
    #expect(active.kind == .pending)

    let cancelledID = try #require(await store.cancelFollowUp(runID))
    #expect(try await store.completeFollowUp(runID, requestID: cancelledID, resultText: "late", operation: .shorter) == false)
    try await store.beginFollowUp(runID, sourceVersion: 1, visibleText: "Replacement /formal", requestID: "request-current")
    #expect(try await store.completeFollowUp(runID, requestID: cancelledID, resultText: "still late", operation: .shorter) == false)
    #expect(try await store.completeFollowUp(runID, requestID: "request-current", resultText: "Formal replacement", operation: .formal))

    let completed = try #require(await store.receipt(for: runID)?.runtimeContext)
    #expect(completed.resultVersions.map(\.number) == [1, 2])
    #expect(completed.resultVersions[1].sourceVersion == 1)
    #expect(completed.fullText == "Formal replacement")
    #expect(completed.followUpState == nil)
}

@Test func followUpStoreRefusesEmptyResultsAndMigratesOlderMarkerOnlyAfterDecode() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var store: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let runID = try await store!.submit(commandText: "/email Original", moduleID: "draft.email")
    try await store!.enqueue(runID)
    try await store!.beginExecution(runID)
    try await store!.succeed(runID, summary: "Original", runtimeContext: .init(resultVersions: [
        .init(number: 1, inputText: "/email Original", resultText: "Original", operation: .initial),
    ]))
    try await store!.beginFollowUp(runID, sourceVersion: 1, visibleText: "Edited /shorter", requestID: "request-empty")
    await #expect(throws: OmniRunError.emptyFollowUpResult) {
        try await store!.completeFollowUp(runID, requestID: "request-empty", resultText: " \n ", operation: .shorter)
    }
    #expect((await store!.receipt(for: runID))?.runtimeContext?.followUpState?.kind == .pending)
    let log = paths.root.appendingPathComponent("events.jsonl")
    let historicalBytes = try Data(contentsOf: log)
    store = nil
    try Data("{\"storage_version\":1}".utf8).write(to: paths.root.appendingPathComponent("storage-version.json"))

    let restarted = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    #expect(try Data(contentsOf: log) == historicalBytes)
    #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.root.appendingPathComponent("storage-version.json"))) as? [String: Int] == ["storage_version": 2])
    #expect((await restarted.receipt(for: runID))?.runtimeContext?.followUpState?.requestID == "request-empty")
}

@Test func validButUnsupportedFinalRuntimeEnvelopeDoesNotTriggerTailRepair() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var store: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let runID = try await store!.submit(commandText: "context")
    try await store!.updateRuntimeContext(runID, context: .init())
    store = nil
    let log = paths.root.appendingPathComponent("events.jsonl")
    var text = try String(contentsOf: log, encoding: .utf8)
    #expect(text.contains("\"version\":2"))
    text = text.replacingOccurrences(of: "\"version\":2", with: "\"version\":3")
    let unsupported = Data(text.dropLast().utf8)
    try unsupported.write(to: log)

    #expect(throws: OmniRunError.self) {
        _ = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    }
    #expect(try Data(contentsOf: log) == unsupported)
}

@Test func truncatedTailIsPhysicallyRepairedBeforeNewAppend() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var store: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    _ = try await store!.submit(commandText: "complete")
    store = nil
    let log = paths.root.appendingPathComponent("events.jsonl")
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"partial\"".utf8))
    try handle.close()
    let restarted = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    _ = try await restarted.submit(commandText: "after repair")
    let data = try Data(contentsOf: log)
    #expect(data.last == 0x0A)
    #expect((await restarted.allEvents()).count == 2)
}

@Test func completeFinalEventWithoutNewlineIsRetainedAndNormalizedBeforeAppend() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var store: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let original = try await store!.submit(commandText: "complete final record")
    store = nil
    let log = paths.root.appendingPathComponent("events.jsonl")
    var data = try Data(contentsOf: log)
    #expect(data.last == 0x0A)
    data.removeLast()
    try data.write(to: log)

    let restarted = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    #expect((try #require(await restarted.receipt(for: original))).commandText == "complete final record")
    _ = try await restarted.submit(commandText: "after normalization")
    #expect((try Data(contentsOf: log)).last == 0x0A)
    #expect((await restarted.allEvents()).count == 2)
}

@Test func interiorCorruptionFailsClosedWithoutRepairOrDerivedWrites() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var store: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    _ = try await store!.submit(commandText: "preserve this event")
    store = nil
    let log = paths.root.appendingPathComponent("events.jsonl")
    let corrupt = Data("{\"not\":\"an event\"}\n".utf8) + (try Data(contentsOf: log))
    try corrupt.write(to: log)
    try? FileManager.default.removeItem(at: paths.root.appendingPathComponent("runs.sqlite"))
    try? FileManager.default.removeItem(at: paths.root.appendingPathComponent("artifacts"))

    #expect(throws: OmniRunError.self) {
        _ = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    }
    #expect(try Data(contentsOf: log) == corrupt)
    #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("runs.sqlite").path))
    #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("artifacts").path))
}

@Test func futureStorageVersionIsRejectedBeforeTailRepairIndexOrArtifactWrites() throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let log = paths.root.appendingPathComponent("events.jsonl")
    let partial = Data("{\"incomplete\"".utf8)
    try partial.write(to: log)
    let marker = paths.root.appendingPathComponent("storage-version.json")
    try Data("{\"storage_version\":3}".utf8).write(to: marker)

    #expect(throws: OmniRunError.unsupportedStorageVersion(3)) {
        _ = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    }
    #expect(try Data(contentsOf: log) == partial)
    #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("runs.sqlite").path))
    #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("artifacts").path))
}

@Test func markerlessPhaseFourLogReconstructsUnchangedBeforeVersionMigration() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    // Use an exactly representable clock so this checks migration semantics,
    // independently of sub-microsecond JSON date rounding.
    var originalStore: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope, now: { Date(timeIntervalSince1970: 1_788_640_000) })
    let id = try await originalStore!.submit(commandText: "phase four receipt")
    let events = await originalStore!.allEvents()
    let receipt = try #require(await originalStore!.receipt(for: id))
    originalStore = nil
    let marker = paths.root.appendingPathComponent("storage-version.json")
    try FileManager.default.removeItem(at: marker)

    let migrated = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    #expect(await migrated.allEvents() == events)
    #expect((try #require(await migrated.receipt(for: id))) == receipt)
    let markerData = try Data(contentsOf: marker)
    let markerObject = try #require(JSONSerialization.jsonObject(with: markerData) as? [String: Int])
    #expect(markerObject["storage_version"] == OmniRunStore.currentStorageVersion)
}

@Test func corruptOrDeletedIndexIsRebuiltFromJSONL() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var store: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let id = try await store!.submit(commandText: "source truth")
    store = nil
    let index = paths.root.appendingPathComponent("runs.sqlite")
    try FileManager.default.removeItem(at: index)
    var rebuilt: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    #expect((try #require(await rebuilt!.receipt(for: id))).commandText == "source truth")
    // Release the rebuilt store before replacing its disposable index file.
    rebuilt = nil
    try Data("not sqlite".utf8).write(to: index)
    let repaired = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    #expect((try #require(await repaired.receipt(for: id))).status == .submitted)
}

@Test func cancellationRequiresReapAndUncertainEffectsBecomeInterrupted() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let id = try await store.submit(commandText: "cancel")
    try await store.enqueue(id)
    try await store.beginExecution(id)
    try await store.requestCancellation(id)
    #expect((try #require(await store.receipt(for: id))).status == .running)
    try await store.acknowledgeCancellation(id, acknowledgement: .init(priorRequestObserved: true, executionStoppedAndReaped: true, ownerAcknowledged: true, effectCertainty: .uncertain))
    let receipt = try #require(await store.receipt(for: id))
    #expect(receipt.status == .interrupted)
    #expect(receipt.effectCertainty == .uncertain)
    #expect(receipt.activeLeases.isEmpty)
    #expect((await store.allEvents()).contains { $0.kind == .effectUncertain })
}

@Test func fullyAcknowledgedCertainCancellationIsCleanAndReleasesDefaultLease() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let id = try await store.submit(commandText: "clean cancel")
    try await store.enqueue(id)
    try await store.beginExecution(id)
    try await store.requestCancellation(id)
    try await store.acknowledgeCancellation(id, acknowledgement: .init(priorRequestObserved: true, executionStoppedAndReaped: true, ownerAcknowledged: true, effectCertainty: .certain))
    let receipt = try #require(await store.receipt(for: id))
    #expect(receipt.status == .cancelled)
    #expect(receipt.activeLeases.isEmpty)
    #expect(Array((await store.allEvents()).map(\.kind).suffix(2)) == [.cancellationAcknowledged, .cancelled])
}

@Test func effectsRequireMatchedAttemptsAndIdempotencyProofForAutomaticRetry() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let id = try await store.submit(commandText: "effect")
    try await store.enqueue(id)
    try await store.beginExecution(id)
    await #expect(throws: OmniRunError.missingEffectAttempt("missing")) {
        try await store.recordEffectOutcome(id, effectID: "missing", outcome: .succeeded, certainty: .certain)
    }
    try await store.recordEffectAttempt(id, effectID: "e1", adapterID: "fixture", operationID: "append", idempotencyKey: "key", idempotencyProven: true)
    try await store.recordEffectOutcome(id, effectID: "e1", outcome: .succeeded, certainty: .certain)
    #expect(try await store.automaticRetryIsAllowed(id))
    await #expect(throws: OmniRunError.duplicateEffectOutcome("e1")) {
        try await store.recordEffectOutcome(id, effectID: "e1", outcome: .succeeded, certainty: .certain)
    }
    #expect(try await store.indexedActiveRuns().map(\.id) == [id])
}

@Test func invalidRetryParentDoesNotCreateASubmittedOrphan() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let missing = RunID(rawValue: "oi_00000000000000000000000000")!
    await #expect(throws: OmniRunError.unknownRun(missing)) {
        _ = try await store.submit(commandText: "retry", retryOf: missing)
    }
    #expect(await store.allEvents().isEmpty)
    #expect(await store.recentRuns().isEmpty)
}

@Test func restartMarksUnmatchedEffectAttemptUncertainBeforeInterrupting() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    var first: OmniRunStore? = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let id = try await first!.submit(commandText: "unmatched")
    try await first!.enqueue(id)
    try await first!.beginExecution(id)
    try await first!.recordEffectAttempt(id, effectID: "e1", adapterID: "fixture", operationID: "append")
    first = nil
    let restarted = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    _ = try await restarted.reconcileIncompleteWork()
    let kinds = await restarted.allEvents().filter { $0.runID == id }.map(\.kind)
    #expect(Array(kinds.suffix(2)) == [.effectUncertain, .interrupted])
}

@Test func retryLeaseRetentionAndReceiptAgreeWithEventLog() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let original = try await store.submit(commandText: "original")
    try await store.enqueue(original)
    try await store.beginExecution(original)
    try await store.fail(original)
    let retry = try await store.submit(commandText: "retry", retryOf: original)
    let lease = try await store.acquireLivenessLease(retry, leaseID: "lease")
    #expect(await store.idleExitIsSuppressed())
    try await store.releaseLivenessLease(retry, leaseID: lease)
    try await store.enqueue(retry)
    try await store.beginExecution(retry)
    try await store.succeed(retry)
    let artifact = paths.root.appendingPathComponent("artifacts").appendingPathComponent(retry.rawValue)
    try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: artifact.appendingPathComponent("proof.txt"))
    try await store.attachArtifact(retry, relativePath: "proof.txt")
    try await store.applyRetention(to: retry)
    let receipt = try #require(await store.receipt(for: retry))
    #expect(receipt.retryOf == original)
    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    let events = await store.allEvents().filter { $0.runID == retry }
    #expect(events.last?.kind == .retentionTombstoned)
    #expect(events.map(\.sequence) == Array(1...events.count))
}

@Test func proposalLifecycleUsesFrozenStateNames() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let id = try await store.submit(commandText: "/unknown")
    try await store.beginProposal(id)
    try await store.markProposalReady(
        id,
        moduleID: "capture.todo",
        planHash: "hash",
        capabilities: ["append-ledger"],
        input: "buy milk",
        inputDigest: "digest",
        retryPolicyProfile: "mutation"
    )
    try await store.confirmProposal(id)
    let receipt = try #require(await store.receipt(for: id))
    #expect(receipt.status == .confirmed)
    #expect(receipt.moduleID == "capture.todo")
    #expect(receipt.planHash == "hash")
    #expect(receipt.proposalCapabilities == ["append-ledger"])
    #expect(receipt.proposalInput == "buy milk")
    #expect(receipt.proposalInputDigest == "digest")
    #expect(receipt.retryPolicyProfile == "mutation")
}

@Test func terminalTransitionReleasesAllLeasesAndRejectsNewLease() async throws {
    let paths = try OmniRunTestRoot.make()
    defer { OmniRunTestRoot.remove(paths.envelope) }
    let store = try OmniRunStore(developmentRoot: paths.root, allowedRoot: paths.envelope)
    let id = try await store.submit(commandText: "leases")
    _ = try await store.acquireLivenessLease(id, leaseID: "custom")
    try await store.enqueue(id)
    try await store.beginExecution(id)
    try await store.succeed(id)
    #expect((try #require(await store.receipt(for: id))).activeLeases.isEmpty)
    await #expect(throws: OmniRunError.self) {
        _ = try await store.acquireLivenessLease(id, leaseID: "too-late")
    }
}
