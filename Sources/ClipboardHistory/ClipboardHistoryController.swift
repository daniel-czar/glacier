import AppKit
import ApplicationServices
import Foundation
import HyperOverlayRuntime
import ImageIO
import OmniCore
import OmniPresentation
import UniformTypeIdentifiers

/// What a ⌘Y push did (C95, D5): whether the stack was full, and how to take
/// the push back. The host owns the stash; Clipboard only asks.
public struct ClipboardStashPush {
    public let droppedOldest: Bool
    public let undo: @MainActor () -> Bool

    public init(droppedOldest: Bool, undo: @escaping @MainActor () -> Bool) {
        self.droppedOldest = droppedOldest
        self.undo = undo
    }
}

/// One resident service, independent of Omni's run history and launcher index.
@MainActor
public final class ClipboardHistoryController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSMenuDelegate {
    public static let overlayID = "hyper-clipboard"
    /// The Keep for choices, in the panel menu and in Settings → Clipboard.
    public static let retentionChoices = [24, 36, 72, 168, 336, 720]
    /// Settings → Clipboard → Paste (H20): what Return pastes. ⇧↩ always
    /// pastes plain text and ⌥↩ always the copied flavours.
    public var pasteMode: OmniPasteMode = .asCopied { didSet { refreshStatus() } }
    /// Capture paused or resumed here (the panel menu), for the status menu.
    public var onSettingsChanged: (@MainActor () -> Void)?
    /// The app's settings owner persists a panel capture choice and then applies
    /// its effective policy through `setCaptureEnabled`. Nil keeps local behavior.
    public var onCaptureIntent: (@MainActor (Bool) async throws -> Void)?
    private let store: ClipboardHistoryStore
    /// Injectable payload wait for deterministic lifecycle tests.
    var payloadLoader: (@Sendable (UUID) async throws -> ClipboardHistoryPayload?)?
    /// Test seam for observing the exact origin handed to the paste target.
    var targetResolver: @MainActor (pid_t?) -> PasteTarget? = { PasteTarget($0) }
    private let capture: ClipboardHistoryCapture
    private let foreground: ForegroundArbitrator
    private var settings = ClipboardHistorySettings()
    private var entries: [ClipboardHistorySummary] = []
    private var timer: Timer?
    private var captureTask: Task<Void, Never>?
    private var monitor: Any?
    private var ready = false
    private var revision = 0
    private var listRevision = 0
    private var previewRevision = 0
    private var target: PasteTarget?
    private var statusMessage: String?
    private var captureIntentTask: Task<Void, Never>?
    private var busy = false
    /// Narrow test seam: the last recall's completion, independent of its payload wait.
    var recallTask: Task<Void, Never>?
    private var maintenanceTicks = 0
    private var activationObserver: NSObjectProtocol?
    private var capacityWarningAtUsage: Int?
    private var storageUsage: (usedBytes: Int, capacityBytes: Int)?
    private var pendingCapture: (ClipboardHistoryPayload, ClipboardHistorySource)?
    private var maintenanceRequested = false
    private var clearInProgress = false
    private let panel = OverlayPanelFactory.makePanel(size: NSSize(width: 640, height: 590))
    private let search = OmniEphemeralTextView()
    private let searchScroll = NSScrollView()
    private let toolPill = OmniToolPillView(title: "Clipboard")
    private let table = NSTableView()
    private let list = NSScrollView()
    private let imagePreview = NSImageView()
    private let textPreview = NSTextView()
    private let textScroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let keyHintsView = OmniKeyHintsView()
    private let pasteButton = OmniPadRunButton()
    private let actionsMenu = NSMenu(title: "Clipboard history")
    private let thumbnails = NSCache<NSUUID, NSImage>()
    /// ⌘Y Stash (C95, D5): pushes the selected row onto Omni's stash. Nil where
    /// no stash is composed; the verb and its hint are absent then.
    public var onStash: (@MainActor (ClipboardHistoryPayload, ClipboardHistorySummary) -> ClipboardStashPush?)?
    /// Holds the stash pushes made while the picker is open; cleared on close.
    public let stashUndoManager = UndoManager()
    /// `Stashed · now active`: shown until the next keystroke, never timed.
    public private(set) var notice: String?

    public init(store: ClipboardHistoryStore, foreground: ForegroundArbitrator,
                pasteboard: NSPasteboard = .general,
                source: @escaping () -> ClipboardHistorySource = {
                    let app = NSWorkspace.shared.frontmostApplication
                    return ClipboardHistorySource(bundleID: app?.bundleIdentifier, name: app?.localizedName)
                }) {
        self.store = store
        self.foreground = foreground
        capture = ClipboardHistoryCapture(pasteboard: pasteboard, currentSource: source)
        super.init()
        buildInterface()
    }

    public var capturedExternalOriginPID: pid_t? { target?.pid }
    public var isVisible: Bool { panel.isVisible }
    public var isKeyWindow: Bool { panel.isKeyWindow }
    public var statusFacts: [String: String] {
        var facts = ["ready": String(ready), "paused": String(settings.paused),
         "retentionHours": String(settings.retentionHours), "visible": String(isVisible),
         "error": statusMessage ?? ""]
        if let storageUsage {
            facts["storageUsedBytes"] = String(storageUsage.usedBytes)
            facts["storageCapacityBytes"] = String(storageUsage.capacityBytes)
        }
        return facts
    }

    public var isMonitoring: Bool { ready && timer != nil }

    /// Start/recover only after the canonical owner has committed its intent.
    /// Persist that intent before installing a poller, so stale pause metadata cannot briefly resume capture.
    public func start(effectiveCapture enabled: Bool) async throws {
        stop()
        _ = try await store.load()
        var effective = try await store.settings()
        effective.paused = !enabled
        try await store.updateSettings(effective)
        settings = effective
        await start()
        guard isMonitoring, settings.paused == !enabled else {
            stop()
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    public func start() async {
        do {
            _ = try await store.load()
            settings = try await store.settings()
            try await recoverCapacityIfFreed()
            guard !Task.isCancelled else { return }
            capture.resetBaseline()
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture.noteSourceTransition() }
            }
            ready = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            refreshStatus()
        } catch { fail("Clipboard history could not open its local store.") }
    }

    public func stop() {
        ready = false
        timer?.invalidate(); timer = nil
        captureTask?.cancel(); captureTask = nil
        pendingCapture = nil; maintenanceRequested = false
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        dismiss(restoreFocus: false)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    public func show(query: String = "", originPID: pid_t? = nil) {
        installKeyboardMonitor()
        capturePendingBeforeForeground()
        revision &+= 1
        busy = false
        target = targetResolver(originPID)
        if foreground.activeOverlay != Self.overlayID { _ = foreground.show(Self.overlayID) }
        search.string = query
        layoutInterface()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrame(OverlayPanelPlacement.frame(size: panel.frame.size, visibleFrame: screen.visibleFrame), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        refresh()
    }

    public func dismiss(restoreFocus: Bool) {
        stashUndoManager.removeAllActions()
        notice = nil
        revision &+= 1
        listRevision &+= 1
        previewRevision &+= 1
        busy = false
        recallTask = nil
        panel.orderOut(nil)
        if foreground.activeOverlay == Self.overlayID { _ = foreground.close() }
        if restoreFocus { target?.application?.activate(options: []) }
        target = nil
    }

    private func poll(performMaintenance: Bool = true) {
        guard ready else { return }
        guard !clearInProgress else { capture.resetBaseline(); return }
        if performMaintenance {
            maintenanceTicks += 1
            if maintenanceTicks >= 170 { maintenanceTicks = 0; maintenanceRequested = true }
        }
        // Snapshot before a foreground switch, even if disk work is still pending.
        // One bounded pending value avoids an unbounded queue of image payloads.
        switch capture.read(settings: settings) {
        case .ignored, .changedDuringRead: break
        case .unavailable(let message): fail(message)
        case .captured(let payload, let source): pendingCapture = (payload, source)
        }
        guard captureTask == nil, pendingCapture != nil || maintenanceRequested else { return }
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.captureTask = nil }
            while !Task.isCancelled, !self.clearInProgress {
                if let (payload, source) = self.pendingCapture {
                    self.pendingCapture = nil
                    do {
                        _ = try await self.store.save(payload: payload, source: source)
                        try? await self.recoverCapacityIfFreed()
                        if self.capacityWarningAtUsage == nil { self.statusMessage = nil }
                        if self.isVisible { self.refresh() }
                    } catch ClipboardHistoryStoreError.capacityExceeded(_, let availableBytes) {
                        self.storageUsage = try? await self.store.storageUsage()
                        self.capacityWarningAtUsage = self.storageUsage?.usedBytes ?? Int.max
                        self.fail(availableBytes == 0
                            ? "History storage is full. Delete saved items or wait for expiry."
                            : "A copied item could not fit in history storage. Smaller copies can still be saved.")
                    } catch ClipboardHistoryStoreError.paused {
                    } catch { self.fail("A clipboard item could not be saved.") }
                } else if self.maintenanceRequested {
                    self.maintenanceRequested = false
                    do {
                        _ = try await self.store.load()
                        try await self.recoverCapacityIfFreed()
                        self.thumbnails.removeAllObjects()
                        if self.isVisible { self.refresh() }
                    } catch { self.fail("History expiry could not complete; capture is stopped."); self.ready = false; break }
                } else { break }
            }
        }
    }

    public func capturePendingBeforeForeground() { poll(performMaintenance: false) }

    /// Clear is a barrier: discard queued reads, drain any already-started save,
    /// then delete and baseline again before collection can resume.
    public func clearSavedHistory() async throws {
        guard !clearInProgress else { return }
        clearInProgress = true
        revision &+= 1
        busy = false
        recallTask = nil
        refreshStatus()
        pendingCapture = nil
        capture.resetBaseline()
        let inFlight = captureTask
        defer { capture.resetBaseline(); clearInProgress = false; refreshStatus() }
        await inFlight?.value
        try await store.clear()
        capacityWarningAtUsage = nil; statusMessage = nil
        try? await recoverCapacityIfFreed()
        thumbnails.removeAllObjects()
        refresh()
    }

    private func recoverCapacityIfFreed() async throws {
        let usage = try await store.storageUsage()
        storageUsage = usage
        guard let previous = capacityWarningAtUsage else { return }
        if usage.usedBytes < previous {
            capacityWarningAtUsage = nil
            statusMessage = nil
            capture.resetBaseline()
        }
    }

    private func refresh() {
        listRevision &+= 1
        let token = listRevision
        let selectedID = table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow].id : nil
        let query = search.string
        Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await self.store.list(query: query)
                guard token == self.listRevision else { return }
                self.entries = rows
                self.table.reloadData()
                let selected = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? (rows.isEmpty ? -1 : 0)
                self.table.selectRowIndexes(selected >= 0 ? IndexSet(integer: selected) : [], byExtendingSelection: false)
                self.updatePreview()
                self.refreshStatus()
            } catch {
                if token == self.listRevision { self.fail("Clipboard history could not be read.") }
            }
        }
    }

    private func refreshStatus() {
        let countLabel = entries.count == 1 ? "entry" : "entries"
        if let notice {
            status.attributedStringValue = NSAttributedString(string: notice + (stashUndoManager.canUndo ? "   ⌘Z" : ""), attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: OmniFrostedStyle.warning,
            ])
        } else {
            status.attributedStringValue = NSAttributedString(
                string: statusMessage ?? "\(entries.count) \(countLabel) · \(retentionLabel(settings.retentionHours))\(settings.paused ? " · paused" : "")",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk])
        }
        var hints: [OmniPadKeyHint] = []
        if let selected {
            if onStash == nil {
                hints = [.init("↩", "Paste"), .init("⌘↩", "Copy only")]
                if selected.hasFormatting {
                    hints.append(pasteMode == .asCopied ? .init("⇧↩", "Plain text") : .init("⌥↩", "Formatted"))
                }
            } else {
                // C95: ⌘Y Stash takes the strip's middle place; ⌘↩ copy only
                // and ⌥↩ formatted paste keep working, unhinted.
                hints = [.init("↩", "Paste"), .init("⌘Y", "Stash")]
            }
        }
        hints.append(.init("esc", "Close"))
        keyHintsView.hints = hints
        pasteButton.isEnabled = selected != nil && !busy && !clearInProgress
        pasteButton.needsDisplay = true
        menuNeedsUpdate(actionsMenu)
        layoutInterface()
    }

    private func fail(_ message: String) { statusMessage = message; refreshStatus() }
    private func retentionLabel(_ hours: Int) -> String {
        guard hours % 24 == 0 else { return "\(hours) hours" }
        let days = hours / 24
        return "\(days) \(days == 1 ? "day" : "days")"
    }
    private var selected: ClipboardHistorySummary? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 254, height: 62))
        let image = NSImageView(frame: NSRect(x: 6, y: 8, width: 48, height: 46))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.image = entry.kind == .image ? thumbnails.object(forKey: entry.id as NSUUID) : NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Text")
        cell.addSubview(image)
        let title = NSTextField(labelWithString: entry.preview.replacingOccurrences(of: "\n", with: " ↵ "))
        title.frame = NSRect(x: 64, y: 29, width: 180, height: 22)
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        cell.addSubview(title)
        let detail = NSTextField(labelWithString: "\(entry.sourceName ?? entry.sourceBundleID ?? "Unknown app") · \(entry.copiedAt.formatted(date: .omitted, time: .shortened))")
        detail.frame = NSRect(x: 64, y: 10, width: 180, height: 16)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        cell.addSubview(detail)
        if entry.kind == .image, image.image == nil {
            Task { [weak self, weak image] in
                guard let self, case .image(let data, _) = try? await self.store.payload(id: entry.id) else { return }
                let thumbnail = Self.image(data, maxPixels: 100)
                if let thumbnail { self.thumbnails.setObject(thumbnail, forKey: entry.id as NSUUID) }
                image?.image = thumbnail
            }
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }
    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === search else { return }
        layoutInterface()
        refresh()
    }

    private func updatePreview() {
        previewRevision &+= 1
        let token = previewRevision
        imagePreview.image = nil
        textPreview.string = entries.isEmpty ? "No entries yet.\nCopy text or an image to begin." : ""
        imagePreview.isHidden = true; textScroll.isHidden = false
        refreshStatus()
        guard let entry = selected else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.store.payload(id: entry.id)
                guard self.previewRevision == token else { return }
                switch payload {
                case .text(let plain, _, _): self.textPreview.string = plain
                case .image(let data, _):
                    self.imagePreview.image = Self.image(data, maxPixels: 1400)
                    self.imagePreview.isHidden = false; self.textScroll.isHidden = true
                case nil: self.refresh()
                }
            } catch {
                if self.previewRevision == token { self.fail("The saved item could not be opened.") }
            }
        }
    }

    private static func image(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    @objc private func pasteDefault() { recall(copyOnly: false, formatted: false) }
    /// ↩, double-click and the round button: Settings → Clipboard → Paste.
    @objc private func pasteByMode() { recall(copyOnly: false, formatted: pasteMode == .asCopied) }
    @objc private func pasteFormatted() { recall(copyOnly: false, formatted: true) }
    @objc private func copyOnly() { recall(copyOnly: true, formatted: false) }

    private func recall(copyOnly: Bool, formatted: Bool) {
        guard !busy, !clearInProgress, let selected else { return }
        let token = revision
        let generation = foreground.generation
        let origin = target
        busy = true; refreshStatus()
        recallTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.validInvocation(token, generation) {
                    self.busy = false
                    self.recallTask = nil
                    self.refreshStatus()
                }
            }
            do {
                let loaded: ClipboardHistoryPayload?
                if let payloadLoader = self.payloadLoader {
                    loaded = try await payloadLoader(selected.id)
                } else {
                    loaded = try await self.store.payload(id: selected.id)
                }
                guard let payload = loaded,
                      self.validInvocation(token, generation) else { return }
                if copyOnly {
                    guard self.capture.write(payload, formatted: false) else { self.fail("Copy failed."); return }
                    self.dismiss(restoreFocus: true)
                    return
                }
                let failure = await TargetedPaste.perform(
                    into: origin,
                    hide: { self.panel.orderOut(nil) },
                    write: { self.capture.write(payload, formatted: formatted) },
                    isCurrent: { self.validInvocation(token, generation) }
                )
                guard self.validInvocation(token, generation) else { return }
                switch failure {
                case nil: self.dismiss(restoreFocus: false)
                case .accessibilityRequired: self.fail("Enable Accessibility for Hyper Overlay Host to paste, or use Copy only.")
                case .targetUnavailable: self.fail("The original app is unavailable. Use Copy only.")
                case .activationFailed: self.reopenAfterFailure("Could not return to the original app.")
                case .focusChanged: self.reopenAfterFailure("Focus changed. Nothing was pasted; use Copy only.")
                case .writeFailed: self.reopenAfterFailure("Copy failed. Nothing was pasted.")
                case .superseded: return
                }
            } catch {
                if self.validInvocation(token, generation) { self.fail("The saved item could not be recalled.") }
            }
        }
    }

    private func validInvocation(_ token: Int, _ generation: Int) -> Bool {
        revision == token && foreground.isCurrent(overlay: Self.overlayID, generation: generation)
    }

    private func reopenAfterFailure(_ message: String) {
        guard foreground.activeOverlay == Self.overlayID else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fail(message)
    }

    @objc private func togglePause() { _ = requestCaptureToggle() }

    /// Shared menu action and deterministic test seam. The Boolean passed to
    /// the app owner means capture enabled, rather than paused.
    @discardableResult
    func requestCaptureToggle() -> Task<Void, Never>? {
        guard captureIntentTask == nil else { return nil }
        if let onCaptureIntent {
            let requestedEnabled = settings.paused
            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.captureIntentTask = nil
                    self.refreshStatus()
                }
                do {
                    try await onCaptureIntent(requestedEnabled)
                    if self.statusMessage == "Capture setting could not be changed. Try again." {
                        self.statusMessage = nil
                    }
                } catch {
                    self.fail("Capture setting could not be changed. Try again.")
                }
            }
            captureIntentTask = task
            refreshStatus()
            return task
        }
        settings.paused.toggle()
        capture.resetBaseline()
        persistSettings()
        onSettingsChanged?()
        return nil
    }

    public var isCapturePaused: Bool { settings.paused }

    /// Settings → Clipboard → History: the service's own facts.
    public func historyState() async -> (paused: Bool, retentionHours: Int, itemCount: Int, usedBytes: Int?) {
        let count = (try? await store.load().count) ?? entries.count
        let usage = try? await store.storageUsage()
        return (settings.paused, settings.retentionHours, count, usage?.usedBytes)
    }

    /// Capture copied items on or off, as the panel menu's Pause does.
    public func setCaptureEnabled(_ enabled: Bool) async throws {
        guard settings.paused == enabled else { return }
        let previous = settings
        settings.paused = !enabled
        capture.resetBaseline()
        do {
            try await saveSettings()
        } catch {
            // Memory matches the disk again, so a retry writes.
            settings = previous
            refreshStatus()
            throw error
        }
        onSettingsChanged?()
    }

    public func setRetentionHours(_ hours: Int) async throws {
        guard (1...87_600).contains(hours) else { throw ClipboardHistoryStoreError.invalidRetentionDays }
        let previous = settings
        settings.retentionHours = hours
        do {
            try await saveSettings()
        } catch {
            settings = previous
            refreshStatus()
            throw error
        }
    }

    /// `persistSettings`, awaited, so Settings can say when a write failed.
    private func saveSettings() async throws {
        let snapshot = settings
        refreshStatus()
        do {
            try await store.updateSettings(snapshot)
            try await recoverCapacityIfFreed()
            ready = timer != nil
            refresh()
        } catch {
            ready = false
            fail("Settings could not be saved; capture is stopped.")
            throw error
        }
    }

    private func persistSettings() {
        let snapshot = settings
        refreshStatus()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.updateSettings(snapshot)
                try await self.recoverCapacityIfFreed()
                self.ready = self.timer != nil
                self.refresh()
            }
            catch { self.ready = false; self.fail("Settings could not be saved; capture is stopped.") }
        }
    }

    /// ⌘Y: the selected row joins the stash on top, whole (every flavour it
    /// kept). The push is undoable with ⌘Z until the picker closes.
    @objc public func stashSelected() {
        guard let onStash, let entry = selected else { return }
        let token = revision
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let payload = try await self.store.payload(id: entry.id), self.revision == token else { return }
                guard let push = onStash(payload, entry) else {
                    self.notice = "The stash could not take this entry"
                    self.refreshStatus()
                    return
                }
                self.stashUndoManager.registerUndo(withTarget: self) { controller in
                    MainActor.assumeIsolated {
                        controller.notice = push.undo() ? nil : "The stash changed since · nothing undone"
                        controller.refreshStatus()
                    }
                }
                self.notice = push.droppedOldest ? "Stashed · oldest dropped" : "Stashed · now active"
                self.refreshStatus()
            } catch { self.fail("The saved item could not be stashed.") }
        }
    }

    @objc private func deleteSelected() {
        guard let entry = selected else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.delete(id: entry.id)
                try await self.recoverCapacityIfFreed()
                self.thumbnails.removeObject(forKey: entry.id as NSUUID); self.refresh()
            }
            catch { self.fail("The saved item could not be deleted.") }
        }
    }

    @objc private func clearSaved() {
        let alert = NSAlert()
        alert.messageText = "Clear saved clipboard history?"
        alert.informativeText = "Saved text and images will be removed. Your current clipboard stays as it is."
        alert.addButton(withTitle: "Clear history"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        capture.resetBaseline()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clearSavedHistory()
            }
            catch { self.fail("Saved history could not be cleared.") }
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === actionsMenu else { return }
        menu.removeAllItems()
        let pauseItem = NSMenuItem(title: settings.paused ? "Resume capture" : "Pause capture",
                                   action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self; pauseItem.isEnabled = captureIntentTask == nil
        menu.addItem(pauseItem)
        let deleteItem = NSMenuItem(title: "Delete selected", action: #selector(deleteSelected), keyEquivalent: "")
        deleteItem.target = self; deleteItem.isEnabled = selected != nil
        menu.addItem(deleteItem)
        let clearItem = NSMenuItem(title: "Clear history…", action: #selector(clearSaved), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = makeSettingsMenu()
        menu.addItem(settingsItem)
    }

    private func makeSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Keep history for", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        for hours in Self.retentionChoices {
            let item = NSMenuItem(title: retentionLabel(hours), action: #selector(changeRetention(_:)), keyEquivalent: "")
            item.target = self; item.tag = hours; item.state = settings.retentionHours == hours ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Exclude an app…", action: #selector(addExclusion), keyEquivalent: "")
        add.target = self; menu.addItem(add)
        for bundleID in settings.excludedBundleIDs {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String } ?? bundleID
            let item = NSMenuItem(title: "Allow \(name) again", action: #selector(removeExclusion(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = bundleID; menu.addItem(item)
        }
        menu.addItem(.separator())
        let info = NSMenuItem(title: "App exclusions use available source signals; Pause stops all capture.", action: nil, keyEquivalent: "")
        menu.addItem(info)
        return menu
    }

    @objc private func changeRetention(_ sender: NSMenuItem) { settings.retentionHours = sender.tag; persistSettings() }
    @objc private func removeExclusion(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.excludedBundleIDs.removeAll { $0 == id }; persistSettings()
    }
    @objc private func addExclusion() {
        let open = NSOpenPanel()
        open.title = "Choose an app to exclude"
        open.allowedContentTypes = [.applicationBundle]
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.canChooseDirectories = false; open.canChooseFiles = true
        guard open.runModal() == .OK, let url = open.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        if !settings.excludedBundleIDs.contains(id) { settings.excludedBundleIDs.append(id) }
        capture.resetBaseline(); persistSettings()
    }

    private func layoutInterface() {
        guard let surface = panel.contentView else { return }
        let width = surface.bounds.width
        let contentWidth = max(1, width - 36)
        search.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 25)
        OmniToolPillLayout.reserveFirstLine(beside: search, pill: toolPill, fieldWidth: contentWidth)
        search.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        if let container = search.textContainer { search.layoutManager?.ensureLayout(for: container) }
        let textHeight = search.textContainer.map { search.layoutManager?.usedRect(for: $0).height ?? 25 } ?? 25
        let fieldHeight = min(96, max(25, ceil(textHeight + 2)))
        searchScroll.frame = NSRect(x: 18, y: surface.bounds.height - 14 - fieldHeight,
                                    width: contentWidth, height: fieldHeight)
        search.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(fieldHeight, textHeight))
        OmniToolPillLayout.place(toolPill, beside: search, in: searchScroll.frame)

        let resultBottom: CGFloat = 100
        let resultTop = searchScroll.frame.minY - 16
        let resultHeight = max(1, resultTop - resultBottom)
        list.frame = NSRect(x: 18, y: resultBottom, width: 254, height: resultHeight)
        let previewFrame = NSRect(x: 282, y: resultBottom, width: max(1, width - 300), height: resultHeight)
        imagePreview.frame = previewFrame
        textScroll.frame = previewFrame
        var textFrame = textPreview.frame
        textFrame.size.width = textScroll.contentSize.width
        textPreview.frame = textFrame
        pasteButton.frame = NSRect(x: width - 44, y: 12, width: 32, height: 32)
        let hintWidth = min(keyHintsView.fittingWidth, max(1, pasteButton.frame.minX - 30))
        keyHintsView.frame = NSRect(x: pasteButton.frame.minX - 12 - hintWidth,
                                     y: 13, width: hintWidth, height: 30)
    }

    private func buildInterface() {
        panel.title = "Clipboard history"
        panel.setAccessibilityIdentifier("hyper.clipboard.history")
        let surface = OmniFrostedSurface(frame: NSRect(x: 0, y: 0, width: 640, height: 590))
        panel.contentView = surface
        actionsMenu.delegate = self
        search.isEditable = true
        search.isSelectable = true
        search.isRichText = false
        search.drawsBackground = false
        search.font = .systemFont(ofSize: 17)
        search.textColor = OmniFrostedStyle.ink
        search.insertionPointColor = OmniFrostedStyle.accent
        search.textContainerInset = .zero
        search.textContainer?.lineFragmentPadding = 0
        search.textContainer?.widthTracksTextView = true
        search.isVerticallyResizable = true
        search.isHorizontallyResizable = false
        search.autoresizingMask = [.width]
        search.placeholderString = "Search what you copied"
        search.onEscape = { [weak self] in self?.dismiss(restoreFocus: true) }
        search.onSubmit = { [weak self] in self?.pasteByMode() }
        search.delegate = self
        search.setAccessibilityIdentifier("hyper.clipboard.search")
        searchScroll.drawsBackground = false
        searchScroll.hasVerticalScroller = false
        searchScroll.borderType = .noBorder
        searchScroll.documentView = search
        surface.addSubview(searchScroll)
        surface.addSubview(toolPill)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = 254; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 62; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(pasteByMode)
        table.setAccessibilityIdentifier("hyper.clipboard.entries")
        table.menu = actionsMenu
        list.documentView = table; list.hasVerticalScroller = true; list.drawsBackground = false
        list.menu = actionsMenu
        surface.addSubview(list)
        imagePreview.frame = NSRect(x: 282, y: 100, width: 340, height: 394)
        imagePreview.imageScaling = .scaleProportionallyUpOrDown
        surface.addSubview(imagePreview)
        textPreview.isEditable = false; textPreview.isSelectable = true; textPreview.isRichText = false
        textPreview.drawsBackground = false; textPreview.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textPreview.textContainerInset = NSSize(width: 10, height: 10)
        textPreview.isVerticallyResizable = true; textPreview.isHorizontallyResizable = false
        textPreview.autoresizingMask = [.width]
        textPreview.textContainer?.widthTracksTextView = true
        textScroll.frame = imagePreview.frame; textScroll.documentView = textPreview
        textScroll.hasVerticalScroller = true; textScroll.drawsBackground = false
        textPreview.frame = NSRect(origin: .zero, size: textScroll.contentSize)
        surface.addSubview(textScroll)
        status.frame = NSRect(x: 18, y: 66, width: 604, height: 19)
        status.font = .systemFont(ofSize: 13); status.textColor = OmniFrostedStyle.secondaryInk
        status.setAccessibilityIdentifier("hyper.clipboard.summary")
        status.toolTip = "Control-click the list for Pause, Delete, Clear and Settings."
        surface.addSubview(status)
        keyHintsView.setAccessibilityIdentifier("hyper.clipboard.key-hints")
        surface.addSubview(keyHintsView)
        pasteButton.symbolName = "arrow.turn.down.left"
        pasteButton.setAccessibilityLabel("Paste and close")
        pasteButton.toolTip = "Paste and close"
        pasteButton.setAccessibilityIdentifier("hyper.clipboard.paste")
        pasteButton.onPress = { [weak self] in self?.pasteByMode() }
        surface.addSubview(pasteButton)
        layoutInterface()
        refreshStatus()
        thumbnails.countLimit = 80
    }

    /// The picker can reopen after stop/recovery without rebuilding its views.
    private func installKeyboardMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel else { return false }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
                // A notice lasts until the next keystroke (C95).
                let noticeShowing = self.notice != nil
                if noticeShowing, !self.search.hasMarkedText() {
                    self.notice = nil
                    self.refreshStatus()
                }
                if !self.search.hasMarkedText(), modifiers == .command {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "y" where self.onStash != nil:
                        self.stashSelected(); return true
                    // The push's undo wins while its notice shows or the
                    // query has no typing to undo; otherwise typing first.
                    case "z" where self.stashUndoManager.canUndo
                        && (noticeShowing || self.search.undoManager?.canUndo != true):
                        self.stashUndoManager.undo(); return true
                    default: break
                    }
                }
                switch event.keyCode {
                case 53:
                    if self.search.hasMarkedText() { return false }
                    self.dismiss(restoreFocus: true); return true
                case 36, 76:
                    if self.search.hasMarkedText() { return false }
                    if event.modifierFlags.contains(.command) { self.copyOnly() }
                    else if event.modifierFlags.contains(.option) { self.pasteFormatted() }
                    else if event.modifierFlags.contains(.shift) { self.pasteDefault() }
                    else { self.pasteByMode() }
                    return true
                case 125, 126:
                    if self.search.hasMarkedText() { return false }
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.numericPad, .function])
                    guard modifiers.isEmpty else { return false }
                    guard !self.entries.isEmpty else { return true }
                    let row = max(0, min(self.entries.count - 1, self.table.selectedRow + (event.keyCode == 125 ? 1 : -1)))
                    self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.table.scrollRowToVisible(row); return true
                case 51 where event.modifierFlags.contains(.command):
                    if self.search.hasMarkedText() { return false }
                    self.deleteSelected(); return true
                default: return false
                }
            }
            return handled ? nil : event
        }
    }
}
