import AppKit
import OmniCore

@MainActor
public final class OmniRegexInputView: OmniEphemeralTextView {
    public var onMoveSelection: ((Int) -> Void)?
    public var onAddToSheet: (() -> Void)?
    public var onUndoAdd: (() -> Void)?
    public var onGenerate: (() -> Void)?

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleSheetKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    public override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else { super.keyDown(with: event); return }
        if handleSheetKey(event) { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command && (event.keyCode == 36 || event.keyCode == 76) {
            onGenerate?()
            return
        }
        if modifiers.subtracting([.numericPad, .function]).isEmpty, event.keyCode == 125 || event.keyCode == 126 {
            onMoveSelection?(event.keyCode == 125 ? 1 : -1)
            return
        }
        super.keyDown(with: event)
    }
    private func handleSheetKey(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(), event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        if event.charactersIgnoringModifiers?.lowercased() == "s" { onAddToSheet?(); return true }
        if event.charactersIgnoringModifiers?.lowercased() == "z", let onUndoAdd { onUndoAdd(); return true }
        return false
    }
}

@MainActor
public final class OmniRegexViewController: NSViewController, NSTextViewDelegate {
    public static let preferredSize = NSSize(width: OmniPadPlacement.width, height: 320)
    public let session: OmniRegexSession
    public let editor = OmniRegexInputView()
    public let toolPill = OmniToolPillView(title: "Regex")
    public let provenanceChip = OmniProvenanceChip()
    public private(set) var provenance: OmniPadProvenance?
    public let routeLabel = NSTextField(labelWithString: "")
    public let keyHintsView = OmniKeyHintsView()
    public let copyButton = OmniPadRunButton()
    public var onCloseRequested: (() -> Void)?
    public var onCopyRequested: (() -> Void)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640
    private let inputScroll = NSScrollView()
    private let resultScroll = NSScrollView()
    private let resultBody = OmniRegexFlippedView()
    private let resultDivider = OmniRegexHairline()
    private let footerDivider = OmniRegexHairline()
    private let resultFade = OmniPadResultFade()
    private var workingIndicator: OmniPadWorkingIndicator?
    private var bodyHeight: CGFloat = 0
    private var layoutInProgress = false

    public init(session: OmniRegexSession) { self.session = session; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        view = OmniFrostedSurface(frame: NSRect(origin: .zero, size: Self.preferredSize))
        view.autoresizingMask = [.width, .height]
        view.setAccessibilityIdentifier("omni.regex")
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
        editor.placeholderString = "A pattern to read, or what it should match"
        editor.delegate = self
        editor.onEscape = { [weak self] in self?.onCloseRequested?() }
        editor.onSubmit = { [weak self] in self?.submitOrCopy() }
        editor.onMoveSelection = { [weak self] in self?.session.moveSelection(by: $0) }
        editor.onAddToSheet = { [weak self] in _ = self?.session.addSelectedToSheet() }
        editor.onGenerate = { [weak self] in self?.session.generateNow() }
        editor.setAccessibilityIdentifier("omni.regex.input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.scrollerStyle = .overlay
        inputScroll.borderType = .noBorder
        inputScroll.documentView = editor
        provenanceChip.usesCompactLabel = true
        provenanceChip.setAccessibilityIdentifier("omni.regex.provenance")
        provenanceChip.onClear = { [weak self] in
            self?.provenance = nil
            self?.session.clearSelection()
            self?.focusInput(preservingSelection: true)
        }
        resultScroll.drawsBackground = false
        resultScroll.hasVerticalScroller = true
        resultScroll.scrollerStyle = .overlay
        resultScroll.borderType = .noBorder
        resultScroll.documentView = resultBody
        resultScroll.setAccessibilityIdentifier("omni.regex.results")
        resultScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resultScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: resultScroll.contentView)
        resultFade.setAccessibilityIdentifier("omni.regex.result-fade")
        routeLabel.font = .systemFont(ofSize: 13)
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.setAccessibilityIdentifier("omni.regex.route")
        copyButton.symbolName = "doc.on.doc"
        copyButton.toolTip = "Copy and close"
        copyButton.setAccessibilityLabel("Copy and close")
        copyButton.setAccessibilityIdentifier("omni.regex.copy")
        copyButton.onPress = { [weak self] in self?.submitOrCopy() }
        for child in [inputScroll, toolPill, provenanceChip, resultDivider, resultScroll, resultFade,
                      footerDivider, routeLabel, keyHintsView, copyButton] as [NSView] { view.addSubview(child) }
        render()
    }
    public override func viewDidLayout() { super.viewDidLayout(); layoutControls() }
    public func clearUndoHistory() { if isViewLoaded { editor.undoManager?.removeAllActions() } }
    public func focusInput(preservingSelection: Bool = false) {
        view.window?.makeFirstResponder(editor)
        if !preservingSelection { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
    }
    public func setProvenance(_ value: OmniPadProvenance?) { provenance = value; render() }
    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === editor else { return }
        session.inputChanged(editor.string)
    }
    public func render() {
        guard isViewLoaded else { return }
        if !session.isOpen { provenance = nil }
        if !editor.hasMarkedText() {
            if editor.string != session.input { editor.string = session.input }
            editor.font = session.inputIsPattern ? .monospacedSystemFont(ofSize: 15, weight: .regular) : .systemFont(ofSize: 17)
        }
        editor.onUndoAdd = session.canUndoAdd ? { [weak self] in _ = self?.session.undoAdd() } : nil
        editor.needsDisplay = true
        provenanceChip.provenance = provenance
        provenanceChip.isHidden = provenance == nil || session.selection == nil
        rebuildResults()
        let summary = NSMutableAttributedString(string: session.summary, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk,
        ])
        if session.failure != nil {
            summary.insert(NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.systemRed,
            ]), at: 0)
        }
        routeLabel.attributedStringValue = summary
        routeLabel.toolTip = session.failure ?? session.summary
        routeLabel.setAccessibilityLabel(session.failure.map { session.summary + ": " + $0 } ?? session.summary)
        let generate = session.selectedPattern == nil && session.canGenerateManually
        keyHintsView.hints = (generate ? [.init("↩", "Generate")] : session.selectedPattern == nil ? [] : [.init("↩", "Copy and close")])
            + (session.canGenerateManually ? [.init("⌘↩", "Generate")] : [])
            + (session.canAddSelected ? [.init("⌘S", "Add to sheet")] : []) + [.init("esc", "Close")]
        copyButton.isEnabled = (generate || session.selectedPattern != nil) && !editor.hasMarkedText()
        copyButton.symbolName = generate ? "sparkles" : "doc.on.doc"
        copyButton.setAccessibilityLabel(generate ? "Generate pattern" : "Copy and close")
        copyButton.toolTip = generate ? "Generate a pattern from the current text" : "Copy and close"
        copyButton.needsDisplay = true
        if session.isGenerating || session.isAnalyzing {
            if workingIndicator == nil {
                let indicator = OmniPadWorkingIndicator(frame: .zero)
                indicator.setAccessibilityIdentifier("omni.regex.working")
                view.addSubview(indicator)
                workingIndicator = indicator
            }
        } else { workingIndicator?.stop(); workingIndicator?.removeFromSuperview(); workingIndicator = nil }
        layoutControls()
    }

    func submitOrCopy() {
        if session.selectedPattern == nil && session.canGenerateManually { session.generateNow() }
        else { onCopyRequested?() }
    }
    private func rebuildResults() {
        resultBody.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 12
        let width: CGFloat = 604
        for (index, entry) in session.sheetRows.enumerated() {
            let row = OmniRegexRowView(name: entry.name, text: entry.pattern, trailing: "sheet", selected: session.selectedIndex == index)
            row.setAccessibilityIdentifier("omni.regex.sheet.\(index)")
            row.onSelect = { [weak self] in self?.session.select(index) }
            add(row, y: &y, height: 32, width: width)
        }
        if let generated = session.generated {
            if !session.sheetRows.isEmpty { y += 8 }
            let row = OmniRegexRowView(text: generated.pattern, trailing: "Provider · generated", selected: session.generatedIsSelected)
            row.setAccessibilityIdentifier("omni.regex.generated")
            row.onSelect = { [weak self] in guard let self else { return }; self.session.select(self.session.sheetRows.count) }
            add(row, y: &y, height: 34, width: width)
        }
        if let ast = session.analysis?.ast, session.analysis?.compileFailure == nil {
            let scene = OmniRegexRailroad.layout(ast)
            let diagram = OmniRegexRailroadView(scene: scene)
            diagram.setAccessibilityIdentifier("omni.regex.railroad")
            add(diagram, y: &y, height: scene.size.height, width: width)
        }
        if let matches = session.selectionMatches {
            let caption = matches.matchFailure == nil
                ? "On the selection · \(matches.matchingLineCount) of \(matches.totalLineCount) lines match"
                : "On the selection · matching incomplete"
            addCaption(caption, y: &y)
            for (index, line) in matches.lines.enumerated() {
                let row = OmniRegexRowView(text: line.text, trailing: line.captures.joined(separator: " · "),
                    kind: line.matched ? "✓" : "–", tint: line.matched ? .systemGreen : nil, highlights: line.matches.map(\.range))
                row.setAccessibilityIdentifier("omni.regex.match.\(index)")
                add(row, y: &y, height: 30, width: width)
            }
            if matches.totalLineCount > matches.lines.count {
                addCaption("\(matches.totalLineCount - matches.lines.count) more lines", y: &y)
            }
        }
        if let evaluation = session.exampleEvaluation {
            addCaption("The model's examples, run here", y: &y)
            for (index, example) in evaluation.examples.enumerated() {
                let failed = example.agreed == false
                let kind = example.doesMatch == nil ? "●" : (failed ? "✗" : (example.shouldMatch ? "✓" : "–"))
                let row = OmniRegexRowView(text: example.text, trailing: String(example.verdict.dropFirst(2)), kind: kind,
                    tint: failed || example.doesMatch == nil ? .systemRed : (example.shouldMatch ? .systemGreen : nil), boldVerdict: failed)
                row.setAccessibilityIdentifier("omni.regex.example.\(index)")
                add(row, y: &y, height: 30, width: width)
            }
            if let note = session.generated?.note, !note.isEmpty { addCaption(note, y: &y) }
        }
        if let failure = session.failure, session.analysis == nil || session.analysis?.compileFailure != nil {
            let label = NSTextField(wrappingLabelWithString: session.generated?.pattern ?? (session.isReadMode ? session.input : failure))
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.textColor = OmniFrostedStyle.ink
            label.toolTip = failure
            label.setAccessibilityIdentifier("omni.regex.failure")
            add(label, y: &y, height: 36, width: width)
        }
        bodyHeight = resultBody.subviews.isEmpty ? 0 : y + 10
    }
    private func add(_ child: NSView, y: inout CGFloat, height: CGFloat, width: CGFloat) {
        child.frame = NSRect(x: 0, y: y, width: width, height: height)
        resultBody.addSubview(child)
        y += height
    }
    private func addCaption(_ text: String, y: inout CGFloat) {
        y += 8
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = OmniFrostedStyle.secondaryInk
        add(label, y: &y, height: 22, width: 604)
    }
    private func layoutControls() {
        guard isViewLoaded, !layoutInProgress else { return }
        layoutInProgress = true
        defer { layoutInProgress = false }
        let width = view.bounds.width
        let contentWidth = max(1, width - 36)
        editor.frame.size.width = contentWidth
        editor.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        OmniToolPillLayout.reserveFirstLine(beside: editor, pill: toolPill, fieldWidth: contentWidth)
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        let textHeight = max(25, ceil(editor.textContainer.map { editor.layoutManager?.usedRect(for: $0).height ?? 25 } ?? 25) + 2)
        let chipHeight: CGFloat = provenanceChip.isHidden ? 0 : 38
        let fieldHeight = min(100, textHeight)
        let inputHeight = fieldHeight + 27 + chipHeight
        let narrow = routeLabel.intrinsicContentSize.width + keyHintsView.fittingWidth + 90 > width
        let footerHeight: CGFloat = narrow ? 78 : 54
        let resultHeight = min(440, max(0, maximumHeight - inputHeight - footerHeight), bodyHeight)
        let height = inputHeight + resultHeight + footerHeight
        if abs(view.bounds.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        provenanceChip.frame = NSRect(x: 16, y: height - 38, width: min(contentWidth, provenanceChip.fittingWidth), height: 26)
        inputScroll.frame = NSRect(x: 18, y: height - chipHeight - 14 - fieldHeight, width: contentWidth, height: fieldHeight)
        editor.frame.size = NSSize(width: contentWidth, height: max(fieldHeight, textHeight))
        OmniToolPillLayout.place(toolPill, beside: editor, in: inputScroll.frame)
        resultBody.frame = NSRect(x: 0, y: 0, width: max(604, contentWidth), height: bodyHeight)
        resultScroll.frame = NSRect(x: 18, y: footerHeight, width: contentWidth, height: resultHeight)
        resultScroll.hasHorizontalScroller = contentWidth < 604
        resultDivider.isHidden = bodyHeight == 0
        resultDivider.frame = NSRect(x: 0, y: height - inputHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        footerDivider.frame = NSRect(x: 0, y: footerHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        resultFade.frame = NSRect(x: 18, y: footerHeight, width: contentWidth, height: 24)
        copyButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 76))
        keyHintsView.frame = NSRect(x: copyButton.frame.minX - 12 - hintWidth, y: 12, width: hintWidth, height: 30)
        let routeX: CGFloat = workingIndicator == nil ? 18 : 42
        let routeY: CGFloat = narrow ? 51 : 19
        routeLabel.frame = NSRect(x: routeX, y: routeY, width: max(1, (narrow ? width - 18 : keyHintsView.frame.minX - 12) - routeX), height: 18)
        workingIndicator?.frame = NSRect(x: 16, y: routeY, width: 24, height: 18)
        updateFade()
    }
    @objc private func resultScrolled(_ notification: Notification) { updateFade() }
    private func updateFade() { resultFade.isHidden = bodyHeight <= resultScroll.contentView.bounds.maxY + 13 }
}

@MainActor private final class OmniRegexFlippedView: NSView { override var isFlipped: Bool { true } }
@MainActor private final class OmniRegexHairline: NSView {
    override func draw(_ dirtyRect: NSRect) { OmniFrostedStyle.controlLine.setFill(); bounds.fill() }
}

@MainActor private final class OmniRegexRowView: NSView {
    override var isFlipped: Bool { true }
    var onSelect: (() -> Void)?
    private let kindLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    init(name: String? = nil, text: String, trailing: String, selected: Bool = false,
         kind: String = "", tint: NSColor? = nil, highlights: [NSRange] = [], boldVerdict: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = selected ? OmniFrostedStyle.selectedFill.cgColor : NSColor.clear.cgColor
        kindLabel.stringValue = kind
        kindLabel.alignment = .center
        kindLabel.font = .systemFont(ofSize: 13)
        kindLabel.textColor = tint ?? OmniFrostedStyle.secondaryInk
        let value = NSMutableAttributedString(string: name.map { $0 + "  " } ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: OmniFrostedStyle.ink,
        ])
        let pattern = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: name == nil ? 13 : 12, weight: .regular),
            .foregroundColor: name == nil ? OmniFrostedStyle.ink : OmniFrostedStyle.secondaryInk,
        ])
        for range in highlights where range.location != NSNotFound && NSMaxRange(range) <= pattern.length {
            pattern.addAttribute(.backgroundColor, value: OmniFrostedStyle.accent.withAlphaComponent(0.3), range: range)
        }
        value.append(pattern)
        valueLabel.attributedStringValue = value
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.toolTip = text
        let detail = NSMutableAttributedString(string: trailing, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: boldVerdict ? NSColor.systemRed : OmniFrostedStyle.secondaryInk,
        ])
        if boldVerdict, let last = trailing.components(separatedBy: " · ").last {
            detail.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .bold),
                                range: NSRange(location: detail.length - (last as NSString).length, length: (last as NSString).length))
        }
        trailingLabel.attributedStringValue = detail
        trailingLabel.alignment = .right
        trailingLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.toolTip = trailing
        for child in [kindLabel, valueLabel, trailingLabel] { addSubview(child) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([kind, name, text, trailing].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func layout() {
        super.layout()
        let trailingWidth = min(bounds.width * 0.45, trailingLabel.intrinsicContentSize.width + 4)
        kindLabel.frame = NSRect(x: 0, y: 6, width: 24, height: 18)
        valueLabel.frame = NSRect(x: 36, y: 5, width: max(1, bounds.width - trailingWidth - 48), height: 20)
        trailingLabel.frame = NSRect(x: bounds.width - trailingWidth - 4, y: 6, width: trailingWidth, height: 18)
    }
}

/// Shares the H12 panel, so switching tools never leaves another floating window.
@MainActor
public final class OmniRegexWindowController {
    public let session: OmniRegexSession
    public let viewController: OmniRegexViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    public var onCopy: ((String) -> Void)?
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?
    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }
    public init(session: OmniRegexSession, presentsInterface: Bool = true) {
        self.session = session
        viewController = OmniRegexViewController(session: session)
        self.presentsInterface = presentsInterface
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onCopyRequested = { [weak self] in self?.copyCurrentSelection() }
        viewController.onSizeChanged = { [weak self] in self?.resize(to: $0) }
    }
    public func show(input: String = "", selection: String? = nil, provenance: OmniPadProvenance? = nil,
                     notice: String? = nil, reusing reusedPanel: NSPanel? = nil) {
        anchorFrame = reusedPanel?.frame
        session.open(input: input, selection: selection, notice: notice)
        viewController.loadViewIfNeeded()
        viewController.clearUndoHistory()
        viewController.setProvenance(provenance)
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
        created.setAccessibilityIdentifier("omni.regex.panel")
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
            previous.onCloseRequested = nil; previous.onFocusLost = nil
            previous.onCopyRequested = nil; previous.onSubmitRequested = nil
        }
        panel = nil
        return previous
    }
    public func dismiss() { session.close(); viewController.clearUndoHistory(); panel?.orderOut(nil) }
    public func copyCurrentSelection() {
        guard !viewController.editor.hasMarkedText(), let pattern = session.selectedPattern else { return }
        onCopy?(pattern)
        requestClose()
    }
    private func resize(to size: NSSize) {
        guard let panel, let anchorFrame else { return }
        panel.setFrame(NSRect(x: anchorFrame.midX - size.width / 2, y: anchorFrame.maxY - size.height,
                              width: size.width, height: size.height), display: true, animate: false)
    }
    private func requestClose() { if let onCloseRequested { onCloseRequested() } else { dismiss() } }
    private func requestFocusLoss() {
        guard session.isOpen else { return }
        if let onFocusLost { onFocusLost() } else { dismiss() }
    }
    private static func targetVisibleFrame() -> NSRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
