import AppKit
import OmniCore
import QuickLookUI

@MainActor
public final class OmniMapInputView: OmniEphemeralTextView {
    var onMoveForm: ((Int, Int) -> Bool)?
    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        if !hasMarkedText(), modifiers.isEmpty {
            let movement: (Int, Int)? = switch event.keyCode {
            case 123: (-1, 0)
            case 124: (1, 0)
            case 125: (0, 1)
            case 126: (0, -1)
            default: nil
            }
            if let movement, onMoveForm?(movement.0, movement.1) == true { return }
        }
        super.keyDown(with: event)
    }
}

@MainActor
public final class OmniMapChooserView: NSView {
    public private(set) var cellFrames: [CGRect] = []
    public var selectedForm: OmniMapForm? { didSet { needsDisplay = true } }
    public var onSelect: ((OmniMapForm) -> Void)?
    public override var isFlipped: Bool { true }
    private let scenes = OmniMapForm.allCases.map { OmniMapLayouts.layout(OmniMapSamples.document(for: $0)) }

    @discardableResult
    public func arrange(width: CGFloat) -> CGFloat {
        let cellWidth = max(1, (width - 30) / 4)
        cellFrames = OmniMapForm.allCases.indices.map { index in
            CGRect(x: CGFloat(index % 4) * (cellWidth + 10), y: CGFloat(index / 4) * 124, width: cellWidth, height: 116)
        }
        frame.size = NSSize(width: width, height: 240)
        return 240
    }

    public override func draw(_ dirtyRect: NSRect) {
        for (index, frame) in cellFrames.enumerated() {
            let form = OmniMapForm.allCases[index]
            if form == selectedForm {
                OmniFrostedStyle.ink.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            }
            let scene = scenes[index]
            let scale = min(max(1, frame.width - 16) / scene.size.width, 64 / scene.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.translateBy(x: frame.midX - scene.size.width * scale / 2, y: frame.minY + 6)
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            OmniMapDrawing.draw(scene)
            NSGraphicsContext.restoreGraphicsState()
            OmniDrawnPrimitives.label(form.title, frame: CGRect(x: frame.minX + 8, y: frame.minY + 74, width: frame.width - 16, height: 16),
                                      size: 12, color: OmniFrostedStyle.ink, weight: .semibold, alignment: .left)
            OmniDrawnPrimitives.label(form.question, frame: CGRect(x: frame.minX + 8, y: frame.minY + 92, width: frame.width - 16, height: 28),
                                      size: 10.5, color: OmniFrostedStyle.secondaryInk, alignment: .left, wraps: true)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = cellFrames.firstIndex(where: { $0.contains(point) }) { onSelect?(OmniMapForm.allCases[index]) }
    }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .list }
    public override func accessibilityLabel() -> String? {
        OmniMapForm.allCases.map { $0.title + ": " + $0.question }.joined(separator: ". ")
    }
}

@MainActor private final class OmniMapFormButton: NSButton {
    var onPress: (() -> Void)?
    init(title: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(press)
        isBordered = false
        alignment = .left
        font = .systemFont(ofSize: 13, weight: .semibold)
        contentTintColor = OmniFrostedStyle.ink
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func press() { onPress?() }
}

@MainActor
public final class OmniMapViewController: NSViewController, NSTextViewDelegate, NSPopoverDelegate, OmniDrawnPreviewProviding {
    public static let placeholder = "A question or a phrase · add “as loop”, “as matrix” to choose"
    public let editor = OmniMapInputView()
    public let drawing = OmniMapDrawing()
    public let chooser = OmniMapChooserView()
    public let toolPill = OmniToolPillView(title: "Map")
    public let routeLabel = NSTextField(labelWithString: "")
    public let keyHintsView = OmniKeyHintsView()
    public let copyButton = OmniPadRunButton()
    public let provenanceChip = OmniProvenanceChip()
    public private(set) var provenance: OmniPadProvenance?
    public let session: OmniMapSession
    public var onCloseRequested: (() -> Void)?
    public var onCopyRequested: (() -> Void)?
    public var onLargerRequested: (() -> Bool)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640
    let drawnPreview = OmniDrawnPreview()
    private let inputScroll = NSScrollView()
    private let resultScroll = NSScrollView()
    private let resultDivider = OmniMapHairline()
    private let footerDivider = OmniMapHairline()
    private let resultFade = OmniPadResultFade()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var formButton: OmniMapFormButton!
    private var working: OmniPadWorkingIndicator?
    private var formPopover: NSPopover?
    public private(set) var isPresentingFormChooser = false
    private var arranging = false

    public init(session: OmniMapSession) { self.session = session; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = OmniFrostedSurface(frame: NSRect(x: 0, y: 0, width: 640, height: 384))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier("omni.map")
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
        editor.onCopyOutput = { [weak self] in self?.onCopyRequested?() }
        editor.onSubmit = { [weak self] in self?.submitOrCopy() }
        editor.onLarger = { [weak self] in self?.onLargerRequested?() ?? false }
        editor.onMoveForm = { [weak self] x, y in self?.session.moveSelection(columns: x, rows: y) ?? false }
        editor.setAccessibilityIdentifier("omni.map.input")
        for scroll in [inputScroll, resultScroll] {
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
        }
        inputScroll.documentView = editor
        resultScroll.hasHorizontalScroller = true
        resultScroll.documentView = chooser
        chooser.onSelect = { [weak self] form in self?.session.selectForm(form); self?.focusInput() }
        chooser.setAccessibilityIdentifier("omni.map.forms")
        drawing.setAccessibilityIdentifier("omni.map.drawing")
        provenanceChip.usesCompactLabel = true
        provenanceChip.onClear = { [weak self] in
            self?.provenance = nil
            self?.session.inputChanged("")
            self?.editor.undoManager?.removeAllActions()
        }
        formButton = OmniMapFormButton(title: "Map") { [weak self] in self?.showFormChooser() }
        formButton.setAccessibilityIdentifier("omni.map.form")
        formButton.toolTip = "Choose a form and ask again"
        routeLabel.font = .systemFont(ofSize: 13)
        routeLabel.textColor = OmniFrostedStyle.secondaryInk
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.setAccessibilityIdentifier("omni.map.route")
        statusLabel.font = OmniFrostedStyle.diagnosticFont
        statusLabel.textColor = OmniFrostedStyle.secondaryInk
        copyButton.symbolName = "doc.on.doc"
        copyButton.toolTip = "Copy and close"
        copyButton.setAccessibilityLabel("Copy and close")
        copyButton.setAccessibilityIdentifier("omni.map.copy")
        copyButton.onPress = { [weak self] in self?.submitOrCopy() }
        for child in [inputScroll, resultScroll, provenanceChip, toolPill, resultDivider, footerDivider,
                      formButton!, routeLabel, keyHintsView, copyButton, statusLabel, resultFade] as [NSView] { root.addSubview(child) }
        render()
    }

    public override func viewDidLayout() { super.viewDidLayout(); arrange() }
    public func focusInput() {
        guard isViewLoaded else { return }
        view.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
    public func setProvenance(_ value: OmniPadProvenance?) { provenance = value; if isViewLoaded { render() } }
    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === editor else { return }
        session.inputChanged(editor.string)
    }

    public func render() {
        guard isViewLoaded else { return }
        if !session.outputIsCurrent { drawnPreview.close() }
        if !session.isOpen { provenance = nil; closeFormChooser() }
        if editor.string != session.input { editor.string = session.input }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        if let mode = session.parsed.modeRange { editor.layoutManager?.addTemporaryAttribute(.foregroundColor, value: OmniFrostedStyle.mode, forCharacterRange: mode) }
        editor.needsDisplay = true
        provenanceChip.provenance = provenance
        provenanceChip.isHidden = provenance == nil
        chooser.selectedForm = session.selectedForm
        drawing.display(session.document)
        drawing.alphaValue = session.outputIsCurrent ? 1 : 0.42
        let active: NSView = session.document == nil ? chooser : drawing
        if resultScroll.documentView !== active { resultScroll.documentView = active }
        let summary = session.summary
        let parts = summary.components(separatedBy: " · ")
        formButton.title = parts.first ?? "Map"
        let detail = parts.dropFirst().joined(separator: " · ")
        routeLabel.stringValue = detail.isEmpty ? "" : "· " + detail
        if let reason = session.failureReason {
            let mark = NSMutableAttributedString(string: "● ", attributes: [.font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.systemRed, .baselineOffset: 2])
            mark.append(NSAttributedString(string: routeLabel.stringValue, attributes: [.font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: OmniFrostedStyle.secondaryInk]))
            routeLabel.attributedStringValue = mark
            routeLabel.toolTip = reason
        } else { routeLabel.toolTip = session.notice }
        statusLabel.stringValue = session.notice ?? ""
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        let generate = session.canSubmit
        copyButton.isEnabled = generate || session.copyableDocument != nil
        copyButton.symbolName = generate ? "sparkles" : "doc.on.doc"
        copyButton.setAccessibilityLabel(generate ? "Generate map" : "Copy and close")
        copyButton.toolTip = generate ? "Generate a map from the current text" : "Copy and close"
        keyHintsView.hints = (generate ? [.init("↩", "Generate")] :
            session.copyableDocument != nil ? [.init("↩", "Copy and close"), .init("␣", "Larger")] : [])
            + [.init("esc", "Close")]
        if session.phase == .waiting, working == nil {
            let dot = OmniPadWorkingIndicator(frame: .zero)
            view.addSubview(dot)
            working = dot
        } else if session.phase != .waiting {
            working?.stop(); working?.removeFromSuperview(); working = nil
        }
        arrange()
    }

    func submitOrCopy() {
        if session.canSubmit { session.submit() }
        else { onCopyRequested?() }
    }

    public func showFormChooser() {
        guard formPopover == nil else { return }
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 226))
        for (index, form) in OmniMapForm.allCases.enumerated() {
            let button = OmniMapFormButton(title: form.title + " · " + form.question) { [weak self] in
                self?.session.selectForm(form)
                self?.closeFormChooser()
                self?.focusInput()
            }
            button.frame = NSRect(x: 12, y: 194 - CGFloat(index) * 30, width: 236, height: 28)
            button.font = .systemFont(ofSize: 12)
            button.lineBreakMode = .byTruncatingTail
            content.view.addSubview(button)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.delegate = self
        formPopover = popover
        isPresentingFormChooser = true
        popover.show(relativeTo: formButton.bounds, of: formButton, preferredEdge: .maxY)
    }
    public func closeFormChooser() {
        let previous = formPopover
        formPopover = nil
        previous?.performClose(nil)
        isPresentingFormChooser = false
    }
    public func popoverDidClose(_ notification: Notification) { formPopover = nil; isPresentingFormChooser = false; focusInput() }

    private func textHeight(width: CGFloat) -> CGFloat {
        editor.frame.size.width = width
        editor.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        guard let manager = editor.layoutManager, let container = editor.textContainer else { return 24 }
        manager.ensureLayout(for: container)
        return max(24, ceil(manager.usedRect(for: container).height))
    }

    private func arrange() {
        guard isViewLoaded, !arranging else { return }
        arranging = true
        defer { arranging = false }
        let width = view.bounds.width
        let contentWidth = max(1, width - 36)
        OmniToolPillLayout.reserveFirstLine(beside: editor, pill: toolPill, fieldWidth: contentWidth)
        let editorHeight = min(130, textHeight(width: contentWidth))
        let inputHeight = editorHeight + 26
        let provenanceHeight: CGFloat = provenance == nil ? 0 : 38
        let formWidth = ceil(formButton.attributedTitle.size().width) + 8
        let summaryWidth = formWidth + routeLabel.attributedStringValue.size().width + (working == nil ? 0 : 24)
        let narrow = width < 540 || summaryWidth + keyHintsView.fittingWidth + 96 > width
        let footerHeight: CGFloat = narrow ? 82 : 54
        let noticeHeight: CGFloat = statusLabel.isHidden ? 0 : 32
        let contentHeight = session.document == nil ? chooser.arrange(width: contentWidth) : drawing.arrange(width: contentWidth)
        let resultHeight = min(contentHeight, max(24, maximumHeight - inputHeight - provenanceHeight - footerHeight - noticeHeight - 30))
        let height = inputHeight + provenanceHeight + resultHeight + 30 + footerHeight + noticeHeight
        if abs(view.frame.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        provenanceChip.frame = NSRect(x: 16, y: height - 38, width: min(contentWidth, provenanceChip.fittingWidth), height: 26)
        inputScroll.frame = NSRect(x: 18, y: height - provenanceHeight - inputHeight + 14, width: contentWidth, height: editorHeight)
        editor.frame.size = NSSize(width: contentWidth, height: max(editorHeight, inputScroll.contentSize.height))
        OmniToolPillLayout.place(toolPill, beside: editor, in: inputScroll.frame)
        let resultTop = height - provenanceHeight - inputHeight
        resultDivider.frame = NSRect(x: 0, y: resultTop, width: width, height: OmniFrostedStyle.hairlineWidth)
        resultScroll.frame = NSRect(x: 18, y: resultTop - resultHeight - 14, width: contentWidth, height: resultHeight)
        footerDivider.frame = NSRect(x: 0, y: footerHeight + noticeHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        copyButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        let hintsWidth = min(keyHintsView.fittingWidth, max(1, width - 74))
        keyHintsView.frame = NSRect(x: width - 56 - hintsWidth, y: 12, width: hintsWidth, height: 30)
        let routeY: CGFloat = narrow ? 51 : 19
        let routeX: CGFloat = working == nil ? 18 : 42
        formButton.frame = NSRect(x: routeX, y: routeY - 2, width: formWidth, height: 22)
        let textX = formButton.frame.maxX
        routeLabel.frame = NSRect(x: textX, y: routeY, width: max(1, (narrow ? width - 18 : keyHintsView.frame.minX - 12) - textX), height: 18)
        working?.frame = NSRect(x: 16, y: routeY, width: 24, height: 18)
        statusLabel.frame = NSRect(x: 18, y: footerHeight + 8, width: contentWidth, height: max(0, noticeHeight - 12))
        resultFade.frame = NSRect(x: 18, y: resultScroll.frame.minY, width: contentWidth, height: 20)
        resultFade.isHidden = contentHeight <= resultHeight + 1
    }
}

@MainActor private final class OmniMapHairline: NSView {
    override func draw(_ dirtyRect: NSRect) { OmniFrostedStyle.controlLine.setFill(); bounds.fill() }
}

@MainActor
public final class OmniMapWindowController {
    public let session: OmniMapSession
    public let viewController: OmniMapViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    public var writePasteboardItem: (NSPasteboardItem) -> Bool = { item in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }
    private let presentsInterface: Bool
    private var anchor: NSRect?

    public init(producer: @escaping OmniMapProducer, presentsInterface: Bool = true,
                debounce: Duration = .milliseconds(350),
                automaticRequestsEnabled: @escaping @MainActor () -> Bool = { true }) {
        session = OmniMapSession(producer: producer, debounce: debounce,
                                 automaticRequestsEnabled: automaticRequestsEnabled)
        viewController = OmniMapViewController(session: session)
        self.presentsInterface = presentsInterface
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCopyRequested = { [weak self] in self?.copyCurrentOutput() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onLargerRequested = { [weak self] in self?.showLarger() ?? false }
        viewController.onSizeChanged = { [weak self] size in self?.resize(size) }
        viewController.drawnPreview.onReturnToTool = { [weak self] in
            guard let self, self.session.isOpen else { return }
            if self.presentsInterface { self.panel?.makeKeyAndOrderFront(nil); self.viewController.focusInput() }
        }
    }

    public func show(input: String = "", notice: String? = nil, provenance: OmniPadProvenance? = nil, reusing reused: NSPanel? = nil) {
        anchor = reused?.frame
        session.open(input: input, notice: notice)
        viewController.loadViewIfNeeded()
        viewController.setProvenance(provenance)
        viewController.editor.undoManager?.removeAllActions()
        let pointer = NSEvent.mouseLocation
        let screen = reused?.screen ?? NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = anchor?.maxY ?? visible.maxY - visible.height * OmniPadPlacement.topFraction
        viewController.maximumHeight = max(160, top - visible.minY - 12)
        viewController.view.setFrameSize(NSSize(width: min(640, max(1, visible.width - 24)), height: 384))
        viewController.render()
        let size = viewController.view.frame.size
        let created = (reused as? OmniEphemeralPanel) ?? (panel as? OmniEphemeralPanel) ?? OmniEphemeralPanel(
            contentRect: OmniPadPlacement.frame(size: size, visibleFrame: visible), styleMask: [.borderless], backing: .buffered, defer: false)
        created.level = .floating
        created.hasShadow = true
        created.isOpaque = false
        created.backgroundColor = .clear
        created.collectionBehavior = [.moveToActiveSpace, .transient]
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.contentViewController = viewController
        created.initialFirstResponder = viewController.editor
        created.setAccessibilityIdentifier("omni.map.panel")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onCopyRequested = { [weak self] in self?.copyCurrentOutput() }
        created.onSubmitRequested = { [weak self] in self?.viewController.submitOrCopy() }
        created.onMoveExpressSelection = nil
        created.onFocusLost = { [weak self] in
            guard let self, !self.viewController.drawnPreview.isPresenting, !self.viewController.isPresentingFormChooser else { return }
            if let onFocusLost = self.onFocusLost { onFocusLost() } else { self.dismiss() }
        }
        panel = created
        if anchor == nil { anchor = OmniPadPlacement.frame(size: size, visibleFrame: visible) }
        resize(size)
        if presentsInterface { created.makeKeyAndOrderFront(nil); viewController.focusInput(); NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    public func relinquishPanelForReplacement() -> NSPanel? {
        viewController.drawnPreview.close()
        viewController.closeFormChooser()
        let previous = panel
        if let previous = previous as? OmniEphemeralPanel {
            previous.onCloseRequested = nil; previous.onCopyRequested = nil; previous.onFocusLost = nil
            previous.onSubmitRequested = nil; previous.onMoveExpressSelection = nil
        }
        panel = nil
        return previous
    }

    public func dismiss() {
        viewController.drawnPreview.close()
        viewController.closeFormChooser()
        session.close()
        viewController.editor.undoManager?.removeAllActions()
        panel?.orderOut(nil)
    }

    public func copyCurrentOutput() {
        guard let document = session.copyableDocument, let item = OmniMapCopyComposer.item(document), writePasteboardItem(item) else { return }
        viewController.drawnPreview.close()
        if let onCloseRequested { onCloseRequested() } else { dismiss() }
    }

    @discardableResult public func showLarger() -> Bool {
        guard let document = session.copyableDocument, let png = OmniMapCopyComposer.png(document) else { return false }
        let preview = viewController.drawnPreview
        if preview.isPresenting { preview.close(); return true }
        do { try preview.prepare(png, title: "Map") } catch { return false }
        guard presentsInterface else { return true }
        guard let shared = QLPreviewPanel.shared() else { preview.close(); return false }
        shared.makeKeyAndOrderFront(nil)
        shared.updateController()
        guard shared.currentController as AnyObject? === panel else { preview.close(); return false }
        shared.reloadData()
        return true
    }

    private func requestClose() {
        if viewController.drawnPreview.isPresenting { viewController.drawnPreview.close(); return }
        if viewController.isPresentingFormChooser { viewController.closeFormChooser(); return }
        if let onCloseRequested { onCloseRequested() } else { dismiss() }
    }
    private func resize(_ size: NSSize) {
        guard let panel, let anchor else { return }
        panel.setFrame(NSRect(x: anchor.midX - size.width / 2, y: anchor.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}
