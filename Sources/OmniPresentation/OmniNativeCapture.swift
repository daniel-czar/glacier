import AppKit
import HyperOverlayRuntime

public enum OmniMaterialTreatment: String, Sendable {
    case nativeMaterial
    case opaqueFallback
}

public enum OmniNativeCaptureScenario: String, CaseIterable, Sendable {
    case emptyEditor, longEditor, autocomplete, referencePicker
    case proposal, failure, settings, contrastFallback, constrainedScreen

    public var accessibilityIdentifier: String { "omni.capture.\(rawValue)" }
}

/// Captures an actual AppKit view tree after the application has supplied
/// fixture data. It performs no owner, provider, or platform operation.
@MainActor
public enum OmniNativeCaptureHarness {
    public static func prepare(
        _ view: NSView,
        scenario: OmniNativeCaptureScenario,
        treatment: OmniMaterialTreatment = .nativeMaterial,
        appearance: NSAppearance.Name = .aqua
    ) {
        view.appearance = NSAppearance(named: appearance)
        view.setAccessibilityIdentifier(scenario.accessibilityIdentifier)
        apply(treatment: treatment, to: view)
        view.layoutSubtreeIfNeeded()
    }

    public static func image(of view: NSView) -> NSImage {
        let bounds = view.bounds.integral
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(bounds.width)),
            pixelsHigh: max(1, Int(bounds.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        view.needsDisplay = true
        view.subviews.forEach { $0.needsDisplay = true; $0.layoutSubtreeIfNeeded() }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: representation)
        }
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    public static func image(of panel: NSPanel) -> NSImage? {
        panel.contentView.map(image(of:))
    }

    private static func apply(treatment: OmniMaterialTreatment, to view: NSView) {
        (view as? OmniMaterialView)?.apply(transparency: treatment)
        view.subviews.forEach { apply(treatment: treatment, to: $0) }
    }
}

/// The pad's fixed screen position (C23): centred, in the upper third,
/// regardless of how it was invoked (Spotlight idiom). Separate from the
/// Hyper overlay's own placement, which the live host keeps.
public enum OmniPadPlacement {
    public static let width: CGFloat = 640
    /// Fraction of the visible height above the pad's top edge.
    public static let topFraction: CGFloat = 0.2

    public static func frame(size: NSSize, visibleFrame: NSRect, margin: CGFloat = 12) -> NSRect {
        let width = min(size.width, max(1, visibleFrame.width - margin * 2))
        let x = visibleFrame.midX - width / 2
        let top = visibleFrame.maxY - visibleFrame.height * topFraction
        let y = max(visibleFrame.minY + margin, top - size.height)
        return NSRect(x: x, y: y, width: width, height: size.height)
    }
}

@MainActor
public enum OmniPanelFactory {
    public static func makePad(
        controller: OmniCommandPadViewController,
        visibleFrame: NSRect
    ) -> OmniCommandPadPanel {
        let size = NSSize(width: min(OmniPadPlacement.width, max(320, visibleFrame.width - 32)), height: 108)
        let panel = OmniCommandPadPanel(
            contentRect: OmniPadPlacement.frame(size: size, visibleFrame: visibleFrame),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        // The controller closes on app deactivation. AppKit's implicit hide
        // leaves isVisible and Omni's foreground ownership out of sync.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = controller
        panel.initialFirstResponder = controller.editor
        panel.setAccessibilityIdentifier("omni.command-pad")
        panel.setAccessibilityLabel("Glacier command pad")
        return panel
    }
}
