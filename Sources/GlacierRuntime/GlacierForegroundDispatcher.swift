import Foundation
import GlacierWorkspace
import HyperOverlayRuntime

@MainActor
final class GlacierDesktopLifecycle {
    private(set) var isTerminating = false

    func terminate() { isTerminating = true }
    var isActive: Bool { !isTerminating }

    func afterPriorChange(_ prior: Task<Bool, Never>?) async -> Bool {
        _ = await prior?.value
        return isActive
    }
}

/// Orders desktop hotkeys before their asynchronous native work begins.
@MainActor
final class GlacierForegroundDispatcher {
    enum NativeAction: Equatable {
        case launcher
        case capture
        case webSearch
        case tool(OmniEphemeralToolKind)

        init?(id: String) {
            switch id {
            case "launcher.open": self = .launcher
            case "capture.new": self = .capture
            case "browser.search-selection": self = .webSearch
            default:
                guard let kind = OmniEphemeralToolKind.allCases.first(where: { "tool." + $0.descriptor.id == id }) else { return nil }
                self = .tool(kind)
            }
        }

        var actionID: String {
            switch self {
            case .launcher: "launcher.open"
            case .capture: "capture.new"
            case .webSearch: "browser.search-selection"
            case .tool(let kind): "tool." + kind.descriptor.id
            }
        }

        func perform(on native: OmniNativeWorkspaceController) async {
            switch self {
            case .launcher: await native.beginQuickRequest()
            case .capture: _ = await native.beginCapture()
            case .webSearch: _ = await native.beginSelectedWebSearch()
            case .tool(let kind): _ = await native.beginEphemeralTool(kind)
            }
        }
    }

    private var generation: UInt64 = 0
    private let invalidateNative: @MainActor () -> Void
    private let prepareNative: @MainActor () -> Void
    private let canOpenNative: @MainActor (NativeAction) -> Bool
    private let openNative: @MainActor (NativeAction) async -> Void

    init(invalidateNative: @escaping @MainActor () -> Void,
         prepareNative: @escaping @MainActor () -> Void,
         canOpenNative: @escaping @MainActor (NativeAction) -> Bool,
         openNative: @escaping @MainActor (NativeAction) async -> Void) {
        self.invalidateNative = invalidateNative
        self.prepareNative = prepareNative
        self.canOpenNative = canOpenNative
        self.openNative = openNative
    }

    /// Native menu and notification intents also win over queued hotkeys.
    func nativeIntentReserved() { generation &+= 1 }
    func nativeWillForeground() { prepareNative() }

    /// A clipboard, key action, or contributed tool wins immediately.
    func supersedeNative() {
        generation &+= 1
        invalidateNative()
    }

    @discardableResult
    func dispatch(_ id: String) -> Task<Void, Never>? {
        guard let action = NativeAction(id: id) else { return nil }
        supersedeNative()
        let ticket = generation
        return Task { [weak self] in
            guard let self, self.generation == ticket, self.canOpenNative(action) else { return }
            await self.openNative(action)
        }
    }

    /// Collection commands also cross an async boundary before their own token exists.
    @discardableResult
    func dispatchEffect(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        supersedeNative()
        let ticket = generation
        return Task { [weak self] in
            guard let self, self.generation == ticket, !Task.isCancelled else { return }
            await operation()
        }
    }

    func handoffToClipboard(
        query: String, explicitPID: pid_t?, authoritativeOrigin: Bool,
        nativeVisible: Bool, capturedNativeOrigin: @MainActor () -> pid_t?,
        frontmostPID: @MainActor () -> pid_t?, hostPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        dismissNative: @MainActor () -> Void,
        showClipboard: @MainActor (String, pid_t?) -> Void
    ) {
        let target: pid_t?
        if authoritativeOrigin {
            target = explicitPID
        } else {
            target = HostSurfaceRouting.clipboardOrigin(
                explicitPID: explicitPID, omniVisible: nativeVisible,
                omniOriginPID: nativeVisible ? capturedNativeOrigin() : nil,
                frontmostPID: frontmostPID(), hostPID: hostPID)
        }
        supersedeNative()
        dismissNative()
        showClipboard(query, target)
    }
}
