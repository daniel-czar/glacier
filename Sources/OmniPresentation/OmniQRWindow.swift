import AppKit
import UniformTypeIdentifiers

/// The artifact owns its contrast. Only the ink dims when the input no longer fits.
@MainActor
public final class OmniQRTileView: NSView {
    public static let side: CGFloat = 280
    public var code: OmniQRCode? { didSet { needsDisplay = true } }
    public var inkOpacity: CGFloat = 1 { didSet { needsDisplay = true } }
    public override var isFlipped: Bool { true }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .image }
    public override func accessibilityLabel() -> String? { "QR code, version \(code?.version ?? 0)" }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        guard let code else { return }
        // Align every module to physical pixels, including on Retina screens.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let unit = floor(min(bounds.width, bounds.height) * scale / CGFloat(code.modules + 8))
        guard unit >= 1, let context = NSGraphicsContext.current?.cgContext else { return }
        let total = CGFloat(code.modules + 8) * unit
        let left = floor((bounds.width * scale - total) / 2) / scale
        let top = floor((bounds.height * scale - total) / 2) / scale
        context.setShouldAntialias(false)
        context.setFillColor(NSColor.black.withAlphaComponent(inkOpacity).cgColor)
        for row in 0..<code.modules {
            for column in 0..<code.modules where code.isDark(row: row, column: column) {
                context.fill(CGRect(x: left + CGFloat(column + 4) * unit / scale,
                                    y: top + CGFloat(row + 4) * unit / scale,
                                    width: unit / scale, height: unit / scale))
            }
        }
    }
}

@MainActor
public final class OmniQRInputView: OmniEphemeralTextView {
    public var onSave: (() -> Void)?
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s" { onSave?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
public final class OmniQRViewController: NSViewController, NSTextViewDelegate {
    public static let preferredSize = NSSize(width: OmniPadPlacement.width, height: 130)
    public let session: OmniQRSession
    public let editor = OmniQRInputView()
    public let toolPill = OmniToolPillView(title: "QR")
    public let tileView = OmniQRTileView()
    public let provenanceChip = OmniProvenanceChip()
    public private(set) var provenance: OmniPadProvenance?
    public let routeLabel = NSTextField(labelWithString: "")
    public let keyHintsView = OmniKeyHintsView()
    public let copyButton = OmniPadRunButton()
    public var onCloseRequested: (() -> Void)?
    public var onChooseRequested: (() -> Void)?
    public var onSaveRequested: (() -> Void)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640
    public var routeText: String { routeLabel.stringValue }
    private let inputScroll = NSScrollView()
    private let resultDivider = OmniQRHairline()
    private let footerDivider = OmniQRHairline()
    private var layoutInProgress = false
    public var exportFailure: String? { didSet { render() } }

    public init(session: OmniQRSession) { self.session = session; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        view = OmniFrostedSurface(frame: NSRect(origin: .zero, size: Self.preferredSize))
        view.autoresizingMask = [.width, .height]
        view.setAccessibilityIdentifier("omni.qr")
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
        editor.placeholderString = "Text, a link, or wifi:NAME,password"
        editor.delegate = self
        editor.onEscape = { [weak self] in self?.onCloseRequested?() }
        editor.onSubmit = { [weak self] in self?.onChooseRequested?() }
        editor.onSave = { [weak self] in self?.onSaveRequested?() }
        editor.setAccessibilityIdentifier("omni.qr.input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.scrollerStyle = .overlay
        inputScroll.borderType = .noBorder
        inputScroll.documentView = editor
        provenanceChip.usesCompactLabel = true
        provenanceChip.setAccessibilityIdentifier("omni.qr.provenance")
        provenanceChip.onClear = { [weak self] in
            guard let self else { return }
            self.setProvenance(nil)
            self.session.inputChanged("")
            self.clearUndoHistory()
            self.focusInput()
        }
        tileView.setAccessibilityIdentifier("omni.qr.tile")
        routeLabel.font = .systemFont(ofSize: 13)
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.setAccessibilityIdentifier("omni.qr.route")
        copyButton.symbolName = "doc.on.doc"
        copyButton.setAccessibilityLabel("Copy and close")
        copyButton.setAccessibilityIdentifier("omni.qr.copy")
        copyButton.toolTip = "Copy and close"
        copyButton.onPress = { [weak self] in self?.onChooseRequested?() }
        for child in [inputScroll, toolPill, provenanceChip, footerDivider, routeLabel, keyHintsView, copyButton] as [NSView] { view.addSubview(child) }
        render()
    }
    public override func viewDidLayout() { super.viewDidLayout(); layoutControls() }
    public func focusInput(preservingSelection: Bool = false) {
        view.window?.makeFirstResponder(editor)
        if !preservingSelection {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }
    public func clearUndoHistory() { if isViewLoaded { editor.undoManager?.removeAllActions() } }
    public func setProvenance(_ value: OmniPadProvenance?) { provenance = value; render() }
    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === editor else { return }
        // A render copies session.input into the editor when they differ.
        // Commit the native edit before clearing an export error can render.
        session.inputChanged(editor.string)
        if exportFailure != nil { exportFailure = nil }
    }
    public func render() {
        guard isViewLoaded else { return }
        if !session.isOpen { provenance = nil }
        if editor.string != session.input { editor.string = session.input }
        editor.needsDisplay = true
        provenanceChip.provenance = provenance
        provenanceChip.isHidden = provenance == nil
        tileView.code = session.code ?? session.lastFittingCode
        tileView.inkOpacity = CGFloat(session.previewOpacity)
        if tileView.code != nil {
            if tileView.superview == nil { view.addSubview(resultDivider); view.addSubview(tileView) }
        } else { tileView.removeFromSuperview(); resultDivider.removeFromSuperview() }
        let text = exportFailure ?? session.summary ?? ""
        let summary = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk,
        ])
        if let first = text.components(separatedBy: " · ").first, !first.isEmpty {
            summary.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                   .foregroundColor: OmniFrostedStyle.ink], range: NSRange(location: 0, length: (first as NSString).length))
        }
        if session.failure != nil || exportFailure != nil {
            summary.insert(NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.systemRed,
            ]), at: 0)
        }
        routeLabel.attributedStringValue = summary
        routeLabel.toolTip = text
        routeLabel.setAccessibilityLabel(text)
        keyHintsView.hints = (session.canExport ? [.init("↩", "Copy and close"), .init("⌘S", "Save…")] : []) + [.init("esc", "Close")]
        copyButton.isEnabled = session.canExport
        copyButton.needsDisplay = true
        layoutControls()
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
        let chipHeight: CGFloat = provenance == nil ? 0 : 38
        let footerHeight: CGFloat = 78
        let resultHeight: CGFloat = tileView.code == nil ? 0 : OmniQRTileView.side + 36
        let fieldBudget = max(25, maximumHeight - chipHeight - footerHeight - resultHeight - 27)
        let fieldHeight = min(130, fieldBudget, textHeight)
        let height = chipHeight + fieldHeight + 27 + resultHeight + footerHeight
        if abs(view.bounds.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        provenanceChip.frame = NSRect(x: 16, y: height - 38, width: min(max(1, width - 36), provenanceChip.fittingWidth), height: 26)
        inputScroll.frame = NSRect(x: 18, y: height - chipHeight - 14 - fieldHeight, width: contentWidth, height: fieldHeight)
        editor.frame.size = NSSize(width: contentWidth, height: max(fieldHeight, textHeight))
        OmniToolPillLayout.place(toolPill, beside: editor, in: inputScroll.frame)
        resultDivider.frame = NSRect(x: 0, y: footerHeight + resultHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        tileView.frame = NSRect(x: floor((width - OmniQRTileView.side) / 2), y: footerHeight + 18,
                                width: OmniQRTileView.side, height: OmniQRTileView.side)
        footerDivider.frame = NSRect(x: 0, y: footerHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        routeLabel.frame = NSRect(x: 18, y: 51, width: max(1, width - 36), height: 18)
        copyButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 76))
        keyHintsView.frame = NSRect(x: copyButton.frame.minX - 12 - hintWidth, y: 12, width: hintWidth, height: 30)
    }
}

@MainActor private final class OmniQRHairline: NSView {
    override func draw(_ dirtyRect: NSRect) { OmniFrostedStyle.controlLine.setFill(); bounds.fill() }
}

@MainActor
public final class OmniQRWindowController: NSObject {
    public let session: OmniQRSession
    public let viewController: OmniQRViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    public var writePasteboardItem: (NSPasteboardItem) -> Bool = { item in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }
    public private(set) var isSaving = false
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?
    private var artifactWasVisible = false
    private var savePanel: NSSavePanel?
    private var formatPicker: NSPopUpButton?

    public init(session: OmniQRSession = OmniQRSession(), presentsInterface: Bool = true) {
        self.session = session
        self.presentsInterface = presentsInterface
        viewController = OmniQRViewController(session: session)
        super.init()
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onChooseRequested = { [weak self] in self?.copySelectionAndClose() }
        viewController.onSaveRequested = { [weak self] in self?.save() }
        viewController.onSizeChanged = { [weak self] size in self?.resize(to: size) }
    }
    public func show(input: String = "", provenance: OmniPadProvenance? = nil, reusing reusedPanel: NSPanel? = nil) {
        anchorFrame = nil
        session.open(input: input)
        viewController.loadViewIfNeeded()
        viewController.exportFailure = nil
        viewController.setProvenance(provenance)
        viewController.clearUndoHistory()
        let screen = reusedPanel?.screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = reusedPanel?.frame.maxY ?? visibleFrame.maxY - visibleFrame.height * OmniPadPlacement.topFraction
        // Reserve the fixed artifact before letting the input grow upward.
        viewController.maximumHeight = max(476, visibleFrame.height - 24)
        viewController.view.setFrameSize(NSSize(width: min(OmniPadPlacement.width, visibleFrame.width - 24), height: viewController.view.frame.height))
        viewController.render()
        let size = viewController.view.frame.size
        let frame = NSRect(x: (reusedPanel?.frame.midX ?? visibleFrame.midX) - size.width / 2,
                           y: max(visibleFrame.minY + 12, top - size.height), width: size.width, height: size.height)
        let created = (reusedPanel as? OmniEphemeralPanel) ?? (panel as? OmniEphemeralPanel)
            ?? OmniEphemeralPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        created.level = .floating
        created.hasShadow = true
        created.isOpaque = false
        created.backgroundColor = .clear
        created.collectionBehavior = [.moveToActiveSpace, .transient]
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.contentViewController = viewController
        created.initialFirstResponder = viewController.editor
        created.setAccessibilityIdentifier("omni.qr.panel")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onFocusLost = { [weak self] in self?.requestFocusLoss() }
        created.onCopyRequested = nil
        created.onSubmitRequested = { [weak self] in self?.copySelectionAndClose() }
        created.onMoveExpressSelection = nil
        panel = created
        anchorFrame = frame
        artifactWasVisible = session.code != nil || session.lastFittingCode != nil
        created.setFrame(frame, display: true)
        guard presentsInterface else { return }
        created.makeKeyAndOrderFront(nil)
        viewController.focusInput()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    public func relinquishPanelForReplacement() -> NSPanel? {
        let previous = panel
        if let previous = previous as? OmniEphemeralPanel {
            previous.onCloseRequested = nil; previous.onFocusLost = nil; previous.onCopyRequested = nil
            previous.onSubmitRequested = nil; previous.onMoveExpressSelection = nil
        }
        panel = nil
        return previous
    }
    public func dismiss() {
        savePanel?.cancel(nil)
        session.close()
        viewController.clearUndoHistory()
        panel?.orderOut(nil)
    }
    @discardableResult
    public func copyCurrentOutput() -> Bool {
        guard session.canExport, !viewController.editor.hasMarkedText(),
              let code = session.code else { return false }
        do {
            let item = NSPasteboardItem()
            item.setData(try code.pngData(), forType: .png)
            item.setString(code.payload.encoded, forType: .string)
            guard writePasteboardItem(item) else { throw CocoaError(.fileWriteUnknown) }
            return true
        } catch { viewController.exportFailure = "Could not copy QR code"; return false }
    }
    public func copySelectionAndClose() { if copyCurrentOutput() { requestClose() } }

    public func save() {
        guard !isSaving, session.canExport, !viewController.editor.hasMarkedText(),
              let code = session.code, let panel else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.png, .svg]
        save.canCreateDirectories = true
        save.nameFieldStringValue = code.payload.defaultFilename + ".png"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        picker.addItems(withTitles: ["PNG image (.png)", "SVG image (.svg)"])
        picker.target = self
        picker.action = #selector(changeSaveFormat(_:))
        save.accessoryView = picker
        formatPicker = picker
        savePanel = save
        isSaving = true
        save.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            defer {
                self.isSaving = false; self.savePanel = nil; self.formatPicker = nil
                if self.session.isOpen {
                    self.panel?.makeKeyAndOrderFront(nil)
                    self.viewController.focusInput(preservingSelection: true)
                }
            }
            guard response == .OK, let url = save.url else { return }
            do {
                let data = url.pathExtension.lowercased() == "svg" ? code.svgData() : try code.pngData()
                try data.write(to: url, options: .atomic)
                self.viewController.exportFailure = nil
            } catch { self.viewController.exportFailure = "Could not save QR code" }
        }
    }
    @objc private func changeSaveFormat(_ sender: NSPopUpButton) {
        guard let savePanel else { return }
        let ext = sender.indexOfSelectedItem == 1 ? "svg" : "png"
        savePanel.allowedContentTypes = sender.indexOfSelectedItem == 1 ? [.svg] : [.png]
        savePanel.nameFieldStringValue = (savePanel.nameFieldStringValue as NSString).deletingPathExtension + "." + ext
    }
    private func resize(to size: NSSize) {
        guard let panel, var anchorFrame else { return }
        let hasArtifact = session.code != nil || session.lastFittingCode != nil
        if hasArtifact != artifactWasVisible {
            let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            anchorFrame.origin.y = max(visible.minY + 12, panel.frame.maxY - size.height)
            self.anchorFrame = anchorFrame
            artifactWasVisible = hasArtifact
        }
        // A growing field adds space above the artifact; its tile stays still.
        panel.setFrame(NSRect(x: anchorFrame.midX - size.width / 2, y: anchorFrame.minY,
                              width: size.width, height: size.height), display: true, animate: false)
    }
    private func requestClose() { if let onCloseRequested { onCloseRequested() } else { dismiss() } }
    private func requestFocusLoss() {
        guard session.isOpen, !isSaving else { return }
        if let onFocusLost { onFocusLost() } else { dismiss() }
    }
}
