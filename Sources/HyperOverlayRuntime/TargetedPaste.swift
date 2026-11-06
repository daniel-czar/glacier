import AppKit
import ApplicationServices

/// History and stash recall writes carry this marker, so the clipboard
/// collector never takes a recalled item back in as a new copy.
public enum RecallPasteboardMarker {
    public static let type = NSPasteboard.PasteboardType("local.Glacier.Development.clipboard-recall")
}

/// The app a paste returns to, pinned by pid, bundle and launch date so a
/// relaunched or replaced process never receives it. The host itself is
/// never a target.
public struct PasteTarget: Sendable, Equatable {
    public let pid: pid_t
    public let bundleID: String?
    public let launchDate: Date?

    @MainActor
    public init?(_ pid: pid_t?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        self.pid = pid
        bundleID = app.bundleIdentifier
        launchDate = app.launchDate
    }

    @MainActor
    public var application: NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier == bundleID, app.launchDate == launchDate else { return nil }
        return app
    }
}

public enum TargetedPasteFailure: Error, Sendable, Equatable {
    /// Before anything moved: no Accessibility trust, so no keystroke can be sent.
    case accessibilityRequired
    /// Before anything moved: the original app is gone or was never captured.
    case targetUnavailable
    /// After the surface hid: the original app could not be activated.
    case activationFailed
    /// After the surface hid: another app came to the front first.
    case focusChanged
    /// After the surface hid: the pasteboard write failed; nothing was pasted.
    case writeFailed
    /// A newer invocation or foreground request superseded this one.
    case superseded

    /// Whether the calling surface had already hidden itself.
    public var surfaceHidden: Bool {
        switch self {
        case .accessibilityRequired, .targetUnavailable: false
        case .activationFailed, .focusChanged, .writeFailed, .superseded: true
        }
    }
}

/// The paste chain Clipboard and Stash share: return to the target, write the
/// pasteboard only once it is in front, and post ⌘V to its pid alone, so a
/// last-moment app switch cannot receive the paste.
@MainActor
public enum TargetedPaste {
    /// How the target comes to the front. Clipboard and Stash pickers
    /// `restoreOrigin`: they activate the app they were opened over. Collect's
    /// direct actions `requireFrontmost`: the target must already be in
    /// front, and nothing is ever activated, so an app switch cancels.
    public enum Policy: Sendable, Equatable {
        case restoreOrigin
        case requireFrontmost
    }

    public static func perform(
        into target: PasteTarget?,
        policy: Policy = .restoreOrigin,
        hide: () -> Void,
        write: () -> Bool,
        isCurrent: () -> Bool,
        trusted: () -> Bool = { AXIsProcessTrusted() },
        frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    ) async -> TargetedPasteFailure? {
        guard trusted() else { return .accessibilityRequired }
        guard let target, let app = target.application,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return .targetUnavailable }
        down.flags = .maskCommand
        up.flags = .maskCommand
        if policy == .requireFrontmost {
            guard isCurrent() else { return .superseded }
            guard frontmostPID() == target.pid, target.application != nil else { return .focusChanged }
            guard write() else { return .writeFailed }
            guard isCurrent(), frontmostPID() == target.pid else { return .focusChanged }
            down.postToPid(target.pid)
            up.postToPid(target.pid)
            return nil
        }
        hide()
        guard app.activate(options: []) else { return .activationFailed }
        for _ in 0..<12 {
            guard isCurrent(), target.application != nil else { return .superseded }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard isCurrent() else { return .superseded }
        guard target.application != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return .focusChanged }
        guard write() else { return .writeFailed }
        down.postToPid(target.pid)
        up.postToPid(target.pid)
        return nil
    }
}
