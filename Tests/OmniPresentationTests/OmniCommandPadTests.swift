import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

@MainActor
private func padParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    let references = try ReferenceRegistry([
        PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)
    ])
    return OmniParser(manifest: manifest, references: references)
}

@MainActor
private func footer(_ text: String, route: OmniPadRoute? = OmniPadRoute(providerName: "Cerebras"), completion: Bool = false, transient: String? = nil) throws -> OmniPadFooterState {
    let parser = try padParser()
    return OmniCommandPadViewController.footerState(for: parser.parse(text), route: route, completionVisible: completion, transientMessage: transient)
}

@Test @MainActor func workspaceCommandOpensNativeWorkspaceWithoutSubmittingRun() throws {
    let parser = try padParser()
    let intent = parser.parse("/workspace")
    #expect(SubmissionClassifier().classify(intent) == .tier1(dispatchToken: "/workspace"))
    #expect(try footer("/workspace", route: nil).routeLine == .outcome("Workspace"))
    let pad = OmniCommandPadViewController(parser: parser)
    pad.loadView()
    var opens = 0
    var submissions = 0
    pad.onOpenWorkspace = { opens += 1 }
    pad.onSubmit = { _, _ in submissions += 1 }
    pad.editor.string = "/workspace"
    pad.editor.onSubmit?(.enterShowHere)
    #expect(opens == 1)
    #expect(submissions == 0)
    pad.editor.string = "/workspace extra"
    pad.editor.onSubmit?(.enterShowHere)
    #expect(opens == 1)
    #expect(submissions == 0)
    #expect(OmniPadVocabulary.help(for: "/workspace").contains("workspace window"))
}

@Test @MainActor func footerStateFollowsTheRouteLineTable() throws {
    let empty = try footer("")
    #expect(empty.routeLine == .hint(OmniCommandPadViewController.emptyHint))
    #expect(!empty.runEnabled && !empty.submits)
    #expect(empty.keyHints == OmniPadKeyHint.run)

    let bare = try footer("Hey Daniel, coffee on Thursday?")
    #expect(bare.routeLine == .hint(OmniCommandPadViewController.addCommandHint))
    #expect(!bare.runEnabled && !bare.submits)

    let composed = try footer("Hey /email accept the invitation /style:formal")
    #expect(composed.routeLine == .outcome("Email draft · formal"))
    #expect(composed.runEnabled && composed.submits)
    #expect(composed.keyHints == OmniPadKeyHint.run)

    let valued = try footer("/translate:de gartenschlauch")
    #expect(valued.routeLine == .outcome("Translation · de"))

    let deterministic = try footer("/g coffee near the office", route: nil)
    #expect(deterministic.routeLine == .outcome("Google search"))

    let override = try footer("/email accept /style:formal /offline", route: OmniPadRoute(providerName: "Local", scope: .thisRunOnly))
    #expect(override.routeLine == .outcome("Email draft · formal · Local, this run only"))

    let unknown = try footer("/summarise the thread")
    #expect(unknown.routeLine == .propose("/summarise isn't a command · ↩ asks for a proposal instead"))
    #expect(unknown.keyHints == OmniPadKeyHint.propose)
    #expect(unknown.runEnabled && unknown.submits)

    let invalid = try footer("/email x /style:casual")
    if case .propose(let text) = invalid.routeLine { #expect(text.hasPrefix("invalid value")) } else { Issue.record("expected a proposal line") }

    let combined = try footer("/email x /todo y")
    #expect(combined.routeLine == .propose("multiple commands · ↩ asks for a proposal instead"))

    let notReady = try footer("/email x /style:formal", route: OmniPadRoute(providerName: nil, unavailable: "Cerebras: credential is missing"))
    #expect(notReady.routeLine == .attention("Cerebras: credential is missing"))
    #expect(!notReady.runEnabled && !notReady.submits)
    #expect(notReady.keyHints == OmniPadKeyHint.dismissOnly)

    let typing = try footer("/t", completion: true)
    #expect(typing.routeLine == .hint(OmniCommandPadViewController.typingHint))
    #expect(typing.keyHints == OmniPadKeyHint.completion)
    // The menu never changes what Enter or the ↑ button does (C22, C25).
    #expect(typing.runEnabled && typing.submits)

    let notice = try footer("/email x", transient: "Replaced your unsent draft · ⌘Z restores it")
    #expect(notice.routeLine == .notice("Replaced your unsent draft · ⌘Z restores it"))
    #expect(notice.keyHints == OmniPadKeyHint.run)
}

@Test @MainActor func spanConfirmsItsParseInTheRouteLineWhileTyping() throws {
    // C82: the endpoints as read and the headline, before anything runs.
    let typed = try footer("/span 1 oct 2014 to 30 sep 2016", route: nil)
    #expect(typed.routeLine == .outcome("1 Oct 2014 – 30 Sep 2016 · 2 years · 731 days"))
    #expect(typed.runEnabled && typed.submits)
    #expect(typed.keyHints == OmniPadKeyHint.run)
    // Two endpoints on two lines read the same.
    #expect(try footer("/span 1 october 2014\n30 september 2016", route: nil).routeLine == .outcome("1 Oct 2014 – 30 Sep 2016 · 2 years · 731 days"))
    #expect(try footer("/span 1 oct 2014 to 30 sep 2016 excl /offline", route: nil).routeLine == .outcome("1 Oct 2014 – 30 Sep 2016 · 1 year, 11 months, 29 days · 730 days"))
    let offset = try footer("/span 5 months after 19 october 2026", route: nil)
    #expect(offset.routeLine == .outcome("19 Mar 2027 · 5 months after 19 Oct 2026"))
    #expect(offset.runEnabled && offset.submits)
    #expect(try footer("/span 5 months before 19 october 2026 /offline", route: nil).routeLine == .outcome("19 May 2026 · 5 months before 19 Oct 2026"))
    // Bare, or not parseable yet: the static outcome, never an error.
    #expect(try footer("/span", route: nil).routeLine == .outcome("Time span"))
    #expect(try footer("/span 1 oct 20", route: nil).routeLine == .outcome("Time span"))
    #expect(try footer("/span hello", route: nil).routeLine == .outcome("Time span"))
    // The help column's kind line already says where it runs.
    let span = try #require(try padParser().manifest.command(for: "/span"))
    #expect(OmniPadVocabulary.kind(for: span) == "Command · runs locally")
    #expect(OmniPadVocabulary.outcome(for: "/span") == "Time span")
    #expect(OmniPadVocabulary.description(for: "/span").contains("date offset"))
    #expect(OmniPadVocabulary.help(for: "/span").contains("5 months after 19 oct 2026"))
}

@Test @MainActor func routeLinesFitWithNotesAndModelControlsAtTheFixedPadWidth() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    pad.setModelChoices([OmniModelChoice(id: "fixture", label: "Claude Sonnet medium")])
    pad.selectModelProfile(id: "fixture")
    pad.notesButton.title = "12 notes"
    pad.notesButton.isHidden = false
    pad.keyHintsView.hints = OmniPadKeyHint.launcherPropose
    let lines: [OmniPadRouteLine] = [
        .propose(OmniCommandPadViewController.pickOrProposeLine),
        .propose(OmniCommandPadViewController.nothingMatchesLine),
        .propose(OmniCommandPadViewController.proposeInsteadLine),
        .propose(OmniCommandPadViewController.annotatedProposalLine),
        .propose("Launcher index is loading"),
        .outcome("Open " + String(repeating: "long document title ", count: 8) + "· document"),
        .outcome("24 Oct 2026 23:59 – 26 Oct 2026 14:46 · 1 day, 14 h, 47 min · 38.8 hours"),
        .attention("Cerebras: credential is missing"),
        .notice("Replaced your unsent draft · ⌘Z restores it"),
    ]
    for line in lines {
        pad.statusLabel.attributedStringValue = OmniCommandPadViewController.attributedRouteLine(line)
        pad.layoutPad(width: OmniPadPlacement.width)
        let fitting = pad.statusLabel.fittingSize
        #expect(fitting.width <= pad.statusLabel.frame.width + 1)
        #expect(fitting.height <= pad.statusLabel.frame.height + 1)
        #expect(pad.statusLabel.frame.minX >= 16)
        #expect(pad.statusLabel.frame.maxX <= OmniPadPlacement.width - 16)
        #expect(!pad.statusLabel.frame.intersects(pad.notesButton.frame))
        #expect(!pad.statusLabel.frame.intersects(pad.modelPopUp.frame))
        #expect(!pad.statusLabel.frame.intersects(pad.modelOverrideLabel.frame))
        #expect(!pad.statusLabel.frame.intersects(pad.clearModelButton.frame))
        #expect(!pad.modelPopUp.frame.intersects(pad.notesButton.frame))
        #expect(!pad.modelOverrideLabel.frame.intersects(pad.notesButton.frame))
        #expect(!pad.clearModelButton.frame.intersects(pad.notesButton.frame))
        #expect(!pad.statusLabel.frame.intersects(pad.keyHintsView.frame))
        #expect(!pad.statusLabel.frame.intersects(pad.runButton.frame))
        // C116: the model controls are retired from the footer.
        #expect(pad.modelPopUp.isHidden && pad.modelOverrideLabel.isHidden && pad.clearModelButton.isHidden)
    }
}

/// C116: the footer's model chevron is retired; model choice is Settings →
/// Models or `/model`, and the route line's tooltip names the model.
@Test @MainActor func retiredModelChevronLeavesTheRouteLineNamingTheModel() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    pad.setModelChoices([
        OmniModelChoice(id: "claude-capable", label: "Claude Sonnet medium"),
        OmniModelChoice(id: "local-fast", label: "Local Qwen3 8B"),
    ])
    #expect(pad.modelPopUp.isHidden)
    #expect(pad.modelOverrideLabel.isHidden && pad.clearModelButton.isHidden)
    pad.onResolveRoute = { _, id in
        OmniPadRoute(
            providerName: id == nil ? "Cerebras" : "Claude",
            scope: id == nil ? .policyDefault : .thisRunOnly,
            displayName: id == nil ? "Cerebras Qwen 3.8 27B" : "Claude Sonnet medium"
        )
    }
    pad.editor.string = "/email accept /style:formal"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(pad.routeLine == .outcome("Email draft · formal"))
    #expect(pad.modelPopUp.isHidden)
    #expect(pad.statusLabel.toolTip == "Cerebras Qwen 3.8 27B (default)")
    #expect(pad.modelPopUp.toolTip == nil)
}

@Test @MainActor func localOnlyRouteKeepsItsVisibleScopeAndTooltip() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    pad.setModelChoices([OmniModelChoice(id: "local-fast", label: "Local Qwen3 8B")])
    pad.onResolveRoute = { _, _ in OmniPadRoute(providerName: "Local", scope: .thisRunOnly, displayName: "Local Qwen3 8B") }
    pad.editor.string = "/email accept /offline"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(pad.routeLine == .outcome("Email draft · Local, this run only"))
    #expect(pad.statusLabel.toolTip == "Local Qwen3 8B (this run)")
}

@Test @MainActor func modelChevronDisablesPhysicalBlocksAndKeepsTheReason() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    pad.setModelChoices([
        .init(id: "claude-capable", label: "Claude Sonnet medium", unavailabilityReason: "Claude: not logged in"),
        .init(id: "chatgpt-capable", label: "ChatGPT GPT-5.6 medium"),
    ])
    let item = try #require(pad.modelPopUp.item(at: 2))
    #expect(!item.isEnabled)
    #expect(item.title == "Claude Sonnet medium — Claude: not logged in")
    #expect(item.toolTip == "Claude: not logged in")
    #expect(pad.modelPopUp.item(at: 3)?.isEnabled == true)
    pad.modelPopUp.selectItem(at: 2)
    _ = pad.modelPopUp.sendAction(pad.modelPopUp.action, to: pad.modelPopUp.target)
    #expect(pad.selectedModelProfileID == nil)
}

@Test @MainActor func proposalsHaveTheSamePhysicalPrecheckAndNoSetupButton() throws {
    let unavailable = OmniPadRoute(providerName: nil, unavailable: "Claude: not logged in", recoveryHint: "Log in with the Claude CLI")
    for text in ["/summarise this", "/email /msg hello", "plain text"] {
        let state = try footer(text, route: unavailable, completion: true)
        #expect(state.routeLine == .attention("Claude: not logged in"))
        #expect(!state.submits && !state.runEnabled)
    }
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    pad.onResolveRoute = { _, _ in unavailable }
    pad.editor.string = "/summarise this"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    var submissions = 0
    pad.onSubmit = { _, _ in submissions += 1 }
    pad.editor.onSubmit?(.enterShowHere)
    #expect(submissions == 0)
    #expect(pad.settingsButton.isHidden)
    #expect(pad.statusLabel.toolTip == "Log in with the Claude CLI")
}

@Test @MainActor func launcherProposalPrecheckDoesNotBlockMechanicalLaunches() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    pad.launcherEnabled = true
    pad.onResolveLauncher = { text in .empty(LauncherQuery(text).text) }
    pad.onResolveRoute = { _, _ in .init(providerName: nil, unavailable: "ChatGPT: Codex CLI not found") }
    pad.editor.string = "synthesize this idea"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(pad.routeLine == .attention("ChatGPT: Codex CLI not found"))
    var submissions = 0
    pad.onSubmit = { _, _ in submissions += 1 }
    pad.editor.onSubmit?(.enterShowHere)
    #expect(submissions == 0)
}

@Test @MainActor func modelChevronClearAndResultVisibility() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    pad.setModelChoices([OmniModelChoice(id: "claude-capable", label: "Claude Sonnet medium")])
    pad.selectModelProfile(id: "claude-capable")
    pad.clearModelButton.performClick(nil)
    #expect(pad.selectedModelProfileID == nil)
    #expect(pad.modelOverrideLabel.isHidden && pad.clearModelButton.isHidden)
    pad.selectModelProfile(id: "claude-capable")
    pad.beginWorking(runID: "r1", requestText: "/email accept")
    #expect(pad.modelPopUp.isHidden && pad.modelOverrideLabel.isHidden && pad.clearModelButton.isHidden)
    pad.showResult(runID: "r1", result: OmniPadResult(kind: .text, body: "Done", summary: "Email draft"))
    #expect(pad.modelPopUp.isHidden && pad.modelOverrideLabel.isHidden && pad.clearModelButton.isHidden)
    pad.returnToComposing()
    // C116: composing again never brings the retired chevron back.
    #expect(pad.modelPopUp.isHidden)
}

@Test @MainActor func completionAcceptsWithTabMovesWithArrowsAndEscClosesTheMenuFirst() throws {
    _ = NSApplication.shared
    let controller = OmniCommandPadViewController(parser: try padParser())
    controller.loadView()
    _ = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    var escapes = 0
    controller.onEscape = { escapes += 1 }
    let change = Notification(name: NSText.didChangeNotification)

    controller.editor.string = "/t"
    controller.editor.setSelectedRange(NSRange(location: 2, length: 0))
    controller.textDidChange(change)
    #expect(controller.isCompletionVisible)
    #expect(Set(controller.completionChoices.map(\.canonicalText)) == ["/todo", "/translate"])
    #expect(controller.completionMenu != nil)
    #expect(controller.routeLine == .hint(OmniCommandPadViewController.typingHint))

    // Esc closes the menu first, the pad second (C25).
    #expect(controller.editor.onEscapeMenu?() == true)
    #expect(!controller.isCompletionVisible)
    #expect(escapes == 0)
    #expect(controller.editor.onEscapeMenu?() == false)

    controller.textDidChange(change)
    #expect(controller.isCompletionVisible)
    let first = controller.completionChoices[0].canonicalText
    let second = controller.completionChoices[1].canonicalText
    #expect(controller.editor.onArrow?(1) == true)
    #expect(controller.completionIndex == 1)
    #expect(controller.editor.onArrow?(1) == true)
    #expect(controller.completionIndex == 0)
    #expect(controller.editor.onArrow?(-1) == true)
    #expect(controller.completionIndex == 1)
    #expect(controller.editor.onTab?() == true)
    #expect(controller.editor.string == second)
    #expect(!controller.isCompletionVisible)
    _ = first

    // Without a menu, Tab and arrows fall through.
    #expect(controller.editor.onTab?() == false)
    #expect(controller.editor.onArrow?(1) == false)
}

@Test @MainActor func runButtonDoesWhatEnterDoesAndBareTextNeverSubmits() throws {
    let controller = OmniCommandPadViewController(parser: try padParser())
    controller.loadView()
    var submissions: [(String, OmniSubmitGesture)] = []
    controller.onSubmit = { submissions.append(($0, $1)) }
    let change = Notification(name: NSText.didChangeNotification)

    controller.editor.string = "just some text"
    controller.textDidChange(change)
    #expect(!controller.runButton.isEnabled)
    controller.editor.onSubmit?(.enterShowHere)
    #expect(submissions.isEmpty)
    #expect(controller.routeLine == .hint(OmniCommandPadViewController.addCommandHint))

    controller.editor.string = "/todo buy milk"
    controller.textDidChange(change)
    #expect(controller.runButton.isEnabled)
    controller.runButton.onPress?()
    #expect(submissions.count == 1)
    #expect(submissions.first?.0 == "/todo buy milk")
    #expect(submissions.first?.1 == .enterShowHere)
    controller.editor.onSubmit?(.commandEnterAttach)
    #expect(submissions.last?.1 == .commandEnterAttach)
}

@Test @MainActor func provenanceStripShowsSourceAndWordCountAndClearsThroughTheChip() throws {
    let controller = OmniCommandPadViewController(parser: try padParser())
    controller.loadView()
    #expect(controller.provenanceChip.isHidden)
    #expect(controller.wordCountLabel.isHidden)
    var cleared = 0
    controller.onClearProvenance = { cleared += 1 }

    controller.setProvenance(OmniPadProvenance(source: "Mail", detail: "Mira Chen", wordCount: 40))
    #expect(!controller.provenanceChip.isHidden)
    // D3: the chip reads like the workspace header, `From Mail “Mira Chen”`.
    #expect(controller.provenanceChip.provenance?.label == "From Mail “Mira Chen”")
    #expect(controller.wordCountLabel.stringValue == "40 words")
    #expect(controller.provenanceChip.accessibilityLabel()?.contains("From Mail “Mira Chen”") == true)
    controller.provenanceChip.performClick(nil)
    #expect(cleared == 1)

    controller.setProvenance(OmniPadProvenance(source: "Notes", wordCount: 1))
    #expect(controller.wordCountLabel.stringValue == "1 word")
    controller.setProvenance(nil)
    #expect(controller.provenanceChip.isHidden)
}

@Test func padPlacementSitsInTheUpperThirdCentred() {
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let frame = OmniPadPlacement.frame(size: NSSize(width: 640, height: 108), visibleFrame: visible)
    #expect(frame.width == 640)
    #expect(frame.midX == 720)
    #expect(frame.maxY == 900 - 900 * OmniPadPlacement.topFraction)
    let narrow = OmniPadPlacement.frame(size: NSSize(width: 640, height: 108), visibleFrame: NSRect(x: 0, y: 0, width: 400, height: 300))
    #expect(narrow.width == 376)
    #expect(narrow.minY >= 12)
}

@Test @MainActor func asyncRouteRefreshLeavesNoticesAndTheMenuAlone() throws {
    _ = NSApplication.shared
    let controller = OmniCommandPadViewController(parser: try padParser())
    controller.loadView()
    _ = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    let change = Notification(name: NSText.didChangeNotification)
    controller.editor.string = "/email accept /style:formal"
    controller.textDidChange(change)
    controller.showTransientNotice("Replaced your unsent draft · ⌘Z restores it")
    controller.refreshRoute()
    #expect(controller.routeLine == .notice("Replaced your unsent draft · ⌘Z restores it"))

    controller.editor.string = "/t"
    controller.editor.setSelectedRange(NSRange(location: 2, length: 0))
    controller.textDidChange(change)
    #expect(controller.isCompletionVisible)
    controller.dismissCompletion()
    controller.refreshRoute()
    #expect(!controller.isCompletionVisible)
    // With a menu up, Enter still runs and the button stays what it is (C22, C25).
    controller.textDidChange(change)
    #expect(controller.isCompletionVisible)
    #expect(controller.footerState.keyHints.contains(OmniPadKeyHint("↩", "Run")))
}

@Test @MainActor func completionWithoutAWindowNeverWedgesTheFooter() throws {
    let controller = OmniCommandPadViewController(parser: try padParser())
    controller.loadView()
    let change = Notification(name: NSText.didChangeNotification)
    controller.editor.string = "/t"
    controller.editor.setSelectedRange(NSRange(location: 2, length: 0))
    controller.textDidChange(change)
    #expect(!controller.isCompletionVisible)
    #expect(controller.editor.onEscapeMenu?() == false)
    #expect(controller.routeLine != .hint(OmniCommandPadViewController.typingHint))
}

@Test @MainActor func tabAndArrowsReachTheMenuThroughKeyDown() throws {
    _ = NSApplication.shared
    let controller = OmniCommandPadViewController(parser: try padParser())
    controller.loadView()
    _ = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    let change = Notification(name: NSText.didChangeNotification)
    controller.editor.string = "/t"
    controller.editor.setSelectedRange(NSRange(location: 2, length: 0))
    controller.textDidChange(change)
    #expect(controller.isCompletionVisible)
    func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    controller.editor.keyDown(with: key(125, ""))
    #expect(controller.completionIndex == 1)
    let expected = controller.completionChoices[1].canonicalText
    controller.editor.keyDown(with: key(48, "\t"))
    #expect(controller.editor.string == expected)
    #expect(!controller.isCompletionVisible)
    // Without a menu, the pad does not consume Tab.
    #expect(controller.editor.onTab?() == false)
}

@MainActor
private func descendant(_ id: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == id { return view }
    for child in view.subviews {
        if let match = descendant(id, in: child) { return match }
    }
    return nil
}

@MainActor
private func padKey(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code
    )!
}

@Test @MainActor func submittedRequestSurvivesDraftClearWithTokenAndAnnotationTints() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    let request = "/translate:de The annotated phrase\nA long second line that must be collapsed"
    let phrase = (request as NSString).range(of: "annotated phrase")
    let note = OmniTextAnnotation(range: phrase, guidance: "Keep this phrase")
    pad.editor.string = request
    pad.setAnnotations([note])
    pad.setProvenance(OmniPadProvenance(source: "Mail", wordCount: 7))

    pad.beginWorking(runID: "r1", requestText: request, annotations: [note])
    pad.editor.string = ""
    pad.clearAnnotations()
    pad.setProvenance(nil)

    #expect(pad.mode == .working(runID: "r1"))
    #expect(pad.submittedRequestText == request)
    #expect(pad.submittedRequestView.string.hasSuffix("…"))
    #expect(!pad.submittedRequestView.string.contains("second line"))
    #expect(!pad.submittedRequestView.isEditable)
    #expect(pad.submittedRequestView.annotations == [note])
    #expect(pad.submittedProvenance?.source == "Mail")
    #expect(!pad.provenanceChip.isHidden)
    #expect(pad.submittedRequestView.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
    #expect(pad.footerState.keyHints == OmniPadKeyHint.working)
}

@Test @MainActor func textAndConfirmationResultsRouteEnterToDifferentCallbacks() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    var copied: [String] = []
    var closed: [String] = []
    var opened: [String] = []
    pad.onCopyResult = { copied.append($0) }
    pad.onCloseResult = { closed.append($0) }
    pad.onOpenResult = { opened.append($0) }
    pad.beginWorking(runID: "text", requestText: "/translate:de garden hose")
    pad.editor.onSubmit?(.enterShowHere)
    #expect(copied.isEmpty && closed.isEmpty)
    pad.editor.onSubmit?(.commandEnterAttach)
    #expect(opened == ["text"])

    let full = String(repeating: "A long result that stays complete in the model. ", count: 80)
    pad.showResult(runID: "text", result: OmniPadResult(kind: .text, body: full, summary: "Translation · Cerebras"))
    #expect(pad.mode == .result(runID: "text"))
    #expect(pad.result?.body == full)
    #expect(pad.footerState.keyHints == OmniPadKeyHint.textResult)
    #expect(pad.resultScrollView?.frame.height == 240)
    #expect(descendant("omni.pad.result-fade", in: pad.view) != nil)
    #expect(pad.runButton.symbolName == "doc.on.doc")
    pad.resultTextView.setSelectedRange(NSRange(location: 2, length: 8))
    pad.showResult(runID: "text", result: OmniPadResult(kind: .text, body: full, summary: "Translation · Cerebras"))
    #expect(pad.resultTextView.selectedRange() == NSRange(location: 2, length: 8))
    pad.resultTextView.keyDown(with: padKey(36, flags: .command))
    #expect(opened == ["text", "text"])
    pad.resultTextView.keyDown(with: padKey(36))
    #expect(copied == ["text"])
    #expect(closed.isEmpty)

    pad.returnToComposing()
    pad.beginWorking(runID: "write", requestText: "/todo buy milk")
    pad.showResult(runID: "write", result: OmniPadResult(kind: .confirmation, body: "/todo · added to Ledger", summary: "Todo · Ledger"))
    #expect(pad.footerState.keyHints == OmniPadKeyHint.confirmationResult)
    pad.editor.onSubmit?(.enterShowHere)
    #expect(closed == ["write"])
    #expect(copied == ["text"])
}

@Test @MainActor func failureRetryIsAvailableOnlyWhenSuppliedByTheHost() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    var retries: [String] = []
    pad.onRetryResult = { retries.append($0) }
    pad.beginWorking(runID: "failed", requestText: "/email reply")
    pad.showResult(runID: "failed", result: OmniPadResult(kind: .failure(retryAllowed: false), body: "Route unavailable", summary: "Could not finish"))
    let retry = try #require(descendant("omni.pad.retry", in: pad.view) as? OmniPadInlineButton)
    #expect(retry.isHidden)
    #expect(pad.resultTextView.textColor == OmniFrostedStyle.warning)
    pad.editor.onSubmit?(.enterShowHere)
    #expect(retries.isEmpty)

    pad.returnToComposing()
    pad.beginWorking(runID: "retryable", requestText: "/translate:de hello")
    pad.showResult(runID: "retryable", result: OmniPadResult(kind: .failure(retryAllowed: true), body: "Timed out", summary: "Could not finish"))
    #expect(!retry.isHidden)
    retry.onPress?()
    #expect(retries == ["retryable"])
}

@Test @MainActor func proposalChooserIsAResultAndEnterConfirmsSelectedAlternative() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try padParser())
    pad.loadView()
    var confirmed: [(String, String)] = []
    pad.onConfirmProposal = { confirmed.append(($0, $1)) }
    pad.beginWorking(runID: "proposal", requestText: "summarise and search")
    pad.showProposalChooser(runID: "proposal", alternatives: [
        OmniPadAlternative(id: "one", planHash: "h1", title: "Summarise", steps: ["/qq summarise"]),
        OmniPadAlternative(id: "two", planHash: "h2", title: "Search", steps: ["/g search"]),
    ])
    #expect(pad.mode == .result(runID: "proposal"))
    #expect(pad.result?.kind == .proposal)
    pad.submittedRequestView.keyDown(with: padKey(19))
    #expect(pad.chosenIndex == 1)
    pad.submittedRequestView.keyDown(with: padKey(36))
    #expect(confirmed.count == 1)
    #expect(confirmed.first?.0 == "proposal")
    #expect(confirmed.first?.1 == "h2")
}

// MARK: Slash palette (C78)

/// The pad from a 1440×900 visible frame (top edge at 720). The screen top is
/// pinned so the tests do not depend on the host display: `.infinity` for the
/// full eight rows, or a real value to exercise the room above the pad.
@MainActor private func paletteController(screenTop: CGFloat = .infinity) throws -> OmniCommandPadViewController {
    _ = NSApplication.shared
    let controller = OmniCommandPadViewController(parser: try padParser())
    controller.loadView()
    _ = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    controller.completionScreenTop = screenTop
    return controller
}

@MainActor private func type(_ text: String, into controller: OmniCommandPadViewController) {
    controller.editor.string = text
    controller.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    controller.textDidChange(Notification(name: NSText.didChangeNotification))
}

@Test @MainActor func bareSlashListsEveryCommandButTheAliasesWithHelp() throws {
    let controller = try paletteController()
    type("/", into: controller)
    #expect(controller.isCompletionVisible)
    let expected = (controller.parser.manifest.commands.filter { $0.role != .alias }.map(\.token)
        + [OmniPronunciationRoute.token, OmniRecallRoute.token, OmniRatioRoute.token, OmniExpressRoute.token, OmniMapRoute.token, OmniCharactersRoute.token, OmniWeatherRoute.token, OmniQRRoute.token, OmniRegexRoute.token, "/calc"]
        + OmniClipboardRoute.tokens).sorted()
    #expect(controller.completionChoices.map(\.canonicalText) == expected)
    #expect(!controller.completionChoices.contains { $0.canonicalText == "/formal" || $0.canonicalText == "/retrieve" })
    #expect(controller.completionIndex == 0)
    for item in controller.completionItems {
        #expect(!item.choice.label.isEmpty, "\(item.choice.canonicalText) has no description")
        #expect(!item.help.body.isEmpty, "\(item.choice.canonicalText) has no help")
        #expect(!item.help.kind.isEmpty, "\(item.choice.canonicalText) has no kind")
    }
    // Argument shapes come from the manifest, not from prose.
    let translate = try #require(controller.completionItems.first { $0.choice.canonicalText == "/translate" })
    #expect(translate.help.usage == ["/translate:<lang> (optional)", "de · en · en-GB · en-US"])
    #expect(translate.help.kind == "Command · runs a model, or local with /offline")
    let email = try #require(controller.completionItems.first { $0.choice.canonicalText == "/email" })
    #expect(email.help.usage == ["With /style:formal"])
    let style = try #require(controller.completionItems.first { $0.choice.canonicalText == "/style" })
    #expect(style.help.usage == ["/style:<style>", "formal"])
    #expect(style.role == .modifier)
    // /g refuses /offline and is not "local": it opens the browser.
    let search = try #require(controller.completionItems.first { $0.choice.canonicalText == "/g" })
    #expect(search.help.usage.isEmpty)
    #expect(search.help.kind == "Command · opens your browser")
    let todo = try #require(controller.completionItems.first { $0.choice.canonicalText == "/todo" })
    #expect(todo.help.usage.isEmpty)
    #expect(todo.help.kind == "Command · runs locally")
    let menu = try #require(controller.completionMenu)
    #expect(!menu.canBecomeKey)
    // Nothing submits on a bare slash, so the hints promise no run (C25 untouched).
    #expect(controller.routeLine == .hint(OmniCommandPadViewController.typingHint))
    #expect(controller.footerState.keyHints == OmniPadKeyHint.completionBrowse)
    #expect(!controller.footerState.submits)
    // And Enter over it reaches no submit handler.
    var submissions = 0
    controller.onSubmit = { _, _ in submissions += 1 }
    controller.submit(.enterShowHere)
    #expect(submissions == 0)
}

@Test @MainActor func pronunciationRouteRequiresALeadingStandaloneTokenAndKeepsTheTermLiteral() {
    #expect(OmniPronunciationRoute.term(in: "/pron") == "")
    #expect(OmniPronunciationRoute.term(in: "  /pron \tFingerspitzengefühl  ") == "Fingerspitzengefühl")
    #expect(OmniPronunciationRoute.term(in: "/pron  /g  literal") == "/g  literal")
    #expect(OmniPronunciationRoute.term(in: "/pronounce word") == nil)
    #expect(OmniPronunciationRoute.term(in: "/pron:word") == nil)
    #expect(OmniPronunciationRoute.term(in: "/PRON word") == nil)
    #expect(OmniPronunciationRoute.term(in: "please /pron word") == nil)
}

@Test @MainActor func expressRouteIsLeadingAndItsTailIsLiteral() {
    #expect(OmniExpressRoute.text(in: "/express") == "")
    #expect(OmniExpressRoute.text(in: "  /express  Guten Morgen /g @work ✓  ") == "Guten Morgen /g @work ✓")
    #expect(OmniExpressRoute.text(in: "/expressive words") == nil)
    #expect(OmniExpressRoute.text(in: "/express:words") == nil)
    #expect(OmniExpressRoute.text(in: "please /express words") == nil)
}

@Test @MainActor func expressPadRouteOpensOnceWithoutDurableSubmission() throws {
    let controller = try paletteController()
    var texts: [String] = []
    var submissions = 0
    var modelResolutions = 0
    controller.onExpressRequested = { texts.append($0) }
    controller.onSubmit = { _, _ in submissions += 1 }
    controller.onResolveRoute = { _, _ in
        modelResolutions += 1
        return OmniPadRoute(providerName: "Cerebras")
    }
    type("/ex", into: controller)
    #expect(controller.completionItems.contains { $0.choice.canonicalText == "/express" })
    type("/express /g literal", into: controller)
    #expect(!controller.isCompletionVisible)
    #expect(controller.routeLine == .outcome("Express · opens native panel"))
    #expect(controller.runButton.accessibilityLabel() == "Open Express panel")
    #expect(controller.modelPopUp.isHidden)
    #expect(modelResolutions == 0)
    controller.editor.onSubmit?(.enterShowHere)
    controller.editor.onSubmit?(.enterShowHere)
    #expect(texts == ["/g literal"])
    #expect(submissions == 0)
    #expect(modelResolutions == 0)
}

@Test @MainActor func pronunciationCompletionAndFooterShowTheLocalPanelRoute() throws {
    let controller = try paletteController()
    type("/pr", into: controller)
    let choice = try #require(controller.completionItems.first { $0.choice.canonicalText == "/pron" })
    #expect(choice.choice.label == "Pronounce a word or phrase")
    #expect(choice.help.kind == "Tool · opens native panel")
    #expect(!choice.help.body.contains("Cerebras"))
    #expect(choice.help.body.contains("No durable command run is created"))
    type("/pron /g literal", into: controller)
    #expect(!controller.isCompletionVisible)
    #expect(controller.routeLine == .outcome("Pronunciation · opens native panel"))
    #expect(controller.footerState.keyHints == OmniPadKeyHint.pronunciation)
    #expect(controller.runButton.isEnabled)
    #expect(controller.runButton.accessibilityLabel() == "Open pronunciation panel")
    let termPosition = (controller.editor.string as NSString).range(of: "/g").location
    #expect(controller.editor.textStorage?.attribute(.underlineStyle, at: termPosition, effectiveRange: nil) == nil)
    #expect(controller.editor.textStorage?.attribute(.backgroundColor, at: termPosition, effectiveRange: nil) == nil)
}

@Test @MainActor func pronunciationEnterOpensOnceWithoutDurableOrModelDispatch() throws {
    let controller = try paletteController()
    var terms: [String] = []
    var durableSubmissions = 0
    var modelResolutions = 0
    controller.onPronunciationRequested = { terms.append($0) }
    controller.onSubmit = { _, _ in durableSubmissions += 1 }
    controller.onResolveRoute = { _, _ in
        modelResolutions += 1
        return OmniPadRoute(providerName: "Cerebras")
    }

    type("/pr", into: controller)
    #expect(terms.isEmpty)
    #expect(modelResolutions == 0)
    type("/pron /g literal", into: controller)
    #expect(terms.isEmpty)
    #expect(modelResolutions == 0)
    controller.editor.onSubmit?(.enterShowHere)
    controller.editor.onSubmit?(.enterShowHere)
    #expect(terms == ["/g literal"])
    #expect(durableSubmissions == 0)
    #expect(modelResolutions == 0)

    type("/pron", into: controller)
    controller.runButton.onPress?()
    #expect(terms == ["/g literal", ""])
    #expect(durableSubmissions == 0)
}

@Test @MainActor func paletteFiltersLiveRestoresOnBackspaceAndClosesWithoutTheSlash() throws {
    let controller = try paletteController()
    type("/", into: controller)
    let all = controller.completionChoices.count
    #expect(all > OmniCompletionMenu.visibleRows)
    #expect(controller.moveCompletion(by: 3) == true)
    #expect(controller.completionIndex == 3)
    // A changed set puts the highlight back on the first row.
    type("/e", into: controller)
    #expect(controller.completionChoices.map(\.canonicalText) == ["/email", "/expand", "/express"])
    #expect(controller.completionIndex == 0)
    // A typed-out valued token still lists its members, as before.
    type("/style", into: controller)
    #expect(controller.completionChoices.map(\.canonicalText) == ["/style:formal"])
    // Never the alias /retrieve, even when the prefix matches it.
    type("/re", into: controller)
    #expect(controller.completionChoices.map(\.canonicalText) == ["/recall", "/regex", "/remind"])
    #expect(controller.moveCompletion(by: 1) == true)
    type("/", into: controller)
    #expect(controller.completionChoices.count == all)
    #expect(controller.completionIndex == 0)
    type("", into: controller)
    #expect(!controller.isCompletionVisible)
    #expect(controller.completionMenu == nil)
    // A valued token lists its registry members with what each means.
    type("/expand:", into: controller)
    #expect(controller.completionChoices.map(\.canonicalText) == ["/expand:deepen", "/expand:broaden", "/expand:concretise", "/expand:challenge", "/expand:connect"])
    #expect(controller.completionItems[0].choice.label == "Go further into the idea itself")
    #expect(controller.completionItems[0].help.body == "Go further into the idea itself")
    type("/expand:c", into: controller)
    #expect(controller.completionChoices.map(\.canonicalText) == ["/expand:concretise", "/expand:challenge", "/expand:connect"])
}

@Test @MainActor func paletteListScrollsTheHighlightIntoViewAndTheHelpFollows() throws {
    let controller = try paletteController()
    type("/", into: controller)
    let menu = try #require(controller.completionMenu)
    let count = controller.completionChoices.count
    #expect(menu.visibleRowCount == OmniCompletionMenu.visibleRows)
    #expect(count > menu.visibleRowCount)
    #expect(menu.listScrollView.frame.height == CGFloat(OmniCompletionMenu.visibleRows) * OmniCompletionMenu.rowHeight)
    #expect(menu.frame.width == OmniCompletionMenu.listWidth + OmniCompletionMenu.helpWidth)
    #expect(menu.frame.height >= CGFloat(OmniCompletionMenu.visibleRows) * OmniCompletionMenu.rowHeight)
    #expect(menu.helpView.item?.help.token == controller.completionChoices[0].canonicalText)
    func rowIsVisible(_ index: Int) -> Bool {
        let row = NSRect(x: 0, y: OmniCompletionMenu.rowHeight * CGFloat(index), width: 1, height: OmniCompletionMenu.rowHeight)
        return menu.listScrollView.documentVisibleRect.contains(row)
    }
    #expect(rowIsVisible(0))
    #expect(!rowIsVisible(count - 1))
    // Up from the top wraps to the last row and scrolls it into view.
    #expect(controller.moveCompletion(by: -1) == true)
    #expect(controller.completionIndex == count - 1)
    #expect(menu.highlighted == count - 1)
    #expect(rowIsVisible(count - 1))
    #expect(!rowIsVisible(0))
    #expect(menu.helpView.item?.help.token == controller.completionChoices[count - 1].canonicalText)
    #expect(controller.moveCompletion(by: 1) == true)
    #expect(controller.completionIndex == 0)
    #expect(rowIsVisible(0))
    // The column's prose sizes the panel; every item fits the tallest one.
    let tallest = controller.completionItems.map { OmniCompletionHelpView.fittingHeight(for: $0, width: OmniCompletionMenu.helpWidth) }.max() ?? 0
    #expect(menu.frame.height >= tallest)
}

@Test @MainActor func hoverMovesTheHighlightWithoutScrollingAndTabTakesIt() throws {
    let controller = try paletteController()
    type("/", into: controller)
    let menu = try #require(controller.completionMenu)
    let before = menu.listScrollView.documentVisibleRect
    menu.onHover?(3)
    #expect(controller.completionIndex == 3)
    #expect(menu.highlighted == 3)
    #expect(menu.helpView.item?.help.token == controller.completionChoices[3].canonicalText)
    #expect(menu.listScrollView.documentVisibleRect == before)
    // Hovering the highlighted row again is a no-op; an out-of-range index is ignored.
    menu.onHover?(3)
    menu.onHover?(99)
    #expect(controller.completionIndex == 3)
    let expected = controller.completionChoices[3].canonicalText
    #expect(controller.editor.onTab?() == true)
    #expect(controller.editor.string == expected)
    #expect(!controller.isCompletionVisible)
    // A click on a row accepts that row.
    type("/", into: controller)
    let clicked = controller.completionChoices[1].canonicalText
    try #require(controller.completionMenu).onChoose?(1)
    #expect(controller.editor.string == clicked)
    #expect(!controller.isCompletionVisible)
}

@Test @MainActor func paletteUsageLinesFollowTheManifestValueTypes() throws {
    let parser = try padParser()
    let manifest = parser.manifest
    let shorter = try #require(manifest.command(for: "/shorter"))
    #expect(OmniPadVocabulary.usage(for: shorter, valueTypes: manifest.valueTypes) == ["/shorter:<length> (optional)", "25% · 120w · 3s"])
    let expand = try #require(manifest.command(for: "/expand"))
    #expect(OmniPadVocabulary.usage(for: expand, valueTypes: manifest.valueTypes) == ["/expand:<lens> (optional)", "deepen · broaden · concretise · challenge · connect"])
    #expect(OmniPadVocabulary.usage(for: try #require(manifest.command(for: "/g")), valueTypes: manifest.valueTypes).isEmpty)
    #expect(OmniPadVocabulary.kind(for: shorter) == "Command · follow-up")
    let offline = try #require(manifest.command(for: "/offline"))
    #expect(OmniPadVocabulary.usage(for: offline, valueTypes: manifest.valueTypes).isEmpty)
    #expect(OmniPadVocabulary.kind(for: offline) == "Mode · this run only")
    let todo = try #require(manifest.command(for: "/todo"))
    #expect(OmniPadVocabulary.kind(for: todo) == "Command · runs locally")
    #expect(OmniPadVocabulary.kind(for: try #require(manifest.command(for: "/qq"))) == "Command · runs a model, or local with /offline")
    #expect(OmniPadVocabulary.kind(for: try #require(manifest.command(for: "/g"))) == "Command · opens your browser")
    #expect(OmniPadVocabulary.kind(for: try #require(manifest.command(for: "/model"))) == "Settings")
    // Every non-alias command has prose; the switch has no silent default in practice.
    for command in manifest.commands where command.role != .alias {
        #expect(!OmniPadVocabulary.help(for: command.token).isEmpty, "\(command.token) has no help")
    }
}

/// Receipts of the palette for the run folder when `OMNI_CAPTURE_DIR` is set.
@Test @MainActor func paletteCaptures() throws {
    let controller = try paletteController()
    type("/", into: controller)
    let items = controller.completionItems
    let roomy = OmniCompletionMenu(items: items, highlighted: 0, room: 600)
    roomy.highlight(2, scrollingIntoView: false)
    let bare = try #require(roomy.contentView)
    try polishCapture(bare, name: "palette-bare-slash-light", appearance: .aqua)
    try polishCapture(bare, name: "palette-bare-slash-dark", appearance: .darkAqua)
    roomy.highlight(items.count - 1)
    try polishCapture(bare, name: "palette-bare-slash-scrolled-light", appearance: .aqua)
    let laptop = try paletteController(screenTop: 900)
    type("/", into: laptop)
    let live = try #require(laptop.completionMenu?.contentView)
    try polishCapture(live, name: "palette-live-900pt-light", appearance: .aqua)
    type("/expand:", into: controller)
    let members = try #require(controller.completionMenu?.contentView)
    try polishCapture(members, name: "palette-expand-members-light", appearance: .aqua)
    type("/tr", into: controller)
    let single = try #require(controller.completionMenu?.contentView)
    try polishCapture(single, name: "palette-single-row-dark", appearance: .darkAqua)
}

@Test @MainActor func paletteNeverOpensBehindATrailingSpaceSoTheOfferRowStaysHonest() throws {
    let controller = try paletteController()
    // Material with a slash left behind a space: the slash is text again (C77),
    // the offer row shows, and no palette hides it.
    type("Can we move the call to Friday?\nI have a clash on Thursday.\n/ ", into: controller)
    #expect(!controller.isCompletionVisible)
    #expect(controller.isOfferRowVisible)
    // The same material with the slash under the caret: palette up, offer row
    // down, and the footer promises no run because nothing submits.
    type("Can we move the call to Friday?\nI have a clash on Thursday.\n/", into: controller)
    #expect(controller.isCompletionVisible)
    #expect(!controller.isOfferRowVisible)
    #expect(!controller.footerState.submits)
    #expect(controller.footerState.keyHints == OmniPadKeyHint.completionBrowse)
    var submissions = 0
    controller.onSubmit = { _, _ in submissions += 1 }
    controller.submit(.enterShowHere)
    #expect(submissions == 0)
}

@Test @MainActor func paletteFitsTheRoomAboveThePadOrMovesBelowIt() throws {
    let controller = try paletteController()
    type("/", into: controller)
    let items = controller.completionItems
    let tallestHelp = OmniCompletionMenu.minimumHeight(for: items)
    let heightDetails = items.map { "\($0.choice.canonicalText):\(OmniCompletionMenu.minimumHeight(for: [$0]))" }.joined(separator: ", ")
    // A 13-inch Air with the menu bar and a visible Dock keeps about 810 pt
    // of visible frame; the pad in its upper third leaves 154 pt above it.
    #expect(tallestHelp <= 154, "the tallest help column (\(tallestHelp) pt) must fit 154 pt: \(heightDetails)")
    let pad = NSRect(x: 400, y: 612, width: 640, height: 108)
    let fitted = OmniCompletionMenu(items: items, highlighted: 0, room: 154)
    #expect(fitted.visibleRowCount == 4)
    #expect(fitted.listScrollView.frame.height == 4 * OmniCompletionMenu.rowHeight)
    fitted.present(above: pad, caretX: 420, screenTop: pad.maxY + OmniCompletionMenu.gap + 154)
    #expect(!fitted.isBelowPad)
    #expect(fitted.frame.maxY <= pad.maxY + OmniCompletionMenu.gap + 154)
    #expect(fitted.frame.minY == pad.maxY + OmniCompletionMenu.gap)
    // No limit, a huge finite value, or the default: the full eight, never a crash.
    #expect(OmniCompletionMenu(items: items, highlighted: 0, room: .infinity).visibleRowCount == OmniCompletionMenu.visibleRows)
    #expect(OmniCompletionMenu(items: items, highlighted: 0, room: .greatestFiniteMagnitude).visibleRowCount == OmniCompletionMenu.visibleRows)
    #expect(OmniCompletionMenu(items: items, highlighted: 0).visibleRowCount == OmniCompletionMenu.visibleRows)
    #expect(OmniCompletionMenu(items: items, highlighted: 0, room: -50).visibleRowCount == 1)
    #expect(OmniCompletionMenu(items: items, highlighted: 0, room: -.infinity).visibleRowCount == 1)
    #expect(OmniCompletionMenu(items: items, highlighted: 0, room: .nan).visibleRowCount == OmniCompletionMenu.visibleRows)
    // Not even the help column fits above: below the pad, with the full list.
    let cramped = OmniCompletionMenu(items: items, highlighted: 0, room: .infinity)
    cramped.present(above: pad, caretX: 420, screenTop: pad.maxY + 40)
    #expect(cramped.isBelowPad)
    #expect(cramped.frame.maxY == pad.minY - OmniCompletionMenu.gap)
    #expect(cramped.visibleRowCount == OmniCompletionMenu.visibleRows)
    // The live path on a 900 pt visible frame: five rows, above the pad.
    let laptop = try paletteController(screenTop: 900)
    type("/", into: laptop)
    let live = try #require(laptop.completionMenu)
    #expect(live.visibleRowCount == 5)
    #expect(!live.isBelowPad)
    #expect(live.frame.maxY <= 900)
    // The live path when the help cannot fit: eight rows below the pad.
    let tiny = try paletteController(screenTop: 720 + OmniCompletionMenu.gap + 60)
    type("/", into: tiny)
    let below = try #require(tiny.completionMenu)
    #expect(below.isBelowPad)
    #expect(below.visibleRowCount == OmniCompletionMenu.visibleRows)
    #expect(below.frame.maxY <= tiny.view.window!.frame.minY - OmniCompletionMenu.gap)
}

@Test @MainActor func hoverIgnoresTheSameSpotAfterScrollingAndFollowsRealMovement() throws {
    let controller = try paletteController()
    type("/", into: controller)
    let menu = try #require(controller.completionMenu)
    let list = try #require(menu.listScrollView.documentView as? OmniCompletionListView)
    list.lastPointer = NSPoint(x: -5000, y: -5000)
    func move(to windowPoint: NSPoint) {
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: menu.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        list.mouseMoved(with: event)
    }
    // The pointer arrives over row 2.
    let spot = list.convert(NSPoint(x: 40, y: 2 * OmniCompletionMenu.rowHeight + 15), to: nil)
    move(to: spot)
    #expect(controller.completionIndex == 2)
    // The keyboard scrolls the list to the last row; the resting pointer, now
    // over some other row, must not take the highlight back.
    #expect(controller.moveCompletion(by: -3) == true)
    let last = controller.completionChoices.count - 1
    #expect(controller.completionIndex == last)
    move(to: spot)
    #expect(controller.completionIndex == last)
    // Real movement names the row now under the pointer, without scrolling.
    let visible = menu.listScrollView.documentVisibleRect
    let moved = NSPoint(x: spot.x + 6, y: spot.y)
    move(to: moved)
    let expected = Int(list.convert(moved, from: nil).y / OmniCompletionMenu.rowHeight)
    #expect(controller.completionIndex == expected)
    #expect(expected != last)
    #expect(menu.listScrollView.documentVisibleRect == visible)
}
