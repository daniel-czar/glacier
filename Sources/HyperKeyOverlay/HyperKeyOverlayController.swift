import AppKit
import HyperOverlayCore
import HyperOverlayRuntime

/// Watches a configured modifier group and keys typed while it is down.
/// Global monitors see other apps' events
/// under the host's Accessibility grant; local monitors see the host's own.
/// Chords another app consumes (Keyboard Maestro's) are not seen.
@MainActor
final class HyperHoldMonitor {
    static let hyperFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    var requiredFlags: NSEvent.ModifierFlags = hyperFlags
    private(set) var globalAvailable = false
    var onHyperChanged: ((Bool) -> Void)?
    var onKeyDown: ((UInt16) -> Void)?
    private var monitors: [Any] = []
    private var hyperDown = false

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global); globalAvailable = true }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hyperDown = false
        globalAvailable = false
    }

    func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let down = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: requiredFlags)
            guard down != hyperDown else { return }
            hyperDown = down
            onHyperChanged?(down)
        case .keyDown:
            onKeyDown?(event.keyCode)
        default:
            break
        }
    }
}

/// The plain `esc` claim while pinned; a protocol so tests need no Carbon.
@MainActor
public protocol HyperEscapeClaim: AnyObject {
    func claim(handler: @escaping @MainActor () -> Void) -> Bool
    func release()
}

extension TransientHotKey: HyperEscapeClaim {
    public func claim(handler: @escaping @MainActor () -> Void) -> Bool { claim(keyCode: 53, handler: handler) }
}

/// The Hyper overlay (H18): a hint owned by the keyboard state, not a fifth
/// surface. It touches no lifecycle, arbiter or focus, and stores nothing.
@MainActor
public final class HyperKeyOverlayController {
    public let layout: HyperKeyboardLayout
    public private(set) var catalog: HyperBindingCatalog
    public var presentation: HyperHoldStateMachine.Presentation { machine.presentation }
    /// Ordered in and not fading out.
    public private(set) var isShown = false
    public private(set) var panel: HyperKeyOverlayPanel?

    private var machine = HyperHoldStateMachine()
    private let registered: @MainActor () -> [OverlayHotKeyBinding]
    private let bindingsURL: URL?
    private let padFrame: @MainActor () -> NSRect?
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let escapeClaim: any HyperEscapeClaim
    private let presentsInterface: Bool
    private let holdModifiers: NSEvent.ModifierFlags?
    private var monitor: HyperHoldMonitor?
    private var fadeGeneration = 0
    private var escapeClaimed = false
    private var fileStamp: Date?
    private var file: HyperBindingsFile?
    private var fileProblem: String?
    /// Live labels by overlay id, read at every show (Collect's counts).
    public var labelOverrides: (@MainActor () -> [String: String])?

    public init(
        layout: HyperKeyboardLayout = .ukISOMacBook,
        holdModifiers: NSEvent.ModifierFlags? = nil,
        registered: @escaping @MainActor () -> [OverlayHotKeyBinding],
        bindingsURL: URL?,
        padFrame: @escaping @MainActor () -> NSRect? = { nil },
        presentsInterface: Bool = true,
        escapeClaim: any HyperEscapeClaim = TransientHotKey(),
        schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        }
    ) {
        self.layout = layout
        self.holdModifiers = holdModifiers
        self.registered = registered
        self.bindingsURL = bindingsURL
        self.padFrame = padFrame
        self.presentsInterface = presentsInterface
        self.escapeClaim = escapeClaim
        self.schedule = schedule
        self.catalog = HyperBindingCatalog(bindings: [:], problems: [])
    }

    /// Builds the panel now so the threshold only orders it in (no build
    /// latency); `monitoringKeyboard` installs the hold monitor.
    public func start(monitoringKeyboard: Bool) {
        refreshBindings()
        if presentsInterface, panel == nil {
            panel = HyperKeyOverlayPanel(layout: layout, catalog: catalog)
            if let holdModifiers {
                var pressed: Set<String> = []
                if holdModifiers.contains(.command) { pressed.formUnion(["command", "right-command"]) }
                if holdModifiers.contains(.option) { pressed.formUnion(["option", "right-option"]) }
                if holdModifiers.contains(.control) { pressed.insert("control") }
                if holdModifiers.contains(.shift) { pressed.formUnion(["shift", "right-shift"]) }
                panel?.keysView.pressedCapIDs = pressed
            }
        }
        guard monitoringKeyboard, (holdModifiers ?? HyperHoldMonitor.hyperFlags) != [], monitor == nil else { return }
        let monitor = HyperHoldMonitor()
        monitor.requiredFlags = holdModifiers ?? HyperHoldMonitor.hyperFlags
        monitor.onHyperChanged = { [weak self] down in self?.hyperChanged(down: down) }
        monitor.onKeyDown = { [weak self] code in self?.keyDown(keyCode: code) }
        monitor.start()
        self.monitor = monitor
    }

    public func stop() {
        monitor?.stop()
        monitor = nil
        apply(machine.dismiss())
        if escapeClaimed { escapeClaim.release(); escapeClaimed = false }
    }

    /// Re-reads the bindings file when it changed and rebuilds the catalog
    /// from what actually registered.
    public func refreshBindings() {
        if let bindingsURL {
            let stamp = (try? bindingsURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if stamp != fileStamp || (file == nil && fileProblem == nil) {
                fileStamp = stamp
                do {
                    file = try HyperBindingsFile.decode(Data(contentsOf: bindingsURL))
                    fileProblem = nil
                } catch {
                    file = nil
                    fileProblem = FileManager.default.fileExists(atPath: bindingsURL.path)
                        ? "\(bindingsURL.lastPathComponent) could not be read: \(error)"
                        : "\(bindingsURL.lastPathComponent) is missing; native chords use fallback labels"
                }
            }
        }
        let built = HyperBindingCatalog.build(registered: registered(), file: file, layout: layout,
                                              labels: labelOverrides?() ?? [:])
        catalog = HyperBindingCatalog(bindings: built.bindings, problems: (fileProblem.map { [$0] } ?? []) + built.problems)
        panel?.keysView.catalog = catalog
    }

    /// Facts for the host's status.
    public var statusFacts: [String: String] {
        var facts = [
            "presentation": "\(machine.presentation)",
            "bindings": "\(catalog.bindings.count)",
            "native": "\(catalog.bindings.values.filter { $0.owner == .native }.count)",
            "keyboard_maestro": "\(catalog.bindings.values.filter { $0.owner == .keyboardMaestro }.count)",
            "monitoring": monitor == nil ? "false" : "true",
            "global_monitoring_available": monitor?.globalAvailable == true ? "true" : "false",
        ]
        if let bindingsURL { facts["bindings_file"] = bindingsURL.path }
        if !catalog.problems.isEmpty { facts["problems"] = catalog.problems.joined(separator: " | ") }
        return facts
    }

    // MARK: Inputs

    public func hyperChanged(down: Bool) { apply(machine.hyperChanged(down: down)) }

    public func keyDown(keyCode: UInt16) {
        // `esc` falls back to observation when the claim failed.
        if keyCode == 53, machine.presentation == .pinned, !escapeClaimed {
            apply(machine.escape())
            return
        }
        apply(machine.keyDown())
    }

    /// A native chord fired: its action runs, the hint goes.
    public func bindingFired(_ overlayID: String) { apply(machine.bindingFired()) }

    /// Hyper+H, or `show hyper-help` on the socket.
    public func helpPressed() { apply(machine.helpPressed()) }

    public func escape() { apply(machine.escape()) }

    public func dismiss() { apply(machine.dismiss()) }

    // MARK: Effects

    private func apply(_ effects: [HyperHoldStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startTimer(let token):
                schedule(HyperHoldStateMachine.holdThreshold) { [weak self] in
                    guard let self else { return }
                    self.apply(self.machine.timerFired(token: token))
                }
            case .cancelTimer:
                break // a stale token is ignored by the machine
            case .present(let presentation):
                present(presentation == .pinned ? .pinned : .held)
            case .hide(let fade):
                hide(fade: fade)
            case .claimEscape:
                escapeClaimed = escapeClaim.claim { [weak self] in self?.escape() }
            case .releaseEscape:
                if escapeClaimed { escapeClaim.release() }
                escapeClaimed = false
            }
        }
    }

    private func present(_ mode: HyperKeyOverlayView.Mode) {
        refreshBindings()
        fadeGeneration += 1
        let wasShown = isShown
        isShown = true
        guard presentsInterface else { return }
        if panel == nil { panel = HyperKeyOverlayPanel(layout: layout, catalog: catalog) }
        guard let panel else { return }
        let pad = padFrame()
        let visible = HyperKeyOverlayPlacement.screen(pad: pad)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.size(for: mode, visible: visible)
        var frame = HyperKeyOverlayPlacement.frame(size: size, visible: visible, pad: pad)
        if wasShown, panel.isVisible {
            // Held → pinned while up: keep the top edge, grow downward, but
            // never past the bottom of the screen.
            frame.origin = NSPoint(x: panel.frame.minX, y: max(panel.frame.maxY - size.height, visible.minY + 8))
        }
        panel.apply(mode: mode, frame: frame)
        // Appear at once; this also replaces a fade out still running.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
    }

    private func hide(fade: Bool) {
        fadeGeneration += 1
        let generation = fadeGeneration
        isShown = false
        guard presentsInterface, let panel else { return }
        panel.keysView.hidePopover()
        guard fade, panel.isVisible else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = HyperHoldStateMachine.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, let panel, generation == self.fadeGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }
}
