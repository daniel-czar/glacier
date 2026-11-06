import AppKit

/// Shared native material vocabulary for Omni's compact floating surfaces.
/// The colors are dynamic, so an app-local appearance override is honoured
/// without requiring a separate theme setting.
@MainActor
public enum OmniFrostedStyle {
    public static let cornerRadius: CGFloat = 20
    public static let hairlineWidth: CGFloat = 0.5

    public static let bodyFont = NSFont.systemFont(ofSize: 14)
    public static let commandFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    public static let sourceTextFontSize: CGFloat = 19
    public static let smallLabelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    public static let diagnosticFont = NSFont.systemFont(ofSize: 12)

    /// Crisp navy text in light mode, with a softly lifted equivalent in dark mode.
    public static let ink = adaptiveColor(light: NSColor(srgbRed: 0.075, green: 0.122, blue: 0.157, alpha: 1), dark: NSColor(srgbRed: 0.941, green: 0.973, blue: 0.988, alpha: 1))
    public static let secondaryInk = adaptiveColor(light: NSColor(srgbRed: 0.20, green: 0.27, blue: 0.31, alpha: 0.82), dark: NSColor(srgbRed: 0.78, green: 0.85, blue: 0.88, alpha: 0.84))
    public static let line = adaptiveColor(light: NSColor.white.withAlphaComponent(0.54), dark: NSColor.white.withAlphaComponent(0.24))
    /// Control silhouettes need a neutral edge on a light opaque ground.
    /// Floating material surfaces clip cleanly without a white outer rim.
    public static let controlLine = adaptiveColor(light: NSColor(srgbRed: 0.20, green: 0.27, blue: 0.31, alpha: 0.18), dark: NSColor.white.withAlphaComponent(0.24))
    public static let controlFill = adaptiveColor(light: NSColor.white.withAlphaComponent(0.14), dark: NSColor.white.withAlphaComponent(0.09))
    public static let hoverFill = adaptiveColor(light: NSColor.white.withAlphaComponent(0.25), dark: NSColor.white.withAlphaComponent(0.16))
    public static let selectedFill = adaptiveColor(light: NSColor(srgbRed: 0.76, green: 0.90, blue: 0.98, alpha: 0.63), dark: NSColor(srgbRed: 0.18, green: 0.40, blue: 0.55, alpha: 0.68))
    // Token tints per C41 (placeholders to tune on the real display): text on a
    // 13 % fill in light, 20 % in dark. Command `#0a4fa0`/`#a4c8ff`, modifier
    // `#5b3a9c`/`#cdb6ff`, mode `#0f6e5c`/`#8fe3c9`, unresolved grey.
    public static let accent = adaptiveColor(light: NSColor(srgbRed: 0x0a / 255, green: 0x4f / 255, blue: 0xa0 / 255, alpha: 1), dark: NSColor(srgbRed: 0xa4 / 255, green: 0xc8 / 255, blue: 0xff / 255, alpha: 1))
    public static var command: NSColor { accent }
    public static let modifier = adaptiveColor(light: NSColor(srgbRed: 0x5b / 255, green: 0x3a / 255, blue: 0x9c / 255, alpha: 1), dark: NSColor(srgbRed: 0xcd / 255, green: 0xb6 / 255, blue: 0xff / 255, alpha: 1))
    public static let mode = adaptiveColor(light: NSColor(srgbRed: 0x0f / 255, green: 0x6e / 255, blue: 0x5c / 255, alpha: 1), dark: NSColor(srgbRed: 0x8f / 255, green: 0xe3 / 255, blue: 0xc9 / 255, alpha: 1))
    /// Half-typed and unknown tokens share one tint: "unresolved", not "error" (C28).
    public static let unresolved = adaptiveColor(light: NSColor.black.withAlphaComponent(0.55), dark: NSColor.white.withAlphaComponent(0.6))
    public static let reference = adaptiveColor(light: NSColor(srgbRed: 0.09, green: 0.37, blue: 0.30, alpha: 1), dark: NSColor(srgbRed: 0.72, green: 0.92, blue: 0.83, alpha: 1))
    public static let warning = adaptiveColor(light: NSColor(srgbRed: 0.70, green: 0.18, blue: 0.18, alpha: 1), dark: NSColor(srgbRed: 1, green: 0.61, blue: 0.58, alpha: 1))
    /// Provisional alias-expanded colour: warm bronze inside the frosted palette.
    public static let aliasExpanded = adaptiveColor(light: NSColor(srgbRed: 0.45, green: 0.30, blue: 0.12, alpha: 1), dark: NSColor(srgbRed: 0.96, green: 0.84, blue: 0.62, alpha: 1))
    /// A `/find` pill's key (D2): the command hue, dimmed; its value takes
    /// the full command hue, both on the command token fill.
    public static let findPillKey = adaptiveColor(light: NSColor(srgbRed: 0x0a / 255, green: 0x4f / 255, blue: 0xa0 / 255, alpha: 0.58), dark: NSColor(srgbRed: 0xa4 / 255, green: 0xc8 / 255, blue: 0xff / 255, alpha: 0.62))
    public static let tokenValue = adaptiveColor(light: NSColor(srgbRed: 0.12, green: 0.22, blue: 0.42, alpha: 1), dark: NSColor(srgbRed: 0.82, green: 0.90, blue: 1, alpha: 1))

    public static let accentTokenFill = adaptiveColor(light: NSColor(srgbRed: 0x0a / 255, green: 0x4f / 255, blue: 0xa0 / 255, alpha: 0.13), dark: NSColor(srgbRed: 0xa4 / 255, green: 0xc8 / 255, blue: 0xff / 255, alpha: 0.20))
    public static var commandTokenFill: NSColor { accentTokenFill }
    public static let modifierTokenFill = adaptiveColor(light: NSColor(srgbRed: 0x5b / 255, green: 0x3a / 255, blue: 0x9c / 255, alpha: 0.13), dark: NSColor(srgbRed: 0xcd / 255, green: 0xb6 / 255, blue: 0xff / 255, alpha: 0.20))
    public static let modeTokenFill = adaptiveColor(light: NSColor(srgbRed: 0x0f / 255, green: 0x6e / 255, blue: 0x5c / 255, alpha: 0.13), dark: NSColor(srgbRed: 0x8f / 255, green: 0xe3 / 255, blue: 0xc9 / 255, alpha: 0.20))
    public static let unresolvedTokenFill = adaptiveColor(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.10))
    public static let referenceTokenFill = adaptiveColor(light: NSColor(srgbRed: 0.80, green: 0.94, blue: 0.87, alpha: 0.76), dark: NSColor(srgbRed: 0.10, green: 0.31, blue: 0.25, alpha: 0.84))
    public static let aliasExpandedTokenFill = adaptiveColor(light: NSColor(srgbRed: 0.96, green: 0.90, blue: 0.76, alpha: 0.80), dark: NSColor(srgbRed: 0.38, green: 0.28, blue: 0.14, alpha: 0.84))
    public static let tokenValueFill = adaptiveColor(light: NSColor(srgbRed: 0.88, green: 0.93, blue: 0.98, alpha: 0.72), dark: NSColor(srgbRed: 0.16, green: 0.28, blue: 0.40, alpha: 0.78))
    /// Guidance spans use amber over the rendered text, leaving token fills in
    /// place. The hue is brighter than the alias-expanded token's warm tan.
    public static let annotationFill = adaptiveColor(light: NSColor(srgbRed: 1, green: 0.72, blue: 0, alpha: 0.30), dark: NSColor(srgbRed: 1, green: 0.68, blue: 0.08, alpha: 0.32))
    public static let annotationActiveFill = adaptiveColor(light: NSColor(srgbRed: 1, green: 0.72, blue: 0, alpha: 0.42), dark: NSColor(srgbRed: 1, green: 0.68, blue: 0.08, alpha: 0.47))
    public static let annotationRule = adaptiveColor(light: NSColor(srgbRed: 0.68, green: 0.37, blue: 0, alpha: 1), dark: NSColor(srgbRed: 1, green: 0.74, blue: 0.32, alpha: 1))

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// A diffuse AppKit material surface with a clipped edge. The visual-effect
/// mask shapes both its material and the window shadow when used as contentView.
@MainActor
public class OmniFrostedSurface: NSVisualEffectView {
    public private(set) var materialTreatment: OmniMaterialTreatment = .nativeMaterial
    public let cornerRadius: CGFloat
    private var materialMaskSize: NSSize = .zero

    public init(frame frameRect: NSRect, cornerRadius: CGFloat = OmniFrostedStyle.cornerRadius) {
        self.cornerRadius = cornerRadius
        super.init(frame: frameRect)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        refreshMaterialMask()
        refreshAccessibilityTreatment()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceDetails()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshMaterialMask()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        refreshMaterialMask()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshMaterialMask(force: true)
    }

    private func refreshMaterialMask(force: Bool = false) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard force || size != materialMaskSize else { return }
        materialMaskSize = size
        let radius = min(cornerRadius, size.width / 2, size.height / 2)
        maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    /// Allows capture and test callers to force the same accessible treatment
    /// used when macOS has Reduce Transparency or Increase Contrast enabled.
    public func apply(transparency: OmniMaterialTreatment) {
        materialTreatment = transparency
        switch transparency {
        case .nativeMaterial:
            material = .underWindowBackground
            blendingMode = .behindWindow
            layer?.backgroundColor = nil
        case .opaqueFallback:
            material = .windowBackground
            blendingMode = .withinWindow
            layer?.backgroundColor = resolved(OmniFrostedStyle.controlFill).cgColor
        }
        applyAppearanceDetails()
    }

    public func refreshAccessibilityTreatment() {
        let workspace = NSWorkspace.shared
        let accessible = workspace.accessibilityDisplayShouldReduceTransparency || workspace.accessibilityDisplayShouldIncreaseContrast
        apply(transparency: accessible ? .opaqueFallback : .nativeMaterial)
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        refreshAccessibilityTreatment()
    }

    private func applyAppearanceDetails() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        let opaqueFallback = materialTreatment == .opaqueFallback
        layer.borderWidth = opaqueFallback ? 1 : 0
        layer.borderColor = opaqueFallback
            ? resolved(OmniFrostedStyle.secondaryInk).withAlphaComponent(0.42).cgColor
            : nil
        if opaqueFallback {
            layer.backgroundColor = resolved(NSColor.windowBackgroundColor).cgColor
        }
    }

    private func resolved(_ color: NSColor) -> NSColor {
        var concrete: NSColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            concrete = color.usingColorSpace(.deviceRGB) ?? color
        }
        return concrete ?? color
    }
}
