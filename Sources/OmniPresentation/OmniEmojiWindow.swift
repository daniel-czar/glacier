import AppKit
import OmniCore

/// The field keeps focus; plain arrows move the grid selection while there
/// are cells, and ⌘C with no text selected copies the selected emoji.
@MainActor
public final class OmniEmojiInputView: OmniEphemeralTextView {
    /// Columns and rows to move; false leaves the key to the text view.
    public var onMoveSelection: ((Int, Int) -> Bool)?
    /// Copies the selected emoji; false when there is none.
    public var onCopySelection: (() -> Bool)?
    public var onGenerate: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        if !hasMarkedText(), modifiers == .command && (event.keyCode == 36 || event.keyCode == 76) {
            onGenerate?()
            return
        }
        if !hasMarkedText(), modifiers.isEmpty {
            let move: (Int, Int)? = switch event.keyCode {
            case 123: (-1, 0)
            case 124: (1, 0)
            case 125: (0, 1)
            case 126: (0, -1)
            default: nil
            }
            if let move, onMoveSelection?(move.0, move.1) == true { return }
        }
        super.keyDown(with: event)
    }

    public override func copy(_ sender: Any?) {
        if selectedRange().length == 0, onCopySelection?() == true { return }
        super.copy(sender)
    }
}

/// Every cell drawn by one view: no labels under cells, the selected cell
/// filled with an accent inset ring, model picks below a hairline.
@MainActor
public final class OmniEmojiGridView: NSView {
    public static let cellHeight: CGFloat = 52
    public static let gap: CGFloat = 4
    public static let glyphSize: CGFloat = 28
    public static let sourceLabel = "Provider · suggested"

    public override var isFlipped: Bool { true }
    public private(set) var cellFrames: [NSRect] = []
    public private(set) var hairlineFrame: NSRect?
    public private(set) var sourceFrame: NSRect?
    public var onSelect: ((Int) -> Void)?
    public var onActivate: ((Int) -> Void)?
    private var localGlyphs: [String] = []
    private var suggestedGlyphs: [String] = []
    private var accessibilityNames: [String] = []
    private var accessibilityKind = "emoji"
    private var selectedIndex: Int?
    private let emojiFont = NSFont(name: "Apple Color Emoji", size: OmniEmojiGridView.glyphSize)
        ?? .systemFont(ofSize: OmniEmojiGridView.glyphSize)
    private let characterFont = NSFont.systemFont(ofSize: 26)
    private var usesCharacterFont = false
    private let sourceFont = NSFont.systemFont(ofSize: 12)

    public func display(local: [EmojiEntry], suggested: [EmojiEntry], selectedIndex: Int?, skinTone: OmniSkinTone = .none) {
        localGlyphs = local.map { skinTone.apply(to: $0.emoji) }
        suggestedGlyphs = suggested.map { skinTone.apply(to: $0.emoji) }
        accessibilityNames = (local + suggested).map(\.displayName)
        accessibilityKind = "emoji"
        usesCharacterFont = false
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    /// Characters reuse the same cell geometry, selection ring and hairline.
    public func displayCharacters(local: [CharacterEntry], suggested: [CharacterEntry], selectedIndex: Int?) {
        localGlyphs = local.map(\.displayGlyph)
        suggestedGlyphs = suggested.map(\.displayGlyph)
        accessibilityNames = (local + suggested).map(\.name)
        accessibilityKind = "characters"
        usesCharacterFont = true
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    /// Lays out cells at `width` and returns the content height, including
    /// the reference's 12 pt above the first row and 14 pt below the last.
    @discardableResult
    public func arrange(width: CGFloat) -> CGFloat {
        let columns = CGFloat(OmniEmojiSession.columns)
        let cellWidth = max(1, (width - Self.gap * (columns - 1)) / columns)
        var frames: [NSRect] = []
        guard !localGlyphs.isEmpty || !suggestedGlyphs.isEmpty else {
            cellFrames = []
            hairlineFrame = nil
            sourceFrame = nil
            return 0
        }
        var y: CGFloat = 12
        func place(_ count: Int) {
            for index in 0..<count {
                let column = CGFloat(index % OmniEmojiSession.columns)
                let row = CGFloat(index / OmniEmojiSession.columns)
                frames.append(NSRect(x: column * (cellWidth + Self.gap), y: y + row * (Self.cellHeight + Self.gap),
                                     width: cellWidth, height: Self.cellHeight))
            }
            let rows = CGFloat((count + OmniEmojiSession.columns - 1) / OmniEmojiSession.columns)
            y += rows * Self.cellHeight + max(0, rows - 1) * Self.gap
        }
        place(localGlyphs.count)
        hairlineFrame = nil
        sourceFrame = nil
        if !suggestedGlyphs.isEmpty {
            if !localGlyphs.isEmpty {
                y += 10
                hairlineFrame = NSRect(x: 0, y: y, width: width, height: OmniFrostedStyle.hairlineWidth)
                y += 12
            }
            place(suggestedGlyphs.count)
            y += 6
            sourceFrame = NSRect(x: 0, y: y, width: width, height: 15)
            y += 15
        }
        cellFrames = frames
        return y + 14
    }

    public override func draw(_ dirtyRect: NSRect) {
        let entries = localGlyphs + suggestedGlyphs
        for (index, frame) in cellFrames.enumerated() where entries.indices.contains(index) && frame.intersects(dirtyRect) {
            if index == selectedIndex {
                let path = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
                OmniFrostedStyle.selectedFill.setFill()
                path.fill()
                let ring = NSBezierPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75), xRadius: 7.25, yRadius: 7.25)
                ring.lineWidth = 1.5
                OmniFrostedStyle.accent.withAlphaComponent(0.9).setStroke()
                ring.stroke()
            }
            let attributes: [NSAttributedString.Key: Any] = usesCharacterFont
                ? [.font: characterFont, .foregroundColor: OmniFrostedStyle.ink]
                : [.font: emojiFont]
            let glyph = NSAttributedString(string: entries[index], attributes: attributes)
            let size = glyph.size()
            glyph.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        if let hairlineFrame {
            OmniFrostedStyle.controlLine.setFill()
            hairlineFrame.fill()
        }
        if let sourceFrame {
            (Self.sourceLabel as NSString).draw(in: sourceFrame, withAttributes: [
                .font: sourceFont, .foregroundColor: OmniFrostedStyle.secondaryInk.withAlphaComponent(0.6),
            ])
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = cellFrames.firstIndex(where: { $0.contains(point) }) else { return }
        if event.clickCount >= 2 { onActivate?(index) } else { onSelect?(index) }
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .list }
    public override func accessibilityLabel() -> String? {
        let entries = localGlyphs + suggestedGlyphs
        guard let selectedIndex, entries.indices.contains(selectedIndex) else { return "No \(accessibilityKind)" }
        return "\(entries.count) \(accessibilityKind), \(accessibilityNames[selectedIndex]) selected"
    }
}

@MainActor
public final class OmniEmojiViewController: NSViewController, NSTextViewDelegate {
    public static let preferredSize = NSSize(width: OmniPadPlacement.width, height: 106)
    public nonisolated static let placeholder = "Name, keyword or description"
    public nonisolated static let title = "Emoji"
    public let editor = OmniEmojiInputView()
    public let toolPill = OmniToolPillView(title: "Emoji")
    public let gridView = OmniEmojiGridView()
    public let routeLabel = NSTextField(labelWithString: "")
    public let keyHintsView = OmniKeyHintsView()
    public let copyButton = OmniPadRunButton()
    public let provenanceChip = OmniProvenanceChip()
    public let session: OmniEmojiSession
    public private(set) var provenance: OmniPadProvenance?
    public var onCloseRequested: (() -> Void)?
    /// Enter, the round button or a double-click: copy and close.
    public var onChooseRequested: (() -> Void)?
    public var onCopyRequested: (() -> Bool)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640

    private let inputScroll = NSScrollView()
    private let resultScroll = NSScrollView()
    private let resultDivider = OmniEmojiHairline()
    private let footerDivider = OmniEmojiHairline()
    private let resultFade = OmniPadResultFade()
    private var workingIndicator: OmniPadWorkingIndicator?
    private var layoutInProgress = false
    private var lastScrolledIndex: Int?

    public init(session: OmniEmojiSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = OmniFrostedSurface(frame: NSRect(origin: .zero, size: Self.preferredSize))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier("omni.emoji")
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
        editor.onSubmit = { [weak self] in self?.submitOrChoose() }
        editor.onMoveSelection = { [weak self] dx, dy in
            guard let self, !self.session.rows.isEmpty else { return false }
            self.session.moveSelection(columns: dx, rows: dy)
            return true
        }
        editor.onCopySelection = { [weak self] in self?.onCopyRequested?() ?? false }
        editor.onGenerate = { [weak self] in self?.session.suggestNow() }
        editor.setAccessibilityIdentifier("omni.emoji.input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = false
        inputScroll.borderType = .noBorder
        inputScroll.documentView = editor

        gridView.setAccessibilityIdentifier("omni.emoji.grid")
        gridView.onSelect = { [weak self] index in
            self?.session.select(index)
            if let self { self.view.window?.makeFirstResponder(self.editor) }
        }
        gridView.onActivate = { [weak self] index in
            self?.session.select(index)
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
        resultScroll.setAccessibilityIdentifier("omni.emoji.results")
        resultFade.setAccessibilityIdentifier("omni.emoji.result-fade")

        provenanceChip.setAccessibilityIdentifier("omni.emoji.provenance")
        provenanceChip.usesCompactLabel = true
        provenanceChip.onClear = { [weak self] in self?.setProvenance(nil) }
        routeLabel.font = .systemFont(ofSize: 13)
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.setAccessibilityIdentifier("omni.emoji.route")
        copyButton.symbolName = "doc.on.doc"
        copyButton.setAccessibilityLabel("Copy and close")
        copyButton.toolTip = "Copy and close"
        copyButton.setAccessibilityIdentifier("omni.emoji.copy")
        copyButton.onPress = { [weak self] in self?.submitOrChoose() }
        for child in [provenanceChip, inputScroll, toolPill, footerDivider, routeLabel, keyHintsView, copyButton] as [NSView] {
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
        gridView.display(local: session.localRows, suggested: session.suggestedRows, selectedIndex: session.selectedIndex,
                         skinTone: session.skinTone)
        let hasResults = !session.rows.isEmpty
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
        let canCopy = session.selectedEntry != nil
        let generate = !canCopy && session.canSuggestManually
        keyHintsView.hints = (generate ? [.init("↩", "Suggest")] : canCopy ? [.init("↩", "Copy and close")] : [])
            + (session.canSuggestManually ? [.init("⌘↩", "Suggest")] : [])
            + [.init("esc", "Close")]
        copyButton.isEnabled = canCopy || generate
        copyButton.symbolName = generate ? "sparkles" : "doc.on.doc"
        copyButton.setAccessibilityLabel(generate ? "Suggest emoji" : "Copy and close")
        copyButton.toolTip = generate ? "Suggest emoji from the current text" : "Copy and close"
        copyButton.needsDisplay = true
        if session.isSuggesting {
            if workingIndicator == nil {
                let indicator = OmniPadWorkingIndicator(frame: .zero)
                indicator.setAccessibilityIdentifier("omni.emoji.working")
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

    func submitOrChoose() {
        if session.selectedEntry == nil && session.canSuggestManually { session.suggestNow() }
        else { onChooseRequested?() }
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
        let bodyHeight = gridView.arrange(width: contentWidth)
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
        gridView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(bodyHeight, resultScroll.contentSize.height))
        resultFade.frame = NSRect(x: 18, y: footerHeight + 1, width: contentWidth, height: 24)
        footerDivider.frame = NSRect(x: 0, y: footerHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        copyButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 76))
        keyHintsView.frame = NSRect(x: copyButton.frame.minX - 12 - hintWidth, y: 12, width: hintWidth, height: 30)
        let routeX: CGFloat = workingIndicator == nil ? 18 : 42
        routeLabel.frame = NSRect(x: routeX, y: 19, width: max(1, keyHintsView.frame.minX - 12 - routeX), height: 18)
        workingIndicator?.frame = NSRect(x: 16, y: 19, width: 24, height: 18)
        if let index = session.selectedIndex, index != lastScrolledIndex, gridView.cellFrames.indices.contains(index) {
            gridView.scrollToVisible(gridView.cellFrames[index].insetBy(dx: 0, dy: -8))
        }
        lastScrolledIndex = session.selectedIndex
        updateFade()
    }

    @objc private func resultScrolled(_ notification: Notification) { updateFade() }

    private func updateFade() {
        resultFade.isHidden = gridView.frame.height <= resultScroll.contentView.bounds.maxY + 13
    }
}

@MainActor private final class OmniEmojiHairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.controlLine.setFill()
        bounds.fill()
    }
}

/// The disposable panel shared with the other ephemeral tools: switching tools
/// never leaves a second floating window. The host owns the clipboard and focus.
@MainActor
public final class OmniEmojiWindowController {
    public let session: OmniEmojiSession
    public let viewController: OmniEmojiViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    /// Writes the chosen emoji to the clipboard and counts the pick: on
    /// Enter (then the tool closes) and on ⌘C (it stays open).
    public var onCopy: ((EmojiEntry) -> Void)?
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?

    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }

    public init(session: OmniEmojiSession, presentsInterface: Bool = true) {
        self.session = session
        viewController = OmniEmojiViewController(session: session)
        self.presentsInterface = presentsInterface
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onChooseRequested = { [weak self] in self?.copySelectionAndClose() }
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
        created.setAccessibilityIdentifier("omni.emoji.panel")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onFocusLost = { [weak self] in self?.requestFocusLoss() }
        created.onCopyRequested = nil
        created.onSubmitRequested = { [weak self] in self?.viewController.submitOrChoose() }
        created.onMoveExpressSelection = { [weak self] offset in
            guard let self, !self.session.rows.isEmpty else { return false }
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

    /// Enter (quick-launch §2.4): copy the selection and close; closing
    /// returns focus to the app the tool came from, so ⌘V pastes there.
    public func copySelectionAndClose() {
        guard copySelection() else { return }
        requestClose()
    }

    @discardableResult
    public func copySelection() -> Bool {
        guard let entry = session.selectedEntry, let onCopy else { return false }
        onCopy(entry)
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
