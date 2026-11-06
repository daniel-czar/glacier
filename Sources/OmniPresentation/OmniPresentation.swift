import AppKit
import HyperOverlayRuntime
import OmniCore

/// `commandYClose` is the stash chord: the pad submits, then closes once the
/// run is admitted; that working close owes the receipt as its arrival (C53).
public enum OmniSubmitGesture: String, Sendable {
    case enterShowHere, commandEnterAttach, commandYClose

    /// Every gesture but ⌘↩ runs from the pad rather than the workspace.
    public var runsFromPad: Bool { self != .commandEnterAttach }
}
public enum OmniForegroundState: Equatable, Sendable { case hidden, legacy, editing, attached(runID: String) }

public struct OmniSurfaceSnapshot: Equatable, Sendable {
    public let foreground: OmniForegroundState
    public let uiGeneration: Int
    public let detachedRunIDs: [String]
    public init(foreground: OmniForegroundState, uiGeneration: Int, detachedRunIDs: [String]) {
        self.foreground = foreground; self.uiGeneration = uiGeneration; self.detachedRunIDs = detachedRunIDs
    }
}

/// Projects durable runs onto native surfaces. The injected arbitrator remains
/// the only foreground owner; result tiles never take keyboard focus.
@MainActor public final class OmniForegroundCoordinator {
    private var foreground: OmniForegroundState = .hidden
    private let runtime: ForegroundArbitrator
    private var ownership: (overlay: String, generation: Int)?
    private var detached: [String] = []
    public init(runtime: ForegroundArbitrator) { self.runtime = runtime }
    public func showOmni() { claimForeground("omni-editing"); foreground = .editing }
    public func showLegacy() { if case .attached(let id) = foreground { appendDetached(id) }; claimForeground("legacy"); foreground = .legacy }
    @discardableResult public func submit(runID: String, gesture: OmniSubmitGesture, expectedGeneration: Int? = nil) -> Bool {
        if let expectedGeneration, runtime.generation != expectedGeneration {
            if gesture.runsFromPad { appendDetached(runID) }
            return false
        }
        switch gesture {
        case .enterShowHere, .commandYClose: showOmni()
        case .commandEnterAttach: claimForeground("omni-attached"); foreground = .attached(runID: runID)
        }
        return true
    }
    public func detachPadRun(_ runID: String) { appendDetached(runID); closeBeforeSubmission() }
    public func closeBeforeSubmission() { guard foreground == .editing else { return }; releaseForeground(); foreground = .hidden }
    public func detachAttachedResult() { guard case .attached(let id) = foreground else { return }; appendDetached(id); releaseForeground(); foreground = .hidden }
    public func dismissTile(runID: String) { detached.removeAll { $0 == runID } }
    public func isCurrent(generation: Int) -> Bool { runtime.generation == generation }
    public func snapshot() -> OmniSurfaceSnapshot { .init(foreground: foreground, uiGeneration: runtime.generation, detachedRunIDs: detached) }
    /// A presentation claim is idempotent; the host's show operation also
    /// implements hotkey toggling, which must not hide an already attached run.
    private func claimForeground(_ overlay: String) {
        if runtime.activeOverlay != overlay { _ = runtime.show(overlay) }
        ownership = runtime.activeOverlay == overlay ? (overlay, runtime.generation) : nil
    }
    /// A delayed close may clear our local projection, but only its own
    /// generation can release the shared foreground, including same-tool reopen.
    private func releaseForeground() {
        if let ownership, runtime.isCurrent(overlay: ownership.overlay, generation: ownership.generation) {
            _ = runtime.close()
        }
        ownership = nil
    }
    private func appendDetached(_ id: String) { guard !detached.contains(id) else { return }; detached.append(id) }
}

/// The plain-text pasteboard types among an NSTextView's writable ones:
/// AppKit writes the legacy string type and bridges it to the plain-text
/// UTIs; RTF is what carries tints and pills elsewhere.
enum OmniPlainPasteboard {
    static func isPlainText(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .string || type.rawValue == "NSStringPboardType"
    }
}

public enum OmniTokenRenderer {
    /// `findFacets`, when given, draws `/find`'s complete, index-known
    /// filters as pills (D2): display attributes only, the text is unchanged.
    /// `unresolvedAtoms` paint as unresolved whatever the manifest says: a
    /// `/stash:4` the grammar accepts but the stack cannot fill (C96).
    @MainActor public static func attributedText(_ text: String, parser: OmniParser, fontSize: CGFloat = 22, followUp: Bool = false, findFacets: FindFacets? = nil, unresolvedAtoms: Set<String> = []) -> NSAttributedString {
        let commandFont = fontSize == 22 ? OmniFrostedStyle.commandFont : NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: OmniFrostedStyle.ink])
        let source = text as NSString; var search = NSRange(location: 0, length: source.length)
        for atom in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let range = source.range(of: atom, options: [], range: search); guard range.location != NSNotFound else { continue }
            search = NSRange(location: range.upperBound, length: max(0, source.length - range.upperBound))
            let slash = SlashAtom.parse(atom)
            let paint = unresolvedAtoms.contains(atom) ? TokenPaint(role: nil, aliasExpanded: false, acceptedValue: false)
                : tokenPaint(atom: atom, slash: slash, parser: parser, followUp: followUp)
            if let role = paint.role {
                let palette: (foreground: NSColor, background: NSColor) = {
                    if paint.aliasExpanded { return (OmniFrostedStyle.aliasExpanded, OmniFrostedStyle.aliasExpandedTokenFill) }
                    return switch role {
                    case .primary, .settings: (OmniFrostedStyle.command, OmniFrostedStyle.commandTokenFill)
                    case .modifier: (OmniFrostedStyle.modifier, OmniFrostedStyle.modifierTokenFill)
                    case .mode: (OmniFrostedStyle.mode, OmniFrostedStyle.modeTokenFill)
                    case .alias: (OmniFrostedStyle.aliasExpanded, OmniFrostedStyle.aliasExpandedTokenFill)
                    }
                }()
                result.addAttributes([.foregroundColor: palette.foreground, .backgroundColor: palette.background, .font: commandFont], range: range)
                if paint.acceptedValue {
                    let colon = source.range(of: ":", options: [], range: range)
                    if colon.location != NSNotFound {
                        let valueRange = NSRange(location: colon.location, length: range.upperBound - colon.location)
                        result.addAttributes([.foregroundColor: OmniFrostedStyle.tokenValue, .backgroundColor: OmniFrostedStyle.tokenValueFill, .font: commandFont], range: valueRange)
                    }
                }
            } else if !followUp && declaredReference(atom, parser: parser) {
                result.addAttributes([.foregroundColor: OmniFrostedStyle.reference, .backgroundColor: OmniFrostedStyle.referenceTokenFill, .font: commandFont], range: range)
            } else if atom.hasPrefix("/") && SlashAtom.parse(atom) != nil {
                // Unresolved: grey with a dotted underline, the same for half-typed and unknown (C28).
                result.addAttributes([
                    .foregroundColor: OmniFrostedStyle.unresolved,
                    .backgroundColor: OmniFrostedStyle.unresolvedTokenFill,
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: OmniFrostedStyle.unresolved,
                    .font: commandFont,
                ], range: range)
            }
        }
        if let findFacets, !followUp {
            for span in FindFilterSpan.spans(in: text, facets: findFacets) {
                // Same font as the text around it, so a value that completes
                // or shrinks never shifts the line.
                let key = NSRange(location: span.range.location, length: span.keyLength)
                let value = NSRange(location: span.range.location + span.keyLength, length: span.range.length - span.keyLength)
                result.addAttributes([.foregroundColor: OmniFrostedStyle.findPillKey, .backgroundColor: OmniFrostedStyle.commandTokenFill], range: key)
                result.addAttributes([.foregroundColor: OmniFrostedStyle.command, .backgroundColor: OmniFrostedStyle.commandTokenFill], range: value)
            }
        }
        return result
    }
    private static func declaredReference(_ atom: String, parser: OmniParser) -> Bool {
        guard atom.hasPrefix("@") else { return false }; let value = String(atom.dropFirst()); let pair = value.split(separator: ":", maxSplits: 1).map(String.init)
        return pair.count == 2 ? parser.references.qualified(namespace: pair[0], key: pair[1]) != nil : parser.references.unique(key: value) != nil
    }

    private struct TokenPaint {
        var role: TokenRole?
        var aliasExpanded: Bool
        var acceptedValue: Bool
    }

    private static func tokenPaint(atom: String, slash: SlashAtom?, parser: OmniParser, followUp: Bool) -> TokenPaint {
        if followUp { return followUpPaint(slash) }
        guard let command = parser.manifest.command(matchingAtom: atom) ?? parser.manifest.command(for: atom) else {
            return TokenPaint(role: nil, aliasExpanded: false, acceptedValue: false)
        }
        if let spec = command.value {
            switch TokenValueNormalizer.validate(raw: slash?.value, spec: spec, types: parser.manifest.valueTypes) {
            case .invalid:
                return TokenPaint(role: nil, aliasExpanded: false, acceptedValue: false)
            case .omitted:
                if spec.required { return TokenPaint(role: nil, aliasExpanded: false, acceptedValue: false) }
                return rolePaint(command, parser: parser, acceptedValue: false)
            case .accepted:
                return rolePaint(command, parser: parser, acceptedValue: true)
            }
        }
        if slash?.value != nil {
            return TokenPaint(role: nil, aliasExpanded: false, acceptedValue: false)
        }
        return rolePaint(command, parser: parser, acceptedValue: false)
    }

    private static func followUpPaint(_ slash: SlashAtom?) -> TokenPaint {
        guard let slash else { return TokenPaint(role: nil, aliasExpanded: false, acceptedValue: false) }
        switch slash.name.lowercased() {
        case "shorter":
            if let raw = slash.value {
                guard LengthValue.parse(raw) != nil else {
                    return TokenPaint(role: nil, aliasExpanded: false, acceptedValue: false)
                }
                return TokenPaint(role: .primary, aliasExpanded: false, acceptedValue: true)
            }
            return TokenPaint(role: .primary, aliasExpanded: false, acceptedValue: false)
        case "formal":
            if slash.value != nil {
                return TokenPaint(role: nil, aliasExpanded: false, acceptedValue: false)
            }
            return TokenPaint(role: .alias, aliasExpanded: true, acceptedValue: false)
        case "style" where slash.value == "formal":
            return TokenPaint(role: .modifier, aliasExpanded: false, acceptedValue: true)
        default:
            return TokenPaint(role: nil, aliasExpanded: false, acceptedValue: false)
        }
    }

    private static func rolePaint(_ command: ManifestCommand, parser: OmniParser, acceptedValue: Bool) -> TokenPaint {
        if command.role == .alias {
            let role = command.canonical.flatMap { parser.manifest.command(matchingAtom: $0)?.role } ?? .modifier
            return TokenPaint(role: role, aliasExpanded: true, acceptedValue: acceptedValue)
        }
        return TokenPaint(role: command.role, aliasExpanded: false, acceptedValue: acceptedValue)
    }
}

extension NSTextView {
    /// ⌘A / ⌘C / ⌘X / ⌘V for hosts that install no Edit menu (the resident
    /// Hyper host), where these key equivalents would otherwise beep. A host
    /// with an Edit menu handles them before keyDown. Cut and paste only in an
    /// editable view; paste is plain text because Omni's fields are rich only
    /// for their own token tints. Returns whether the event was handled.
    func performStandardEditingKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.shift), !modifiers.contains(.option),
              !modifiers.contains(.control), !hasMarkedText() else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": if isEditable { cut(nil) }
        case "v": if isEditable { pasteAsPlainText(nil) }
        default: return false
        }
        return true
    }
}

/// Read-only, selectable text (the workspace's version input and result):
/// ⌘A and ⌘C work without an Edit menu.
@MainActor public final class OmniSelectableTextView: NSTextView {
    public var annotations: [OmniTextAnnotation] = [] { didSet { needsDisplay = true } }
    public var activeAnnotationID: UUID? { didSet { needsDisplay = true } }
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        OmniAnnotationHighlight.draw(annotations, activeID: activeAnnotationID, in: self, dirtyRect: dirtyRect)
    }
    public override func keyDown(with event: NSEvent) {
        if performStandardEditingKey(event) { return }
        super.keyDown(with: event)
    }
}

@MainActor public final class OmniCommandTextView: NSTextView, @preconcurrency NSTextStorageDelegate {
    /// Copy and drag carry plain text: the field is rich only for its own
    /// token tints and `/find` pills, never for what it hands elsewhere.
    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter(OmniPlainPasteboard.isPlainText)
    }
    public var onSubmit: ((OmniSubmitGesture) -> Void)?
    public var onEscape: (() -> Void)?
    public var onAnnotationShortcut: (() -> Void)?
    /// ⌘Y, the stash chord; returns false when this field has no stash.
    public var onStashChord: (() -> Bool)?
    public var onAnnotationHover: ((UUID?) -> Void)?
    public var onAnnotationsChanged: (([OmniTextAnnotation]) -> Void)?
    /// Dependent presentation must wait until NSTextStorage finishes a real
    /// character edit. Annotation data itself is still remapped synchronously.
    private(set) var isProcessingCharacterEdit = false
    public private(set) var annotations: [OmniTextAnnotation] = []
    public var activeAnnotationID: UUID? { didSet { needsDisplay = true } }
    private var annotationTextSnapshot = ""
    private var annotationTrackingArea: NSTrackingArea?
    private var expectedUndoText: String?
    private var compositionBase: (text: String, annotations: [OmniTextAnnotation], range: NSRange)?
    private struct PendingTextEdit {
        let before: String
        let range: NSRange
        let replacement: String
    }
    private var pendingTextEdit: PendingTextEdit?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    public func installAnnotationTracking() {
        textStorage?.delegate = self
        annotationTextSnapshot = string
        pendingTextEdit = nil
    }
    /// The field owns its undo stack (C27: a replaced draft is one ⌘Z away),
    /// with or without a window.
    private let ownUndoManager = UndoManager()
    public override var undoManager: UndoManager? { ownUndoManager }
    /// Ghost text while the field is empty (canvas state 1).
    public var placeholder = "" { didSet { needsDisplay = true } }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        OmniAnnotationHighlight.draw(annotations, activeID: activeAnnotationID, in: self, dirtyRect: dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? OmniFrostedStyle.commandFont,
            .foregroundColor: OmniFrostedStyle.secondaryInk.withAlphaComponent(0.45),
        ]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attributes)
    }

    public override func didChangeText() {
        super.didChangeText()
        reconcileAnnotations()
        pendingTextEdit = nil
        needsDisplay = true
    }

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let accepted = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        // NSTextStorage can merge a one-character key edit with a broad token
        // restyle. Retain the native edit location only for this pending edit;
        // didProcessEditing verifies it against the actual before/after text.
        pendingTextEdit = accepted ? replacementString.map {
            PendingTextEdit(before: string, range: affectedCharRange, replacement: $0)
        } : nil
        return accepted
    }

    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if compositionBase == nil {
            let range = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            compositionBase = (text: self.string, annotations: annotations, range: range)
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    public override func unmarkText() {
        let base = compositionBase
        super.unmarkText()
        guard let base else { return }
        compositionBase = nil
        let replacementLength = (string as NSString).length - (base.text as NSString).length + base.range.length
        guard replacementLength >= 0 else { setAnnotations([]); return }
        let final = OmniAnnotationRanges.validated(
            OmniAnnotationRanges.remap(base.annotations, replacing: base.range, withUTF16Length: replacementLength),
            in: string
        )
        annotationTextSnapshot = string
        if final != annotations {
            annotations = final
            onAnnotationsChanged?(annotations)
            needsDisplay = true
        }
    }
    /// Replace a whole document's annotations after setting its text. Callers
    /// use this for a new pad request or a restored composer draft.
    public func setAnnotations(_ value: [OmniTextAnnotation]) {
        if textStorage?.delegate !== self { installAnnotationTracking() }
        annotationTextSnapshot = string
        pendingTextEdit = nil
        let accepted = OmniAnnotationRanges.validated(value, in: string)
        guard accepted != annotations else { return }
        annotations = accepted
        onAnnotationsChanged?(annotations)
        needsDisplay = true
    }

    public func changeAnnotations(_ value: [OmniTextAnnotation]) {
        reconcileAnnotations()
        let previous = annotations
        let accepted = OmniAnnotationRanges.validated(value, in: string)
        guard accepted != previous else { return }
        undoManager?.registerUndo(withTarget: self) { target in target.changeAnnotations(previous) }
        undoManager?.setActionName("Guidance note")
        setAnnotations(accepted)
    }

    public func reconcileAnnotations() {
        if textStorage?.delegate !== self { installAnnotationTracking() }
        guard let change = Self.textChange(from: annotationTextSnapshot, to: string) else { return }
        let oldLength = (annotationTextSnapshot as NSString).length
        annotationTextSnapshot = string
        let updated = OmniAnnotationRanges.droppingRequestNotesIfBlank(
            OmniAnnotationRanges.droppingRequestNotesIfReplaced(
                OmniAnnotationRanges.remap(annotations, replacing: change.range, withUTF16Length: change.replacementLength),
                replacing: change.range,
                inOldTextOfLength: oldLength
            ),
            in: string
        )
        if updated != annotations {
            annotations = updated
            onAnnotationsChanged?(annotations)
        }
        needsDisplay = true
    }

    private static func textChange(from oldText: String, to newText: String) -> (range: NSRange, replacementLength: Int)? {
        let old = Array(oldText.utf16)
        let new = Array(newText.utf16)
        guard old != new else { return nil }
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count - prefix, new.count - prefix),
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        return (NSRange(location: prefix, length: old.count - prefix - suffix), new.count - prefix - suffix)
    }

    private static func exactTextChange(
        from oldText: String,
        to newText: String,
        range: NSRange,
        replacement: String
    ) -> (range: NSRange, replacementLength: Int)? {
        let old = oldText as NSString
        guard range.location >= 0, range.length >= 0,
              range.location <= old.length, range.length <= old.length - range.location else { return nil }
        let candidate = old.replacingCharacters(in: range, with: replacement)
        guard candidate.utf16.elementsEqual(newText.utf16) else { return nil }
        return (range, replacement.utf16.count)
    }

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        isProcessingCharacterEdit = true
        defer { isProcessingCharacterEdit = false; pendingTextEdit = nil }
        let newText = textStorage.string
        // NSTextStorage reports setAttributedString as character editing even
        // when a token restyle writes the exact same characters.
        guard newText != annotationTextSnapshot else { return }
        if let expectedUndoText, newText == expectedUndoText {
            self.expectedUndoText = nil
            annotationTextSnapshot = newText
            needsDisplay = true
            return
        }
        let previousText = annotationTextSnapshot
        let previousNotes = annotations
        let nativeChange: (range: NSRange, replacementLength: Int)? = pendingTextEdit.flatMap { hint in
            guard hint.before.utf16.elementsEqual(previousText.utf16) else { return nil }
            return Self.exactTextChange(from: previousText, to: newText, range: hint.range, replacement: hint.replacement)
        }
        let characterChange: (range: NSRange, replacementLength: Int)? = {
            // A characters-only storage callback retains its exact range.
            // Character+attribute callbacks may cover much more than the text
            // replacement, so they require the native hint or text diff.
            guard !editedMask.contains(.editedAttributes), editedRange.location >= 0,
                  editedRange.length >= 0, editedRange.length >= delta,
                  editedRange.location <= (newText as NSString).length,
                  editedRange.length <= (newText as NSString).length - editedRange.location else { return nil }
            let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
            let replacement = (newText as NSString).substring(with: editedRange)
            return Self.exactTextChange(from: previousText, to: newText, range: oldRange, replacement: replacement)
        }()
        guard let change = nativeChange ?? characterChange ?? Self.textChange(from: previousText, to: newText) else { return }
        annotationTextSnapshot = newText
        let updated = OmniAnnotationRanges.droppingRequestNotesIfBlank(
            OmniAnnotationRanges.droppingRequestNotesIfReplaced(
                OmniAnnotationRanges.remap(annotations, replacing: change.range, withUTF16Length: change.replacementLength),
                replacing: change.range,
                inOldTextOfLength: (previousText as NSString).length
            ),
            in: newText
        )
        guard updated != annotations else { needsDisplay = true; return }
        annotations = updated
        if compositionBase == nil && undoManager?.isUndoing != true && undoManager?.isRedoing != true {
            undoManager?.registerUndo(withTarget: self) { target in
                target.restoreAnnotations(previousNotes, for: previousText)
            }
        }
        onAnnotationsChanged?(annotations)
        needsDisplay = true
    }

    private func restoreAnnotations(_ value: [OmniTextAnnotation], for expectedText: String) {
        let current = annotations
        let currentText = annotationTextSnapshot
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreAnnotations(current, for: currentText)
        }
        annotations = value
        if string != expectedText { expectedUndoText = expectedText }
        else { expectedUndoText = nil }
        onAnnotationsChanged?(annotations)
        needsDisplay = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let annotationTrackingArea { removeTrackingArea(annotationTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        annotationTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        onAnnotationHover?(annotationID(at: point))
    }

    /// NSText layout's nearest-glyph lookup can return the last glyph when the
    /// pointer is far into blank space. Check the painted span rectangles.
    public func annotationID(at point: NSPoint) -> UUID? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let count = (string as NSString).length
        for note in annotations where note.range.length > 0 && note.range.upperBound <= count {
            let glyphs = layoutManager.glyphRange(forCharacterRange: note.range, actualCharacterRange: nil)
            var hit = false
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                let visible = NSIntersectionRange(glyphs, lineGlyphs)
                guard visible.length > 0 else { return }
                let rect = layoutManager.boundingRect(forGlyphRange: visible, in: textContainer)
                    .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                    .insetBy(dx: -1, dy: -1)
                if rect.contains(point) { hit = true }
            }
            if hit { return note.id }
        }
        return nil
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onAnnotationHover?(nil)
    }
    /// Esc closes the completion menu first, the pad second (C25).
    public var onEscapeMenu: (() -> Bool)?
    /// Tab accepts the highlighted completion; returns false when no menu is up.
    public var onTab: (() -> Bool)?
    /// Arrow keys move the completion highlight (-1 up, +1 down).
    public var onArrow: ((Int) -> Bool)?
    /// Digits jump in the proposal chooser (C26); consumed only while choosing.
    public var onDigit: ((Int) -> Bool)?
    /// ⌥⌘C copies the highlighted file row's path (Finder's Copy as
    /// Pathname); returns false when no file row is highlighted.
    public var onCopyPath: (() -> Bool)?

    public override func keyDown(with event: NSEvent) {
        // ⌘Z / ⌘⇧Z reach the field's own undo stack even in hosts that
        // install no Edit menu (the resident Hyper host): the replaced-draft
        // restore (C27) and the launch undo (C50) both live there. A host
        // with an Edit menu handles the key equivalent before keyDown.
        // Only in an editable field with no marked (IME) text: a locked field
        // (proposal flow) must not change under a pending decision.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "k",
           isEditable, !hasMarkedText() {
            onAnnotationShortcut?()
            return
        }
        if modifiers.intersection([.command, .shift, .option, .control]) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "y", isEditable, !hasMarkedText(),
           onStashChord?() == true {
            return
        }
        if modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "z", isEditable, !hasMarkedText(), let undoManager {
            if modifiers.contains(.shift) {
                if undoManager.canRedo { undoManager.redo() }
            } else if undoManager.canUndo {
                undoManager.undo()
            }
            return
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "c",
           onCopyPath?() == true {
            return
        }
        if performStandardEditingKey(event) { return }
        switch event.keyCode {
        case 53:
            if onEscapeMenu?() == true { return }
            onEscape?()
            return
        case 36, 76:
            onSubmit?(event.modifierFlags.contains(.command) ? .commandEnterAttach : .enterShowHere)
            return
        case 48:
            if isEditable, !hasMarkedText(), onTab?() == true { return }
        case 126:
            if onArrow?(-1) == true { return }
        case 125:
            if onArrow?(1) == true { return }
        default:
            // Only a plain digit can pick; ⌘-digits stay free (C73).
            if let digit = OmniDigitKeys.digit(forKeyCode: event.keyCode),
               modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
               onDigit?(digit) == true { return }
        }
        super.keyDown(with: event)
    }
}
@MainActor public final class OmniCommandPadPanel: NSPanel { public override var canBecomeKey: Bool { true }; public override var canBecomeMain: Bool { true } }

public struct OmniReferenceChoice: Sendable, Equatable, Identifiable { public let id: String; public let canonicalText: String; public let label: String; public init(id: String, canonicalText: String, label: String) { self.id = id; self.canonicalText = canonicalText; self.label = label } }

@MainActor final class OmniMaterialView: OmniFrostedSurface {
    var retainedTargets: [NSObject] = []
}
@MainActor private final class ChoiceTarget: NSObject { let value: OmniReferenceChoice; let handler: (OmniReferenceChoice) -> Void; init(_ value: OmniReferenceChoice, handler: @escaping (OmniReferenceChoice) -> Void) { self.value = value; self.handler = handler }; @objc func choose(_ sender: Any?) { handler(value) } }

@MainActor public final class OmniReferencePicker: NSPanel {
    public var onChoose: ((OmniReferenceChoice) -> Void)?
    public init(choices: [OmniReferenceChoice], anchor: NSRect, headingText: String = "Choose reference") {
        let height = min(260, max(70, 26 + choices.count * 34)); let frame = NSRect(x: anchor.minX, y: max(20, anchor.minY - CGFloat(height) - 8), width: 320, height: CGFloat(height))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false); isFloatingPanel = true; level = .floating; hasShadow = true
        let root = OmniMaterialView(frame: NSRect(origin: .zero, size: frame.size)); root.setAccessibilityIdentifier("omni.reference-picker")
        let heading = NSTextField(labelWithString: headingText); heading.font = .systemFont(ofSize: 12, weight: .semibold); heading.frame = NSRect(x: 14, y: frame.height - 27, width: frame.width - 28, height: 16); root.addSubview(heading)
        for (index, choice) in choices.enumerated() {
            let button = OmniReadableButton(title: choice.label); button.bezelStyle = .rounded; button.alignment = .left; button.frame = NSRect(x: 12, y: frame.height - 58 - CGFloat(index) * 34, width: frame.width - 24, height: 27); button.setAccessibilityIdentifier("omni.reference-choice.\(choice.id)")
            let target = ChoiceTarget(choice) { [weak self] selected in self?.onChoose?(selected); self?.orderOut(nil) }; button.target = target; button.action = #selector(ChoiceTarget.choose(_:)); root.retainedTargets.append(target); root.addSubview(button)
        }
        contentView = root
    }
    public override var canBecomeKey: Bool { false }
}

/// One selectable model profile for a single invocation. IDs are stable
/// profile identifiers; labels are display-only and never persisted.
public struct OmniModelChoice: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let unavailabilityReason: String?
    public var isEnabled: Bool { unavailabilityReason == nil }
    public var menuTitle: String { unavailabilityReason.map { "\(label) — \($0)" } ?? label }
    public init(id: String, label: String, unavailabilityReason: String? = nil) {
        self.id = id
        self.label = label
        self.unavailabilityReason = unavailabilityReason
    }
}

/// Native buttons on a HUD material must keep their own control contrast.
/// Opting out of vibrancy also keeps labels legible in light appearance.
@MainActor final class OmniReadableButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
    }
    override var allowsVibrancy: Bool { false }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

public struct OmniModelAssignmentRow: Sendable, Equatable, Identifiable {
    public let commandID: String
    public let main: String?
    public let fallback: String?
    public let availability: String
    public let supportsModel: Bool
    /// The settings surface renders only these application-supplied choices. It
    /// never accepts arbitrary provider/model strings from the UI.
    public let allowedMainChoices: [String]
    public let allowedFallbackChoices: [String]
    public var id: String { commandID }
    public init(commandID: String, main: String?, fallback: String?, availability: String, supportsModel: Bool, allowedMainChoices: [String] = [], allowedFallbackChoices: [String] = []) {
        self.commandID = commandID; self.main = main; self.fallback = fallback; self.availability = availability; self.supportsModel = supportsModel; self.allowedMainChoices = allowedMainChoices; self.allowedFallbackChoices = allowedFallbackChoices
    }
}
