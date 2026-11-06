import AppKit
import Foundation
import GlacierConfiguration
import GlacierConnections
import GlacierRuntime
import HyperOverlayRuntime
import OmniAdapters
import OmniCore
import OmniModels
import OmniPresentation
import Testing
@testable import GlacierWorkspace

private struct LifecycleNoSecrets: SecretStore {
    func insert(_ secret: String, account: UUID) throws { throw CancellationError() }
    func read(account: UUID) throws -> String { throw CancellationError() }
    func remove(account: UUID) throws { throw CancellationError() }
}
private struct LifecycleNoNetwork: ConnectionNetworkTransport {
    func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange { throw CancellationError() }
    func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream { throw CancellationError() }
}

@MainActor
private func lifecycleFixture(root: URL, selection: NativeSelectionCapture = NativeSelectionCapture(),
                              presentsInterface: Bool = false) async throws -> (GlacierComposition, OmniNativeWorkspaceController) {
    _ = NSApplication.shared
    let home = root.appendingPathComponent("home")
    let paths = try GlacierPaths(home: home, supportOverride: root.appendingPathComponent("Glacier"))
    let composition = try await GlacierComposition.make(paths: paths, home: home, hostActions: GlacierHostActions(),
        applicationRoots: [], network: LifecycleNoNetwork(), secrets: LifecycleNoSecrets(),
        platform: RecordingPlatformAdapter(), fileEffect: { _, _ in throw CancellationError() })
    let controller = OmniNativeWorkspaceController(environment: composition.workspace,
        foreground: ForegroundArbitrator(allowedOverlays: ["omni-editing", "omni-attached", "omni-ephemeral", "omni-capture"]),
        presentsInterface: presentsInterface, selectionCapture: selection, notifications: RecordingOmniNotificationClient(availability: .unavailable(reason: "fixture")),
        ownsApplicationMenu: false, pasteboardWriter: { _ in }, restoreOrigin: {},
        focusOrigin: FocusOriginTracker(frontmostProcessID: { nil }))
    return (composition, controller)
}

@MainActor @Test func hiddenStatusItemKeepsSettingsShortcutInWorkspaceAndPad() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-settings-key-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (composition, controller) = try await lifecycleFixture(root: root, presentsInterface: true)
    defer { controller.stop() }
    var settingsCalls = 0
    controller.onShowSettings = { focusModels in
        #expect(!focusModels)
        settingsCalls += 1
    }
    let statusItem = try #require(controller.statusPresenter?.statusItem)
    statusItem.isVisible = false
    let menu = controller.makeApplicationMenu(includesEditMenu: false)
    let settingsItem = try #require(menu.items.first?.submenu?.item(withTitle: "Settings…"))
    #expect(settingsItem.keyEquivalent == ",")
    #expect(settingsItem.keyEquivalentModifierMask == .command)
    let settingsKey = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil,
        characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43
    ))

    controller.workspace.showWorkspace()
    #expect(controller.workspace.workspacePanel.isVisible)
    #expect(menu.performKeyEquivalent(with: settingsKey))
    let workspaceDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while settingsCalls < 1, ContinuousClock.now < workspaceDeadline {
        try await Task.sleep(for: .milliseconds(15))
    }
    #expect(settingsCalls == 1)

    controller.presentQuickDraft("draft stays", feedback: "")
    #expect(controller.isQuickPadVisible)
    #expect(menu.performKeyEquivalent(with: settingsKey))
    let padDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while settingsCalls < 2, ContinuousClock.now < padDeadline {
        try await Task.sleep(for: .milliseconds(15))
    }
    #expect(settingsCalls == 2)
    #expect(controller.quickPadController.editor.string == "draft stays")
    _ = await composition.service.shutdown()
}

@MainActor @Test func workspaceCommandOpensExistingWindowWithHiddenStatusItem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-workspace-command-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (composition, controller) = try await lifecycleFixture(root: root, presentsInterface: true)
    defer { controller.stop() }
    var settings = composition.snapshot.read()
    settings.modules["launcher"] = .init(enabled: false)
    await composition.applyRuntimePolicy(settings)
    #expect(!composition.snapshot.permits("launcher.open"))
    controller.canInvoke = { composition.snapshot.permits($0) }
    controller.refreshActionAvailability()
    controller.statusPresenter?.statusItem.isVisible = false
    controller.presentQuickDraft("/wo", feedback: "")
    let pad = controller.quickPadController
    pad.editor.setSelectedRange(NSRange(location: 3, length: 0))
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(pad.completionChoices.map(\.canonicalText).contains("/workspace"))
    pad.editor.string = "/workspace"
    pad.editor.setSelectedRange(NSRange(location: 10, length: 0))
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(pad.footerState.routeLine == .outcome("Workspace"))
    controller.quickPadController.editor.onSubmit?(.enterShowHere)
    #expect(controller.workspace.workspacePanel.isVisible)
    #expect(!controller.isQuickPadVisible)
    #expect(controller.padRunID == nil)
    #expect(await composition.store.recentRuns().isEmpty)
    _ = await composition.service.shutdown()
}

@MainActor @Test func stoppedWorkspaceCannotFinishSuspendedStartup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-stop-start-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (composition, controller) = try await lifecycleFixture(root: root)
    defer { controller.stop() }
    var snapshots = 0
    controller.afterResultsSnapshot = { [weak controller] _ in
        snapshots += 1
        controller?.stop()
    }
    do {
        try await controller.show()
        Issue.record("A stopped controller must not finish startup")
    } catch is CancellationError { }
    #expect(snapshots == 1)
    try await Task.sleep(for: .milliseconds(220))
    #expect(snapshots == 1, "No poller may be restarted after stop")
    #expect(controller.statusPresenter == nil)
    #expect(!controller.hasForegroundSurface)
    _ = await composition.service.shutdown()
}

@MainActor @Test func hostWindowCloseIsHandledBeforeNativeDraftDismissal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-host-close-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (composition, controller) = try await lifecycleFixture(root: root)
    defer { controller.stop() }
    controller.presentQuickDraft("keep this draft", feedback: "")
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    var closes = 0
    controller.onCloseHostWindow = { candidate in
        guard candidate === window else { return false }
        closes += 1
        window.close()
        return true
    }
    controller.closeFrontSurface(keyWindow: window)
    #expect(closes == 1)
    #expect(controller.quickPadController.editor.string == "keep this draft")
    #expect(controller.hasForegroundSurface, "Closing host Settings must leave native editing ownership alone")
    _ = await composition.service.shutdown()
}

private actor LifecycleSelectionValue {
    var value: OmniSelectionSourceResult = .empty
    func read() -> OmniSelectionSourceResult { value }
    func set(_ newValue: OmniSelectionSourceResult) { value = newValue }
}

private struct LifecycleChangingSelection: OmniSelectionSnapshotProvider {
    let value: LifecycleSelectionValue
    func accessibilityPermissionIsGranted() -> Bool { true }
    @MainActor func frontmostApplication() -> OmniSelectionApplication? {
        .init(processID: 4242, name: "Fixture")
    }
    func selection(in application: OmniSelectionApplication, maximumTextLength: Int) async -> OmniSelectionSourceResult {
        await value.read()
    }
}

@MainActor @Test func closingQuickPadDiscardsRequestAndNextOpenCapturesFreshSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-fresh-pad-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = LifecycleSelectionValue()
    let (composition, controller) = try await lifecycleFixture(root: root,
        selection: NativeSelectionCapture(provider: LifecycleChangingSelection(value: selection)),
        presentsInterface: true)
    defer { controller.stop() }
    controller.presentQuickDraft("old request", feedback: "")
    let pad = controller.quickPadController
    pad.setModelChoices([OmniModelChoice(id: "fixture", label: "Fixture model")])
    pad.selectModelProfile(id: "fixture")
    controller.importQuickSelection(CapturedOmniSelection(text: "old selection", appName: "Old app",
        processID: 4242, windowTitle: "Old window", bundleIdentifier: "fixture.old"))
    pad.setAnnotations([OmniTextAnnotation(range: NSRange(location: 0, length: 3), guidance: "old note")])
    pad.editor.undoManager?.registerUndo(withTarget: controller) { _ in }
    #expect(pad.editor.undoManager?.canUndo == true)
    #expect(!pad.annotations.isEmpty)
    #expect(pad.provenance != nil)
    #expect(pad.selectedModelProfileID == "fixture")

    controller.closeFrontSurface(keyWindow: controller.quickPanel)
    #expect(!controller.isQuickPadVisible)
    #expect(pad.editor.string.isEmpty)
    #expect(pad.annotations.isEmpty)
    #expect(pad.provenance == nil)
    #expect(controller.quickProvenance == nil)
    #expect(pad.selectedModelProfileID == nil)
    #expect(pad.editor.undoManager?.canUndo == false)

    await controller.beginQuickRequest()
    #expect(controller.isQuickPadVisible)
    #expect(pad.editor.string.isEmpty)
    #expect(pad.provenance == nil)
    controller.dismissQuickPad(restoreFocus: false)

    await selection.set(.selected("fresh external selection"))
    await controller.beginQuickRequest()
    #expect(pad.editor.string == "fresh external selection")
    #expect(pad.provenance?.source == "Fixture")
    #expect(controller.quickProvenance?.appName == "Fixture")
    #expect(pad.annotations.isEmpty)
    _ = await composition.service.shutdown()
}

private struct LifecycleSelection: OmniSelectionSnapshotProvider {
    var hostOwnsFocus = false
    let onRead: @MainActor @Sendable () -> Void
    func accessibilityPermissionIsGranted() -> Bool { true }
    @MainActor func frontmostApplication() -> OmniSelectionApplication? {
        .init(processID: hostOwnsFocus ? ProcessInfo.processInfo.processIdentifier : 4242, name: "Fixture")
    }
    func selection(in application: OmniSelectionApplication, maximumTextLength: Int) async -> OmniSelectionSourceResult {
        await onRead()
        return .selected("fresh external selection")
    }
}

@MainActor @Test func hostPickerTransfersReturnOriginWithoutReadingHiddenAppSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-origin-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = NativeSelectionCapture(provider: LifecycleSelection(hostOwnsFocus: true, onRead: {
        Issue.record("A key host picker must not cause a hidden application AX read")
    }))
    let (composition, controller) = try await lifecycleFixture(root: root, selection: selection)
    defer { controller.stop() }
    controller.hostSurfaceOrigin = { (active: true, processID: 4242) }
    #expect(await controller.beginEphemeralTool(.translation))
    #expect(controller.capturedExternalOriginPID == 4242)
    #expect(controller.ephemeralTool?.session.input == "")
    #expect(controller.ephemeralTool?.viewController.provenance == nil)
    _ = await composition.service.shutdown()
}

@MainActor @Test func moduleDisabledDuringSelectionCannotReopenItsToolOrCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-pending-disable-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var enabled = true
    let selection = NativeSelectionCapture(provider: LifecycleSelection(onRead: { enabled = false }))
    let (composition, controller) = try await lifecycleFixture(root: root, selection: selection)
    defer { controller.stop() }
    controller.canInvoke = { _ in enabled }
    #expect(!(await controller.beginEphemeralTool(.translation)))
    #expect(controller.ephemeralTool == nil)
    enabled = true
    #expect(!(await controller.beginCapture()))
    #expect(!controller.isCaptureVisible)
    enabled = true
    #expect(!(await controller.beginSelectedWebSearch()))
    #expect(!controller.hasForegroundSurface)
    controller.stop()
    enabled = true
    await controller.beginQuickRequest()
    #expect(!(await controller.beginSelectedWebSearch()))
    #expect(!controller.hasForegroundSurface)
    _ = await composition.service.shutdown()
}
