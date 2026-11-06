import AppKit
import Foundation
import HyperOverlayCore
@testable import HyperOverlayRuntime
import Testing

// The former KM utilities as direct actions (plan f71f8baac8f0149e).
// Covered here:
// - input sources and the fallback to the clipboard;
// - the Finder branch;
// - miss, failure and refusal bezels;
// - cancellation that stops the helper;
// - the clipboard revision guard;
// - telemetry;
// - the bounded runner's group kill;
// - the real helpers' output under the host's environment.

@MainActor private final class FakeKeyEffects: KeyActionEffects {
    var isTrusted = true
    var releases = true
    var copies: [CollectCopy] = []
    var waits: [Duration] = []
    var clipboard: String?
    var revision = 1
    var finder: FinderSelection = .nothing
    var finderDelay: Duration?
    var finderCompleted = 0
    var helpers: [KeyActionHelper: HelperAnswer] = [:]
    var helperCalls: [KeyActionHelper] = []
    var helperDelay: Duration?
    var onHelper: (() -> Void)?
    var directories: Set<String> = []
    var opened: [([String], KeyActionApp?)] = []
    var revealed: [[String]] = []
    var written: [String] = []
    var writtenFiles: [[String]] = []
    var failures: [String] = []
    var notices: [String] = []
    var onCopy: (() -> Void)?
    var copyDelay: Duration?

    func trusted() -> Bool { isTrusted }
    func waitForHyperRelease() async -> Bool { releases }
    func copySelection(from target: PasteTarget, wait: Duration, isCurrent: @escaping @MainActor () -> Bool) async -> CollectCopy {
        waits.append(wait)
        onCopy?()
        if let copyDelay { try? await Task.sleep(for: copyDelay) }
        guard isCurrent() else { return .changed }
        return copies.isEmpty ? .failed : copies.removeFirst()
    }
    func clipboardText() -> String? { clipboard }
    func clipboardRevision() -> Int { revision }
    func finderSelection() async -> FinderSelection {
        if let finderDelay { try? await Task.sleep(for: finderDelay) }
        finderCompleted += 1
        return finder
    }
    func helper(_ helper: KeyActionHelper, input: String) async -> HelperAnswer {
        helperCalls.append(helper)
        onHelper?()
        if let helperDelay {
            // A real helper is killed on cancel; its answer is then a failure.
            do { try await Task.sleep(for: helperDelay) } catch { return .failed }
        }
        return helpers[helper] ?? .none
    }
    func directoryExists(_ path: String) -> Bool { directories.contains(path) }
    func open(_ urls: [URL], with app: KeyActionApp?) async -> Bool {
        opened.append((urls.map { $0.isFileURL ? $0.path : $0.absoluteString }, app))
        return true
    }
    func reveal(_ urls: [URL]) -> Bool {
        revealed.append(urls.map(\.path))
        return true
    }
    func writeClipboard(text: String, ifRevision revision: Int) -> ClipboardWrite {
        guard revision == self.revision else { return .stale }
        written.append(text)
        self.revision += 1
        return .written
    }
    func writeClipboard(files: [URL], ifRevision revision: Int) -> ClipboardWrite {
        guard revision == self.revision else { return .stale }
        writtenFiles.append(files.map(\.path))
        self.revision += 1
        return .written
    }
    func showFailure(_ text: String) { failures.append(text) }
    func showNotice(_ text: String) { notices.append(text) }
}

/// Another running app to aim at; nothing is ever posted to it here.
@MainActor private func frontApp() throws -> PasteTarget {
    let other = NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleIdentifier == "com.apple.dock"
    } ?? NSWorkspace.shared.runningApplications.first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    return try #require(PasteTarget(other?.processIdentifier))
}

@Suite(.serialized) @MainActor struct KeyActionSuite {

@Test func localMarkdownLinkOpensDestinationBeforeURLLookingLabel() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.copies = [.text("[https://example.org/label](/tmp/glacier-target.md)")]
    effects.helpers[.extractPath] = .value("/tmp/glacier-target.md")
    #expect(await controller.perform(.openNaturally, target: try frontApp()) == .done("opened"))
    #expect(effects.helperCalls == [.extractPath])
    #expect(effects.opened.map(\.0) == [["/tmp/glacier-target.md"]])

    effects.copies = [.text("[https://example.org/label](/tmp/glacier-missing.md)")]
    effects.helpers[.extractPath] = .none
    #expect(await controller.perform(.openNaturally, target: try frontApp()) == .miss("No path or URL found"))
    #expect(effects.opened.count == 1)
}

@Test func everyKeyMapsToItsChordAndTheEightAreDirectActions() {
    #expect(HyperKeyAction.allCases.count == 8)
    for action in HyperKeyAction.allCases {
        #expect(HyperKeyAction(overlayID: action.overlayID) == action)
        #expect(OverlayID.directActions.contains(action.overlayID))
        #expect(!OverlayID.implemented.contains(action.overlayID), "a direct action is never a socket show target")
    }
    #expect(OverlayID.keyActions.intersection(OverlayID.collectActions).isEmpty)
    #expect(HyperKeyAction(overlayID: OverlayID.collectAdd) == nil)
}

@Test func revealUsesAFreshCopyAndWaitsOnlyBrieflyBeforeFallingBack() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.copies = [.text("see ~/notes/a.md")]
    effects.helpers[.extractPath] = .value("/Users/x/notes/a.md")
    let outcome = await controller.perform(.reveal, target: try frontApp())
    #expect(outcome == .done("revealed") && effects.revealed == [["/Users/x/notes/a.md"]])
    #expect(effects.waits == [KeyActionController.fallbackWait] && KeyActionController.fallbackWait == .milliseconds(300))
    #expect(effects.failures.isEmpty && effects.notices.isEmpty, "opening something is its own feedback")
    // Nothing selected: the clipboard as it is, as KM did.
    effects.clipboard = "/Users/x/b.md"
    effects.helpers[.extractPath] = .value("/Users/x/b.md")
    #expect(await controller.perform(.reveal, target: try frontApp()) == .done("revealed"))
    // Nothing at all: the miss speaks.
    effects.clipboard = nil
    #expect(await controller.perform(.reveal, target: try frontApp()) == .miss("No path found"))
    effects.clipboard = "no path in here"
    effects.helpers[.extractPath] = HelperAnswer.none
    #expect(await controller.perform(.reveal, target: try frontApp()) == .miss("No path found"))
    // A helper that failed is not a miss.
    effects.helpers[.extractPath] = .failed
    #expect(await controller.perform(.reveal, target: try frontApp()) == .failed("Lookup failed"))
    #expect(effects.failures == ["No path found", "No path found", "Lookup failed"])
}

@Test func openTakesExplicitSchemesAsWrittenAndNeverGuessesAfterAFailedLookup() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.helpers = [.extractURL: .value("https://example.com/README.md"), .extractPath: .value("/Users/x/README.md")]
    effects.copies = [.text("read https://example.com/README.md now")]
    _ = await controller.perform(.openNaturally, target: try frontApp())
    #expect(effects.opened.last?.0 == ["https://example.com/README.md"], "an http(s) URL is never mistaken for a local file")
    effects.copies = [.text("open obsidian://open?vault=notes&file=a")]
    _ = await controller.perform(.openNaturally, target: try frontApp())
    #expect(effects.opened.last?.0 == ["obsidian://open?vault=notes&file=a"], "other schemes open as written")
    effects.copies = [.text("(see obsidian://open?vault=a).")]
    _ = await controller.perform(.openNaturally, target: try frontApp())
    #expect(effects.opened.last?.0 == ["obsidian://open?vault=a"], "prose punctuation is not part of the URL")
    effects.copies = [.text("file:///Users/x/My%20Notes/n.md")]
    _ = await controller.perform(.openNaturally, target: try frontApp())
    #expect(effects.opened.last?.0 == ["/Users/x/My Notes/n.md"], "file: opens as its path")
    effects.copies = [.text("notes.md")]
    _ = await controller.perform(.openNaturally, target: try frontApp())
    #expect(effects.opened.last?.0 == ["/Users/x/README.md"] && effects.opened.last?.1 == nil, "an existing path beats https://notes.md")
    effects.helpers = [.extractURL: .value("https://example.com"), .extractPath: HelperAnswer.none]
    effects.copies = [.text("example.com")]
    _ = await controller.perform(.openNaturally, target: try frontApp())
    #expect(effects.opened.last?.0 == ["https://example.com"])
    // A slow or broken path lookup never falls through to a URL guess.
    effects.helpers = [.extractURL: .value("https://notes.md"), .extractPath: .failed]
    effects.copies = [.text("notes.md")]
    #expect(await controller.perform(.openNaturally, target: try frontApp()) == .failed("Lookup failed"))
    #expect(effects.opened.last?.0 == ["https://example.com"], "nothing new opened")
    effects.helpers = [:]
    effects.copies = [.text("plain words")]
    #expect(await controller.perform(.openNaturally, target: try frontApp()) == .miss("No path or URL found"))
}

@Test func openTriesTheURLFirstForWebAddressesAsKMDid() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    // km-extract-path can resolve github.com/a/b to a local folder.
    effects.helpers = [.extractURL: .value("https://github.com/anthropics/claude-code"),
                       .extractPath: .value("/Users/x/Projects/claude-code")]
    effects.copies = [.text("github.com/anthropics/claude-code")]
    _ = await controller.perform(.openNaturally, target: try frontApp())
    #expect(effects.opened.last?.0 == ["https://github.com/anthropics/claude-code"] && effects.helperCalls == [.extractURL])
    for text in ["example.com", "www.example.org/x", "see github.com/a/b.", "docs at (anthropic.com)"] {
        #expect(KeyActionController.looksLikeWebAddress(text), "\(text)")
    }
    for text in ["notes.md", "README.md", "~/site.com/x", "Projects/foo.io/a.md", "v1.2.3", "main.swift:42", "plain words"] {
        #expect(!KeyActionController.looksLikeWebAddress(text), "\(text)")
    }
}

@Test func theFinderQueryOutlivesACancelSoAFirstUsePromptSurvives() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.finder = .items(["/Users/x/a.md"])
    effects.finderDelay = .milliseconds(200)
    let task = controller.start(.editInSublime, target: try frontApp(), frontIsFinder: true)
    try await Task.sleep(for: .milliseconds(40))
    controller.invalidate()
    #expect(await task.value == .cancelled)
    #expect(effects.finderCompleted == 1 && effects.opened.isEmpty, "the query ran to its end; its stale answer was discarded")
}

@Test func jumpToRootRevealsTheRootTheHelperChose() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.copies = [.text("/Users/x/Tooling/apps/omni-intent/Sources/A.swift")]
    effects.helpers[.jumpRoot] = .value("/Users/x/Tooling/apps/omni-intent")
    #expect(await controller.perform(.jumpToRoot, target: try frontApp()) == .done("revealed-root"))
    #expect(effects.revealed == [["/Users/x/Tooling/apps/omni-intent"]])
    effects.helpers[.jumpRoot] = HelperAnswer.none
    effects.copies = [.text("nothing")]
    #expect(await controller.perform(.jumpToRoot, target: try frontApp()) == .miss("No path root found"))
}

@Test func sublimeAndTerminalReadTheFinderSelectionWithoutCopying() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.finder = .items(["/Users/x/a.md", "/Users/x/dir"])
    effects.directories = ["/Users/x/dir"]
    #expect(await controller.perform(.editInSublime, target: try frontApp(), frontIsFinder: true) == .done("opened"))
    #expect(effects.opened.last?.0 == ["/Users/x/a.md", "/Users/x/dir"] && effects.opened.last?.1 == .sublime)
    // Terminal: the first item, a file's parent.
    _ = await controller.perform(.terminalHere, target: try frontApp(), frontIsFinder: true)
    #expect(effects.opened.last?.0 == ["/Users/x"] && effects.opened.last?.1 == .ghostty)
    effects.finder = .window("/Users/x/Projects")
    _ = await controller.perform(.terminalHere, target: try frontApp(), frontIsFinder: true)
    #expect(effects.opened.last?.0 == ["/Users/x/Projects"])
    #expect(await controller.perform(.editInSublime, target: try frontApp(), frontIsFinder: true) == .miss("No file selected"))
    effects.finder = .nothing
    _ = await controller.perform(.terminalHere, target: try frontApp(), frontIsFinder: true)
    #expect(effects.opened.last?.0 == [OverlayPaths.homeDirectory.path], "no selection, no window: home")
    #expect(effects.waits.isEmpty, "the Finder branch never presses ⌘C, so the clipboard is untouched")
    effects.finder = .unavailable("Finder access needed")
    #expect(await controller.perform(.editInSublime, target: try frontApp(), frontIsFinder: true) == .failed("Finder access needed"))
    // Finder in front behind a host surface: refuse rather than read it.
    #expect(await controller.perform(.editInSublime, target: nil, frontIsFinder: true) == .refused("No app to act on"))
    #expect(await controller.perform(.copyPath, target: nil, frontIsFinder: true) == .refused("No app to act on"))
    // Outside Finder: the selection's path; a file opens Ghostty at its parent.
    effects.copies = [.text("/Users/x/notes/a.md")]
    effects.helpers[.extractPath] = .value("/Users/x/notes/a.md")
    _ = await controller.perform(.terminalHere, target: try frontApp())
    #expect(effects.opened.last?.0 == ["/Users/x/notes"])
}

@Test func copyPathNeedsNoAppSaysWhatItCopiedAndNeverOverwritesANewerCopy() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.clipboard = "  ~/notes/a.md  "
    effects.helpers[.extractPath] = .value("/Users/x/notes/a.md")
    // A host surface owns the foreground: P still works from the clipboard.
    #expect(await controller.perform(.copyPath, target: nil) == .done("copied", notice: "Path copied"))
    #expect(effects.written == ["/Users/x/notes/a.md"] && effects.notices == ["Path copied"] && effects.waits.isEmpty)
    effects.finder = .items(["/Users/x/a.md", "/Users/x/b.md"])
    _ = await controller.perform(.copyPath, target: try frontApp(), frontIsFinder: true)
    #expect(effects.written.last == "/Users/x/a.md\n/Users/x/b.md" && effects.notices.last == "2 paths copied")
    effects.finder = .window("/Users/x/Projects")
    _ = await controller.perform(.copyPath, target: try frontApp(), frontIsFinder: true)
    #expect(effects.written.last == "/Users/x/Projects")
    effects.finder = .nothing
    #expect(await controller.perform(.copyPath, target: try frontApp(), frontIsFinder: true) == .miss("Nothing selected"))
    // A copy made while the lookup ran wins.
    effects.onHelper = { effects.revision += 1 }
    let before = effects.written
    #expect(await controller.perform(.copyPath, target: nil) == .failed("Clipboard changed"))
    #expect(effects.written == before)
    effects.onHelper = nil
    effects.clipboard = nil
    #expect(await controller.perform(.copyPath, target: nil) == .miss("No path found"))
}

@Test func copyPathFromTheClipboardSurvivesAnAppSwitch() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.clipboard = "~/a.md"
    effects.helpers[.extractPath] = .value("/Users/x/a.md")
    effects.helperDelay = .milliseconds(150)
    let task = controller.start(.copyPath, target: nil, frontIsFinder: false)
    try await Task.sleep(for: .milliseconds(40))
    controller.invalidate()  // ⌘Tab to paste elsewhere
    #expect(await task.value == .done("copied", notice: "Path copied"), "P needs no app; the revision guard protects a newer copy")
}

@Test func fenceRefusesAStaleClipboardAndGatherWritesFileReferences() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.clipboard = "old copy"
    #expect(await controller.perform(.fence, target: try frontApp()) == .miss("No selected text"))
    #expect(effects.waits == [KeyActionController.selectionWait] && effects.written.isEmpty)
    effects.copies = [.text("let a = 1")]
    effects.helpers[.fence] = .value("```\nlet a = 1\n```")
    #expect(await controller.perform(.fence, target: try frontApp()) == .done("copied", notice: "Fenced"))
    #expect(effects.written == ["```\nlet a = 1\n```"])
    effects.copies = [.text("see a.md and b.json")]
    effects.helpers[.gather] = .value("/Users/x/a.md\n/Users/x/b.json")
    #expect(await controller.perform(.gatherFiles, target: try frontApp()) == .done("copied-files", notice: "2 files ready"))
    #expect(effects.writtenFiles == [["/Users/x/a.md", "/Users/x/b.json"]])
    effects.helpers[.gather] = HelperAnswer.none
    effects.copies = [.text("nothing named")]
    #expect(await controller.perform(.gatherFiles, target: try frontApp()) == .miss("No files found"))
}

@Test func aCancelStopsTheHelperFreesTheLaneAndWritesNothing() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.copies = [.text("see a.md")]
    effects.helpers[.gather] = .value("/Users/x/a.md")
    effects.helperDelay = .seconds(30)
    let clock = ContinuousClock()
    let start = clock.now
    let task = controller.start(.gatherFiles, target: try frontApp(), frontIsFinder: false)
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.busy)
    controller.invalidate()
    #expect(await task.value == .cancelled)
    #expect(clock.now - start < .seconds(2), "the helper is stopped, not waited out")
    #expect(!controller.busy && effects.writtenFiles.isEmpty && effects.failures.last == "Destination changed")
}

@Test func refusalsBusyAndCancellationSpeakAndActOnNothing() async throws {
    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    #expect(await controller.perform(.reveal, target: nil) == .refused("No app to act on"))
    effects.isTrusted = false
    #expect(await controller.perform(.reveal, target: try frontApp()) == .refused("Accessibility access needed"))
    effects.isTrusted = true
    // A newer intent (another chord, an app switch) during the copy.
    effects.onCopy = { controller.invalidate() }
    effects.copies = [.text("/a")]
    effects.helpers[.extractPath] = .value("/a")
    #expect(await controller.perform(.reveal, target: try frontApp()) == .cancelled)
    #expect(effects.revealed.isEmpty && effects.failures.last == "Destination changed")
    // The lane is reserved at the press: a second action answers Busy at
    // once, even before the first task has run; the first finishes.
    effects.onCopy = nil
    effects.copyDelay = .milliseconds(150)
    effects.copies = [.text("/a")]
    let target = try frontApp()
    let first = controller.start(.reveal, target: target, frontIsFinder: false)
    #expect(controller.busy)
    #expect(await controller.perform(.reveal, target: target) == .refused("Busy"))
    #expect(await first.value == .done("revealed"))
    #expect(effects.failures.last == "Busy" && effects.revealed == [["/a"]])
    #expect(KeyActionOutcome.refused("Busy").telemetry == "refused:Busy")
}

@Test func telemetryCountsFiresAndKeepsOnlyOutcomesNeverContent() {
    let telemetry = DirectActionTelemetry()
    let at = Date(timeIntervalSince1970: 1_793_100_000)
    let reveal = telemetry.fired(OverlayID.reveal, at: at)
    telemetry.finished(OverlayID.reveal, token: reveal, outcome: KeyActionOutcome.done("revealed").telemetry)
    let add = telemetry.fired(OverlayID.collectAdd, at: at)
    let next = telemetry.fired(OverlayID.collectNext, at: at)
    telemetry.failLatestOpen(among: OverlayID.collectActions, outcome: "failed:Busy")
    telemetry.finished(OverlayID.collectAdd, token: add, outcome: "done")
    telemetry.finished(OverlayID.collectNext, token: next, outcome: "done")
    // G pressed twice: the second press's refusal cannot take the first's outcome.
    let firstG = telemetry.fired(OverlayID.gatherFiles, at: at)
    let secondG = telemetry.fired(OverlayID.gatherFiles, at: at)
    telemetry.finished(OverlayID.gatherFiles, token: secondG, outcome: "refused:Busy")
    telemetry.finished(OverlayID.gatherFiles, token: firstG, outcome: "copied-files")
    let facts = telemetry.facts
    #expect(facts[OverlayID.reveal] == "count=1 last=2026-10-27T11:20:00Z outcome=revealed")
    #expect(facts[OverlayID.collectNext]?.hasSuffix("outcome=failed:Busy") == true, "the latest open Collect record takes the failure")
    #expect(facts[OverlayID.collectAdd]?.hasSuffix("outcome=done") == true)
    #expect(facts[OverlayID.gatherFiles]?.hasPrefix("count=2") == true)
    #expect(facts[OverlayID.gatherFiles]?.hasSuffix("outcome=copied-files") == true, "the first press keeps its record")
    #expect(facts[OverlayID.fence] == nil, "a chord that never arrived has no record")
}

@Test func finderAnswersParseFileURLsIntoSelectionWindowNothingOrAReason() {
    let ok: (String) -> HelperProcess.Result = { HelperProcess.Result(status: 0, stdout: $0, stderr: "") }
    #expect(KeyActionSystemEffects.parseFinder(ok("S\nfile:///Users/x/a.md\nfile:///Users/x/dir/\n")) == .items(["/Users/x/a.md", "/Users/x/dir"]))
    #expect(KeyActionSystemEffects.parseFinder(ok("S\nfile:///Users/x/line%0Abreak.md\nfile:///Users/x/My%20File.md\n"))
            == .items(["/Users/x/line\nbreak.md", "/Users/x/My File.md"]), "a line break in a name stays one item")
    #expect(KeyActionSystemEffects.parseFinder(ok("W\nfile:///Users/x/Desktop/\n")) == .window("/Users/x/Desktop"))
    #expect(KeyActionSystemEffects.parseFinder(ok("N\n")) == .nothing)
    #expect(KeyActionSystemEffects.parseFinder(ok("S\n")) == .nothing)
    let denied = HelperProcess.Result(status: 1, stdout: "", stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)")
    #expect(KeyActionSystemEffects.parseFinder(denied) == .unavailable("Finder access needed"))
    #expect(KeyActionSystemEffects.parseFinder(nil) == .unavailable("Finder didn't answer"))
}

/// Opt in because this opens a temporary Finder window. Exercise the actual
/// AppleScript: a mocked `.window` answer cannot catch Finder's unresolved
/// `URL of insertion location` property specifier.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OMNI_FINDER_UI_TESTS"] == "1"))
func realFinderCopiesTheFolderWithNoSelectionAndTheFileWhenSelected() async throws {
    // Foundation keeps /var in its temporary URL even after symlink
    // resolution, while Finder reports /private/var. Use the user cache so
    // exact clipboard path assertions do not depend on that system alias.
    let cache = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
    let directory = cache.appendingPathComponent("omni-finder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("A file with spaces\nand a line break.txt")
    try Data("fixture".utf8).write(to: file)
    let script = """
    on readSelection()
    \(KeyActionSystemEffects.finderScript)
    end readSelection
    tell application "Finder"
        set testWindow to make new Finder window to (POSIX file "\(directory.path)" as alias)
        activate
        try
            set selection to {}
            set folderAnswer to my readSelection()
            set selection to {first file of (target of testWindow)}
            set fileAnswer to my readSelection()
            close testWindow
        on error errorText number errorNumber
            close testWindow
            error errorText number errorNumber
        end try
    end tell
    return folderAnswer & linefeed & "---" & linefeed & fileAnswer
    """
    let result = try #require(await HelperProcess.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-"],
                                                     stdin: script, environment: HelperProcess.baseEnvironment,
                                                     timeout: KeyActionSystemEffects.finderTimeout))
    try #require(result.status == 0, "Finder integration failed: \(result.stderr)")
    let answers = result.stdout.components(separatedBy: "\n---\n")
    try #require(answers.count == 2)
    let folderSelection = KeyActionSystemEffects.parseFinder(.init(status: 0, stdout: answers[0], stderr: ""))
    let fileSelection = KeyActionSystemEffects.parseFinder(.init(status: 0, stdout: answers[1], stderr: ""))
    #expect(folderSelection == .window(directory.path))
    #expect(fileSelection == .items([file.path]))

    let effects = FakeKeyEffects()
    let controller = KeyActionController(effects: effects)
    effects.finder = folderSelection
    #expect(await controller.perform(.copyPath, target: try frontApp(), frontIsFinder: true) == .done("copied", notice: "Path copied"))
    #expect(effects.written == [directory.path])
    effects.finder = fileSelection
    #expect(await controller.perform(.copyPath, target: try frontApp(), frontIsFinder: true) == .done("copied", notice: "Path copied"))
    #expect(effects.written == [directory.path, file.path])
    #expect(effects.waits.isEmpty && effects.helperCalls.isEmpty)
}

@Test func helperExitCodesSeparateAMissFromAFailure() {
    let result: (Int32, String) -> HelperProcess.Result = { HelperProcess.Result(status: $0, stdout: $1, stderr: "") }
    #expect(KeyActionSystemEffects.answer(.extractPath, result(0, "/a\n")) == .value("/a"))
    #expect(KeyActionSystemEffects.answer(.fence, result(0, "```\na\n```")) == .value("```\na\n```"), "the fence keeps its bytes")
    #expect(KeyActionSystemEffects.answer(.extractPath, result(0, "\n")) == HelperAnswer.none)
    #expect(KeyActionSystemEffects.answer(.extractPath, result(1, "")) == HelperAnswer.none)
    #expect(KeyActionSystemEffects.answer(.fence, result(64, "")) == HelperAnswer.none)
    #expect(KeyActionSystemEffects.answer(.extractPath, result(2, "")) == .failed)
    #expect(KeyActionSystemEffects.answer(.extractPath, nil) == .failed, "a timeout or a signal is a failure, not a miss")
}

/// A cancelled helper ends at once, with everything it spawned.
@Test func cancellingTheRunnerKillsTheHelpersWholeProcessGroup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("key-helpers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pidFile = directory.appendingPathComponent("child.pid")
    let script = directory.appendingPathComponent("crawl")
    try Data("#!/bin/sh\n/bin/sleep 30 &\necho $! > \"\(pidFile.path)\"\nwait\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let clock = ContinuousClock()
    let start = clock.now
    let task = Task { await HelperProcess.run(script, stdin: "", environment: HelperProcess.baseEnvironment, timeout: 20) }
    var childPID: pid_t?
    for _ in 0..<100 where childPID == nil {
        try await Task.sleep(for: .milliseconds(20))
        childPID = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    let child = try #require(childPID)
    task.cancel()
    #expect(await task.value == nil)
    #expect(clock.now - start < .seconds(5))
    try await Task.sleep(for: .milliseconds(200))
    #expect(kill(child, 0) != 0, "the grandchild was signalled with its group")
}

/// The real helpers under the resident host's environment (minimal PATH plus
/// HOME), against inputs whose answers do not depend on the machine's files.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: KeyActionSystemEffects.helperInvocation(.extractPath).executable.path),
               "the KM helpers are not installed here"))
func theRealHelpersAnswerUnderTheHostEnvironment() async throws {
    func run(_ helper: KeyActionHelper, _ input: String) async -> HelperProcess.Result? {
        let invocation = KeyActionSystemEffects.helperInvocation(helper)
        return await HelperProcess.run(invocation.executable, arguments: invocation.arguments, stdin: input,
                                       environment: KeyActionSystemEffects.helperEnvironment, timeout: 8)
    }
    func value(_ helper: KeyActionHelper, _ input: String) async -> HelperAnswer {
        KeyActionSystemEffects.answer(helper, await run(helper, input))
    }
    let here = URL(fileURLWithPath: #filePath)
    let packageRoot = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let existing = packageRoot.appendingPathComponent("Package.swift").path
    #expect(await value(.extractPath, existing) == .value(existing))
    #expect(await value(.extractURL, "read https://example.com/docs/page now") == .value("https://example.com/docs/page"))
    #expect(await value(.fence, "a ``` b") == .value("````\na ``` b\n````"), "a longer fence than any run inside")
    #expect(await value(.fence, "") == HelperAnswer.none, "empty input exits 64 and never notifies")
    if case .value(let root) = await value(.jumpRoot, here.path) {
        #expect(URL(fileURLWithPath: root).resolvingSymlinksInPath().path == packageRoot.resolvingSymlinksInPath().path,
                "the git top of this checkout")
    } else {
        Issue.record("km-jump-root found no root for this checkout")
    }
    // gather --print: a miss is exit 1 with no output, never a clipboard write.
    #expect(await value(.gather, "") == HelperAnswer.none)
    #expect(await value(.gather, "no file names in this sentence") == HelperAnswer.none)
    #expect(await value(.gather, "see \(existing)") == .value(existing))
}

}
