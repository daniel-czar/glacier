import AppKit
import Foundation
import HyperOverlayCore
@testable import HyperOverlayRuntime
import Testing

// H19 Collect (C104–C110): the persisted queue, the serialized lane and its
// failure semantics, the no-activation paste, and Equalize's golden outputs.

private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("collect-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("clipboard-buffer/state.json")
}

/// Another running app to aim at; never reached by a posted event in these
/// tests, which stop at the checks before any dispatch.
@MainActor private func someOtherApp() throws -> PasteTarget {
    let other = NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleIdentifier == "com.apple.dock"
    } ?? NSWorkspace.shared.runningApplications.first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    return try #require(PasteTarget(other?.processIdentifier))
}

@MainActor private final class FakeEffects: CollectEffects {
    var isTrusted = true
    var releases = true
    var beforeRelease: (() -> Void)?
    var copies: [CollectCopy] = []
    var pastes: [String] = []
    var pasteResult: TargetedPasteFailure?
    var onPaste: (() -> Void)?
    var beforePaste: (@MainActor () async -> Void)?
    var failures: [CollectFailure] = []
    var notices: [String] = []
    var clipboard: (text: String, changeCount: Int)? = ("a  b", 7)
    var normalized: String? = "a b"
    var replaced: [String] = []
    var replaceSucceeds = true

    func trusted() -> Bool { isTrusted }
    func waitForHyperRelease() async -> Bool { beforeRelease?(); return releases }
    func copySelection(from target: PasteTarget, isCurrent: @escaping @MainActor () -> Bool) async -> CollectCopy {
        copies.isEmpty ? .failed : copies.removeFirst()
    }
    func paste(_ text: String, into target: PasteTarget, isCurrent: @escaping @MainActor () -> Bool) async -> TargetedPasteFailure? {
        onPaste?()
        await beforePaste?()
        guard isCurrent() else { return .superseded }
        if pasteResult == nil { pastes.append(text) }
        return pasteResult
    }
    func clipboardText() -> (text: String, changeCount: Int)? { clipboard }
    func normalize(_ text: String) async -> String? { normalized }
    func replaceClipboard(_ text: String, expectedChangeCount: Int) -> Bool {
        if replaceSucceeds { replaced.append(text) }
        return replaceSucceeds
    }
    func showFailure(_ failure: CollectFailure) { failures.append(failure) }
    func showNotice(_ text: String) { notices.append(text) }
}

private let normalizerURL = OverlayPaths.homeDirectory.appendingPathComponent("bin/normalize-text")

@Suite(.serialized) @MainActor struct CollectSuite {

@Test func storePersistsOrderAndReloadsAndRefusesARunawayCeilingWithoutEvicting() throws {
    let url = temporaryStoreURL()
    let store = ClipboardBufferStore(url: url)
    try store.append("A\nline two")
    try store.append("B ||| not a separator")
    try store.append("A\nline two")
    let reloaded = ClipboardBufferStore(url: url)
    #expect(reloaded.items.map(\.text) == ["A\nline two", "B ||| not a separator", "A\nline two"], "duplicates stay separate")
    #expect(Set(reloaded.items.map(\.id)).count == 3)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    // Bytes over the ceiling: refused, the old items untouched.
    let huge = String(repeating: "x", count: ClipboardBufferStore.maximumBytes)
    #expect(throws: ClipboardBufferError.full) { try store.append(huge) }
    #expect(store.count == 3)
}

@Test func aCorruptFileFailsVisiblyAndIsNeverReplaced() async throws {
    let url = temporaryStoreURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: url)
    let store = ClipboardBufferStore(url: url)
    #expect(!store.isReady && store.loadError != nil)
    #expect(throws: (any Error).self) { try store.append("x") }
    #expect(try String(contentsOf: url, encoding: .utf8) == "{not json")
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    await controller.perform(.pasteNext, target: try someOtherApp())
    #expect(effects.failures == [.unavailable])
}

@Test func anUnrecordedSendFoundAtStartPausesPastingUntilResumed() async throws {
    let url = temporaryStoreURL()
    let store = ClipboardBufferStore(url: url)
    try store.append("A")
    try store.mutate { $0.sending = $0.items.map(\.id) }
    let restarted = ClipboardBufferStore(url: url)
    #expect(restarted.isPaused, "a crash between dispatch and consume")
    let effects = FakeEffects()
    let controller = CollectController(store: restarted, effects: effects)
    #expect(controller.statusLine == "Collected · 1 · paused")
    await controller.perform(.pasteNext, target: try someOtherApp())
    #expect(effects.failures == [.paused] && effects.pastes.isEmpty)
    effects.copies = [.text("B")]
    await controller.perform(.collect, target: try someOtherApp())
    #expect(controller.count == 2, "collecting continues while paused")
    controller.resumePasting()
    #expect(!controller.isPaused && controller.count == 2, "resume keeps every item")
    await controller.perform(.pasteNext, target: try someOtherApp())
    #expect(effects.pastes == ["A"])
}

@Test func collectThenPasteNextThenPasteAllConsumesOnlyAfterDispatch() async throws {
    let store = ClipboardBufferStore(url: temporaryStoreURL())
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    let target = try someOtherApp()
    effects.copies = [.text("A"), .text("B"), .text("C1\nC2")]
    for _ in 0..<3 { await controller.perform(.collect, target: target) }
    #expect(controller.statusLine == "Collected · 3")
    #expect(controller.capLabels[OverlayID.collectNext] == "Paste next · 3")
    // The item is still there while the paste is in flight.
    effects.onPaste = { #expect(store.count == 3 && store.state.sending?.count == 1) }
    await controller.perform(.pasteNext, target: target)
    effects.onPaste = nil
    #expect(effects.pastes == ["A"] && controller.count == 2)
    await controller.perform(.pasteNext, target: target)
    await controller.perform(.pasteAll, target: target)
    #expect(effects.pastes == ["A", "B", "C1\nC2"])
    #expect(controller.count == 0 && controller.statusLine == nil && store.state.sending == nil)
    #expect(controller.capLabels[OverlayID.collectAdd] == "Collect")
    // Empty: the bezel says so and nothing is pasted.
    await controller.perform(.pasteNext, target: target)
    #expect(effects.failures == [.empty] && effects.pastes.count == 3)
}

@Test func pasteAllJoinsWithALineFeedAndKeepsInternalWhitespace() async throws {
    let store = ClipboardBufferStore(url: temporaryStoreURL())
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    effects.copies = [.text("  indented\n"), .text("tab\there")]
    for _ in 0..<2 { await controller.perform(.collect, target: try someOtherApp()) }
    await controller.perform(.pasteAll, target: try someOtherApp())
    #expect(effects.pastes == ["  indented\n\ntab\there"])
}

@Test func aFailedOrSupersededPasteKeepsTheItem() async throws {
    let store = ClipboardBufferStore(url: temporaryStoreURL())
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    effects.copies = [.text("A")]
    await controller.perform(.collect, target: try someOtherApp())
    effects.pasteResult = .focusChanged
    await controller.perform(.pasteNext, target: try someOtherApp())
    #expect(controller.count == 1 && store.state.sending == nil)
    #expect(effects.failures == [.destinationChanged])
    // An app switch mid-paste (the activation observer invalidates).
    effects.pasteResult = nil
    effects.onPaste = { controller.invalidate() }
    await controller.perform(.pasteNext, target: try someOtherApp())
    #expect(controller.count == 1 && effects.pastes.isEmpty)
    #expect(effects.failures.last == .destinationChanged)
}

@Test func foregroundReplacementDuringHyperReleaseKeepsQueuedPasteUnsent() async throws {
    let store = ClipboardBufferStore(url: temporaryStoreURL())
    try store.append("keep queued")
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    effects.beforeRelease = { controller.invalidate() }
    await controller.perform(.pasteNext, target: try someOtherApp())
    #expect(effects.pastes.isEmpty)
    #expect(controller.count == 1)
    #expect(store.state.sending == nil)
}

@Test func aSendThatCannotBeRecordedPausesInMemoryAndKeepsTheItem() async throws {
    let url = temporaryStoreURL()
    let store = ClipboardBufferStore(url: url)
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    effects.copies = [.text("A")]
    await controller.perform(.collect, target: try someOtherApp())
    // After dispatch the disk refuses: a directory now sits where the file
    // was, so the atomic replacement cannot land.
    effects.onPaste = {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("blocker"), withIntermediateDirectories: true)
    }
    await controller.perform(.pasteNext, target: try someOtherApp())
    effects.onPaste = nil
    #expect(effects.pastes == ["A"] && effects.failures == [.paused])
    #expect(controller.count == 1 && controller.isPaused, "kept, and paused although the disk refused the pause")
    #expect(controller.statusLine == "Collected · 1 · paused")
    await controller.perform(.pasteNext, target: try someOtherApp())
    #expect(effects.pastes == ["A"] && effects.failures == [.paused, .paused], "nothing repeats unasked")
}

@Test func clearCancelsAPendingPasteWithoutABezel() async throws {
    let store = ClipboardBufferStore(url: temporaryStoreURL())
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    effects.copies = [.text("A")]
    await controller.perform(.collect, target: try someOtherApp())
    effects.beforePaste = { await controller.perform(.clear, target: nil) }
    await controller.perform(.pasteNext, target: try someOtherApp())
    #expect(effects.pastes.isEmpty && controller.count == 0 && store.state.sending == nil)
    #expect(effects.failures.isEmpty, "⌫ asked for it; nothing to report")
}

@Test func copyFailuresAndRefusalsNeverAppend() async throws {
    let store = ClipboardBufferStore(url: temporaryStoreURL())
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    effects.copies = [.failed, .changed, .text("")]
    for _ in 0..<3 { await controller.perform(.collect, target: try someOtherApp()) }
    #expect(controller.count == 0)
    #expect(effects.failures == [.copyFailed, .destinationChanged, .copyFailed])
    effects.failures = []
    await controller.perform(.collect, target: nil)
    effects.isTrusted = false
    await controller.perform(.collect, target: try someOtherApp())
    #expect(effects.failures == [.noDestination, .accessibility])
    // No store (a candidate or harness host): unavailable, never a crash.
    let bare = CollectController(store: nil, effects: effects)
    await bare.perform(.collect, target: try someOtherApp())
    #expect(effects.failures.last == .unavailable)
}

@Test func clearEmptiesAndUnpausesAndTheOrdinaryClipboardIsNotTouched() async throws {
    let store = ClipboardBufferStore(url: temporaryStoreURL())
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    effects.copies = [.text("A"), .text("B")]
    for _ in 0..<2 { await controller.perform(.collect, target: try someOtherApp()) }
    try store.mutate { $0.paused = true }
    await controller.perform(.clear, target: nil)
    #expect(controller.count == 0 && !controller.isPaused && controller.statusLine == nil)
    #expect(effects.replaced.isEmpty && effects.pastes.isEmpty)
}

@Test func equalizeRewritesOnlyAChangedClipboardAndNeverTouchesTheQueue() async throws {
    let store = ClipboardBufferStore(url: temporaryStoreURL())
    let effects = FakeEffects()
    let controller = CollectController(store: store, effects: effects)
    effects.copies = [.text("A")]
    await controller.perform(.collect, target: try someOtherApp())
    await controller.perform(.equalize, target: nil)
    #expect(effects.replaced == ["a b"] && controller.count == 1 && effects.pastes.isEmpty)
    #expect(effects.notices == ["Equalized"], "the result is invisible, so it says so (D1)")
    effects.normalized = "a  b"
    await controller.perform(.equalize, target: nil)
    #expect(effects.replaced == ["a b"], "unchanged text is not rewritten")
    #expect(effects.notices == ["Equalized", "Already equal"])
    effects.normalized = nil
    await controller.perform(.equalize, target: nil)
    #expect(effects.failures == [.equalizeFailed])
    effects.normalized = ""
    await controller.perform(.equalize, target: nil)
    #expect(effects.failures.count == 2 && effects.replaced == ["a b"], "an empty result never wipes the copy")
    effects.normalized = "x"
    effects.replaceSucceeds = false
    await controller.perform(.equalize, target: nil)
    #expect(effects.failures == [.equalizeFailed, .equalizeFailed, .equalizeFailed])
    // Equalize needs no queue: a host without a store still runs it.
    let bare = FakeEffects()
    await CollectController(store: nil, effects: bare).perform(.equalize, target: nil)
    #expect(bare.replaced == ["a b"] && bare.failures.isEmpty)
}

/// A helper that exits unread (EPIPE on a large write), hangs, or ignores
/// SIGTERM returns nil within its bound and never takes the host down.
@Test func theNormalizerRunnerSurvivesBrokenHelpers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("collect-helpers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func helper(_ name: String, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    let big = String(repeating: "x", count: 1 << 20)
    let unread = await CollectNormalizer.run(big, executable: try helper("unread", "exit 3"), timeout: 2)
    #expect(unread == nil)
    let clock = ContinuousClock()
    let start = clock.now
    let hangs = await CollectNormalizer.run("a", executable: try helper("hangs", "exec sleep 30"), timeout: 0.3)
    let stubborn = await CollectNormalizer.run("a", executable: try helper("stubborn", "trap '' TERM\nwhile :; do :; done"), timeout: 0.3)
    #expect(hangs == nil && stubborn == nil)
    #expect(clock.now - start < .seconds(3), "bounded, SIGKILL after the grace period")
    let echo = await CollectNormalizer.run("a  b", executable: try helper("echo", "cat"), timeout: 2)
    #expect(echo == "a  b")
}

@Test func requireFrontmostNeverActivatesAndRefusesAMovedDestination() async throws {
    let target = try someOtherApp()
    var writes = 0
    let moved = await TargetedPaste.perform(into: target, policy: .requireFrontmost, hide: {},
                                            write: { writes += 1; return true }, isCurrent: { true },
                                            trusted: { true }, frontmostPID: { ProcessInfo.processInfo.processIdentifier })
    #expect(moved == .focusChanged && writes == 0, "the target is not in front: no activation, no write, no event")
    let stale = await TargetedPaste.perform(into: target, policy: .requireFrontmost, hide: {},
                                            write: { writes += 1; return true }, isCurrent: { false },
                                            trusted: { true }, frontmostPID: { target.pid })
    #expect(stale == .superseded && writes == 0)
}

@Test func collectActionsMapFromTheirChordsAndOnlyCVBNeedATarget() {
    #expect(CollectAction(overlayID: OverlayID.collectAdd) == .collect)
    #expect(CollectAction(overlayID: OverlayID.equalize) == .equalize)
    #expect(CollectAction(overlayID: OverlayID.stash) == nil)
    #expect(CollectAction.allCases.filter(\.needsTarget) == [.collect, .pasteNext, .pasteAll])
}

/// The current V normaliser under the resident host's environment
/// (`/usr/bin/python3` through `env`), byte for byte against the plan's
/// nine synthetic cases (run `17b62a1220d7e543`, normalization-comparison.json).
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: normalizerURL.path), "normalize-text is not installed here"))
func equalizeMatchesTheNormalizerGoldens() async {
    let cases: [(String, String, String)] = [
        ("wrapped-path", "/tmp/report/\n  long-name.txt\n", "/tmp/report/long-name.txt\n"),
        ("inline-path-gap", "/tmp/report/file-    name.txt\n", "/tmp/report/file-name.txt\n"),
        ("crlf", "alpha\r\nbeta\r\n", "alpha\nbeta\n"),
        ("indented-prose", "A paragraph\n  an indented explanation\nNext paragraph\n", "A paragraph\n  an indented explanation\nNext paragraph\n"),
        ("fenced-command-with-context", "Before\n```bash\necho hi\n```\nAfter\n", "Before\n```bash\necho hi\n```\nAfter\n"),
        ("shell-backslash", "echo hello \\\n  world\n", "echo hello \\\n  world\n"),
        ("bullets", "- alpha\n- beta\n", "- alpha\n- beta\n"),
        ("unicode", "Grüße 👋\n次の行\n", "Grüße 👋\n次の行\n"),
        ("trailing-newlines", "alpha\n\n", "alpha\n\n"),
    ]
    for (name, input, expected) in cases {
        let output = await CollectNormalizer.run(input, executable: normalizerURL)
        #expect(output == expected, "\(name)")
    }
}

}
