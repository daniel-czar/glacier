import AppKit

/// Shared window behavior for the held Hyper picture and keyed palettes.
/// A keyed child remains nonactivating: it can receive keys without making
/// the host the frontmost application.
@MainActor
public class HyperOverlayPanelBase: NSPanel {
    public var allowsKey: Bool

    public init(size: NSSize, title: String, accessibilityIdentifier: String, allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.title = title
        setAccessibilityIdentifier(accessibilityIdentifier)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    public override var canBecomeKey: Bool { allowsKey }
    public override var canBecomeMain: Bool { false }
}
