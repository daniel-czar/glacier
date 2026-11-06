import AppKit
import OmniCore

// MARK: - Renderer-neutral options (decision step, amendment 1.4.0)

/// One row of an options result: a position (`/stance`) or a lens (`/expand`).
public struct OmniPadOption: Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// Something the model noticed; tickable before a pick (D6, step 2).
public struct OmniPadNoticed: Equatable, Sendable {
    public let id: String
    public let label: String
    public let note: String
    public let quote: String?

    public init(id: String, label: String, note: String, quote: String? = nil) {
        self.id = id
        self.label = label
        self.note = note
        self.quote = quote
    }
}

public struct OmniPadOptions: Equatable, Sendable {
    public let heading: String
    public let options: [OmniPadOption]
    public let noticed: [OmniPadNoticed]
    /// The route line while picking, e.g. `Positions · a pick drafts an email`.
    public let summary: String
    /// What Enter says it does: `Draft` when a pick runs a draft at once.
    public let pickVerb: String

    public init(heading: String, options: [OmniPadOption], noticed: [OmniPadNoticed] = [], summary: String, pickVerb: String) {
        self.heading = heading
        // At most seven per list (recognition first); positions arrive
        // capped at four by `StanceResult.parse`, the lenses are five.
        self.options = Array(options.prefix(7))
        self.noticed = Array(noticed.prefix(6))
        self.summary = summary
        self.pickVerb = pickVerb
    }
}

/// A pick runs at once, or returns to composing with the notes attached and
/// the draft token in place ("edit first", ⌥↩ or ⌥-digit).
public enum OmniPadPickGesture: Equatable, Sendable {
    case run
    case editFirst
}

// MARK: - Options result

public extension OmniCommandPadViewController {
    static let tickLetters: [Character] = ["a", "b", "c", "d", "e", "f"]

    /// The run's positions, drawn in the body. Enter or a digit picks, ⌥
    /// edits first, letters tick noticed items, esc closes, ⌘↩ opens the
    /// workspace. The run ID binds every key to the visible run.
    func showOptions(runID: String, options: OmniPadOptions) {
        switch mode {
        case .working(let boundID), .result(let boundID):
            guard boundID == runID else { return }
        case .composing, .suggesting:
            return
        }
        dismissCompletion()
        clearLauncher()
        transientMessage = nil
        mode = .result(runID: runID)
        result = OmniPadResult(kind: .options, body: "", summary: options.summary)
        localOptionsPick = nil
        self.options = options
        optionIndex = 0
        tickedNoticed = []
        clearResultBody()
        rebuildOptions()
        renderFooter()
        view.window?.makeFirstResponder(submittedRequestView)
    }

    @discardableResult
    func moveOption(by delta: Int) -> Bool {
        guard case .result = mode, result?.kind == .options, let count = options?.options.count, count > 0 else { return false }
        optionIndex = (optionIndex + delta + count) % count
        highlightOptions()
        return true
    }

    /// A digit picks and commits at once (D6).
    @discardableResult
    func chooseOption(number: Int, gesture: OmniPadPickGesture) -> Bool {
        guard case .result = mode, result?.kind == .options, let options,
              options.options.indices.contains(number - 1) else { return false }
        optionIndex = number - 1
        highlightOptions()
        return confirmOption(gesture)
    }

    @discardableResult
    func confirmOption(_ gesture: OmniPadPickGesture) -> Bool {
        guard case .result(let runID) = mode, result?.kind == .options, let options,
              options.options.indices.contains(optionIndex) else { return false }
        if let localOptionsPick {
            localOptionsPick(optionIndex, gesture)
            return true
        }
        onPickOption?(runID, optionIndex, tickedNoticed.sorted(), gesture)
        return true
    }

    /// Letters a–f tick noticed items; they are never digits, so a tick can
    /// never be mistaken for a pick.
    @discardableResult
    func toggleNoticed(letter: Character) -> Bool {
        guard case .result = mode, result?.kind == .options, let options,
              let index = Self.tickLetters.firstIndex(of: letter),
              options.noticed.indices.contains(index) else { return false }
        toggleNoticed(index: index)
        return true
    }

    func toggleNoticed(index: Int) {
        guard let options, options.noticed.indices.contains(index) else { return }
        if tickedNoticed.contains(index) { tickedNoticed.remove(index) } else { tickedNoticed.insert(index) }
        for (offset, row) in noticedRows.enumerated() { row.isTicked = tickedNoticed.contains(offset) }
        renderFooter()
    }

    internal var optionsKeyHints: [OmniPadKeyHint] {
        let count = options?.options.count ?? 0
        var hints: [OmniPadKeyHint] = [.init("↩", options?.pickVerb ?? "Pick"), .init(count > 1 ? "1–\(count)" : "1", "")]
        if let noticed = options?.noticed, !noticed.isEmpty {
            hints.append(.init(noticed.count > 1 ? "a–\(Self.tickLetters[noticed.count - 1])" : "a", tickedNoticed.isEmpty ? "Tick" : "\(tickedNoticed.count) ticked"))
        }
        hints.append(.init("⌥↩", "Edit first"))
        hints.append(.init("esc", ""))
        return hints
    }

    internal func highlightOptions() {
        for (index, row) in optionRows.enumerated() { row.isChosen = index == optionIndex }
    }

    internal func rebuildOptions() {
        optionsView?.removeFromSuperview()
        optionRows = []
        noticedRows = []
        guard let options else { return }
        let headingHeight: CGFloat = 22
        let rowHeight = OmniOptionRow.rowHeight
        let noticedHeading: CGFloat = options.noticed.isEmpty ? 0 : 22
        let noticedHeight = OmniNoticedRow.rowHeight * CGFloat(options.noticed.count)
        let height = headingHeight + rowHeight * CGFloat(options.options.count) + noticedHeading + noticedHeight + 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: height))
        container.setAccessibilityIdentifier("omni.pad.options")
        container.autoresizingMask = [.width]
        let heading = NSTextField(labelWithString: options.heading)
        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        heading.textColor = OmniFrostedStyle.secondaryInk
        heading.frame = NSRect(x: 16, y: height - headingHeight + 2, width: view.bounds.width - 32, height: 14)
        container.addSubview(heading)
        var top = height - headingHeight
        for (index, option) in options.options.enumerated() {
            top -= rowHeight
            let row = OmniOptionRow(number: index + 1, option: option) { [weak self] gesture in
                guard let self else { return }
                self.optionIndex = index
                self.highlightOptions()
                self.confirmOption(gesture)
            }
            row.frame = NSRect(x: 12, y: top, width: view.bounds.width - 24, height: rowHeight)
            row.autoresizingMask = [.width]
            row.setAccessibilityIdentifier("omni.pad.option.\(index + 1)")
            row.isChosen = index == optionIndex
            container.addSubview(row)
            optionRows.append(row)
        }
        if !options.noticed.isEmpty {
            top -= noticedHeading
            let subheading = NSTextField(labelWithString: "NOTICED · TICK WHAT THE DRAFT SHOULD HANDLE")
            subheading.font = .systemFont(ofSize: 10, weight: .semibold)
            subheading.textColor = OmniFrostedStyle.annotationRule
            subheading.frame = NSRect(x: 16, y: top + 4, width: view.bounds.width - 32, height: 14)
            container.addSubview(subheading)
            for (index, item) in options.noticed.enumerated() {
                top -= OmniNoticedRow.rowHeight
                let row = OmniNoticedRow(letter: Self.tickLetters[index], item: item) { [weak self] in self?.toggleNoticed(index: index) }
                row.frame = NSRect(x: 12, y: top, width: view.bounds.width - 24, height: OmniNoticedRow.rowHeight)
                row.autoresizingMask = [.width]
                row.setAccessibilityIdentifier("omni.pad.noticed.\(Self.tickLetters[index])")
                row.isTicked = tickedNoticed.contains(index)
                container.addSubview(row)
                noticedRows.append(row)
            }
        }
        view.addSubview(container)
        optionsView = container
        bodyHeight = height
        layoutPad(width: view.bounds.width)
    }
}

// MARK: - Bare `/expand` (milestone 3)

public extension OmniCommandPadViewController {
    /// The local result's binding: never a run ID (those are `oi_…`).
    static let localOptionsRunID = "local.expand"

    var isShowingLocalOptions: Bool { localOptionsPick != nil && mode == .result(runID: Self.localOptionsRunID) }

    /// esc on the lenses: back to composing with the text untouched.
    @discardableResult
    func dismissLocalOptions() -> Bool {
        guard isShowingLocalOptions else { return false }
        returnToComposing()
        showCommandEditor()
        return true
    }
}

extension OmniCommandPadViewController {
    func isBareExpand(_ intent: ParsedIntent) -> Bool {
        intent.dispatchToken == OmniDecisionStep.expandToken
            && intent.tokenValues[OmniDecisionStep.expandToken] == nil
            && intent.primaryTokens.count == 1 && intent.settingsTokens.isEmpty
            && intent.diagnostics.isEmpty
    }

    /// The five fixed lenses as a local options result. Nothing has run.
    func presentExpandLenses() {
        let request = editor.string
        beginWorking(runID: Self.localOptionsRunID, requestText: request, annotations: annotations, summary: OmniPadVocabulary.outcome(for: OmniDecisionStep.expandToken))
        showOptions(runID: Self.localOptionsRunID, options: OmniPadOptions(
            heading: "EXPAND · PICK A LENS",
            options: OmniDecisionStep.expandLenses.map { OmniPadOption(id: $0.id, title: $0.title, detail: $0.detail) },
            summary: "Expansion · pick a lens · nothing has run yet",
            pickVerb: "Expand"
        ))
        localOptionsPick = { [weak self] index, gesture in self?.pickLens(index, gesture: gesture) }
    }

    /// The pick rewrites the visible token to `/expand:<lens>` and runs it,
    /// or (edit first) leaves it in the field.
    func pickLens(_ index: Int, gesture: OmniPadPickGesture) {
        guard OmniDecisionStep.expandLenses.indices.contains(index) else { return }
        let lens = OmniDecisionStep.expandLenses[index]
        returnToComposing()
        applyVisibleRewrite(VisibleRewrite(from: OmniDecisionStep.expandToken, to: "\(OmniDecisionStep.expandToken):\(lens.id)"))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        showCommandEditor()
        if gesture == .run { submit(.enterShowHere) }
    }
}

// MARK: - Offer row (D3)

extension OmniCommandPadViewController {
    /// Material is captured or multi-line text with no token, no `@ref` and
    /// no note (D3). Short single-line bare text stays launcher-first, and
    /// annotated bare text keeps its *Ask for a proposal* route.
    func isOfferMaterial(_ intent: ParsedIntent) -> Bool {
        guard mode == .composing, parser.manifest.command(for: OmniDecisionStep.stanceToken) != nil else { return false }
        let text = editor.string
        guard provenance != nil || text.contains(where: \.isNewline) else { return false }
        guard annotations.isEmpty else { return false }
        // An id is an address, never material (D1): no `/stance` for it.
        guard OmniIDAddress(text) == nil else { return false }
        return isMaterialText(intent)
    }

    /// Text with no command syntax, so Enter has one plain meaning.
    func isMaterialText(_ intent: ParsedIntent) -> Bool {
        let text = editor.string
        guard !intent.isEmpty,
              intent.primaryTokens.isEmpty, intent.settingsTokens.isEmpty, intent.modifiers.isEmpty, intent.modes.isEmpty,
              intent.markers.isEmpty, intent.diagnostics.isEmpty
        else { return false }
        // Only real command syntax disqualifies: a bound or ambiguous @ref, a
        // slash token, or a bare `/` or `@` being typed. Paths in terminal
        // output, `@MainActor` in code and `@here` in Slack are material.
        let commandReference = intent.references.contains {
            switch $0 {
            case .binding, .ambiguous: true
            case .plainText: false
            }
        }
        guard !commandReference else { return false }
        // A bare `/` or `@` is command syntax only while it is being typed,
        // at the caret; "Tue / Wed" or "meet @ 3" elsewhere is material.
        let ns = text as NSString
        let caret = min(editor.selectedRange().location, ns.length)
        let before = ns.substring(to: caret)
        if before.last?.isWhitespace == false,
           let typing = before.split(whereSeparator: \.isWhitespace).last,
           typing == "/" || typing == "@" { return false }
        return !text.split(whereSeparator: \.isWhitespace).contains { SlashAtom.parse(String($0)) != nil }
    }

    public var isOfferRowVisible: Bool { offerRowView != nil }
    public var offerRowTitle: String? { offerRowView?.title }

    /// The route Enter would take: the same material with `/stance`.
    func offerRoute(_ intent: ParsedIntent) -> OmniPadRoute? {
        resolvedRoute(parser.parse(Self.withStance(editor.string)))
    }

    static func withStance(_ text: String) -> String {
        text + (text.last?.isWhitespace == true ? "" : " ") + OmniDecisionStep.stanceToken
    }

    static func offerFooterState(route: OmniPadRoute?, transientMessage: String?) -> OmniPadFooterState {
        var line: OmniPadRouteLine
        var hints: [OmniPadKeyHint] = [.init("↩", "Decide"), .init("⌘↩", "Open in workspace"), .init("esc", "")]
        var enabled = true
        if let unavailable = route?.unavailable {
            line = .attention(unavailable)
            hints = OmniPadKeyHint.dismissOnly
            enabled = false
        } else {
            line = .outcome(OmniPadVocabulary.outcome(for: OmniDecisionStep.stanceToken) + " · or type / for a command")
        }
        if let transientMessage { line = .notice(transientMessage) }
        // Enter always does one visible thing here: it inserts `/stance`.
        return OmniPadFooterState(routeLine: line, keyHints: hints, runEnabled: enabled, submits: true)
    }

    /// Shown in the body while the text is material; it replaces the *Add a
    /// command to this text* hint for that state and never takes the caret.
    func refreshOfferRow(_ parsed: ParsedIntent) {
        let show = isViewLoaded && isOfferMaterial(parsed) && !isCompletionVisible
        guard show else {
            if let row = offerRowView {
                row.removeFromSuperview()
                offerRowView = nil
                if mode == .composing, launcherView == nil { bodyHeight = 0 }
            }
            return
        }
        let title = OmniMaterialSource.offerTitle(appName: provenance?.source)
        if offerRowView?.title != title {
            offerRowView?.removeFromSuperview()
            let row = OmniOfferRow(title: title) { [weak self] gesture in self?.acceptOffer(gesture) }
            row.setAccessibilityIdentifier("omni.pad.offer")
            view.addSubview(row)
            offerRowView = row
        }
        bodyHeight = OmniOfferRow.rowHeight + 8
    }

    /// Inserts `/stance` visibly at the end (spans before it keep their
    /// offsets), then submits through the ordinary path.
    func acceptOffer(_ gesture: OmniSubmitGesture) {
        let ns = editor.string as NSString
        let insertion = (editor.string.last?.isWhitespace == true ? "" : " ") + OmniDecisionStep.stanceToken
        replace(NSRange(location: ns.length, length: 0), with: insertion)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        submit(gesture)
    }
}

// MARK: - Views

/// One position: `1  Decline, keep the door open` over its approach.
@MainActor public final class OmniOptionRow: NSButton {
    public static let rowHeight: CGFloat = 44
    public let option: OmniPadOption
    private let number: Int
    private let handler: (OmniPadPickGesture) -> Void
    var isChosen = false { didSet { if oldValue != isChosen { needsDisplay = true } } }

    init(number: Int, option: OmniPadOption, handler: @escaping (OmniPadPickGesture) -> Void) {
        self.number = number
        self.option = option
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        setAccessibilityLabel("\(number). \(option.title): \(option.detail)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var allowsVibrancy: Bool { false }

    @objc private func invoke() {
        let option = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        handler(option ? .editFirst : .run)
    }

    public override func draw(_ dirtyRect: NSRect) {
        if isChosen {
            OmniFrostedStyle.selectedFill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let numberText = "\(number)" as NSString
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: OmniFrostedStyle.secondaryInk]
        // Buttons draw flipped: title on the first line, approach beneath.
        let titleY: CGFloat = isFlipped ? 5 : bounds.height - 22
        let detailY: CGFloat = isFlipped ? 23 : 6
        numberText.draw(at: NSPoint(x: 9, y: titleY + 2), withAttributes: numberAttributes)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: OmniFrostedStyle.ink, .paragraphStyle: paragraph]
        let detailAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: OmniFrostedStyle.secondaryInk, .paragraphStyle: paragraph]
        let width = max(0, bounds.width - 34)
        (option.title as NSString).draw(in: NSRect(x: 26, y: titleY, width: width, height: 17), withAttributes: titleAttributes)
        (option.detail as NSString).draw(in: NSRect(x: 26, y: detailY, width: width, height: 16), withAttributes: detailAttributes)
    }
}

/// One noticed item: `☐ a  Causal pair — the apology is attached to…`.
@MainActor public final class OmniNoticedRow: NSButton {
    public static let rowHeight: CGFloat = 26
    public let item: OmniPadNoticed
    private let letter: Character
    private let handler: () -> Void
    var isTicked = false { didSet { if oldValue != isTicked { needsDisplay = true; setAccessibilityValue(isTicked ? "ticked" : "not ticked") } } }

    init(letter: Character, item: OmniPadNoticed, handler: @escaping () -> Void) {
        self.letter = letter
        self.item = item
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("\(letter). \(item.label): \(item.note)")
        setAccessibilityValue("not ticked")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var allowsVibrancy: Bool { false }
    @objc private func invoke() { handler() }

    public override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 8, y: (bounds.height - 13) / 2, width: 13, height: 13)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        (isTicked ? OmniFrostedStyle.annotationRule : OmniFrostedStyle.controlFill).setFill()
        path.fill()
        OmniFrostedStyle.annotationRule.setStroke()
        path.lineWidth = 1
        path.stroke()
        if isTicked {
            let check = "✓" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
            let size = check.size(withAttributes: attributes)
            check.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attributes)
        }
        let keyAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: OmniFrostedStyle.secondaryInk]
        let key = String(letter) as NSString
        let keySize = key.size(withAttributes: keyAttributes)
        key.draw(at: NSPoint(x: 28, y: (bounds.height - keySize.height) / 2), withAttributes: keyAttributes)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: item.label, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: OmniFrostedStyle.annotationRule])
        text.append(NSAttributedString(string: " — " + item.note, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: OmniFrostedStyle.ink]))
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        let size = text.size()
        text.draw(in: NSRect(x: 42, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 50), height: size.height))
    }
}

/// `Decide how to respond  /stance  ↩` : the one row material gets (D3).
@MainActor public final class OmniOfferRow: NSButton {
    public static let rowHeight: CGFloat = 30
    private let handler: (OmniSubmitGesture) -> Void

    init(title: String, handler: @escaping (OmniSubmitGesture) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        // The row is a recognition cue, not a focus stop: arrows keep the caret.
        refusesFirstResponder = true
        setAccessibilityLabel("\(title). Press Return to run /stance")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var allowsVibrancy: Bool { false }
    public override var acceptsFirstResponder: Bool { false }

    @objc private func invoke() {
        let command = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        handler(command ? .commandEnterAttach : .enterShowHere)
    }

    public override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.selectedFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 7, yRadius: 7).fill()
        if let icon = NSImage(systemSymbolName: "signpost.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [OmniFrostedStyle.ink]))) {
            icon.draw(in: NSRect(x: 9, y: (bounds.height - 15) / 2, width: 15, height: 15))
        }
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: OmniFrostedStyle.ink]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        (title as NSString).draw(at: NSPoint(x: 32, y: (bounds.height - titleSize.height) / 2), withAttributes: titleAttributes)
        let token = OmniDecisionStep.stanceToken as NSString
        let tokenAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: OmniFrostedStyle.command]
        let tokenSize = token.size(withAttributes: tokenAttributes)
        token.draw(at: NSPoint(x: 32 + titleSize.width + 10, y: (bounds.height - tokenSize.height) / 2), withAttributes: tokenAttributes)
        let badge = NSRect(x: bounds.width - 30, y: (bounds.height - 16) / 2, width: 22, height: 16)
        NSColor.systemGreen.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        let glyph = "↵" as NSString
        let glyphAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
        let glyphSize = glyph.size(withAttributes: glyphAttributes)
        glyph.draw(at: NSPoint(x: badge.midX - glyphSize.width / 2, y: badge.midY - glyphSize.height / 2), withAttributes: glyphAttributes)
    }
}
