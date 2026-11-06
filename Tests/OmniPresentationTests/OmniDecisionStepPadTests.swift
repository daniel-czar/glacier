import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

// Decision step in the pad (D3, D6): the offer row on material, the
// `options` result kind, its keys, and the route line's position title.

@MainActor
private func decisionParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    return OmniParser(manifest: manifest, references: try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)]))
}

@MainActor
private final class DecisionPad {
    let pad: OmniCommandPadViewController
    var submits: [(String, OmniSubmitGesture)] = []
    var picks: [(runID: String, index: Int, ticked: [Int], gesture: OmniPadPickGesture)] = []
    var escapes = 0

    init(launcher: Bool = true) throws {
        _ = NSApplication.shared
        pad = OmniCommandPadViewController(parser: try decisionParser())
        pad.loadView()
        _ = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        pad.onLauncherQuery = { [unowned self] text in pad.showLauncherResults(.empty(LauncherQuery(text).text, lane: .curated)) }
        pad.onSubmit = { [unowned self] text, gesture in submits.append((text, gesture)) }
        pad.onPickOption = { [unowned self] runID, index, ticked, gesture in picks.append((runID, index, ticked, gesture)) }
        pad.onEscape = { [unowned self] in escapes += 1 }
        pad.launcherEnabled = launcher
    }

    func type(_ text: String) {
        pad.editor.string = text
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func showPositions(noticed: [OmniPadNoticed] = []) {
        pad.beginWorking(runID: "run-stance", requestText: "material /stance", summary: "Positions")
        pad.showOptions(runID: "run-stance", options: OmniPadOptions(
            heading: "POSITIONS · PICK ONE",
            options: [
                .init(id: "1", title: "Accept as asked", detail: "Say yes plainly."),
                .init(id: "2", title: "Decline without a reason", detail: "Say no; add nothing."),
                .init(id: "3", title: "Ask one question", detail: "Ask which day suits."),
                .init(id: "4", title: "Hold for now", detail: "A short holding reply."),
            ],
            noticed: noticed,
            summary: "Positions · a pick drafts an email",
            pickVerb: "Draft"
        ))
    }
}

@MainActor
private func key(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

private let mail = "Hey Daniel — coffee Thursday?\nI can do 15:30 near the office.\n\nMira"

// MARK: Offer row scope (D3)

@Test @MainActor func capturedOrMultiLineMaterialShowsTheOfferRowWordedBySource() throws {
    let harness = try DecisionPad()
    harness.type("Thanks for the draft, I'll read it tonight")
    harness.pad.setProvenance(OmniPadProvenance(source: "Mail", detail: "Re: draft", wordCount: 8))
    #expect(harness.pad.isOfferRowVisible)
    #expect(harness.pad.offerRowTitle == "Decide how to respond")
    harness.pad.setProvenance(OmniPadProvenance(source: "Xcode", wordCount: 8))
    #expect(harness.pad.offerRowTitle == "Decide how to approach")
    harness.pad.setProvenance(OmniPadProvenance(source: "Safari", wordCount: 8))
    #expect(harness.pad.offerRowTitle == "Decide what to do with this")
    harness.pad.setProvenance(nil)
    harness.type("line one\nline two")
    #expect(harness.pad.isOfferRowVisible)
    #expect(harness.pad.offerRowTitle == "Decide what to do with this")
    // The row replaces the paste-first hint and Enter is never dead there.
    #expect(harness.pad.routeLine != .hint(OmniCommandPadViewController.addCommandHint))
    #expect(harness.pad.footerState.submits)
}

@Test @MainActor func theOfferRowNeverAppearsWhereTheLauncherOrACommandApplies() throws {
    let harness = try DecisionPad()
    harness.type("ghostty")
    #expect(harness.pad.mode == .suggesting)
    #expect(!harness.pad.isOfferRowVisible)
    harness.type("line one\nline two /email")
    #expect(!harness.pad.isOfferRowVisible)
    harness.type("line one\nline two @zoe")
    #expect(!harness.pad.isOfferRowVisible)
    harness.type("line one\nline two /offline")
    #expect(!harness.pad.isOfferRowVisible)
    // A note keeps annotated bare text's *Ask for a proposal* short-circuit.
    harness.type("line one\nline two")
    harness.pad.setAnnotations([OmniTextAnnotation(range: NSRange(location: 0, length: 4), guidance: "Keep this")])
    #expect(!harness.pad.isOfferRowVisible)
    #expect(harness.pad.routeLine == .propose(OmniCommandPadViewController.annotatedProposalLine))
    // Without the launcher composed, short bare text still is not material.
    let plain = try DecisionPad(launcher: false)
    plain.type("a short sentence")
    #expect(!plain.pad.isOfferRowVisible)
    #expect(plain.pad.routeLine == .hint(OmniCommandPadViewController.addCommandHint))
}

@Test @MainActor func enterOnMaterialInsertsStanceVisiblyAndSubmitsIt() throws {
    let harness = try DecisionPad()
    harness.type(mail)
    harness.pad.setProvenance(OmniPadProvenance(source: "Mail", wordCount: 14))
    #expect(harness.pad.isOfferRowVisible)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.pad.editor.string == mail + " /stance")
    #expect(harness.submits.count == 1)
    #expect(harness.submits.first?.0.hasSuffix("/stance") == true)
    #expect(harness.submits.first?.1 == .enterShowHere)
    #expect(!harness.pad.isOfferRowVisible)
}

@Test @MainActor func arrowsInMultiLineMaterialMoveTheCaretNotTheOfferRow() throws {
    let harness = try DecisionPad()
    harness.type(mail)
    #expect(harness.pad.isOfferRowVisible)
    #expect(harness.pad.editor.onArrow?(1) == false)
    #expect(harness.pad.editor.onArrow?(-1) == false)
}

// MARK: Options result (D6)

@Test @MainActor func digitsOneToFourPickAtOnceByKeyCode() throws {
    let harness = try DecisionPad()
    harness.showPositions()
    #expect(harness.pad.result?.kind == .options)
    #expect(harness.pad.optionRows.count == 4)
    #expect(harness.pad.routeLine == .outcome("Positions · a pick drafts an email"))
    harness.pad.submittedRequestView.keyDown(with: key(21, "4"))
    #expect(harness.picks.count == 1)
    #expect(harness.picks.first?.index == 3)
    #expect(harness.picks.first?.gesture == .run)
    harness.pad.submittedRequestView.keyDown(with: key(19, "2"))
    #expect(harness.picks.last?.index == 1)
    // Keys past the last position, and ⌘/⌃/⇧ digits, never pick (C73).
    harness.pad.submittedRequestView.keyDown(with: key(23, "5"))
    harness.pad.submittedRequestView.keyDown(with: key(18, "1", .command))
    harness.pad.submittedRequestView.keyDown(with: key(18, "1", .control))
    harness.pad.submittedRequestView.keyDown(with: key(18, "!", .shift))
    #expect(harness.picks.count == 2)
    #expect(OmniDigitKeys.digit(forKeyCode: 21) == 4)
    #expect(OmniDigitKeys.digit(forKeyCode: 23) == 5)
}

@Test @MainActor func enterPicksTheHighlightedPositionAndOptionEditsFirst() throws {
    let harness = try DecisionPad()
    harness.showPositions()
    harness.pad.submittedRequestView.keyDown(with: key(125, ""))
    harness.pad.submittedRequestView.keyDown(with: key(125, ""))
    harness.pad.submittedRequestView.keyDown(with: key(36, "\r"))
    #expect(harness.picks.last?.index == 2)
    #expect(harness.picks.last?.gesture == .run)
    harness.pad.submittedRequestView.keyDown(with: key(36, "\r", .option))
    #expect(harness.picks.last?.gesture == .editFirst)
    harness.pad.submittedRequestView.keyDown(with: key(18, "¡", .option))
    #expect(harness.picks.last?.index == 0)
    #expect(harness.picks.last?.gesture == .editFirst)
    harness.pad.submittedRequestView.keyDown(with: key(53, "\u{1b}"))
    #expect(harness.escapes == 1)
}

@Test @MainActor func lettersTickNoticedItemsAndTheDigitCommitsThem() throws {
    let harness = try DecisionPad()
    harness.showPositions(noticed: [
        .init(id: "a", label: "suppression", note: "Mira plays down her constraint.", quote: "kinder to your stack"),
        .init(id: "b", label: "off-stage context", note: "Friday is pressing."),
        .init(id: "c", label: "causal pair", note: "The meeting exists for the draft."),
    ])
    #expect(harness.pad.noticedRows.count == 3)
    #expect(harness.pad.footerState.keyHints.contains(.init("a–c", "Tick")))
    harness.pad.submittedRequestView.keyDown(with: key(0, "a"))
    harness.pad.submittedRequestView.keyDown(with: key(8, "c"))
    harness.pad.submittedRequestView.keyDown(with: key(8, "c"))
    harness.pad.submittedRequestView.keyDown(with: key(8, "c"))
    harness.pad.submittedRequestView.keyDown(with: key(2, "d"))
    #expect(harness.pad.tickedNoticed == [0, 2])
    #expect(harness.picks.isEmpty, "a tick is never a pick")
    harness.pad.submittedRequestView.keyDown(with: key(19, "2"))
    #expect(harness.picks.first?.ticked == [0, 2])
    #expect(harness.picks.first?.index == 1)
}

@Test @MainActor func optionsResultsNeverCopyAndCommandEnterOpensTheWorkspace() throws {
    let harness = try DecisionPad()
    var copies = 0
    var opens: [String] = []
    harness.pad.onCopyResult = { _ in copies += 1 }
    harness.pad.onOpenResult = { opens.append($0) }
    harness.showPositions()
    harness.pad.submittedRequestView.keyDown(with: key(36, "\r", .command))
    #expect(opens == ["run-stance"])
    #expect(copies == 0)
    #expect(!harness.pad.runButton.isHidden)
}

@Test @MainActor func aChosenPositionsTitleJoinsTheRouteLine() throws {
    let harness = try DecisionPad()
    harness.type(mail + " /email ✗")
    harness.pad.setAnnotations([.request(guidance: "Reply declining.", origin: .proposed, label: "Decline without a reason")])
    #expect(harness.pad.routeLine.text.hasPrefix("Email draft"))
    #expect(harness.pad.routeLine.text.hasSuffix(" · Decline without a reason"))
    #expect(harness.pad.annotations.first?.isRequestScoped == true)
    // A request note has no tint and survives the submitted-request clip.
    harness.pad.beginWorking(runID: "run-draft", requestText: harness.pad.editor.string, annotations: harness.pad.annotations, summary: "Email draft · Decline without a reason")
    #expect(harness.pad.submittedRequestView.annotations.count == 1)
    #expect(harness.pad.routeLine == .waiting("Email draft · Decline without a reason"))
}

@Test @MainActor func clearingTheRequestTakesItsRequestNotes() throws {
    let harness = try DecisionPad()
    harness.type(mail)
    harness.pad.setAnnotations([.request(guidance: "Accept", origin: .proposed, label: "Accept")])
    #expect(harness.pad.annotations.count == 1)
    harness.type("")
    harness.pad.editor.reconcileAnnotations()
    #expect(harness.pad.annotations.isEmpty)
}

@Test @MainActor func theNotesOverviewListsRequestNotesFirstAndMarksSuggestions() {
    let span = OmniTextAnnotation(range: NSRange(location: 4, length: 6), guidance: "Keep", origin: .proposed)
    let user = OmniTextAnnotation(range: NSRange(location: 0, length: 3), guidance: "Mine")
    let pick = OmniTextAnnotation.request(guidance: "Decline", origin: .proposed, label: "Decline warmly")
    let ordered = OmniAnnotationUI.overviewOrder([span, user, pick])
    #expect(ordered.map(\.id) == [pick.id, user.id, span.id])
    let source = "Hey Daniel, coffee?" as NSString
    #expect(OmniAnnotationUI.overviewSnippet(pick, source: source) == "Whole request · Decline warmly · suggested")
    #expect(OmniAnnotationUI.overviewSnippet(span, source: source) == "“Daniel” · suggested")
    #expect(OmniAnnotationUI.overviewSnippet(user, source: source) == "“Hey”")
    // A whole-request tick has no position: its guidance leads with the point.
    let tick = OmniTextAnnotation.request(guidance: "purpose or lifecycle: Board prep is the deadline — take this into account in the response.", origin: .proposed)
    #expect(OmniAnnotationUI.overviewSnippet(tick, source: source) == "Whole request · purpose or lifecycle: Board prep is the de… · suggested")
}

// MARK: Review fixes (M1 review)

@Test @MainActor func materialThatMentionsPathsOrHandlesStillGetsTheOfferRow() throws {
    let harness = try DecisionPad()
    harness.pad.setProvenance(OmniPadProvenance(source: "Terminal", wordCount: 6))
    harness.type("cd /Users/x/Tooling\nls -la")
    #expect(harness.pad.isOfferRowVisible)
    harness.pad.setProvenance(OmniPadProvenance(source: "Xcode", wordCount: 4))
    harness.type("@MainActor\nfunc render()")
    #expect(harness.pad.isOfferRowVisible)
    harness.pad.setProvenance(OmniPadProvenance(source: "Slack", wordCount: 5))
    harness.type("@here can someone\nlook at this")
    #expect(harness.pad.isOfferRowVisible)
    // Real command syntax still disqualifies.
    harness.type("@zoe can you\nlook at this")
    #expect(!harness.pad.isOfferRowVisible)
    harness.type("can you\nlook at this /")
    #expect(!harness.pad.isOfferRowVisible)
}

@Test @MainActor func theOfferRowResolvesOnlyTheStanceRoute() throws {
    let harness = try DecisionPad()
    var resolved: [String?] = []
    harness.pad.onResolveRoute = { intent, _ in
        resolved.append(intent.dispatchToken)
        // Tier 2 is down; /stance is fine.
        return intent.dispatchToken == nil ? OmniPadRoute(providerName: nil, unavailable: "Proposals unavailable") : OmniPadRoute(providerName: "Cerebras")
    }
    harness.type(mail)
    harness.pad.setProvenance(OmniPadProvenance(source: "Mail", wordCount: 14))
    #expect(harness.pad.isOfferRowVisible)
    #expect(!resolved.isEmpty)
    #expect(resolved.allSatisfy { $0 == "/stance" }, "one command route per render, never the bare text's")
    #expect(harness.pad.footerState.submits)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.count == 1)
    #expect(harness.submits.first?.0.hasSuffix("/stance") == true)
}

@Test @MainActor func digitsTypedWhileComposingAreNeverConsumed() throws {
    let harness = try DecisionPad()
    harness.type(mail)
    #expect(harness.pad.editor.onDigit?(2) == false)
    #expect(harness.pad.editor.onDigit?(4) == false)
}

@Test @MainActor func replacingTheWholeMaterialDropsItsRequestNoteUndoably() throws {
    let harness = try DecisionPad()
    harness.type(mail + " /email ✓")
    harness.pad.setAnnotations([.request(guidance: "Accept", origin: .proposed, label: "Accept")])
    let editor = harness.pad.editor
    let whole = NSRange(location: 0, length: (editor.string as NSString).length)
    let next = "A different mail\n\nSam"
    editor.undoManager?.beginUndoGrouping()
    if editor.shouldChangeText(in: whole, replacementString: next) {
        editor.textStorage?.replaceCharacters(in: whole, with: next)
        editor.didChangeText()
    }
    editor.undoManager?.endUndoGrouping()
    #expect(editor.string == next)
    #expect(harness.pad.annotations.isEmpty)
    editor.undoManager?.undo()
    #expect(editor.string == mail + " /email ✓")
    #expect(harness.pad.annotations.first?.label == "Accept")
}

@Test @MainActor func theWorkspaceInputNamesWholeRequestNotes() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    let pick = OmniTextAnnotation.request(guidance: "Reply accepting.", origin: .proposed, label: "Accept as asked")
    workspace.displayResult(
        runID: "r", title: "Reply · Coffee", status: "succeeded",
        versions: [OmniWorkspaceVersion(number: 1, inputText: mail + " /email ✓", resultText: "Hi Mira", operation: "initial", annotations: [pick])],
        selectedVersion: 1, submittedAnnotations: [pick]
    )
    func find(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for child in view.subviews { if let hit = find(id, in: child) { return hit } }
        return nil
    }
    let root = try #require(workspace.workspacePanel.contentView)
    let disclosure = try #require(find("omni.workspace.input-disclosure", in: root) as? NSButton)
    disclosure.performClick(nil)
    let line = try #require(find("omni.workspace.request-notes", in: root) as? NSTextField)
    #expect(line.stringValue == "Whole request · Accept as asked · suggested")
}

// MARK: Bare /expand (milestone 3)

@Test @MainActor func bareExpandShowsTheFiveLensesLocallyAndAPickRunsTheValuedToken() throws {
    let harness = try DecisionPad()
    harness.type("receipts make agents honest /expand")
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.isEmpty, "bare /expand never submits")
    #expect(harness.pad.isShowingLocalOptions)
    #expect(harness.pad.options?.options.map(\.id) == ["deepen", "broaden", "concretise", "challenge", "connect"])
    harness.pad.submittedRequestView.keyDown(with: key(23, "5"))
    #expect(harness.pad.mode == .composing)
    #expect(harness.pad.editor.string == "receipts make agents honest /expand:connect")
    #expect(harness.submits.last?.0.hasSuffix("/expand:connect") == true)
    #expect(harness.picks.isEmpty, "a local pick never reaches the run chooser")
}

@Test @MainActor func editFirstOnALensLeavesTheTokenAndEscKeepsTheText() throws {
    let harness = try DecisionPad()
    harness.type("an idea /expand")
    harness.pad.editor.onSubmit?(.enterShowHere)
    harness.pad.submittedRequestView.keyDown(with: key(18, "¡", .option))
    #expect(harness.pad.editor.string == "an idea /expand:deepen")
    #expect(harness.submits.isEmpty)
    harness.type("an idea /expand")
    harness.pad.editor.onSubmit?(.enterShowHere)
    harness.pad.submittedRequestView.keyDown(with: key(53, "\u{1b}"))
    #expect(harness.pad.mode == .composing)
    #expect(harness.pad.editor.string == "an idea /expand")
    #expect(harness.escapes == 0, "esc on the lenses returns to composing, not to the host")
    // A valued token typed directly skips the picker.
    harness.type("an idea /expand:broaden")
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.last?.0.hasSuffix("/expand:broaden") == true)
    #expect(!harness.pad.isShowingLocalOptions)
}

@Test @MainActor func aLoneSlashOrAtIsCommandSyntaxOnlyAtTheCaret() throws {
    let harness = try DecisionPad()
    harness.pad.setProvenance(OmniPadProvenance(source: "Mail", wordCount: 9))
    harness.type("Could we meet Tue / Wed\nor meet @ 3 instead?")
    #expect(harness.pad.isOfferRowVisible)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.last?.0.hasSuffix("/stance") == true)
}
