import Foundation
import Testing
@testable import HyperOverlayCore

/// The owner's live Keyboard Maestro manifest. Tests that read it are parity
/// checks against the installed machine and skip where the file is absent.
private let liveManifestURL = ProcessInfo.processInfo.environment["HYPER_OVERLAY_TEST_MANIFEST"]
    .map { URL(fileURLWithPath: $0) }
    ?? OverlayPaths.keyboardMaestroRoot.appendingPathComponent("hyper-overlays.json")
private let requiresLiveManifest: ConditionTrait = .enabled(
    if: FileManager.default.fileExists(atPath: liveManifestURL.path),
    "live Keyboard Maestro manifest is not installed on this machine"
)

private enum FixtureError: Error {
    case missingOverlay(String)
    case missingNativeHotkey(String)
}

private func mutatedLiveManifest(
    overlayID: String,
    mutate: (inout [String: Any]) -> Void
) throws -> Data {
    var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: liveManifestURL)) as! [[String: Any]]
    guard let index = rows.firstIndex(where: { $0["id"] as? String == overlayID }) else {
        throw FixtureError.missingOverlay(overlayID)
    }
    guard var nativeHotkey = rows[index]["native_hotkey"] as? [String: Any] else {
        throw FixtureError.missingNativeHotkey(overlayID)
    }

    mutate(&nativeHotkey)
    rows[index]["native_hotkey"] = nativeHotkey
    return try JSONSerialization.data(withJSONObject: rows)
}

@Test(requiresLiveManifest) func manifestIncludesClipboardWithoutChangingExistingChords() throws {
    let bindings = try HotKeyManifest.load(from: liveManifestURL)

    #expect(bindings.count == 26)
    #expect(Set(bindings.map(\.overlayID)) == OverlayID.hotkeyIDs.subtracting([OverlayID.normalizeNote, OverlayID.referenceSheet]))
    // Collect (H19): C, V, B, - and = on all four Hyper modifiers; 0 unbound.
    // Clear left ⌫ (51): macOS never delivers ⌃⌥⇧⌘⌫ to a global hotkey.
    #expect(bindings.first { $0.overlayID == OverlayID.collectAdd }?.chord.keyCode == 8)
    #expect(bindings.first { $0.overlayID == OverlayID.collectNext }?.chord.keyCode == 9)
    #expect(bindings.first { $0.overlayID == OverlayID.collectAll }?.chord.keyCode == 11)
    #expect(bindings.first { $0.overlayID == OverlayID.collectClear }?.chord.keyCode == 27)
    #expect(!bindings.contains { $0.chord.keyCode == 51 })
    #expect(bindings.first { $0.overlayID == OverlayID.equalize }?.chord.keyCode == 24)
    // The former KM utilities (plan f71f8baac8f0149e); A and Q are retired.
    let keys: [String: UInt32] = [OverlayID.reveal: 15, OverlayID.openNaturally: 31, OverlayID.jumpToRoot: 38,
                                  OverlayID.editInSublime: 1, OverlayID.terminalHere: 17, OverlayID.copyPath: 35,
                                  OverlayID.fence: 13, OverlayID.gatherFiles: 5]
    for (id, keyCode) in keys {
        #expect(bindings.first { $0.overlayID == id }?.chord.keyCode == keyCode, "\(id)")
    }
    #expect(!bindings.contains { $0.chord.keyCode == 0 || $0.chord.keyCode == 12 }, "Hyper+A and Hyper+Q stay unbound")
    #expect(!bindings.contains { $0.chord.keyCode == 29 })
    #expect(!bindings.contains { $0.overlayID == OverlayID.normalizeNote })
    #expect(!bindings.contains { $0.chord.keyCode == 33 })
    #expect(bindings.first { $0.overlayID == OverlayID.reference }?.chord.keyCode == 30)
    #expect(bindings.first { $0.overlayID == OverlayID.capture }?.chord.keyCode == 45)
    #expect(bindings.first { $0.overlayID == OverlayID.pronounce }?.chord.keyCode == 32)
    #expect(bindings.first { $0.overlayID == OverlayID.express }?.chord.keyCode == 14)
    // Stash took Hyper+Y (yank, C92); Clipboard moved to Hyper+' (2026-10-26).
    #expect(bindings.first { $0.overlayID == OverlayID.clipboard }?.chord.keyCode == 39)
    #expect(bindings.first { $0.overlayID == OverlayID.stash }?.chord.keyCode == 16)
    // Karabiner translates the user-facing Hyper+/? chord to Hyper+F18.
    #expect(bindings.first { $0.overlayID == OverlayID.quickQuestion }?.chord.keyCode == 79)
    #expect(!bindings.contains { $0.chord.keyCode == 40 })
}

@Test(requiresLiveManifest) func decoderRejectsInvalidHotkeyFields() throws {
    let unknownModifier = try mutatedLiveManifest(overlayID: OverlayID.reference) {
        $0["modifiers"] = ["caps_lock"]
    }
    let invalidKeyCode = try mutatedLiveManifest(overlayID: OverlayID.reference) {
        $0["key_code"] = 128
    }
    let emptyModifiers = try mutatedLiveManifest(overlayID: OverlayID.reference) {
        $0["modifiers"] = []
    }
    let duplicateModifier = try mutatedLiveManifest(overlayID: OverlayID.reference) {
        $0["modifiers"] = ["command", "command"]
    }

    #expect(throws: Error.self) { try HotKeyManifest.decode(unknownModifier) }
    #expect(throws: Error.self) { try HotKeyManifest.decode(invalidKeyCode) }
    #expect(throws: Error.self) { try HotKeyManifest.decode(emptyModifiers) }
    #expect(throws: Error.self) { try HotKeyManifest.decode(duplicateModifier) }
}

@Test func modifierOrderingProducesTheSameChord() {
    let ordered = HotKeyChord(keyCode: 30, modifiers: [.command, .option, .control, .shift])
    let reordered = HotKeyChord(keyCode: 30, modifiers: [.shift, .control, .option, .command])

    #expect(ordered == reordered)
    #expect(ordered.modifiers == [.command, .option, .control, .shift])
}

@Test(requiresLiveManifest) func reorderedModifiersStillCollideInTheManifest() throws {
    let collision = try mutatedLiveManifest(overlayID: OverlayID.help) {
        $0["key_code"] = 30
        $0["modifiers"] = ["shift", "control", "option", "command"]
    }

    #expect(throws: Error.self) { try HotKeyManifest.decode(collision) }
}

@Test(requiresLiveManifest) func disabledBindingsDoNotReserveTheirFormerChord() throws {
    let disabledCollision = try mutatedLiveManifest(overlayID: OverlayID.normalizeNote) {
        $0["key_code"] = 30
    }

    #expect(try HotKeyManifest.decode(disabledCollision).count == 26)
    let reenabledCollision = try mutatedLiveManifest(overlayID: OverlayID.normalizeNote) {
        $0["enabled"] = true
    }
    #expect(throws: Error.self) { try HotKeyManifest.decode(reenabledCollision) }
    let invalidDisabledField = try mutatedLiveManifest(overlayID: OverlayID.normalizeNote) {
        $0["key_code"] = 128
    }
    #expect(throws: Error.self) { try HotKeyManifest.decode(invalidDisabledField) }
}
