import AppKit
import OmniCore

/// Drawn over text after token styling. This leaves every token's fill and
/// foreground attributes intact, including alias-expanded tokens.
@MainActor enum OmniAnnotationHighlight {
    static func draw(_ notes: [OmniTextAnnotation], activeID: UUID?, in view: NSTextView, dirtyRect: NSRect) {
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        let length = (view.string as NSString).length
        for note in notes where note.range.length > 0 && note.range.upperBound <= length {
            let glyphs = layout.glyphRange(forCharacterRange: note.range, actualCharacterRange: nil)
            layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                let intersection = NSIntersectionRange(glyphs, lineGlyphs)
                guard intersection.length > 0 else { return }
                var rect = layout.boundingRect(forGlyphRange: intersection, in: container)
                rect.origin.x += view.textContainerOrigin.x
                rect.origin.y += view.textContainerOrigin.y
                guard rect.intersects(dirtyRect) else { return }
                let active = note.id == activeID
                (active ? OmniFrostedStyle.annotationActiveFill : OmniFrostedStyle.annotationFill).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
                OmniFrostedStyle.annotationRule.setFill()
                NSRect(x: rect.minX, y: rect.maxY - 1.5, width: rect.width, height: 1.5).fill()
            }
        }
    }
}

@MainActor final class OmniAnnotationUI: NSObject, NSWindowDelegate {
    weak var editor: OmniCommandTextView?
    var onNotice: ((String) -> Void)?
    var onChanged: (() -> Void)?
    private var mark: OmniAnnotationMark?
    private(set) var card: NSPanel?
    private(set) var hover: NSPanel?
    private(set) var overview: NSPanel?
    private var field: OmniAnnotationField?
    private var editingID: UUID?
    private var pendingRange: NSRange?
    private var hoveredID: UUID?
    private var overviewEventMonitor: Any?
    private var cardEventMonitor: Any?

    init(editor: OmniCommandTextView) {
        self.editor = editor
        super.init()
        editor.onAnnotationShortcut = { [weak self] in self?.openForSelection() }
        editor.onAnnotationHover = { [weak self] id in self?.hoverAnnotation(id) }
        editor.window?.acceptsMouseMovedEvents = true
    }

    func changed() {
        if let editingID, editor?.annotations.contains(where: { $0.id == editingID }) != true { closeCard() }
        if let hoveredID, editor?.annotations.contains(where: { $0.id == hoveredID }) != true { closeHover() }
        updateMark()
        onChanged?()
    }

    func updateMark() {
        guard let editor, editor.isEditable, editor.selectedRange().length > 0 else {
            mark?.removeFromSuperview()
            mark = nil
            return
        }
        let selection = editor.selectedRange()
        let endCharacter = NSRange(location: selection.upperBound - 1, length: 1)
        let anchor = editor.firstRect(forCharacterRange: endCharacter, actualRange: nil)
        guard anchor != .zero else { mark?.removeFromSuperview(); mark = nil; return }
        if mark == nil {
            let button = OmniAnnotationMark()
            button.onPress = { [weak self] in self?.openForSelection() }
            editor.addSubview(button)
            mark = button
        }
        let windowPoint = editor.window?.convertPoint(fromScreen: NSPoint(x: anchor.maxX, y: anchor.minY)) ?? .zero
        let point = editor.convert(windowPoint, from: nil)
        mark?.frame = NSRect(x: point.x + 3, y: point.y - 8, width: 18, height: 18)
    }

    func openForSelection() {
        guard let editor else { return }
        editor.reconcileAnnotations()
        let range = editor.selectedRange()
        guard range.length > 0 else { onNotice?("Select text to annotate"); return }
        let overlap = editor.annotations.filter { NSIntersectionRange($0.range, range).length > 0 }
        if overlap.count == 1, overlap[0].range == range {
            openCard(range: range, editing: overlap[0])
        } else if !overlap.isEmpty {
            onNotice?("Select text without an existing note")
        } else {
            openCard(range: range, editing: nil)
        }
    }

    func showHover(_ id: UUID?) { hoverAnnotation(id) }

    func openCard(range: NSRange, editing: OmniTextAnnotation?) {
        guard let editor else { return }
        closeHover()
        closeOverview()
        closeCard()
        pendingRange = range
        editingID = editing?.id
        let width: CGFloat = 414
        let height: CGFloat = 118
        let panel = makePanel(size: NSSize(width: width, height: height), identifier: "omni.annotation.card")
        let root = panel.contentView!
        let heading = label("GUIDANCE · NOT IN THE OUTPUT", size: 10, weight: .semibold, color: OmniFrostedStyle.annotationRule)
        heading.frame = NSRect(x: 14, y: 88, width: width - 42, height: 16)
        root.addSubview(heading)
        let close = iconButton("×", id: "omni.annotation.cancel") { [weak self] in self?.closeCard(restoreFocus: true) }
        close.frame = NSRect(x: width - 30, y: 84, width: 22, height: 22)
        root.addSubview(close)
        let input = OmniAnnotationField(frame: NSRect(x: 14, y: 46, width: width - 28, height: 32))
        input.stringValue = editing?.guidance ?? ""
        input.placeholderString = "What should the model do with this part?"
        input.font = .systemFont(ofSize: 13)
        input.bezelStyle = .roundedBezel
        input.onAttach = { [weak self] in self?.attachCurrent() }
        input.onCancel = { [weak self] in self?.closeCard(restoreFocus: true) }
        root.addSubview(input)
        field = input
        let hint = label("↩ attach · esc cancel", size: 11, weight: .regular, color: OmniFrostedStyle.secondaryInk)
        hint.frame = NSRect(x: 14, y: 13, width: width - 28, height: 18)
        root.addSubview(hint)
        card = panel
        present(panel, above: range, in: editor)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        cardEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            if event.windowNumber != panel?.windowNumber { self?.closeCard() }
            return event
        }
    }

    private func attachCurrent() {
        guard let editor, let range = pendingRange, let field else { return }
        let guidance = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guidance.isEmpty else { NSSound.beep(); return }
        var value = editor.annotations
        if let editingID, let index = value.firstIndex(where: { $0.id == editingID }) {
            value[index] = value[index].editedByUser(guidance: guidance)
        } else {
            value.append(OmniTextAnnotation(range: range, guidance: guidance))
        }
        editor.changeAnnotations(value)
        closeCard(restoreFocus: true)
        changed()
    }

    func remove(_ id: UUID) {
        guard let editor else { return }
        editor.changeAnnotations(editor.annotations.filter { $0.id != id })
        closeHover()
        if overview != nil { openOverview(anchor: nil) }
        changed()
    }

    func openOverview(anchor: NSView?) {
        guard let editor, !editor.annotations.isEmpty else { closeOverview(); return }
        closeCard()
        closeHover()
        closeOverview()
        let notes = Self.overviewOrder(editor.annotations)
        let width: CGFloat = 420
        let rowWidth = width - 14
        let textWidth = rowWidth - 82 // a dedicated edit/remove column
        let source = editor.string as NSString
        let rows = notes.map { note -> (note: OmniTextAnnotation, snippet: String, height: CGFloat) in
            let snippet = Self.overviewSnippet(note, source: source)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let guidanceHeight = ceil((note.guidance as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph],
                context: nil
            ).height)
            return (note, snippet, max(78, guidanceHeight + 42))
        }
        let listHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
        let height = min(440, 34 + listHeight + 10)
        let panel = makePanel(size: NSSize(width: width, height: height), identifier: "omni.annotation.overview")
        let root = panel.contentView!
        let heading = label(notes.contains(where: \.isRequestScoped) ? "NOTES · WHOLE REQUEST, THEN TEXT ORDER" : "NOTES · IN TEXT ORDER", size: 10, weight: .semibold, color: OmniFrostedStyle.annotationRule)
        heading.frame = NSRect(x: 14, y: height - 27, width: width - 28, height: 16)
        root.addSubview(heading)
        let scroll = NSScrollView(frame: NSRect(x: 7, y: 9, width: width - 14, height: height - 43))
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = listHeight > scroll.frame.height
        scroll.autohidesScrollers = true
        let rowsView = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: listHeight))
        scroll.documentView = rowsView
        root.addSubview(scroll)
        var top = listHeight
        for (index, item) in rows.enumerated() {
            let note = item.note
            top -= item.height
            let row = OmniAnnotationOverviewRow(frame: NSRect(x: 0, y: top, width: rowWidth, height: item.height - 3))
            row.setAccessibilityIdentifier("omni.annotation.overview-row.\(index)")
            row.onHover = { [weak self] active in self?.editor?.activeAnnotationID = active ? note.id : nil }
            let quoted = label(item.snippet, size: 11, weight: .medium, color: OmniFrostedStyle.annotationRule)
            quoted.lineBreakMode = .byTruncatingTail
            quoted.frame = NSRect(x: 10, y: row.bounds.height - 26, width: textWidth, height: 18)
            row.addSubview(quoted)
            let guidance = label(note.guidance, size: 12, weight: .regular, color: OmniFrostedStyle.ink)
            guidance.lineBreakMode = .byWordWrapping
            guidance.usesSingleLineMode = false
            guidance.maximumNumberOfLines = 0
            guidance.frame = NSRect(x: 10, y: 9, width: textWidth, height: row.bounds.height - 37)
            row.addSubview(guidance)
            let edit = iconButton("✎", id: "omni.annotation.edit.\(index)") { [weak self] in
                self?.editor?.setSelectedRange(note.range)
                self?.openCard(range: note.range, editing: note)
            }
            edit.setAccessibilityLabel("Edit guidance \(index + 1)")
            edit.frame = NSRect(x: row.bounds.width - 64, y: (row.bounds.height - 26) / 2, width: 26, height: 26)
            edit.title = ""
            row.addSubview(edit)
            let editGlyph = OmniAnnotationGlyph(symbol: "✎")
            editGlyph.frame = edit.frame
            row.addSubview(editGlyph)
            let remove = iconButton("×", id: "omni.annotation.remove.\(index)") { [weak self] in self?.remove(note.id) }
            remove.setAccessibilityLabel("Remove guidance \(index + 1)")
            remove.frame = NSRect(x: row.bounds.width - 34, y: (row.bounds.height - 26) / 2, width: 26, height: 26)
            remove.title = ""
            row.addSubview(remove)
            let removeGlyph = OmniAnnotationGlyph(symbol: "×")
            removeGlyph.frame = remove.frame
            row.addSubview(removeGlyph)
            rowsView.addSubview(row)
        }
        // The document view is not flipped: its highest-y row is the first
        // annotation, so an overflowing list must begin at the top origin.
        if listHeight > scroll.contentView.bounds.height {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: listHeight - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        overview = panel
        let frame = anchor?.window?.convertToScreen(anchor!.convert(anchor!.bounds, to: nil)) ?? editor.firstRect(forCharacterRange: notes[0].range, actualRange: nil)
        let origin = NSPoint(x: frame.minX, y: frame.maxY + 8)
        panel.setFrameOrigin(clamp(origin, panel: panel, near: editor.window))
        panel.orderFrontRegardless()
        overviewEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak panel] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.closeOverview()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown,
               event.windowNumber != panel?.windowNumber {
                self.closeOverview()
            }
            return event
        }
    }

    /// Request notes first, in their given order, then span notes in text
    /// order (D2: a whole-request note lists first under `N notes`).
    static func overviewOrder(_ notes: [OmniTextAnnotation]) -> [OmniTextAnnotation] {
        notes.filter(\.isRequestScoped) + notes.filter { !$0.isRequestScoped }.sorted { $0.range.location < $1.range.location }
    }

    /// `“quoted span”`, or `Whole request · <position>` for a request note
    /// (the start of its guidance when it has no position); a
    /// model-proposed note says so.
    static func overviewSnippet(_ note: OmniTextAnnotation, source: NSString) -> String {
        let base: String
        if note.isRequestScoped {
            let guidance = note.guidance.replacingOccurrences(of: "\n", with: " ")
            let lead = String(guidance.prefix(42)) + (guidance.count > 42 ? "…" : "")
            base = "Whole request · " + (note.label ?? lead)
        } else {
            let raw = note.range.upperBound <= source.length
                ? source.substring(with: note.range).replacingOccurrences(of: "\n", with: " ")
                : ""
            base = "“\(String(raw.prefix(42)))\(raw.count > 42 ? "…" : "")”"
        }
        return note.origin == .proposed ? base + " · suggested" : base
    }

    private func hoverAnnotation(_ id: UUID?) {
        guard id != hoveredID || (id != nil && hover == nil) else { return }
        hoveredID = id
        if id == nil, let hover {
            Task { @MainActor [weak self, weak hover] in
                try? await Task.sleep(for: .milliseconds(180))
                guard let self, self.hoveredID == nil else { return }
                if hover?.frame.contains(NSEvent.mouseLocation) != true { self.closeHover() }
            }
            return
        }
        guard card == nil, overview == nil, let editor, let id,
              let note = editor.annotations.first(where: { $0.id == id }) else { closeHover(); return }
        closeHover()
        hoveredID = id
        editor.activeAnnotationID = id
        let width: CGFloat = 420
        let textWidth = width - 55
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        func measuredHeight(width: CGFloat) -> CGFloat {
            ceil((note.guidance as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph],
                context: nil
            ).height)
        }
        let unscrolledHeight = measuredHeight(width: textWidth)
        let height = min(240, max(44, unscrolledHeight + 20))
        let panel = makePanel(size: NSSize(width: width, height: height), identifier: "omni.annotation.hover")
        let root = OmniAnnotationHoverRoot(frame: NSRect(x: 0, y: 0, width: width, height: height), cornerRadius: 12)
        root.setAccessibilityIdentifier("omni.annotation.hover")
        root.onExit = { [weak self, weak panel] point in
            self?.hoverPanelDidExit(at: point, panel: panel, annotationID: id)
        }
        panel.contentView = root
        panel.acceptsMouseMovedEvents = true
        let text = label(note.guidance, size: 12, weight: .regular, color: OmniFrostedStyle.ink)
        text.lineBreakMode = .byWordWrapping
        text.usesSingleLineMode = false
        text.maximumNumberOfLines = 0
        if unscrolledHeight > height - 20 {
            let scroll = NSScrollView(frame: NSRect(x: 12, y: 10, width: textWidth + 2, height: height - 20))
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.setAccessibilityIdentifier("omni.annotation.hover-scroll")
            scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: textWidth, height: height * 2))
            scroll.layoutSubtreeIfNeeded()
            // Leave the same text insets after the system accounts for a regular scroller.
            let renderedTextWidth = max(1, scroll.contentSize.width - 14)
            let measured = measuredHeight(width: renderedTextWidth)
            let cellHeight = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: renderedTextWidth, height: .greatestFiniteMagnitude)).height ?? measured
            text.frame = NSRect(x: 2, y: 0, width: renderedTextWidth, height: max(measured, cellHeight) + 12)
            scroll.documentView = text
            root.addSubview(scroll)
            scroll.layoutSubtreeIfNeeded()
            let visualStartY = text.isFlipped ? 0 : max(0, text.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: visualStartY))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            text.frame = NSRect(x: 14, y: 10, width: textWidth, height: height - 20)
            root.addSubview(text)
        }
        let remove = iconButton("×", id: "omni.annotation.hover-remove") { [weak self] in self?.remove(id) }
        remove.frame = NSRect(x: width - 32, y: height - 32, width: 22, height: 22)
        root.addSubview(remove)
        hover = panel
        present(panel, above: note.range, in: editor)
    }

    private func hoverPanelDidExit(at screenPoint: NSPoint, panel: NSPanel?, annotationID: UUID) {
        guard let panel, panel === hover, !panel.frame.contains(screenPoint) else { return }
        if let editor, let window = editor.window {
            let point = editor.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            if editor.annotationID(at: point) == annotationID { return }
        }
        closeHover()
    }

    func closeCard(restoreFocus: Bool = false) {
        if let cardEventMonitor { NSEvent.removeMonitor(cardEventMonitor); self.cardEventMonitor = nil }
        if let card { card.orderOut(nil); card.parent?.removeChildWindow(card) }
        card = nil
        field = nil
        pendingRange = nil
        editingID = nil
        if restoreFocus {
            editor?.window?.makeKeyAndOrderFront(nil)
            if let editor { editor.window?.makeFirstResponder(editor) }
        }
    }
    func closeHover() {
        if let hover { hover.orderOut(nil); hover.parent?.removeChildWindow(hover) }
        hover = nil
        hoveredID = nil
        editor?.activeAnnotationID = nil
    }
    func closeOverview() {
        if let overviewEventMonitor { NSEvent.removeMonitor(overviewEventMonitor); self.overviewEventMonitor = nil }
        if let overview { overview.orderOut(nil); overview.parent?.removeChildWindow(overview) }
        overview = nil
        editor?.activeAnnotationID = nil
    }
    func closeAll() { closeCard(); closeHover(); closeOverview(); mark?.removeFromSuperview(); mark = nil }

    private func makePanel(size: NSSize, identifier: String) -> NSPanel {
        let panel = OmniAnnotationPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.contentView = OmniMaterialView(frame: NSRect(origin: .zero, size: size), cornerRadius: 12)
        panel.contentView?.setAccessibilityIdentifier(identifier)
        editor?.window?.addChildWindow(panel, ordered: .above)
        return panel
    }

    private func present(_ panel: NSPanel, above range: NSRange, in editor: NSTextView) {
        let rect = editor.firstRect(forCharacterRange: range, actualRange: nil)
        panel.setFrameOrigin(clamp(NSPoint(x: rect.minX, y: rect.maxY + 8), panel: panel, near: editor.window))
        panel.orderFrontRegardless()
    }

    private func clamp(_ origin: NSPoint, panel: NSPanel, near window: NSWindow?) -> NSPoint {
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: min(max(origin.x, screen.minX + 8), screen.maxX - panel.frame.width - 8),
                       y: min(max(origin.y, screen.minY + 8), screen.maxY - panel.frame.height - 8))
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    private func iconButton(_ title: String, id: String, action: @escaping () -> Void) -> OmniAnnotationActionButton {
        let button = OmniAnnotationActionButton(title: title, action: action)
        button.setAccessibilityIdentifier(id)
        return button
    }
}

@MainActor private final class OmniAnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor private final class OmniAnnotationHoverRoot: OmniFrostedSurface {
    var onExit: ((NSPoint) -> Void)?
    private var exitTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let exitTrackingArea { removeTrackingArea(exitTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        exitTrackingArea = area
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        onExit?(point)
    }
}

@MainActor private final class OmniAnnotationField: NSTextField, NSTextFieldDelegate {
    var onAttach: (() -> Void)?
    var onCancel: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onAttach?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { onAttach?(); return }
        super.keyDown(with: event)
    }
}

@MainActor private final class OmniAnnotationActionButton: NSButton {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 15)
        target = self
        self.action = #selector(invoke)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            OmniFrostedStyle.annotationFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let text = title as NSString
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = dark
            ? NSColor(srgbRed: 1, green: 0.74, blue: 0.32, alpha: 1)
            : NSColor(srgbRed: 0.42, green: 0.24, blue: 0.04, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: ink,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

@MainActor private final class OmniAnnotationMark: NSButton {
    var onPress: (() -> Void)?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        title = "+"
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .semibold)
        contentTintColor = OmniFrostedStyle.annotationRule
        target = self
        action = #selector(invoke)
        setAccessibilityIdentifier("omni.annotation.mark")
        setAccessibilityLabel("Add guidance to selected text")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { onPress?() }
}

@MainActor private final class OmniAnnotationOverviewRow: NSView {
    var onHover: ((Bool) -> Void)?
    private var isActive = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { isActive = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { isActive = false; onHover?(false) }
    override func draw(_ dirtyRect: NSRect) {
        (isActive ? OmniFrostedStyle.annotationActiveFill : OmniFrostedStyle.controlFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

/// Draw icon ink above AppKit's button cache while clicks pass to the button.
@MainActor private final class OmniAnnotationGlyph: NSView {
    private let symbol: NSString
    init(symbol: String) {
        self.symbol = symbol as NSString
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = symbol.size(withAttributes: attributes)
        symbol.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
