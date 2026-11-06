import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

// ⌘Y, the stash chord in the pad (D3, D4): what the field holds goes through
// the ordinary `/stash` submit with the closing gesture; never a result row,
// and nothing that would lose a command or a note.

@MainActor
private func chordParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    return OmniParser(manifest: manifest, references: try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)]))
}

@MainActor
private final class ChordPad {
    let pad: OmniCommandPadViewController
    var submits: [(String, OmniSubmitGesture)] = []
    var launches = 0

    init() throws {
        _ = NSApplication.shared
        pad = OmniCommandPadViewController(parser: try chordParser())
        pad.loadView()
        _ = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        pad.onLauncherQuery = { [unowned self] text in pad.showLauncherResults(.empty(LauncherQuery(text).text, lane: .curated)) }
        pad.onSubmit = { [unowned self] text, gesture in submits.append((text, gesture)) }
        pad.onLaunch = { [unowned self] _, _, _ in launches += 1 }
        pad.launcherEnabled = true
    }

    func type(_ text: String) {
        pad.editor.string = text
        pad.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func commandY() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16)!
        pad.editor.keyDown(with: event)
    }
}

@Test @MainActor func commandYOnTypedTextAppendsTheTokenVisiblyAndSubmitsWithTheClosingGesture() throws {
    let harness = try ChordPad()
    harness.type("garage MOT")
    #expect(harness.pad.mode == .suggesting, "short bare text starts launcher-first")
    harness.commandY()
    // On its own line: a line holding the token is rejoined with single spaces.
    #expect(harness.pad.editor.string == "garage MOT\n/stash")
    #expect(harness.submits.count == 1)
    #expect(harness.submits.map(\.1) == [.commandYClose])
    #expect(OmniStashText.payload(fromCommandText: harness.pad.editor.string) == "garage MOT")
    #expect(harness.launches == 0, "a highlighted launcher row never stands in for the stash")
}

@Test @MainActor func commandYOnCapturedMultiLineMaterialStashesItRatherThanOfferingStance() throws {
    let harness = try ChordPad()
    harness.pad.setProvenance(OmniPadProvenance(source: "Mail", detail: "Re: draft", wordCount: 8))
    harness.type("Hey Daniel — coffee Thursday?\nI can do 15:30 near the office.\n")
    #expect(harness.pad.isOfferRowVisible)
    harness.commandY()
    // Ends in a newline: the token takes the next line, which the payload drops.
    #expect(harness.pad.editor.string == "Hey Daniel — coffee Thursday?\nI can do 15:30 near the office.\n/stash")
    #expect(harness.submits.map(\.1) == [.commandYClose])
    // The host runs the visible field, lines intact (the canonical text is one line).
    #expect(OmniStashText.payload(fromCommandText: harness.pad.editor.string) == "Hey Daniel — coffee Thursday?\nI can do 15:30 near the office.")
}

@Test @MainActor func commandYKeepsTabsAndRunsOfSpacesOnTheLastLine() throws {
    for material in ["NAME    AGE\nbob     42", "a\tb\tc", "let x    = 1"] {
        let harness = try ChordPad()
        harness.type(material)
        harness.commandY()
        #expect(harness.submits.map(\.1) == [.commandYClose], "\(material)")
        #expect(OmniStashText.payload(fromCommandText: harness.pad.editor.string) == material)
    }
}

@Test @MainActor func commandYOnAFieldThatAlreadyPushesSubmitsItUnchanged() throws {
    let harness = try ChordPad()
    harness.type("/stash keep this one")
    harness.commandY()
    #expect(harness.pad.editor.string == "/stash keep this one")
    #expect(harness.submits.map(\.0) == ["/stash keep this one"])
    #expect(harness.submits.map(\.1) == [.commandYClose])
}

@Test @MainActor func commandYRefusesWhatItCannotStashWholeAndSaysWhy() throws {
    let harness = try ChordPad()
    harness.type("   ")
    harness.commandY()
    #expect(harness.pad.routeLine == .notice(OmniCommandPadViewController.stashChordEmptyLine))

    // A command, an import atom and an unknown slash word are not plain text.
    // A push that would drop another slash word, or a ✓ ✗ marker, is refused too.
    for line in ["/qq what is a torque wrench", "/stash:2 /qq why", "cd /tmp", "/stash see /docs", "done ✓ item", "/stash done ✗ item"] {
        harness.type(line)
        harness.commandY()
        #expect(harness.pad.editor.string == line, "\(line) is left as typed")
        #expect(harness.pad.routeLine == .notice(OmniCommandPadViewController.stashChordCommandLine), "\(line)")
    }

    // Notes would be lost: the stash keeps text only.
    harness.type("keep this with a note")
    harness.pad.setAnnotations([OmniTextAnnotation(range: NSRange(location: 0, length: 4), guidance: "Keep")])
    harness.commandY()
    #expect(harness.pad.routeLine == .notice(OmniCommandPadViewController.stashChordNotesLine))
    #expect(harness.submits.isEmpty)

    // The notice goes with the next keystroke, like every transient line.
    harness.type("keep this with a note, typed on")
    #expect(harness.pad.routeLine != .notice(OmniCommandPadViewController.stashChordNotesLine))
}

@Test @MainActor func commandYIsNotTheStashChordOnAResultOrWithOtherModifiers() throws {
    let harness = try ChordPad()
    harness.type("keep this")
    let shifted = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
        context: nil, characters: "Y", charactersIgnoringModifiers: "Y", isARepeat: false, keyCode: 16)!
    harness.pad.editor.keyDown(with: shifted)
    #expect(harness.submits.isEmpty)
    #expect(harness.pad.stashChord(), "composing: the chord is handled")

    harness.submits = []
    harness.pad.beginWorking(runID: "run-1", requestText: "keep this /stash", summary: "Stash")
    #expect(!harness.pad.stashChord())
    harness.pad.showResult(runID: "run-1", result: OmniPadResult(kind: .confirmation, body: "/stash · stashed", summary: "Saved · Stash"))
    #expect(!harness.pad.stashChord(), "a result is never stashed by ⌘Y")
    #expect(harness.submits.isEmpty)
}

@Test @MainActor func theStashHelpNamesTheChord() {
    #expect(OmniPadVocabulary.help(for: "/stash").contains("⌘Y"))
}
