import Foundation
@testable import GlacierPronunciation
import OmniModels
import OmniPresentation
import Testing

private final class PronunciationFixtureProcess: CLIProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data]
    private var finished = false
    private var stops = 0
    private var starts = 0
    private var written = Data()
    private let exitCode: Int32
    private let hangAtEnd: Bool
    private let terminationGate: PronunciationTerminationGate?
    init(events: [[String: Any]], exitCode: Int32 = 0, hangAtEnd: Bool = false,
         terminationGate: PronunciationTerminationGate? = nil) throws {
        lines = try events.map { try JSONSerialization.data(withJSONObject: $0) }
        self.exitCode = exitCode
        self.hangAtEnd = hangAtEnd
        self.terminationGate = terminationGate
    }
    func start() throws { lock.withLock { starts += 1 } }
    func write(_ data: Data) throws { lock.withLock { written.append(data) } }
    func closeStdin() {}
    func nextLine(until deadline: ContinuousClock.Instant) async throws -> Data? {
        let next: Data? = lock.withLock { lines.isEmpty ? nil : lines.removeFirst() }
        if let next { return next }
        if hangAtEnd { try await Task.sleep(for: .seconds(30)) }
        lock.withLock { finished = true }
        return nil
    }
    func terminate(graceful: Duration, interruptFirst: Bool) async {
        let ownsStop = lock.withLock { stops += 1; return stops == 1 }
        if ownsStop {
            if let terminationGate { await terminationGate.wait() }
            lock.withLock { finished = true }
        }
    }
    func waitForExit(_ limit: Duration) async -> Bool {
        if let terminationGate { await terminationGate.wait(); lock.withLock { finished = true } }
        return lock.withLock { finished }
    }
    var terminationStatus: Int32? { lock.withLock { finished ? exitCode : nil } }
    func stderrTail() -> String { "never expose raw stderr" }
    var stopCount: Int { lock.withLock { stops } }
    var startCount: Int { lock.withLock { starts } }
    var stdinText: String { lock.withLock { String(decoding: written, as: UTF8.self) } }
}

private actor PronunciationTerminationGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PronunciationDeltaRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func all() -> [String] { values }
}

private func pronunciationFixtureEvents(exitCode: Int = 0) -> [[String: Any]] {
    let ipa: [String: Any] = ["accent": "GA", "ipa": "ɪˈpɪtəmi", "source": "wiktionary", "pos": "noun"]
    let audio: [String: Any] = ["source": "forvo", "accent": "US", "attribution": "speaker",
                                "online": true, "source_url": "https://forvo.com/word/epitome/"]
    return [
        ["version": 1, "event": "transcriptions", "term": "epitome", "transcriptions": [ipa]],
        ["version": 1, "event": "audio", "audio": audio, "synthetic": false],
        ["version": 1, "event": "complete", "result": ["transcriptions": [ipa], "audio": [audio],
            "errors": [], "played": "forvo:online", "exit_code": exitCode]]
    ]
}

@Test func pronunciationClientStreamsTypedEventsBeforeCompleting() async throws {
    let process = try PronunciationFixtureProcess(events: pronunciationFixtureEvents())
    let recorder = PronunciationDeltaRecorder()
    let client = GlacierPronunciationClient { term in
        #expect(term == "epitome /g literal")
        return process
    }
    let result = try await client.producer("epitome /g literal") { await recorder.append($0) }
    let deltas = await recorder.all()
    #expect(deltas.count == 2)
    #expect(deltas.allSatisfy { $0.hasSuffix("\n") })
    let transcription = try #require(OmniPronunciationPresentation.decode(deltas[0]))
    #expect(transcription.transcriptions.map(\.ipa) == ["/ɪˈpɪtəmi/"])
    #expect(!transcription.isPlaying)
    let playing = try #require(OmniPronunciationPresentation.decode(deltas.joined()))
    #expect(playing.attribution?.text == "speaker · US")
    #expect(playing.isPlaying)
    let completed = try #require(OmniPronunciationPresentation.decode(result))
    #expect(completed.attribution?.sourceLabel == "Pronunciations by Forvo")
    #expect(!completed.isPlaying)
    #expect(completed.exitCode == 0)
    #expect(!result.contains("online only"))
    #expect(!result.contains("never expose"))
    #expect(process.stopCount > 0)
    #expect(process.stdinText == "epitome /g literal")
}

@Test func pronunciationClientKeepsSyntheticAndPartialResults() async throws {
    let synthetic: [String: Any] = ["source": "say", "accent": "synthetic", "attribution": "Samantha", "synthetic": true]
    let events: [[String: Any]] = [
        ["version": 1, "event": "transcriptions", "term": "unknown", "transcriptions": []],
        ["version": 1, "event": "audio", "audio": synthetic, "voice": "Samantha", "synthetic": true],
        ["version": 1, "event": "complete", "result": ["transcriptions": [], "audio": [synthetic],
            "errors": [["source": "wiktionary", "message": "network failed"]],
            "played": "say:Samantha", "exit_code": 2]]
    ]
    let process = try PronunciationFixtureProcess(events: events, exitCode: 2)
    let client = GlacierPronunciationClient { _ in process }
    let result = try await client.producer("unknown") { _ in }
    let presentation = try #require(OmniPronunciationPresentation.decode(result))
    #expect(presentation.attribution?.text == "Samantha · synthetic")
    #expect(presentation.sources.first?.failureReason == "network failed")
    #expect(presentation.transcriptions.isEmpty)
    #expect(presentation.sourcesTried == ["Wiktionary", "CMUdict"])
}

@Test func pronunciationClientRefusesIncompleteOrWrongVersionResponses() async throws {
    for events in [Array(pronunciationFixtureEvents().dropLast()), [["version": 99, "event": "complete"]]] {
        let process = try PronunciationFixtureProcess(events: events)
        let client = GlacierPronunciationClient { _ in process }
        await #expect(throws: EphemeralToolFailure.self) {
            try await client.producer("epitome") { _ in }
        }
        #expect(process.stopCount > 0)
    }
}

@Test func pronunciationClientCancellationTerminatesOwnedProcess() async throws {
    let process = try PronunciationFixtureProcess(events: [pronunciationFixtureEvents()[0]], hangAtEnd: true)
    let recorder = PronunciationDeltaRecorder()
    let client = GlacierPronunciationClient { _ in process }
    let task = Task { try await client.producer("epitome") { await recorder.append($0) } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await recorder.all().isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(process.stopCount > 0)
}

@Test func pronunciationClientNeverLaunchesEmptyInput() async {
    let client = GlacierPronunciationClient { _ in
        Issue.record("Empty input must not invoke pron or read the clipboard")
        throw EphemeralToolFailure("fixture")
    }
    await #expect(throws: EphemeralToolFailure.self) { try await client.producer("  ") { _ in } }
}

@Test func bundledRuntimeRejectsInterpreterSymlinkOutsideBundle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-pron-paths-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("bundle", isDirectory: true)
    let bin = bundle.appendingPathComponent("runtime/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("python3"),
                                              withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
    let paths = GlacierPronunciationPaths(bundleRoot: bundle,
                                           supportDirectory: root.appendingPathComponent("support"))
    #expect(throws: EphemeralToolFailure.self) { _ = try paths.prepare() }
}

@Test func pronunciationRapidReplacementWaitsForOldPlayerExit() async throws {
    let gate = PronunciationTerminationGate()
    let first = try PronunciationFixtureProcess(events: [], hangAtEnd: true, terminationGate: gate)
    let second = try PronunciationFixtureProcess(events: pronunciationFixtureEvents())
    let third = try PronunciationFixtureProcess(events: pronunciationFixtureEvents())
    let client = GlacierPronunciationClient { term in
        switch term { case "first": first; case "second": second; default: third }
    }
    let firstTask = Task { try await client.producer("first") { _ in } }
    while first.startCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
    firstTask.cancel()
    while first.stopCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
    let secondTask = Task { try await client.producer("second") { _ in } }
    try await Task.sleep(for: .milliseconds(20))
    let thirdTask = Task { try await client.producer("third") { _ in } }
    try await Task.sleep(for: .milliseconds(20))
    #expect(second.startCount == 0)
    #expect(third.startCount == 0)
    await gate.release()
    await #expect(throws: CancellationError.self) { try await firstTask.value }
    await #expect(throws: CancellationError.self) { try await secondTask.value }
    let result = try await thirdTask.value
    #expect(OmniPronunciationPresentation.decode(result)?.transcriptions.first?.source == "Wiktionary")
    #expect(third.startCount == 1)
}
