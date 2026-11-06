import AppKit
import OmniCore

/// An explicit-save draft. A queued run cannot be submitted again from this
/// session, even if the owner acknowledgement is delayed or uncertain.
@MainActor
public final class OmniCaptureSession {
    public private(set) var input = ""
    public private(set) var isOpen = false
    public private(set) var isSaving = false
    public private(set) var wasAdmitted = false
    public private(set) var notice: String?
    public var onChange: (@MainActor () -> Void)?

    public var request: OmniCaptureRequest? { OmniCaptureRequest.classify(input) }
    public var canSave: Bool { isOpen && !isSaving && !wasAdmitted && request != nil }

    public func open(input: String, notice: String? = nil) {
        self.input = input
        self.notice = notice
        isOpen = true
        isSaving = false
        wasAdmitted = false
        onChange?()
    }

    public func inputChanged(_ input: String) {
        guard isOpen, !isSaving, !wasAdmitted else { return }
        self.input = input
        notice = nil
        onChange?()
    }

    @discardableResult
    public func beginSave() -> Bool {
        guard canSave else { return false }
        isSaving = true
        notice = "Saving…"
        onChange?()
        return true
    }

    public func finishSave(admitted: Bool, notice: String) {
        guard isOpen else { return }
        isSaving = false
        wasAdmitted = admitted
        self.notice = notice
        onChange?()
    }

    public func close() {
        isOpen = false
        isSaving = false
        wasAdmitted = false
        input = ""
        notice = nil
        onChange?()
    }
}

@MainActor
public final class OmniCaptureTextView: NSTextView {
    public var onSave: (() -> Void)?
    public var onClose: (() -> Void)?
    public var placeholderString = "Capture a note or paste a link…"

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholderString as NSString).draw(
            in: NSRect(x: 0, y: 1, width: bounds.width, height: 44),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 17),
                             .foregroundColor: OmniFrostedStyle.ink.withAlphaComponent(0.38)]
        )
    }

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        if event.keyCode == 53 { onClose?(); return }
        if !hasMarkedText(), (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty {
            onSave?()
            return
        }
        // Shift+Return and Option+Return retain AppKit's native newline path.
        if performStandardEditingKey(event) { return }
        super.keyDown(with: event)
    }
}

@MainActor
public final class OmniCaptureViewController: NSViewController, NSTextViewDelegate {
    public let editor = OmniCaptureTextView()
    public let routeLabel = NSTextField(labelWithString: "")
    public let statusLabel = NSTextField(wrappingLabelWithString: "")
    public let provenanceChip = OmniProvenanceChip()
    public let saveButton = NSButton(title: "Save", target: nil, action: nil)
    public let keyHintsView = OmniKeyHintsView()
    public private(set) var provenance: OmniPadProvenance?
    public var onSaveRequested: (() -> Void)?
    public var onCloseRequested: (() -> Void)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640

    private let session: OmniCaptureSession
    private let inputScroll = NSScrollView()
    private var layingOut = false

    public init(session: OmniCaptureSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = OmniFrostedSurface(frame: NSRect(x: 0, y: 0, width: OmniPadPlacement.width, height: 146))
        root.setAccessibilityIdentifier("omni.capture")
        view = root
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 17)
        editor.textColor = OmniFrostedStyle.ink
        editor.insertionPointColor = OmniFrostedStyle.accent
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.onSave = { [weak self] in self?.onSaveRequested?() }
        editor.onClose = { [weak self] in self?.onCloseRequested?() }
        editor.setAccessibilityIdentifier("omni.capture.input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.scrollerStyle = .overlay
        inputScroll.borderType = .noBorder
        inputScroll.documentView = editor
        provenanceChip.setAccessibilityIdentifier("omni.capture.provenance")
        provenanceChip.onClear = { [weak self] in
            self?.provenance = nil
            self?.session.inputChanged("")
            self?.render()
            self?.focusInput()
        }
        routeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        routeLabel.textColor = OmniFrostedStyle.ink
        routeLabel.setAccessibilityIdentifier("omni.capture.route")
        statusLabel.font = OmniFrostedStyle.diagnosticFont
        statusLabel.textColor = OmniFrostedStyle.warning
        statusLabel.setAccessibilityIdentifier("omni.capture.status")
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(savePressed(_:))
        saveButton.setAccessibilityIdentifier("omni.capture.save")
        for child in [inputScroll, provenanceChip, routeLabel, statusLabel, keyHintsView, saveButton] as [NSView] {
            root.addSubview(child)
        }
        render()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutControls()
    }

    public func setProvenance(_ value: OmniPadProvenance?) {
        provenance = value
        render()
    }

    public func focusInput() {
        guard let window = view.window else { return }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    public func render() {
        guard isViewLoaded else { return }
        if editor.string != session.input { editor.string = session.input }
        editor.isEditable = !session.isSaving && !session.wasAdmitted
        provenanceChip.provenance = provenance
        provenanceChip.isHidden = provenance == nil
        routeLabel.stringValue = session.request?.destination.routeTitle ?? OmniCaptureDestination.note.routeTitle
        statusLabel.stringValue = session.notice ?? ""
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        saveButton.isEnabled = session.canSave
        keyHintsView.hints = [.init("↩", "Save"), .init("⇧↩", "New line"), .init("esc", "Close")]
        layoutControls()
    }

    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === editor else { return }
        session.inputChanged(editor.string)
        render()
    }

    @objc private func savePressed(_ sender: Any?) { onSaveRequested?() }

    private func layoutControls() {
        guard isViewLoaded, !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        let width = view.bounds.width
        let contentWidth = max(1, width - 36)
        editor.frame.size.width = contentWidth
        editor.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        if let manager = editor.layoutManager, let container = editor.textContainer { manager.ensureLayout(for: container) }
        let textHeight: CGFloat
        if let manager = editor.layoutManager, let container = editor.textContainer {
            textHeight = max(28, ceil(manager.usedRect(for: container).height))
        } else {
            textHeight = 28
        }
        let chipHeight: CGFloat = provenance == nil ? 0 : 36
        let inputHeight = min(160, textHeight + 26)
        let statusHeight: CGFloat = statusLabel.isHidden ? 0 : 28
        let footerHeight: CGFloat = 54
        let height = min(maximumHeight, chipHeight + inputHeight + statusHeight + footerHeight)
        if abs(view.bounds.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        provenanceChip.frame = NSRect(x: 16, y: height - 34, width: min(width - 32, provenanceChip.fittingWidth), height: 26)
        inputScroll.frame = NSRect(x: 18, y: footerHeight + statusHeight + 12, width: contentWidth,
                                   height: max(28, height - footerHeight - statusHeight - chipHeight - 26))
        editor.frame.size = NSSize(width: contentWidth, height: max(textHeight, inputScroll.contentSize.height))
        statusLabel.frame = NSRect(x: 18, y: footerHeight + 3, width: contentWidth, height: statusHeight)
        routeLabel.frame = NSRect(x: 18, y: 18, width: max(1, width - 330), height: 18)
        saveButton.frame = NSRect(x: width - 78, y: 11, width: 64, height: 32)
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 250))
        keyHintsView.frame = NSRect(x: saveButton.frame.minX - hintWidth - 10, y: 12, width: hintWidth, height: 30)
    }
}

@MainActor
private final class OmniCapturePanel: NSPanel {
    var onCloseRequested: (() -> Void)?
    var onFocusLost: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCloseRequested?() }
    override func performClose(_ sender: Any?) { onCloseRequested?() }
    override func resignKey() { super.resignKey(); onFocusLost?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCloseRequested?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
public final class OmniCaptureWindowController {
    public let session = OmniCaptureSession()
    public let viewController: OmniCaptureViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    public var onSaveRequested: (() -> Void)?
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?

    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }

    public init(presentsInterface: Bool = true) {
        self.presentsInterface = presentsInterface
        viewController = OmniCaptureViewController(session: session)
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onSaveRequested = { [weak self] in self?.onSaveRequested?() }
        viewController.onSizeChanged = { [weak self] size in self?.resize(to: size) }
    }

    public func show(input: String, notice: String? = nil, provenance: OmniPadProvenance? = nil) {
        session.open(input: input, notice: notice)
        viewController.loadViewIfNeeded()
        viewController.setProvenance(provenance)
        viewController.editor.undoManager?.removeAllActions()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(OmniPadPlacement.width, max(1, visibleFrame.width - 24))
        let top = visibleFrame.maxY - visibleFrame.height * OmniPadPlacement.topFraction
        viewController.maximumHeight = max(150, top - visibleFrame.minY - 12)
        viewController.view.setFrameSize(NSSize(width: width, height: viewController.view.frame.height))
        viewController.render()
        let size = viewController.view.frame.size
        let created = OmniCapturePanel(contentRect: OmniPadPlacement.frame(size: size, visibleFrame: visibleFrame),
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
        created.setAccessibilityIdentifier("omni.capture.panel")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onFocusLost = { [weak self] in self?.requestFocusLoss() }
        panel = created
        anchorFrame = OmniPadPlacement.frame(size: size, visibleFrame: visibleFrame)
        resize(to: size)
        guard presentsInterface else { return }
        created.makeKeyAndOrderFront(nil)
        viewController.focusInput()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        session.close()
        viewController.editor.undoManager?.removeAllActions()
        viewController.setProvenance(nil)
        panel?.orderOut(nil)
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
}
