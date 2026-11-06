import AppKit
import OmniCore
import OmniPresentation
import Testing

@MainActor
private func polishAnnotationParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    let references = try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)])
    return OmniParser(manifest: manifest, references: references)
}

@MainActor
private func polishAnnotationFixture() throws -> (OmniCommandPadViewController, NSPanel) {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try polishAnnotationParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    pad.editor.string = "/email reply to Mira"
    return (pad, window)
}

@Test @MainActor func annotationPolishShortHoverAlignsRemoveAndKeepsAction() throws {
    let (pad, window) = try polishAnnotationFixture()
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    let note = OmniTextAnnotation(range: NSRange(location: 7, length: 5), guidance: "Keep the Bessel reference")
    pad.setAnnotations([note])
    pad.showAnnotationHover(note.id)
    let panel = try #require(pad.annotationHoverPanel)
    let root = try #require(panel.contentView)
    let remove = try #require(root.subviews.first { $0.accessibilityIdentifier() == "omni.annotation.hover-remove" } as? NSButton)
    #expect(panel.frame.height == 44)
    #expect(abs(remove.frame.maxY - (root.bounds.maxY - 10)) < 1)
    #expect(remove.frame.width == 22 && remove.frame.height == 22)
    try polishCapture(root, name: "annotation-polish-short-hover-light", appearance: .aqua)
    try polishCapture(root, name: "annotation-polish-short-hover-dark", appearance: .darkAqua)
    remove.performClick(nil)
    #expect(pad.annotations.isEmpty)
}

@Test @MainActor func annotationPolishLongHoverMeasuresRenderedWidthAndScrollsToLastLine() throws {
    let (pad, window) = try polishAnnotationFixture()
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    let finalMarker = "FINAL: The reply must end with a proposed time after 16:00."
    let middle = Array(repeating: "Preserve the Bessel reference while declining Thursday before 16:00.", count: 18).joined(separator: " ")
    let guidance = "BEGIN: Keep the Bessel reference. \(middle) \(finalMarker)"
    let note = OmniTextAnnotation(range: NSRange(location: 7, length: 5), guidance: guidance)
    pad.setAnnotations([note])
    pad.showAnnotationHover(note.id)
    let panel = try #require(pad.annotationHoverPanel)
    let root = try #require(panel.contentView)
    let scroll = try #require(root.subviews.compactMap { $0 as? NSScrollView }.first)
    let text = try #require(scroll.documentView as? NSTextField)
    let renderedWidth = scroll.contentSize.width - 14
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let measured = ceil((guidance as NSString).boundingRect(
        with: NSSize(width: renderedWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph],
        context: nil
    ).height)
    #expect(text.frame.width == renderedWidth)
    #expect(text.stringValue.hasPrefix("BEGIN:"))
    #expect(text.stringValue.hasSuffix(finalMarker))
    let cellHeight = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: renderedWidth, height: .greatestFiniteMagnitude)).height ?? measured
    #expect(text.frame.height >= max(measured, cellHeight) + 8)
    #expect(text.frame.height > scroll.contentView.bounds.height)
    try polishCapture(root, name: "annotation-polish-long-hover-top-light", appearance: .aqua)
    let visualEndY = text.isFlipped ? max(0, text.frame.height - scroll.contentView.bounds.height) : 0
    scroll.contentView.scroll(to: NSPoint(x: 0, y: visualEndY))
    scroll.reflectScrolledClipView(scroll.contentView)
    if text.isFlipped {
        #expect(scroll.contentView.bounds.maxY >= text.frame.height - 1)
    } else {
        #expect(scroll.contentView.bounds.minY <= 1)
    }
    try polishCapture(root, name: "annotation-polish-long-hover-bottom-light", appearance: .aqua)
    try polishCapture(root, name: "annotation-polish-long-hover-bottom-dark", appearance: .darkAqua)
}
