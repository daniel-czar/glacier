import AppKit
import HyperOverlayCore
import OmniPresentation

/// Windowless (C103): non-activating, floating, never key or main, frosted
/// with an 18 pt radius and a hairline, no title, close or traffic lights. It
/// joins every Space so it appears over full-screen apps too.
@MainActor
public final class HyperKeyOverlayPanel: HyperOverlayPanelBase {
    public static let cornerRadius: CGFloat = 18
    public let surface: OmniFrostedSurface
    public let keysView: HyperKeyOverlayView

    public init(layout: HyperKeyboardLayout, catalog: HyperBindingCatalog) {
        let size = HyperKeyOverlayView.contentSize(layout: layout, mode: .held)
        surface = OmniFrostedSurface(frame: NSRect(origin: .zero, size: size), cornerRadius: Self.cornerRadius)
        keysView = HyperKeyOverlayView(layout: layout, catalog: catalog)
        super.init(size: size, title: "Hyper Overlay", accessibilityIdentifier: "hyper.keys.panel", allowsKey: false)
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        surface.autoresizingMask = [.width, .height]
        keysView.frame = surface.bounds
        keysView.autoresizingMask = [.width, .height]
        surface.addSubview(keysView)
        contentView = surface
    }

    public override var canBecomeKey: Bool { false }

    /// Sizes the panel for `mode`, scaled down to fit `visible` when the
    /// picture is wider than the screen; the drawing keeps its own units.
    public func size(for mode: HyperKeyOverlayView.Mode, visible: NSRect) -> NSSize {
        let natural = HyperKeyOverlayView.contentSize(layout: keysView.keyboard, mode: mode)
        let scale = min(1, (visible.width - 40) / natural.width, (visible.height - 40) / natural.height)
        return NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    public func apply(mode: HyperKeyOverlayView.Mode, frame: NSRect) {
        keysView.mode = mode
        setFrame(frame, display: false)
        let natural = HyperKeyOverlayView.contentSize(layout: keysView.keyboard, mode: mode)
        keysView.frame = surface.bounds
        keysView.bounds = NSRect(origin: .zero, size: natural)
        keysView.needsLayout = true
        keysView.needsDisplay = true
        ignoresMouseEvents = mode != .pinned
    }
}

/// Centred on the active screen; below the pad when the pad is open (C103).
public enum HyperKeyOverlayPlacement {
    public static let padGap: CGFloat = 16

    public static func frame(size: NSSize, visible: NSRect, pad: NSRect?) -> NSRect {
        if let pad, pad.intersects(visible) {
            let y = pad.minY - padGap - size.height
            if y >= visible.minY + 8 {
                let x = min(max(pad.midX - size.width / 2, visible.minX + 8), visible.maxX - 8 - size.width)
                return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
            }
        }
        return NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The screen under the pointer (gotcha 13.6), or the pad's when it is open.
    public static func screen(pad: NSRect?, pointer: NSPoint = NSEvent.mouseLocation) -> NSScreen? {
        if let pad, let screen = NSScreen.screens.first(where: { $0.frame.intersects(pad) }) { return screen }
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }
}
