import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

private let quickNow = Date(timeIntervalSince1970: 1_790_000_000)
private let quickFixture = LauncherIndex(candidates: [
    LauncherCandidate(title: "Emacs", path: "/Applications/Emacs.app", kind: "app", source: .apps),
    LauncherCandidate(title: "Email drafts", path: "/Users/fixture/Documents/email-drafts.md", kind: "markdown", source: .roots),
])
private let emoji = OmniQuickLaunch(letters: "em", title: "Emoji", toolID: "emoji")
private let quick = OmniQuickLaunch(letters: "qq", title: "Quick answer", toolID: "quick-question")
private let clipboard = OmniQuickLaunch(letters: "cl", title: "Clipboard history", toolID: "clipboard-history")

@MainActor private final class QuickLaunchPadHarness {
    let pad: OmniCommandPadViewController
    var opened: [OmniQuickLaunch] = []
    var launches: [String] = []
    var submits: [String] = []

    init(launcher: Bool, handler: Bool = true) throws {
        _ = NSApplication.shared
        let manifest = try CommandManifest(data: FrozenContractCorpus().data(named: "manifest"))
        pad = OmniCommandPadViewController(parser: OmniParser(manifest: manifest, references: try ReferenceRegistry([])))
        pad.loadView()
        _ = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        pad.quickLaunchTools = [quick, clipboard, emoji]
        if handler { pad.onQuickLaunch = { [unowned self] in opened.append($0) } }
        pad.onSubmit = { [unowned self] text, _ in submits.append(text) }
        if launcher {
            pad.launcherHome = "/Users/fixture"
            pad.onLauncherQuery = { [unowned self] text in pad.showLauncherResults(quickFixture.query(text, now: quickNow)) }
            pad.onResolveLauncher = { text in quickFixture.query(text, now: quickNow) }
            pad.onLaunch = { [unowned self] id, _, _ in launches.append(id) }
            pad.launcherEnabled = true
        }
    }

    func type(_ text: String) {
        pad.editor.string = text
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
        pad.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    func tab() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        pad.editor.keyDown(with: event)
    }

    var tabHint: OmniPadKeyHint? { pad.footerState.keyHints.first { $0.key == "⇥" } }

    var tint: NSColor? {
        guard pad.editor.textStorage?.length ?? 0 > 0 else { return nil }
        return pad.editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
}

@Test @MainActor func exactAbbreviationTintsTokenAndNamesToolOnTab() throws {
    for launcher in [false, true] {
        let harness = try QuickLaunchPadHarness(launcher: launcher)
        harness.type("em")
        #expect(harness.pad.matchedQuickLaunch == emoji)
        #expect(harness.tabHint == OmniPadKeyHint("⇥", "Emoji", emphasized: true))
        #expect(harness.pad.footerState.keyHints.first == harness.tabHint)
        #expect(harness.pad.keyHintsView.hints == harness.pad.footerState.keyHints)
        #expect(harness.tint == OmniFrostedStyle.mode)
        #expect(harness.pad.editor.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor == OmniFrostedStyle.modeTokenFill)

        harness.type("ema")
        #expect(harness.pad.matchedQuickLaunch == nil)
        #expect(harness.tabHint?.label != "Emoji")
        #expect(harness.pad.footerState.keyHints.allSatisfy { !$0.emphasized })
        #expect(harness.tint != OmniFrostedStyle.mode)
    }
}

@Test @MainActor func tabOnAbbreviationOpensToolAndOtherwiseKeepsTheLaneToggle() throws {
    let harness = try QuickLaunchPadHarness(launcher: true)
    harness.type("em")
    harness.tab()
    #expect(harness.opened == [emoji])
    #expect(harness.pad.launcherLane == .curated)
    #expect(harness.pad.editor.string == "em")

    harness.type("ema")
    harness.tab()
    #expect(harness.opened == [emoji])
    #expect(harness.pad.launcherLane == .everywhere)
    #expect(harness.pad.editor.string == "ema")
}

@Test @MainActor func clipboardAbbreviationIsExactAndOnlyTabOpensIt() throws {
    let harness = try QuickLaunchPadHarness(launcher: true)
    harness.type("cl")
    #expect(harness.pad.matchedQuickLaunch == clipboard)
    #expect(harness.tabHint == OmniPadKeyHint("⇥", "Clipboard history", emphasized: true))
    harness.tab()
    #expect(harness.opened == [clipboard])

    for text in ["CL", " cl", "cl ", "cli"] {
        harness.type(text)
        #expect(harness.pad.matchedQuickLaunch == nil)
        harness.tab()
        #expect(harness.opened == [clipboard])
    }

    let enter = try QuickLaunchPadHarness(launcher: true)
    enter.type("cl")
    enter.pad.editor.onSubmit?(.enterShowHere)
    #expect(enter.opened.isEmpty)
    #expect(enter.launches.count + enter.submits.count == 1)
}

@Test @MainActor func enterOnAbbreviationStillSearchesFiles() throws {
    // Enter does exactly what it does on a pad with no abbreviations at all.
    let harness = try QuickLaunchPadHarness(launcher: true)
    let plain = try QuickLaunchPadHarness(launcher: true, handler: false)
    plain.pad.quickLaunchTools = []
    for pad in [harness, plain] {
        pad.type("em")
        #expect(pad.pad.mode == .suggesting)
        #expect(pad.pad.launcherState?.results.rows.isEmpty == false)
        pad.pad.editor.onSubmit?(.enterShowHere)
    }
    #expect(harness.opened.isEmpty)
    #expect(harness.launches == plain.launches && harness.submits == plain.submits)
    #expect(harness.launches.count + harness.submits.count == 1)
    #expect(harness.pad.footerState.routeLine == plain.pad.footerState.routeLine)
    #expect(harness.pad.footerState.runEnabled == plain.pad.footerState.runEnabled)
}

@Test @MainActor func everywhereLaneTabHintBecomesTheTool() throws {
    let harness = try QuickLaunchPadHarness(launcher: true)
    harness.type("")
    harness.tab()
    #expect(harness.pad.launcherLane == .everywhere)
    harness.type("qq")
    #expect(harness.pad.footerState.keyHints.filter { $0.key == "⇥" } == [OmniPadKeyHint("⇥", "Quick answer", emphasized: true)])
    harness.tab()
    #expect(harness.opened == [quick])
    #expect(harness.pad.launcherLane == .everywhere)
}

@Test @MainActor func caretAwayFromTheEndOrNoHandlerKeepsOrdinaryMeaning() throws {
    let harness = try QuickLaunchPadHarness(launcher: false)
    harness.type("em")
    harness.pad.editor.setSelectedRange(NSRange(location: 1, length: 0))
    #expect(harness.pad.matchedQuickLaunch == nil)
    #expect(harness.tint != OmniFrostedStyle.mode)
    #expect(harness.tabHint == nil)
    harness.pad.editor.setSelectedRange(NSRange(location: 2, length: 0))
    #expect(harness.pad.matchedQuickLaunch == emoji)
    #expect(harness.tint == OmniFrostedStyle.mode)

    harness.type("EM")
    #expect(harness.pad.matchedQuickLaunch == nil)
    harness.type(" em")
    #expect(harness.pad.matchedQuickLaunch == nil)

    let unhandled = try QuickLaunchPadHarness(launcher: false, handler: false)
    unhandled.type("em")
    #expect(unhandled.pad.matchedQuickLaunch == nil)
    #expect(unhandled.tabHint == nil)
}

@Test @MainActor func annotatedAbbreviationIsARequestNotASwitch() throws {
    let harness = try QuickLaunchPadHarness(launcher: false)
    harness.type("qq")
    harness.pad.setAnnotations([OmniTextAnnotation(range: NSRange(location: 0, length: 2), guidance: "Explain this")])
    harness.pad.editor.setSelectedRange(NSRange(location: 2, length: 0))
    #expect(harness.pad.matchedQuickLaunch == nil)
    harness.tab()
    #expect(harness.opened.isEmpty)
}
