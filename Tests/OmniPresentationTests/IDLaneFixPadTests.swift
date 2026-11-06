import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

// M1 review fixes in the pad (D1): an id stays an address with a trailing
// newline or as an imported selection; honest footers while loading, before
// the rows arrive, and with a note.

private let surfaceID = "569d5a7cf925cbd7"

@MainActor
private func fixParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    return OmniParser(manifest: manifest, references: try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)]))
}

private let surface = LauncherCandidate(title: "Decision surface", path: "/Users/fixture/Base/surface_\(surfaceID).md", kind: "spec", source: .docsIndex, documentID: surfaceID)
private let ids = LauncherIDMap(curated: [surface], everywhere: [])

@MainActor
private final class FixPad {
    let pad: OmniCommandPadViewController
    var launches: [(String, LauncherOpenAction, LaunchContext)] = []
    var submits: [String] = []
    var deliver = true
    var pending = false

    init() throws {
        _ = NSApplication.shared
        pad = OmniCommandPadViewController(parser: try fixParser())
        pad.loadView()
        _ = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        pad.onLauncherQuery = { [unowned self] text in
            guard deliver, let address = OmniIDAddress(text) else { return }
            pad.showLauncherResults(ids.results(for: address, query: LauncherQuery(text).text, lane: pad.launcherLane))
        }
        pad.onResolveLauncher = { [unowned self] text in
            OmniIDAddress(text).map { ids.results(for: $0, query: LauncherQuery(text).text, lane: pad.launcherLane) } ?? .empty(LauncherQuery(text).text)
        }
        pad.onLaunch = { [unowned self] in launches.append(($0, $1, $2)) }
        pad.onSubmit = { [unowned self] text, _ in submits.append(text) }
        pad.onIDLookupPending = { [unowned self] in pending }
        pad.launcherEnabled = true
    }

    func type(_ text: String) {
        pad.editor.string = text
        pad.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
    }
}

@Test @MainActor func aPastedIDWithATrailingNewlineIsStillAnAddress() throws {
    let harness = try FixPad()
    harness.type(surfaceID + "\n")
    #expect(harness.pad.mode == .suggesting)
    #expect(!harness.pad.isOfferRowVisible, "never /stance material")
    #expect(harness.pad.launcherState?.results.rows.map(\.candidate.path) == [surface.path])
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.map(\.0) == [surface.id])
    #expect(harness.submits.isEmpty)
}

@Test @MainActor func anIDInAnyCaseOrWrappedInZeroWidthCharactersIsAnAddress() throws {
    for text in [surfaceID.uppercased(), "\u{200B}\(surfaceID)\u{FEFF}", "DOC:\(surfaceID.uppercased())", "`\(surfaceID)`", "\(surfaceID).", "“\(surfaceID)”"] {
        let harness = try FixPad()
        harness.type(text)
        #expect(harness.pad.mode == .suggesting, "\(text.debugDescription)")
        #expect(harness.pad.launcherState?.items.contains(.askForProposal) == false)
        #expect(!harness.pad.isOfferRowVisible)
        harness.pad.editor.onSubmit?(.enterShowHere)
        #expect(harness.launches.map(\.0) == [surface.id], "it opens; never a proposal")
        #expect(harness.submits.isEmpty)
    }
}

@Test @MainActor func anImportedSelectionThatIsAnIDIsAnAddressToo() throws {
    let harness = try FixPad()
    harness.pad.setProvenance(OmniPadProvenance(source: "Ghostty", detail: "zsh", wordCount: 1))
    harness.type(surfaceID)
    #expect(harness.pad.mode == .suggesting)
    #expect(!harness.pad.isOfferRowVisible)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.count == 1 && harness.submits.isEmpty)
    // Ordinary material from the same app is still material (C77).
    harness.type("Can we move the call to Thursday?")
    #expect(harness.pad.mode == .composing)
    #expect(harness.pad.isOfferRowVisible)
}

@Test @MainActor func aMissWhileIDsAreLoadingSaysSo() throws {
    let harness = try FixPad()
    harness.pending = true
    harness.type("0123456789abcdef")
    #expect(harness.pad.routeLine == .hint("Ids are still loading · try again in a moment"))
    harness.pending = false
    harness.type("fedcba9876543210")
    #expect(harness.pad.routeLine == .hint("No document with this id"))
}

@Test @MainActor func beforeTheRowsArriveAnIDLooksItselfUpAndEnterStillOpens() throws {
    let harness = try FixPad()
    harness.deliver = false
    harness.type(surfaceID)
    #expect(harness.pad.routeLine == .hint("Looking up the id"))
    #expect(harness.pad.footerState.submits)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.map(\.0) == [surface.id], "Enter resolves on the current text")
    #expect(harness.submits.isEmpty)
}

@Test @MainActor func anIDWithANoteSaysWhyNothingRunsAndNeverSubmits() throws {
    let harness = try FixPad()
    harness.type(surfaceID)
    harness.pad.setAnnotations([OmniTextAnnotation(range: NSRange(location: 0, length: 16), guidance: "What is this?")])
    #expect(harness.pad.mode == .composing)
    #expect(harness.pad.routeLine == .hint("An id opens from the launcher · remove the note to open it"))
    #expect(!harness.pad.footerState.submits)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.isEmpty && harness.launches.isEmpty)
}

@Test @MainActor func tabOnACapturedIDTypesNoTab() throws {
    let harness = try FixPad()
    harness.pad.setProvenance(OmniPadProvenance(source: "Ghostty", detail: "zsh", wordCount: 1))
    harness.type(surfaceID)
    harness.pad.editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!)
    #expect(harness.pad.editor.string == surfaceID)
    #expect(harness.pad.mode == .suggesting)
}
