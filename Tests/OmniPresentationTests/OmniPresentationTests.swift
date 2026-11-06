import AppKit
import Foundation
import HyperOverlayRuntime
import OmniCore
import OmniPresentation
import Testing

@MainActor
private func parser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    let references = try ReferenceRegistry([
        PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)
    ])
    return OmniParser(manifest: manifest, references: references)
}

@MainActor
private func coordinator() -> OmniForegroundCoordinator {
    OmniForegroundCoordinator(
        runtime: ForegroundArbitrator(allowedOverlays: ["legacy", "omni-editing", "omni-attached"])
    )
}

@Test @MainActor func foregroundReplacementNeverCancelsOrRekeysRun() {
    let coordinator = coordinator()
    coordinator.showOmni()
    coordinator.submit(runID: "oi_00000000000000000000000001", gesture: .commandEnterAttach)
    let attached = coordinator.snapshot()
    coordinator.showLegacy()
    let replaced = coordinator.snapshot()

    #expect(attached.foreground == .attached(runID: "oi_00000000000000000000000001"))
    #expect(replaced.foreground == .legacy)
    #expect(replaced.detachedRunIDs == ["oi_00000000000000000000000001"])
    #expect(replaced.uiGeneration > attached.uiGeneration)
}

@Test @MainActor func fullFrozenForegroundTableIsSerialized() {
    let editing = coordinator()
    editing.showOmni()
    editing.showLegacy()
    #expect(editing.snapshot().foreground == .legacy)
    #expect(editing.snapshot().detachedRunIDs.isEmpty)

    let attached = coordinator()
    attached.showOmni()
    attached.submit(runID: "oi_00000000000000000000000002", gesture: .commandEnterAttach)
    attached.showLegacy()
    #expect(attached.snapshot().foreground == .legacy)
    #expect(attached.snapshot().detachedRunIDs == ["oi_00000000000000000000000002"])

    let pad = coordinator()
    pad.showOmni()
    pad.submit(runID: "oi_00000000000000000000000003", gesture: .enterShowHere)
    #expect(pad.snapshot().foreground == .editing)
    #expect(pad.snapshot().detachedRunIDs.isEmpty)
    pad.detachPadRun("oi_00000000000000000000000003")
    pad.showLegacy()
    #expect(pad.snapshot().detachedRunIDs == ["oi_00000000000000000000000003"])

    let replacement = coordinator()
    replacement.showLegacy()
    replacement.showOmni()
    #expect(replacement.snapshot().foreground == .editing)

    let idempotent = coordinator()
    idempotent.showOmni()
    let before = idempotent.snapshot()
    idempotent.showOmni()
    #expect(idempotent.snapshot() == before)
}

@Test @MainActor func enterVersusLegacyRacePreservesRunWithoutStaleFocusMutation() {
    let coordinator = coordinator()
    coordinator.showOmni()
    let padGeneration = coordinator.snapshot().uiGeneration
    coordinator.showLegacy()
    let accepted = coordinator.submit(
        runID: "oi_00000000000000000000000004",
        gesture: .commandEnterAttach,
        expectedGeneration: padGeneration
    )
    #expect(!accepted)
    #expect(coordinator.snapshot().foreground == .legacy)
    #expect(coordinator.snapshot().detachedRunIDs.isEmpty, "Cmd+Enter never creates a notification debt")
}

@Test @MainActor func escapeBeforeSubmissionCreatesNoRunProjection() {
    let coordinator = coordinator()
    coordinator.showOmni()
    coordinator.closeBeforeSubmission()
    #expect(coordinator.snapshot().foreground == .hidden)
    #expect(coordinator.snapshot().detachedRunIDs.isEmpty)
}

@Test(arguments: [false, true], [false, true]) @MainActor
func staleOmniCloseCannotReleaseANewerForegroundOwner(attached: Bool, sameOverlay: Bool) {
    let runtime = ForegroundArbitrator(allowedOverlays: ["legacy", "omni-editing", "omni-attached"])
    let coordinator = OmniForegroundCoordinator(runtime: runtime)
    let runID = "oi_00000000000000000000000005"
    coordinator.showOmni()
    if attached { coordinator.submit(runID: runID, gesture: .commandEnterAttach) }
    let replacement = sameOverlay ? (attached ? "omni-attached" : "omni-editing") : "legacy"
    _ = runtime.close()
    _ = runtime.show(replacement)
    let replacementGeneration = runtime.generation

    if attached { coordinator.detachAttachedResult() }
    else { coordinator.closeBeforeSubmission() }

    #expect(runtime.activeOverlay == replacement)
    #expect(runtime.generation == replacementGeneration)
    #expect(coordinator.snapshot().foreground == .hidden)
    #expect(coordinator.snapshot().detachedRunIDs == (attached ? [runID] : []))
}

@Test @MainActor func foregroundClaimsRecoverAfterExternalReplacementAndNeverToggleAttachedRuns() {
    let runtime = ForegroundArbitrator(allowedOverlays: ["legacy", "omni-editing", "omni-attached"])
    let coordinator = OmniForegroundCoordinator(runtime: runtime)
    coordinator.showOmni()
    _ = runtime.show("legacy")
    coordinator.showOmni()
    #expect(runtime.activeOverlay == "omni-editing")

    coordinator.submit(runID: "oi_00000000000000000000000006", gesture: .commandEnterAttach)
    coordinator.submit(runID: "oi_00000000000000000000000007", gesture: .commandEnterAttach)
    #expect(runtime.activeOverlay == "omni-attached")
    #expect(coordinator.snapshot().foreground == .attached(runID: "oi_00000000000000000000000007"))

    coordinator.showLegacy()
    _ = runtime.show("omni-editing")
    coordinator.showLegacy()
    #expect(runtime.activeOverlay == "legacy")
}

@Test @MainActor func commandPadIsTheOnlyKeyCapableSurfaceAndShowsDevelopmentIndicator() throws {
    let controller = OmniCommandPadViewController(parser: try parser())
    controller.loadView()
    let pad = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))

    #expect(pad.canBecomeKey)
    #expect(controller.developmentLabel.stringValue.contains("PURE FAKE"))
    #expect(controller.editor.accessibilityIdentifier() == "omni.command-editor")
}

@Test @MainActor func visibleInsertionAndAliasRewriteRemainEditorTruth() throws {
    let controller = OmniCommandPadViewController(parser: try parser())
    controller.loadView()
    controller.editor.string = "/email /formal hello"
    controller.applyVisibleRewrite(VisibleRewrite(from: "/formal", to: "/style:formal"))
    controller.insertVisibleText(" @zoe")

    #expect(controller.editor.string.contains("/style:formal"))
    #expect(controller.editor.string.contains("@zoe"))
}

@Test @MainActor func nativeCaptureScenariosHaveStableDistinctIdentifiers() {
    #expect(Set(OmniNativeCaptureScenario.allCases.map(\.accessibilityIdentifier)).count == OmniNativeCaptureScenario.allCases.count)
    #expect(OmniNativeCaptureScenario.constrainedScreen.accessibilityIdentifier == "omni.capture.constrainedScreen")
}

@Test @MainActor func longEditorKeepsFooterAndDevelopmentIndicatorOutsideScrollableText() throws {
    let controller = OmniCommandPadViewController(parser: try parser())
    controller.loadView()
    controller.editor.string = String(repeating: "A paragraph that should wrap in the bounded command editor. ", count: 40)
    controller.textDidChange(Notification(name: NSText.didChangeNotification))
    let scroll = try #require(controller.editorScrollView)

    // Three strips (C19): the field scrolls between the top edge and the footer.
    #expect(scroll.frame.maxY <= controller.view.bounds.height - 12)
    #expect(controller.statusLabel.frame.maxY <= scroll.frame.minY)
    #expect(controller.runButton.frame.maxY <= scroll.frame.minY)
    #expect(scroll.frame.height <= 210)
}

@Test @MainActor func narrowFactoryUsesConstrainedWidthAndNativeCaptureIsRenderable() throws {
    let controller = OmniCommandPadViewController(parser: try parser())
    controller.loadView()
    let panel = OmniPanelFactory.makePad(
        controller: controller,
        visibleFrame: NSRect(x: 0, y: 0, width: 340, height: 500)
    )
    OmniNativeCaptureHarness.prepare(
        controller.view,
        scenario: .constrainedScreen,
        treatment: .opaqueFallback,
        appearance: .darkAqua
    )

    #expect(panel.frame.width >= 320)
    #expect(OmniNativeCaptureHarness.image(of: controller.view).size.width > 0)
}

@Test @MainActor func frostedTokensDistinguishModifierAliasesAndFollowUpScope() throws {
    let parser = try parser()
    let alias = OmniTokenRenderer.attributedText("/formal accepted", parser: parser)
    #expect(alias.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == OmniFrostedStyle.aliasExpanded)
    let followUp = OmniTokenRenderer.attributedText("/shorter accepted", parser: parser, fontSize: 18, followUp: true)
    #expect(followUp.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor == OmniFrostedStyle.accentTokenFill)
    let fresh = OmniTokenRenderer.attributedText("/shorter accepted", parser: parser)
    #expect(fresh.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor == OmniFrostedStyle.accentTokenFill)
    let valued = OmniTokenRenderer.attributedText("/shorter:25% keep", parser: parser)
    let colon = (valued.string as NSString).range(of: ":")
    #expect(valued.attribute(.foregroundColor, at: colon.location, effectiveRange: nil) as? NSColor == OmniFrostedStyle.tokenValue)
    let unknown = OmniTokenRenderer.attributedText("/save accepted", parser: parser)
    #expect(unknown.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    let casual = OmniTokenRenderer.attributedText("/style:casual hello", parser: parser)
    #expect(casual.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    #expect(casual.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == OmniFrostedStyle.unresolved)
    let bareStyle = OmniTokenRenderer.attributedText("/style hello", parser: parser)
    #expect(bareStyle.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    #expect(followUp.string == "/shorter accepted")
    let pathProse = OmniTokenRenderer.attributedText("Read /usr/bin docs /formal", parser: parser, followUp: true)
    #expect(pathProse.attribute(.underlineStyle, at: 5, effectiveRange: nil) == nil)
    #expect(pathProse.attribute(.backgroundColor, at: 5, effectiveRange: nil) == nil)
    #expect(pathProse.string == "Read /usr/bin docs /formal")
    let invalidLength = OmniTokenRenderer.attributedText("/shorter:nope keep", parser: parser, followUp: true)
    #expect(invalidLength.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    let unexpectedFormal = OmniTokenRenderer.attributedText("/formal:nope keep", parser: parser, followUp: true)
    #expect(unexpectedFormal.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    #expect(unexpectedFormal.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != OmniFrostedStyle.aliasExpanded)
    let unexpectedTime = OmniTokenRenderer.attributedText("/remind:15:00 buy milk", parser: parser)
    #expect(unexpectedTime.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    let timeColon = (unexpectedTime.string as NSString).range(of: ":")
    #expect(unexpectedTime.attribute(.foregroundColor, at: timeColon.location, effectiveRange: nil) as? NSColor != OmniFrostedStyle.tokenValue)
}

@Test @MainActor func commandPadLiveRewritesAndDiagnosticsFollowTheTokenGrammar() throws {
    let controller = OmniCommandPadViewController(parser: try parser())
    controller.loadView()
    let change = Notification(name: NSText.didChangeNotification)

    controller.editor.string = "/email /formal x"
    controller.textDidChange(change)
    #expect(controller.editor.string.contains("/style:formal"))
    #expect(!controller.editor.string.contains("/formal"))

    controller.editor.string = "/email @zoe x"
    controller.textDidChange(change)
    #expect(controller.editor.string.contains("@zoe"))
    #expect(!controller.editor.string.contains("@people:zoe"))

    controller.editor.string = "/shorter:0.25"
    controller.textDidChange(change)
    #expect(controller.editor.string.contains("/shorter:0.25"))
    #expect(!controller.editor.string.contains("/shorter:25%"))

    controller.editor.string = "/shorter:0.25 "
    controller.textDidChange(change)
    #expect(controller.editor.string.contains("/shorter:25%"))

    controller.editor.string = "/retrieve /formal hello"
    controller.textDidChange(change)
    #expect(controller.editor.string.contains("/find"))
    #expect(controller.editor.string.contains("/style:formal"))
    #expect(!controller.editor.string.contains("/retrieve"))
    #expect(!controller.editor.string.contains("/formal"))

    controller.editor.string = "See https://example.com/shorter:0.25 docs /shorter:0.25 "
    controller.textDidChange(change)
    #expect(controller.editor.string.contains("https://example.com/shorter:0.25"))
    #expect(controller.editor.string.contains("/shorter:25%"))

    controller.editor.string = "/shorter:1 /shorter:10 "
    controller.textDidChange(change)
    #expect(controller.editor.string.contains("/shorter:1%"))
    #expect(controller.editor.string.contains("/shorter:10%"))

    // Grammar escalations read as proposals in the route line (C26), not tiers.
    controller.editor.string = "/email /style:casual x"
    controller.textDidChange(change)
    #expect(controller.statusLabel.stringValue.contains("invalid value"))
    #expect(controller.statusLabel.stringValue.contains("asks for a proposal"))
    if case .propose = controller.routeLine {} else { Issue.record("expected a proposal route line") }

    controller.editor.string = "/remind:15:00 x"
    controller.textDidChange(change)
    #expect(controller.statusLabel.stringValue.contains("unexpected value"))
    if case .propose = controller.routeLine {} else { Issue.record("expected a proposal route line") }
}

@Test @MainActor func liveRewriteLeavesTheValuedAtomUnderTheCaretAloneWhereverItSits() throws {
    let controller = OmniCommandPadViewController(parser: try parser())
    controller.loadView()
    let change = Notification(name: NSText.didChangeNotification)

    // Editing a value in the middle of the text: `0` on the way to `0.3` must
    // not become `0%` under the cursor.
    var text = "Keep this /shorter:0 please"
    controller.editor.string = text
    controller.editor.setSelectedRange(NSRange(location: (text as NSString).range(of: "/shorter:0").upperBound, length: 0))
    controller.textDidChange(change)
    #expect(controller.editor.string == "Keep this /shorter:0 please")

    // Caret strictly inside the value counts as in progress too.
    controller.editor.setSelectedRange(NSRange(location: (text as NSString).range(of: ":0").location + 1, length: 0))
    controller.textDidChange(change)
    #expect(controller.editor.string == "Keep this /shorter:0 please")

    // Once the caret leaves the atom the canonical form is applied.
    controller.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    controller.textDidChange(change)
    #expect(controller.editor.string == "Keep this /shorter:0% please")

    // A finished atom rewrites even when an identical literal is under the caret.
    text = "/shorter:1 x /shorter:1"
    controller.editor.string = text
    controller.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    controller.textDidChange(change)
    #expect(controller.editor.string == "/shorter:1% x /shorter:1")

    // Caret sitting before an atom is not editing it.
    text = "x /shorter:0.25"
    controller.editor.string = text
    controller.editor.setSelectedRange(NSRange(location: 2, length: 0))
    controller.textDidChange(change)
    #expect(controller.editor.string == "x /shorter:25%")
}

@Test @MainActor func autocompleteReplacesTheCaretAtomNotAnEarlierStyleToken() throws {
    let controller = OmniCommandPadViewController(parser: try parser())
    controller.loadView()
    let text = "/style:formal /st"
    controller.editor.string = text
    controller.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    controller.replaceActiveAtom(with: "/stash")
    #expect(controller.editor.string == "/style:formal /stash")
}
