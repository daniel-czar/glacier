import AppKit
import HyperOverlayCore
import OmniPresentation

/// The picture (C100–C102): the user's keyboard from the layout table, bound
/// keys tinted by kind with their label on the cap, unbound keys faded back.
/// The supplied keyboard layout and pressed-cap set control modifier labels
/// and held appearance. Pinned adds the
/// `esc Close` hint and a read-only popover on hover.
@MainActor
public final class HyperKeyOverlayView: NSView {
    public enum Mode: Sendable, Equatable { case held, pinned }

    public static let padding = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
    public static let hintRowHeight: CGFloat = 34
    static let capRadius: CGFloat = 8
    /// Condensed: at 9.5 pt AppKit sets SF wider than the canvas's browser
    /// rendering, and `Pronounce` would not fit a 58 pt cap.
    static let labelFont = NSFont.systemFont(ofSize: 9.5, weight: .medium, width: .condensed)
    static let glyphFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let shiftedFont = NSFont.systemFont(ofSize: 11)
    static let modifierFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let functionFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    public let keyboard: HyperKeyboardLayout
    public var catalog: HyperBindingCatalog { didSet { needsDisplay = true; hidePopover() } }
    /// Physical modifier caps to draw as held. Glacier supplies the configured
    /// modifier group; the legacy host retains its Caps Lock default.
    public var pressedCapIDs: Set<String> = ["caps"] { didSet { needsDisplay = true } }
    public var mode: Mode = .held {
        didSet {
            guard oldValue != mode else { return }
            keyHintsView.isHidden = mode != .pinned
            if mode != .pinned { hidePopover() }
            needsDisplay = true
        }
    }
    public private(set) var hoveredCapID: String?
    public let keyHintsView = OmniKeyHintsView()
    public let popover = HyperKeyPopoverView()
    private var trackingArea: NSTrackingArea?

    public init(layout: HyperKeyboardLayout, catalog: HyperBindingCatalog) {
        self.keyboard = layout
        self.catalog = catalog
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize(layout: layout, mode: .held)))
        keyHintsView.hints = [.init("esc", "Close")]
        keyHintsView.isHidden = true
        keyHintsView.setAccessibilityIdentifier("hyper.keys.hints")
        addSubview(keyHintsView)
        popover.isHidden = true
        addSubview(popover)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Hyper keys")
        setAccessibilityIdentifier("hyper.keys")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { true }
    public override var allowsVibrancy: Bool { false }

    public static func contentSize(layout: HyperKeyboardLayout, mode: Mode) -> NSSize {
        NSSize(width: padding.left + layout.size.width + padding.right,
               height: padding.top + layout.size.height + padding.bottom + (mode == .pinned ? hintRowHeight : 0))
    }

    /// Where a cap sits in this view.
    public func rect(for cap: HyperKeyCap) -> NSRect { cap.frame.offsetBy(dx: Self.padding.left, dy: Self.padding.top) }

    public override func layout() {
        super.layout()
        let width = keyHintsView.fittingWidth
        keyHintsView.frame = NSRect(x: bounds.width - Self.padding.right - width,
                                    y: bounds.height - Self.padding.bottom / 2 - 30, width: width, height: 30)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        for cap in keyboard.caps {
            draw(cap)
        }
    }

    private func draw(_ cap: HyperKeyCap) {
        let rect = rect(for: cap)
        let path = Self.outline(for: cap, offset: NSPoint(x: Self.padding.left, y: Self.padding.top))
        let binding = catalog.bindings[cap.id]
        let pressed = pressedCapIDs.contains(cap.id) && mode == .held
        let tint = binding.map { $0.kind == .surface ? OmniFrostedStyle.mode : OmniFrostedStyle.command }
        let ink = NSColor.labelColor

        if pressed {
            OmniFrostedStyle.mode.withAlphaComponent(0.32).setFill()
            path.fill()
            // Inset shadow: the key is down.
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowBlurRadius = 4
            shadow.set()
            let rim = NSBezierPath(rect: rect.insetBy(dx: -8, dy: -8))
            rim.append(path.reversed)
            NSColor.black.withAlphaComponent(0.6).setFill()
            rim.fill()
            NSGraphicsContext.restoreGraphicsState()
            OmniFrostedStyle.mode.withAlphaComponent(0.7).setStroke()
        } else if let tint {
            tint.withAlphaComponent(0.13).setFill()
            path.fill()
            tint.withAlphaComponent(hoveredCapID == cap.id ? 0.8 : 0.35).setStroke()
        } else {
            ink.withAlphaComponent(0.05).setFill()
            path.fill()
            ink.withAlphaComponent(0.08).setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        let glyphInk = pressed || binding != nil ? ink : ink.withAlphaComponent(0.32)
        switch cap.style {
        case .character:
            text(cap.glyph, font: Self.glyphFont, color: glyphInk, at: NSPoint(x: rect.minX + 7, y: rect.minY + 5))
            if let shifted = cap.shifted {
                let size = (shifted as NSString).size(withAttributes: [.font: Self.shiftedFont])
                text(shifted, font: Self.shiftedFont, color: glyphInk.withAlphaComponent(glyphInk.alphaComponent * 0.8),
                     at: NSPoint(x: rect.maxX - 7 - size.width, y: rect.minY + 5))
            }
        case .modifier where binding != nil:
            // A bound modifier key (⌫ Clear collected): the word moves up to
            // the letter's place so the label can take the bottom-left.
            text(cap.glyph, font: Self.modifierFont, color: glyphInk, at: NSPoint(x: rect.minX + 7, y: rect.minY + 5))
        case .modifier:
            let word = (pressed ? NSFont.systemFont(ofSize: 11, weight: .semibold) : Self.modifierFont)
            let height = ("Ag" as NSString).size(withAttributes: [.font: word]).height
            text(cap.glyph, font: word, color: glyphInk, at: NSPoint(x: rect.minX + 7, y: rect.maxY - 6 - height))
            if let symbol = cap.symbol {
                let font = NSFont.systemFont(ofSize: 12)
                let size = (symbol as NSString).size(withAttributes: [.font: font])
                text(symbol, font: font, color: glyphInk, at: NSPoint(x: rect.maxX - 7 - size.width, y: rect.minY + 5))
            }
        case .function:
            text(cap.glyph, font: Self.functionFont, color: glyphInk, at: NSPoint(x: rect.minX + 7, y: rect.minY + 7))
        case .arrow:
            let font = NSFont.systemFont(ofSize: 11)
            let size = (cap.glyph as NSString).size(withAttributes: [.font: font])
            text(cap.glyph, font: font, color: glyphInk, at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        case .space:
            break
        case .isoEnter:
            let stem = (cap.stemFrame ?? cap.frame).offsetBy(dx: Self.padding.left, dy: Self.padding.top)
            let font = NSFont.systemFont(ofSize: 11)
            let size = (cap.glyph as NSString).size(withAttributes: [.font: font])
            text(cap.glyph, font: font, color: glyphInk, at: NSPoint(x: stem.maxX - 7 - size.width, y: stem.maxY - 6 - size.height))
        }

        if let binding, let tint {
            let labelRect: NSRect
            if cap.style == .space {
                // The Space bar has no letter: its label takes the modifier
                // word's place, bottom-left.
                let height = ("Ag" as NSString).size(withAttributes: [.font: Self.modifierFont]).height
                labelRect = NSRect(x: rect.minX + 7, y: rect.maxY - 6 - height, width: rect.width - 12, height: height)
                (binding.label as NSString).draw(in: labelRect, withAttributes: [.font: Self.modifierFont, .foregroundColor: tint])
            } else {
                let height = Self.labelHeight(binding.label, width: rect.width - 12)
                labelRect = NSRect(x: rect.minX + 7, y: rect.maxY - 6 - height, width: rect.width - 12, height: height)
                (binding.label as NSString).draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                 attributes: Self.labelAttributes(color: tint))
            }
        }
    }

    private func text(_ string: String, font: NSFont, color: NSColor, at point: NSPoint) {
        guard !string.isEmpty else { return }
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    static func labelAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.0
        paragraph.maximumLineHeight = 11
        paragraph.minimumLineHeight = 11
        return [.font: labelFont, .foregroundColor: color, .paragraphStyle: paragraph, .kern: 0.1]
    }

    /// At most two lines at the cap's label width (C101).
    static func labelHeight(_ label: String, width: CGFloat) -> CGFloat {
        let measured = (label as NSString).boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin],
                                                        attributes: labelAttributes(color: .labelColor)).height
        return min(ceil(measured), 22)
    }

    /// Whether `label` fits a standard cap in two lines without truncation.
    public static func labelFits(_ label: String, capWidth: CGFloat = HyperKeyboardLayout.keySize) -> Bool {
        let measured = (label as NSString).boundingRect(with: NSSize(width: capWidth - 12, height: 200), options: [.usesLineFragmentOrigin],
                                                        attributes: labelAttributes(color: .labelColor))
        let words = label.split(separator: " ")
        let widest = words.map { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0
        return ceil(measured.height) <= 22 && widest <= capWidth - 12
    }

    /// A rounded cap; the ISO Enter's outline steps in for its narrower stem.
    static func outline(for cap: HyperKeyCap, offset: NSPoint) -> NSBezierPath {
        let top = cap.frame.offsetBy(dx: offset.x, dy: offset.y)
        guard let stemFrame = cap.stemFrame else {
            return NSBezierPath(roundedRect: top.insetBy(dx: 0.5, dy: 0.5), xRadius: capRadius, yRadius: capRadius)
        }
        let stem = stemFrame.offsetBy(dx: offset.x, dy: offset.y)
        let r = capRadius
        // Flipped view: y grows downward. Clockwise from the top-left corner.
        let points = [
            NSPoint(x: top.minX + 0.5, y: top.minY + 0.5), NSPoint(x: top.maxX - 0.5, y: top.minY + 0.5),
            NSPoint(x: top.maxX - 0.5, y: stem.maxY - 0.5), NSPoint(x: stem.minX + 0.5, y: stem.maxY - 0.5),
            NSPoint(x: stem.minX + 0.5, y: top.maxY - 0.5), NSPoint(x: top.minX + 0.5, y: top.maxY - 0.5),
        ]
        let path = NSBezierPath()
        let start = NSPoint(x: (points[0].x + points[1].x) / 2, y: points[0].y)
        path.move(to: start)
        for index in 1...points.count {
            let corner = points[index % points.count]
            let next = points[(index + 1) % points.count]
            path.appendArc(from: corner, to: next, radius: r)
        }
        path.close()
        return path
    }

    // MARK: Hover (pinned only)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        hidePopover()
    }

    /// The cap under `point`, or nil; the Enter stem counts as Enter.
    public func cap(at point: NSPoint) -> HyperKeyCap? {
        keyboard.caps.first { cap in
            let offset = NSPoint(x: Self.padding.left, y: Self.padding.top)
            return Self.outline(for: cap, offset: offset).contains(point)
        }
    }

    public func hover(at point: NSPoint) {
        guard mode == .pinned, let cap = cap(at: point), let binding = catalog.bindings[cap.id] else {
            hidePopover()
            return
        }
        guard hoveredCapID != cap.id else { return }
        hoveredCapID = cap.id
        let chord = binding.chordLabel ?? (binding.owner == .keyboardMaestro
            ? "Hyper \(Self.chordName(cap))" : Self.chordName(cap))
        popover.show(title: "\(binding.label) · \(chord)", description: binding.description, meta: binding.shape)
        var anchor = rect(for: cap)
        if let stem = cap.stemFrame { anchor = anchor.union(stem.offsetBy(dx: Self.padding.left, dy: Self.padding.top)) }
        let size = popover.fittingSize
        var x = anchor.midX - size.width / 2
        x = max(Self.padding.left, min(x, bounds.width - Self.padding.right - size.width))
        // Below the key when it fits inside the panel, otherwise above.
        let below = anchor.maxY + 8
        let y = below + size.height <= bounds.height - 8 ? below : anchor.minY - 8 - size.height
        popover.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        popover.isHidden = false
        needsDisplay = true
    }

    public func hidePopover() {
        guard hoveredCapID != nil || !popover.isHidden else { return }
        hoveredCapID = nil
        popover.isHidden = true
        needsDisplay = true
    }

    static func chordName(_ cap: HyperKeyCap) -> String {
        switch cap.id {
        case "space": "Space"
        default: cap.glyph.isEmpty ? cap.id : cap.glyph
        }
    }
}

/// The pinned overlay's read-only detail: `<label> · Hyper <key>`, the long
/// description, and how the binding behaves.
@MainActor
public final class HyperKeyPopoverView: NSView {
    public let titleLabel = NSTextField(labelWithString: "")
    public let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    public let metaLabel = NSTextField(labelWithString: "")
    static let width: CGFloat = 230

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        descriptionLabel.font = .systemFont(ofSize: 12.5)
        descriptionLabel.preferredMaxLayoutWidth = Self.width - 24
        metaLabel.font = .systemFont(ofSize: 11.5)
        // Dynamic, so it resolves in the popover's own appearance.
        metaLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, descriptionLabel, metaLabel] { addSubview(label) }
        setAccessibilityIdentifier("hyper.keys.popover")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }
    public override var wantsUpdateLayer: Bool { true }

    public func show(title: String, description: String, meta: String) {
        titleLabel.stringValue = title
        descriptionLabel.stringValue = description
        metaLabel.stringValue = meta
        needsLayout = true
    }

    public override var fittingSize: NSSize {
        let inner = Self.width - 24
        let title = titleLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 16
        let body = descriptionLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 400)).height ?? 16
        let meta = metaLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 14
        return NSSize(width: Self.width, height: 10 + title + 2 + body + 6 + meta + 10)
    }

    public override func layout() {
        super.layout()
        let inner = bounds.width - 24
        let title = titleLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 16
        let body = descriptionLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 400)).height ?? 16
        let meta = metaLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 14
        titleLabel.frame = NSRect(x: 12, y: 10, width: inner, height: title)
        descriptionLabel.frame = NSRect(x: 12, y: titleLabel.frame.maxY + 2, width: inner, height: body)
        metaLabel.frame = NSRect(x: 12, y: descriptionLabel.frame.maxY + 6, width: inner, height: meta)
    }
}
