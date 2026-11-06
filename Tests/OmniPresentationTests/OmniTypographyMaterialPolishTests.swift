import AppKit
import Foundation
import OmniCore
@testable import OmniPresentation
import Testing

@MainActor private func materialMaskAlpha(_ mask: NSImage, x: Int, y: Int) throws -> CGFloat {
    let data = try #require(mask.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    return try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
}

@Test @MainActor func frostedSurfaceMasksMaterialAndWindowShadowAtItsRoundedCorners() throws {
    _ = NSApplication.shared
    let surface = OmniFrostedSurface(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        surface.appearance = NSAppearance(named: appearance)
        for treatment in [OmniMaterialTreatment.nativeMaterial, .opaqueFallback] {
            surface.apply(transparency: treatment)
            let mask = try #require(surface.maskImage)
            #expect(mask.size == surface.bounds.size)
            #expect(try materialMaskAlpha(mask, x: 0, y: 0) < 0.05)
            #expect(try materialMaskAlpha(mask, x: 30, y: 30) > 0.95)
            #expect(surface.layer?.cornerRadius == OmniFrostedStyle.cornerRadius)
            #expect(surface.layer?.masksToBounds == true)
        }
        surface.setFrameSize(NSSize(width: 400, height: 160))
        #expect(surface.frame.size == NSSize(width: 400, height: 160))
        #expect(surface.maskImage?.size == surface.bounds.size)
        surface.setBoundsSize(NSSize(width: 380, height: 150))
        let resizedMask = try #require(surface.maskImage)
        #expect(resizedMask.size == surface.bounds.size)
        #expect(try materialMaskAlpha(resizedMask, x: 0, y: 0) < 0.05)
        #expect(try materialMaskAlpha(resizedMask, x: 30, y: 30) > 0.95)
    }
}

@Test @MainActor func frostedSurfaceCornersKeepMaterialClipWithoutBrightRim() throws {
    _ = NSApplication.shared
    let surface = OmniFrostedSurface(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    let layer = try #require(surface.layer)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        surface.appearance = NSAppearance(named: appearance)
        surface.apply(transparency: .nativeMaterial)
        #expect(layer.masksToBounds)
        #expect(layer.cornerRadius == OmniFrostedStyle.cornerRadius)
        #expect(layer.borderWidth == 0)
        #expect(layer.borderColor == nil)

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = surface.bounds.size
        surface.effectiveAppearance.performAsCurrentDrawingAppearance {
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
        }
        let corner = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        let edge = try #require(bitmap.colorAt(x: 200, y: 0)?.usingColorSpace(.deviceRGB))
        let inside = try #require(bitmap.colorAt(x: 200, y: 2)?.usingColorSpace(.deviceRGB))
        #expect(corner.alphaComponent < 0.05)
        #expect(edge.alphaComponent > 0.95 && inside.alphaComponent > 0.95)
        #expect(abs(edge.redComponent - inside.redComponent) < 0.03)
        #expect(abs(edge.greenComponent - inside.greenComponent) < 0.03)
        #expect(abs(edge.blueComponent - inside.blueComponent) < 0.03)

        surface.setFrameSize(NSSize(width: 400, height: 160))
        surface.layoutSubtreeIfNeeded()
        #expect(surface.bounds.size == NSSize(width: 400, height: 160))
        #expect(layer.cornerRadius == OmniFrostedStyle.cornerRadius)
        #expect(layer.masksToBounds)

        surface.apply(transparency: .opaqueFallback)
        #expect(layer.borderWidth == 1)
        #expect(layer.borderColor != nil)
    }
}

@MainActor private func typographyPad() throws -> (OmniCommandPadViewController, NSPanel) {
    _ = NSApplication.shared
    let corpus = FrozenContractCorpus()
    let parser = OmniParser(manifest: try CommandManifest(data: corpus.data(named: "manifest")), references: try ReferenceRegistry([]))
    let pad = OmniCommandPadViewController(parser: parser)
    pad.loadView()
    let panel = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    return (pad, panel)
}

@MainActor private func renderedFont(_ pad: OmniCommandPadViewController, at location: Int = 0) throws -> NSFont {
    let storage = try #require(pad.editor.textStorage)
    return try #require(storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
}

@Test @MainActor func padTypographyMultilineKeepsTextSelectionAnnotationsAndSubmit() throws {
    let (pad, panel) = try typographyPad()
    defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }
    let text = "Hi Mira,\n\nThursday after 16:00 works. I’m looking forward to discussing the prototype and the next steps.\n\n/email accept the invitation /style:formal"
    let canonical = pad.parser.parse(text).canonicalText
    let selected = (text as NSString).range(of: "16:00")
    pad.setProvenance(.init(source: "Mail", detail: "Mira Chen", wordCount: 30))
    pad.editor.string = text
    pad.editor.setSelectedRange(selected)
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    let note = OmniTextAnnotation(range: selected, guidance: "Keep the time constraint.")
    pad.setAnnotations([note])

    #expect(pad.editor.string == text)
    #expect(pad.editor.selectedRange() == selected)
    #expect(pad.annotations.map(\.id) == [note.id])
    #expect(pad.annotations.first?.range == selected)
    #expect(pad.provenance?.source == "Mail")
    let body = try renderedFont(pad)
    #expect(body.pointSize >= 17 && body.pointSize <= 20)
    let token = try renderedFont(pad, at: (text as NSString).range(of: "/email").location)
    #expect(token.pointSize == body.pointSize)
    #expect(token.fontName != body.fontName)
    #expect((pad.editor.typingAttributes[.font] as? NSFont)?.pointSize == body.pointSize)

    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        try polishCapture(pad.view, name: "pad2-source-\(suffix)", appearance: appearance)
    }
    var submitted: String?
    pad.onSubmit = { value, _ in submitted = value }
    pad.runButton.performClick(nil)
    #expect(submitted == canonical)
}

@Test @MainActor func padTypographyUndoRestoresShortCommandScale() throws {
    let (pad, panel) = try typographyPad()
    defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }
    let original = "/email accept the invitation"
    pad.editor.string = original
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    #expect(try renderedFont(pad).pointSize == 22)
    panel.makeFirstResponder(pad.editor)
    let undo = try #require(pad.editor.undoManager)
    undo.removeAllActions()
    pad.editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
    undo.beginUndoGrouping()
    pad.editor.insertText("\n\nThank you for the invitation. Thursday works well for me.", replacementRange: pad.editor.selectedRange())
    undo.endUndoGrouping()
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    #expect(try renderedFont(pad).pointSize < 22)
    #expect(undo.canUndo)
    undo.undo()
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    #expect(pad.editor.string == original)
    #expect(try renderedFont(pad).pointSize == 22)
    #expect((pad.editor.typingAttributes[.font] as? NSFont)?.pointSize == 22)
}

@Test @MainActor func padTypographyCompletionRetainsMultilineSourceAndAnchor() throws {
    let (pad, panel) = try typographyPad()
    defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }
    (pad.view as? OmniFrostedSurface)?.apply(transparency: .opaqueFallback)
    let source = "Hi Mira,\n\nThursday after 16:00 works. I look forward to discussing the next steps.\n\n/email accept the invitation"
    pad.editor.string = source
    pad.editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    let top = panel.frame.maxY
    pad.editor.insertText(" /t", replacementRange: pad.editor.selectedRange())
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    #expect(pad.editor.string == source + " /t")
    #expect(pad.editor.selectedRange() == NSRange(location: ((source + " /t") as NSString).length, length: 0))
    #expect(pad.isCompletionVisible)
    #expect(pad.completionChoices.contains { $0.canonicalText == "/translate" })
    #expect(pad.routeLine.text == "Type a command")
    #expect(abs(panel.frame.maxY - top) < 1)
    #expect(try renderedFont(pad).pointSize < 22)
    #expect(pad.editorScrollView!.frame.minY >= pad.keyHintsView.frame.maxY)
    try polishCapture(pad.view, name: "pad2-source-completion-light", appearance: .aqua)
}

@Test @MainActor func padTypographyAnnotationEditsWaitForMeasuredPresentation() throws {
    let (pad, panel) = try typographyPad()
    defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }
    let source = "/email Hello Mira,\n\nThursday after 16:00 works well for me."
    pad.editor.string = source
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    let span = (source as NSString).range(of: "16:00")
    let timeNote = OmniTextAnnotation(range: span, guidance: "Keep the time")
    pad.setAnnotations([timeNote])
    #expect(!pad.notesButton.isHidden)
    pad.showAnnotationHover(timeNote.id)
    _ = try #require(pad.annotationHoverPanel)
    var observed: [OmniTextAnnotation]?
    var hoverRetainedDuringEdit = false
    var storageCallbackObserved = false
    pad.onAnnotationsChanged = {
        observed = $0
        if pad.editor.isProcessingCharacterEdit {
            storageCallbackObserved = true
            hoverRetainedDuringEdit = pad.annotationHoverPanel != nil
        }
    }

    // This is the first half of a native/host text edit: storage and annotation
    // data change before NSTextView's didChange notification measures the UI.
    let storage = try #require(pad.editor.textStorage)
    storage.replaceCharacters(in: span, with: "")
    #expect(pad.annotations.isEmpty)
    #expect(observed?.isEmpty == true)
    #expect(storageCallbackObserved)
    #expect(hoverRetainedDuringEdit)
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    #expect(pad.notesButton.isHidden)
    #expect(pad.annotationHoverPanel == nil)
    #expect(pad.editor.string == (source as NSString).replacingCharacters(in: span, with: ""))

    let nextSpan = (pad.editor.string as NSString).range(of: "Thursday")
    let note = OmniTextAnnotation(range: nextSpan, guidance: "Keep the day")
    pad.setAnnotations([note])
    #expect(!pad.notesButton.isHidden)
    pad.editor.setSelectedRange(NSRange(location: 0, length: 0))
    pad.editor.insertText("Hello, ", replacementRange: pad.editor.selectedRange())
    pad.textDidChange(Notification(name: NSText.didChangeNotification, object: pad.editor))
    #expect(pad.annotations.first?.id == note.id)
    #expect(pad.annotations.first?.range.location == nextSpan.location + 7)
    #expect(!pad.notesButton.isHidden)
    #expect(try renderedFont(pad).pointSize < 22)
    try polishCapture(pad.view, name: "pad2-source-annotated-edit-light", appearance: .aqua)
}

/// Render the actual custom control on a solid ground, without relying on the
/// visual-effect cache's treatment of composited window layers.
@MainActor private func paintedControl(_ view: NSView, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
    let width = Int(view.bounds.width)
    let height = Int(view.bounds.height)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    view.appearance = NSAppearance(named: appearance)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        (appearance == .aqua ? NSColor.white : NSColor.black).setFill()
        view.bounds.fill()
        view.draw(view.bounds)
    }
    return bitmap
}

@Test @MainActor func padMaterialControlsKeepTheirShapeOnSolidLightAndDarkGrounds() throws {
    let hints = OmniKeyHintsView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
    hints.hints = [.init("esc", "")]
    let provenance = OmniProvenanceChip()
    provenance.frame = NSRect(x: 0, y: 0, width: 210, height: 26)
    provenance.provenance = .init(source: "Mail", detail: "Mira Chen", wordCount: 30)
    let scope = OmniLauncherScopeChip(frame: NSRect(x: 0, y: 0, width: 110, height: 26))
    for (name, control, sample) in [
        ("keycap", hints as NSView, NSPoint(x: 67, y: 1)),
        ("provenance", provenance as NSView, NSPoint(x: 100, y: 0)),
        ("scope", scope as NSView, NSPoint(x: 55, y: 0)),
    ] {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let bitmap = try paintedControl(control, appearance: appearance)
            let color = try #require(bitmap.colorAt(x: Int(sample.x), y: Int(sample.y))?.usingColorSpace(.deviceRGB))
            if appearance == .aqua {
                #expect(max(color.redComponent, color.greenComponent, color.blueComponent) < 0.98)
            } else {
                #expect(min(color.redComponent, color.greenComponent, color.blueComponent) > 0.02)
            }
            if let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("pad2-\(name)-solid-\(suffix).png"))
            }
        }
    }
}
