import AppKit
import OmniCore

/// The stack view's field. Keys that act on the stack are taken here; with
/// an empty field Space previews and ⌫ drops, otherwise they edit the query.
@MainActor
public final class OmniStashInputView: OmniEphemeralTextView {
    public var onKeystroke: (() -> Void)?
    public var onMoveSelection: ((Int) -> Void)?
    public var onPaste: (() -> Void)?
    /// ⇧↩: plain text whatever Settings says.
    public var onPastePlain: (() -> Void)?
    public var onCopyOnly: (() -> Void)?
    public var onEdit: (() -> Void)?
    public var onDrop: (() -> Void)?
    public var onClear: (() -> Void)?
    public var onPreview: (() -> Void)?
    public var onClosePreview: (() -> Bool)?
    public var onUndo: (() -> Void)?
    public var onRedo: (() -> Void)?
    /// The session's manager, so typing and stack changes share one ⌘Z.
    public var sharedUndoManager: UndoManager?

    public override var undoManager: UndoManager? { sharedUndoManager ?? super.undoManager }

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard !hasMarkedText() else { super.keyDown(with: event); return }
        onKeystroke?()
        switch event.keyCode {
        case 53 where onClosePreview?() == true:
            return
        case 125 where modifiers.isEmpty, 126 where modifiers.isEmpty:
            onMoveSelection?(event.keyCode == 125 ? 1 : -1)
            return
        case 36, 76:
            guard !event.isARepeat else { return }
            if modifiers == .command { onEdit?() } else if modifiers == .option { onCopyOnly?() }
            else if modifiers == .shift { onPastePlain?() } else if modifiers.isEmpty { onPaste?() }
            return
        case 51 where string.isEmpty && modifiers.isEmpty:
            onDrop?()
            return
        case 51 where string.isEmpty && modifiers == .command:
            onClear?()
            return
        case 49 where string.isEmpty && modifiers.isEmpty:
            onPreview?()
            return
        default:
            break
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "z" { onUndo?(); return }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" { onRedo?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
public final class OmniStashViewController: NSViewController, NSTextViewDelegate {
    nonisolated public static let placeholder = "Search the stash"
    public static let preferredSize = NSSize(width: OmniPadPlacement.width, height: 120)
    public let editor = OmniStashInputView()
    public let toolPill = OmniToolPillView(title: "Stash")
    public let routeLabel = NSTextField(labelWithString: "")
    public let keyHintsView = OmniKeyHintsView()
    public let pasteButton = OmniPadRunButton()
    public let preview = OmniContentPreview()
    public let session: OmniStashSession
    public var onCloseRequested: (() -> Void)?
    public var onPasteRequested: (() -> Void)?
    public var onPastePlainRequested: (() -> Void)?
    public var onCopyOnlyRequested: (() -> Void)?
    public var onEditRequested: (() -> Void)?
    public var onSizeChanged: ((NSSize) -> Void)?
    public var maximumHeight: CGFloat = 640

    private let inputScroll = NSScrollView()
    private let resultScroll = NSScrollView()
    private let resultBody = OmniStashFlippedView()
    private let resultDivider = OmniStashHairline()
    private let footerDivider = OmniStashHairline()
    public private(set) var rowViews: [OmniKindRowView] = []
    private var layoutInProgress = false

    public init(session: OmniStashSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = OmniFrostedSurface(frame: NSRect(origin: .zero, size: Self.preferredSize))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier("omni.stash")
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
        editor.sharedUndoManager = session.undoManager
        editor.onEscape = { [weak self] in self?.onCloseRequested?() }
        editor.onKeystroke = { [weak self] in self?.session.noteKeystroke() }
        editor.onMoveSelection = { [weak self] delta in
            self?.preview.close()
            self?.session.moveSelection(by: delta)
        }
        editor.onPaste = { [weak self] in self?.onPasteRequested?() }
        editor.onPastePlain = { [weak self] in self?.onPastePlainRequested?() }
        editor.onCopyOnly = { [weak self] in self?.onCopyOnlyRequested?() }
        editor.onEdit = { [weak self] in self?.onEditRequested?() }
        editor.onDrop = { [weak self] in
            self?.preview.close()
            self?.session.dropSelected()
        }
        editor.onClear = { [weak self] in
            self?.preview.close()
            self?.session.clearAll()
        }
        editor.onPreview = { [weak self] in self?.togglePreview() }
        editor.onClosePreview = { [weak self] in
            guard let self, self.preview.isShown else { return false }
            self.preview.close()
            return true
        }
        editor.onUndo = { [weak self] in self?.session.undo() }
        editor.onRedo = { [weak self] in self?.session.redo() }
        editor.setAccessibilityIdentifier("omni.stash.input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = false
        inputScroll.borderType = .noBorder
        inputScroll.documentView = editor

        resultScroll.drawsBackground = false
        resultScroll.hasVerticalScroller = true
        resultScroll.scrollerStyle = .overlay
        resultScroll.borderType = .noBorder
        resultScroll.documentView = resultBody
        resultScroll.setAccessibilityIdentifier("omni.stash.rows")
        resultDivider.setAccessibilityIdentifier("omni.stash.result-divider")
        footerDivider.setAccessibilityIdentifier("omni.stash.footer-divider")

        routeLabel.font = .systemFont(ofSize: 13)
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.setAccessibilityIdentifier("omni.stash.summary")
        pasteButton.symbolName = "arrow.turn.down.left"
        pasteButton.setAccessibilityLabel("Paste and close")
        pasteButton.toolTip = "Paste and close"
        pasteButton.setAccessibilityIdentifier("omni.stash.paste")
        pasteButton.onPress = { [weak self] in self?.onPasteRequested?() }
        keyHintsView.setAccessibilityIdentifier("omni.stash.key-hints")
        for child in [inputScroll, toolPill, resultDivider, resultScroll, footerDivider, routeLabel, keyHintsView, pasteButton] as [NSView] {
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

    public func render() {
        guard isViewLoaded else { return }
        if editor.string != session.query { editor.string = session.query }
        editor.needsDisplay = true
        rebuildRows()
        let message = session.notice ?? session.error
        let route = NSMutableAttributedString(string: message ?? session.summary, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: message == nil ? .regular : .medium),
            .foregroundColor: message == nil ? OmniFrostedStyle.secondaryInk : OmniFrostedStyle.warning,
        ])
        if session.notice != nil, session.canUndo {
            route.append(NSAttributedString(string: "   ⌘Z", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: OmniFrostedStyle.warning,
            ]))
        }
        routeLabel.attributedStringValue = route
        keyHintsView.hints = (session.selectedRow == nil ? [] : [.init("↩", "Paste"), .init("⌘↩", "Edit")])
            + [.init("esc", "Close")]
        pasteButton.isEnabled = session.selectedRow != nil
        pasteButton.needsDisplay = true
        layoutControls()
    }

    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === editor else { return }
        preview.close()
        session.inputChanged(editor.string)
    }

    public func clearUndoHistory() { session.undoManager.removeAllActions() }

    public func togglePreview() {
        guard let row = session.selectedRow, let index = session.selectedIndex, rowViews.indices.contains(index) else { return }
        let image = row.entry.representations.first { OmniStashRepresentation.isImageType($0.type) }?.data
        preview.toggle(text: row.entry.text, kind: row.entry.kind, imageData: image, relativeTo: rowViews[index])
    }

    static func content(for row: OmniStashRow, now: Date = Date()) -> OmniKindRowContent {
        OmniKindRowContent(
            kind: row.entry.kind,
            text: row.entry.text,
            detail: "\(row.entry.source) · \(OmniRelativeTime.label(for: row.entry.editedAt ?? row.entry.createdAt, now: now))",
            token: row.token,
            tokenDimmed: row.position != 1,
            emphasized: row.position == 1,
            imageData: row.entry.representations.first { OmniStashRepresentation.isImageType($0.type) }?.data,
            imageKey: row.entry.id
        )
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        let now = Date()
        for (index, row) in session.rows.enumerated() {
            let rowView = OmniKindRowView(content: Self.content(for: row, now: now), selected: index == session.selectedIndex)
            rowView.setAccessibilityIdentifier("omni.stash.row.\(row.position)")
            rowView.onSelect = { [weak self] in self?.session.select(index) }
            rowView.onActivate = { [weak self] in
                self?.session.select(index)
                self?.onPasteRequested?()
            }
            resultBody.addSubview(rowView)
            rowViews.append(rowView)
        }
    }

    private func layoutControls() {
        guard isViewLoaded, !layoutInProgress else { return }
        layoutInProgress = true
        defer { layoutInProgress = false }
        let width = view.bounds.width
        let contentWidth = max(1, width - 20)
        let topInset: CGFloat = 8
        let bottomInset: CGFloat = 10
        let gap: CGFloat = 2
        let heights = rowViews.map { OmniKindRowView.height(for: $0.content, width: contentWidth) }
        let rowsHeight = heights.reduce(0, +) + gap * CGFloat(max(0, heights.count - 1))
        let bodyHeight = rowViews.isEmpty ? 0 : topInset + rowsHeight + bottomInset
        resultBody.frame = NSRect(x: 0, y: 0, width: contentWidth, height: bodyHeight)
        var cursor = topInset
        for (row, height) in zip(rowViews, heights) {
            row.frame = NSRect(x: 0, y: cursor, width: contentWidth, height: height)
            row.layoutContent()
            cursor += height + gap
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
        // No rows, no result region (C61): the field sits on the summary.
        let resultHeight = min(520, resultBudget, bodyHeight)
        let height = inputHeight + resultHeight + footerHeight
        if abs(view.bounds.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        inputScroll.frame = NSRect(x: 18, y: height - 14 - fieldHeight, width: width - 36, height: fieldHeight)
        editor.frame = NSRect(x: 0, y: 0, width: inputScroll.frame.width, height: max(fieldHeight, textHeight))
        OmniToolPillLayout.place(toolPill, beside: editor, in: inputScroll.frame)
        resultDivider.isHidden = rowViews.isEmpty
        resultScroll.isHidden = rowViews.isEmpty
        resultDivider.frame = NSRect(x: 0, y: height - inputHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        resultScroll.frame = NSRect(x: 10, y: footerHeight, width: contentWidth, height: resultHeight)
        footerDivider.frame = NSRect(x: 0, y: footerHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        pasteButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 76))
        keyHintsView.frame = NSRect(x: pasteButton.frame.minX - 12 - hintWidth, y: 12, width: hintWidth, height: 30)
        let routeY: CGFloat = narrow ? 51 : 19
        routeLabel.frame = NSRect(x: 18, y: routeY,
            width: max(1, (narrow ? width - 18 : keyHintsView.frame.minX - 12) - 18), height: 18)
        if let selectedIndex = session.selectedIndex, rowViews.indices.contains(selectedIndex), resultHeight > 0 {
            resultScroll.contentView.scrollToVisible(rowViews[selectedIndex].frame)
        }
    }
}

@MainActor private final class OmniStashFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class OmniStashHairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.controlLine.setFill()
        bounds.fill()
    }
}

/// The `st` tool (C92–C94), in the same disposable panel as the other
/// ephemeral tools. Enter applies the selected entry (paste, never pop);
/// the host performs paste, copy and the move to the workspace.
@MainActor
public final class OmniStashWindowController {
    public let session: OmniStashSession
    public let viewController: OmniStashViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    public var onPaste: ((OmniStashEntry) -> Void)?
    public var onPastePlain: ((OmniStashEntry) -> Void)?
    public var onCopyOnly: ((OmniStashEntry) -> Void)?
    public var onEdit: ((OmniStashEntry) -> Void)?
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?

    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }

    public init(session: OmniStashSession, presentsInterface: Bool = true) {
        self.session = session
        viewController = OmniStashViewController(session: session)
        self.presentsInterface = presentsInterface
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onPasteRequested = { [weak self] in self?.pasteSelection() }
        viewController.onPastePlainRequested = { [weak self] in self?.pasteSelection(plainText: true) }
        viewController.onCopyOnlyRequested = { [weak self] in self?.copySelection() }
        viewController.onEditRequested = { [weak self] in self?.editSelection() }
        viewController.onSizeChanged = { [weak self] size in self?.resize(to: size) }
    }

    public func show(reusing reusedPanel: NSPanel? = nil) {
        anchorFrame = reusedPanel?.frame
        session.open()
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
        created.setAccessibilityIdentifier("omni.stash.panel")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onFocusLost = { [weak self] in self?.requestFocusLoss() }
        created.onCopyRequested = nil
        created.onSubmitRequested = { [weak self] in self?.pasteSelection() }
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
        viewController.preview.close()
        panel = nil
        return previous
    }

    public func dismiss() {
        viewController.preview.close()
        session.close()
        panel?.orderOut(nil)
    }

    /// Hides the panel without closing the session, so a paste's return to
    /// the original app does not count as focus loss.
    public func hideForPaste() {
        viewController.preview.close()
        if let panel = panel as? OmniEphemeralPanel { panel.onFocusLost = nil }
        panel?.orderOut(nil)
    }

    public func pasteSelection(plainText: Bool = false) {
        guard let entry = session.selectedRow?.entry else { return }
        if plainText, let onPastePlain { onPastePlain(entry) } else { onPaste?(entry) }
    }

    public func copySelection() {
        guard let entry = session.selectedRow?.entry else { return }
        onCopyOnly?(entry)
    }

    public func editSelection() {
        guard let entry = session.selectedRow?.entry else { return }
        onEdit?(entry)
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
