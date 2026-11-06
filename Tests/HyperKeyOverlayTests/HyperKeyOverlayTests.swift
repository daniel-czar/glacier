import AppKit
import Foundation
import HyperOverlayCore
@testable import HyperKeyOverlay
import OmniPresentation
import Testing

// H18: the overlay panel, controller and picture (C98–C103).

private let hyper: [HotKeyModifier] = [.command, .option, .control, .shift]
private func binding(_ id: String, _ keyCode: UInt32) -> OverlayHotKeyBinding {
    OverlayHotKeyBinding(overlayID: id, chord: HotKeyChord(keyCode: keyCode, modifiers: hyper))
}

private let liveBindingsURL = ProcessInfo.processInfo.environment["HYPER_OVERLAY_TEST_BINDINGS"]
    .map { URL(fileURLWithPath: $0) }
    ?? OverlayPaths.keyboardMaestroRoot.appendingPathComponent(HyperBindingsFile.fileName)

@MainActor private final class FakeEscape: HyperEscapeClaim {
    var grants = true
    var handler: (@MainActor () -> Void)?
    var claims = 0
    var releases = 0
    func claim(handler: @escaping @MainActor () -> Void) -> Bool {
        claims += 1
        self.handler = grants ? handler : nil
        return grants
    }
    func release() { releases += 1; handler = nil }
}

@MainActor private final class Rig {
    var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    let escape = FakeEscape()
    var registered = [binding(OverlayID.stash, 16), binding(OverlayID.help, 4), binding(OverlayID.translate, 37)]
    let directory: URL
    let controller: HyperKeyOverlayController

    init(file: HyperBindingsFile? = nil, presentsInterface: Bool = false) throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hyper-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(HyperBindingsFile.fileName)
        if let file { try JSONEncoder().encode(file).write(to: url) }
        var rig: Rig?
        controller = HyperKeyOverlayController(
            registered: { rig?.registered ?? [] }, bindingsURL: url, presentsInterface: presentsInterface,
            escapeClaim: escape, schedule: { delay, work in rig?.scheduled.append((delay, work)) }
        )
        rig = self
    }

    func fireTimers() {
        let pending = scheduled
        scheduled = []
        for (_, work) in pending { work() }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

@Suite(.serialized) @MainActor struct HyperKeyOverlaySuite {

@Test func panelIsANonActivatingHintThatNeverTakesKey() {
    _ = NSApplication.shared
    let panel = HyperKeyOverlayPanel(layout: .ukISOMacBook, catalog: HyperBindingCatalog(bindings: [:], problems: []))
    #expect(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless))
    #expect(!panel.canBecomeKey && !panel.canBecomeMain)
    #expect(panel.level == .floating && !panel.hidesOnDeactivate)
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(panel.surface.cornerRadius == 18)
    let visible = NSRect(x: 0, y: 0, width: 1470, height: 920)
    panel.apply(mode: .held, frame: NSRect(origin: .zero, size: panel.size(for: .held, visible: visible)))
    #expect(panel.ignoresMouseEvents, "held: no hover")
    panel.apply(mode: .pinned, frame: NSRect(origin: .zero, size: panel.size(for: .pinned, visible: visible)))
    #expect(!panel.ignoresMouseEvents, "pinned: hover for detail")
    #expect(panel.size(for: .held, visible: visible) == NSSize(width: 981, height: 400))
    #expect(panel.size(for: .pinned, visible: visible).height == 434)
    // A narrow screen scales the picture down instead of clipping it.
    #expect(panel.size(for: .held, visible: NSRect(x: 0, y: 0, width: 800, height: 600)).width <= 760)
}

@Test func placementCentresOrSitsBelowThePad() {
    let visible = NSRect(x: 0, y: 0, width: 1470, height: 920)
    let size = NSSize(width: 981, height: 400)
    let centred = HyperKeyOverlayPlacement.frame(size: size, visible: visible, pad: nil)
    #expect(abs(centred.midX - visible.midX) <= 0.5 && abs(centred.midY - visible.midY) <= 0.5)
    let pad = NSRect(x: 415, y: 640, width: 640, height: 108)
    let below = HyperKeyOverlayPlacement.frame(size: size, visible: visible, pad: pad)
    #expect(below.maxY == pad.minY - HyperKeyOverlayPlacement.padGap && abs(below.midX - pad.midX) <= 0.5)
    // No room below the pad: centred instead.
    let low = NSRect(x: 415, y: 200, width: 640, height: 108)
    #expect(HyperKeyOverlayPlacement.frame(size: size, visible: visible, pad: low) == centred)
}

@Test func holdShowsAfterTheThresholdAndReleaseHides() throws {
    let rig = try Rig()
    rig.controller.start(monitoringKeyboard: false)
    rig.controller.hyperChanged(down: true)
    #expect(rig.scheduled.map(\.0) == [HyperHoldStateMachine.holdThreshold])
    #expect(!rig.controller.isShown)
    rig.fireTimers()
    #expect(rig.controller.presentation == .held && rig.controller.isShown)
    rig.controller.hyperChanged(down: false)
    #expect(rig.controller.presentation == .hidden && !rig.controller.isShown)
}

@Test func aChordBeforeTheThresholdNeverShows() throws {
    let rig = try Rig()
    rig.controller.start(monitoringKeyboard: false)
    rig.controller.hyperChanged(down: true)
    rig.controller.bindingFired(OverlayID.translate)
    rig.fireTimers()
    #expect(!rig.controller.isShown)
    rig.controller.hyperChanged(down: false)
    rig.controller.hyperChanged(down: true)
    rig.controller.keyDown(keyCode: 40) // unbound Hyper+K
    rig.fireTimers()
    #expect(!rig.controller.isShown)
}

@Test func helpPinsClaimsEscapeAndEscapeCloses() throws {
    let rig = try Rig()
    rig.controller.start(monitoringKeyboard: false)
    rig.controller.helpPressed()
    #expect(rig.controller.presentation == .pinned && rig.escape.claims == 1)
    rig.controller.hyperChanged(down: false)
    #expect(rig.controller.presentation == .pinned, "pinned stays after release")
    let escape = try #require(rig.escape.handler)
    escape()
    #expect(rig.controller.presentation == .hidden && rig.escape.releases == 1)
    // When another app owns plain esc, the key is observed instead.
    rig.escape.grants = false
    rig.controller.helpPressed()
    rig.controller.keyDown(keyCode: 53)
    #expect(rig.controller.presentation == .hidden)
}

@Test func hyperFromPinnedHoldsAndAnyChordEndsIt() throws {
    let rig = try Rig()
    rig.controller.start(monitoringKeyboard: false)
    rig.controller.helpPressed()
    rig.controller.hyperChanged(down: true)
    #expect(rig.controller.presentation == .held, "Caps Lock goes down on the picture at once")
    #expect(rig.scheduled.isEmpty, "no threshold: it is already up")
    rig.controller.keyDown(keyCode: 1) // Hyper+S, a Keyboard Maestro chord
    rig.controller.hyperChanged(down: false)
    #expect(rig.controller.presentation == .hidden)
}

@Test func catalogComesFromWhatRegisteredAndTheFileWithProblemsInStatus() throws {
    let rig = try Rig(file: HyperBindingsFile(bindings: [
        .init(owner: .native, overlay: OverlayID.stash, label: "Stash", description: "Stash stack"),
        .init(owner: .native, overlay: OverlayID.help, label: "Keep this open", description: "Keep this overlay open"),
        .init(owner: .keyboardMaestro, key: "V", label: "Paste plain", description: "Normalize clipboard and paste", shape: "Deterministic · no notification"),
        .init(owner: .keyboardMaestro, key: "Y", label: "Clash", description: "taken by the stash"),
    ]))
    rig.controller.start(monitoringKeyboard: false)
    let catalog = rig.controller.catalog
    #expect(catalog.bindings["Y"]?.label == "Stash" && catalog.bindings["H"]?.label == "Keep this open")
    #expect(catalog.bindings["L"]?.label == "Translate", "registered but unnamed: fallback label")
    #expect(catalog.bindings["V"]?.owner == .keyboardMaestro)
    let facts = rig.controller.statusFacts
    #expect(facts["bindings"] == "4" && facts["native"] == "3" && facts["keyboard_maestro"] == "1")
    #expect(facts["problems"]?.contains("Clash") == true)
    // A chord that registers later appears on the next refresh.
    rig.registered.append(binding(OverlayID.express, 14))
    rig.controller.refreshBindings()
    #expect(rig.controller.catalog.bindings["E"] != nil)
}

@Test func aMissingBindingsFileStillDrawsTheNativeChords() throws {
    let rig = try Rig()
    rig.controller.start(monitoringKeyboard: false)
    #expect(rig.controller.catalog.bindings.count == 3)
    #expect(rig.controller.statusFacts["problems"]?.contains("is missing") == true)
}

@Test func pinnedHoverShowsTheLongDescriptionHeldDoesNot() {
    _ = NSApplication.shared
    let layout = HyperKeyboardLayout.ukISOMacBook
    let catalog = HyperBindingCatalog(bindings: [
        "V": HyperCapBinding(capID: "V", label: "Paste plain", description: "Normalises the clipboard and pastes the result.",
                             kind: .command, owner: .keyboardMaestro, overlayID: nil, shape: "Deterministic · no notification"),
    ], problems: [])
    let view = HyperKeyOverlayView(layout: layout, catalog: catalog)
    let v = view.rect(for: layout.cap(id: "V")!)
    view.hover(at: NSPoint(x: v.midX, y: v.midY))
    #expect(view.popover.isHidden, "held: hover is not allowed")
    view.mode = .pinned
    #expect(!view.keyHintsView.isHidden && view.keyHintsView.hints == [.init("esc", "Close")])
    view.hover(at: NSPoint(x: v.midX, y: v.midY))
    #expect(!view.popover.isHidden && view.hoveredCapID == "V")
    #expect(view.popover.titleLabel.stringValue == "Paste plain · Hyper V")
    #expect(view.popover.metaLabel.stringValue == "Deterministic · no notification")
    #expect(abs(view.popover.frame.midX - v.midX) <= 1, "the popover sits under its key")
    #expect(view.popover.frame.minY > v.maxY || view.popover.frame.maxY < v.minY)
    let q = view.rect(for: layout.cap(id: "Q")!)
    view.hover(at: NSPoint(x: q.midX, y: q.midY))
    #expect(view.popover.isHidden, "an unbound key has no detail")
    view.mode = .held
    #expect(view.keyHintsView.isHidden)
}

@Test func collectCountsReplaceTheFileLabelsAndEveryCountLabelFits() throws {
    let rig = try Rig(file: HyperBindingsFile(bindings: [
        .init(owner: .native, overlay: OverlayID.collectAdd, label: "Collect", description: "Copy and collect"),
        .init(owner: .native, overlay: OverlayID.collectClear, label: "Clear collected", description: "Discard what you collected"),
    ]))
    rig.registered = [binding(OverlayID.collectAdd, 8), binding(OverlayID.collectNext, 9), binding(OverlayID.collectAll, 11),
                      binding(OverlayID.collectClear, 27), binding(OverlayID.equalize, 24)]
    var count = 3
    rig.controller.labelOverrides = { [OverlayID.collectAdd: "Collect · \(count)", OverlayID.collectNext: "Paste next · \(count)"] }
    rig.controller.start(monitoringKeyboard: false)
    #expect(rig.controller.catalog.bindings["C"]?.label == "Collect · 3")
    #expect(rig.controller.catalog.bindings["V"]?.label == "Paste next · 3")
    #expect(rig.controller.catalog.bindings["-"]?.label == "Clear collected", "Clear sits on minus, beside =")
    #expect(rig.controller.catalog.bindings["="]?.kind == .command)
    count = 0
    rig.controller.refreshBindings()
    #expect(rig.controller.catalog.bindings["C"]?.label == "Collect · 0")
    // The longest labels the counts can make still fit two lines on a cap.
    for label in ["Collect · 999", "Paste next · 999", "Paste all · 999", "Clear collected", "Equalize"] {
        #expect(HyperKeyOverlayView.labelFits(label), "\(label)")
    }
}

@Test func bezelIsAFailureHUDThatNeverTakesKeyOrJoinsTheOverlayCount() throws {
    _ = NSApplication.shared
    let bezel = HyperBezel()
    bezel.show("Buffer empty")
    #expect(bezel.message == "Buffer empty")
    let panel = try #require(bezel.panel)
    #expect(panel.title != "Hyper Overlay", "the release probe counts overlays by that title")
    #expect(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    panel.orderOut(nil)
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: liveBindingsURL.path), "no live bindings file on this machine"))
func liveBindingsFileDecodesNamesRealCapsAndEveryLabelFitsItsCap() throws {
    let file = try HyperBindingsFile.decode(Data(contentsOf: liveBindingsURL))
    let layout = HyperKeyboardLayout.ukISOMacBook
    for entry in file.bindings {
        if let key = entry.key { #expect(layout.cap(id: key) != nil, "\(entry.label): \(key)") }
        if entry.owner == .native { #expect(entry.overlay != nil, "\(entry.label)") }
        let width: CGFloat = entry.key.flatMap { layout.cap(id: $0)?.frame.width } ?? CGFloat(HyperKeyboardLayout.keySize)
        if entry.overlay != OverlayID.space {
            #expect(HyperKeyOverlayView.labelFits(entry.label, capWidth: width), "\(entry.label) does not fit two lines")
        }
    }
    let keys = file.bindings.compactMap(\.key)
    #expect(Set(keys).count == keys.count, "a key is listed twice")
}

@Test func designCaptureHyperOverlay() throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return }
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = (try? HyperBindingsFile.decode(Data(contentsOf: liveBindingsURL)))
    let registered = [
        binding(OverlayID.space, 49), binding(OverlayID.clipboard, 39), binding(OverlayID.stash, 16),
        binding(OverlayID.translate, 37), binding(OverlayID.pronounce, 32), binding(OverlayID.semanticTools, 46),
        binding(OverlayID.quickQuestion, 79), binding(OverlayID.reference, 30), binding(OverlayID.express, 14),
        binding(OverlayID.help, 4), binding(OverlayID.zoxide, 6), binding(OverlayID.capture, 45),
        binding(OverlayID.webSearch, 42),
    ]
    let catalog = HyperBindingCatalog.build(registered: registered, file: file, layout: .ukISOMacBook)
    for (name, appearance, mode, hover) in [
        ("held-dark", NSAppearance.Name.darkAqua, HyperKeyOverlayView.Mode.held, nil as String?),
        ("pinned-dark", .darkAqua, .pinned, "V"),
        ("held-light", .aqua, .held, nil),
        ("pinned-light", .aqua, .pinned, "Y"),
    ] {
        let size = HyperKeyOverlayView.contentSize(layout: .ukISOMacBook, mode: mode)
        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        ground.wantsLayer = true
        ground.appearance = NSAppearance(named: appearance)
        ground.layer?.backgroundColor = (appearance == .darkAqua ? NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1)
                                                               : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1)).cgColor
        let view = HyperKeyOverlayView(layout: .ukISOMacBook, catalog: catalog)
        view.frame = ground.bounds
        view.mode = mode
        ground.addSubview(view)
        view.layoutSubtreeIfNeeded()
        if let hover, let cap = HyperKeyboardLayout.ukISOMacBook.cap(id: hover) {
            let rect = view.rect(for: cap)
            view.hover(at: NSPoint(x: rect.midX, y: rect.midY))
            view.popover.layoutSubtreeIfNeeded()
        }
        let representation = try #require(ground.bitmapImageRepForCachingDisplay(in: ground.bounds))
        ground.cacheDisplay(in: ground.bounds, to: representation)
        try #require(representation.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("hyper-overlay-\(name).png"))
    }
}

}
