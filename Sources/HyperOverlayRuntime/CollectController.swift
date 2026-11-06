import Foundation
import HyperOverlayCore

/// Collect's direct actions (H19, C104–C110): Hyper C, V, B, - and =.
public enum CollectAction: String, Sendable, CaseIterable {
    case collect
    case pasteNext
    case pasteAll
    case clear
    case equalize

    public init?(overlayID: String) {
        guard let action = Self.allCases.first(where: { $0.overlayID == overlayID }) else { return nil }
        self = action
    }

    public var overlayID: String {
        switch self {
        case .collect: OverlayID.collectAdd
        case .pasteNext: OverlayID.collectNext
        case .pasteAll: OverlayID.collectAll
        case .clear: OverlayID.collectClear
        case .equalize: OverlayID.equalize
        }
    }

    /// C, V and B act on the app in front; - and = need no destination.
    public var needsTarget: Bool { self == .collect || self == .pasteNext || self == .pasteAll }
}

/// Failures speak, success is silent (C108, C109). The handoff's bezel texts,
/// plus four it did not name: a full store, pasting paused, a store that
/// cannot be read, Equalize failing, and no app to act on.
public enum CollectFailure: String, Sendable, Equatable {
    case empty = "Buffer empty"
    case copyFailed = "Copy failed"
    case destinationChanged = "Destination changed"
    case busy = "Busy"
    case accessibility = "Accessibility access needed"
    case full = "Collection full"
    case paused = "Pasting paused · resume in the menu bar"
    case unavailable = "Collect unavailable"
    case pasteFailed = "Paste failed"
    case equalizeFailed = "Equalize failed"
    case noDestination = "No app to act on"
}

/// The outcome of ⌘C in the pinned app: a fresh copy's text (or Finder
/// paths), nothing usable, or the destination moved.
public enum CollectCopy: Sendable, Equatable {
    case text(String)
    case failed
    case changed
}

/// The platform side, injected so the lane is testable without keys,
/// pasteboards or other apps.
@MainActor
public protocol CollectEffects: AnyObject {
    func trusted() -> Bool
    /// Waits, bounded, until the physical Hyper modifiers are up, so the
    /// synthetic ⌘C or ⌘V is not read as a different chord.
    func waitForHyperRelease() async -> Bool
    func copySelection(from target: PasteTarget, isCurrent: @escaping @MainActor () -> Bool) async -> CollectCopy
    /// Plain text with the history marker, ⌘V to the target, no activation.
    /// Nil means the paste event was sent.
    func paste(_ text: String, into target: PasteTarget, isCurrent: @escaping @MainActor () -> Bool) async -> TargetedPasteFailure?
    func clipboardText() -> (text: String, changeCount: Int)?
    func normalize(_ text: String) async -> String?
    func replaceClipboard(_ text: String, expectedChangeCount: Int) -> Bool
    func showFailure(_ failure: CollectFailure)
    /// Success you could not otherwise see (D1 of plan f71f8baac8f0149e):
    /// only Equalize uses it.
    func showNotice(_ text: String)
}

/// One serialized lane. A newer foreground intent, an app switch or ⌫
/// invalidates the pending action; items are consumed only after their
/// paste event was dispatched.
@MainActor
public final class CollectController {
    public let store: ClipboardBufferStore?
    /// Between items when a batch pastes: Settings → Clipboard → Batch
    /// separator (O31), a new line unless set.
    public var batchSeparator = "\n"
    private let effects: any CollectEffects
    public private(set) var busy = false
    private var generation = 0
    /// The generation of the action in the lane, and the last one ⌫ moved
    /// past: an action ⌫ cancelled says nothing.
    private var activeGeneration = 0
    private var clearedGeneration = -1

    public init(store: ClipboardBufferStore?, effects: any CollectEffects) {
        self.store = store
        self.effects = effects
    }

    public var count: Int { store?.count ?? 0 }
    public var isPaused: Bool { store?.isPaused == true }

    /// The menu bar line (C108): present only while something is collected.
    public var statusLine: String? {
        guard let store, store.isReady, store.count > 0 || store.isPaused else { return nil }
        return store.isPaused ? "Collected · \(store.count) · paused" : "Collected · \(store.count)"
    }

    /// The overlay caps' labels (C108): counts while non-empty.
    public var capLabels: [String: String] {
        let n = count
        let suffix = n > 0 ? " · \(n)" : ""
        return [
            OverlayID.collectAdd: "Collect" + suffix,
            OverlayID.collectNext: "Paste next" + suffix,
            OverlayID.collectAll: "Paste all" + suffix,
        ]
    }

    public var statusFacts: [String: String] {
        var facts = ["ready": store?.isReady == true ? "true" : "false", "count": "\(count)",
                     "busy": busy ? "true" : "false", "paused": isPaused ? "true" : "false"]
        if store == nil { facts["error"] = "Collect runs only in the installed host" }
        if let error = store?.loadError { facts["error"] = error }
        return facts
    }

    /// A newer foreground intent or an app switch: the pending action stops
    /// at its next check.
    public func invalidate() { generation &+= 1 }

    /// The menu bar's `Resume pasting`: the person has looked at the last
    /// paste; keep every item.
    public func resumePasting() {
        try? store?.mutate { state in
            state.paused = false
            state.sending = nil
        }
    }

    public func perform(_ action: CollectAction, target: PasteTarget?) async {
        if action == .equalize {
            // Equalize touches only the clipboard: it needs no store, and an
            // app switch does not cancel it (the revision guard protects a
            // newer copy).
            guard !busy else { return effects.showFailure(.busy) }
            busy = true
            defer { busy = false }
            return await equalize()
        }
        guard let store, store.isReady else { return effects.showFailure(.unavailable) }
        if action == .clear { return clear(store) }
        guard !busy else { return effects.showFailure(.busy) }
        if action.needsTarget {
            guard effects.trusted() else { return effects.showFailure(.accessibility) }
            guard let target else { return effects.showFailure(.noDestination) }
            busy = true
            defer { busy = false }
            generation &+= 1
            let mine = generation
            activeGeneration = mine
            let isCurrent: @MainActor () -> Bool = { [weak self] in self?.generation == mine }
            switch action {
            case .collect: await collect(store, target: target, isCurrent: isCurrent)
            case .pasteNext: await paste(store, all: false, target: target, isCurrent: isCurrent)
            case .pasteAll: await paste(store, all: true, target: target, isCurrent: isCurrent)
            case .clear, .equalize: break
            }
        }
    }

    /// A failure after the action was cancelled by ⌫ is not news.
    private func fail(_ failure: CollectFailure, cancelled: Bool) {
        if cancelled, failure == .destinationChanged, clearedGeneration > activeGeneration { return }
        effects.showFailure(failure)
    }

    private func collect(_ store: ClipboardBufferStore, target: PasteTarget, isCurrent: @escaping @MainActor () -> Bool) async {
        guard await effects.waitForHyperRelease() else { return effects.showFailure(.copyFailed) }
        guard isCurrent() else { return fail(.destinationChanged, cancelled: true) }
        switch await effects.copySelection(from: target, isCurrent: isCurrent) {
        case .changed:
            fail(.destinationChanged, cancelled: !isCurrent())
        case .failed:
            effects.showFailure(.copyFailed)
        case .text(let text):
            guard isCurrent() else { return fail(.destinationChanged, cancelled: true) }
            guard !text.isEmpty else { return effects.showFailure(.copyFailed) }
            do { try store.append(text) } catch ClipboardBufferError.full {
                effects.showFailure(.full)
            } catch {
                effects.showFailure(.unavailable)
            }
        }
    }

    private func paste(_ store: ClipboardBufferStore, all: Bool, target: PasteTarget, isCurrent: @escaping @MainActor () -> Bool) async {
        // An unrecorded send, on disk or only in memory, holds pasting.
        guard !store.isPaused, store.state.sending == nil else { return effects.showFailure(.paused) }
        guard !store.items.isEmpty else { return effects.showFailure(.empty) }
        guard await effects.waitForHyperRelease() else { return effects.showFailure(.pasteFailed) }
        guard isCurrent() else { return fail(.destinationChanged, cancelled: true) }
        let snapshot = all ? store.items : [store.items[0]]
        let ids = snapshot.map(\.id)
        let text = snapshot.map(\.text).joined(separator: batchSeparator)
        // Name the items in flight before the event exists: a crash after
        // dispatch then pauses instead of losing or replaying them.
        do { try store.mutate { $0.sending = ids } } catch { return effects.showFailure(.unavailable) }
        if let failure = await effects.paste(text, into: target, isCurrent: isCurrent) {
            try? store.mutate { $0.sending = nil }
            switch failure {
            case .accessibilityRequired: effects.showFailure(.accessibility)
            case .targetUnavailable, .activationFailed, .focusChanged, .superseded: fail(.destinationChanged, cancelled: !isCurrent())
            case .writeFailed: effects.showFailure(.pasteFailed)
            }
            return
        }
        // Sent: consume exactly that snapshot (items collected since stay).
        do {
            try store.mutate { state in
                state.items.removeAll { ids.contains($0.id) }
                state.sending = nil
            }
        } catch {
            // The paste went out but could not be recorded: keep the items
            // and pause, in memory even if the disk refuses, so nothing is
            // lost and nothing repeats unasked.
            store.pauseAfterUnrecordedSend()
            effects.showFailure(.paused)
        }
    }

    private func clear(_ store: ClipboardBufferStore) {
        invalidate()
        clearedGeneration = generation
        do {
            try store.mutate { state in
                state.items = []
                state.sending = nil
                state.paused = false
            }
        } catch {
            effects.showFailure(.unavailable)
        }
    }

    private func equalize() async {
        guard let (text, changeCount) = effects.clipboardText() else { return effects.showFailure(.equalizeFailed) }
        // An empty result is a broken helper, never a reason to wipe the copy.
        guard let normalized = await effects.normalize(text), !normalized.isEmpty else {
            return effects.showFailure(.equalizeFailed)
        }
        guard normalized != text else { return effects.showNotice("Already equal") }
        guard effects.replaceClipboard(normalized, expectedChangeCount: changeCount) else {
            return effects.showFailure(.equalizeFailed)
        }
        effects.showNotice("Equalized")
    }
}
