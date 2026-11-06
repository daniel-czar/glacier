import AppKit
import ApplicationServices
import Foundation

/// Collect's real platform effects (H19): the pasteboard, synthetic ⌘C and
/// ⌘V to a pinned app, and the Equalize helper. Nothing here activates an
/// app; a destination that leaves the front cancels instead.
@MainActor
public final class CollectSystemEffects: CollectEffects {
    public static let releaseWait: Duration = .milliseconds(1_500)
    public static let copyWait: Duration = .milliseconds(1_000)

    private let pasteboard: NSPasteboard
    private let normalizer: URL?
    private let normalization: (@Sendable (String) async -> String?)?
    private let onFailure: @MainActor (CollectFailure) -> Void
    private let onNotice: @MainActor (String) -> Void

    public init(pasteboard: NSPasteboard = .general, normalizer: URL? = nil,
                normalization: (@Sendable (String) async -> String?)? = nil,
                onFailure: @escaping @MainActor (CollectFailure) -> Void,
                onNotice: @escaping @MainActor (String) -> Void = { _ in }) {
        self.pasteboard = pasteboard
        self.normalizer = normalizer
        self.normalization = normalization
        self.onFailure = onFailure
        self.onNotice = onNotice
    }

    public func trusted() -> Bool { AXIsProcessTrusted() }

    public func waitForHyperRelease() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.releaseWait)
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        while clock.now < deadline, !Task.isCancelled {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    public func copySelection(from target: PasteTarget, isCurrent: @escaping @MainActor () -> Bool) async -> CollectCopy {
        await copySelection(from: target, wait: Self.copyWait, isCurrent: isCurrent)
    }

    /// ⌘C in the pinned app, then a fresh, readable copy within `wait`.
    /// `.failed` also means nothing new arrived: the key actions read that
    /// as "nothing selected" and fall back to the clipboard.
    public func copySelection(from target: PasteTarget, wait: Duration,
                              isCurrent: @escaping @MainActor () -> Bool) async -> CollectCopy {
        guard Self.frontmostPID() == target.pid, target.application != nil else { return .changed }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return .failed }
        down.flags = .maskCommand
        up.flags = .maskCommand
        let before = pasteboard.changeCount
        down.postToPid(target.pid)
        up.postToPid(target.pid)
        // Poll for a fresh, readable copy, not a fixed delay: a stale clipboard
        // is never collected, and an app that clears first and writes a moment
        // later is waited for within the same deadline.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            guard isCurrent(), Self.frontmostPID() == target.pid else { return .changed }
            guard pasteboard.changeCount != before else { continue }
            let revision = pasteboard.changeCount
            if let text = Self.read(pasteboard) {
                guard pasteboard.changeCount == revision else { continue }
                return .text(text)
            }
        }
        return .failed
    }

    /// File URLs first (a Finder selection is its paths, one per line), then
    /// plain text, as `clip_sanitizer` did. Concealed and transient copies
    /// (password managers) are never collected.
    public static func read(_ pasteboard: NSPasteboard) -> String? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard !types.contains("org.nspasteboard.ConcealedType"), !types.contains("org.nspasteboard.TransientType") else { return nil }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.path).joined(separator: "\n")
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }

    public func paste(_ text: String, into target: PasteTarget, isCurrent: @escaping @MainActor () -> Bool) async -> TargetedPasteFailure? {
        let pasteboard = pasteboard
        return await TargetedPaste.perform(into: target, policy: .requireFrontmost, hide: {},
                                           write: { Self.writeMarked(text, to: pasteboard) }, isCurrent: isCurrent)
    }

    /// Plain text plus the history marker, so Clipboard history does not take
    /// a synthetic write back in as a new copy.
    @discardableResult
    public static func writeMarked(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: RecallPasteboardMarker.type)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// The text Equalize may rewrite, with the revision it was read at.
    /// Concealed and transient copies are left alone: rewriting them would
    /// drop the password manager's markers.
    public func clipboardText() -> (text: String, changeCount: Int)? {
        let revision = pasteboard.changeCount
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard !types.contains("org.nspasteboard.ConcealedType"), !types.contains("org.nspasteboard.TransientType"),
              let text = pasteboard.string(forType: .string), !text.isEmpty,
              pasteboard.changeCount == revision
        else { return nil }
        return (text, revision)
    }

    public func normalize(_ text: String) async -> String? {
        if let normalization { return await normalization(text) }
        guard let normalizer else { return nil }
        return await CollectNormalizer.run(text, executable: normalizer)
    }

    /// Writes only over the copy it read; on a failed write it restores that
    /// text if nothing newer arrived meanwhile.
    public func replaceClipboard(_ text: String, expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        let original = pasteboard.string(forType: .string)
        if Self.writeMarked(text, to: pasteboard) { return true }
        if let original, pasteboard.changeCount == expectedChangeCount + 1 {
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
        }
        return false
    }

    public func showFailure(_ failure: CollectFailure) { onFailure(failure) }

    public func showNotice(_ text: String) { onNotice(text) }

    static func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
}

/// Equalize (C106): the current V normaliser, `normalize-text` in
/// stdin/stdout mode, under the resident host's minimal environment. Bounded;
/// a timeout, a failure or invalid output returns nil and nothing is written.
public enum CollectNormalizer {
    public static let timeout: TimeInterval = 3
    public static let environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONIOENCODING": "utf-8",
        "LC_ALL": "en_US.UTF-8",
    ]

    public static func run(_ text: String, executable: URL,
                           timeout: TimeInterval = CollectNormalizer.timeout) async -> String? {
        guard let result = await HelperProcess.run(executable, stdin: text, environment: environment, timeout: timeout),
              result.status == 0
        else { return nil }
        return result.stdout
    }
}
