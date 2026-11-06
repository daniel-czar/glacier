import AppKit
import Foundation
import OmniPresentation
import Testing
import Vision

@Test @MainActor func qrNativeEditorEditsReachGenerationWithoutResettingTextOrCaret() throws {
    _ = NSApplication.shared
    let window = OmniQRWindowController(presentsInterface: false)
    var copies = 0
    window.writePasteboardItem = { _ in copies += 1; return true }
    window.show()
    defer { window.dismiss() }
    let editor = window.viewController.editor
    #expect(window.panel?.makeFirstResponder(editor) == true)
    #expect(window.panel?.firstResponder === editor)
    editor.insertText("h", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.string == "h")
    #expect(window.session.input == "h")
    #expect(window.session.code?.payload.encoded == "h")
    editor.insertText("ello", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.string == "hello")
    #expect(window.session.input == "hello")
    editor.setSelectedRange(NSRange(location: 1, length: 3))
    editor.insertText("i", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.string == "hio")
    #expect(window.session.input == "hio")
    #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
    editor.deleteBackward(nil)
    #expect(editor.string == "ho")
    #expect(window.session.input == "ho")
    #expect(editor.selectedRange() == NSRange(location: 1, length: 0))

    window.viewController.exportFailure = "Could not save QR code"
    editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.string == "héo")
    #expect(window.session.input == "héo")
    #expect(window.viewController.exportFailure == nil)
    #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
    editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    #expect(editor.string == "héにo")
    // AppKit notifies textDidChange when composition commits, not for this
    // provisional marked text. Keep it intact until insertText commits it.
    #expect(window.session.input == "héo")
    #expect(!window.copyCurrentOutput())
    window.viewController.editor.onSave?()
    #expect(!window.isSaving)
    #expect(copies == 0)
    editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!editor.hasMarkedText())
    #expect(editor.string == "hé日本o")
    #expect(window.session.input == editor.string)
    #expect(window.copyCurrentOutput())
    #expect(copies == 1)
}

@Test @MainActor func qrReturningFocusAfterSavePreservesTheSelection() {
    _ = NSApplication.shared
    let window = OmniQRWindowController(presentsInterface: false)
    window.show(input: "edit in the middle")
    defer { window.dismiss() }
    let editor = window.viewController.editor
    let selection = NSRange(location: 5, length: 6)
    editor.setSelectedRange(selection)
    #expect(window.panel?.makeFirstResponder(nil) == true)
    #expect(window.panel?.firstResponder !== editor)
    window.viewController.focusInput(preservingSelection: true)
    #expect(window.panel?.firstResponder === editor)
    #expect(editor.selectedRange() == selection)
}

private final class QRNetworkTrap: URLProtocol, @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
    }
    private static let counter = Counter()
    static var requests: Int { counter.lock.withLock { counter.count } }
    override class func canInit(with request: URLRequest) -> Bool {
        counter.lock.withLock { counter.count += 1 }
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    override func stopLoading() {}
}

@Test @MainActor func qrGeneratingAndExportingMakesNoNetworkRequest() async throws {
    _ = NSApplication.shared
    #expect(URLProtocol.registerClass(QRNetworkTrap.self))
    defer { URLProtocol.unregisterClass(QRNetworkTrap.self) }
    let before = QRNetworkTrap.requests
    let window = OmniQRWindowController(presentsInterface: false)
    window.writePasteboardItem = { _ in true }
    window.show(input: "https://open-meteo.com/en/docs")
    window.session.inputChanged("wifi:Home,hunter2")
    #expect(window.copyCurrentOutput())
    window.dismiss()
    try await Task.sleep(for: .milliseconds(100))
    #expect(QRNetworkTrap.requests == before)
}

@Test @MainActor func qrWindowCopiesOneItemAndClosesOnlyAfterSuccessfulWrite() throws {
    _ = NSApplication.shared
    let window = OmniQRWindowController(presentsInterface: false)
    window.show(input: "wifi:Home,hunter2")
    defer { window.dismiss() }
    var items: [NSPasteboardItem] = []
    window.writePasteboardItem = { items.append($0); return false }
    window.copySelectionAndClose()
    #expect(window.session.isOpen)
    #expect(window.viewController.routeText.contains("Could not copy"))
    window.writePasteboardItem = { items.append($0); return true }
    window.copySelectionAndClose()
    #expect(!window.session.isOpen)
    #expect(items.count == 2)
    #expect(Set(items[1].types) == Set([.png, .string]))
    #expect(items[1].string(forType: .string) == "WIFI:T:WPA;S:Home;P:hunter2;;")
    let png = try #require(items[1].data(forType: .png))
    let image = try #require(NSBitmapImageRep(data: png))
    #expect(image.pixelsWide == 1024 && image.pixelsHigh == 1024)
    #expect(window.viewController.editor.string.isEmpty)
    #expect(window.session.lastFittingCode == nil)
}

@Test @MainActor func qrWindowStaleCodeCannotBeCopiedAndRestoresImmediately() {
    _ = NSApplication.shared
    let window = OmniQRWindowController(presentsInterface: false)
    window.show(input: "a")
    defer { window.dismiss() }
    var writes = 0
    window.writePasteboardItem = { _ in writes += 1; return true }
    window.session.inputChanged(String(repeating: "x", count: 3100))
    #expect(window.viewController.tileView.inkOpacity == 0.35)
    #expect(!window.viewController.copyButton.isEnabled)
    #expect(!window.viewController.keyHintsView.hints.contains { $0.label == "Save…" })
    window.copySelectionAndClose()
    #expect(writes == 0 && window.session.isOpen)
    window.session.inputChanged("b")
    #expect(window.viewController.tileView.inkOpacity == 1)
    #expect(window.viewController.copyButton.isEnabled)
    #expect(window.viewController.routeText.contains("Text · 1 chars"))
}

@Test @MainActor func qrFieldGrowsAndScrollsWhileTileStaysFixed() throws {
    _ = NSApplication.shared
    let window = OmniQRWindowController(presentsInterface: false)
    window.show(input: "short")
    defer { window.dismiss() }
    let panel = try #require(window.panel)
    let tile = window.viewController.tileView
    let tileOrigin = panel.frame.origin.y + tile.frame.origin.y
    let tileSize = tile.frame.size
    let oldHeight = panel.frame.height
    window.session.inputChanged(Array(repeating: "a line", count: 12).joined(separator: "\n"))
    #expect(panel.frame.height > oldHeight)
    #expect(tile.frame.size == tileSize)
    #expect(panel.frame.origin.y + tile.frame.origin.y == tileOrigin)
    let scroll = try #require(window.viewController.editor.enclosingScrollView)
    #expect(scroll.frame.height <= 130)
    #expect(window.viewController.editor.frame.height > scroll.frame.height)
    #expect(window.viewController.toolPill.title == "QR")
}

@Test @MainActor func qrProvenanceCanBeClearedWithoutPeeking() {
    _ = NSApplication.shared
    let window = OmniQRWindowController(presentsInterface: false)
    window.show(input: "selection", provenance: .init(source: "Safari", detail: nil, wordCount: 1))
    defer { window.dismiss() }
    #expect(window.viewController.provenance?.source == "Safari")
    window.viewController.provenanceChip.onClear?()
    #expect(window.viewController.provenance == nil)
    #expect(window.session.input.isEmpty)
    #expect(window.session.code == nil)
    window.dismiss()
    window.show()
    #expect(window.session.input.isEmpty)
}

@Test @MainActor func qrCommandSSavesAndReturnCopies() throws {
    _ = NSApplication.shared
    let controller = OmniQRViewController(session: OmniQRSession())
    controller.loadViewIfNeeded()
    var saves = 0
    var copies = 0
    controller.onSaveRequested = { saves += 1 }
    controller.onChooseRequested = { copies += 1 }
    let save = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
    #expect(controller.editor.performKeyEquivalent(with: save))
    controller.editor.onSubmit?()
    #expect(saves == 1 && copies == 1)
}

@Test @MainActor func qrMaximumVersionKeepsWhiteTileCornersInBothAppearances() throws {
    _ = NSApplication.shared
    let tile = OmniQRTileView(frame: NSRect(x: 0, y: 0, width: 280, height: 280))
    tile.code = try OmniQRCode.generate(OmniQRPayload(input: String(repeating: "a", count: 2953)))
    tile.inkOpacity = 0.35
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        tile.appearance = NSAppearance(named: appearance)
        let bitmap = try #require(tile.bitmapImageRepForCachingDisplay(in: tile.bounds))
        tile.cacheDisplay(in: tile.bounds, to: bitmap)
        for (x, y) in [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.genericRGB))
            #expect(color.redComponent == 1 && color.greenComponent == 1 && color.blueComponent == 1)
            #expect(color.alphaComponent == 1)
        }
    }
}

@Test @MainActor func designCaptureQRStates() throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"] else { return }
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let window = OmniQRWindowController(presentsInterface: false)
    defer { window.dismiss() }
    func capture(_ name: String, appearance: NSAppearance.Name) throws {
        let view = window.viewController.view
        view.appearance = NSAppearance(named: appearance)
        (view as? OmniFrostedSurface)?.apply(transparency: .opaqueFallback)
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        if window.session.canExport, let expected = window.session.payload?.encoded {
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(data: png).perform([request])
            #expect(request.results?.contains { $0.payloadStringValue == expected } == true)
        }
    }
    window.show()
    try capture("qr-empty-dark", appearance: .darkAqua)
    window.session.inputChanged("https://open-meteo.com/en/docs")
    try capture("qr-link-dark", appearance: .darkAqua)
    try capture("qr-link-light", appearance: .aqua)
    let code = try #require(window.session.code)
    try code.pngData().write(to: directory.appendingPathComponent("qr-link-export.png"))
    try code.svgData().write(to: directory.appendingPathComponent("qr-link-export.svg"))
    window.session.inputChanged(String(repeating: "x", count: 232))
    try capture("qr-dense-dark", appearance: .darkAqua)
    window.session.inputChanged(String(repeating: "x", count: 3100))
    try capture("qr-too-long-dark", appearance: .darkAqua)
    window.session.inputChanged("wifi:Home,hunter2")
    try capture("qr-wifi-light", appearance: .aqua)
}
