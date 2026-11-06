import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

private let everywhereNow = Date(timeIntervalSince1970: 1_790_000_000)
private let curatedFixture = LauncherIndex(candidates: [
    LauncherCandidate(title: "Ghostty", path: "/Applications/Ghostty.app", kind: "app", source: .apps),
    LauncherCandidate(title: "Omni Intent", path: "/Users/fixture/Tooling/apps/omni-intent", kind: "folder", source: .roots),
    LauncherCandidate(title: "Omni Intent Reference", path: "/Users/fixture/Tooling/omni.md", kind: "reference", source: .docsIndex),
])
private let wideFixture = LauncherIndex(candidates: LauncherIndexAssembler.union(curated: curatedFixture.candidates, everywhere: [
    LauncherCandidate(title: "Bloom Handbook", path: "/Users/fixture/Downloads/bloom-handbook.pdf", kind: "pdf", source: .files, added: everywhereNow),
    LauncherCandidate(title: "Bloom Installer", path: "/Users/fixture/Downloads/bloom-installer.dmg", kind: "dmg", source: .files, added: everywhereNow),
    LauncherCandidate(title: "Bio portrait", path: "/Users/fixture/Documents/bio-portrait.jpg", kind: "jpg", source: .files, added: everywhereNow),
    LauncherCandidate(title: "Bio notes", path: "/Users/fixture/Documents/bio-notes.pdf", kind: "pdf", source: .files),
]), lane: .everywhere)

@MainActor private final class EverywherePadHarness {
    let pad: OmniCommandPadViewController
    var launches: [(String, LauncherOpenAction, LaunchContext)] = []
    var proposals = 0
    var fallthroughs = 0
    var delivers = true
    var matchCountOverride: Int?

    init() throws {
        _ = NSApplication.shared
        let corpus = FrozenContractCorpus()
        let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
        pad = OmniCommandPadViewController(parser: OmniParser(manifest: manifest, references: try ReferenceRegistry([])))
        pad.loadView()
        _ = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        pad.launcherHome = "/Users/fixture"
        pad.onLauncherQuery = { [unowned self] text in if delivers { pad.showLauncherResults(resolve(text)) } }
        pad.onResolveLauncher = { [unowned self] text in resolve(text) }
        pad.onLaunch = { [unowned self] id, action, context in launches.append((id, action, context)) }
        pad.onSubmit = { [unowned self] _, _ in proposals += 1 }
        pad.onLauncherFallthrough = { [unowned self] _ in fallthroughs += 1 }
        pad.launcherEnabled = true
    }

    func resolve(_ text: String) -> LauncherResults {
        if pad.launcherLane == .everywhere { return wideFixture.query(text, now: everywhereNow) }
        let result = curatedFixture.query(text, now: everywhereNow)
        return LauncherResults(query: result.query, rows: result.rows, ready: result.ready, margin: result.margin,
                               everywhereMatchCount: matchCountOverride ?? wideFixture.matchCount(text))
    }

    func type(_ text: String) {
        pad.editor.string = text
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func tab() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        pad.editor.keyDown(with: event)
    }
}

@Test @MainActor func tabKeepsQueryWidensWithChipNarrowsAndCloseResetsScope() throws {
    let harness = try EverywherePadHarness()
    harness.type("bloom")
    #expect(harness.pad.routeLine.text == "⇥ search everywhere · 2 matches")
    harness.tab()
    #expect(harness.pad.editor.string == "bloom")
    #expect(harness.pad.launcherLane == .everywhere)
    #expect(!harness.pad.launcherScopeChip.isHidden)
    #expect(harness.pad.launcherState?.results.rows.count == 2)
    #expect(harness.pad.launcherState?.highlighted == 0)
    harness.tab()
    #expect(harness.pad.editor.string == "bloom")
    #expect(harness.pad.launcherLane == .curated && harness.pad.launcherScopeChip.isHidden)
    harness.tab()
    harness.pad.endLauncherSession()
    #expect(harness.pad.launcherLane == .curated && harness.pad.launcherScopeChip.isHidden)
    #expect(harness.pad.editor.string == "bloom")
}

@Test @MainActor func tabAcceptsSlashCompletionAndLeavesAnnotationsAndMarkedTextAlone() throws {
    let harness = try EverywherePadHarness()
    harness.type("/em")
    #expect(harness.pad.isCompletionVisible)
    harness.tab()
    #expect(harness.pad.editor.string.hasPrefix("/email"))
    #expect(harness.pad.launcherLane == .curated)
    harness.type("bloom")
    harness.pad.setAnnotations([OmniTextAnnotation(range: NSRange(location: 0, length: 5), guidance: "Explain this")])
    #expect(harness.pad.toggleLauncherLane() == false)
    #expect(harness.pad.launcherLane == .curated)
    harness.pad.clearAnnotations()
    harness.pad.editor.setMarkedText("blo", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: 5))
    #expect(harness.pad.editor.hasMarkedText())
    #expect(harness.pad.toggleLauncherLane() == false)
    #expect(harness.pad.launcherLane == .curated)
    harness.pad.editor.unmarkText()
}

@Test @MainActor func emptyAndShortWidenHaveOnlyHintAndNoProposalOrRows() throws {
    let harness = try EverywherePadHarness()
    harness.tab()
    #expect(harness.pad.mode == .suggesting)
    #expect(harness.pad.launcherLane == .everywhere)
    #expect(harness.pad.routeLine == .hint(OmniCommandPadViewController.everywhereQueryHint))
    for text in ["", "b", "bl"] {
        harness.type(text)
        #expect(harness.pad.launcherState?.results.rows.isEmpty == true)
        harness.pad.editor.onSubmit?(.enterShowHere)
    }
    #expect(harness.launches.isEmpty && harness.proposals == 0 && harness.fallthroughs == 0)
}

@Test @MainActor func everywhereEnterIgnoresReadyRevealsArchivesAndNoMatchesIsNoOp() throws {
    let harness = try EverywherePadHarness()
    harness.type("bloom")
    harness.tab()
    #expect(harness.pad.launcherState?.results.ready == false)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.count == 1)
    #expect(harness.launches[0].0.hasSuffix("bloom-handbook.pdf"))
    #expect(harness.launches[0].1 == .open && harness.launches[0].2.lane == .everywhere)
    harness.type("bloom installer")
    #expect(harness.pad.routeLine.text.hasPrefix("Reveal Bloom Installer"))
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.last?.1 == .reveal)
    harness.type("bloom handbook")
    harness.pad.editor.onSubmit?(.commandEnterAttach)
    #expect(harness.launches.last?.1 == .reveal)
    harness.type("zzqnonexistent")
    #expect(harness.pad.routeLine == .hint(OmniCommandPadViewController.backToProposalLine))
    let before = harness.launches.count
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.count == before && harness.proposals == 0 && harness.fallthroughs == 0)
}

@Test @MainActor func everywhereUndoAndFailureNeverInsertProposalItemAndStaleLaneResultsAreDropped() throws {
    let harness = try EverywherePadHarness()
    harness.type("bloom")
    harness.tab()
    let id = try #require(harness.pad.launcherState?.results.top?.id)
    #expect(harness.pad.markLaunchUndo(candidateID: id))
    #expect(harness.pad.launcherState?.items.contains(.askForProposal) == false)
    harness.pad.editor.onSubmit?(.enterShowHere)
    #expect(harness.launches.count == 1 && harness.proposals == 0)
    #expect(harness.pad.markLaunchFailed(candidateID: id))
    #expect(harness.pad.launcherState?.items.contains(.askForProposal) == false)
    let stale = wideFixture.query("bloom", now: everywhereNow)
    harness.tab()
    harness.pad.showLauncherResults(stale)
    #expect(harness.pad.launcherState?.results.lane == .curated)
}

@Test @MainActor func curatedWidenOfferStartsAtThreeAndCapsCountWithoutChangingReadyEnter() throws {
    let harness = try EverywherePadHarness()
    harness.matchCountOverride = 100
    harness.type("om")
    #expect(!harness.pad.routeLine.text.contains("search everywhere"))
    harness.type("omni")
    #expect(harness.pad.routeLine.text == "⇥ search everywhere · 99+ matches")
    harness.type("ghostty")
    #expect(harness.pad.launcherState?.results.ready == true)
    #expect(!harness.pad.routeLine.text.contains("search everywhere"))
}

@Test @MainActor func designCaptureEverywhereLane() throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        for state in ["curated-footer", "everywhere-chip", "everywhere-image"] {
            let harness = try EverywherePadHarness()
            harness.type(state == "everywhere-image" ? "bio" : "bloom")
            if state != "curated-footer" { harness.tab() }
            let view = harness.pad.view
            view.appearance = NSAppearance(named: appearance)
            func opaque(_ node: NSView) {
                (node as? OmniFrostedSurface)?.apply(transparency: .opaqueFallback)
                node.subviews.forEach(opaque)
            }
            opaque(view)
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds.integral
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = bounds.size
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: bounds, to: bitmap) }
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("h14-\(state)-\(suffix).png"))
        }
    }
}
