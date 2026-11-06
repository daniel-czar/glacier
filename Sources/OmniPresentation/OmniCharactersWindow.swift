import AppKit
import OmniCore

@MainActor
public final class OmniCharactersViewController: NSViewController, NSTextViewDelegate {
    public static let preferredSize = NSSize(width: OmniPadPlacement.width, height: 106)
    public nonisolated static let placeholder = "Name, glyph or code point"
    public nonisolated static let title = "Characters"
    public let editor = OmniEmojiInputView()
    public let toolPill = OmniToolPillView(title: "Characters")
    public let gridView = OmniEmojiGridView()
    public let identifyView = OmniCharacterIdentifyView()
    public let routeLabel = NSTextField(labelWithString: "")
    public let keyHintsView = OmniKeyHintsView()
    public let insertButton = OmniPadRunButton()
    public let provenanceChip = OmniProvenanceChip()
    public let session: OmniCharactersSession
    public private(set) var provenance: OmniPadProvenance?
    public var onCloseRequested: (() -> Void)?
    /// Enter, the round button or a double-click: insert and close.
    public var onChooseRequested: (() -> Void)?
    public var onCopyRequested: (() -> Bool)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640

    private let inputScroll = NSScrollView()
    private let resultScroll = NSScrollView()
    private let resultDivider = OmniCharactersHairline()
    private let footerDivider = OmniCharactersHairline()
    private let resultFade = OmniPadResultFade()
    private var workingIndicator: OmniPadWorkingIndicator?
    private var layoutInProgress = false
    private var lastScrolledIndex: Int?
    private var lastScrolledRepresentationIndex: Int?

    public init(session: OmniCharactersSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = OmniFrostedSurface(frame: NSRect(origin: .zero, size: Self.preferredSize))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier("omni.characters")
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
        editor.onMoveSelection = { [weak self] dx, dy in
            guard let self, (self.session.identifiedEntry != nil || !self.session.rows.isEmpty) else { return false }
            if self.session.identifiedEntry != nil && dx != 0 { return false }
            self.session.moveSelection(columns: dx, rows: dy)
            return true
        }
        editor.onCopySelection = { [weak self] in self?.onCopyRequested?() ?? false }
        editor.setAccessibilityIdentifier("omni.characters.input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = false
        inputScroll.borderType = .noBorder
        inputScroll.documentView = editor

        gridView.setAccessibilityIdentifier("omni.characters.grid")
        gridView.onSelect = { [weak self] index in
            self?.session.select(index)
            if let self { self.view.window?.makeFirstResponder(self.editor) }
        }
        gridView.onActivate = { [weak self] index in
            self?.session.select(index)
            self?.onChooseRequested?()
        }
        identifyView.setAccessibilityIdentifier("omni.characters.identify")
        identifyView.onSelect = { [weak self] index in
            self?.session.selectRepresentation(index)
            if let self { self.view.window?.makeFirstResponder(self.editor) }
        }
        identifyView.onActivate = { [weak self] index in
            self?.session.selectRepresentation(index)
            self?.onChooseRequested?()
        }
        resultScroll.drawsBackground = false
        resultScroll.hasVerticalScroller = true
        resultScroll.scrollerStyle = .overlay
        resultScroll.borderType = .noBorder
        resultScroll.documentView = gridView
        resultScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resultScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: resultScroll.contentView)
        resultScroll.setAccessibilityIdentifier("omni.characters.results")
        resultFade.setAccessibilityIdentifier("omni.characters.result-fade")

        provenanceChip.setAccessibilityIdentifier("omni.characters.provenance")
        provenanceChip.usesCompactLabel = true
        provenanceChip.onClear = { [weak self] in self?.setProvenance(nil) }
        routeLabel.font = .systemFont(ofSize: 13)
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.setAccessibilityIdentifier("omni.characters.route")
        insertButton.symbolName = "return"
        insertButton.setAccessibilityLabel("Insert and close")
        insertButton.toolTip = "Insert and close"
        insertButton.setAccessibilityIdentifier("omni.characters.insert")
        insertButton.onPress = { [weak self] in self?.onChooseRequested?() }
        for child in [provenanceChip, inputScroll, toolPill, footerDivider, routeLabel, keyHintsView, insertButton] as [NSView] {
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

    public func setProvenance(_ value: OmniPadProvenance?) {
        provenance = value
        if isViewLoaded { render() }
    }

    /// The selected name and optional suggestion source, or a notice.
    public var routeText: String { routeLabel.stringValue }

    public func render() {
        guard isViewLoaded else { return }
        if !session.isOpen { provenance = nil }
        if editor.string != session.input { editor.string = session.input }
        editor.needsDisplay = true
        provenanceChip.provenance = provenance
        provenanceChip.isHidden = provenance == nil
        gridView.displayCharacters(local: session.localRows, suggested: session.suggestedRows, selectedIndex: session.selectedIndex)
        identifyView.display(entry: session.identifiedEntry, representations: session.representations,
                             selectedIndex: session.selectedRepresentationIndex)
        let resultDocument: NSView = session.identifiedEntry == nil ? gridView : identifyView
        if resultScroll.documentView !== resultDocument { resultScroll.documentView = resultDocument }
        let hasResults = !session.rows.isEmpty || session.identifiedEntry != nil
        if !hasResults {
            resultScroll.removeFromSuperview()
            resultDivider.removeFromSuperview()
            resultFade.removeFromSuperview()
        } else if resultScroll.superview == nil {
            view.addSubview(resultDivider)
            view.addSubview(resultScroll)
            view.addSubview(resultFade)
        }
        let warning = session.notice ?? session.error
        routeLabel.attributedStringValue = NSAttributedString(string: warning ?? session.routeDetail ?? "",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: warning == nil ? .regular : .medium),
                         .foregroundColor: warning == nil ? OmniFrostedStyle.secondaryInk : OmniFrostedStyle.warning])
        let canCopy = session.selectedText != nil
        keyHintsView.hints = (canCopy ? [.init("↩", "Insert and close")] : []) + [.init("esc", "Close")]
        insertButton.isEnabled = canCopy
        insertButton.needsDisplay = true
        if session.isSuggesting {
            if workingIndicator == nil {
                let indicator = OmniPadWorkingIndicator(frame: .zero)
                indicator.setAccessibilityIdentifier("omni.characters.working")
                view.addSubview(indicator)
                workingIndicator = indicator
            }
        } else {
            workingIndicator?.stop()
            workingIndicator?.removeFromSuperview()
            workingIndicator = nil
        }
        layoutControls()
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
        let chipHeight: CGFloat = provenance == nil ? 0 : 38
        editor.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 25)
        OmniToolPillLayout.reserveFirstLine(beside: editor, pill: toolPill, fieldWidth: contentWidth)
        editor.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        let textHeight = editor.textContainer.map { editor.layoutManager?.usedRect(for: $0).height ?? 25 } ?? 25
        let fieldHeight = min(96, max(25, ceil(textHeight + 2)))
        let inputHeight = fieldHeight + 27
        let footerHeight: CGFloat = 54
        let bodyHeight = session.identifiedEntry == nil
            ? gridView.arrange(width: contentWidth)
            : identifyView.arrange(width: contentWidth)
        let resultBudget = max(0, maximumHeight - chipHeight - inputHeight - footerHeight)
        let resultHeight = min(372, resultBudget, bodyHeight)
        let height = chipHeight + inputHeight + resultHeight + footerHeight
        if abs(view.bounds.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        provenanceChip.frame = NSRect(x: 16, y: height - 38, width: min(max(1, width - 124), provenanceChip.fittingWidth), height: 26)
        inputScroll.frame = NSRect(x: 18, y: height - chipHeight - 14 - fieldHeight,
                                   width: contentWidth, height: fieldHeight)
        editor.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(fieldHeight, textHeight))
        OmniToolPillLayout.place(toolPill, beside: editor, in: inputScroll.frame)
        let resultTop = height - chipHeight - inputHeight
        resultDivider.frame = NSRect(x: 0, y: resultTop, width: width, height: OmniFrostedStyle.hairlineWidth)
        resultScroll.frame = NSRect(x: 18, y: footerHeight + 1, width: contentWidth, height: max(0, resultHeight - 2))
        let document = resultScroll.documentView
        document?.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(bodyHeight, resultScroll.contentSize.height))
        resultFade.frame = NSRect(x: 18, y: footerHeight + 1, width: contentWidth, height: 24)
        footerDivider.frame = NSRect(x: 0, y: footerHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        insertButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 76))
        keyHintsView.frame = NSRect(x: insertButton.frame.minX - 12 - hintWidth, y: 12, width: hintWidth, height: 30)
        let routeX: CGFloat = workingIndicator == nil ? 18 : 42
        routeLabel.frame = NSRect(x: routeX, y: 19, width: max(1, keyHintsView.frame.minX - 12 - routeX), height: 18)
        workingIndicator?.frame = NSRect(x: 16, y: 19, width: 24, height: 18)
        if session.identifiedEntry != nil, lastScrolledRepresentationIndex != session.selectedRepresentationIndex,
           identifyView.rowFrames.indices.contains(session.selectedRepresentationIndex) {
            identifyView.scrollToVisible(identifyView.rowFrames[session.selectedRepresentationIndex].insetBy(dx: 0, dy: -6))
        }
        lastScrolledRepresentationIndex = session.identifiedEntry == nil ? nil : session.selectedRepresentationIndex
        if let index = session.selectedIndex, index != lastScrolledIndex, gridView.cellFrames.indices.contains(index) {
            gridView.scrollToVisible(gridView.cellFrames[index].insetBy(dx: 0, dy: -8))
        }
        lastScrolledIndex = session.selectedIndex
        updateFade()
    }

    @objc private func resultScrolled(_ notification: Notification) { updateFade() }

    private func updateFade() {
        resultFade.isHidden = (resultScroll.documentView?.frame.height ?? 0) <= resultScroll.contentView.bounds.maxY + 13
    }
}

/// Identify's large glyph and selectable representation rows. The panel keeps
/// the input editor focused; mouse selection changes only the active row.
@MainActor
public final class OmniCharacterIdentifyView: NSView {
    public override var isFlipped: Bool { true }
    public private(set) var rowFrames: [NSRect] = []
    public var onSelect: ((Int) -> Void)?
    public var onActivate: ((Int) -> Void)?
    private var entry: CharacterEntry?
    private var representations: [CharacterRepresentation] = []
    private var selectedIndex = 0
    private let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private let valueFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

    public func display(entry: CharacterEntry?, representations: [CharacterRepresentation], selectedIndex: Int) {
        self.entry = entry
        if entry == nil { rowFrames = [] }
        self.representations = representations
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    @discardableResult
    public func arrange(width: CGFloat) -> CGFloat {
        guard entry != nil else { rowFrames = []; return 0 }
        rowFrames = representations.indices.map { index in
            NSRect(x: 0, y: 104 + CGFloat(index) * 36, width: width, height: 34)
        }
        return 104 + CGFloat(representations.count) * 36 + 14
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }
        let big = NSRect(x: 0, y: 12, width: 72, height: 72)
        OmniFrostedStyle.selectedFill.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: big, xRadius: 12, yRadius: 12).fill()
        drawText(entry.displayGlyph, in: big, font: .systemFont(ofSize: 44),
                 color: OmniFrostedStyle.ink, alignment: .center)
        let textWidth = max(1, bounds.width - 90)
        drawText(entry.name, in: NSRect(x: 90, y: 24, width: textWidth, height: 24),
                 font: .systemFont(ofSize: 17, weight: .medium), color: OmniFrostedStyle.ink)
        drawText("\(entry.block) · \(entry.category) · since Unicode \(entry.since)",
                 in: NSRect(x: 90, y: 52, width: textWidth, height: 20),
                 font: .systemFont(ofSize: 12.5), color: OmniFrostedStyle.secondaryInk)
        for (index, row) in representations.enumerated() where rowFrames.indices.contains(index) {
            let frame = rowFrames[index].insetBy(dx: 8, dy: 0)
            if index == selectedIndex {
                OmniFrostedStyle.selectedFill.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            }
            let labelRect = NSRect(x: frame.minX + 8, y: frame.minY + 10, width: 112, height: 16)
            drawText(row.label.uppercased(), in: labelRect, font: labelFont,
                     color: OmniFrostedStyle.secondaryInk)
            let valueRect = NSRect(x: frame.minX + 132, y: frame.minY + 8,
                                   width: max(1, frame.width - 140), height: 20)
            drawText(row.displayText, in: valueRect, font: valueFont, color: OmniFrostedStyle.ink)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowFrames.firstIndex(where: { $0.contains(point) }) else { return }
        if event.clickCount >= 2 { onActivate?(index) } else { onSelect?(index) }
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .list }
    public override func accessibilityLabel() -> String? {
        guard let entry, representations.indices.contains(selectedIndex) else { return "No character" }
        return "\(entry.name), \(representations[selectedIndex].label) selected"
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                          alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color,
                                                            .paragraphStyle: style])
    }
}

@MainActor private final class OmniCharactersHairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.controlLine.setFill()
        bounds.fill()
    }
}

/// The disposable panel shared with the other ephemeral tools: switching tools
/// never leaves a second floating window. The host owns the clipboard and focus.
@MainActor
public final class OmniCharactersWindowController {
    public let session: OmniCharactersSession
    public let viewController: OmniCharactersViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    /// Host-owned insertion and copy actions. The panel never writes the clipboard.
    public var onInsert: ((CharacterEntry, String) -> Void)?
    public var onCopy: ((CharacterEntry, String) -> Void)?
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?

    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }

    public init(session: OmniCharactersSession, presentsInterface: Bool = true) {
        self.session = session
        viewController = OmniCharactersViewController(session: session)
        self.presentsInterface = presentsInterface
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onChooseRequested = { [weak self] in self?.insertSelectionAndClose() }
        viewController.onCopyRequested = { [weak self] in self?.copySelection() ?? false }
        viewController.onSizeChanged = { [weak self] size in self?.resize(to: size) }
    }

    public func show(input: String = "", notice: String? = nil, provenance: OmniPadProvenance? = nil, reusing reusedPanel: NSPanel? = nil) {
        anchorFrame = reusedPanel?.frame
        session.open(input: input, notice: notice)
        viewController.loadViewIfNeeded()
        viewController.setProvenance(provenance)
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
        created.setAccessibilityIdentifier("omni.characters.panel")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onFocusLost = { [weak self] in self?.requestFocusLoss() }
        created.onCopyRequested = nil
        created.onSubmitRequested = { [weak self] in self?.insertSelectionAndClose() }
        created.onMoveExpressSelection = { [weak self] offset in
            guard let self, (self.session.identifiedEntry != nil || !self.session.rows.isEmpty) else { return false }
            self.session.moveSelection(columns: 0, rows: offset)
            return true
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

    /// The host owns the async insert chain and closes after its outcome.
    public func insertSelectionAndClose() {
        guard let entry = session.selectedEntry, let text = session.selectedText, let onInsert else { return }
        onInsert(entry, text)
    }

    /// Prevent focus-loss dismissal while the host returns to the target app.
    public func hideForInsert() {
        if let panel = panel as? OmniEphemeralPanel {
            panel.onFocusLost = nil
            panel.onCloseRequested = nil
        }
        panel?.orderOut(nil)
    }

    @discardableResult
    public func copySelection() -> Bool {
        guard let entry = session.selectedEntry, let text = session.selectedText, let onCopy else { return false }
        onCopy(entry, text)
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
