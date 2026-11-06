import AppKit
import OmniCore
import OmniPresentation
import Testing

@MainActor private func annotationParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    let references = try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)])
    return OmniParser(manifest: manifest, references: references)
}

@MainActor private func annotationView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = annotationView(id, in: child) { return found }
    }
    return nil
}

@Suite(.serialized) struct OmniAnnotationsTests {

@Test @MainActor func annotationShortcutOpensCardWithoutEditMenu() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try annotationParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    _ = window
    pad.editor.string = "Write a reply about Thursday /email"
    pad.editor.reconcileAnnotations()
    pad.editor.setSelectedRange(NSRange(location: 20, length: 8))
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "K", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
    let oldMenu = NSApp.mainMenu
    NSApp.mainMenu = nil
    defer { NSApp.mainMenu = oldMenu }
    pad.editor.keyDown(with: event)
    #expect(pad.annotationCardPanel != nil)
    #expect(pad.annotationCardPanel?.contentView?.accessibilityIdentifier() == "omni.annotation.card")
}

@Test @MainActor func noteFieldEditorEnterAttachesAndEscapeCancels() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try annotationParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    _ = window
    pad.editor.string = "/email Reply kindly"
    pad.editor.setSelectedRange(NSRange(location: 7, length: 5))
    pad.openAnnotationForSelection()
    let card = try #require(pad.annotationCardPanel)
    let input = try #require(card.contentView?.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    let fieldEditor = try #require(card.fieldEditor(true, for: input) as? NSTextView)
    input.stringValue = "Keep it short"
    fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(pad.annotations.count == 1)
    #expect(pad.annotations.first?.guidance == "Keep it short")

    pad.editor.setSelectedRange(NSRange(location: 13, length: 6))
    pad.openAnnotationForSelection()
    let secondCard = try #require(pad.annotationCardPanel)
    let secondInput = try #require(secondCard.contentView?.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    let secondEditor = try #require(secondCard.fieldEditor(true, for: secondInput) as? NSTextView)
    secondEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    #expect(pad.annotationCardPanel == nil)
    #expect(pad.annotations.count == 1)
}

@Test @MainActor func annotationTextEditsAndNoteUndoPreserveRanges() {
    let editor = OmniCommandTextView()
    editor.string = "abcdef"
    let note = OmniTextAnnotation(range: NSRange(location: 2, length: 3), guidance: "Keep this")
    editor.setAnnotations([note])
    editor.textStorage?.replaceCharacters(in: NSRange(location: 2, length: 0), with: "X")
    #expect(editor.annotations.first?.range == NSRange(location: 3, length: 3))
    editor.textStorage?.replaceCharacters(in: NSRange(location: 5, length: 0), with: "Y")
    #expect(editor.annotations.first?.range == NSRange(location: 3, length: 4))
    editor.textStorage?.replaceCharacters(in: NSRange(location: 3, length: 3), with: "")
    #expect(editor.annotations.first?.range == NSRange(location: 3, length: 1))
    editor.textStorage?.replaceCharacters(in: NSRange(location: 3, length: 1), with: "")
    #expect(editor.annotations.isEmpty)
    editor.undoManager?.removeAllActions()
    let another = OmniTextAnnotation(range: NSRange(location: 1, length: 2), guidance: "Another")
    editor.changeAnnotations([another])
    #expect(editor.annotations == [another])
    editor.undoManager?.undo()
    #expect(editor.annotations.isEmpty)
    editor.undoManager?.redo()
    #expect(editor.annotations == [another])
}

@Test @MainActor func repeatedCharactersUseExactEditRangeAndWholeSpanUndo() {
    let editor = OmniCommandTextView()
    editor.allowsUndo = true
    editor.string = "aaaa"
    let note = OmniTextAnnotation(range: NSRange(location: 2, length: 1), guidance: "Third a")
    editor.setAnnotations([note])
    editor.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
    #expect(editor.annotations.first?.range == NSRange(location: 1, length: 1))
    editor.undoManager?.removeAllActions()

    editor.setSelectedRange(NSRange(location: 1, length: 1))
    editor.insertText("", replacementRange: NSRange(location: 1, length: 1))
    #expect(editor.annotations.isEmpty)
    editor.undoManager?.undo()
    #expect(editor.string == "aaa")
    #expect(editor.annotations.first?.range == NSRange(location: 1, length: 1))
    editor.undoManager?.redo()
    #expect(editor.string == "aa")
    #expect(editor.annotations.isEmpty)
}

@Test @MainActor func markedCompositionRemapsInsideAndBesideSpan() {
    let editor = OmniCommandTextView()
    editor.string = "ab cd"
    let note = OmniTextAnnotation(range: NSRange(location: 3, length: 2), guidance: "Keep")
    editor.setAnnotations([note])
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    editor.setMarkedText("¨", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 4, length: 0))
    #expect(editor.annotations.first?.range == NSRange(location: 3, length: 3))
    editor.setMarkedText("ä", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 4, length: 1))
    editor.unmarkText()
    #expect(editor.annotations.first?.range == NSRange(location: 3, length: 3))
    editor.setSelectedRange(NSRange(location: 3, length: 0))
    editor.setMarkedText("é", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 3, length: 0))
    editor.unmarkText()
    #expect(editor.annotations.first?.range == NSRange(location: 4, length: 3))
}

@Test @MainActor func padRestyleKeepsNoteAndTokenPaint() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try annotationParser())
    pad.loadView()
    let text = "/email send to Zoe"
    pad.editor.string = text
    let note = OmniTextAnnotation(range: NSRange(location: 1, length: 4), guidance: "Be gentle")
    pad.setAnnotations([note])
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    #expect(pad.annotations == [note])
    #expect(pad.notesButton.title == "1 note")
    let tokenPaint = pad.editor.textStorage?.attribute(.backgroundColor, at: 1, effectiveRange: nil) as? NSColor
    #expect(tokenPaint != nil)
    #expect(pad.editor.frame.width > 0)
    #expect(pad.view.frame.width == OmniCommandPadViewController.preferredWidth)
}

@Test @MainActor func annotationHoverHitsPaintedSpanButNotBlankLineArea() throws {
    let editor = OmniCommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
    editor.textContainer?.containerSize = NSSize(width: 390, height: 80)
    editor.string = "annotated text"
    let note = OmniTextAnnotation(range: NSRange(location: 0, length: 9), guidance: "Keep this")
    editor.setAnnotations([note])
    let layout = try #require(editor.layoutManager)
    let container = try #require(editor.textContainer)
    layout.ensureLayout(for: container)
    let glyphs = layout.glyphRange(forCharacterRange: note.range, actualCharacterRange: nil)
    let painted = layout.boundingRect(forGlyphRange: glyphs, in: container)
        .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
    #expect(editor.annotationID(at: NSPoint(x: painted.midX, y: painted.midY)) == note.id)
    #expect(editor.annotationID(at: NSPoint(x: editor.bounds.maxX - 8, y: painted.midY)) == nil)
}

@Test @MainActor func annotationSelectionMarkSitsAtEndOfMultilineSelection() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try annotationParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    _ = window
    let text = "First line of the message\nSecond line contains the selected end"
    pad.editor.string = text
    let selection = NSRange(location: 0, length: (text as NSString).length)
    pad.editor.setSelectedRange(selection)
    pad.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: pad.editor))
    let mark = try #require(pad.editor.subviews.first { $0.accessibilityIdentifier() == "omni.annotation.mark" })
    let lastRect = pad.editor.firstRect(forCharacterRange: NSRange(location: selection.upperBound - 1, length: 1), actualRange: nil)
    let firstRect = pad.editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
    let lastWindowPoint = window.convertPoint(fromScreen: NSPoint(x: lastRect.maxX, y: lastRect.minY))
    let expected = pad.editor.convert(lastWindowPoint, from: nil)
    #expect(abs(mark.frame.minX - (expected.x + 3)) < 2)
    #expect(abs(mark.frame.midY - (expected.y + 1)) < 2)
    #expect(abs(lastRect.minY - firstRect.minY) > 8)
}

@Test @MainActor func boundEditorWindowDeliversMouseMovedEvents() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try annotationParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    window.orderFrontRegardless()
    pad.editor.updateTrackingAreas()
    #expect(window.acceptsMouseMovedEvents)
    pad.editor.string = "annotated text /email"
    let note = OmniTextAnnotation(range: NSRange(location: 0, length: 9), guidance: "Keep")
    pad.setAnnotations([note])
    let layout = try #require(pad.editor.layoutManager)
    let container = try #require(pad.editor.textContainer)
    layout.ensureLayout(for: container)
    let glyphs = layout.glyphRange(forCharacterRange: note.range, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        .offsetBy(dx: pad.editor.textContainerOrigin.x, dy: pad.editor.textContainerOrigin.y)
    let point = pad.editor.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    var observed: UUID?
    pad.editor.onAnnotationHover = { observed = $0 }
    let event = try #require(NSEvent.mouseEvent(
        with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 0, pressure: 0
    ))
    window.sendEvent(event)
    #expect(observed == note.id)
}

@Test @MainActor func longHoverGuidanceIsScrollableAndComplete() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try annotationParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    _ = window
    pad.editor.string = "/email reply to Mira"
    let guidance = Array(repeating: "Preserve the Bessel reference while declining Thursday before 16:00.", count: 18).joined(separator: " ")
    let note = OmniTextAnnotation(range: NSRange(location: 7, length: 5), guidance: guidance)
    pad.setAnnotations([note])
    pad.showAnnotationHover(note.id)
    let panel = try #require(pad.annotationHoverPanel)
    #expect(panel.frame.height == 240)
    let scroll = try #require(panel.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
    #expect(scroll.hasVerticalScroller)
    #expect((scroll.documentView as? NSTextField)?.stringValue == guidance)
    #expect(scroll.documentView?.frame.height ?? 0 > scroll.frame.height)
    pad.closeAnnotationPanels()
}

@Test @MainActor func hoverPanelExitDismissesAwayFromPanelAndAnnotatedSpan() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try annotationParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    pad.editor.string = "/email reply to Mira"
    let note = OmniTextAnnotation(range: NSRange(location: 7, length: 5), guidance: "Keep this phrase")
    pad.setAnnotations([note])
    pad.showAnnotationHover(note.id)
    let panel = try #require(pad.annotationHoverPanel)
    let root = try #require(panel.contentView)
    let exit = try #require(NSEvent.enterExitEvent(
        with: .mouseExited, location: NSPoint(x: -1_000, y: -1_000), modifierFlags: [], timestamp: 0,
        windowNumber: panel.windowNumber, context: nil,
        eventNumber: 0, trackingNumber: 1, userData: nil
    ))
    root.mouseExited(with: exit)
    #expect(pad.annotationHoverPanel == nil)
}

@Test @MainActor func overflowingOverviewOpensAtFirstAnnotation() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try annotationParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    let words = (0..<12).map { "note\($0)" }
    let text = "/email " + words.joined(separator: " ")
    pad.editor.string = text
    let source = text as NSString
    pad.setAnnotations(words.enumerated().map { index, word in
        OmniTextAnnotation(range: source.range(of: word), guidance: "Guidance \(index)")
    })
    pad.notesButton.performClick(nil)
    let panel = try #require(pad.annotationOverviewPanel)
    let scroll = try #require(panel.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
    let rows = try #require(scroll.documentView)
    let first = try #require(annotationView("omni.annotation.overview-row.0", in: rows))
    let last = try #require(annotationView("omni.annotation.overview-row.11", in: rows))
    let visible = scroll.contentView.bounds
    #expect(panel.frame.height == 440)
    #expect(visible.intersects(first.frame))
    #expect(!visible.intersects(last.frame))
}

@Test @MainActor func hoverReopensAfterCloseAndOverviewButtonsActOnNotes() throws {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try annotationParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    _ = window
    let text = "/email first second"
    pad.editor.string = text
    let first = OmniTextAnnotation(range: NSRange(location: 7, length: 5), guidance: "Keep the first phrase intact")
    let second = OmniTextAnnotation(range: NSRange(location: 13, length: 6), guidance: "This is a long note that should wrap to another line without clipping the guidance or hiding its controls.")
    pad.setAnnotations([first, second])

    pad.showAnnotationHover(first.id)
    #expect(pad.annotationHoverPanel != nil)
    pad.closeAnnotationPanels()
    pad.showAnnotationHover(first.id)
    #expect(pad.annotationHoverPanel != nil)
    pad.closeAnnotationPanels()

    pad.notesButton.performClick(nil)
    let overview = try #require(pad.annotationOverviewPanel?.contentView)
    let row = try #require(annotationView("omni.annotation.overview-row.1", in: overview))
    let remove = try #require(annotationView("omni.annotation.remove.1", in: overview) as? NSButton)
    let edit = try #require(annotationView("omni.annotation.edit.1", in: overview) as? NSButton)
    #expect(remove.isEnabled && !remove.isHidden && row.bounds.contains(NSPoint(x: remove.frame.midX, y: remove.frame.midY)))
    #expect(edit.isEnabled && !edit.isHidden && row.bounds.contains(NSPoint(x: edit.frame.midX, y: edit.frame.midY)))
    edit.performClick(nil)
    #expect(pad.annotationCardPanel != nil)
    pad.closeAnnotationPanels()
    pad.notesButton.performClick(nil)
    let updatedOverview = try #require(pad.annotationOverviewPanel?.contentView)
    let updatedRemove = try #require(annotationView("omni.annotation.remove.1", in: updatedOverview) as? NSButton)
    updatedRemove.performClick(nil)
    #expect(pad.annotations == [first])
    pad.closeAnnotationPanels()
}

@Test @MainActor func workspaceComposerNotesAndHistoricalInput() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900), parser: try annotationParser())
    defer { workspace.hideWorkspace() }
    let note = OmniTextAnnotation(range: NSRange(location: 8, length: 5), guidance: "Keep this")
    var saved: [OmniTextAnnotation] = []
    var savedText = ""
    workspace.onAnnotationsChanged = { saved = $0 }
    workspace.onComposerTextChanged = { savedText = $0 }
    workspace.showComposer(text: "/shorter Bessel update", runID: "r1", sourceVersion: 1, annotations: [note])
    #expect(workspace.annotations == [note])
    #expect(saved == [note])
    workspace.editor.string = "/shorter Bessel update!"
    workspace.textDidChange(Notification(name: NSText.didChangeNotification, object: workspace.editor))
    #expect(savedText == workspace.editor.string)
    workspace.displayResult(runID: "r1", title: "Draft", status: "done",
                            versions: [OmniWorkspaceVersion(number: 1, inputText: "/email Bessel update", resultText: "Done", operation: "initial", annotations: [note])],
                            selectedVersion: 1)
    #expect(workspace.displayedVersions.first?.annotations == [note])
}

}
