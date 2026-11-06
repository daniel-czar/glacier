import AppKit

/// The resolved identity of a live tool. It stays outside the editable text and
/// lets pointer events reach the field beneath it.
@MainActor
public final class OmniToolPillView: NSView {
    public static let height: CGFloat = 22
    private static let horizontalInset: CGFloat = 9
    private static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    private weak var trackedEditor: NSTextView?
    private weak var observedClipView: NSClipView?
    private var trackedFieldWidth: CGFloat = 0
    private var trackedLineHeight: CGFloat = 25
    private var trackedGap: CGFloat = 10

    private let baseTitle: String
    public var shortcutLabel: String? {
        didSet {
            setAccessibilityLabel(title)
            needsDisplay = true
        }
    }
    public var title: String { baseTitle + (shortcutLabel.map { " · \($0)" } ?? "") }
    public var fittingWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: Self.labelFont]).width)
            + 2 * Self.horizontalInset
    }

    public init(title: String, shortcutLabel: String? = nil) {
        baseTitle = title
        self.shortcutLabel = shortcutLabel
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: Self.height))
        setAccessibilityIdentifier("omni.tool-pill")
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(self.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    public override func isAccessibilityElement() -> Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.mode.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
        let label = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: OmniFrostedStyle.mode,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: Self.horizontalInset, y: (bounds.height - size.height) / 2),
                   withAttributes: attributes)
    }

    fileprivate func trackVisibleInput(_ editor: NSTextView, fieldWidth: CGFloat,
                                       firstLineHeight: CGFloat, gap: CGFloat) {
        trackedEditor = editor
        trackedFieldWidth = fieldWidth
        trackedLineHeight = firstLineHeight
        trackedGap = gap
        guard let clipView = editor.enclosingScrollView?.contentView,
              observedClipView !== clipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                      object: observedClipView)
        }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(inputScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: clipView)
    }

    @objc private func inputScrolled(_ notification: Notification) {
        guard let trackedEditor else { return }
        OmniToolPillLayout.reserveFirstLine(beside: trackedEditor, pill: self,
            fieldWidth: trackedFieldWidth, firstLineHeight: trackedLineHeight, gap: trackedGap)
    }
}

/// Keeps the pill on the first input line while TextKit lays later lines under
/// it at full field width. `fieldFrame` is the input scroll view's frame in its
/// parent; the editor itself remains the full width of that scroll view.
@MainActor
public enum OmniToolPillLayout {
    public static func place(_ pill: OmniToolPillView, beside editor: NSTextView,
                             in fieldFrame: NSRect, firstLineHeight: CGFloat = 25,
                             gap: CGFloat = 10) {
        let pillWidth = pill.fittingWidth
        pill.frame = NSRect(x: fieldFrame.maxX - pillWidth,
                            y: fieldFrame.maxY - (firstLineHeight + OmniToolPillView.height) / 2,
                            width: pillWidth, height: OmniToolPillView.height)
        pill.trackVisibleInput(editor, fieldWidth: fieldFrame.width,
                               firstLineHeight: firstLineHeight, gap: gap)
        reserveFirstLine(beside: editor, pill: pill, fieldWidth: fieldFrame.width,
                         firstLineHeight: firstLineHeight, gap: gap)
    }

    /// Call before measuring TextKit's used rect, then call `place` after the
    /// input strip's final frame is known.
    public static func reserveFirstLine(beside editor: NSTextView, pill: OmniToolPillView,
                                        fieldWidth: CGFloat, firstLineHeight: CGFloat = 25,
                                        gap: CGFloat = 10) {
        let pillWidth = pill.fittingWidth
        let reservedWidth = min(pillWidth + gap, max(0, fieldWidth - 24))
        (editor as? OmniEphemeralTextView)?.firstLineReservedWidth = reservedWidth
        guard let container = editor.textContainer else { return }
        let lineHeight = editor.layoutManager?.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: 17))
            ?? firstLineHeight
        let visibleTop = max(0, editor.enclosingScrollView?.contentView.bounds.minY ?? 0)
        let exclusion = NSRect(x: fieldWidth - reservedWidth, y: visibleTop,
                               width: reservedWidth, height: min(firstLineHeight, lineHeight))
        if container.exclusionPaths.first?.bounds != exclusion || container.exclusionPaths.count != 1 {
            container.exclusionPaths = [NSBezierPath(rect: exclusion)]
        }
    }
}
