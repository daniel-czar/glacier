import AppKit
import OmniCore

/// Everything under the field, drawn by one view: the reference grid at a
/// common height (C118), or the dimensioned drawing over rows whose kind
/// cell is the row's ratio in miniature (C119).
@MainActor
public final class OmniRatioResultView: NSView {
    /// Every grid shape shares this height, so width is the comparison.
    public static let shapeHeight: CGFloat = 56
    public static let drawingMaximum = NSSize(width: 384, height: 200)
    public static let rowHeight: CGFloat = 36
    /// The miniature's box inside the 40 pt kind column.
    public static let miniature = NSSize(width: 30, height: 22)
    static let inset: CGFloat = 8
    static let cellPadding: CGFloat = 6

    public override var isFlipped: Bool { true }
    public private(set) var cellFrames: [NSRect] = []
    public private(set) var rowFrames: [NSRect] = []
    /// The drawn rectangle (not its labels), when there is one.
    public private(set) var drawingFrame: NSRect?
    public var onSelect: ((Int) -> Void)?
    public var onActivate: ((Int) -> Void)?
    private var result: RatioResult = .empty
    private var selectedIndex: Int?
    private var shapeFrames: [NSRect] = []

    private let cellLabelFont = NSFont.systemFont(ofSize: 11)
    private let dimensionFont = NSFont.systemFont(ofSize: 11.5)
    private let insideFont = NSFont.systemFont(ofSize: 20, weight: .medium)
    private let rowFont = NSFont.systemFont(ofSize: 14)
    private let qualifierFont = NSFont.systemFont(ofSize: 13)
    private let noteFont = NSFont.systemFont(ofSize: 12)

    public func display(result: RatioResult, selectedIndex: Int?) {
        self.result = result
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    /// Lays out at `width` and returns the content height: 14 pt above the
    /// first line and 12 pt below the last, as in the reference.
    @discardableResult
    public func arrange(width: CGFloat) -> CGFloat {
        cellFrames = []
        shapeFrames = []
        rowFrames = []
        drawingFrame = nil
        guard !result.grid.isEmpty || !result.rows.isEmpty else { return 0 }
        let inner = max(1, width - Self.inset * 2)
        var y: CGFloat = 14
        if !result.grid.isEmpty {
            var x: CGFloat = 0
            var lineTop = y
            let cellHeight = Self.cellPadding * 2 + Self.shapeHeight + 5 + 14
            for common in result.grid {
                let shapeWidth = (Self.shapeHeight * common.shape.decimal).rounded()
                let cellWidth = max(shapeWidth, label(for: common).size().width) + Self.cellPadding * 2
                if x > 0, x + cellWidth > inner {
                    x = 0
                    lineTop += cellHeight + 10
                }
                let cell = NSRect(x: Self.inset + x, y: lineTop, width: cellWidth, height: cellHeight)
                cellFrames.append(cell)
                shapeFrames.append(NSRect(x: cell.midX - shapeWidth / 2, y: cell.minY + Self.cellPadding,
                                          width: shapeWidth, height: Self.shapeHeight))
                x += cellWidth + 12
            }
            return lineTop + cellHeight + 12
        }
        if let drawing = result.drawing {
            let heightLabelWidth = dimension(drawing.heightLabel).size().width
            let room = NSSize(width: min(Self.drawingMaximum.width, max(24, inner - 2 * (heightLabelWidth + 10))),
                              height: Self.drawingMaximum.height)
            let scale = min(room.width / drawing.shape.width, room.height / drawing.shape.height)
            let size = NSSize(width: max(6, (drawing.shape.width * scale).rounded()),
                              height: max(6, (drawing.shape.height * scale).rounded()))
            y += 18
            drawingFrame = NSRect(x: ((width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
            y += size.height + 14
            if !insideFits(drawing, in: drawingFrame!) { y += 26 }
        }
        for _ in result.rows {
            rowFrames.append(NSRect(x: 0, y: y, width: width, height: Self.rowHeight))
            y += Self.rowHeight + 2
        }
        return y - 2 + 12
    }

    public override func draw(_ dirtyRect: NSRect) {
        for (index, cell) in cellFrames.enumerated() where result.grid.indices.contains(index) && cell.intersects(dirtyRect) {
            let selected = index == selectedIndex
            if selected {
                OmniFrostedStyle.selectedFill.setFill()
                NSBezierPath(roundedRect: cell, xRadius: 8, yRadius: 8).fill()
            }
            outline(shapeFrames[index], lineWidth: 1.5, radius: 2,
                    color: selected ? OmniFrostedStyle.accent : OmniFrostedStyle.ink.withAlphaComponent(0.8), fill: true)
            let text = label(for: result.grid[index])
            let size = text.size()
            text.draw(at: NSPoint(x: cell.midX - size.width / 2, y: shapeFrames[index].maxY + 5))
        }
        if let drawing = result.drawing, let frame = drawingFrame {
            drawDimensioned(drawing, in: frame)
        }
        for (index, rowFrame) in rowFrames.enumerated() where result.rows.indices.contains(index) && rowFrame.intersects(dirtyRect) {
            drawRow(result.rows[index], in: rowFrame, selected: index == selectedIndex)
        }
    }

    /// The cell in the next visual line up or down nearest this one's centre.
    public func verticalNeighbour(of index: Int, direction: Int) -> Int? {
        guard cellFrames.indices.contains(index), direction != 0 else { return nil }
        let current = cellFrames[index]
        let lines = Array(Set(cellFrames.map(\.minY))).sorted()
        guard let line = lines.firstIndex(of: current.minY), lines.indices.contains(line + direction) else { return nil }
        let target = lines[line + direction]
        return cellFrames.indices.filter { cellFrames[$0].minY == target }
            .min { abs(cellFrames[$0].midX - current.midX) < abs(cellFrames[$1].midX - current.midX) }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frames = result.grid.isEmpty ? rowFrames : cellFrames
        guard let index = frames.firstIndex(where: { $0.contains(point) }) else { return }
        if event.clickCount >= 2 { onActivate?(index) } else { onSelect?(index) }
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .list }
    public override func accessibilityLabel() -> String? {
        if let drawing = result.drawing {
            return "Drawing \(drawing.widthLabel) by \(drawing.heightLabel), \(drawing.ratioLabel). " + (result.summary(at: selectedIndex) ?? "")
        }
        return result.summary(at: selectedIndex) ?? "No ratio"
    }

    // MARK: Drawing

    private func label(for common: RatioCommon) -> NSAttributedString {
        let text = NSMutableAttributedString(string: common.label, attributes: [
            .font: cellLabelFont, .foregroundColor: OmniFrostedStyle.ink.withAlphaComponent(0.75),
        ])
        text.append(NSAttributedString(string: "  " + common.gridNote, attributes: [
            .font: cellLabelFont, .foregroundColor: OmniFrostedStyle.secondaryInk.withAlphaComponent(0.55),
        ]))
        return text
    }

    private func dimension(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: dimensionFont, .foregroundColor: OmniFrostedStyle.secondaryInk])
    }

    private func inside(_ drawing: RatioDrawing) -> NSAttributedString {
        NSAttributedString(string: drawing.ratioLabel, attributes: [
            .font: insideFont, .foregroundColor: OmniFrostedStyle.ink, .kern: 0.4,
        ])
    }

    private func insideFits(_ drawing: RatioDrawing, in frame: NSRect) -> Bool {
        let size = inside(drawing).size()
        return size.width + 16 <= frame.width && size.height + 8 <= frame.height
    }

    /// Like a sketch, never a filled card: hairline box, width centred above
    /// between two rules, height beside, the ratio inside.
    private func drawDimensioned(_ drawing: RatioDrawing, in frame: NSRect) {
        outline(frame, lineWidth: 1.5, radius: 2, color: OmniFrostedStyle.ink.withAlphaComponent(0.85), fill: true)
        let width = dimension(drawing.widthLabel)
        let widthSize = width.size()
        let labelY = frame.minY - 18
        width.draw(at: NSPoint(x: frame.midX - widthSize.width / 2, y: labelY))
        OmniFrostedStyle.controlLine.setFill()
        let ruleY = labelY + (widthSize.height / 2).rounded()
        let gap = widthSize.width / 2 + 6
        for rule in [NSRect(x: frame.minX, y: ruleY, width: max(0, frame.width / 2 - gap), height: 1),
                     NSRect(x: frame.midX + gap, y: ruleY, width: max(0, frame.width / 2 - gap), height: 1)] {
            rule.fill()
        }
        let height = dimension(drawing.heightLabel)
        height.draw(at: NSPoint(x: frame.maxX + 10, y: frame.midY - height.size().height / 2))
        let ratio = inside(drawing)
        let ratioSize = ratio.size()
        let fits = insideFits(drawing, in: frame)
        ratio.draw(at: NSPoint(x: frame.midX - ratioSize.width / 2,
                               y: fits ? frame.midY - ratioSize.height / 2 : frame.maxY + 6))
    }

    private func drawRow(_ row: RatioRow, in frame: NSRect, selected: Bool) {
        if selected {
            OmniFrostedStyle.selectedFill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        }
        let kind = NSRect(x: frame.minX + Self.inset, y: frame.midY - 12, width: 40, height: 24)
        let scale = min(Self.miniature.width / row.shape.width, Self.miniature.height / row.shape.height)
        let mini = NSSize(width: max(3, row.shape.width * scale), height: max(3, row.shape.height * scale))
        outline(NSRect(x: kind.midX - mini.width / 2, y: kind.midY - mini.height / 2, width: mini.width, height: mini.height),
                lineWidth: 1.2, radius: 1.5, color: OmniFrostedStyle.secondaryInk.withAlphaComponent(0.75), fill: false)
        var noteMinX = frame.maxX - Self.inset
        if let note = row.note {
            let text = NSAttributedString(string: note, attributes: [
                .font: noteFont, .foregroundColor: OmniFrostedStyle.secondaryInk.withAlphaComponent(0.6),
            ])
            let size = text.size()
            noteMinX -= size.width
            text.draw(at: NSPoint(x: noteMinX, y: frame.midY - size.height / 2))
        }
        let main = NSMutableAttributedString(string: row.text, attributes: [.font: rowFont, .foregroundColor: OmniFrostedStyle.ink])
        if let qualifier = row.qualifier {
            main.append(NSAttributedString(string: "  " + qualifier, attributes: [
                .font: qualifierFont, .foregroundColor: OmniFrostedStyle.secondaryInk.withAlphaComponent(0.7),
            ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        main.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: main.length))
        let textX = kind.maxX + 12
        let lineHeight = ceil(main.size().height)
        main.draw(with: NSRect(x: textX, y: frame.midY - lineHeight / 2, width: max(1, noteMinX - 12 - textX), height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func outline(_ rect: NSRect, lineWidth: CGFloat, radius: CGFloat, color: NSColor, fill: Bool) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), xRadius: radius, yRadius: radius)
        if fill {
            OmniFrostedStyle.controlFill.setFill()
            path.fill()
        }
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }
}

@MainActor
public final class OmniRatioViewController: NSViewController, NSTextViewDelegate {
    public static let preferredSize = NSSize(width: OmniPadPlacement.width, height: 106)
    public nonisolated static let placeholder = "16:9, 1200×628, 16:9 at 1200 wide, or a name"
    public nonisolated static let title = "Ratio"
    /// The emoji field already moves a selection on plain arrows and copies it on ⌘C.
    public let editor = OmniEmojiInputView()
    public let toolPill = OmniToolPillView(title: "Ratio")
    public let resultView = OmniRatioResultView()
    public let routeLabel = NSTextField(labelWithString: "")
    public let keyHintsView = OmniKeyHintsView()
    public let copyButton = OmniPadRunButton()
    public let session: OmniRatioSession
    public var onCloseRequested: (() -> Void)?
    /// Enter, the round button or a double-click: copy and close.
    public var onChooseRequested: (() -> Void)?
    public var onCopyRequested: (() -> Bool)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640

    private let inputScroll = NSScrollView()
    private let resultScroll = NSScrollView()
    private let resultDivider = OmniRatioHairline()
    private let footerDivider = OmniRatioHairline()
    private let resultFade = OmniPadResultFade()
    private var layoutInProgress = false
    private var lastScrolledIndex: Int?

    public init(session: OmniRatioSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = OmniFrostedSurface(frame: NSRect(origin: .zero, size: Self.preferredSize))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier("omni.ratio")
        view = root

        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 17)
        editor.textColor = OmniFrostedStyle.ink
        editor.insertionPointColor = OmniFrostedStyle.accent
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.placeholderString = Self.placeholder
        editor.delegate = self
        editor.onEscape = { [weak self] in self?.onCloseRequested?() }
        editor.onSubmit = { [weak self] in self?.onChooseRequested?() }
        editor.onMoveSelection = { [weak self] dx, dy in self?.moveSelection(columns: dx, rows: dy) ?? false }
        editor.onCopySelection = { [weak self] in self?.onCopyRequested?() ?? false }
        editor.setAccessibilityIdentifier("omni.ratio.input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = false
        inputScroll.borderType = .noBorder
        inputScroll.documentView = editor

        resultView.setAccessibilityIdentifier("omni.ratio.result")
        resultView.onSelect = { [weak self] index in
            self?.session.select(index)
            if let self { self.view.window?.makeFirstResponder(self.editor) }
        }
        resultView.onActivate = { [weak self] index in
            self?.session.select(index)
            self?.onChooseRequested?()
        }
        resultScroll.drawsBackground = false
        resultScroll.hasVerticalScroller = true
        resultScroll.scrollerStyle = .overlay
        resultScroll.borderType = .noBorder
        resultScroll.documentView = resultView
        resultScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resultScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: resultScroll.contentView)
        resultScroll.setAccessibilityIdentifier("omni.ratio.results")
        resultFade.setAccessibilityIdentifier("omni.ratio.result-fade")

        routeLabel.font = .systemFont(ofSize: 13)
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.setAccessibilityIdentifier("omni.ratio.route")
        copyButton.symbolName = "doc.on.doc"
        copyButton.setAccessibilityLabel("Copy and close")
        copyButton.toolTip = "Copy and close"
        copyButton.setAccessibilityIdentifier("omni.ratio.copy")
        copyButton.onPress = { [weak self] in self?.onChooseRequested?() }
        for child in [inputScroll, toolPill, footerDivider, routeLabel, keyHintsView, copyButton] as [NSView] {
            root.addSubview(child)
        }
        render()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutControls()
    }

    public func focusInput() {
        guard isViewLoaded, let window = view.window else { return }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    public func clearUndoHistory() { if isViewLoaded { editor.undoManager?.removeAllActions() } }

    /// The summary line as shown.
    public var routeText: String { routeLabel.stringValue }

    /// ←→ step through grid cells, ↑↓ change lines by position; on rows only
    /// ↑↓ move, so ←→ stay with the caret.
    @discardableResult
    public func moveSelection(columns dx: Int, rows dy: Int) -> Bool {
        let result = session.result
        guard result.itemCount > 0 else { return false }
        let current = session.selectedIndex ?? 0
        if !result.grid.isEmpty {
            if dx != 0 {
                session.select(max(0, min(result.grid.count - 1, current + dx)))
            } else if dy != 0 {
                if resultView.cellFrames.isEmpty { layoutControls() }
                session.select(resultView.verticalNeighbour(of: current, direction: dy) ?? current)
            }
            return true
        }
        guard dy != 0 else { return false }
        return session.moveSelection(by: dy)
    }

    public func render() {
        guard isViewLoaded else { return }
        if editor.string != session.input { editor.string = session.input }
        editor.needsDisplay = true
        resultView.display(result: session.result, selectedIndex: session.selectedIndex)
        let hasResults = session.result.itemCount > 0
        if !hasResults {
            resultScroll.removeFromSuperview()
            resultDivider.removeFromSuperview()
            resultFade.removeFromSuperview()
        } else if resultScroll.superview == nil {
            view.addSubview(resultDivider)
            view.addSubview(resultScroll)
            view.addSubview(resultFade)
        }
        routeLabel.attributedStringValue = Self.summaryLine(notice: session.notice, summary: session.summary, miss: session.isMiss)
        let canCopy = session.copyText != nil
        keyHintsView.hints = (canCopy ? [.init("↩", "Copy and close")] : []) + [.init("esc", "Close")]
        copyButton.isEnabled = canCopy
        copyButton.needsDisplay = true
        layoutControls()
    }

    /// The subject in medium weight, the rest secondary; a miss all dimmed.
    static func summaryLine(notice: String?, summary: String?, miss: Bool) -> NSAttributedString {
        if let notice {
            return NSAttributedString(string: notice, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: OmniFrostedStyle.warning,
            ])
        }
        guard let summary else { return NSAttributedString(string: "") }
        if miss {
            return NSAttributedString(string: summary, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk.withAlphaComponent(0.6),
            ])
        }
        let parts = summary.components(separatedBy: " · ")
        let line = NSMutableAttributedString(string: parts[0], attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: OmniFrostedStyle.ink.withAlphaComponent(0.9),
        ])
        if parts.count > 1 {
            line.append(NSAttributedString(string: " · " + parts.dropFirst().joined(separator: " · "), attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk,
            ]))
        }
        return line
    }

    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === editor else { return }
        session.inputChanged(editor.string)
    }

    private func layoutControls() {
        guard isViewLoaded, !layoutInProgress else { return }
        layoutInProgress = true
        defer { layoutInProgress = false }
        let width = view.bounds.width
        let contentWidth = max(1, width - 36)
        editor.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 25)
        OmniToolPillLayout.reserveFirstLine(beside: editor, pill: toolPill, fieldWidth: contentWidth)
        editor.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        let textHeight = editor.textContainer.map { editor.layoutManager?.usedRect(for: $0).height ?? 25 } ?? 25
        let fieldHeight = min(96, max(25, ceil(textHeight + 2)))
        let inputHeight = fieldHeight + 27
        let footerHeight: CGFloat = 54
        // Rows reach 8 pt past the text column on both sides, as in Recall.
        let resultWidth = max(1, width - 20)
        let bodyHeight = resultView.arrange(width: resultWidth)
        let resultBudget = max(0, maximumHeight - inputHeight - footerHeight)
        let resultHeight = min(440, resultBudget, bodyHeight)
        let height = inputHeight + resultHeight + footerHeight
        if abs(view.bounds.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        inputScroll.frame = NSRect(x: 18, y: height - 14 - fieldHeight, width: contentWidth, height: fieldHeight)
        editor.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(fieldHeight, textHeight))
        OmniToolPillLayout.place(toolPill, beside: editor, in: inputScroll.frame)
        let resultTop = height - inputHeight
        resultDivider.frame = NSRect(x: 0, y: resultTop, width: width, height: OmniFrostedStyle.hairlineWidth)
        resultScroll.frame = NSRect(x: 10, y: footerHeight + 1, width: resultWidth, height: max(0, resultHeight - 2))
        resultView.frame = NSRect(x: 0, y: 0, width: resultWidth, height: max(bodyHeight, resultScroll.contentSize.height))
        resultFade.frame = NSRect(x: 10, y: footerHeight + 1, width: resultWidth, height: 24)
        footerDivider.frame = NSRect(x: 0, y: footerHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        copyButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 76))
        keyHintsView.frame = NSRect(x: copyButton.frame.minX - 12 - hintWidth, y: 12, width: hintWidth, height: 30)
        routeLabel.frame = NSRect(x: 18, y: 19, width: max(1, keyHintsView.frame.minX - 30), height: 18)
        if let index = session.selectedIndex, index != lastScrolledIndex {
            let frames = session.result.grid.isEmpty ? resultView.rowFrames : resultView.cellFrames
            if frames.indices.contains(index) { resultView.scrollToVisible(frames[index].insetBy(dx: 0, dy: -8)) }
        }
        lastScrolledIndex = session.selectedIndex
        updateFade()
    }

    @objc private func resultScrolled(_ notification: Notification) { updateFade() }

    private func updateFade() {
        resultFade.isHidden = resultView.frame.height <= resultScroll.contentView.bounds.maxY + 13
    }
}

@MainActor private final class OmniRatioHairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.controlLine.setFill()
        bounds.fill()
    }
}

/// The disposable panel shared with the other ephemeral tools. The host owns
/// the clipboard and focus; this window only says what to copy.
@MainActor
public final class OmniRatioWindowController {
    public let session: OmniRatioSession
    public let viewController: OmniRatioViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    /// Writes the selection's copy text: on Enter (then the tool closes) and
    /// on ⌘C (it stays open).
    public var onCopy: ((String) -> Void)?
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?

    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }

    public init(session: OmniRatioSession, presentsInterface: Bool = true) {
        self.session = session
        viewController = OmniRatioViewController(session: session)
        self.presentsInterface = presentsInterface
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onChooseRequested = { [weak self] in self?.copySelectionAndClose() }
        viewController.onCopyRequested = { [weak self] in self?.copySelection() ?? false }
        viewController.onSizeChanged = { [weak self] size in self?.resize(to: size) }
    }

    public func show(input: String = "", reusing reusedPanel: NSPanel? = nil) {
        anchorFrame = reusedPanel?.frame
        session.open(input: input)
        viewController.loadViewIfNeeded()
        viewController.clearUndoHistory()
        let visibleFrame = reusedPanel?.screen?.visibleFrame ?? Self.targetVisibleFrame()
        let top = anchorFrame?.maxY ?? visibleFrame.maxY - visibleFrame.height * OmniPadPlacement.topFraction
        viewController.maximumHeight = max(160, top - visibleFrame.minY - 12)
        let width = min(OmniPadPlacement.width, max(1, visibleFrame.width - 24))
        viewController.view.setFrameSize(NSSize(width: width, height: viewController.view.frame.height))
        viewController.render()
        let size = viewController.view.frame.size
        let created = (reusedPanel as? OmniEphemeralPanel) ?? (panel as? OmniEphemeralPanel)
            ?? OmniEphemeralPanel(contentRect: OmniPadPlacement.frame(size: size, visibleFrame: visibleFrame),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        created.level = .floating
        created.hasShadow = true
        created.isOpaque = false
        created.backgroundColor = .clear
        created.collectionBehavior = [.moveToActiveSpace, .transient]
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.contentViewController = viewController
        created.initialFirstResponder = viewController.editor
        created.setAccessibilityIdentifier("omni.ratio.panel")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onFocusLost = { [weak self] in self?.requestFocusLoss() }
        created.onCopyRequested = nil
        created.onSubmitRequested = { [weak self] in self?.copySelectionAndClose() }
        created.onMoveExpressSelection = { [weak self] offset in
            self?.viewController.moveSelection(columns: 0, rows: offset) ?? false
        }
        panel = created
        if anchorFrame == nil { anchorFrame = OmniPadPlacement.frame(size: size, visibleFrame: visibleFrame) }
        resize(to: size)
        guard presentsInterface else { return }
        created.makeKeyAndOrderFront(nil)
        viewController.focusInput()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func relinquishPanelForReplacement() -> NSPanel? {
        let previous = panel
        if let previous = previous as? OmniEphemeralPanel {
            previous.onCloseRequested = nil
            previous.onFocusLost = nil
            previous.onCopyRequested = nil
            previous.onSubmitRequested = nil
            previous.onMoveExpressSelection = nil
        }
        panel = nil
        return previous
    }

    public func dismiss() {
        session.close()
        viewController.clearUndoHistory()
        panel?.orderOut(nil)
    }

    /// Enter: copy the selection and close; closing returns focus to the app
    /// the tool came from, so ⌘V pastes there.
    public func copySelectionAndClose() {
        guard copySelection() else { return }
        requestClose()
    }

    @discardableResult
    public func copySelection() -> Bool {
        guard let text = session.copyText, let onCopy else { return false }
        onCopy(text)
        return true
    }

    private func resize(to size: NSSize) {
        guard let panel, let anchorFrame else { return }
        panel.setFrame(NSRect(x: anchorFrame.midX - size.width / 2, y: anchorFrame.maxY - size.height,
                              width: size.width, height: size.height), display: true, animate: false)
    }

    private func requestClose() {
        if let onCloseRequested { onCloseRequested() } else { dismiss() }
    }

    private func requestFocusLoss() {
        guard session.isOpen else { return }
        if let onFocusLost { onFocusLost() } else { dismiss() }
    }

    private static func targetVisibleFrame() -> NSRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
