import AppKit
import Foundation
import GlacierConfiguration
import GlacierConnections
import GlacierWorkspace
import HyperOverlayRuntime
import OmniAdapters
import OmniModels
import Testing
@testable import GlacierRuntime

private struct FixedSelection: OmniSelectionSnapshotProvider {
    func accessibilityPermissionIsGranted() -> Bool { true }
    @MainActor func frontmostApplication() -> OmniSelectionApplication? {
        .init(processID: 42_424, name: "Example", bundleIdentifier: "example.app")
    }
    func selection(in application: OmniSelectionApplication, maximumTextLength: Int) async -> OmniSelectionSourceResult {
        .selected("fresh external selection")
    }
    func focusedWindowTitle(in application: OmniSelectionApplication) -> String? { "Document B" }
}

private actor NoNetwork: ConnectionNetworkTransport {
    func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        throw NSError(domain: "NoNetwork", code: 1)
    }
    func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream {
        throw NSError(domain: "NoNetwork", code: 1)
    }
}

private final class NoSecrets: SecretStore, @unchecked Sendable {
    func insert(_ secret: String, account: UUID) throws { throw NSError(domain: "NoSecrets", code: 1) }
    func read(account: UUID) throws -> String { throw NSError(domain: "NoSecrets", code: 1) }
    func remove(account: UUID) throws { throw NSError(domain: "NoSecrets", code: 1) }
}

@MainActor
@Test func terminatedDesktopGateRejectsAQueuedChangeAfterItsPredecessorResumes() async {
    let lifecycle = GlacierDesktopLifecycle()
    var resumePrior: CheckedContinuation<Bool, Never>?
    let prior = Task<Bool, Never> {
        await withCheckedContinuation { resumePrior = $0 }
    }
    while resumePrior == nil { await Task.yield() }
    let next = Task { await lifecycle.afterPriorChange(prior) }
    await Task.yield()
    lifecycle.terminate()
    resumePrior?.resume(returning: true)
    #expect(await next.value == false)
    #expect(!lifecycle.isActive)
}

@MainActor
@Test func terminationSupersedesQueuedNativeDispatch() async {
    let lifecycle = GlacierDesktopLifecycle()
    var opened = false
    let dispatcher = GlacierForegroundDispatcher(
        invalidateNative: {}, prepareNative: {},
        canOpenNative: { _ in lifecycle.isActive },
        openNative: { _ in opened = true })
    let queued = dispatcher.dispatch("launcher.open")
    lifecycle.terminate()
    dispatcher.supersedeNative()
    await queued?.value
    #expect(!opened)
}

@MainActor
@Test func productionDesktopToolActionReadsFreshExternalSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-dispatch-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try GlacierPaths(home: root, supportOverride: root.appendingPathComponent("Glacier"))
    let composition = try await GlacierComposition.make(
        paths: paths, home: root, hostActions: GlacierHostActions(), applicationRoots: [],
        network: NoNetwork(), secrets: NoSecrets(), platform: RecordingPlatformAdapter(),
        fileEffect: { _, _ in throw NSError(domain: "NoFileEffect", code: 1) })
    let native = OmniNativeWorkspaceController(
        environment: composition.workspace,
        foreground: ForegroundArbitrator(allowedOverlays: ["omni-ephemeral"]),
        presentsInterface: false,
        selectionCapture: NativeSelectionCapture(provider: FixedSelection()),
        notifications: RecordingOmniNotificationClient(),
        ownsApplicationMenu: false,
        ephemeralProducers: [.translation: { _, _ in "unused" }])
    native.canInvoke = { _ in true }

    let action = try #require(GlacierForegroundDispatcher.NativeAction(id: "tool.translate"))
    await action.perform(on: native)
    #expect(native.ephemeralTool?.session.input == "fresh external selection")
    #expect(native.ephemeralTool?.viewController.provenance?.source == "Example")
    #expect(native.ephemeralTool?.viewController.provenance?.detail == "Document B")
    native.stop()
}

@MainActor
@Test func desktopToolHotkeysUseExternalToolRoute() async {
    var opened: [GlacierForegroundDispatcher.NativeAction] = []
    var invalidations = 0
    let dispatcher = GlacierForegroundDispatcher(
        invalidateNative: { invalidations += 1 },
        prepareNative: {},
        canOpenNative: { _ in true },
        openNative: { opened.append($0) })

    for kind in OmniEphemeralToolKind.allCases {
        let task = dispatcher.dispatch("tool." + kind.descriptor.id)
        #expect(task.map { _ in true } ?? false)
        await task?.value
        #expect(opened.last == .tool(kind))
    }
    #expect(invalidations == OmniEphemeralToolKind.allCases.count)
    #expect(dispatcher.dispatch("tool.unknown").map { _ in true } == nil)
}

@MainActor
@Test func newerSynchronousIntentCancelsQueuedNativeActions() async {
    var opened: [GlacierForegroundDispatcher.NativeAction] = []
    var invalidations = 0
    var preparations = 0
    var permitted = true
    let dispatcher = GlacierForegroundDispatcher(
        invalidateNative: { invalidations += 1 },
        prepareNative: { preparations += 1 },
        canOpenNative: { _ in permitted },
        openNative: { opened.append($0) })

    let launcher = dispatcher.dispatch("launcher.open")
    dispatcher.supersedeNative() // Clipboard or another action wins before the task starts.
    await launcher?.value
    #expect(opened.isEmpty)

    let capture = dispatcher.dispatch("capture.new")
    dispatcher.nativeIntentReserved() // Native menu or notification wins.
    dispatcher.nativeWillForeground()
    await capture?.value
    #expect(opened.isEmpty)
    #expect(preparations == 1)

    let web = dispatcher.dispatch("browser.search-selection")
    await web?.value
    #expect(opened == [.webSearch])
    let disabled = dispatcher.dispatch("tool.translate")
    permitted = false
    await disabled?.value
    #expect(opened == [.webSearch])
    #expect(invalidations == 5)
}

@MainActor
@Test func clipboardHandoffCapturesAuthoritativeOriginBeforeNativeDismissal() {
    var events: [String] = []
    var shownPID: pid_t?
    let dispatcher = GlacierForegroundDispatcher(
        invalidateNative: { events.append("invalidate") },
        prepareNative: {},
        canOpenNative: { _ in true },
        openNative: { _ in })

    dispatcher.handoffToClipboard(
        query: "needle", explicitPID: 71, authoritativeOrigin: true,
        nativeVisible: false,
        capturedNativeOrigin: { Issue.record("Native origin must not replace an authoritative origin"); return 1 },
        frontmostPID: { Issue.record("Frontmost app must not replace an authoritative origin"); return 2 },
        dismissNative: { events.append("dismiss") },
        showClipboard: { query, pid in events.append("show:" + query); shownPID = pid })
    #expect(shownPID == 71)
    #expect(events == ["invalidate", "dismiss", "show:needle"])

    events.removeAll()
    dispatcher.handoffToClipboard(
        query: "", explicitPID: nil, authoritativeOrigin: false,
        nativeVisible: true,
        capturedNativeOrigin: { events.append("capture"); return 82 },
        frontmostPID: { events.append("front"); return 99 }, hostPID: 99,
        dismissNative: { events.append("dismiss") },
        showClipboard: { _, pid in events.append("show"); shownPID = pid })
    #expect(shownPID == 82)
    #expect(events == ["capture", "front", "invalidate", "dismiss", "show"])

    events.removeAll()
    dispatcher.handoffToClipboard(
        query: "", explicitPID: nil, authoritativeOrigin: false,
        nativeVisible: true,
        capturedNativeOrigin: { events.append("capture"); return 82 },
        frontmostPID: { events.append("front"); return 91 }, hostPID: 99,
        dismissNative: { events.append("dismiss") },
        showClipboard: { _, pid in events.append("show"); shownPID = pid })
    #expect(shownPID == 91)
    #expect(events == ["capture", "front", "invalidate", "dismiss", "show"])
}

@MainActor
@Test func hostCloseHandlerConsumesOnlyTheSettingsWindow() {
    _ = NSApplication.shared
    let settings = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let other = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    settings.isReleasedWhenClosed = false
    other.isReleasedWhenClosed = false
    #expect(!GlacierDesktop.closeHostSettings(other, settingsWindow: settings))
    #expect(!GlacierDesktop.closeHostSettings(settings, settingsWindow: nil))
    #expect(GlacierDesktop.closeHostSettings(settings, settingsWindow: settings))
}

@MainActor @Test func queuedCollectionEffectCannotRunAfterAReplacementOrShutdown() async {
    var effects = 0
    let dispatcher = GlacierForegroundDispatcher(invalidateNative: {}, prepareNative: {},
        canOpenNative: { _ in true }, openNative: { _ in })
    let old = dispatcher.dispatchEffect { effects += 1 }
    dispatcher.nativeIntentReserved()
    await old.value
    #expect(effects == 0)
    let quitting = dispatcher.dispatchEffect { effects += 1 }
    dispatcher.supersedeNative()
    await quitting.value
    #expect(effects == 0)
    await dispatcher.dispatchEffect { effects += 1 }.value
    #expect(effects == 1)
}
