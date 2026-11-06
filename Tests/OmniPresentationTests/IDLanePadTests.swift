import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

// The exact-id lane in the pad (D1, decision surface 569d5a7cf925cbd7):
// paste an id, Enter opens it; a miss is a plain footer and a dead Enter;
// neither ever reaches the proposal fallthrough.

private let surfaceID = "569d5a7cf925cbd7"
private let now = Date(timeIntervalSince1970: 1_790_000_000)

@MainActor
private func idParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    return OmniParser(manifest: manifest, references: try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)]))
}

private let surface = LauncherCandidate(title: "Omni find id lane — decision surface", path: "/Users/fixture/Base/surface_\(surfaceID).md", kind: "spec", source: .docsIndex, documentID: surfaceID)
private let run = LauncherCandidate(title: "\(surfaceID)_omni_find_id_lane", path: "/Users/fixture/Tooling/agent-output/\(surfaceID)_omni_find_id_lane", kind: "run-folder", source: .roots)
private let curated = [surface, LauncherCandidate(title: "Ghostty", path: "/Applications/Ghostty.app", kind: "app", source: .apps)]
private let ids = LauncherIDMap(curated: curated, everywhere: [run])
private let scored = LauncherIndex(candidates: curated)

/// The service's query, in miniature: ids first, then the scorer.
private func answer(_ text: String, lane: LauncherLane) -> LauncherResults {
    if let address = OmniIDAddress(text) { return ids.results(for: address, query: LauncherQuery(text).text, lane: lane) }
    return lane == .curated ? scored.query(text, now: now) : .empty(LauncherQuery(text).text, lane: lane)
}

@MainActor
private final class IDPad {
    let pad: OmniCommandPadViewController
    var launches: [(id: String, action: LauncherOpenAction, context: LaunchContext)] = []
    var fallthroughs: [LaunchContext] = []
    var submits: [(String, OmniSubmitGesture)] = []
    var copied: [String] = []

    init() throws {
        _ = NSApplication.shared
        pad = OmniCommandPadViewController(parser: try idParser())
        pad.loadView()
        _ = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        pad.launcherHome = "/Users/fixture"
        pad.onLauncherQuery = { [unowned self] text in pad.showLauncherResults(answer(text, lane: pad.launcherLane)) }
        pad.onResolveLauncher = { [unowned self] text in answer(text, lane: pad.launcherLane) }
        pad.onLaunch = { [unowned self] id, action, context in launches.append((id, action, context)) }
        pad.onLauncherFallthrough = { [unowned self] context in fallthroughs.append(context) }
        pad.onSubmit = { [unowned self] text, gesture in submits.append((text, gesture)) }
        pad.onCopyPath = { [unowned self] path in copied.append(path) }
        pad.launcherEnabled = true
    }

    func type(_ text: String) {
        pad.editor.string = text
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
    }

    var proposed: Bool { !submits.isEmpty || !fallthroughs.isEmpty }
}

private func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

@Test @MainActor func aPastedIDIsReadyAndEnterOpensIt() throws {
    let harness = try IDPad()
    harness.type(surfaceID)
    #expect(harness.pad.mode == .suggesting)
    let state = try #require(harness.pad.launcherState)
    #expect(state.results.rows.map(\.candidate.path) == [surface.path, run.path])
    #expect(state.readyBadgeIndex == 0)
    #expect(harness.pad.routeLine == .outcome("Open Omni find id lane — decision surface · spec"))
    #expect(harness.pad.footerState.keyHints == OmniPadKeyHint.idLane)
    harness.pad.editor.keyDown(with: key("\r", keyCode: 36))
    let launch = try #require(harness.launches.first)
    #expect(launch.id == surface.id && launch.action == .open)
    #expect(launch.context.lane == .curated && launch.context.query == surfaceID && launch.context.selection == .ready)
    #expect(!harness.proposed)
}

@Test @MainActor func aMissIsAPlainFooterAndEnterDoesNothing() throws {
    let harness = try IDPad()
    for text in ["0123456789abcdef", "doc:0123456789abcdef"] {
        harness.type(text)
        #expect(harness.pad.mode == .suggesting)
        #expect(harness.pad.launcherState?.results.idLookup == .miss)
        #expect(harness.pad.routeLine == .hint("No document with this id"))
        #expect(harness.pad.footerState.submits == false)
        harness.pad.editor.keyDown(with: key("\r", keyCode: 36))
        harness.pad.editor.onSubmit?(.commandEnterAttach)
    }
    harness.type("run:0123456789abcdef")
    #expect(harness.pad.routeLine == .hint("No run folder with this id"))
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.isEmpty)
    #expect(!harness.proposed, "an id never reaches the proposal fallthrough")
}

@Test @MainActor func runAndDocNamespacesNarrowAndARunFolderOpensThroughItsLane() throws {
    let harness = try IDPad()
    harness.type("run:\(surfaceID)")
    #expect(harness.pad.launcherState?.results.rows.map(\.candidate.path) == [run.path])
    harness.pad.editor.onSubmit?(.enterShowHere)
    let launch = try #require(harness.launches.first)
    #expect(launch.id == run.id)
    // Held only by the everywhere lane, so it opens through that opener
    // although the pad is on the curated lane.
    #expect(launch.context.lane == .everywhere)
    #expect(harness.pad.launcherLane == .curated)
    #expect(!harness.proposed)
}

@Test @MainActor func theIDLaneChordsRevealAndCopyThePath() throws {
    let harness = try IDPad()
    harness.type(surfaceID)
    harness.pad.editor.keyDown(with: key("\r", keyCode: 36, flags: .command))
    #expect(harness.launches.last?.action == .reveal)
    harness.pad.editor.keyDown(with: key("c", keyCode: 8, flags: [.command, .option]))
    #expect(harness.copied == [surface.path])
    // ↓ then ⌥⌘C copies the run folder's path instead.
    harness.pad.editor.keyDown(with: key("", keyCode: 125))
    harness.pad.editor.keyDown(with: key("c", keyCode: 8, flags: [.command, .option]))
    #expect(harness.copied.last == run.path)
    // Off the id lane the chord is not consumed.
    harness.type("ghostty")
    harness.pad.editor.keyDown(with: key("c", keyCode: 8, flags: [.command, .option]))
    #expect(harness.copied.count == 2)
    #expect(!harness.proposed)
}

@Test @MainActor func wrongLengthsAreOrdinaryLauncherText() throws {
    let harness = try IDPad()
    // Case folds (one normaliser, steering 2026-10-10); length does not.
    harness.type(surfaceID.uppercased())
    #expect(harness.pad.launcherState?.results.idLookup != nil)
    for text in [String(surfaceID.dropLast()), surfaceID + "0"] {
        harness.type(text)
        #expect(harness.pad.launcherState?.results.idLookup == nil)
    }
    // Ordinary text with no ready row still asks for a proposal (C50).
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.submits.count == 1)
}

@Test @MainActor func aFailedOpenOrAnUndoNeverOffersAProposalOnAnID() throws {
    let harness = try IDPad()
    harness.type(surfaceID)
    #expect(harness.pad.markLaunchFailed(candidateID: surface.id))
    #expect(harness.pad.launcherState?.items.contains(.askForProposal) == false)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.count == 1, "Enter tries the row again")
    #expect(harness.pad.markLaunchUndo(candidateID: surface.id))
    #expect(harness.pad.launcherState?.items.contains(.askForProposal) == false)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(!harness.proposed)
}

@Test @MainActor func tabStillWidensOnAnIDAndTheLookupIsTheSameInBothLanes() throws {
    let harness = try IDPad()
    harness.type(surfaceID)
    #expect(harness.pad.editor.onTab?() == true)
    #expect(harness.pad.launcherLane == .everywhere)
    #expect(harness.pad.launcherState?.results.rows.map(\.candidate.path) == [surface.path, run.path])
    harness.pad.editor.onSubmit?(.enterShowHere)
    // The curated document opens through the curated lane that holds it.
    #expect(harness.launches.last?.context.lane == .curated)
    harness.type("ffffffffffffffff")
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.count == 1)
    #expect(!harness.proposed)
}
