import AppKit
import QuickLookUI

@MainActor
public class OmniEphemeralTextView: NSTextView {
    public var onEscape: (() -> Void)?
    var onCopyOutput: (() -> Void)?
    var onCopyAll: (() -> Void)?
    var onMoveExpressSelection: ((Int) -> Bool)?
    public var onSubmit: (() -> Void)?
    var onCopySelected: (() -> Void)?
    var onLarger: (() -> Bool)?
    public var placeholderString: String?
    public var firstLineReservedWidth: CGFloat = 0 {
        didSet { if firstLineReservedWidth != oldValue { needsDisplay = true } }
    }

    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter(OmniPlainPasteboard.isPlainText)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholderString else { return }
        (placeholderString as NSString).draw(
            in: NSRect(x: 0, y: 1, width: max(1, bounds.width - firstLineReservedWidth), height: 44),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 17),
                             .foregroundColor: OmniFrostedStyle.ink.withAlphaComponent(0.38)]
        )
    }

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {
            if hasMarkedText() {
                // Consuming composition here avoids bubbling Escape to the
                // panel's cancelOperation, which would close the whole tool.
                inputContext?.discardMarkedText()
                if hasMarkedText() { unmarkText() }
            } else { onEscape?() }
            return
        }
        if !hasMarkedText(), (event.keyCode == 125 || event.keyCode == 126),
           modifiers.subtracting([.numericPad, .function]).isEmpty,
           onMoveExpressSelection?(event.keyCode == 125 ? 1 : -1) == true { return }
        if !hasMarkedText(), event.keyCode == 49, modifiers.isEmpty, onLarger?() == true { return }
        // Let an input method confirm marked text before treating Return as an action.
        if !hasMarkedText(), (event.keyCode == 36 || event.keyCode == 76),
           modifiers.subtracting([.numericPad, .function]) == [.option],
           let onCopyAll {
            if !event.isARepeat { onCopyAll() }
            return
        }
        if !hasMarkedText(), (event.keyCode == 36 || event.keyCode == 76),
           modifiers.subtracting([.numericPad, .function]).isEmpty {
            if let onSubmit {
                if !event.isARepeat { onSubmit() }
            } else {
                onCopyOutput?()
            }
            return
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" {
            (onCopySelected ?? onCopyOutput)?()
            return
        }
        if performStandardEditingKey(event) { return }
        super.keyDown(with: event)
    }
}

@MainActor
public final class OmniEphemeralViewController: NSViewController, NSTextViewDelegate, OmniDrawnPreviewProviding {
    public static let preferredSize = NSSize(width: OmniPadPlacement.width, height: 106)
    public let editor = OmniEphemeralTextView()
    public let resultTextView = OmniEphemeralTextView()
    /// Only actionable failures/capture notices appear here; no routine status text.
    public let statusLabel = NSTextField(wrappingLabelWithString: "")
    public let routeLabel = NSTextField(labelWithString: "")
    public let copyButton = OmniPadRunButton()
    public let toolPill: OmniToolPillView
    public let expressResultsView = OmniExpressResultsView()
    public let conceptDrawing = OmniConceptLensDrawing()
    public let keyHintsView = OmniKeyHintsView()
    public let provenanceChip = OmniProvenanceChip()
    public private(set) var provenance: OmniPadProvenance?
    public private(set) var pronunciation: OmniPronunciationPresentation?
    public var onCloseRequested: (() -> Void)?
    public var onCopyRequested: (() -> Void)?
    public var onCopyAllRequested: (() -> Void)?
    public var onCopySelectedRequested: (() -> Void)?
    public var onLargerRequested: (() -> Bool)?
    public var onSizeChanged: ((NSSize) -> Void)?
    var maximumHeight: CGFloat = 640

    private let session: OmniEphemeralSession
    let conceptPreview = OmniDrawnPreview()
    var drawnPreview: OmniDrawnPreview { conceptPreview }
    private var isPronunciation: Bool { session.descriptor.resultStyle == .pronunciation }
    private var isExpress: Bool { session.descriptor.resultStyle == .express }
    private var isDrawnConcept: Bool { session.descriptor.resultStyle == .drawnConcept }
    let pronunciationRoute = OmniPronunciationSourceRoute()
    private let inputScroll = NSScrollView()
    private let resultScroll = NSScrollView()
    private let expressResultScroll = NSScrollView()
    private let conceptResultScroll = NSScrollView()
    private let resultSeparator = OmniEphemeralHairline()
    private let footerSeparator = OmniEphemeralHairline()
    private let resultFade = OmniPadResultFade()
    private let wordCountLabel = NSTextField(labelWithString: "")
    private var workingIndicator: OmniPadWorkingIndicator?
    private var activityTask: Task<Void, Never>?
    private var activityInput: String?
    private var lastRenderedOutput = ""
    private var lastRenderedWidth: CGFloat = 0
    private var lastExpressSelectedIndex: Int?
    private var layoutInProgress = false

    public init(session: OmniEphemeralSession) {
        self.session = session
        toolPill = OmniToolPillView(title: session.descriptor.title,
                                   shortcutLabel: session.descriptor.shortcutLabel)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = OmniFrostedSurface(frame: NSRect(origin: .zero, size: Self.preferredSize))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier("omni.ephemeral.\(session.descriptor.id)")
        view = root

        configure(editor, editable: true, identifier: "omni.ephemeral.input")
        editor.font = .systemFont(ofSize: 17)
        editor.placeholderString = session.descriptor.placeholder
        editor.delegate = self
        configure(resultTextView, editable: false, identifier: "omni.ephemeral.result")
        if isExpress { resultTextView.isSelectable = false }
        if isPronunciation {
            resultTextView.isRichText = true
            resultTextView.linkTextAttributes = [.foregroundColor: OmniFrostedStyle.accent, .cursor: NSCursor.pointingHand]
        }
        for textView in [editor, resultTextView] {
            textView.onEscape = { [weak self] in self?.onCloseRequested?() }
            textView.onCopyOutput = { [weak self] in self?.onCopyRequested?() }
            if isExpress { textView.onCopyAll = { [weak self] in self?.onCopyAllRequested?() } }
            textView.onCopySelected = { [weak self] in self?.onCopySelectedRequested?() }
            textView.onLarger = { [weak self] in self?.onLargerRequested?() ?? false }
            textView.onSubmit = { [weak self] in self?.submitOrCopy() }
        }
        if isExpress {
            editor.onMoveExpressSelection = { [weak self] offset in
                guard let self, !self.session.expressOptions.isEmpty,
                      self.session.phase == .streaming || self.session.outputIsCurrent && self.session.phase == .ready else { return false }
                self.session.moveExpressSelection(by: offset)
                return true
            }
        }
        configure(inputScroll, document: editor)
        configure(resultScroll, document: resultTextView)
        configure(expressResultScroll, document: expressResultsView)
        configure(conceptResultScroll, document: conceptDrawing)
        conceptResultScroll.hasHorizontalScroller = true
        expressResultsView.onSelect = { [weak self] index in
            self?.session.selectExpressOption(at: index)
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.editor)
        }
        resultScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resultScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: resultScroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(resultScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: expressResultScroll.contentView)
        conceptResultScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resultScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: conceptResultScroll.contentView)

        provenanceChip.setAccessibilityIdentifier("omni.ephemeral.provenance")
        provenanceChip.usesCompactLabel = true
        provenanceChip.onClear = { [weak self] in self?.dropCapturedSelection() }
        wordCountLabel.font = .systemFont(ofSize: 12)
        wordCountLabel.textColor = OmniFrostedStyle.secondaryInk
        wordCountLabel.alignment = .right
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.setAccessibilityIdentifier("omni.ephemeral.route")
        let summaryRoute = if ["quick-question", "concept-lens", "express"].contains(session.descriptor.id) {
            session.descriptor.routeProviderLabel
        } else { session.descriptor.routeTitle }
        let providerSuffix = summaryRoute == session.descriptor.routeProviderLabel || session.descriptor.routeProviderLabel.isEmpty
            ? "" : " · \(session.descriptor.routeProviderLabel)"
        let route = NSMutableAttributedString(string: summaryRoute,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: OmniFrostedStyle.ink])
        if !providerSuffix.isEmpty {
            route.append(NSAttributedString(string: providerSuffix,
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk]))
        }
        routeLabel.attributedStringValue = route
        statusLabel.font = OmniFrostedStyle.diagnosticFont
        statusLabel.textColor = OmniFrostedStyle.warning
        statusLabel.setAccessibilityIdentifier("omni.ephemeral.status")
        let explicitReplay = session.descriptor.interaction == .explicitReplay
        copyButton.symbolName = explicitReplay ? "speaker.wave.2.fill" : "doc.on.doc"
        if isPronunciation {
            copyButton.symbolName = "speaker.wave.2"
            copyButton.symbolPointSize = 17
        }
        copyButton.setAccessibilityLabel(explicitReplay ? "Pronounce" : "Copy and close")
        copyButton.toolTip = explicitReplay ? "Pronounce the current text" : "Copy and close"
        copyButton.setAccessibilityIdentifier(explicitReplay ? "omni.ephemeral.play" : "omni.ephemeral.copy")
        copyButton.onPress = { [weak self] in
            self?.submitOrCopy()
        }
        resultFade.setAccessibilityIdentifier("omni.ephemeral.result-fade")
        for child in [inputScroll, provenanceChip, wordCountLabel, footerSeparator,
                      statusLabel, routeLabel, keyHintsView, copyButton, toolPill] as [NSView] {
            root.addSubview(child)
        }
        if isPronunciation {
            routeLabel.isHidden = true
            pronunciationRoute.setAccessibilityIdentifier("omni.ephemeral.sources")
            root.addSubview(pronunciationRoute)
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

    public func clearUndoHistory() {
        guard isViewLoaded else { return }
        editor.undoManager?.removeAllActions()
    }

    public func setProvenance(_ value: OmniPadProvenance?) {
        provenance = value
        if isViewLoaded { render() }
    }

    public func dropCapturedSelection() {
        provenance = nil
        session.inputChanged("")
        clearUndoHistory()
        render()
        focusInput()
    }

    public func render() {
        guard isViewLoaded else { return }
        if !session.outputIsCurrent { conceptPreview.close() }
        if !session.isOpen { provenance = nil }
        if editor.string != session.input { editor.string = session.input }
        editor.needsDisplay = true
        provenanceChip.provenance = provenance
        provenanceChip.isHidden = provenance == nil
        wordCountLabel.isHidden = provenance == nil
        let words = session.input.split(whereSeparator: \.isWhitespace).count
        wordCountLabel.stringValue = "\(words) \(words == 1 ? "word" : "words")"

        let output = session.output
        let resultWidth = max(1, view.bounds.width - 36)
        if isDrawnConcept {
            conceptDrawing.display(session.conceptLens?.map)
            conceptDrawing.alphaValue = session.outputIsCurrent ? 1 : 0.42
            resultTextView.textStorage?.setAttributedString(OmniEphemeralResultRenderer.attributed(
                session.conceptLens?.map == nil ? session.conceptLens?.text ?? "" : "", style: .structured))
        } else if isExpress {
            expressResultsView.display(options: session.expressOptions,
                selectedIndex: session.selectedExpressIndex,
                dimmed: !session.outputIsCurrent && session.phase != .streaming)
        } else if output != lastRenderedOutput || isPronunciation && resultWidth != lastRenderedWidth {
            let replacesOld = session.phase == .streaming && !lastRenderedOutput.isEmpty
                && !output.hasPrefix(lastRenderedOutput)
            if isPronunciation {
                pronunciation = OmniPronunciationPresentation.decode(output)
                resultTextView.textStorage?.setAttributedString(pronunciation.map {
                    OmniPronunciationResultRenderer.attributed($0, width: resultWidth)
                } ?? NSAttributedString(string: ""))
            } else {
                resultTextView.textStorage?.setAttributedString(
                    OmniEphemeralResultRenderer.attributed(output, style: session.descriptor.resultStyle))
            }
            if replacesOld || output.isEmpty { resultScroll.contentView.scroll(to: .zero) }
            lastRenderedOutput = output
            lastRenderedWidth = resultWidth
        }
        let hasDrawing = isDrawnConcept && session.conceptLens?.map != nil
        let hasResults = hasDrawing || (isExpress ? !session.expressOptions.isEmpty : !resultTextView.string.isEmpty)
        if !hasResults {
            resultScroll.removeFromSuperview()
            expressResultScroll.removeFromSuperview()
            conceptResultScroll.removeFromSuperview()
            resultSeparator.removeFromSuperview()
            resultFade.removeFromSuperview()
        } else {
            let activeScroll = hasDrawing ? conceptResultScroll : isExpress ? expressResultScroll : resultScroll
            for scroll in [resultScroll, expressResultScroll, conceptResultScroll] where scroll !== activeScroll {
                scroll.removeFromSuperview()
            }
            if resultSeparator.superview == nil { view.addSubview(resultSeparator) }
            if activeScroll.superview == nil { view.addSubview(activeScroll) }
            if resultFade.superview == nil { view.addSubview(resultFade) }
        }
        resultTextView.alphaValue = session.outputIsCurrent || session.phase == .streaming ? 1 : 0.42
        let explicitReplay = session.descriptor.interaction == .explicitReplay
        let generate = session.isManualMode && session.canSubmit
        copyButton.isEnabled = explicitReplay ? session.canSubmit
            : generate || session.copyableOutput != nil
        if !explicitReplay {
            copyButton.symbolName = generate ? "sparkles" : "doc.on.doc"
            copyButton.setAccessibilityLabel(generate ? "Generate result" : "Copy and close")
            copyButton.toolTip = generate ? "Generate from the current text" : "Copy and close"
        }
        if isPronunciation {
            let current = session.outputIsCurrent || session.phase == .streaming
            let hasAudio = current && pronunciation?.attribution != nil
            let playing = current && session.phase == .streaming && pronunciation?.isPlaying == true
            copyButton.isEnabled = hasAudio && session.canSubmit
            copyButton.isSymbolAnimating = playing
            copyButton.setAccessibilityLabel(playing ? "Playing; replay" : "Replay pronunciation")
            copyButton.toolTip = hasAudio ? "Replay this pronunciation" : "Replay unavailable until audio exists"
            keyHintsView.hints = (hasAudio ? [.init("↩", "Replay")] : [])
                + [.init("esc", playing ? "Stop and close" : "Close")]
            let sources = current ? pronunciation?.sources ?? [] : []
            routeLabel.stringValue = sources.isEmpty ? "Sources" : sources.map(\.name).joined(separator: " · ")
            pronunciationRoute.setSources(sources)
        } else if isExpress {
            copyButton.setAccessibilityLabel(generate ? "Generate alternatives" : "Copy selected wording and close")
            copyButton.toolTip = generate ? "Generate alternatives from the current text" : "Copy selected wording and close"
            keyHintsView.hints = (session.expressOptions.isEmpty ? [] : [.init("↑↓", "Choose")])
                + [.init("↩", generate ? "Generate" : "Copy")]
                + [.init("⌥↩", "Copy all")]
                + [.init("esc", "Close")]
        } else if explicitReplay {
            copyButton.setAccessibilityLabel(session.outputIsCurrent ? "Replay pronunciation" : "Pronounce")
            copyButton.toolTip = session.outputIsCurrent ? "Replay this pronunciation" : "Pronounce the current text"
            keyHintsView.hints = [.init("↩", session.outputIsCurrent ? "Replay" : "Pronounce"),
                                  .init("esc", "Stop and close")]
        } else {
            keyHintsView.hints = (copyButton.isEnabled ? [.init("↩", generate ? "Generate" : "Copy and close")] : [])
                + (hasDrawing && session.outputIsCurrent ? [.init("␣", "Larger")] : []) + [.init("esc", "Close")]
        }
        if isDrawnConcept {
            let reason = session.outputIsCurrent ? session.conceptLens?.failureReason : nil
            let route = NSMutableAttributedString(string: "", attributes: [:])
            if reason != nil {
                route.append(NSAttributedString(string: "● ", attributes: [
                    .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.systemRed, .baselineOffset: 2,
                ]))
            }
            route.append(NSAttributedString(string: session.descriptor.routeProviderLabel, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: OmniFrostedStyle.ink,
            ]))
            routeLabel.attributedStringValue = route
            routeLabel.toolTip = reason
            routeLabel.setAccessibilityLabel(reason.map { session.descriptor.routeProviderLabel + ": " + $0 })
        }
        copyButton.needsDisplay = true
        statusLabel.stringValue = if case .failed(let message) = session.phase { message } else { session.notice ?? "" }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        updateActivity()
        layoutControls()
        if isExpress, let index = session.selectedExpressIndex,
           index != lastExpressSelectedIndex,
           expressResultsView.rowViews.indices.contains(index) {
            var visibleRow = expressResultsView.rowViews[index].frame
            if index == expressResultsView.rowViews.count - 1 { visibleRow.size.height += 8 }
            expressResultScroll.contentView.scrollToVisible(visibleRow)
            updateFade()
        }
        lastExpressSelectedIndex = session.selectedExpressIndex
    }

    func submitOrCopy() {
        if session.canSubmit { session.submit() }
        else { onCopyRequested?() }
    }

    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === editor else { return }
        session.inputChanged(editor.string)
    }

    private func updateActivity() {
        if isPronunciation {
            activityTask?.cancel()
            activityTask = nil
            // Lookup has no body copy. Playback is shown only on the speaker.
            let waitingForAudio = session.phase == .streaming
                && pronunciation?.transcriptions.isEmpty == true && pronunciation?.attribution == nil
            setWorking(session.isOpen && (session.phase == .waiting || waitingForAudio))
            return
        }
        guard session.isOpen, session.phase == .waiting || session.phase == .streaming else {
            activityTask?.cancel()
            activityTask = nil
            activityInput = nil
            setWorking(false)
            return
        }
        if session.phase == .streaming {
            activityTask?.cancel()
            activityTask = nil
            setWorking(true)
        } else if activityInput != session.input {
            activityTask?.cancel()
            activityInput = session.input
            setWorking(false)
            let delay = session.descriptor.debounce
            activityTask = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, let self, self.session.isOpen,
                      self.session.phase == .waiting || self.session.phase == .streaming else { return }
                self.setWorking(true)
                self.layoutControls()
            }
        }
    }

    private func setWorking(_ working: Bool) {
        if working, workingIndicator == nil {
            let indicator = OmniPadWorkingIndicator(frame: .zero)
            indicator.setAccessibilityIdentifier("omni.ephemeral.working")
            view.addSubview(indicator)
            workingIndicator = indicator
        } else if !working {
            workingIndicator?.stop()
            workingIndicator?.removeFromSuperview()
            workingIndicator = nil
        }
    }

    private func configure(_ textView: OmniEphemeralTextView, editable: Bool, identifier: String) {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = OmniFrostedStyle.ink
        textView.insertionPointColor = OmniFrostedStyle.accent
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier(identifier)
    }

    private func configure(_ scroll: NSScrollView, document: NSView) {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
    }

    private func textHeight(_ textView: NSTextView, width: CGFloat) -> CGFloat {
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return 24 }
        manager.ensureLayout(for: container)
        return max(24, ceil(manager.usedRect(for: container).height))
    }

    private func layoutControls() {
        guard isViewLoaded, !layoutInProgress else { return }
        layoutInProgress = true
        defer { layoutInProgress = false }
        let width = view.bounds.width
        let contentWidth = max(1, width - 36)
        OmniToolPillLayout.reserveFirstLine(beside: editor, pill: toolPill, fieldWidth: contentWidth)
        if isExpress { expressResultsView.arrange(width: contentWidth) }
        if isPronunciation, let pronunciation, contentWidth != lastRenderedWidth {
            resultTextView.textStorage?.setAttributedString(OmniPronunciationResultRenderer.attributed(pronunciation, width: contentWidth))
            lastRenderedWidth = contentWidth
        }
        let inputTextHeight = textHeight(editor, width: contentWidth)
        let inputHeight = min(130, inputTextHeight) + 26
        let hasDrawing = isDrawnConcept && session.conceptLens?.map != nil
        let resultTextHeight = hasDrawing ? conceptDrawing.arrange(width: contentWidth)
            : isExpress ? expressResultsView.contentHeight : textHeight(resultTextView, width: contentWidth)
        let chipHeight: CGFloat = provenance == nil ? 0 : 38
        let noticeHeight: CGFloat = statusLabel.isHidden ? 0 : ceil(statusLabel.sizeThatFits(NSSize(width: contentWidth, height: 200)).height) + 12
        let narrow = width < 540 || isPronunciation
            && pronunciationRoute.fittingWidth + keyHintsView.fittingWidth + 86 > width
        let routeHeight = isPronunciation ? pronunciationRoute.arrange(width: contentWidth, apply: false) : 18
        let hintWidth = min(keyHintsView.fittingWidth, max(1, width - 74))
        let hintsHeight = isExpress ? max(30, keyHintsView.fittingHeight(forWidth: hintWidth)) : 30
        let hintExtra = hintsHeight - 30
        let footerHeight: CGFloat = (narrow ? 62 + routeHeight : 54) + hintExtra
        let resultBudget = max(24, maximumHeight - chipHeight - inputHeight - noticeHeight - footerHeight - 30)
        let hasResults = hasDrawing || (isExpress ? !session.expressOptions.isEmpty : !resultTextView.string.isEmpty)
        let resultHeight = hasResults ? min(hasDrawing ? 480 : 320, resultBudget, resultTextHeight) + 30 : 0
        let height = chipHeight + inputHeight + resultHeight + noticeHeight + footerHeight
        if abs(view.bounds.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
            onSizeChanged?(view.frame.size)
        }
        provenanceChip.frame = NSRect(x: 16, y: height - 38, width: min(max(1, width - 124), provenanceChip.fittingWidth), height: 26)
        wordCountLabel.frame = NSRect(x: width - 100, y: height - 34, width: 82, height: 18)
        inputScroll.frame = NSRect(x: 18, y: height - chipHeight - inputHeight + 14, width: contentWidth, height: inputHeight - 26)
        editor.frame.size = NSSize(width: contentWidth, height: max(inputTextHeight, inputScroll.contentSize.height))
        OmniToolPillLayout.place(toolPill, beside: editor, in: inputScroll.frame)
        let resultTop = height - chipHeight - inputHeight
        resultSeparator.frame = NSRect(x: 0, y: resultTop, width: width, height: OmniFrostedStyle.hairlineWidth)
        resultScroll.frame = NSRect(x: 18, y: resultTop - resultHeight + 16, width: contentWidth, height: max(0, resultHeight - 30))
        expressResultScroll.frame = resultScroll.frame
        conceptResultScroll.frame = resultScroll.frame
        resultTextView.frame.size = NSSize(width: contentWidth, height: max(resultTextHeight, resultScroll.contentSize.height))
        if isExpress { expressResultsView.frame.size.height = max(resultTextHeight, expressResultScroll.contentSize.height) }
        resultFade.frame = NSRect(x: 18, y: resultScroll.frame.minY, width: contentWidth, height: 20)
        statusLabel.frame = NSRect(x: 18, y: footerHeight + 6, width: contentWidth, height: max(0, noticeHeight - 12))
        footerSeparator.frame = NSRect(x: 0, y: footerHeight, width: width, height: OmniFrostedStyle.hairlineWidth)
        copyButton.frame = NSRect(x: width - 44, y: 11, width: 32, height: 32)
        let hintRight = copyButton.frame.minX
        keyHintsView.frame = NSRect(x: hintRight - 12 - hintWidth, y: 12, width: hintWidth, height: hintsHeight)
        let routeY: CGFloat = narrow ? 51 + hintExtra : 19
        let routeX: CGFloat = workingIndicator == nil ? 18 : 42
        routeLabel.frame = NSRect(x: routeX, y: routeY, width: max(1, (narrow ? width - 18 : keyHintsView.frame.minX - 12) - routeX), height: 18)
        if isPronunciation {
            pronunciationRoute.frame = NSRect(x: routeX, y: routeY, width: routeLabel.frame.width, height: routeHeight)
            pronunciationRoute.arrange(width: routeLabel.frame.width, apply: true)
        }
        workingIndicator?.frame = NSRect(x: 16, y: routeY, width: 24, height: 18)
        updateFade()
    }

    @objc private func resultScrolled(_ notification: Notification) { updateFade() }

    private func updateFade() {
        resultFade.isHidden = isDrawnConcept && session.conceptLens?.map != nil
            ? conceptDrawing.frame.height <= conceptResultScroll.contentView.bounds.maxY + 1 : isExpress
            ? expressResultsView.frame.height <= expressResultScroll.contentView.bounds.maxY + 1
            : resultTextView.frame.height <= resultScroll.contentView.bounds.maxY + 1
    }
}

@MainActor private final class OmniEphemeralHairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.controlLine.setFill()
        bounds.fill()
    }
}

@MainActor
final class OmniEphemeralPanel: NSPanel {
    // The panel supplies a stable owner across field/result responders.
    // Quick Look's responder-chain callbacks run on the main thread.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { (contentViewController as? any OmniDrawnPreviewProviding)?.drawnPreview.url != nil }
    }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { (contentViewController as? any OmniDrawnPreviewProviding)?.drawnPreview.beginControl(panel) }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { (contentViewController as? any OmniDrawnPreviewProviding)?.drawnPreview.endControl(panel) }
    }
    var onCloseRequested: (() -> Void)?
    var onFocusLost: (() -> Void)?
    var onCopyRequested: (() -> Void)?
    var onCopyAllRequested: (() -> Void)?
    var onCopySelectedRequested: (() -> Void)?
    var onSubmitRequested: (() -> Void)?
    var onMoveExpressSelection: ((Int) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCloseRequested?() }
    override func performClose(_ sender: Any?) { onCloseRequested?() }
    override func resignKey() { super.resignKey(); onFocusLost?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCloseRequested?(); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasMarkedText = (firstResponder as? NSTextView)?.hasMarkedText() == true
        if !hasMarkedText, (event.keyCode == 36 || event.keyCode == 76),
           modifiers.subtracting([.numericPad, .function]) == [.option],
           let onCopyAllRequested {
            if !event.isARepeat { onCopyAllRequested() }
            return
        }
        if !hasMarkedText, modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "c",
           let onCopySelectedRequested {
            if !event.isARepeat { onCopySelectedRequested() }
            return
        }
        if (event.keyCode == 125 || event.keyCode == 126),
           modifiers.subtracting([.numericPad, .function]).isEmpty,
           onMoveExpressSelection?(event.keyCode == 125 ? 1 : -1) == true { return }
        if !hasMarkedText, (event.keyCode == 36 || event.keyCode == 76),
           modifiers.subtracting([.numericPad, .function]).isEmpty {
            if let onSubmitRequested {
                if !event.isARepeat { onSubmitRequested() }
            } else {
                onCopyRequested?()
            }
            return
        }
        super.keyDown(with: event)
    }
}

/// A disposable floating shell; the host retains capture, clipboard and focus ownership.
@MainActor
public final class OmniEphemeralWindowController {
    public let session: OmniEphemeralSession
    public let viewController: OmniEphemeralViewController
    public private(set) var panel: NSPanel?
    public var onCloseRequested: (() -> Void)?
    public var onFocusLost: (() -> Void)?
    public var onCopy: ((String) -> Void)?
    /// Drawn tools write exactly one item, retaining both representations.
    public var writePasteboardItem: (NSPasteboardItem) -> Bool = { item in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
    private let presentsInterface: Bool
    private var anchorFrame: NSRect?

    public var isVisible: Bool { presentsInterface ? panel?.isVisible == true : session.isOpen }

    public init(descriptor: OmniEphemeralToolDescriptor, producer: @escaping OmniEphemeralProducer,
                presentsInterface: Bool = true,
                automaticRequestsEnabled: @escaping @MainActor () -> Bool = { true }) {
        session = OmniEphemeralSession(descriptor: descriptor, producer: producer,
                                       automaticRequestsEnabled: automaticRequestsEnabled)
        viewController = OmniEphemeralViewController(session: session)
        self.presentsInterface = presentsInterface
        session.onChange = { [weak viewController] in viewController?.render() }
        viewController.onCloseRequested = { [weak self] in self?.requestClose() }
        viewController.onCopyRequested = { [weak self] in self?.copyCurrentOutput() }
        viewController.onCopyAllRequested = { [weak self] in self?.copyAllExpressOptions() }
        viewController.onCopySelectedRequested = { [weak self] in self?.copyCurrentOutput() }
        viewController.onLargerRequested = { [weak self] in self?.showLarger() ?? false }
        viewController.conceptPreview.onReturnToTool = { [weak self] in
            guard let self, self.session.isOpen else { return }
            if self.presentsInterface { self.panel?.makeKeyAndOrderFront(nil); self.viewController.focusInput() }
        }
        viewController.onSizeChanged = { [weak self] size in self?.resize(to: size) }
    }

    public func show(input: String, notice: String? = nil, provenance: OmniPadProvenance? = nil, reusing reusedPanel: NSPanel? = nil, submitImmediately: Bool = false) {
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
        let created = (reusedPanel as? OmniEphemeralPanel) ?? (panel as? OmniEphemeralPanel) ?? OmniEphemeralPanel(
            contentRect: OmniPadPlacement.frame(size: size, visibleFrame: visibleFrame),
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
        created.setAccessibilityIdentifier("omni.ephemeral.panel.\(session.descriptor.id)")
        created.onCloseRequested = { [weak self] in self?.requestClose() }
        created.onFocusLost = { [weak self] in self?.requestFocusLoss() }
        created.onCopyRequested = { [weak self] in self?.copyCurrentOutput() }
        created.onCopyAllRequested = session.descriptor.resultStyle == .express ? { [weak self] in self?.copyAllExpressOptions() } : nil
        created.onCopySelectedRequested = session.descriptor.resultStyle == .express ? { [weak self] in self?.copyCurrentOutput() } : nil
        created.onSubmitRequested = { [weak self] in self?.viewController.submitOrCopy() }
        created.onMoveExpressSelection = session.descriptor.resultStyle == .express ? { [weak self] offset in
            guard let self, !self.session.expressOptions.isEmpty,
                  self.session.phase == .streaming || self.session.outputIsCurrent && self.session.phase == .ready else { return false }
            self.session.moveExpressSelection(by: offset)
            return true
        } : nil
        panel = created
        if anchorFrame == nil { anchorFrame = OmniPadPlacement.frame(size: size, visibleFrame: visibleFrame) }
        resize(to: size)
        if submitImmediately { session.submit() }
        guard presentsInterface else { return }
        created.makeKeyAndOrderFront(nil)
        viewController.focusInput()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Transfer only window chrome. The old session still closes/cancels normally.
    public func relinquishPanelForReplacement() -> NSPanel? {
        let previous = panel
        if let previous = previous as? OmniEphemeralPanel {
            previous.onCloseRequested = nil
            previous.onFocusLost = nil
            previous.onCopyRequested = nil
            previous.onCopyAllRequested = nil
            previous.onCopySelectedRequested = nil
            previous.onSubmitRequested = nil
            previous.onMoveExpressSelection = nil
        }
        panel = nil
        return previous
    }

    public func dismiss() {
        viewController.conceptPreview.close()
        session.close()
        viewController.clearUndoHistory()
        panel?.orderOut(nil)
    }

    public func copyCurrentOutput() {
        guard let output = session.copyableOutput else { return }
        if session.descriptor.resultStyle == .drawnConcept, let map = session.conceptLens?.map {
            guard let item = OmniConceptLensCopyComposer.item(map: map, text: output), writePasteboardItem(item) else { return }
            requestClose()
            return
        }
        // Fallback text stays exactly as received; ordinary selected-text
        // Cmd-C is handled directly by the native result text view.
        onCopy?(session.descriptor.resultStyle == .pronunciation ? viewController.resultTextView.string : output)
        if session.descriptor.interaction == .liveCopy { requestClose() }
    }

    /// Returns false when Space should remain ordinary input (empty, pending, fallback).
    @discardableResult
    public func showLarger() -> Bool {
        guard session.descriptor.resultStyle == .drawnConcept,
              session.copyableOutput != nil, let map = session.conceptLens?.map,
              let png = OmniConceptLensCopyComposer.png(map) else { return false }
        let preview = viewController.conceptPreview
        if preview.isPresenting { preview.close(); return true }
        do { try preview.prepare(png) } catch { return false }
        guard presentsInterface else { return true }
        guard let panel = QLPreviewPanel.shared() else { preview.close(); return false }
        // Ordering the shared panel starts its responder-chain ownership handshake.
        panel.makeKeyAndOrderFront(nil)
        panel.updateController()
        guard panel.currentController as AnyObject? === self.panel else { preview.close(); return false }
        panel.reloadData()
        return true
    }

    public func copyAllExpressOptions() {
        guard let result = session.copyableExpressResult else { return }
        onCopy?(OmniExpressProjection.formatAll(result))
        requestClose()
    }

    private func resize(to size: NSSize) {
        guard let panel, let anchorFrame else { return }
        panel.setFrame(NSRect(x: anchorFrame.midX - size.width / 2, y: anchorFrame.maxY - size.height,
                              width: size.width, height: size.height), display: true, animate: false)
    }

    private func requestClose() {
        if viewController.conceptPreview.isPresenting {
            viewController.conceptPreview.close()
            return
        }
        if let onCloseRequested { onCloseRequested() } else { dismiss() }
    }

    private func requestFocusLoss() {
        guard session.isOpen else { return }
        guard !viewController.conceptPreview.isPresenting else { return }
        if let onFocusLost { onFocusLost() } else { dismiss() }
    }

    private static func targetVisibleFrame() -> NSRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
