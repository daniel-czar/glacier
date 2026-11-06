import CoreGraphics
import Foundation
import HyperOverlayCore
import Testing

// H18, the Hyper overlay (C98–C103): the UK ISO layout table, the bindings
// catalog and the hold state machine.

private let layout = HyperKeyboardLayout.ukISOMacBook
private let hyper: [HotKeyModifier] = [.command, .option, .control, .shift]

private func binding(_ id: String, _ keyCode: UInt32) -> OverlayHotKeyBinding {
    OverlayHotKeyBinding(overlayID: id, chord: HotKeyChord(keyCode: keyCode, modifiers: hyper))
}

@Test func ukISOLayoutRowsEndOnOneEdgeAndKeepTheISOShape() throws {
    func cap(_ id: String) throws -> HyperKeyCap { try #require(layout.cap(id: id)) }
    #expect(Double(layout.size.width) == HyperKeyboardLayout.width)
    #expect(Double(layout.size.height) == 28 + 5 * 58 + 5 * 6)
    // Every row ends on the same right edge (Enter's stem closes the A row).
    let enter = try cap("return")
    let stem = try #require(enter.stemFrame)
    let rowEnds = [try cap("touch-id").frame.maxX, try cap("delete").frame.maxX, enter.frame.maxX, stem.maxX,
                   try cap("right-shift").frame.maxX, try cap("right").frame.maxX]
    for end in rowEnds { #expect(abs(Double(end) - HyperKeyboardLayout.width) < 0.001) }
    // Tall ISO Enter: a wider top on the Q row, a narrower stem on the A row,
    // right-aligned; `\ |` beside it.
    #expect(Double(enter.frame.minY) == Double(try cap("Q").frame.minY))
    #expect(Double(stem.minY) == Double(try cap("A").frame.minY))
    #expect(stem.width < enter.frame.width && Double(stem.maxX) == Double(enter.frame.maxX))
    #expect(Double(try cap("\\").frame.maxX) + HyperKeyboardLayout.gap == Double(stem.minX))
    // UK ISO specifics.
    #expect(try cap("§").shifted == "±" && Double(try cap("§").frame.minX) == 0)
    #expect(try cap("2").shifted == "\"" && cap("3").shifted == "£" && cap("'").shifted == "@")
    #expect(layout.cap(forKeyCode: 50)?.id == "`", "` ~ beside left shift")
    #expect(Double(try cap("`").frame.minX) == Double(try cap("shift").frame.maxX) + HyperKeyboardLayout.gap)
    #expect(try cap("caps").glyph == "hyper" && cap("caps").symbol == "⇪")
    #expect(Double(try cap("F1").frame.height) == 28, "half-height function row")
    #expect(Double(try cap("space").frame.width) == 320)
    // Inverted T: ▲ over ▼ in one column, ◀ ▶ full height either side.
    let up = try cap("up"), down = try cap("down"), left = try cap("left")
    #expect(Double(up.frame.minX) == Double(down.frame.minX) && up.frame.maxY < down.frame.minY)
    #expect(Double(up.frame.minY) == Double(left.frame.minY) && Double(down.frame.maxY) == Double(left.frame.maxY))
    // Ids and key codes are unique.
    #expect(Set(layout.caps.map(\.id)).count == layout.caps.count)
    let codes = layout.caps.compactMap(\.keyCode)
    #expect(Set(codes).count == codes.count)
    // No two caps overlap, the Enter stem included.
    for (index, cap) in layout.caps.enumerated() {
        for other in layout.caps[(index + 1)...] {
            let overlaps = [cap.frame] + [cap.stemFrame].compactMap { $0 }
            let others = [other.frame] + [other.stemFrame].compactMap { $0 }
            #expect(!overlaps.contains { a in others.contains { a.intersects($0) } }, "\(cap.id) overlaps \(other.id)")
        }
    }
}

@Test func catalogDrawsWhatRegisteredNamesItFromTheFileAndAddsKeyboardMaestroKeys() {
    let file = HyperBindingsFile(bindings: [
        .init(owner: .native, overlay: OverlayID.stash, label: "Stash", description: "Stash stack"),
        .init(owner: .native, overlay: OverlayID.quickQuestion, key: "/", label: "Quick answer", description: "Live quick answer"),
        .init(owner: .native, overlay: OverlayID.zoxide, label: "Zoxide jump", description: "Zoxide Finder jump"),
        .init(owner: .native, overlay: OverlayID.normalizeNote, label: "Normalize", description: "disabled, never drawn"),
        .init(owner: .keyboardMaestro, key: "V", label: "Paste plain", description: "Normalize clipboard and paste", shape: "Deterministic · no notification"),
        .init(owner: .keyboardMaestro, key: "Y", label: "Collides", description: "native wins"),
        .init(owner: .keyboardMaestro, key: "nope", label: "Nowhere", description: "not a cap"),
    ])
    let registered = [
        binding(OverlayID.stash, 16),
        binding(OverlayID.quickQuestion, 79), // F18 via Karabiner
        binding(OverlayID.zoxide, 6),
        binding(OverlayID.express, 14), // not in the file
        binding(OverlayID.reference, 2),
    ]
    let catalog = HyperBindingCatalog.build(registered: registered, file: file, layout: layout)
    #expect(catalog.bindings["Y"]?.label == "Stash" && catalog.bindings["Y"]?.kind == .surface)
    #expect(catalog.bindings["/"]?.overlayID == OverlayID.quickQuestion, "the file's key overrides F18")
    #expect(catalog.bindings["Z"]?.kind == .command, "Zoxide is blue, as the spec lists it")
    #expect(catalog.bindings["E"]?.label == "Express", "a chord the file does not name still appears")
    #expect(catalog.bindings["D"]?.overlayID == OverlayID.reference && catalog.bindings["D"]?.kind == .surface)
    #expect(catalog.bindings["V"]?.owner == .keyboardMaestro && catalog.bindings["V"]?.kind == .command)
    #expect(catalog.bindings["V"]?.shape == "Deterministic · no notification")
    #expect(catalog.bindings.values.allSatisfy { $0.overlayID != OverlayID.normalizeNote }, "only what registered is drawn")
    #expect(catalog.problems.contains { $0.contains("Collides") && $0.contains("hyper-stash") })
    #expect(catalog.problems.contains { $0.contains("Nowhere") })
    #expect(catalog.bindings.count == 6)
}

@Test func catalogReportsAKeyCodeWithNoCapInsteadOfDrawingIt() {
    let catalog = HyperBindingCatalog.build(registered: [binding(OverlayID.quickQuestion, 79)], file: nil, layout: layout)
    #expect(catalog.bindings.isEmpty)
    #expect(catalog.problems == ["hyper-quick-question: key code 79 has no cap in UK ISO MacBook"])
}

@Test func tintsFollowTheSpecsLists() {
    for surface in [OverlayID.space, OverlayID.clipboard, OverlayID.stash, OverlayID.translate, OverlayID.pronounce,
                    OverlayID.semanticTools, OverlayID.quickQuestion, OverlayID.reference, OverlayID.express, OverlayID.help] {
        #expect(HyperBindingKind.of(overlayID: surface) == .surface, "\(surface)")
    }
    for command in [OverlayID.zoxide, OverlayID.capture, OverlayID.webSearch] {
        #expect(HyperBindingKind.of(overlayID: command) == .command, "\(command)")
    }
}

// MARK: Hold to reveal

private typealias Machine = HyperHoldStateMachine

@Test func holdingPastTheThresholdShowsAndReleasingFadesOut() {
    var machine = Machine()
    #expect(machine.hyperChanged(down: true) == [.startTimer(token: 1)])
    #expect(machine.timerFired(token: 1) == [.present(.held)])
    #expect(machine.presentation == .held)
    #expect(machine.hyperChanged(down: false) == [.hide(fade: true)])
    #expect(machine.presentation == .hidden)
}

@Test func aFluentChordNeverShowsTheOverlay() {
    var machine = Machine()
    _ = machine.hyperChanged(down: true)
    #expect(machine.bindingFired() == [.cancelTimer], "Hyper+L under the threshold")
    #expect(machine.timerFired(token: 1) == [])
    #expect(machine.hyperChanged(down: false) == [])
    // An unbound key also counts as a chord, and a later hold arms afresh.
    _ = machine.hyperChanged(down: true)
    #expect(machine.keyDown() == [.cancelTimer])
    #expect(machine.timerFired(token: 2) == [])
    _ = machine.hyperChanged(down: false)
    #expect(machine.hyperChanged(down: true) == [.startTimer(token: 3)])
    #expect(machine.timerFired(token: 2) == [], "a stale timer is ignored")
    #expect(machine.timerFired(token: 3) == [.present(.held)])
}

@Test func aBoundKeyWhileShownRunsAndHidesAnUnboundKeyChangesNothing() {
    var machine = Machine()
    _ = machine.hyperChanged(down: true)
    _ = machine.timerFired(token: 1)
    #expect(machine.keyDown() == [], "unbound: stays while Hyper is held")
    #expect(machine.presentation == .held)
    #expect(machine.bindingFired() == [.hide(fade: false)])
    #expect(machine.hyperChanged(down: false) == [])
}

@Test func hyperHPinsAndEscapeClosesThePin() {
    var machine = Machine()
    _ = machine.hyperChanged(down: true)
    #expect(machine.helpPressed() == [.cancelTimer, .present(.pinned), .claimEscape], "a fluent Hyper+H pins at once")
    #expect(machine.hyperChanged(down: false) == [], "pinned stays after release")
    #expect(machine.presentation == .pinned)
    #expect(machine.escape() == [.releaseEscape, .hide(fade: false)])
    #expect(machine.escape() == [])
}

@Test func holdingThenPressingHPins() {
    var machine = Machine()
    _ = machine.hyperChanged(down: true)
    _ = machine.timerFired(token: 1)
    #expect(machine.helpPressed() == [.present(.pinned), .claimEscape])
    #expect(machine.hyperChanged(down: false) == [])
    #expect(machine.presentation == .pinned)
}

@Test func hyperDownWhilePinnedBecomesHeldSoAnyChordEndsIt() {
    var machine = Machine()
    _ = machine.helpPressed()
    // Pressing Caps on a pinned overlay draws Caps Lock pressed at once, with
    // no threshold: the overlay is already up.
    #expect(machine.hyperChanged(down: true) == [.releaseEscape, .present(.held)])
    // A Keyboard Maestro chord the host cannot hear (Hyper+S): release ends it.
    #expect(machine.keyDown() == [])
    #expect(machine.hyperChanged(down: false) == [.hide(fade: true)])
    // Hyper+H from pinned toggles it closed.
    _ = machine.helpPressed()
    _ = machine.hyperChanged(down: true)
    #expect(machine.helpPressed() == [.hide(fade: false)])
    #expect(machine.presentation == .hidden)
    // A native chord from pinned runs and closes.
    _ = machine.hyperChanged(down: false)
    _ = machine.helpPressed()
    _ = machine.hyperChanged(down: true)
    #expect(machine.bindingFired() == [.hide(fade: false)])
}

@Test func dismissClosesFromAnyState() {
    var machine = Machine()
    _ = machine.helpPressed()
    #expect(machine.dismiss() == [.releaseEscape, .hide(fade: false)])
    _ = machine.hyperChanged(down: true)
    #expect(machine.dismiss() == [.cancelTimer])
    #expect(machine.timerFired(token: 1) == [])
}
