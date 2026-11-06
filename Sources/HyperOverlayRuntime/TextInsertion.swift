import AppKit
import ApplicationServices

public enum TextInsertionOutcome: Equatable, Sendable {
    case inserted
    case copied(reason: String)
    case cancelled
}

/// Inserts into the app that owned focus before the panel appeared. A successful
/// AX write never touches the pasteboard; a failed AX transport never posts a
/// second insertion attempt, because the first write may have succeeded.
@MainActor
public enum TextInsertion {
    public static let copyNotice = "Copied · press ⌘V to insert"

    public static func perform(
        text: String,
        into target: PasteTarget?,
        hide: () -> Void,
        write: () -> Bool,
        isCurrent: () -> Bool = { true }
    ) async -> TextInsertionOutcome {
        await withoutActuallyEscaping(write) { escapingWrite in
            await withoutActuallyEscaping(isCurrent) { escapingCurrent in
                await perform(text: text, into: target, hide: hide, write: escapingWrite,
                              isCurrent: escapingCurrent, effects: .system)
            }
        }
    }

    static func perform(
        text: String,
        into target: PasteTarget?,
        hide: () -> Void,
        write: @escaping () -> Bool,
        isCurrent: @escaping () -> Bool,
        effects: TextInsertionEffects
    ) async -> TextInsertionOutcome {
        guard isCurrent(), !Task.isCancelled else { return .cancelled }
        hide()
        guard isCurrent(), !Task.isCancelled else { return .cancelled }

        func copy() -> TextInsertionOutcome {
            guard isCurrent(), !Task.isCancelled, write() else { return .cancelled }
            return .copied(reason: copyNotice)
        }

        guard let target, effects.available(target), effects.trusted() else { return copy() }
        guard effects.activate(target) else { return copy() }
        for _ in 0..<12 {
            guard isCurrent(), !Task.isCancelled else { return .cancelled }
            guard effects.available(target) else { return copy() }
            if effects.frontmostPID() == target.pid { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard isCurrent(), !Task.isCancelled else { return .cancelled }
        guard effects.available(target), effects.frontmostPID() == target.pid else { return copy() }

        switch effects.insertAX(text, target, isCurrent) {
        case .inserted:
            return .inserted
        case .unsupported:
            guard isCurrent(), !Task.isCancelled else { return .cancelled }
            guard effects.available(target), effects.frontmostPID() == target.pid else { return copy() }
            let callbacks = InsertionCallbacks(write: write, isCurrent: isCurrent)
            let failure = await effects.paste(target, { callbacks.write() }, { callbacks.isCurrent() })
            if failure == nil { return .inserted }
            if failure == .superseded { return .cancelled }
            return copy()
        case .refused, .ambiguous:
            return copy()
        }
    }
}

enum AXInsertionResult: Equatable {
    case inserted
    case unsupported
    case refused
    case ambiguous
}

@MainActor
private final class InsertionCallbacks {
    let write: () -> Bool
    let isCurrent: () -> Bool

    init(write: @escaping () -> Bool, isCurrent: @escaping () -> Bool) {
        self.write = write
        self.isCurrent = isCurrent
    }
}

/// Small platform seam: tests can prove that a successful AX write cannot
/// also paste, and that an indeterminate AX result cannot trigger ⌘V.
@MainActor
struct TextInsertionEffects {
    var trusted: () -> Bool
    var available: (PasteTarget) -> Bool
    var activate: (PasteTarget) -> Bool
    var frontmostPID: () -> pid_t?
    var insertAX: (String, PasteTarget, () -> Bool) -> AXInsertionResult
    var paste: @MainActor (PasteTarget, @MainActor () -> Bool, @MainActor () -> Bool) async -> TargetedPasteFailure?

    static let system = TextInsertionEffects(
        trusted: { AXIsProcessTrusted() },
        available: { $0.application != nil },
        activate: { $0.application?.activate(options: []) == true },
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        insertAX: { text, target, isCurrent in AXTextInsertion.insert(text, target: target, isCurrent: isCurrent) },
        paste: { target, write, isCurrent in
            await TargetedPaste.perform(into: target, policy: .requireFrontmost,
                                        hide: {}, write: write, isCurrent: isCurrent)
        }
    )
}

/// Synchronous AX IPC with a short per-message timeout. No suspension occurs
/// between the last focus/identity check and the write, so a cancelled task
/// cannot resume later with a retained element and overwrite a new target.
@MainActor
private enum AXTextInsertion {
    static func insert(_ text: String, target: PasteTarget, isCurrent: () -> Bool) -> AXInsertionResult {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focusedValue: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard focusError == .success else { return classify(focusError) }
        guard let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return .ambiguous }
        let focused = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.25)

        var elementPID: pid_t = 0
        guard AXUIElementGetPid(focused, &elementPID) == .success, elementPID == target.pid else { return .ambiguous }
        var subroleValue: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subroleValue)
        if subroleError == .success {
            if (subroleValue as? String) == (kAXSecureTextFieldSubrole as String) { return .refused }
        } else if subroleError != .attributeUnsupported && subroleError != .noValue {
            return .ambiguous
        }

        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable)
        guard settableError == .success else { return classify(settableError) }
        guard settable.boolValue else { return .unsupported }

        // Reacquire focus immediately before mutation: an element retained
        // through a focus change must never be written.
        var currentValue: CFTypeRef?
        let currentError = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &currentValue)
        guard currentError == .success else { return classify(currentError) }
        guard let currentValue, CFEqual(focused, currentValue),
              target.application != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              isCurrent(), !Task.isCancelled else { return .refused }
        let result = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString)
        return result == .success ? .inserted : classify(result)
    }

    private static func classify(_ error: AXError) -> AXInsertionResult {
        switch error {
        case .attributeUnsupported, .noValue, .notImplemented:
            return .unsupported
        case .apiDisabled:
            return .refused
        default:
            return .ambiguous
        }
    }
}
