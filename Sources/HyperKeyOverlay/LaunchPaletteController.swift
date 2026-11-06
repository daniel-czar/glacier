import AppKit

/// Disposable Hyper+A palette. It remembers only the last successful launch
/// in this controller instance; the manifest remains the ordered source.
@MainActor
public final class LaunchPaletteController: NSObject {
    public private(set) var applications: [LaunchApplication] = []
    public private(set) var isShown = false
    public private(set) var panel: LaunchPalettePanel?
    public private(set) var lastLaunchedBundleID: String?
    public var onError: ((String) -> Void)?

    private let effects: any LaunchApplicationEffects
    private let workspace: NSWorkspace
    private let presentsInterface: Bool
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var observingWorkspace = false
    private var hoveredIndex: Int?
    private var activationGeneration = 0
    private var lastSuccessfulActivationGeneration = 0

    public init(effects: any LaunchApplicationEffects = SystemLaunchApplicationEffects(),
                workspace: NSWorkspace = .shared, presentsInterface: Bool = true) {
        self.effects = effects
        self.workspace = workspace
        self.presentsInterface = presentsInterface
        super.init()
    }

    isolated deinit {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if observingWorkspace { workspace.notificationCenter.removeObserver(self) }
    }

    /// Resolve manifest IDs without changing their order. Invalid entries are
    /// returned to the caller for manifest lint and omitted from the UI.
    @discardableResult
    public func load(bundleIDs: [String], keyOverrides: [String: String] = [:]) -> [LaunchPaletteLoadProblem] {
        var resolved: [LaunchApplication] = []
        var problems: [LaunchPaletteLoadProblem] = []
        var seen = Set<String>()
        for id in bundleIDs {
            if !seen.insert(id).inserted {
                problems.append(.init(bundleID: id, message: "Duplicate Launch application \(id)"))
            } else if let app = effects.resolve(bundleID: id) {
                let keyed = LaunchApplication(bundleID: app.bundleID, name: app.name, url: app.url,
                                              icon: app.icon, key: keyOverrides[id] ?? app.key)
                if resolved.count < 8 {
                    resolved.append(keyed)
                } else {
                    problems.append(.init(bundleID: id, message: "Launch accepts at most eight applications"))
                }
            } else {
                problems.append(.init(bundleID: id, message: "Launch application \(id) is not installed"))
            }
        }
        problems.append(contentsOf: load(entries: resolved))
        return problems
    }

    /// Injected resolved entries are useful to callers that already validate
    /// a manifest and to tests that must not launch real applications.
    @discardableResult
    public func load(entries: [LaunchApplication]) -> [LaunchPaletteLoadProblem] {
        var candidates = Array(entries.prefix(8))
        var problems: [LaunchPaletteLoadProblem] = entries.dropFirst(8).map {
            .init(bundleID: $0.bundleID, message: "Launch accepts at most eight applications")
        }
        // Resolve collisions after invalid rows are removed: default keys
        // depend on the final grid width, so a removal can change later caps.
        while true {
            let keys = LaunchPaletteLayout.keys(for: candidates)
            var seen = Set<String>()
            var invalid: Int?
            for (index, key) in keys.enumerated() {
                if key.count != 1 || key.first.map({ $0 < "A" || $0 > "Z" }) != false {
                    problems.append(.init(bundleID: candidates[index].bundleID,
                                          message: "Launch key for \(candidates[index].bundleID) must be one letter A–Z"))
                    invalid = index
                    break
                }
                if !seen.insert(key).inserted {
                    problems.append(.init(bundleID: candidates[index].bundleID,
                                          message: "Launch key \(key) is assigned more than once"))
                    invalid = index
                    break
                }
            }
            guard let invalid else { break }
            candidates.remove(at: invalid)
        }
        applications = candidates
        if let lastLaunchedBundleID,
           !applications.contains(where: { $0.bundleID == lastLaunchedBundleID }) {
            self.lastLaunchedBundleID = nil
        }
        if isShown {
            guard !applications.isEmpty else { dismiss(); return problems }
            refreshPanel()
        }
        return problems
    }

    public func toggle() { isShown ? dismiss() : show() }

    public func show() {
        guard !applications.isEmpty else { return }
        guard !isShown else { return }
        isShown = true
        hoveredIndex = nil
        startObserving()
        refreshPanel()
        guard presentsInterface, let panel else { return }
        installClickAwayMonitors()
        panel.makeKeyAndOrderFront(nil)
        panel.paletteView.refreshHoverFromPointer()
    }

    public func dismiss() {
        guard isShown else { return }
        isShown = false
        hoveredIndex = nil
        removeClickAwayMonitors()
        stopObserving()
        panel?.orderOut(nil)
    }

    /// A direct input seam for the panel and focused tests. The visible panel
    /// swallows every keydown; only bare positional keys and Enter act.
    public func keyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard isShown else { return }
        if keyCode == 53 { dismiss(); return }
        let hyper: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let actual = modifiers.intersection(.deviceIndependentFlagsMask)
        // Carbon owns all Hyper chords, including repeat A. Handling one here
        // could race its callback and reopen a just-dismissed palette.
        if actual.isSuperset(of: hyper) { return }
        guard actual.intersection([.command, .option, .control]).isEmpty else { return }
        if keyCode == 36 || keyCode == 76 {
            if let selected = selectedIndex { activate(at: selected) }
        } else if let index = LaunchPaletteLayout.index(forKeyCode: keyCode, applications: applications) {
            activate(at: index)
        }
    }

    public func activate(at index: Int) {
        guard isShown, applications.indices.contains(index) else { return }
        let app = applications[index]
        let alreadyFrontmost = effects.isFrontmost(bundleID: app.bundleID)
        dismiss()
        if alreadyFrontmost { return }
        activationGeneration += 1
        let generation = activationGeneration
        effects.activate(app) { [weak self] error in
            guard let self else { return }
            if let error {
                self.onError?("Could not open \(app.name): \(error.localizedDescription)")
            } else if generation > self.lastSuccessfulActivationGeneration {
                self.lastSuccessfulActivationGeneration = generation
                self.lastLaunchedBundleID = app.bundleID
                if self.isShown { self.panel?.paletteView.selectedIndex = self.selectedIndex }
            }
        }
    }

    public var selectedIndex: Int? {
        guard !applications.isEmpty else { return nil }
        if let hoveredIndex, applications.indices.contains(hoveredIndex) { return hoveredIndex }
        if let lastLaunchedBundleID,
           let index = applications.firstIndex(where: { $0.bundleID == lastLaunchedBundleID }) { return index }
        return 0
    }

    private func refreshPanel() {
        guard presentsInterface else { return }
        if panel == nil {
            let built = LaunchPalettePanel()
            built.onKeyDown = { [weak self] code, modifiers in self?.keyDown(keyCode: code, modifiers: modifiers) }
            built.paletteView.onSelect = { [weak self] index in self?.activate(at: index) }
            built.paletteView.onHover = { [weak self] index in
                self?.hoveredIndex = index
                self?.panel?.paletteView.selectedIndex = self?.selectedIndex
            }
            panel = built
        }
        guard let panel else { return }
        panel.paletteView.resetHover()
        panel.paletteView.entries = applications
        panel.paletteView.runningBundleIDs = Set(applications.filter { effects.isRunning(bundleID: $0.bundleID) }.map(\.bundleID))
        panel.paletteView.selectedIndex = selectedIndex
        let visible = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.apply(count: applications.count, visible: visible)
    }

    private func startObserving() {
        guard !observingWorkspace else { return }
        observingWorkspace = true
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
    }

    private func stopObserving() {
        guard observingWorkspace else { return }
        workspace.notificationCenter.removeObserver(self)
        observingWorkspace = false
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        guard isShown else { return }
        panel?.paletteView.runningBundleIDs = Set(applications.filter { effects.isRunning(bundleID: $0.bundleID) }.map(\.bundleID))
    }

    private func installClickAwayMonitors() {
        guard localClickMonitor == nil, globalClickMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.dismiss() }
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func removeClickAwayMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }
}
