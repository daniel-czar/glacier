import AppKit
import Foundation
import HyperOverlayRuntime
import OmniCore
import OmniPresentation
import Testing
@testable import ClipboardHistory

private let clipboardUIEnabled = ProcessInfo.processInfo.environment["OMNI_CLIPBOARD_UI_TESTS"] == "1"
    || ProcessInfo.processInfo.environment["GLACIER_CLIPBOARD_UI_TESTS"] == "1"

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func clipboardShowHonorsNilOriginAndKeepsVisibleOwnershipOnRefresh() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-origin-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app") })
    var receivedOrigins: [pid_t?] = []
    controller.targetResolver = { pid in receivedOrigins.append(pid); return PasteTarget(pid) }
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    await controller.start()

    controller.show(originPID: nil)
    #expect(receivedOrigins.count == 1 && receivedOrigins[0] == nil)
    #expect(controller.isVisible)
    #expect(foreground.activeOverlay == ClipboardHistoryController.overlayID)
    let generation = foreground.generation

    // The host can reissue a show with an explicit query/origin while this
    // picker is already open. It must refresh, not toggle ownership off.
    controller.show(query: "saved", originPID: nil)
    #expect(receivedOrigins.count == 2 && receivedOrigins[1] == nil)
    #expect(controller.isVisible)
    #expect(foreground.activeOverlay == ClipboardHistoryController.overlayID)
    #expect(foreground.generation == generation)
}

@MainActor
private final class RecallPayloadGate {
    private var waiters: [CheckedContinuation<ClipboardHistoryPayload?, Error>] = []

    func load(_ id: UUID) async throws -> ClipboardHistoryPayload? {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    var pendingCount: Int { waiters.count }

    func releaseFirst(_ payload: ClipboardHistoryPayload) {
        waiters.removeFirst().resume(returning: payload)
    }

    func releaseAll() {
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
    }
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func staleRecallCannotUnlockNewerClipboardRecall() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-recall-race-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    _ = try await store.save(payload: .text(plain: "saved"))
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app") })
    let gate = RecallPayloadGate()
    controller.payloadLoader = { try await gate.load($0) }
    defer {
        controller.stop()
        gate.releaseAll()
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
    await controller.start()

    controller.show(originPID: -1)
    let window = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "hyper.clipboard.history" })
    let view = try #require(window.contentView)
    let table = try #require(descendant(NSTableView.self, in: view))
    let button = try #require(descendant(OmniPadRunButton.self, in: view))
    let copyOnly = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
    try await waitUntil { table.numberOfRows == 1 && table.selectedRow == 0 }
    NSApp.sendEvent(copyOnly)
    try await waitUntil { gate.pendingCount == 1 }
    let firstRecall = try #require(controller.recallTask)

    controller.dismiss(restoreFocus: false)
    controller.show(originPID: -1)
    try await waitUntil { table.numberOfRows == 1 && table.selectedRow == 0 }
    NSApp.sendEvent(copyOnly)
    try await waitUntil { gate.pendingCount == 2 }
    gate.releaseFirst(.text(plain: "stale"))
    await firstRecall.value
    #expect(!button.isEnabled, "stale completion must not release the newer busy lane")
    NSApp.sendEvent(copyOnly)
    #expect(gate.pendingCount == 1, "a third recall must be refused while the newer one waits")
    gate.releaseFirst(.text(plain: "newest"))
    try await waitUntil { !controller.isVisible }
    #expect(board.string(forType: .string) == "newest")
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func clearingHistoryReleasesPendingRecallLaneForNewEntries() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-clear-recall-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    _ = try await store.save(payload: .text(plain: "old"))
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app") })
    let gate = RecallPayloadGate()
    controller.payloadLoader = { try await gate.load($0) }
    defer {
        controller.stop()
        gate.releaseAll()
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
    await controller.start()

    controller.show(originPID: -1)
    let window = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "hyper.clipboard.history" })
    let view = try #require(window.contentView)
    let table = try #require(descendant(NSTableView.self, in: view))
    let search = try #require(descendant(OmniEphemeralTextView.self, in: view))
    let button = try #require(descendant(OmniPadRunButton.self, in: view))
    let copyOnly = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
    try await waitUntil { table.numberOfRows == 1 && table.selectedRow == 0 }
    NSApp.sendEvent(copyOnly)
    try await waitUntil { gate.pendingCount == 1 }
    let oldRecall = try #require(controller.recallTask)

    try await controller.clearSavedHistory()
    #expect(controller.recallTask == nil)
    try await waitUntil { table.numberOfRows == 0 }
    _ = try await store.save(payload: .text(plain: "new"))
    controller.textDidChange(Notification(name: NSText.didChangeNotification, object: search))
    try await waitUntil { table.numberOfRows == 1 && table.selectedRow == 0 }
    try #require(button.isEnabled, "Clear must release the old recall's busy lane")
    NSApp.sendEvent(copyOnly)
    try await waitUntil { gate.pendingCount == 2 }

    gate.releaseFirst(.text(plain: "old"))
    await oldRecall.value
    #expect(!button.isEnabled, "old recall cannot unlock the new one")
    gate.releaseFirst(.text(plain: "new"))
    try await waitUntil { !controller.isVisible }
    #expect(board.string(forType: .string) == "new")
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func clearIsABarrierForQueuedCaptureAndDoesNotBackfill() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-clear-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.editor") })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    await controller.start()
    board.clearContents(); board.setString("copy queued immediately before Clear", forType: .string)
    controller.capturePendingBeforeForeground()
    try await controller.clearSavedHistory()
    try await Task.sleep(for: .milliseconds(750))
    #expect(try await store.list().isEmpty)
    #expect(board.string(forType: .string) == "copy queued immediately before Clear")
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func explicitForegroundFlushCannotBecomeAMaintenanceTick() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-flush-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    let board = NSPasteboard.withUniqueName()
    var source = ClipboardHistorySource(bundleID: "fixture.editor")
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board, source: { source })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    await controller.start()
    for _ in 0..<169 { controller.capturePendingBeforeForeground() }
    board.clearContents(); board.setString("pending before foreground", forType: .string)
    controller.capturePendingBeforeForeground()
    source = ClipboardHistorySource(bundleID: "fixture.host")
    try await Task.sleep(for: .milliseconds(750))
    #expect(try await store.list().count == 1)
    #expect(try await store.list().first?.sourceBundleID == "fixture.editor")
}

@MainActor
private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<120 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(condition(), "Native fixture did not reach the expected state")
}

@MainActor
private func captureClipboardView(_ view: NSView, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CLIPBOARD_CAPTURE_DIR"] else { return }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        view.appearance = NSAppearance(named: appearance)
        (view as? OmniFrostedSurface)?.apply(transparency: .opaqueFallback)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(
            to: directory.appendingPathComponent("clipboard-\(name)-\(suffix).png"))
    }
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func clipboardPickerCopiesExactTextAndRejectsStaleOrMissingTargets() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    let text = "  First paragraph\n\n\tSecond paragraph  \n"
    _ = try await store.save(payload: .text(plain: text, rtf: Data("rich".utf8)))
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app", name: "Fixture") })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    await controller.start()
    controller.show(originPID: -1)
    let window = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "hyper.clipboard.history" })
    let view = try #require(window.contentView)
    let table = try #require(descendant(NSTableView.self, in: view))
    try await waitUntil { table.numberOfRows == 1 && table.selectedRow == 0 }
    let paste = try #require(descendant(OmniPadRunButton.self, in: view))
    let pill = try #require(descendant(OmniToolPillView.self, in: view))
    #expect(view.bounds.width == 640)
    #expect(pill.title == "Clipboard" && pill.frame.maxX == view.bounds.width - 18)
    #expect(view.subviews.compactMap { $0 as? NSButton }.count == 1)
    // As copied (H20 default): ↩ already pastes the flavours, so ⇧↩ is the plain-text hint.
    #expect(try #require(descendant(OmniKeyHintsView.self, in: view)).hints == [
        .init("↩", "Paste"), .init("⌘↩", "Copy only"), .init("⇧↩", "Plain text"), .init("esc", "Close")])
    let menu = try #require(table.menu)
    let search = try #require(descendant(OmniEphemeralTextView.self, in: view))
    #expect(search.menu !== menu, "The query keeps its native editing menu")
    menu.update()
    #expect(menu.items.map(\.title).contains("Pause capture"))
    #expect(menu.items.map(\.title).contains("Delete selected"))
    #expect(menu.items.map(\.title).contains("Clear history…"))
    #expect(menu.items.map(\.title).contains("Settings"))
    try captureClipboardView(view, name: "picker")

    board.clearContents(); board.setString("untouched", forType: .string)
    paste.performClick(nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(board.string(forType: .string) == "untouched")
    #expect(controller.isVisible)

    let copyOnly = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
    NSApp.sendEvent(copyOnly)
    controller.dismiss(restoreFocus: false)
    try await Task.sleep(for: .milliseconds(100))
    #expect(board.string(forType: .string) == "untouched", "stale action must not mutate the clipboard")

    controller.show(originPID: -1)
    try await waitUntil { table.numberOfRows == 1 && table.selectedRow == 0 }
    NSApp.sendEvent(copyOnly)
    try await waitUntil { !controller.isVisible }
    #expect(board.string(forType: .string) == text)
    #expect(board.data(forType: ClipboardHistoryCapture.privateMarker) != nil)
    #expect(board.data(forType: .rtf) == nil, "copy-only uses the accepted plain-text default")
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func clipboardHintsFollowFormattingAndModifiedArrowsStayInQuery() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-hints-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    _ = try await store.save(payload: .text(plain: "rich", rtf: Data("format".utf8)))
    _ = try await store.save(payload: .text(plain: "plain"))
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2,
        pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    _ = try await store.save(payload: .image(data: png, typeIdentifier: "public.png"))
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app", name: "Fixture") })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    await controller.start()
    controller.show(originPID: -1)
    let window = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "hyper.clipboard.history" })
    let view = try #require(window.contentView)
    let table = try #require(descendant(NSTableView.self, in: view))
    let hints = try #require(descendant(OmniKeyHintsView.self, in: view))
    let search = try #require(descendant(OmniEphemeralTextView.self, in: view))
    try await waitUntil { table.numberOfRows == 3 && table.selectedRow == 0 }
    #expect(!hints.hints.contains(.init("⌥↩", "Formatted")), "Images do not offer formatted paste")
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    #expect(!hints.hints.contains(.init("⌥↩", "Formatted")), "Plain text does not offer formatted paste")
    table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    #expect(hints.hints.contains(.init("⇧↩", "Plain text")), "RTF text pastes as copied; ⇧↩ offers plain text")
    // Settings → Paste → Plain text: ↩ is plain, so ⌥↩ offers the flavours again.
    controller.pasteMode = .plainText
    #expect(hints.hints.contains(.init("⌥↩", "Formatted")), "Plain-text mode keeps formatted paste on ⌥↩")
    controller.pasteMode = .asCopied

    search.string = ""
    window.makeFirstResponder(search)
    let modifiedUp = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
        isARepeat: false, keyCode: 126))
    NSApp.sendEvent(modifiedUp)
    #expect(table.selectedRow == 2, "Modified Up belongs to the multiline query")
    let plainUp = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
        isARepeat: false, keyCode: 126))
    NSApp.sendEvent(plainUp)
    #expect(table.selectedRow == 1, "Plain Up still navigates history")
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func clipboardLongSearchWrapsBelowOnePillAndKeepsFiltering() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-long-search-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    _ = try await store.save(payload: .text(plain: "short saved text"))
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app", name: "Fixture") })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    await controller.start()
    controller.show(originPID: -1)
    let window = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "hyper.clipboard.history" })
    let view = try #require(window.contentView)
    let search = try #require(descendant(OmniEphemeralTextView.self, in: view))
    let pill = try #require(descendant(OmniToolPillView.self, in: view))
    let table = try #require(descendant(NSTableView.self, in: view))
    let longQuery = String(repeating: "something copied from a long descriptive clipboard search ", count: 6)
    search.string = longQuery
    controller.textDidChange(Notification(name: NSText.didChangeNotification, object: search))
    try await waitUntil { table.numberOfRows == 0 }
    #expect(try #require(search.enclosingScrollView).frame.height > 25)
    #expect(search.textContainer.map { search.layoutManager?.usedRect(for: $0).height ?? 0 } ?? 0 > 25)
    #expect(pill.frame.maxX == view.bounds.width - 18)
    #expect(view.subviews.compactMap { $0 as? OmniToolPillView }.count == 1)
    #expect(view.bounds.width == 640)
    try captureClipboardView(view, name: "long-search")
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func rejectedLargeCopyDoesNotStopLaterFittingCopy() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-capacity-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root, maxStorageBytes: 10)
    _ = try await store.save(payload: .text(plain: "123456"))
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app", name: "Fixture") })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    await controller.start()
    #expect(controller.statusFacts["storageUsedBytes"] == "6")
    #expect(controller.statusFacts["storageCapacityBytes"] == "10")

    board.clearContents(); board.setString("way too large", forType: .string)
    try await waitUntil { controller.statusFacts["error"]?.contains("could not fit") == true }
    #expect(try await store.list().count == 1)

    board.clearContents(); board.setString("ok", forType: .string)
    try await waitUntil { controller.statusFacts["storageUsedBytes"] == "8" }
    #expect(try await store.list().count == 2)
    #expect(controller.statusFacts["error"]?.contains("could not fit") == true)
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func oversizedItemWarningSurvivesNewestDuplicateCopy() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-full-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root, maxStorageBytes: 4)
    _ = try await store.save(payload: .text(plain: "full"))
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app", name: "Fixture") })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    await controller.start()
    // No window needed: this exercises collection with the picker closed.
    board.clearContents(); board.setString("does not fit", forType: .string)
    try await waitUntil { controller.statusFacts["error"]?.contains("could not fit") == true }
    board.clearContents(); board.setString("full", forType: .string)
    try await Task.sleep(for: .milliseconds(750))
    #expect(controller.statusFacts["error"]?.contains("could not fit") == true)
    #expect(controller.statusFacts["storageUsedBytes"] == "4")
    #expect(controller.statusFacts["storageCapacityBytes"] == "4")
    #expect(try await store.list().count == 1)
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func fullStoreRollsOldestEntryForNewCapture() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-roll-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root, maxStorageBytes: 4)
    let old = try await store.save(payload: .text(plain: "full"))
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app", name: "Fixture") })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    await controller.start()
    board.clearContents(); board.setString("new", forType: .string)
    try await waitUntil { controller.statusFacts["storageUsedBytes"] == "3" }
    #expect(try await store.payload(id: old.id) == nil)
    #expect(try await store.list().count == 1)
    #expect(controller.statusFacts["error"] == "")
}

@Test(.enabled(if: clipboardUIEnabled, "explicit native UI fixture run"))
@MainActor func commandYStashesTheSelectedRowWithNoticeAndUndo() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-stash-ui-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    _ = try await store.save(payload: .text(plain: "keep this", rtf: Data("rtf".utf8)), source: ClipboardHistorySource(bundleID: "com.apple.Safari", name: "Safari"))
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.app", name: "Fixture") })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    var pushed: [(ClipboardHistoryPayload, String?)] = []
    var undone = 0
    var full = false
    controller.onStash = { payload, summary in
        pushed.append((payload, summary.sourceName))
        return ClipboardStashPush(droppedOldest: full) { undone += 1; return true }
    }
    try await controller.start(effectiveCapture: false)
    controller.stop()
    try await controller.start(effectiveCapture: false)
    controller.show(originPID: -1)
    let window = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "hyper.clipboard.history" })
    let view = try #require(window.contentView)
    let table = try #require(descendant(NSTableView.self, in: view))
    let hints = try #require(descendant(OmniKeyHintsView.self, in: view))
    let search = try #require(descendant(OmniEphemeralTextView.self, in: view))
    try await waitUntil { table.numberOfRows == 1 && table.selectedRow == 0 }
    // C95, D5: the strip names ⌘Y; ⌘↩ and ⌥↩ keep working unhinted.
    #expect(hints.hints == [.init("↩", "Paste"), .init("⌘Y", "Stash"), .init("esc", "Close")])

    window.makeFirstResponder(search)
    func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    // D5: ⌘S moved to ⌘Y with no alias; it stashes nothing now.
    NSApp.sendEvent(try key("s", 1, .command))
    #expect(pushed.isEmpty)
    #expect(controller.notice == nil)
    NSApp.sendEvent(try key("y", 16, .command))
    try await waitUntil { controller.notice == "Stashed · now active" }
    #expect(pushed.count == 1)
    #expect(pushed.first?.0 == .text(plain: "keep this", rtf: Data("rtf".utf8)))
    #expect(pushed.first?.1 == "Safari")
    #expect(search.string.isEmpty, "⌘Y never types a y")

    NSApp.sendEvent(try key("z", 6, .command))
    #expect(undone == 1)
    #expect(controller.notice == nil)

    full = true
    NSApp.sendEvent(try key("y", 16, .command))
    try await waitUntil { controller.notice == "Stashed · oldest dropped" }
    // The notice lasts until the next keystroke, never by timer.
    try await Task.sleep(for: .milliseconds(400))
    #expect(controller.notice == "Stashed · oldest dropped")
    NSApp.sendEvent(try key("k", 40, []))
    #expect(controller.notice == nil)
}

/// Settings → Clipboard (H20): capture, retention and the facts beside them
/// go through the controller, so the menu bar and the panel agree.
@MainActor @Test func settingsCaptureAndRetentionWriteTheStoreAndReportBack() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-settings-\(UUID())")
    let store = try ClipboardHistoryStore(directory: root)
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.editor") })
    defer { controller.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    var changes = 0
    controller.onSettingsChanged = { changes += 1 }
    let initial = await controller.historyState()
    #expect(!initial.paused && initial.retentionHours == 36 && initial.itemCount == 0)
    try await controller.setCaptureEnabled(false)
    #expect(controller.isCapturePaused)
    #expect(try await store.settings().paused)
    #expect(changes == 1)
    // Asking for the state it is already in writes nothing and says nothing.
    try await controller.setCaptureEnabled(false)
    #expect(changes == 1)
    try await controller.setRetentionHours(168)
    #expect(try await store.settings().retentionHours == 168)
    await #expect(throws: ClipboardHistoryStoreError.self) { try await controller.setRetentionHours(0) }
    #expect(try await store.settings().retentionHours == 168)
    try await controller.setCaptureEnabled(true)
    #expect(!(try await store.settings().paused))
    #expect(ClipboardHistoryController.retentionChoices.contains(168))
}
