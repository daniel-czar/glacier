import AppKit
import OmniCore

@MainActor
public final class OmniRecallInputView: OmniEphemeralTextView {
    public var onMoveSelection: ((Int) -> Void)?
    public var onAddToSheet: (() -> Void)?
    public var onUndoAdd: (() -> Void)?
    public var onGenerate: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 125 && modifiers.subtracting([.numericPad, .function]).isEmpty {
            onMoveSelection?(1)
            return
        }
        if event.keyCode == 126 && modifiers.subtracting([.numericPad, .function]).isEmpty {
            onMoveSelection?(-1)
            return
        }
        if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "s" {
            onAddToSheet?()
            return
        }
        if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "z",
           onUndoAdd != nil {
            onUndoAdd?()
            return
        }
        if modifiers == .command && (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            onGenerate?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
public final class OmniRecallViewController: NSViewController, NSTextViewDelegate {
    public static let preferredSize = NSSize(width: OmniPadPlacement.width, height: 420)
    public let editor = OmniRecallInputView()
    public let toolPill = OmniToolPillView(title: "Recall")
    public let routeLabel = NSTextField(labelWithString: "")
    public let keyHintsView = OmniKeyHintsView()
    public let copyButton = OmniPadRunButton()
    public let session: OmniRecallSession
    public var onCloseRequested: (() -> Void)?
    public var onCopyRequested: (() -> Void)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640

    private let inputScroll = NSScrollView()
    private let resultScroll = NSScrollView()
    private let resultBody = OmniRecallFlippedView()
    private let resultDivider = OmniRecallHairline()
    private let footerDivider = OmniRecallHairline()
    private let resultFade = OmniPadResultFade()
    private var rowViews: [OmniRecallRowView] = []
    private var generatedDivider: OmniRecallHairline?
    private var workingIndicator: OmniPadWorkingIndicator?
    private var layoutInProgress = false

    public init(session: OmniRecallSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = OmniFrostedSurface(frame: NSRect(origin: .zero, size: Self.preferredSize))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier("omni.recall")
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
        editor.placeholderString = "What do you want to do?"
        editor.delegate = self
        editor.onEscape = { [weak self] in self?.onCloseRequested?() }
        editor.onSubmit = { [weak self] in self?.submitOrCopy() }
        editor.onMoveSelection = { [weak self] delta in self?.session.moveSelection(by: delta) }
        editor.onAddToSheet = { [weak self] in _ = self?.session.addSelectedToSheet() }
        editor.onGenerate = { [weak self] in self?.session.generateNow() }
        editor.setAccessibilityIdentifier("omni.recall.input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = false
        inputScroll.borderType = .noBorder
        inputScroll.documentView = editor

        resultScroll.drawsBackground = false
        resultScroll.hasVerticalScroller = true
        resultScroll.scrollerStyle = .overlay
        resultScroll.borderType = .noBorder
        resultScroll.documentView = resultBody
        resultScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resultScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: resultScroll.contentView)
        resultScroll.setAccessibilityIdentifier("omni.recall.results")
        resultFade.setAccessibilityIdentifier("omni.recall.result-fade")
        resultDivider.setAccessibilityIdentifier("omni.recall.result-divider")
        footerDivider.setAccessibilityIdentifier("omni.recall.footer-divider")

        routeLabel.font = .systemFont(ofSize: 13)
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.setAccessibilityIdentifier("omni.recall.route")
        copyButton.symbolName = "doc.on.doc"
        copyButton.setAccessibilityLabel("Copy and close")
        copyButton.toolTip = "Copy and close"
        copyButton.setAccessibilityIdentifier("omni.recall.copy")
        copyButton.onPress = { [weak self] in self?.submitOrCopy() }
        for child in [inputScroll, toolPill, resultDivider, resultScroll, resultFade,
                      footerDivider, routeLabel, keyHintsView, copyButton] as [NSView] {
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

    public func render() {
        guard isViewLoaded else { return }
        if editor.string != session.input { editor.string = session.input }
        editor.onUndoAdd = session.canUndoAdd ? { [weak self] in _ = self?.session.undoAdd() } : nil
        editor.needsDisplay = true
        rebuildRows()
        let count = session.commands.count
        let route = if let notice = session.notice {
            session.canUndoAdd ? "\(notice)   ⌘Z" : notice
        }
            else if let error = session.error { error }
            else if session.generatedRows.isEmpty { "Sheet · \(count) \(count == 1 ? "command" : "commands")" }
            else { "Sheet · Provider" }
        let emphasized = session.notice != nil || session.error != nil
        routeLabel.attributedStringValue = NSAttributedString(string: route, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: emphasized ? .medium : .regular),
            .foregroundColor: emphasized ? OmniFrostedStyle.warning : OmniFrostedStyle.secondaryInk
        ])
        let generate = session.selectedCommand == nil && session.canGenerateManually
        keyHintsView.hints = (generate ? [.init("↩", "Suggest")] : session.selectedRow == nil ? [] : [.init("↩", "Copy and close")])
            + (session.canGenerateManually ? [.init("⌘↩", "Suggest")] : [])
            + (session.canAddSelected ? [.init("⌘S", "Add to sheet")] : [])
            + [.init("esc", "Close")]
        copyButton.isEnabled = generate || session.selectedCommand != nil
        copyButton.symbolName = generate ? "sparkles" : "doc.on.doc"
        copyButton.setAccessibilityLabel(generate ? "Suggest a command" : "Copy and close")
        copyButton.toolTip = generate ? "Suggest commands from the current text" : "Copy and close"
        copyButton.needsDisplay = true
        if session.isGenerating {
            if workingIndicator == nil {
                let indicator = OmniPadWorkingIndicator(frame: .zero)
                indicator.setAccessibilityIdentifier("omni.recall.working")
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

    func submitOrCopy() {
        if session.selectedCommand == nil && session.canGenerateManually { session.generateNow() }
        else { onCopyRequested?() }
    }

    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === editor else { return }
        session.inputChanged(editor.string)
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        generatedDivider?.removeFromSuperview()
        generatedDivider = nil
        for (index, row) in session.rows.enumerated() {
            let rowView = OmniRecallRowView(row: row, selected: index == session.selectedIndex)
            rowView.setAccessibilityIdentifier("omni.recall.row.\(index)")
            rowView.onSelect = { [weak self] in self?.session.select(index) }
            resultBody.addSubview(rowView)
            rowViews.append(rowView)
        }
        if !session.generatedRows.isEmpty {
            let divider = OmniRecallHairline()
            divider.setAccessibilityIdentifier("omni.recall.generated-divider")
            resultBody.addSubview(divider)
            generatedDivider = divider
        }
    }

    private func layoutControls() {
        guard isViewLoaded, !layoutInProgress else { return }
        layoutInProgress = true
        defer { layoutInProgress = false }
        let width = view.bounds.width
        let contentWidth = max(1, width - 20)
        let rowHeight: CGFloat = 58
        let topInset: CGFloat = 10
        let bottomInset: CGFloat = 12
        let groupGap: CGFloat = session.generatedRows.isEmpty ? 0 : 18
        let bodyHeight = topInset + CGFloat(rowViews.count) * rowHeight + groupGap + bottomInset
        resultBody.frame = NSRect(x: 0, y: 0, width: contentWidth, height: bodyHeight)
        var cursor = topInset
        for (index, row) in rowViews.enumerated() {
            if index == session.sheetRows.count, let generatedDivider {
                generatedDivider.frame = NSRect(x: 0, y: cursor + 5, width: contentWidth,
                    height: OmniFrostedStyle.hairlineWidth)
                cursor += groupGap
            }
            row.frame = NSRect(x: 0, y: cursor, width: contentWidth, height: rowHeight)
            row.layoutContent()
            cursor += rowHeight
        }

        editor.frame = NSRect(x: 0, y: 0, width: max(1, width - 36), height: 25)
        OmniToolPillLayout.reserveFirstLine(beside: editor, pill: toolPill, fieldWidth: editor.frame.width)
        editor.textContainer?.containerSize = NSSize(width: editor.frame.width, height: .greatestFiniteMagnitude)
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        let textHeight = editor.textContainer.map { editor.layoutManager?.usedRect(for: $0).height ?? 25 } ?? 25
        let fieldHeight = min(96, max(25, ceil(textHeight + 2)))
        let inputHeight = fieldHeight + 27
        let narrow = routeLabel.intrinsicContentSize.width + keyHintsView.fittingWidth + 90 > width
        let footerHeight: CGFloat = narrow ? 70 : 54
        let resultBudget = max(0, maximumHeight - inputHeight - footerHeight)
        let resultHeight = min(372, resultBudget, bodyHeight)
        let height = inputHeight + resultHeight + footerHeight
        if abs(view.bounds.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        inputScroll.frame = NSRect(x: 18, y: height - 14 - fieldHeight, width: width - 36, height: fieldHeight)
        editor.frame = NSRect(x: 0, y: 0, width: inputScroll.frame.width, height: max(fieldHeight, textHeight))
        OmniToolPillLayout.place(toolPill, beside: editor, in: inputScroll.frame)
        resultDivider.frame = NSRect(x: 0, y: height - inputHeight,
            width: width, height: OmniFrostedStyle.hairlineWidth)
        resultScroll.frame = NSRect(x: 10, y: footerHeight, width: contentWidth, height: resultHeight)
        resultFade.frame = NSRect(x: 10, y: footerHeight, width: contentWidth, height: 24)
        footerDivider.frame = NSRect(x: 0, y: footerHeight,
            width: width, height: OmniFrostedStyle.hairlineWidth)
        copyButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 76))
        keyHintsView.frame = NSRect(x: copyButton.frame.minX - 12 - hintWidth, y: 12,
                                    width: hintWidth, height: 30)
        let routeY: CGFloat = narrow ? 51 : 19
        let routeX: CGFloat = workingIndicator == nil ? 18 : 42
        routeLabel.frame = NSRect(x: routeX, y: routeY,
            width: max(1, (narrow ? width - 18 : keyHintsView.frame.minX - 12) - routeX), height: 18)
        workingIndicator?.frame = NSRect(x: 16, y: routeY, width: 24, height: 18)
        if let selectedIndex = session.selectedIndex, rowViews.indices.contains(selectedIndex),
           resultHeight > 0 {
            resultScroll.contentView.scrollToVisible(rowViews[selectedIndex].frame)
        }
        updateFade()
    }

    @objc private func resultScrolled(_ notification: Notification) { updateFade() }

    private func updateFade() {
        resultFade.isHidden = resultBody.frame.height <= resultScroll.contentView.bounds.maxY + 13
    }
}

@MainActor private final class OmniRecallFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class OmniRecallHairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.controlLine.setFill()
        bounds.fill()
    }
}

@MainActor private final class OmniRecallRowView: NSView {
    override var isFlipped: Bool { true }
    let row: OmniRecallRow
    let category = NSTextField(labelWithString: "")
    let command = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let source = NSTextField(labelWithString: "")
    var onSelect: (() -> Void)?

    init(row: OmniRecallRow, selected: Bool) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = selected ? OmniFrostedStyle.selectedFill.cgColor : NSColor.clear.cgColor
        category.stringValue = row.origin == .sheet ? row.command.category.uppercased() : ""
        category.font = .systemFont(ofSize: 10.5, weight: .semibold)
        category.textColor = OmniFrostedStyle.secondaryInk.withAlphaComponent(0.72)
        category.lineBreakMode = .byTruncatingTail
        command.attributedStringValue = Self.commandText(row.command.command)
        command.lineBreakMode = .byTruncatingTail
        detail.attributedStringValue = Self.detailText(row.command)
        detail.lineBreakMode = .byTruncatingTail
        source.stringValue = row.origin == .generated ? "Provider · generated" : ""
        source.font = .systemFont(ofSize: 11)
        source.textColor = OmniFrostedStyle.secondaryInk.withAlphaComponent(0.7)
        source.alignment = .right
        for child in [category, command, detail, source] { addSubview(child) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(row.command.category), \(row.command.command), \(row.command.label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    func layoutContent() {
        let textX: CGFloat = 112
        category.frame = NSRect(x: 8, y: 8, width: 92, height: 16)
        command.frame = NSRect(x: textX, y: 7, width: max(1, bounds.width - textX - 8), height: 20)
        let sourceWidth: CGFloat = row.origin == .generated ? 132 : 0
        detail.frame = NSRect(x: textX, y: 31,
            width: max(1, bounds.width - textX - sourceWidth - 12), height: 17)
        source.frame = NSRect(x: bounds.width - sourceWidth - 8, y: 31,
            width: sourceWidth, height: 17)
    }

    private static func commandText(_ value: String) -> NSAttributedString {
        let base = NSMutableAttributedString(string: value, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14.5, weight: .regular),
            .foregroundColor: OmniFrostedStyle.ink
        ])
        let pattern = try? NSRegularExpression(pattern: "<[^<>]+>")
        for match in pattern?.matches(in: value, range: NSRange(value.startIndex..., in: value)) ?? [] {
            base.addAttribute(.foregroundColor, value: OmniFrostedStyle.secondaryInk, range: match.range)
        }
        return base
    }

    private static func detailText(_ value: RecallCommand) -> NSAttributedString {
        let text = NSMutableAttributedString(string: value.label, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: OmniFrostedStyle.secondaryInk
        ])
        if value.destructive {
            text.insert(NSAttributedString(string: "destructive   ", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: OmniFrostedStyle.warning
            ]), at: 0)
        }
        if !value.note.isEmpty {
            text.append(NSAttributedString(string: "   \(value.note)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: OmniFrostedStyle.secondaryInk.withAlphaComponent(0.75)
            ]))
        }
        return text
    }
}

/// Uses the same disposable panel as other ephemeral tools so switching does
/// not leave a second floating window or alter the host's focus policy.
@MainActor
public final class OmniRecallWindowController {
    public let session: OmniRecallSession
    public let viewController: OmniRecallViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    public var onCopy: ((String) -> Void)?
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?

    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }

    public init(session: OmniRecallSession, presentsInterface: Bool = true) {
        self.session = session
        viewController = OmniRecallViewController(session: session)
        self.presentsInterface = presentsInterface
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onCopyRequested = { [weak self] in self?.copyCurrentSelection() }
        viewController.onSizeChanged = { [weak self] size in self?.resize(to: size) }
    }

    public func show(input: String = "", notice: String? = nil, reusing reusedPanel: NSPanel? = nil) {
        anchorFrame = reusedPanel?.frame
        session.open(input: input, notice: notice)
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
        created.setAccessibilityIdentifier("omni.recall.panel")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onFocusLost = { [weak self] in self?.requestFocusLoss() }
        created.onCopyRequested = { [weak self] in self?.copyCurrentSelection() }
        created.onSubmitRequested = { [weak self] in self?.viewController.submitOrCopy() }
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
        }
        panel = nil
        return previous
    }

    public func dismiss() {
        session.close()
        viewController.clearUndoHistory()
        panel?.orderOut(nil)
    }

    public func copyCurrentSelection() {
        guard let command = session.selectedCommand else { return }
        onCopy?(command)
        requestClose()
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
