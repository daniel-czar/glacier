import AppKit
import Foundation

/// The menu bar item: a template slash-in-square glyph that opens while runs
/// are active, with a badge for completed and failed runs (C14, C63).
@MainActor
public final class OmniStatusItemPresenter {
    public let statusItem: NSStatusItem
    public private(set) var model: OmniStatusIndicatorModel
    public private(set) var lastRendered: OmniStatusIndicator = .idle
    private let badge = OmniStatusBadgeView()
    private let accessibilityLabel: String
    private let clock: () -> Date
    private let reduceMotion: () -> Bool
    private var lastReduceMotion: Bool?
    private var accessibilityObserver: NSObjectProtocol?
    private var ticker: Timer?

    public init(
        statusItem: NSStatusItem,
        accessibilityLabel: String,
        model: OmniStatusIndicatorModel = OmniStatusIndicatorModel(),
        clock: @escaping () -> Date = Date.init,
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.statusItem = statusItem
        self.model = model
        self.accessibilityLabel = accessibilityLabel
        self.clock = clock
        self.reduceMotion = reduceMotion
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            badge.frame = button.bounds
            badge.autoresizingMask = [.width, .height]
            button.addSubview(badge)
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        render()
    }

    public func runStarted(_ runID: String) {
        model.runStarted(runID, at: clock())
        render()
    }

    public func runFinished(_ runID: String, outcome: RunActivityOutcome, announceOutcome: Bool = true) {
        model.runFinished(runID, outcome: outcome, at: clock(), announceOutcome: announceOutcome)
        render()
    }

    public func runOpened(_ runID: String) {
        model.runOpened(runID)
        render()
    }

    public func render() {
        let now = clock()
        let indicator = model.indicator(at: now)
        let motionReduced = reduceMotion()
        if indicator != lastRendered || lastReduceMotion != motionReduced {
            lastRendered = indicator
            lastReduceMotion = motionReduced
            statusItem.button?.image = OmniStatusGlyph.image(for: indicator, reduceMotion: motionReduced)
            statusItem.button?.setAccessibilityLabel(Self.accessibilityLabel(for: indicator, baseLabel: accessibilityLabel))
            badge.indicator = indicator
            badge.needsDisplay = true
            statusItem.button?.toolTip = Self.toolTip(for: indicator)
        }
        let shouldTick = model.isAnimating(at: now) && !(motionReduced && indicator.isRunning)
        if shouldTick {
            if ticker == nil {
                // `.common` keeps the side stepping while a menu is open.
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.render() }
                }
                RunLoop.main.add(timer, forMode: .common)
                ticker = timer
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }

    static func toolTip(for indicator: OmniStatusIndicator) -> String {
        switch indicator {
        case .idle: "Glacier"
        case .running: "Glacier · running"
        case .done: "Glacier · done"
        case .failed: "Glacier · a run failed · open it to clear"
        }
    }

    static func accessibilityLabel(for indicator: OmniStatusIndicator, baseLabel: String) -> String {
        switch indicator {
        case .idle: baseLabel
        case .running: "\(baseLabel), working"
        case .done: "\(baseLabel), done"
        case .failed: "\(baseLabel), a run failed"
        }
    }

    public func tearDown() {
        ticker?.invalidate()
        ticker = nil
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

private extension OmniStatusIndicator {
    var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

/// Paths use AppKit's upward Y axis. Their 24-unit geometry is the SVG
/// reference reflected vertically, then scaled to the status item's 19 pt image box.
@MainActor enum OmniStatusGlyph {
    static let designSize: CGFloat = 24
    static let imageSize: CGFloat = 19
    static let strokeWidth: CGFloat = 2.2
    private static let cornerControl: CGFloat = 5 * 0.5522847498

    static func image(for indicator: OmniStatusIndicator, reduceMotion: Bool) -> NSImage {
        let paths = paths(for: indicator, reduceMotion: reduceMotion)
        let image = NSImage(size: NSSize(width: imageSize, height: imageSize), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.scale(by: imageSize / designSize)
            transform.concat()
            NSColor.black.setStroke()
            for path in paths { path.stroke() }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func paths(for indicator: OmniStatusIndicator, reduceMotion: Bool) -> [NSBezierPath] {
        outlinePaths(for: indicator, reduceMotion: reduceMotion) + [slashPath()]
    }

    static func outlinePaths(for indicator: OmniStatusIndicator, reduceMotion: Bool) -> [NSBezierPath] {
        if case .running(let step) = indicator {
            // The missing left side gives a fixed, recognisably open square.
            if reduceMotion { return [sidePath(0), sidePath(1), sidePath(2)] }
            return [sidePath((step % 4 + 4) % 4)]
        }
        let square = NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 18, height: 18), xRadius: 5, yRadius: 5)
        style(square)
        return [square]
    }

    static func slashPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 14.6, y: 17))
        path.line(to: NSPoint(x: 9.4, y: 7))
        style(path)
        return path
    }

    static func sidePath(_ index: Int) -> NSBezierPath {
        let path = NSBezierPath()
        let c = cornerControl
        switch index {
        case 0: // top, then upper-right corner
            path.move(to: NSPoint(x: 8, y: 21))
            path.line(to: NSPoint(x: 16, y: 21))
            path.curve(to: NSPoint(x: 21, y: 16), controlPoint1: NSPoint(x: 16 + c, y: 21), controlPoint2: NSPoint(x: 21, y: 16 + c))
        case 1: // right, then lower-right corner
            path.move(to: NSPoint(x: 21, y: 16))
            path.line(to: NSPoint(x: 21, y: 8))
            path.curve(to: NSPoint(x: 16, y: 3), controlPoint1: NSPoint(x: 21, y: 8 - c), controlPoint2: NSPoint(x: 16 + c, y: 3))
        case 2: // bottom, then lower-left corner
            path.move(to: NSPoint(x: 16, y: 3))
            path.line(to: NSPoint(x: 8, y: 3))
            path.curve(to: NSPoint(x: 3, y: 8), controlPoint1: NSPoint(x: 8 - c, y: 3), controlPoint2: NSPoint(x: 3, y: 8 - c))
        default: // left, then upper-left corner
            path.move(to: NSPoint(x: 3, y: 8))
            path.line(to: NSPoint(x: 3, y: 16))
            path.curve(to: NSPoint(x: 8, y: 21), controlPoint1: NSPoint(x: 3, y: 16 + c), controlPoint2: NSPoint(x: 8 - c, y: 21))
        }
        style(path)
        return path
    }

    private static func style(_ path: NSBezierPath) {
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }
}

/// Draws only the preserved outcome badges over the template glyph. Colours
/// are the design's placeholders: done `#30d158`, failed `#ff453a`.
final class OmniStatusBadgeView: NSView {
    var indicator: OmniStatusIndicator = .idle

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        switch indicator {
        case .idle:
            return
        case .running:
            return
        case .done:
            let size: CGFloat = 8
            let rect = NSRect(x: bounds.maxX - size - 1, y: 0, width: size, height: size)
            NSColor(srgbRed: 0x30 / 255, green: 0xd1 / 255, blue: 0x58 / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let check = NSBezierPath()
            check.lineWidth = 1.5
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: rect.minX + 2, y: rect.midY))
            check.line(to: NSPoint(x: rect.minX + 3.5, y: rect.minY + 2))
            check.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2.5))
            NSColor.white.setStroke()
            check.stroke()
        case .failed:
            let size: CGFloat = 6
            NSColor(srgbRed: 1, green: 0x45 / 255, blue: 0x3a / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - size - 1, y: 0, width: size, height: size)).fill()
        }
    }
}
