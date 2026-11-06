import AppKit
import Foundation
import HyperOverlayRuntime
import Testing
@testable import ClipboardHistory

@Test @MainActor func declaredHostCopySurvivesRestoringAnotherApplication() {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    var source = ClipboardHistorySource(bundleID: "fixture.editor")
    let capture = ClipboardHistoryCapture(pasteboard: board, currentSource: { source })
    #expect(HostPasteboardWriter.writeText("  host result\n\nnext  ", to: board, sourceBundleID: "fixture.host"))
    source = ClipboardHistorySource(bundleID: "fixture.editor.after")
    capture.noteSourceTransition()
    guard case .captured(let payload, let origin) = capture.read(settings: .init()) else {
        Issue.record("An explicitly source-marked host copy should remain eligible")
        return
    }
    #expect(payload == .text(plain: "  host result\n\nnext  "))
    #expect(origin.bundleID == "fixture.host")
}

@MainActor
private func namedHistoryPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("clipboard-history-tests-\(UUID().uuidString)"))
}

@MainActor
private func put(_ plain: String, on pasteboard: NSPasteboard,
                 rtf: Data? = nil, html: Data? = nil,
                 marker: NSPasteboard.PasteboardType? = nil,
                 declaredSource: String? = nil) {
    let item = NSPasteboardItem()
    item.setString(plain, forType: .string)
    if let rtf { item.setData(rtf, forType: .rtf) }
    if let html { item.setData(html, forType: .html) }
    if let marker { item.setData(Data(), forType: marker) }
    if let declaredSource {
        item.setString(declaredSource, forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
    }
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([item]))
}

@MainActor
private func put(_ data: Data, type: NSPasteboard.PasteboardType, on pasteboard: NSPasteboard) {
    let item = NSPasteboardItem()
    item.setData(data, forType: type)
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([item]))
}

@MainActor
private func smallValidTiff() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2,
        pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
    for y in 0..<2 {
        for x in 0..<2 { bitmap.setColor(.systemBlue, atX: x, y: y) }
    }
    return try #require(bitmap.tiffRepresentation)
}

@MainActor
private func expectIgnored(_ result: ClipboardHistoryCapture.Read) {
    guard case .ignored = result else {
        Issue.record("Expected ignored clipboard change, received \(result)")
        return
    }
}

@MainActor
private func expectChangedDuringRead(_ result: ClipboardHistoryCapture.Read) {
    guard case .changedDuringRead = result else {
        Issue.record("Expected torn-read rejection, received \(result)")
        return
    }
}

@Test @MainActor func captureBaselinesExistingContentAndDoesNotBackfillAfterReset() {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    put("copied before observer", on: board)
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.writer", name: "Writer") })
    expectIgnored(capture.read(settings: .init()))

    put("copied while stopped", on: board)
    capture.resetBaseline()
    expectIgnored(capture.read(settings: .init()))

    put("new copy", on: board)
    guard case let .captured(payload, source) = capture.read(settings: .init()) else {
        Issue.record("A new post-baseline copy should be captured")
        return
    }
    #expect(payload == .text(plain: "new copy"))
    #expect(source.bundleID == "com.example.writer")
    expectIgnored(capture.read(settings: .init()))
}

@Test @MainActor func capturePreservesWhitespaceRtfAndHtmlBytes() async throws {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.editor", name: "Editor") })
    let plain = "  first\n\n\tαβ\r\nlast  \n"
    let rtf = Data("{\\rtf1\\ansi αβ}".utf8)
    let html = Data("<p>αβ&nbsp;value</p>".utf8)
    put(plain, on: board, rtf: rtf, html: html)
    guard case let .captured(payload, source) = capture.read(settings: .init()) else {
        Issue.record("Expected rich text capture")
        return
    }
    #expect(payload == .text(plain: plain, rtf: rtf, html: html))
    #expect(source.bundleID == "com.example.editor")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clipboard-capture-store-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ClipboardHistoryStore(directory: root)
    let summary = try await store.save(payload: payload, source: source)
    #expect(summary.hasFormatting)
    #expect(try await store.payload(id: summary.id) == payload)
}

@Test @MainActor func confidentialTransientAndPrivateMarkersAreRejectedBeforePayload() {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.writer") })
    let markers = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
        NSPasteboard.PasteboardType("net.antelle.keeweb"),
        NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"),
        ClipboardHistoryCapture.privateMarker,
    ]
    for marker in markers {
        put("secret", on: board, marker: marker)
        expectIgnored(capture.read(settings: .init()))
    }
}

@Test @MainActor func observedAndDeclaredExcludedAppsAreRejected() {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    var observed = "com.example.blocked"
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: observed, name: "Observed") })
    let settings = ClipboardHistorySettings(excludedBundleIDs: ["com.example.blocked"])
    put("observed exclusion", on: board)
    expectIgnored(capture.read(settings: settings))

    observed = "com.example.allowed"
    put("declared exclusion", on: board, declaredSource: "com.example.blocked")
    expectIgnored(capture.read(settings: settings))

    put("eligible", on: board, declaredSource: "com.example.allowed")
    guard case let .captured(_, source) = capture.read(settings: settings) else {
        Issue.record("Unexcluded source should be captured")
        return
    }
    #expect(source.bundleID == "com.example.allowed")
}

@Test @MainActor func pauseAndResumeStartFromFreshBaseline() {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.writer") })
    put("while paused", on: board)
    expectIgnored(capture.read(settings: .init(paused: true)))
    capture.resetBaseline()
    expectIgnored(capture.read(settings: .init()))
    put("after resume", on: board)
    guard case let .captured(payload, _) = capture.read(settings: .init()) else {
        Issue.record("A post-resume copy should be captured")
        return
    }
    #expect(payload == .text(plain: "after resume"))
}

@Test @MainActor func recallWriteDoesNotFeedBackIntoCapture() {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.writer") })
    let rtf = Data("{\\rtf1 recalled}".utf8)
    #expect(capture.write(.text(plain: "recalled", rtf: rtf), formatted: true))
    #expect(board.types?.contains(ClipboardHistoryCapture.privateMarker) == true)
    expectIgnored(capture.read(settings: .init()))
    put("fresh user copy", on: board)
    guard case .captured = capture.read(settings: .init()) else {
        Issue.record("Recall suppression must not suppress the next user copy")
        return
    }
}

@Test @MainActor func appSwitchAndTornPasteboardReadAreRejected() {
    let appBoard = namedHistoryPasteboard()
    defer { appBoard.releaseGlobally() }
    var sourceCalls = 0
    let appCapture = ClipboardHistoryCapture(pasteboard: appBoard, currentSource: {
        sourceCalls += 1
        return .init(bundleID: sourceCalls <= 2 ? "com.example.first" : "com.example.second")
    })
    put("app switched", on: appBoard)
    expectChangedDuringRead(appCapture.read(settings: .init()))

    let tornBoard = namedHistoryPasteboard()
    defer { tornBoard.releaseGlobally() }
    var tornCalls = 0
    let tornCapture = ClipboardHistoryCapture(pasteboard: tornBoard, currentSource: {
        tornCalls += 1
        if tornCalls == 3 { put("replacement", on: tornBoard) }
        return .init(bundleID: "com.example.stable")
    })
    put("first value", on: tornBoard)
    expectChangedDuringRead(tornCapture.read(settings: .init()))
}

@Test @MainActor func excludedCopyIsRejectedAfterSwitchToAllowedAppBeforePolling() {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    var frontmost = "com.example.blocked"
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: frontmost) })
    put("copied in excluded app", on: board)
    frontmost = "com.example.allowed"
    expectChangedDuringRead(capture.read(settings:
        .init(excludedBundleIDs: ["com.example.blocked"])))
    expectIgnored(capture.read(settings: .init()))
}

@Test @MainActor func awayAndBackTransitionRejectsUnattributedCopy() {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.allowed") })
    capture.noteSourceTransition()
    put("source changed between polls", on: board)
    expectChangedDuringRead(capture.read(settings: .init()))
    expectIgnored(capture.read(settings: .init()))

    put("next stable copy", on: board)
    guard case let .captured(payload, _) = capture.read(settings: .init()) else {
        Issue.record("A later stable copy should be captured")
        return
    }
    #expect(payload == .text(plain: "next stable copy"))
}

@Test @MainActor func finderFileReferenceWithStringFlavorIsIgnored() {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.apple.finder", name: "Finder") })
    let item = NSPasteboardItem()
    let syntheticURL = URL(fileURLWithPath: "/tmp/clipboard-history-fixture-\(UUID().uuidString)")
    item.setString(syntheticURL.absoluteString, forType: .fileURL)
    item.setString("file displayed as text", forType: .string)
    board.clearContents()
    #expect(board.writeObjects([item]))
    expectIgnored(capture.read(settings: .init()))
}

@Test @MainActor func syntheticJpegUTIPreservesOriginalBytes() throws {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.paint") })
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2,
        pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 6, bitsPerPixel: 24))
    for y in 0..<2 {
        for x in 0..<2 { bitmap.setColor(.systemRed, atX: x, y: y) }
    }
    let jpeg = try #require(bitmap.representation(using: .jpeg,
        properties: [.compressionFactor: 0.9]))
    let type = NSPasteboard.PasteboardType("public.jpeg")
    put(jpeg, type: type, on: board)
    guard case let .captured(payload, _) = capture.read(settings: .init()) else {
        Issue.record("A valid public.jpeg image should be captured")
        return
    }
    #expect(payload == .image(data: jpeg, typeIdentifier: type.rawValue))
}

@Test @MainActor func syntheticPngAndTiffAreCapturedAsOriginalImageBytes() throws {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.paint") })
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2,
        pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
    for y in 0..<2 {
        for x in 0..<2 { bitmap.setColor(.systemBlue, atX: x, y: y) }
    }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let tiff = try #require(bitmap.tiffRepresentation)
    for (data, type) in [(png, NSPasteboard.PasteboardType.png), (tiff, .tiff)] {
        put(data, type: type, on: board)
        guard case let .captured(payload, _) = capture.read(settings: .init()) else {
            Issue.record("Expected synthetic \(type.rawValue) image capture")
            continue
        }
        #expect(payload == .image(data: data, typeIdentifier: type.rawValue))
    }
}

@Test @MainActor func imageCapAcceptsExactBoundaryAndLaterCopiesAfterRefusal() throws {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let capture = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.paint") })
    let small = try smallValidTiff()
    let imageLimit = 12 * 1024 * 1024
    var exact = small
    exact.append(Data(count: imageLimit - small.count))
    #expect(exact.count == imageLimit)

    put(exact, type: .tiff, on: board)
    guard case let .captured(payload, _) = capture.read(settings: .init()) else {
        Issue.record("A valid image at exactly 12 MiB should be captured")
        return
    }
    #expect(payload == .image(data: exact, typeIdentifier: NSPasteboard.PasteboardType.tiff.rawValue))

    var oversized = exact
    oversized.append(0)
    put(oversized, type: .tiff, on: board)
    guard case .unavailable = capture.read(settings: .init()) else {
        Issue.record("An image above 12 MiB should be refused")
        return
    }

    put(small, type: .tiff, on: board)
    guard case let .captured(nextImage, _) = capture.read(settings: .init()) else {
        Issue.record("A later fitting image should still be captured")
        return
    }
    #expect(nextImage == .image(data: small, typeIdentifier: NSPasteboard.PasteboardType.tiff.rawValue))
    put("text after large image", on: board)
    guard case let .captured(nextText, _) = capture.read(settings: .init()) else {
        Issue.record("A later text copy should still be captured")
        return
    }
    #expect(nextText == .text(plain: "text after large image"))
}

@Test @MainActor func injectedItemLimitStillBoundsImagesAndRichTextCanExceedImageCap() throws {
    let board = namedHistoryPasteboard()
    defer { board.releaseGlobally() }
    let small = try smallValidTiff()
    let capture = ClipboardHistoryCapture(pasteboard: board, maxItemBytes: small.count - 1,
        currentSource: { .init(bundleID: "com.example.paint") })
    put(small, type: .tiff, on: board)
    guard case .unavailable = capture.read(settings: .init()) else {
        Issue.record("A smaller injected item limit should still reject the image")
        return
    }
    put("next", on: board)
    guard case let .captured(next, _) = capture.read(settings: .init()) else {
        Issue.record("The rejected image should not block the next small text copy")
        return
    }
    #expect(next == .text(plain: "next"))

    let unrestricted = ClipboardHistoryCapture(pasteboard: board,
        currentSource: { .init(bundleID: "com.example.editor") })
    let plain = String(repeating: "x", count: 12 * 1024 * 1024)
    let html = Data("<p>x</p>".utf8)
    put(plain, on: board, html: html)
    guard case let .captured(richText, _) = unrestricted.read(settings: .init()) else {
        Issue.record("Text plus formatting above 12 MiB should keep the 64 MiB item limit")
        return
    }
    #expect(richText == .text(plain: plain, html: html))
}
