import AppKit

@MainActor
public final class OmniWeatherResultView: NSView {
    public override var isFlipped: Bool { true }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public var onSelect: ((Int) -> Void)?
    public private(set) var rowFrames: [NSRect] = []
    private var display: WeatherDisplay?
    private var candidates: [WeatherPlace] = []
    private var selectedIndex = 0

    public func show(display: WeatherDisplay?, candidates: [WeatherPlace], selectedIndex: Int, dimmed: Bool) {
        self.display = display
        self.candidates = candidates
        self.selectedIndex = selectedIndex
        alphaValue = dimmed ? 0.45 : 1
        needsDisplay = true
        setAccessibilityLabel(candidates.isEmpty ? display.map { "\($0.temperature), \($0.condition). " + $0.facts.map(\.firstLine).joined(separator: ". ") } : candidates.map(\.candidateLabel).joined(separator: ". "))
    }

    public var contentHeight: CGFloat {
        if !candidates.isEmpty { return CGFloat(candidates.count) * 38 + 16 }
        return display == nil ? 0 : 188
    }

    public override func draw(_ dirtyRect: NSRect) {
        rowFrames = []
        if !candidates.isEmpty {
            for (index, place) in candidates.enumerated() {
                let row = NSRect(x: 10, y: 8 + CGFloat(index) * 38, width: bounds.width - 20, height: 36)
                rowFrames.append(row)
                if index == selectedIndex {
                    OmniFrostedStyle.selectedFill.setFill()
                    NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8).fill()
                }
                text(place.candidateLabel, rect: row.insetBy(dx: 12, dy: 8), size: 14)
            }
            return
        }
        guard let display else { return }
        symbol(display.symbol, rect: NSRect(x: 22, y: 20, width: 64, height: 64), size: 64)
        text(display.temperature, rect: NSRect(x: 106, y: 15, width: 250, height: 56), size: 46, weight: .light)
        text(display.condition, rect: NSRect(x: 108, y: 75, width: bounds.width - 228, height: 20), size: 14, secondary: true)
        text("H \(display.high)", rect: NSRect(x: bounds.width - 102, y: 32, width: 80, height: 22), size: 14, alignment: .right)
        text("L \(display.low)", rect: NSRect(x: bounds.width - 102, y: 56, width: 80, height: 22), size: 14, alignment: .right)
        let width = (bounds.width - 44) / 3
        for (index, fact) in display.facts.prefix(3).enumerated() {
            let x = 22 + CGFloat(index) * width
            symbol(fact.symbol, rect: NSRect(x: x, y: 122, width: 18, height: 20), size: 18)
            text(fact.firstLine, rect: NSRect(x: x + 28, y: 121, width: width - 34, height: 22), size: 14, weight: .medium)
            if let second = fact.secondLine, !second.isEmpty {
                text(second, rect: NSRect(x: x + 28, y: 145, width: width - 34, height: 18), size: 12, secondary: true)
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowFrames.firstIndex(where: { $0.contains(point) }) else { return }
        onSelect?(index)
    }

    private func text(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                      secondary: Bool = false, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: secondary ? OmniFrostedStyle.secondaryInk : OmniFrostedStyle.ink,
            .paragraphStyle: paragraph
        ]).draw(in: rect)
    }

    private func symbol(_ name: String, rect: NSRect, size: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(.init(paletteColors: [OmniFrostedStyle.ink]))
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?.draw(in: rect, from: .zero, operation: .sourceOver,
                                                         fraction: 1, respectFlipped: true, hints: nil)
    }
}

@MainActor
public final class OmniWeatherViewController: NSViewController, NSTextViewDelegate {
    public static let preferredSize = NSSize(width: OmniPadPlacement.width, height: 106)
    public let editor = OmniEphemeralTextView()
    public let toolPill = OmniToolPillView(title: "Weather")
    public let routeLabel = NSTextField(labelWithString: "")
    public let keyHintsView = OmniKeyHintsView()
    public let copyButton = OmniPadRunButton()
    public let resultView = OmniWeatherResultView()
    public let session: OmniWeatherSession
    public var onCloseRequested: (() -> Void)?
    public var onChooseRequested: (() -> Void)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640
    public var routeText: String { routeLabel.stringValue }
    private let inputScroll = NSScrollView()
    private let resultDivider = OmniWeatherHairline()
    private let footerDivider = OmniWeatherHairline()
    private var workingIndicator: OmniPadWorkingIndicator?
    private var layoutInProgress = false

    public init(session: OmniWeatherSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        view = OmniFrostedSurface(frame: NSRect(origin: .zero, size: Self.preferredSize))
        view.autoresizingMask = [.width, .height]
        view.setAccessibilityIdentifier("omni.weather")
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
        editor.placeholderString = "A place, or nothing for here"
        editor.delegate = self
        editor.onEscape = { [weak self] in self?.onCloseRequested?() }
        editor.onSubmit = { [weak self] in self?.onChooseRequested?() }
        editor.onMoveExpressSelection = { [weak self] in self?.session.moveSelection(by: $0) ?? false }
        editor.setAccessibilityIdentifier("omni.weather.input")
        inputScroll.drawsBackground = false
        inputScroll.borderType = .noBorder
        inputScroll.documentView = editor
        resultView.setAccessibilityIdentifier("omni.weather.result")
        resultView.onSelect = { [weak self] index in self?.session.selectCandidate(index) }
        routeLabel.font = .systemFont(ofSize: 13)
        routeLabel.lineBreakMode = .byTruncatingMiddle
        routeLabel.setAccessibilityIdentifier("omni.weather.route")
        copyButton.symbolName = "doc.on.doc"
        copyButton.setAccessibilityLabel("Copy and close")
        copyButton.toolTip = "Copy and close"
        copyButton.setAccessibilityIdentifier("omni.weather.copy")
        copyButton.onPress = { [weak self] in self?.onChooseRequested?() }
        for child in [inputScroll, toolPill, footerDivider, routeLabel, keyHintsView, copyButton] as [NSView] { view.addSubview(child) }
        render()
    }

    public override func viewDidLayout() { super.viewDidLayout(); layoutControls() }

    public func focusInput() {
        view.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    public func clearUndoHistory() { if isViewLoaded { editor.undoManager?.removeAllActions() } }

    public func render() {
        guard isViewLoaded else { return }
        if editor.string != session.input { editor.string = session.input }
        editor.needsDisplay = true
        resultView.show(display: session.display, candidates: session.candidates, selectedIndex: session.selectedIndex, dimmed: session.isDimmed)
        if resultView.contentHeight > 0 {
            if resultView.superview == nil { view.addSubview(resultDivider); view.addSubview(resultView) }
        } else { resultView.removeFromSuperview(); resultDivider.removeFromSuperview() }
        let text = session.summary
        let summary = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk
        ])
        if let first = text.components(separatedBy: " · ").first, !first.isEmpty {
            summary.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                   .foregroundColor: OmniFrostedStyle.ink], range: NSRange(location: 0, length: (first as NSString).length))
        }
        if session.failureReason != nil {
            let mark = NSAttributedString(string: "● ", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: OmniFrostedStyle.warning])
            let source = (summary.string as NSString).range(of: "Open-Meteo")
            summary.insert(mark, at: source.location == NSNotFound ? 0 : source.location)
        }
        routeLabel.attributedStringValue = summary
        routeLabel.toolTip = session.failureReason ?? (text.isEmpty ? nil : text)
        routeLabel.setAccessibilityLabel(session.failureReason.map { text + ". " + $0 } ?? text)
        let choosing = !session.candidates.isEmpty
        keyHintsView.hints = (choosing ? [.init("↩", "Choose place")] : session.copyText == nil ? [] : [.init("↩", "Copy and close")]) + [.init("esc", "Close")]
        copyButton.isEnabled = session.copyText != nil
        copyButton.needsDisplay = true
        if session.isLoading {
            if workingIndicator == nil {
                let indicator = OmniPadWorkingIndicator(frame: .zero)
                view.addSubview(indicator)
                workingIndicator = indicator
            }
        } else { workingIndicator?.stop(); workingIndicator?.removeFromSuperview(); workingIndicator = nil }
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
        let fieldHeight: CGFloat = 25
        let inputHeight: CGFloat = 52
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 76))
        let inlineRouteWidth = max(1, width - 86 - hintWidth)
        let fullSummary = routeLabel.attributedStringValue.size().width + 8 > inlineRouteWidth
        let footerHeight: CGFloat = fullSummary ? 78 : 54
        let resultHeight = resultView.contentHeight
        let height = inputHeight + resultHeight + footerHeight
        if abs(view.bounds.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        let contentWidth = max(1, width - 36)
        editor.frame = NSRect(x: 0, y: 0, width: contentWidth, height: fieldHeight)
        editor.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        OmniToolPillLayout.reserveFirstLine(beside: editor, pill: toolPill, fieldWidth: contentWidth)
        inputScroll.frame = NSRect(x: 18, y: height - 14 - fieldHeight, width: contentWidth, height: fieldHeight)
        OmniToolPillLayout.place(toolPill, beside: editor, in: inputScroll.frame)
        resultDivider.frame = NSRect(x: 0, y: footerHeight + resultHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        resultView.frame = NSRect(x: 0, y: footerHeight, width: width, height: resultHeight)
        footerDivider.frame = NSRect(x: 0, y: footerHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        copyButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        keyHintsView.frame = NSRect(x: copyButton.frame.minX - 12 - hintWidth, y: 12, width: hintWidth, height: 30)
        routeLabel.frame = fullSummary
            ? NSRect(x: 18, y: 51, width: max(1, width - 36), height: 18)
            : NSRect(x: 18, y: 19, width: max(1, keyHintsView.frame.minX - 30), height: 18)
        workingIndicator?.frame = NSRect(x: max(18, routeLabel.frame.maxX - 12), y: routeLabel.frame.midY - 5, width: 10, height: 10)
    }
}

@MainActor private final class OmniWeatherHairline: NSView {
    override func draw(_ dirtyRect: NSRect) { OmniFrostedStyle.controlLine.setFill(); bounds.fill() }
}

@MainActor
public final class OmniWeatherWindowController {
    public let session: OmniWeatherSession
    public let viewController: OmniWeatherViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    /// Writes the selection's copy text: on Enter (then the tool closes) and
    /// on ⌘C (it stays open).
    public var onCopy: ((String) -> Void)?
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?

    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }

    public init(session: OmniWeatherSession, presentsInterface: Bool = true) {
        self.session = session
        viewController = OmniWeatherViewController(session: session)
        self.presentsInterface = presentsInterface
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onChooseRequested = { [weak self] in self?.copySelectionAndClose() }
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
        created.setAccessibilityIdentifier("omni.weather.panel")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onFocusLost = { [weak self] in self?.requestFocusLoss() }
        created.onCopyRequested = nil
        created.onSubmitRequested = { [weak self] in self?.copySelectionAndClose() }
        created.onMoveExpressSelection = { [weak self] offset in
            self?.session.moveSelection(by: offset) ?? false
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
        if !session.candidates.isEmpty { session.selectCandidate(session.selectedIndex); return }
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
