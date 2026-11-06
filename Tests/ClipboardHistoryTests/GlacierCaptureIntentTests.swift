import AppKit
import Foundation
import HyperOverlayRuntime
import Testing
@testable import ClipboardHistory

private enum CaptureIntentFailure: Error {
    case rejected
}

/// The panel requests a canonical setting change. Only the owner's successful
/// apply changes the collector's effective pause state.
@MainActor @Test func panelCaptureIntentUsesCanonicalOwnerAndKeepsStateOnFailure() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("glacier-capture-intent-\(UUID())")
    let store = try ClipboardHistoryStore(directory: directory)
    let board = NSPasteboard.withUniqueName()
    let foreground = ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID])
    let controller = ClipboardHistoryController(
        store: store, foreground: foreground, pasteboard: board,
        source: { ClipboardHistorySource(bundleID: "fixture.editor") }
    )
    defer {
        controller.stop()
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    // No start(): this tests policy persistence without polling a real board or
    // registering an application/global event observer.
    try await controller.setCaptureEnabled(false)
    #expect(controller.isCapturePaused)
    #expect(try await store.settings().paused)

    var requested: [Bool] = []
    var canonicalEnabled = false
    var notifications = 0
    controller.onSettingsChanged = { notifications += 1 }
    controller.onCaptureIntent = { enabled in
        requested.append(enabled)
        canonicalEnabled = enabled
        try await controller.setCaptureEnabled(enabled)
    }

    let resume = try #require(controller.requestCaptureToggle())
    #expect(controller.isCapturePaused, "a pending panel request must not claim success")
    #expect(controller.requestCaptureToggle() == nil, "a second click must not enqueue another request")
    await resume.value
    #expect(requested == [true])
    #expect(canonicalEnabled)
    #expect(!controller.isCapturePaused)
    #expect(!(try await store.settings().paused))
    #expect(notifications == 1, "owner apply must not recurse into the intent hook")

    controller.onCaptureIntent = { enabled in
        requested.append(enabled)
        throw CaptureIntentFailure.rejected
    }
    let pause = try #require(controller.requestCaptureToggle())
    await pause.value
    #expect(requested == [true, false])
    #expect(canonicalEnabled)
    #expect(!controller.isCapturePaused)
    #expect(!(try await store.settings().paused))
    #expect(notifications == 1)
    #expect(controller.statusFacts["error"] == "Capture setting could not be changed. Try again.")

    // A canonical save can succeed before the collector apply fails. The owner
    // must still throw instead of treating its saved intent as an apply receipt.
    try await controller.setCaptureEnabled(false)
    canonicalEnabled = false
    controller.onCaptureIntent = { enabled in
        canonicalEnabled = enabled
        throw CaptureIntentFailure.rejected
    }
    let failedApply = try #require(controller.requestCaptureToggle())
    await failedApply.value
    #expect(canonicalEnabled)
    #expect(controller.isCapturePaused)
    #expect(try await store.settings().paused)
    #expect(controller.statusFacts["error"] == "Capture setting could not be changed. Try again.")
}

@MainActor @Test func canonicalCaptureStartupRecoversAfterFailedPauseWithoutStaleResume() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-capture-recovery-\(UUID())")
    let store = try ClipboardHistoryStore(directory: directory)
    let board = NSPasteboard.withUniqueName()
    let controller = ClipboardHistoryController(store: store,
        foreground: ForegroundArbitrator(allowedOverlays: [ClipboardHistoryController.overlayID]),
        pasteboard: board, source: { ClipboardHistorySource(bundleID: "fixture.editor") })
    defer {
        controller.stop(); board.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
    // Polling is confined to a new empty test pasteboard, never the user's clipboard.
    try await controller.start(effectiveCapture: true)
    #expect(controller.isMonitoring)
    #expect(!controller.isCapturePaused)
    let manifest = directory.appendingPathComponent("history.json")
    let backup = directory.appendingPathComponent("history-backup.json")
    try FileManager.default.moveItem(at: manifest, to: backup)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await controller.setCaptureEnabled(false) }
    controller.stop() // The app stops capture after a failed disable apply.
    #expect(!controller.isMonitoring)
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.moveItem(at: backup, to: manifest)
    try await controller.start(effectiveCapture: true)
    #expect(controller.isMonitoring)
    #expect(!controller.isCapturePaused)
    controller.stop()
    // A canonical pause wins over the old unpaused store BEFORE a poller starts.
    try await controller.start(effectiveCapture: false)
    #expect(controller.isMonitoring)
    #expect(controller.isCapturePaused)
    #expect(try await store.settings().paused)
}
