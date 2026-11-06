import AppKit
import OmniPresentation

@MainActor
public final class LaunchPalettePanel: HyperOverlayPanelBase {
    public let surface: OmniFrostedSurface
    public let paletteView: LaunchPaletteView
    public var onKeyDown: ((UInt16, NSEvent.ModifierFlags) -> Void)?

    public init() {
        let size = LaunchPaletteLayout.size(forCount: 8)
        surface = OmniFrostedSurface(frame: NSRect(origin: .zero, size: size), cornerRadius: 18)
        paletteView = LaunchPaletteView(frame: NSRect(origin: .zero, size: size))
        super.init(size: size, title: "Launch", accessibilityIdentifier: "hyper.launch.panel", allowsKey: true)
        surface.autoresizingMask = [.width, .height]
        paletteView.autoresizingMask = [.width, .height]
        surface.addSubview(paletteView)
        contentView = surface
    }

    public func apply(count: Int, visible: NSRect) {
        let natural = LaunchPaletteLayout.size(forCount: count)
        let scale = min(1, (visible.width - 40) / natural.width, (visible.height - 40) / natural.height)
        let size = NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(),
                           y: (visible.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        setFrame(frame, display: false)
        paletteView.frame = surface.bounds
        paletteView.bounds = NSRect(origin: .zero, size: natural)
        paletteView.needsDisplay = true
    }

    /// The nonactivating panel owns keys while visible. Unmapped keys are
    /// deliberately dropped, so they cannot type into the origin app.
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            keyDown(with: event)
            return
        }
        super.sendEvent(event)
    }

    public override func keyDown(with event: NSEvent) {
        onKeyDown?(event.keyCode, event.modifierFlags)
    }
}

@MainActor
public final class LaunchPaletteView: NSView {
    public var entries: [LaunchApplication] = [] { didSet { needsDisplay = true } }
    public var runningBundleIDs: Set<String> = [] { didSet { needsDisplay = true } }
    public var selectedIndex: Int? { didSet { needsDisplay = true } }
    public var onSelect: ((Int) -> Void)?
    public var onHover: ((Int?) -> Void)?
    public private(set) var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var allowsVibrancy: Bool { false }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    public func resetHover() {
        hoveredIndex = nil
        onHover?(nil)
    }

    public func refreshHoverFromPointer() {
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        setHover(index(at: convert(windowPoint, from: nil)))
    }

    public override func mouseMoved(with event: NSEvent) {
        setHover(index(at: convert(event.locationInWindow, from: nil)))
    }

    private func setHover(_ index: Int?) {
        guard hoveredIndex != index else { return }
        hoveredIndex = index
        onHover?(index)
    }

    public override func mouseExited(with event: NSEvent) {
        resetHover()
    }

    public override func mouseDown(with event: NSEvent) {
        if let index = index(at: convert(event.locationInWindow, from: nil)) { onSelect?(index) }
    }

    public func index(at point: NSPoint) -> Int? {
        entries.indices.first { cellFrame(at: $0).contains(point) }
    }

    public func cellFrame(at index: Int) -> NSRect {
        let columns = LaunchPaletteLayout.columns(forCount: entries.count)
        let row = index / columns
        let column = index % columns
        return NSRect(x: LaunchPaletteLayout.padding + CGFloat(column) * (LaunchPaletteLayout.cellWidth + LaunchPaletteLayout.gap),
                      y: LaunchPaletteLayout.padding + CGFloat(row) * (LaunchPaletteLayout.cellHeight + LaunchPaletteLayout.gap),
                      width: LaunchPaletteLayout.cellWidth, height: LaunchPaletteLayout.cellHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let keys = LaunchPaletteLayout.keys(for: entries)
        for index in entries.indices {
            let rect = cellFrame(at: index)
            let selected = index == selectedIndex
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            (selected ? OmniFrostedStyle.selectedFill : OmniFrostedStyle.controlFill).setFill()
            path.fill()
            (selected ? OmniFrostedStyle.command.withAlphaComponent(0.88) : OmniFrostedStyle.controlLine).setStroke()
            path.lineWidth = 1
            path.stroke()

            let cap = NSRect(x: rect.minX + 10, y: rect.minY + 9, width: 23, height: 21)
            let capPath = NSBezierPath(roundedRect: cap, xRadius: 5, yRadius: 5)
            OmniFrostedStyle.controlFill.setFill()
            capPath.fill()
            OmniFrostedStyle.controlLine.setStroke()
            capPath.stroke()
            drawText(keys[index], in: cap, size: 11, weight: .semibold, color: OmniFrostedStyle.secondaryInk)

            let app = entries[index]
            app.icon.draw(in: NSRect(x: rect.midX - 28, y: rect.minY + 29, width: 56, height: 56),
                          from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            drawText(app.name, in: NSRect(x: rect.minX + 5, y: rect.minY + 91, width: rect.width - 10, height: 19),
                     size: 12.5, weight: .medium, color: OmniFrostedStyle.ink)
            if runningBundleIDs.contains(app.bundleID) {
                let dot = NSBezierPath(ovalIn: NSRect(x: rect.midX - 2, y: rect.minY + 118, width: 4, height: 4))
                OmniFrostedStyle.ink.setFill()
                dot.fill()
            }
        }
    }

    private func drawText(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}
