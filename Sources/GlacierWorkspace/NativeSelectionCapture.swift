import AppKit
import ApplicationServices
import Foundation

/// The foreground application identity captured before Omni changes focus.
/// It deliberately carries no application object or accessibility element, so
/// an old UI object can never be reused for a later capture.
public struct OmniSelectionApplication: Sendable, Equatable {
    public let processID: Int32
    public let name: String?
    /// The bundle identifier, when the process has one. The header draws the
    /// app's icon from it; names are lossy (D3, decision surface 569d5a7c).
    public let bundleIdentifier: String?

    public init(processID: Int32, name: String?, bundleIdentifier: String? = nil) {
        self.processID = processID
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct CapturedOmniSelection: Sendable, Equatable {
    public let text: String
    public let appName: String?
    public let processID: Int32
    /// The focused window's title at capture time, best effort (a subject
    /// line in Mail, for example). `nil` when it could not be read.
    public let windowTitle: String?
    public let bundleIdentifier: String?

    public init(text: String, appName: String?, processID: Int32, windowTitle: String? = nil, bundleIdentifier: String? = nil) {
        self.text = text
        self.appName = appName
        self.processID = processID
        self.windowTitle = windowTitle
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum OmniSelectionUnavailableReason: Sendable, Equatable {
    /// Accessibility is not currently granted. The adapter never asks macOS to
    /// display the permission prompt.
    case accessibilityPermissionRequired
    case noFrontmostApplication
    case excludedProcess
    case foregroundChanged
    case secureTextField
    case selectionTooLong
    case sourceUnsupported
    case sourceFailed(Int32)
    case timedOut
}

public enum CapturedOmniSelectionResult: Sendable, Equatable {
    case selected(CapturedOmniSelection)
    case empty
    case unavailable(OmniSelectionUnavailableReason)
}

/// The raw result from a snapshot provider. Keeping this separate from the
/// public result lets the adapter consistently apply truncation and the final
/// foreground-process race check.
public enum OmniSelectionSourceResult: Sendable, Equatable {
    case selected(String)
    case empty
    case unavailable(OmniSelectionUnavailableReason)
}

/// The platform boundary for selection capture. Test providers can be fully
/// deterministic; the production provider only reads the focused element of
/// the foreground application supplied to it.
public protocol OmniSelectionSnapshotProvider: Sendable {
    func accessibilityPermissionIsGranted() -> Bool
    @MainActor func frontmostApplication() -> OmniSelectionApplication?
    func selection(in application: OmniSelectionApplication, maximumTextLength: Int) async -> OmniSelectionSourceResult
    /// The focused window's title, best effort. Never prompts for permission;
    /// any failure to read it returns `nil`.
    func focusedWindowTitle(in application: OmniSelectionApplication) -> String?
}

public extension OmniSelectionSnapshotProvider {
    func focusedWindowTitle(in application: OmniSelectionApplication) -> String? { nil }
}

/// A narrow seam for exercising the same AX query order with synthetic values.
/// Calls stay synchronous on the detached capture worker; CF values never cross
/// an actor or task boundary.
struct OmniAXSelectionReads {
    let attribute: (AXUIElement, CFString) -> (AXError, CFTypeRef?)
    let parameterized: (AXUIElement, CFString, CFTypeRef) -> (AXError, CFTypeRef?)

    static var system: Self {
        Self(
            attribute: { element, name in
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, name, &value)
                return (error, value)
            },
            parameterized: { element, name, parameter in
                var value: CFTypeRef?
                let error = AXUIElementCopyParameterizedAttributeValue(element, name, parameter, &value)
                return (error, value)
            }
        )
    }
}

/// Captures selection before the command pad takes focus. There is no clipboard
/// path and no cache: every result is tied to the current foreground PID.
@MainActor
public final class NativeSelectionCapture {
    public static let defaultMaximumTextLength = 4_096
    public static let hardMaximumTextLength = 16_384
    public static let defaultCaptureTimeout: Duration = .milliseconds(500)

    private let provider: any OmniSelectionSnapshotProvider
    private let maximumTextLength: Int
    private let captureTimeout: Duration

    public init(
        provider: any OmniSelectionSnapshotProvider = SystemOmniSelectionSnapshotProvider(),
        maximumTextLength: Int = NativeSelectionCapture.defaultMaximumTextLength,
        captureTimeout: Duration = NativeSelectionCapture.defaultCaptureTimeout
    ) {
        self.provider = provider
        self.maximumTextLength = min(max(1, maximumTextLength), Self.hardMaximumTextLength)
        self.captureTimeout = captureTimeout
    }

    /// Snapshot the frontmost target and read only its focused selection. The
    /// final PID check rejects text if focus changed while AX was responding.
    public func captureCurrentSelection(excludingPID: Int32) async -> CapturedOmniSelectionResult {
        guard provider.accessibilityPermissionIsGranted() else {
            return .unavailable(.accessibilityPermissionRequired)
        }
        guard let application = provider.frontmostApplication() else {
            return .unavailable(.noFrontmostApplication)
        }
        guard application.processID != excludingPID else {
            return .unavailable(.excludedProcess)
        }

        let read = await boundedSelectionRead(for: application)
        guard provider.frontmostApplication()?.processID == application.processID else {
            return .unavailable(.foregroundChanged)
        }

        switch read.result {
        case .selected(let text):
            guard !text.isEmpty else { return .empty }
            guard text.count <= maximumTextLength else {
                return .unavailable(.selectionTooLong)
            }
            return .selected(CapturedOmniSelection(
                text: text,
                appName: application.name,
                processID: application.processID,
                windowTitle: read.windowTitle,
                bundleIdentifier: application.bundleIdentifier
            ))
        case .empty:
            return .empty
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    /// The selection and, when there is one, the focused window's title, both
    /// read off the main actor under the one capture timeout.
    private func boundedSelectionRead(for application: OmniSelectionApplication) async -> BoundedSelectionRead {
        let provider = provider
        let timeout = captureTimeout
        let maximumTextLength = maximumTextLength
        return await withCheckedContinuation { continuation in
            let gate = SelectionCaptureResultGate(continuation: continuation)
            Task.detached(priority: .userInitiated) {
                let result = await provider.selection(in: application, maximumTextLength: maximumTextLength)
                var title: String?
                if case .selected(let text) = result, !text.isEmpty {
                    title = provider.focusedWindowTitle(in: application)
                }
                gate.resume(with: BoundedSelectionRead(result: result, windowTitle: title))
            }
            Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(for: timeout)
                    gate.resume(with: BoundedSelectionRead(result: .unavailable(.timedOut), windowTitle: nil))
                } catch {
                    // This detached timeout is never cancelled by the caller;
                    // retain the catch to keep future cancellation harmless.
                }
            }
        }
    }
}

/// The default macOS implementation. `frontmostApplication` runs on the main
/// actor, while AX messaging moves to a detached task so an unresponsive target
/// cannot block AppKit event handling.
public struct SystemOmniSelectionSnapshotProvider: OmniSelectionSnapshotProvider {
    public init() {}

    public func accessibilityPermissionIsGranted() -> Bool {
        // The documented key's string value avoids importing the SDK's mutable
        // global declaration into Swift 6's strict-concurrency boundary.
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @MainActor public func frontmostApplication() -> OmniSelectionApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return OmniSelectionApplication(
            processID: application.processIdentifier,
            name: application.localizedName ?? application.bundleIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    public func selection(in application: OmniSelectionApplication, maximumTextLength: Int) async -> OmniSelectionSourceResult {
        await Task.detached(priority: .userInitiated) {
            Self.readFocusedSelection(
                processID: application.processID,
                bundleIdentifier: application.bundleIdentifier,
                maximumTextLength: maximumTextLength
            )
        }.value
    }

    /// Best-effort window title for provenance display. Never prompts for
    /// permission, and any AX failure (unsupported attribute, no focused
    /// window, wrong type) simply yields `nil` rather than throwing.
    public func focusedWindowTitle(in application: OmniSelectionApplication) -> String? {
        guard accessibilityPermissionIsGranted() else { return nil }
        return Self.readFocusedWindowTitle(processID: application.processID)
    }

    private static func readFocusedWindowTitle(processID: Int32) -> String? {
        let process = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetMessagingTimeout(process, 0.45)
        var windowValue: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(process, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard windowResult == .success, let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        _ = AXUIElementSetMessagingTimeout(window, 0.45)
        return stringAttribute(kAXTitleAttribute, from: window)
    }

    private static func readFocusedSelection(processID: Int32, bundleIdentifier: String?, maximumTextLength: Int) -> OmniSelectionSourceResult {
        let process = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetMessagingTimeout(process, 0.45)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(process, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard focusedResult == .success else { return unavailable(for: focusedResult) }
        guard let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .unavailable(.sourceUnsupported)
        }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)
        _ = AXUIElementSetMessagingTimeout(focused, 0.45)

        return readSelection(
            from: focused,
            bundleIdentifier: bundleIdentifier,
            maximumTextLength: maximumTextLength,
            reads: .system
        )
    }

    static func readSelection(
        from focused: AXUIElement,
        bundleIdentifier: String?,
        maximumTextLength: Int,
        reads: OmniAXSelectionReads
    ) -> OmniSelectionSourceResult {
        let role = stringAttribute(kAXRoleAttribute, from: focused, reads: reads)
        let subrole = stringAttribute(kAXSubroleAttribute, from: focused, reads: reads)

        // Password controls must never be read, including through the range
        // and text-marker parameterized attributes below.
        let secureTextFieldSubrole = kAXSecureTextFieldSubrole as String
        if role == secureTextFieldSubrole || subrole == secureTextFieldSubrole {
            return .unavailable(.secureTextField)
        }

        let isSafari = bundleIdentifier == "com.apple.Safari"
            || bundleIdentifier == "com.apple.SafariTechnologyPreview"

        let (selectedResult, selectedValue) = reads.attribute(focused, kAXSelectedTextAttribute as CFString)
        if selectedResult == .success {
            guard let selected = selectedValue as? String else {
                return .unavailable(.sourceUnsupported)
            }
            // A WebArea can expose a document selection through text markers
            // even when its ordinary selected-text answer is empty. A native
            // text control's empty answer remains authoritative.
            if selected.isEmpty && isSafari && role == "AXWebArea" {
                return markerSelectionPreservingEmpty(from: focused, maximumTextLength: maximumTextLength, reads: reads)
            }
            return selectionResult(for: selected, maximumTextLength: maximumTextLength)
        }
        guard selectedResult == .attributeUnsupported || selectedResult == .noValue else {
            return unavailable(for: selectedResult)
        }

        // Some otherwise accessible controls omit AXSelectedText. For those,
        // obtain the selected range first and ask AX for that range only. This
        // never falls back to the pasteboard or synthesizes a copy command.
        let ranged = selectedTextUsingRange(from: focused, maximumTextLength: maximumTextLength, reads: reads)
        guard isSafari else { return ranged }
        switch ranged {
        case .unavailable(.sourceUnsupported):
            return selectedTextUsingMarker(from: focused, maximumTextLength: maximumTextLength, reads: reads)
        case .empty where role == "AXWebArea":
            return markerSelectionPreservingEmpty(from: focused, maximumTextLength: maximumTextLength, reads: reads)
        default:
            return ranged
        }
    }

    private static func selectedTextUsingRange(
        from element: AXUIElement,
        maximumTextLength: Int,
        reads: OmniAXSelectionReads
    ) -> OmniSelectionSourceResult {
        let (rangeResult, rangeValue) = reads.attribute(element, kAXSelectedTextRangeAttribute as CFString)
        guard rangeResult == .success else { return unavailable(for: rangeResult) }
        guard let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return .unavailable(.sourceUnsupported)
        }
        let rangeAXValue = unsafeDowncast(rangeValue, to: AXValue.self)
        guard AXValueGetType(rangeAXValue) == .cfRange else {
            return .unavailable(.sourceUnsupported)
        }
        var range = CFRange()
        guard AXValueGetValue(rangeAXValue, .cfRange, &range), range.location >= 0 else {
            return .unavailable(.sourceUnsupported)
        }
        guard range.length > 0 else { return .empty }
        guard range.length <= maximumTextLength else { return .unavailable(.selectionTooLong) }

        let (stringResult, selectionValue) = reads.parameterized(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue
        )
        guard stringResult == .success else { return unavailable(for: stringResult) }
        guard let selection = selectionValue as? String else { return .unavailable(.sourceUnsupported) }
        return selectionResult(for: selection, maximumTextLength: maximumTextLength)
    }

    private static func markerSelectionPreservingEmpty(
        from element: AXUIElement,
        maximumTextLength: Int,
        reads: OmniAXSelectionReads
    ) -> OmniSelectionSourceResult {
        let result = selectedTextUsingMarker(from: element, maximumTextLength: maximumTextLength, reads: reads)
        // The ordinary API already established an empty selection. A speculative
        // marker lookup must not turn that into an error unless it found a range
        // exceeding our explicit size limit.
        switch result {
        case .selected, .unavailable(.selectionTooLong): return result
        default: return .empty
        }
    }

    private static func selectedTextUsingMarker(
        from element: AXUIElement,
        maximumTextLength: Int,
        reads: OmniAXSelectionReads
    ) -> OmniSelectionSourceResult {
        let (markerResult, markerValue) = reads.attribute(element, "AXSelectedTextMarkerRange" as CFString)
        guard markerResult == .success else { return unavailable(for: markerResult) }
        guard let markerValue, CFGetTypeID(markerValue) == AXTextMarkerRangeGetTypeID() else {
            return .unavailable(.sourceUnsupported)
        }

        // The public AX length query returns UTF-16 code units. Query it before
        // requesting text so an oversized document selection is never copied.
        let (lengthResult, lengthValue) = reads.parameterized(
            element, "AXLengthForTextMarkerRange" as CFString, markerValue
        )
        guard lengthResult == .success else { return unavailable(for: lengthResult) }
        guard let lengthValue, CFGetTypeID(lengthValue) == CFNumberGetTypeID(),
              let number = lengthValue as? NSNumber else {
            return .unavailable(.sourceUnsupported)
        }
        let length = number.doubleValue
        guard length.isFinite, length >= 0, length.rounded(.towardZero) == length else {
            return .unavailable(.sourceUnsupported)
        }
        guard length > 0 else { return .empty }
        guard length <= Double(maximumTextLength) else { return .unavailable(.selectionTooLong) }

        let (stringResult, stringValue) = reads.parameterized(
            element, "AXStringForTextMarkerRange" as CFString, markerValue
        )
        guard stringResult == .success else { return unavailable(for: stringResult) }
        guard let text = stringValue as? String else { return .unavailable(.sourceUnsupported) }
        guard text.utf16.count <= maximumTextLength else { return .unavailable(.selectionTooLong) }
        return selectionResult(for: text, maximumTextLength: maximumTextLength)
    }

    private static func selectionResult(for text: String, maximumTextLength: Int) -> OmniSelectionSourceResult {
        guard !text.isEmpty else { return .empty }
        guard text.count <= maximumTextLength else { return .unavailable(.selectionTooLong) }
        return .selected(text)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement, reads: OmniAXSelectionReads) -> String? {
        let (result, value) = reads.attribute(element, attribute as CFString)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func unavailable(for error: AXError) -> OmniSelectionSourceResult {
        if error == .apiDisabled { return .unavailable(.accessibilityPermissionRequired) }
        if error == .attributeUnsupported || error == .noValue { return .unavailable(.sourceUnsupported) }
        return .unavailable(.sourceFailed(error.rawValue))
    }
}

/// Resumes exactly once when either the AX read or the timeout wins. A timed
/// out AX IPC call may finish later, but it has no retained selection state and
/// can no longer affect the returned result.
private struct BoundedSelectionRead: Sendable {
    let result: OmniSelectionSourceResult
    let windowTitle: String?
}

private final class SelectionCaptureResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BoundedSelectionRead, Never>?

    init(continuation: CheckedContinuation<BoundedSelectionRead, Never>) {
        self.continuation = continuation
    }

    func resume(with result: BoundedSelectionRead) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
