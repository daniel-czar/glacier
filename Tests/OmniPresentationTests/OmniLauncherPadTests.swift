import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

// The pad's `suggesting` state (H10, C50): rows, the ready badge, Enter,
// ↑/↓, the fallthrough and the launch undo.

private let now = Date(timeIntervalSince1970: 1_790_000_000)

@MainActor
private func launcherParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    return OmniParser(manifest: manifest, references: try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)]))
}

private let index = LauncherIndex(candidates: [
    LauncherCandidate(title: "Ghostty", path: "/Applications/Ghostty.app", kind: "app", source: .apps),
    LauncherCandidate(title: "HQ Sidebar Tmux Ghostty Reference", path: "/Users/fixture/Tooling/docs/hq-ghostty.md", kind: "reference", source: .docsIndex),
    LauncherCandidate(title: "omni-intent", path: "/Users/fixture/Lab/omni-intent", kind: "folder", source: .roots),
    LauncherCandidate(title: "Omni Intent Token Grammar", path: "/Users/fixture/Tooling/apps/omni-intent/docs/grammar.md", kind: "spec", source: .docsIndex),
])

@MainActor
private final class PadHarness {
    let pad: OmniCommandPadViewController
    var queries: [String] = []
    var launches: [(id: String, action: LauncherOpenAction, context: LaunchContext)] = []
    var fallthroughs: [LaunchContext] = []
    var submits: [(String, OmniSubmitGesture)] = []
    /// When false, per-keystroke queries are swallowed (a slow pipeline).
    var deliver = true

    init(enabled: Bool = true) throws {
        _ = NSApplication.shared
        pad = OmniCommandPadViewController(parser: try launcherParser())
        pad.loadView()
        _ = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        pad.launcherHome = "/Users/fixture"
        pad.onLauncherQuery = { [unowned self] text in
            queries.append(text)
            if deliver { pad.showLauncherResults(index.query(text, now: now)) }
        }
        pad.onResolveLauncher = { text in index.query(text, now: now) }
        pad.onLaunch = { [unowned self] id, action, context in launches.append((id, action, context)) }
        pad.onLauncherFallthrough = { [unowned self] context in fallthroughs.append(context) }
        pad.onSubmit = { [unowned self] text, gesture in submits.append((text, gesture)) }
        pad.launcherEnabled = enabled
    }

    func type(_ text: String) {
        pad.editor.string = text
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
    }
}

// MARK: Pure state

@Test @MainActor func disabledLauncherDropsLateRowsAndCannotLaunchThem() throws {
    let harness = try PadHarness()
    harness.deliver = false
    harness.type("ghostty")
    #expect(harness.queries == ["ghostty"])
    harness.pad.launcherEnabled = false
    harness.pad.showLauncherResults(index.query("ghostty", now: now))
    #expect(harness.pad.launcherState == nil)
    #expect(harness.pad.launcherRowViews.isEmpty)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.isEmpty)
}

@Test func launcherStateEnterFollowsReadySelectionAndUndo() throws {
    let ready = index.query("ghostty", now: now)
    #expect(ready.ready)
    var state = OmniLauncherPadState(results: ready)
    #expect(state.highlighted == 0)
    guard case .launch(let row, rank: 1, selection: .ready) = state.enter else { Issue.record("expected a ready launch"); return }
    #expect(row.candidate.title == "Ghostty")

    // ↓ past the implicit top row is a manual pick of row 2.
    let moved = state.move(by: 1)
    #expect(moved)
    guard case .launch(let second, rank: 2, selection: .manual) = state.enter else { Issue.record("expected a manual launch"); return }
    #expect(second.candidate.title.hasPrefix("HQ Sidebar"))
    state.move(by: -1)
    state.move(by: -1)
    #expect(state.manualSelection == nil)

    let unready = OmniLauncherPadState(results: index.query("omni", now: now))
    #expect(!unready.results.ready && unready.highlighted == nil)
    #expect(unready.enter == .propose(afterUndo: false))

    let undone = OmniLauncherPadState(results: ready, undoneCandidateID: "/Applications/Ghostty.app")
    #expect(undone.items.first == .askForProposal)
    #expect(undone.enter == .propose(afterUndo: true))

    // The ↵ badge follows the Enter target, not just the ready flag.
    #expect(OmniLauncherPadState(results: ready).readyBadgeIndex == 0)
    #expect(undone.readyBadgeIndex == nil)
    #expect(OmniLauncherPadState(results: ready, manualSelection: 1).readyBadgeIndex == nil)
    #expect(unready.readyBadgeIndex == nil)
}

@Test @MainActor func launcherFooterLinesMatchTheHandoff() throws {
    let readyFooter = OmniCommandPadViewController.launcherFooterState(OmniLauncherPadState(results: index.query("ghostty", now: now)), transientMessage: nil)
    #expect(readyFooter.routeLine == .outcome("Open Ghostty · app"))
    #expect(readyFooter.keyHints == OmniPadKeyHint.launch)
    #expect(readyFooter.submits && readyFooter.runEnabled)

    let unready = OmniCommandPadViewController.launcherFooterState(OmniLauncherPadState(results: index.query("omni", now: now)), transientMessage: nil)
    #expect(unready.routeLine == .propose("⇥ search everywhere"))
    #expect(unready.keyHints == OmniPadKeyHint.launcherPropose)

    let nothing = OmniCommandPadViewController.launcherFooterState(OmniLauncherPadState(results: index.query("zzqx", now: now)), transientMessage: nil)
    #expect(nothing.routeLine == .propose("⇥ search everywhere"))
    #expect(nothing.keyHints == OmniPadKeyHint.propose)
}

@Test @MainActor func onlyBareSingleLineTypedTextIsALauncherQuery() throws {
    let parser = try launcherParser()
    func check(_ text: String, provenance: Bool = false, notes: Bool = false) -> Bool {
        OmniCommandPadViewController.isLauncherQuery(parser.parse(text), rawText: text, hasProvenance: provenance, hasAnnotations: notes)
    }
    #expect(check("ghostty"))
    #expect(check("orbit spec"))
    #expect(!check(""))
    #expect(!check("/email accept"))
    #expect(!check("summarise /qq"))
    #expect(!check("/summarise the thread"))
    #expect(!check("coffee with @zoe"))
    #expect(!check("line one\nline two"))
    #expect(!check("ghostty", provenance: true))
    #expect(!check("ghostty", notes: true))
    // Past the query limit bare text is still launcher-first (unscored; Enter proposes).
    #expect(check(String(repeating: "a", count: 121)))
}

@Test @MainActor func notesImmediatelySuppressLauncherRowsAndRemovingLastNoteRestoresThem() throws {
    let harness = try PadHarness()
    harness.type("ghostty")
    #expect(harness.pad.mode == .suggesting)
    #expect(harness.pad.launcherRowViews.count == 2)
    #expect(harness.queries == ["ghostty"])

    let note = OmniTextAnnotation(range: NSRange(location: 0, length: 7), guidance: "Find the relevant conversation")
    harness.pad.setAnnotations([note])
    #expect(harness.pad.mode == .composing)
    #expect(harness.pad.launcherState == nil)
    #expect(harness.pad.launcherRowViews.isEmpty)
    #expect(harness.pad.launcherView == nil)
    #expect(harness.queries == ["ghostty"])
    #expect(harness.pad.routeLine == .propose(OmniCommandPadViewController.annotatedProposalLine))

    // The answer to the in-flight query is stale even though its text matches.
    harness.pad.showLauncherResults(index.query("ghostty", now: now))
    #expect(harness.pad.launcherRowViews.isEmpty)
    #expect(harness.pad.launcherState == nil)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.isEmpty)
    #expect(harness.submits.map { $0.0 } == ["ghostty"])

    harness.pad.clearAnnotations()
    #expect(harness.pad.mode == .suggesting)
    #expect(harness.queries == ["ghostty", "ghostty"])
    #expect(harness.pad.launcherRowViews.count == 2)
}

@Test @MainActor func notedBareTextNeverStartsOrRefreshesALauncherQuery() throws {
    let harness = try PadHarness()
    harness.pad.editor.string = "ghostty"
    harness.pad.setAnnotations([OmniTextAnnotation(range: NSRange(location: 0, length: 7), guidance: "Ask about setup")])
    harness.pad.textDidChange(Notification(name: NSText.didChangeNotification))
    harness.pad.refreshLauncherResults()
    #expect(harness.pad.mode == .composing)
    #expect(harness.queries.isEmpty)
    #expect(harness.pad.launcherRowViews.isEmpty)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.map { $0.0 } == ["ghostty"])
    #expect(harness.launches.isEmpty)
}

@Test @MainActor func notedMultilineImportedTextStillAsksForAProposal() throws {
    let harness = try PadHarness()
    let text = "line one\nline two"
    harness.type(text)
    harness.pad.setProvenance(OmniPadProvenance(source: "Mail", wordCount: 4))
    harness.pad.setAnnotations([OmniTextAnnotation(range: NSRange(location: 0, length: 8), guidance: "Focus on this")])
    #expect(harness.pad.mode == .composing)
    #expect(harness.pad.routeLine == .propose(OmniCommandPadViewController.annotatedProposalLine))
    #expect(harness.queries.isEmpty)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.map { $0.0 } == ["line one line two"])
    #expect(harness.launches.isEmpty)
}

// MARK: Pad behaviour

@Test @MainActor func withoutALauncherBareTextKeepsItsOldBehaviour() throws {
    let harness = try PadHarness(enabled: false)
    harness.type("ghostty")
    #expect(harness.pad.mode == .composing)
    #expect(harness.pad.routeLine == .hint(OmniCommandPadViewController.addCommandHint))
    #expect(harness.queries.isEmpty)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.isEmpty && harness.launches.isEmpty)
}

@Test @MainActor func typingBareTextSuggestsAndEnterOpensTheReadyRow() throws {
    let harness = try PadHarness()
    harness.type("ghost")
    harness.type("ghostty")
    #expect(harness.pad.mode == .suggesting)
    #expect(harness.queries == ["ghost", "ghostty"])
    #expect(harness.pad.launcherRowViews.count == 2)
    #expect(harness.pad.routeLine == .outcome("Open Ghostty · app"))
    harness.pad.editor.onSubmit?(.enterShowHere)
    let launch = try #require(harness.launches.first)
    #expect(launch.id == "/Applications/Ghostty.app" && launch.action == .open)
    #expect(launch.context.rank == 1 && launch.context.selection == .ready && launch.context.ready && launch.context.query == "ghostty")
    #expect(launch.context.elapsedMilliseconds != nil)
    #expect(harness.submits.isEmpty && harness.fallthroughs.isEmpty)
    // Cmd+Enter reveals.
    harness.pad.editor.onSubmit?(.commandEnterAttach)
    #expect(harness.launches.last?.action == .reveal)
}

@Test @MainActor func enterWithNoReadyRowFallsThroughToTheBareTextSubmit() throws {
    let harness = try PadHarness()
    harness.type("omni")
    #expect(harness.pad.routeLine == .propose("⇥ search everywhere"))
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.isEmpty)
    #expect(harness.fallthroughs.count == 1 && harness.fallthroughs.first?.rank == nil && harness.fallthroughs.first?.candidateCount == 2)
    #expect(harness.submits.count == 1 && harness.submits.first?.0 == "omni" && harness.submits.first?.1 == .enterShowHere)

    harness.type("summarise the thread for me")
    #expect(harness.pad.routeLine == .propose("⇥ search everywhere"))
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.last?.0 == "summarise the thread for me")
}

@Test @MainActor func arrowsPickARowAndTheSelectionIsTheJudgment() throws {
    let harness = try PadHarness()
    harness.type("omni")
    #expect(harness.pad.editor.onArrow?(1) == true)
    #expect(harness.pad.routeLine == .outcome("Open omni-intent · folder · ⇥ search everywhere"))
    #expect(harness.pad.editor.onArrow?(1) == true)
    harness.pad.editor.onSubmit?(.enterShowHere)
    let launch = try #require(harness.launches.first)
    #expect(launch.context.rank == 2 && launch.context.selection == .manual && !launch.context.ready)
    // ↑ above the first row gives Enter back to the proposal.
    harness.type("omni ")
    harness.pad.editor.onArrow?(1)
    harness.pad.editor.onArrow?(-1)
    #expect(harness.pad.launcherState?.highlighted == nil)
}

@Test @MainActor func enterDecidesOnTheCurrentTextNotAStaleBatch() throws {
    let harness = try PadHarness()
    harness.type("omni")
    #expect(harness.pad.launcherState?.results.query == "omni")
    // The next keystroke's rows have not arrived yet.
    harness.deliver = false
    harness.type("ghostty")
    #expect(harness.pad.launcherState?.results.query == "omni")
    // A late batch for older text is dropped.
    harness.pad.showLauncherResults(index.query("omn", now: now))
    #expect(harness.pad.launcherState?.results.query == "omni")
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.first?.id == "/Applications/Ghostty.app")
    #expect(harness.submits.isEmpty)
}

@Test @MainActor func slashCommandsAndImportedSelectionsLeaveSuggesting() throws {
    let harness = try PadHarness()
    harness.type("ghostty")
    #expect(harness.pad.mode == .suggesting)
    harness.type("/email ghostty")
    #expect(harness.pad.mode == .composing)
    #expect(harness.pad.launcherRowViews.isEmpty && harness.pad.launcherState == nil)
    harness.type("ghostty")
    #expect(harness.pad.mode == .suggesting)
    harness.pad.setProvenance(OmniPadProvenance(source: "Mail", wordCount: 1))
    #expect(harness.pad.mode == .composing)
    // D3 (decision step): imported material shows the offer row instead of
    // the *Add a command to this text* hint; Enter runs /stance.
    #expect(harness.pad.isOfferRowVisible)
    #expect(harness.pad.offerRowTitle == "Decide how to respond")
}

@Test @MainActor func aLaunchUndoMarksTheRowAndOffersAProposalFirst() throws {
    let harness = try PadHarness()
    harness.type("ghostty")
    harness.pad.markLaunchUndo(candidateID: "/Applications/Ghostty.app")
    #expect(harness.pad.launcherState?.items.first == .askForProposal)
    #expect(harness.pad.launcherRowViews.count == 3)
    #expect(harness.pad.routeLine == .propose("Ask for a proposal"))
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.isEmpty)
    #expect(harness.fallthroughs.first?.afterUndo == true)
    #expect(harness.submits.first?.0 == "ghostty")
    // Any keystroke drops the mark.
    harness.type("ghostt")
    #expect(harness.pad.launcherState?.undoneCandidateID == nil)
}

@Test @MainActor func proposalFlowTakesOverFromSuggestingAndHandsBack() throws {
    let harness = try PadHarness()
    harness.type("omni")
    harness.pad.beginWorking(runID: "run-1", requestText: harness.pad.editor.string)
    #expect(harness.pad.mode == .working(runID: "run-1"))
    #expect(harness.pad.launcherRowViews.isEmpty)
    harness.pad.returnToComposing()
    #expect(harness.pad.mode == .suggesting)
    #expect(harness.pad.launcherState?.results.query == "omni")
}

@Test @MainActor func commandZReachesTheFieldsOwnUndoStackWithoutAnEditMenu() throws {
    _ = NSApplication.shared
    let editor = OmniCommandTextView()
    final class Box { var undone = 0; var redone = 0 }
    let box = Box()
    editor.undoManager?.registerUndo(withTarget: box) { box in
        box.undone += 1
        editor.undoManager?.registerUndo(withTarget: box) { $0.redone += 1 }
    }
    func key(_ flags: NSEvent.ModifierFlags, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 6)!
    }
    editor.keyDown(with: key(.command, "z"))
    #expect(box.undone == 1)
    editor.keyDown(with: key([.command, .shift], "Z"))
    #expect(box.redone == 1)
}

// MARK: Review round 1 regressions

@Test @MainActor func aLongTypedSentenceStillFallsThroughAndPastedLinesGetTheOfferRow() throws {
    // S5/P4: past the query limit a sentence is not scored but Enter still proposes.
    let harness = try PadHarness()
    let sentence = String(repeating: "please summarise the coffee thread ", count: 4)
    harness.type(sentence)
    #expect(harness.pad.mode == .suggesting)
    #expect(harness.queries.isEmpty)
    #expect(harness.pad.routeLine == .propose("⇥ search everywhere"))
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.count == 1)
    harness.type("pasted line one\npasted line two")
    #expect(harness.pad.mode == .composing)
    // Pasted lines are material: the offer row replaces the paste-first hint (D3).
    #expect(harness.pad.isOfferRowVisible)
    #expect(harness.pad.offerRowTitle == "Decide what to do with this")
}

@Test @MainActor func aFailedOpenMarksTheRowAndEnterFallsThrough() throws {
    // P1: Enter must not go dead on a row that cannot open.
    let harness = try PadHarness()
    harness.type("ghostty")
    #expect(harness.pad.markLaunchFailed(candidateID: "/Applications/Ghostty.app"))
    #expect(harness.pad.launcherState?.items.first == .askForProposal)
    #expect(harness.pad.launcherState?.readyBadgeIndex == nil)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.isEmpty)
    #expect(harness.fallthroughs.first?.afterUndo == false)
    #expect(harness.submits.first?.0 == "ghostty")
}

@Test @MainActor func typingOnAfterAFailedOpenStartsANewQueryClock() throws {
    // Re-review: the clock was only started when entering `suggesting`.
    let harness = try PadHarness()
    harness.type("ghostty")
    harness.pad.editor.onSubmit?(.enterShowHere)
    harness.pad.markLaunchFailed(candidateID: "/Applications/Ghostty.app")
    harness.type("ghost")
    harness.pad.editor.onArrow?(1)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.count == 2)
    #expect(harness.launches.last?.context.elapsedMilliseconds != nil)
}

@Test @MainActor func aKeystrokeAfterTheUndoMarkRepaintsWithoutTheAskRow() throws {
    // P7: the badge must not land on a stale ask row.
    let harness = try PadHarness()
    harness.type("ghostty")
    harness.pad.markLaunchUndo(candidateID: "/Applications/Ghostty.app")
    #expect(harness.pad.launcherRowViews.count == 3)
    harness.deliver = false
    harness.type("ghostt")
    #expect(harness.pad.launcherRowViews.count == 2)
    #expect(harness.pad.launcherRowViews.first?.item != .askForProposal)
}

@Test @MainActor func aPickOnRowsNotYetRefreshedFollowsItsCandidateAtEnter() throws {
    // P7: a ↓ pick made on stale rows opens that candidate, not the new top row.
    let harness = try PadHarness()
    harness.type("ghostt")
    // The next keystroke's rows have not arrived when ↓ and Enter land.
    harness.deliver = false
    harness.type("ghostty")
    #expect(harness.pad.editor.onArrow?(1) == true)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.first?.id == "/Users/fixture/Tooling/docs/hq-ghostty.md")
    #expect(harness.launches.first?.context.selection == .manual)
}

@Test @MainActor func anIndexThatCannotAnswerSaysSoInsteadOfNothingMatches() throws {
    // S1.
    let harness = try PadHarness()
    harness.pad.onLauncherHealth = { "Launcher index is loading" }
    harness.pad.onLauncherQuery = { [unowned harness] text in harness.pad.showLauncherResults(.empty(LauncherQuery(text).text)) }
    harness.type("ghostty")
    #expect(harness.pad.routeLine == .propose("Launcher index is loading · ⇥ search everywhere"))
}

@Test @MainActor func commandZIsLeftAloneInALockedFieldOrDuringComposition() throws {
    // S2/P3: no undo under a pending proposal.
    _ = NSApplication.shared
    let editor = OmniCommandTextView()
    final class Box { var undone = 0 }
    let box = Box()
    editor.undoManager?.registerUndo(withTarget: box) { $0.undone += 1 }
    editor.isEditable = false
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    editor.keyDown(with: event)
    #expect(box.undone == 0)
    editor.isEditable = true
    editor.keyDown(with: event)
    #expect(box.undone == 1)
}

@Test @MainActor func commandASelectsTheWholeFieldWithoutAnEditMenu() throws {
    // The resident host installs no Edit menu, so the field handles ⌘A
    // itself: type, ⌘A, one Delete clears it. ⌘C/⌘X/⌘V share the path but
    // are not exercised here because they would touch the real pasteboard.
    _ = NSApplication.shared
    let editor = OmniCommandTextView()
    func command(_ key: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
    }
    editor.string = "lorem ipsum"
    editor.setSelectedRange(NSRange(location: 11, length: 0))
    editor.keyDown(with: command("a", keyCode: 0))
    #expect(editor.selectedRange() == NSRange(location: 0, length: 11))
    editor.deleteBackward(nil)
    #expect(editor.string.isEmpty)
    // A locked field (proposal flow) still selects, but neither cuts nor pastes.
    editor.string = "pending"
    editor.isEditable = false
    editor.keyDown(with: command("a", keyCode: 0))
    #expect(editor.selectedRange() == NSRange(location: 0, length: 7))
    editor.keyDown(with: command("x", keyCode: 7))
    editor.keyDown(with: command("v", keyCode: 9))
    #expect(editor.string == "pending")
}

@Test @MainActor func readOnlyWorkspaceTextSelectsAllButNeverCutsOrPastes() throws {
    _ = NSApplication.shared
    let text = OmniSelectableTextView(frame: .zero)
    text.isEditable = false
    text.isSelectable = true
    text.string = "Second output"
    func command(_ key: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
    }
    text.keyDown(with: command("a", keyCode: 0))
    #expect(text.selectedRange() == NSRange(location: 0, length: 13))
    text.keyDown(with: command("x", keyCode: 7))
    text.keyDown(with: command("v", keyCode: 9))
    #expect(text.string == "Second output")
}

@Test @MainActor func thePadOpensEmptyWithoutGhostText() throws {
    let harness = try PadHarness()
    #expect(harness.pad.editor.string.isEmpty)
    #expect(harness.pad.editor.placeholder.isEmpty)
}

// MARK: Opt-in design capture

/// `OMNI_CAPTURE_DIR=/some/dir swift test --filter designCaptureLauncherPad`
/// renders the four launcher states in light and dark. No-op without it.
@Test @MainActor func designCaptureLauncherPad() throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return }
    let out = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let states: [(String, (PadHarness) -> Void)] = [
        ("launcher-ready", { $0.type("ghostty") }),
        ("launcher-unready", { $0.type("omni") }),
        ("launcher-nothing", { $0.type("summarise the thread for me") }),
        ("launcher-undo", { harness in harness.type("ghostty"); harness.pad.markLaunchUndo(candidateID: "/Applications/Ghostty.app") }),
    ]
    for (name, setUp) in states {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let harness = try PadHarness()
            setUp(harness)
            let view = harness.pad.view
            view.appearance = NSAppearance(named: appearance)
            func opaque(_ candidate: NSView) {
                (candidate as? OmniFrostedSurface)?.apply(transparency: .opaqueFallback)
                candidate.subviews.forEach(opaque)
            }
            opaque(view)
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds.integral
            let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            representation.size = bounds.size
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: bounds, to: representation) }
            let png = try #require(representation.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
