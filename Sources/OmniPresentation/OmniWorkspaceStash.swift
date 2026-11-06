import AppKit
import OmniCore

/// One stash entry as the workspace shows it (C42, C92): its import token,
/// its text, and `source · when`.
public struct OmniWorkspaceStashEntry: Equatable {
    public let id: String
    public let token: String
    public let text: String
    public let kind: OmniContentKind
    public let detail: String
    public let isEditable: Bool
    public let imageData: Data?

    public init(id: String, token: String, text: String, kind: OmniContentKind, detail: String, isEditable: Bool, imageData: Data? = nil) {
        self.id = id
        self.token = token
        self.text = text
        self.kind = kind
        self.detail = detail
        self.isEditable = isEditable
        self.imageData = imageData
    }
}

/// The pinned row's detail (C42 → C92): the stack, top first, each entry
/// editable in place (Notes idiom: edits save silently), with Copy and Drop
/// per entry and Copy · Clear for the stack.
@MainActor
public final class OmniWorkspaceStashView: NSView, NSTextViewDelegate {
    public override var isFlipped: Bool { true }
    public var onEdited: ((String, String) -> Void)?
    public var onCopy: ((String) -> Void)?
    public var onDrop: ((String) -> Void)?
    public var onClear: (() -> Void)?
    public private(set) var entries: [OmniWorkspaceStashEntry] = []
    /// Entry id → its editor, for focusing (⌘↩ from the stack view) and tests.
    public private(set) var editors: [String: NSTextView] = [:]
    public let titleLabel = NSTextField(labelWithString: "Stash")
    public let subtitleLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let document = OmniFlippedView()
    private var blocks: [(id: String, header: NSView, body: NSView, rule: NSView)] = []
    private var notice: String?
    private var clearButton: NSButton?
    private var copyButton: NSButton?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("omni.workspace.stash")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setAccessibilityIdentifier("omni.workspace.stash.subtitle")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.setAccessibilityIdentifier("omni.workspace.stash.entries")
        let copy = Self.button(title: "Copy", symbol: "doc.on.doc", identifier: "omni.workspace.stash.copy") { [weak self] in
            guard let self, let id = self.focusedEntryID ?? self.entries.first?.id else { return }
            self.onCopy?(id)
        }
        let clear = Self.button(title: "Clear", symbol: "xmark", identifier: "omni.workspace.stash.clear") { [weak self] in self?.onClear?() }
        copyButton = copy
        clearButton = clear
        for child in [titleLabel, subtitleLabel, copy, clear, scroll] as [NSView] { addSubview(child) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The entry whose editor has focus.
    public var focusedEntryID: String? {
        guard let responder = window?.firstResponder as? NSTextView else { return nil }
        return editors.first { $0.value === responder }?.key
    }

    /// Updates in place while the same entries are shown, so a save that
    /// echoes back from the store never moves the caret; rebuilds otherwise.
    public func update(entries next: [OmniWorkspaceStashEntry], notice: String?) {
        self.notice = notice
        let sameShape = next.map(\.id) == entries.map(\.id) && !blocks.isEmpty
        entries = next
        if sameShape {
            for entry in next {
                guard let editor = editors[entry.id], editor.string != entry.text,
                      window?.firstResponder !== editor else { continue }
                editor.string = entry.text
            }
            for (block, entry) in zip(blocks, next) {
                (block.header.subviews.first(where: { $0.accessibilityIdentifier() == "omni.workspace.stash.header-label" }) as? NSTextField)?
                    .attributedStringValue = Self.headerText(entry)
            }
        } else {
            rebuild()
        }
        renderSubtitle()
        needsLayout = true
    }

    public func focus(entryID: String?) {
        let id = entryID ?? entries.first?.id
        guard let id, let editor = editors[id] else { return }
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        if let block = blocks.first(where: { $0.id == id }) {
            document.scrollToVisible(block.header.frame.union(block.body.frame))
        }
    }

    public override func layout() {
        super.layout()
        let left: CGFloat = 28
        let top = safeAreaInsets.top + 18
        let width = max(1, bounds.width - left * 2)
        titleLabel.frame = NSRect(x: left, y: top, width: max(1, width - 180), height: 26)
        clearButton?.frame = NSRect(x: bounds.width - left - 76, y: top, width: 76, height: 26)
        copyButton?.frame = NSRect(x: bounds.width - left - 76 - 8 - 76, y: top, width: 76, height: 26)
        subtitleLabel.frame = NSRect(x: left, y: top + 28, width: width, height: 18)
        scroll.frame = NSRect(x: left, y: top + 58, width: width, height: max(60, bounds.height - top - 58 - 18))
        layoutDocument()
    }

    public func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView,
              let id = editors.first(where: { $0.value === editor })?.key else { return }
        onEdited?(id, editor.string)
        layoutDocument()
    }

    private func rebuild() {
        blocks.forEach { $0.header.removeFromSuperview(); $0.body.removeFromSuperview(); $0.rule.removeFromSuperview() }
        blocks = []
        editors = [:]
        document.subviews.forEach { $0.removeFromSuperview() }
        if entries.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Nothing stashed. ⌘Y in Glacier or on a Clipboard row, or /stash with text, keeps something here.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 13)
            empty.setAccessibilityIdentifier("omni.workspace.stash.empty")
            document.addSubview(empty)
            blocks = [("", empty, NSView(), NSView())]
            return
        }
        for (index, entry) in entries.enumerated() {
            let header = NSView()
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = Self.headerText(entry)
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityIdentifier("omni.workspace.stash.header-label")
            header.addSubview(label)
            let copy = Self.button(title: "Copy", symbol: nil, identifier: "omni.workspace.stash.\(index + 1).copy") { [weak self] in self?.onCopy?(entry.id) }
            let drop = Self.button(title: "Drop", symbol: nil, identifier: "omni.workspace.stash.\(index + 1).drop") { [weak self] in self?.onDrop?(entry.id) }
            header.addSubview(copy)
            header.addSubview(drop)
            let body: NSView
            if entry.isEditable {
                let editor = OmniStashEntryTextView()
                editor.isEditable = true
                editor.isSelectable = true
                editor.isRichText = false
                editor.allowsUndo = true
                editor.drawsBackground = false
                editor.font = entry.kind == .code ? .monospacedSystemFont(ofSize: 14, weight: .regular) : .systemFont(ofSize: 15)
                editor.textColor = .labelColor
                editor.insertionPointColor = OmniFrostedStyle.accent
                editor.textContainerInset = NSSize(width: 0, height: 4)
                editor.textContainer?.lineFragmentPadding = 0
                editor.textContainer?.widthTracksTextView = true
                editor.isVerticallyResizable = false
                editor.string = entry.text
                editor.delegate = self
                editor.setAccessibilityIdentifier("omni.workspace.stash.\(index + 1).text")
                editor.setAccessibilityLabel("Stash \(index + 1), editable")
                editors[entry.id] = editor
                body = editor
            } else {
                let image = NSImageView()
                image.imageScaling = .scaleProportionallyUpOrDown
                image.imageAlignment = .alignLeft
                image.image = entry.imageData.flatMap { OmniKindThumbnail.image($0, maxPixels: 480) }
                image.setAccessibilityIdentifier("omni.workspace.stash.\(index + 1).image")
                body = image
            }
            let rule = OmniStashRuleView()
            for child in [header, body, rule] { document.addSubview(child) }
            blocks.append((entry.id, header, body, rule))
        }
    }

    private func layoutDocument() {
        let width = max(1, scroll.contentSize.width)
        var y: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            if block.id.isEmpty {
                block.header.frame = NSRect(x: 0, y: 0, width: width, height: 40)
                y = 40
                continue
            }
            block.header.frame = NSRect(x: 0, y: y, width: width, height: 24)
            let buttons = block.header.subviews.compactMap { $0 as? NSButton }
            for (offset, button) in buttons.enumerated() {
                button.frame = NSRect(x: width - CGFloat(buttons.count - offset) * 66, y: 0, width: 60, height: 22)
            }
            block.header.subviews.first { $0 is NSTextField }?.frame = NSRect(x: 0, y: 3, width: max(1, width - 140), height: 17)
            y += 28
            let height: CGFloat
            if let editor = block.body as? NSTextView, let container = editor.textContainer {
                container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
                editor.layoutManager?.ensureLayout(for: container)
                height = max(26, ceil((editor.layoutManager?.usedRect(for: container).height ?? 20) + 10))
            } else {
                height = block.body is NSImageView ? 120 : 0
            }
            block.body.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + 12
            block.rule.isHidden = index == blocks.count - 1
            block.rule.frame = NSRect(x: 0, y: y, width: width, height: 1)
            y += 14
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    private func renderSubtitle() {
        let count = entries.count
        subtitleLabel.stringValue = notice ?? "\(count) of \(OmniStashStack.capacity) · top first · /stash imports the top, /stash:N the Nth"
        subtitleLabel.textColor = notice == nil ? .secondaryLabelColor : OmniFrostedStyle.warning
        copyButton?.isEnabled = count > 0
        clearButton?.isEnabled = count > 0
    }

    private static func headerText(_ entry: OmniWorkspaceStashEntry) -> NSAttributedString {
        let text = NSMutableAttributedString(string: entry.token, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: OmniFrostedStyle.command,
        ])
        text.append(NSAttributedString(string: "   " + entry.detail, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    private static func button(title: String, symbol: String?, identifier: String, action: @escaping () -> Void) -> NSButton {
        let button = OmniStashActionButton(title: title, action: action)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        button.imagePosition = symbol == nil ? .noImage : .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityIdentifier(identifier)
        return button
    }
}

/// Plain-text entry editor: ⌘A, ⌘C, ⌘X, ⌘V and ⌘Z work without an Edit
/// menu (the resident host installs none), as in `OmniCommandTextView`.
@MainActor final class OmniStashEntryTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if OmniWorkspaceUndoKey.perform(event, undoManager: undoManager, enabled: !hasMarkedText()) { return }
        if performStandardEditingKey(event) { return }
        super.keyDown(with: event)
    }
}

/// ⌘Z / ⇧⌘Z against a window's undo manager, for hosts with no Edit menu:
/// the stash editors' typing and the workspace's Drop and Clear share it.
@MainActor enum OmniWorkspaceUndoKey {
    static func perform(_ event: NSEvent, undoManager: UndoManager?, enabled: Bool = true) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard enabled, let undoManager, modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control),
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        if modifiers.contains(.shift) {
            if undoManager.canRedo { undoManager.redo() }
        } else if undoManager.canUndo {
            undoManager.undo()
        }
        return true
    }
}

@MainActor private final class OmniStashActionButton: NSButton {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(invoke)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

@MainActor private final class OmniStashRuleView: NSView {
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) { NSColor.separatorColor.setFill(); bounds.fill() }
}
