import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

@MainActor private func nativeKeyPad() throws -> (OmniCommandPadViewController, NSPanel) {
    _ = NSApplication.shared
    let corpus = FrozenContractCorpus()
    let parser = OmniParser(
        manifest: try CommandManifest(data: corpus.data(named: "manifest")),
        references: try ReferenceRegistry([])
    )
    let pad = OmniCommandPadViewController(parser: parser)
    pad.loadView()
    let panel = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    panel.makeKeyAndOrderFront(nil)
    #expect(panel.makeFirstResponder(pad.editor))
    return (pad, panel)
}

@MainActor private func sendNativeKey(
    _ character: String, keyCode: UInt16, to pad: OmniCommandPadViewController,
    in panel: NSPanel, modifiers: NSEvent.ModifierFlags = []
) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil,
        characters: character, charactersIgnoringModifiers: character,
        isARepeat: false, keyCode: keyCode
    ))
    pad.editor.keyDown(with: event)
}

/// AppKit's key interpretation can coalesce a character edit with broad
/// attributed-token changes, unlike a direct insertText call.
@Test @MainActor func padNativeKeyBeforeAnnotatedSpanKeepsNote() throws {
    let (pad, panel) = try nativeKeyPad()
    defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }

    let source = "/email Hey Daniel — would you like to grab coffee Thursday at 15:30?\n\nBest, Mira"
    pad.editor.string = source
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    let span = (source as NSString).range(of: "Thursday at 15:30")
    let note = OmniTextAnnotation(range: span, guidance: "Keep this time")
    pad.setAnnotations([note])
    let insertion = (source as NSString).range(of: "Daniel").location
    pad.editor.setSelectedRange(NSRange(location: insertion, length: 0))
    for (character, keyCode) in [("a", UInt16(0)), ("b", UInt16(11))] {
        try sendNativeKey(character, keyCode: keyCode, to: pad, in: panel)
    }

    #expect(pad.editor.string == (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "ab"))
    #expect(pad.annotations.map(\.id) == [note.id])
    #expect(pad.annotations.first?.range == NSRange(location: span.location + 2, length: span.length))
    #expect(pad.notesButton.title == "1 note")
}

@Test @MainActor func padNativeRepeatedCharacterEditsKeepExactNoteLocation() throws {
    let (pad, panel) = try nativeKeyPad()
    defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }
    let source = "/email aaaa\nnext"
    pad.editor.string = source
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    let run = (source as NSString).range(of: "aaaa")
    let note = OmniTextAnnotation(range: NSRange(location: run.location + 2, length: 1), guidance: "Keep the third a")
    pad.setAnnotations([note])
    pad.editor.setSelectedRange(NSRange(location: run.location + 1, length: 0))

    try sendNativeKey("a", keyCode: 0, to: pad, in: panel)
    #expect(pad.editor.string == (source as NSString).replacingCharacters(in: NSRange(location: run.location + 1, length: 0), with: "a"))
    #expect(pad.annotations.first?.id == note.id)
    #expect(pad.annotations.first?.range == NSRange(location: run.location + 3, length: 1))

    try sendNativeKey("\u{7F}", keyCode: 51, to: pad, in: panel)
    #expect(pad.editor.string == source)
    #expect(pad.annotations.first?.id == note.id)
    #expect(pad.annotations.first?.range == note.range)
}

@Test @MainActor func padNativeKeyUndoRedoRestoreGuidance() throws {
    let (pad, panel) = try nativeKeyPad()
    defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }
    let source = "/email Hello Mira,\n\nThursday at 15:30 works."
    pad.editor.string = source
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    let span = (source as NSString).range(of: "Thursday at 15:30")
    let note = OmniTextAnnotation(range: span, guidance: "Keep the time")
    pad.setAnnotations([note])
    pad.editor.undoManager?.removeAllActions()
    let insertion = (source as NSString).range(of: "Hello").location
    pad.editor.setSelectedRange(NSRange(location: insertion, length: 0))

    try sendNativeKey("a", keyCode: 0, to: pad, in: panel)
    #expect(pad.annotations.first?.range == NSRange(location: span.location + 1, length: span.length))
    #expect(pad.editor.undoManager?.canUndo == true)

    try sendNativeKey("z", keyCode: 6, to: pad, in: panel, modifiers: .command)
    #expect(pad.editor.string == source)
    #expect(pad.annotations == [note])

    try sendNativeKey("Z", keyCode: 6, to: pad, in: panel, modifiers: [.command, .shift])
    #expect(pad.editor.string == (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "a"))
    #expect(pad.annotations.first?.id == note.id)
    #expect(pad.annotations.first?.range == NSRange(location: span.location + 1, length: span.length))
}

@Test @MainActor func coalescedCharacterAndAttributeEditWithoutNativeHintKeepsNote() {
    let editor = OmniCommandTextView()
    let source = "Hello Mira, Thursday at 15:30 works."
    editor.string = source
    let span = (source as NSString).range(of: "Thursday at 15:30")
    let note = OmniTextAnnotation(range: span, guidance: "Keep the time")
    editor.setAnnotations([note])
    let insertion = (source as NSString).range(of: "Mira").location
    guard let storage = editor.textStorage else {
        Issue.record("Missing text storage")
        return
    }

    storage.beginEditing()
    storage.replaceCharacters(in: NSRange(location: insertion, length: 0), with: "a")
    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 19), range: NSRange(location: 0, length: (storage.string as NSString).length))
    storage.endEditing()

    #expect(editor.string == (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "a"))
    #expect(editor.annotations.first?.id == note.id)
    #expect(editor.annotations.first?.range == NSRange(location: span.location + 1, length: span.length))
}
