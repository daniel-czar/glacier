import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

// `/find` in the pad (D2, decision surface 569d5a7cf925cbd7): facets on the
// completion menu, picked values as plain text, and the picker result.

@MainActor
private func findParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    return OmniParser(manifest: manifest, references: try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)]))
}

private let facets = FindFacets(
    kinds: [FindFacetValue(value: "note", count: 2968), FindFacetValue(value: "review", count: 1207), FindFacetValue(value: "report", count: 784)],
    projects: [FindFacetValue(value: "helios", count: 3639), FindFacetValue(value: "cassandra", count: 120)],
    tags: [FindFacetValue(value: "ml", count: 900), FindFacetValue(value: "review-loop", count: 12)]
)

@MainActor
private func findPad(screenTop: CGFloat = 2_000) throws -> OmniCommandPadViewController {
    _ = NSApplication.shared
    let pad = OmniCommandPadViewController(parser: try findParser())
    pad.loadView()
    _ = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    pad.completionScreenTop = screenTop
    pad.onRequestFindFacets = { facets }
    return pad
}

@MainActor
private func type(_ text: String, into pad: OmniCommandPadViewController) {
    pad.editor.string = text
    pad.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
}

@Test @MainActor func findThenTabListsTheThreeFacets() throws {
    let pad = try findPad()
    type("/find ", into: pad)
    #expect(!pad.isCompletionVisible, "a space alone never opens the menu (C78)")
    #expect(pad.editor.onTab?() == true)
    #expect(pad.completionChoices.map(\.canonicalText) == ["kind:", "in:", "tags:"])
    let kind = try #require(pad.completionItems.first)
    #expect(kind.help.kind == "Filter · runs on this Mac")
    #expect(kind.help.usage == ["note 2,968 · review 1,207 · report 784"])
    #expect(pad.routeLine == .hint(OmniCommandPadViewController.typingHint))
    // After a finished filter, Tab asks again.
    type("/find kind:review ", into: pad)
    #expect(pad.editor.onTab?() == true)
    #expect(pad.completionChoices.count == 3)
    // Right after the token itself (`/fi` Tab completes it with no space):
    // the space, then the facets; never a tab character.
    type("/find", into: pad)
    #expect(pad.editor.onTab?() == true)
    #expect(pad.editor.string == "/find ")
    #expect(pad.completionChoices.map(\.canonicalText) == ["kind:", "in:", "tags:"])
    // An earlier word that merely contains /find is not the token.
    type("~/finder /find ", into: pad)
    #expect(pad.editor.onTab?() == true)
    #expect(pad.completionChoices.map(\.canonicalText) == ["kind:", "in:", "tags:"])
}

@Test @MainActor func pickingAFacetListsItsValuesAndAValueInsertsPlainText() throws {
    let pad = try findPad()
    type("/find ", into: pad)
    _ = pad.editor.onTab?()
    #expect(pad.acceptCompletion())
    #expect(pad.editor.string == "/find kind:")
    #expect(pad.completionChoices.map(\.canonicalText) == ["kind:note", "kind:review", "kind:report"], "the facet's values, at once")
    _ = pad.editor.onArrow?(1)
    #expect(pad.acceptCompletion())
    #expect(pad.editor.string == "/find kind:review ")
    #expect(!pad.isCompletionVisible)
    // The stored text is plain: no token, no attachment.
    #expect(pad.editor.textStorage?.string == "/find kind:review ")
    let intent = pad.parser.parse(pad.editor.string)
    #expect(intent.dispatchToken == "/find" && intent.primaryTokens == ["/find"])
}

@Test @MainActor func completeKnownFiltersDrawAsPillsAndTheTextStaysPlain() throws {
    let pad = try findPad()
    let text = "/find kind:review in:helios kind:rev adversarial"
    type(text, into: pad)
    let storage = try #require(pad.editor.textStorage)
    #expect(storage.string == text, "display only: no token, no attachment")
    func color(_ key: NSAttributedString.Key, at location: Int) -> NSColor? { storage.attribute(key, at: location, effectiveRange: nil) as? NSColor }
    // kind:review — key dimmed, value bright, both on the command fill.
    #expect(color(.foregroundColor, at: 6) == OmniFrostedStyle.findPillKey)
    #expect(color(.backgroundColor, at: 6) == OmniFrostedStyle.commandTokenFill)
    #expect(color(.foregroundColor, at: 11) == OmniFrostedStyle.command)
    #expect(color(.backgroundColor, at: 16) == OmniFrostedStyle.commandTokenFill)
    // in:helios too; the half-typed kind:rev and the free word stay plain.
    #expect(color(.backgroundColor, at: 18) == OmniFrostedStyle.commandTokenFill)
    #expect(color(.backgroundColor, at: 28) == nil)
    #expect(color(.backgroundColor, at: 37) == nil)
    // Backspace shrinks the value as plain text, and the pill goes with it.
    type("/find kind:review", into: pad)
    #expect(color(.backgroundColor, at: 11) == OmniFrostedStyle.commandTokenFill)
    pad.editor.setSelectedRange(NSRange(location: 17, length: 0))
    pad.editor.deleteBackward(nil)
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(pad.editor.string == "/find kind:revie")
    #expect(color(.backgroundColor, at: 11) == nil)
    // ⌘C hands plain text only: no RTF carrying the pill colours.
    type("/find kind:review in:helios", into: pad)
    pad.editor.setSelectedRange(NSRange(location: 0, length: (pad.editor.string as NSString).length))
    #expect(pad.editor.selectedRange().length == 27)
    let board = NSPasteboard(name: NSPasteboard.Name("omni-find-pills-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    #expect(!pad.editor.writablePasteboardTypes.isEmpty)
    #expect(pad.editor.writablePasteboardTypes.allSatisfy(OmniPlainPasteboard.isPlainText))
    #expect(pad.editor.writeSelection(to: board, types: pad.editor.writablePasteboardTypes))
    #expect(!(board.types ?? []).contains(.rtf) && !(board.types ?? []).contains(.rtfd), "no rich text leaves the field")
    #expect(board.string(forType: .string) == "/find kind:review in:helios")
    // The submitted-request echo stays plain: no pill fill on the value.
    pad.beginWorking(runID: "run-pills", requestText: "/find kind:review in:helios")
    let echo = try #require(pad.submittedRequestView.textStorage)
    #expect(echo.string.hasPrefix("/find kind:review"))
    #expect(echo.attribute(.backgroundColor, at: 11, effectiveRange: nil) == nil)
    #expect(pad.submittedRequestView.writablePasteboardTypes.allSatisfy(OmniPlainPasteboard.isPlainText))
}

@Test @MainActor func withoutTheIndexNothingIsAPill() throws {
    let pad = try findPad()
    pad.onRequestFindFacets = { nil }
    type("/find kind:review", into: pad)
    #expect(pad.editor.textStorage?.attribute(.backgroundColor, at: 11, effectiveRange: nil) == nil)
}

@Test @MainActor func typedPrefixesCompleteFacetsAndValues() throws {
    let pad = try findPad()
    type("/find k", into: pad)
    #expect(pad.completionChoices.map(\.canonicalText) == ["kind:"])
    type("/find rev", into: pad)
    #expect(pad.completionChoices.map(\.canonicalText) == ["kind:review", "tags:review-loop"], "rev suggests kind:review")
    type("/find in:h", into: pad)
    #expect(pad.completionChoices.map(\.canonicalText) == ["in:helios"])
    #expect(pad.acceptCompletion())
    #expect(pad.editor.string == "/find in:helios ")
    // A word with no matching facet value leaves the menu closed.
    type("/find adversarial", into: pad)
    #expect(!pad.isCompletionVisible)
    // Outside /find, plain words never open it.
    type("kind", into: pad)
    #expect(!pad.isCompletionVisible)
    // The slash palette is unchanged.
    type("/fi", into: pad)
    #expect(pad.completionChoices.map(\.canonicalText) == ["/find"])
}

@Test @MainActor func theFindPaletteHelpFitsTheLaptopBound() throws {
    let pad = try findPad()
    type("/find ", into: pad)
    _ = pad.editor.onTab?()
    #expect(OmniCompletionMenu.minimumHeight(for: pad.completionItems) <= 154, "C78's 13-inch bound")
    type("/find rev", into: pad)
    #expect(OmniCompletionMenu.minimumHeight(for: pad.completionItems) <= 154)
    let find = try #require(OmniCommandPadViewController.paletteItems(for: "/fi", manifest: pad.parser.manifest).first)
    #expect(find.choice.label == "Find documents by id, by picked filters, or in words")
    #expect(find.help.kind == "Command · local, words may ask a model")
    #expect(OmniCompletionMenu.minimumHeight(for: [find]) <= 154)
}

private let rows = [
    OmniFindRow(path: "/Users/fixture/Base/a.md", title: "Adversarial review", kind: "review", id: "569d5a7cf925cbd7"),
    OmniFindRow(path: "/Users/fixture/Base/b.md", title: "Second review", kind: "review"),
    OmniFindRow(path: "/Users/fixture/Tooling/agent-output/0123456789abcdef_run", title: "0123456789abcdef_run", kind: "run-folder", namespace: .run, id: "0123456789abcdef"),
]

private func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

@Test @MainActor func thePickerOpensRevealsAndCopiesStoredRows() throws {
    let pad = try findPad()
    var actions: [(String, Int, OmniPickerAction)] = []
    var opened: [String] = []
    pad.onPickerAction = { actions.append(($0, $1, $2)) }
    pad.onOpenResult = { opened.append($0) }
    type("/find kind:review", into: pad)
    pad.beginWorking(runID: "run-1", requestText: pad.editor.string)
    pad.showPicker(runID: "run-1", find: OmniFindResult(tier: .filters, typed: "kind:review", query: "kind:review", rows: rows, total: 3))
    #expect(pad.result?.kind == .picker)
    #expect(pad.pickerRowViews.count == 3)
    #expect(pad.routeLine == .outcome("Find · 3 found · kind:review"))
    #expect(pad.footerState.keyHints == OmniPadKeyHint.picker)
    let request = pad.submittedRequestView
    request.keyDown(with: key("\r", keyCode: 36))
    request.keyDown(with: key("", keyCode: 125))
    request.keyDown(with: key("\r", keyCode: 36, flags: .command))
    request.keyDown(with: key("c", keyCode: 8, flags: [.command, .option]))
    #expect(actions.map(\.1) == [0, 1, 1])
    #expect(actions.map(\.2) == [.open, .reveal, .copyPath])
    #expect(actions.allSatisfy { $0.0 == "run-1" })
    #expect(opened.isEmpty, "⌘↩ reveals here; it does not open the workspace")
    #expect(pad.routeLine == .notice("Copied the path of Second review"))
    // The run folder draws as a folder in the launcher's row idiom.
    #expect(OmniCommandPadViewController.candidate(for: rows[2]).source == .roots)
}

@Test @MainActor func anEmptyPickerSaysSoAndEnterCloses() throws {
    let pad = try findPad()
    var closed: [String] = []
    pad.onCloseResult = { closed.append($0) }
    pad.beginWorking(runID: "run-2", requestText: "/find kind:nothing")
    pad.showPicker(runID: "run-2", find: OmniFindResult(tier: .filters, typed: "kind:nothing", query: "kind:nothing", rows: [], total: 0))
    #expect(pad.routeLine == .outcome("Find · No match · kind:nothing"))
    pad.submittedRequestView.keyDown(with: key("\r", keyCode: 36))
    #expect(closed == ["run-2"])
}

@Test @MainActor func aLongPickerShowsTenRowsAndSaysWhereTheRestAre() throws {
    let pad = try findPad()
    let many = (0..<14).map { OmniFindRow(path: "/Users/fixture/Base/\($0).md", title: "Doc \($0)", kind: "note") }
    pad.beginWorking(runID: "run-3", requestText: "/find kind:note")
    pad.showPicker(runID: "run-3", find: OmniFindResult(tier: .filters, typed: "kind:note", query: "kind:note", rows: many, total: 14))
    #expect(OmniCommandPadViewController.pickerSummary(OmniFindResult(tier: .filters, typed: "kind:note", query: "kind:note", rows: many, total: 2968)).hasSuffix("first 10 here, 14 in the workspace"), "rows are capped; the count is not")
    #expect(pad.pickerRowViews.count == 10)
    #expect(pad.routeLine == .outcome("Find · 14 found · kind:note · first 10 here, all in the workspace"))
}
