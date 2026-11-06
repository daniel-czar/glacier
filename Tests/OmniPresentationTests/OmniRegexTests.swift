import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

private let regexDates = #"^(\d{4})-(\d{2})-(\d{2})$"#
private let regexSelection = "2026-10-31\n2026-11-01\n31/10/2026\n1993-08-02"
private let regexGenerated = RegexGeneratedPattern(pattern: #"^[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}$"#,
    name: "UK postcode", shouldMatch: ["SW8 2LD", "EC1A 1BB", "M1 1AE"],
    shouldNotMatch: ["sw8 2ld", "SW8 2LD"])

@MainActor private func waitForRegex(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await predicate())
}

private actor RegexGeneratorProbe {
    private var completions: [CheckedContinuation<RegexGeneratedPattern, Never>] = []
    private(set) var started = 0
    func run(_ query: String) async -> RegexGeneratedPattern {
        started += 1
        return await withCheckedContinuation { completions.append($0) }
    }
    func finish(_ value: RegexGeneratedPattern) { if !completions.isEmpty { completions.removeFirst().resume(returning: value) } }
}

@Suite(.serialized) struct OmniRegexTests {
    @MainActor private func makeSession(entries: [RegexSheetEntry] = []) -> OmniRegexSession {
        OmniRegexSession(entries: entries, debounce: .milliseconds(1),
            generator: { _ in regexGenerated }, add: { _, _ in true }, undo: { true })
    }
    @Test @MainActor func dateReadoutRunsOnlyLocallyAndCopiesPattern() async throws {
        _ = NSApplication.shared
        let probe = RegexGeneratorProbe()
        let session = OmniRegexSession(entries: [], generator: { await probe.run($0) }, add: { _, _ in false }, undo: { false })
        let window = OmniRegexWindowController(session: session, presentsInterface: false)
        var copied: String?
        window.onCopy = { copied = $0 }
        window.show(input: regexDates, selection: regexSelection,
                    provenance: OmniPadProvenance(source: "Ghostty", detail: "dates.txt", wordCount: 4))
        try await waitForRegex { session.analysis != nil }
        #expect(session.summary == "3 groups · anchored · ICU")
        #expect(session.selectionMatches?.matchingLineCount == 3)
        #expect(session.selectionMatches?.totalLineCount == 4)
        #expect(session.selectionMatches?.lines.first?.captures == ["2026", "10", "31"])
        #expect(await probe.started == 0)
        let view = window.viewController
        #expect(view.editor.font == .monospacedSystemFont(ofSize: 15, weight: .regular))
        #expect(descendants(view.view).contains { $0.accessibilityIdentifier() == "omni.regex.railroad" })
        #expect(descendants(view.view).filter { $0.accessibilityIdentifier().hasPrefix("omni.regex.match.") }.count == 4)
        capture(view.view, "read-date")
        view.editor.onSubmit?()
        #expect(copied == regexDates)
        #expect(!session.isOpen)
        #expect(session.input.isEmpty && session.selection == nil && session.analysis == nil)
    }
    @Test @MainActor func generatedExamplesAreCheckedAndSaveUndoIsExplicit() async throws {
        _ = NSApplication.shared
        var written: RegexSheetEntry?
        var entries: [RegexSheetEntry] = []
        let session = OmniRegexSession(entries: [], debounce: .milliseconds(1), generator: { _ in regexGenerated },
            add: { entry, _ in written = entry; entries.append(entry); return true },
            undo: { entries = []; return true }, reload: { entries })
        let window = OmniRegexWindowController(session: session, presentsInterface: false)
        window.show(input: "uk postcode")
        try await waitForRegex { session.exampleEvaluation != nil }
        #expect(session.exampleEvaluation?.examples.count == 5)
        #expect(session.exampleEvaluation?.examples.last?.verdict == "✗ should not · matches")
        #expect(session.summary == "Sheet · Provider · 1 example fails")
        #expect(session.selectedPattern == regexGenerated.pattern && session.generatedIsSelected)
        #expect(session.canAddSelected)
        capture(window.viewController.view, "generated-bad-example")
        let commandS = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        #expect(window.viewController.editor.performKeyEquivalent(with: commandS))
        try await waitForRegex { !session.isSaving }
        #expect(written?.name == "UK postcode")
        #expect(session.notice == "Added to sheet ⌘Z")
        #expect(session.canUndoAdd && !session.canAddSelected)
        let commandZ = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        #expect(window.viewController.editor.performKeyEquivalent(with: commandZ))
        try await waitForRegex { !session.isSaving && session.analysis != nil }
        #expect(entries.isEmpty && session.generated != nil && !session.canUndoAdd)
        window.dismiss()
    }
    @Test @MainActor func nativeEditingKeepsCaretAndRunsCurrentPattern() async throws {
        _ = NSApplication.shared
        let window = OmniRegexWindowController(session: makeSession(), presentsInterface: false)
        window.show()
        let editor = window.viewController.editor
        editor.insertText("foo|bar", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.string == "foo|bar")
        #expect(window.session.input == "foo|bar")
        try await waitForRegex { window.session.analysis != nil }
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText("x", replacementRange: editor.selectedRange())
        #expect(editor.string == "foox|bar" && window.session.input == "foox|bar")
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
        editor.insertText(#"(?i)^(foo|bar)+$"#, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try await waitForRegex { window.session.analysis?.flagsSummary.contains("case-insensitive") == true }
        #expect(window.session.summary == "1 group · anchored · ICU · case-insensitive")
        capture(window.viewController.view, "alternation")
        window.dismiss()
    }
    @Test @MainActor func staleGeneratorAndReadMatchesCannotResurrectDismissedSession() async throws {
        let probe = RegexGeneratorProbe()
        let session = OmniRegexSession(entries: [], debounce: .milliseconds(5),
            generator: { await probe.run($0) }, add: { _, _ in false }, undo: { false })
        session.open(input: "postcode")
        try await waitForRegex { await probe.started == 1 }
        session.inputChanged(regexDates)
        try await waitForRegex { session.analysis != nil }
        await probe.finish(regexGenerated)
        try await Task.sleep(for: .milliseconds(25))
        #expect(session.generated == nil && session.selectedPattern == regexDates)
        session.close()
        #expect(session.analysis == nil && session.exampleEvaluation == nil && session.selectionMatches == nil)
    }

    @Test @MainActor func currentRegexCancellationExitsGenerating() async throws {
        let session = OmniRegexSession(entries: [], debounce: .zero,
            generator: { _ in throw CancellationError() }, add: { _, _ in false }, undo: { false })
        session.open(input: "postcode")
        try await waitForRegex { !session.isGenerating }
        #expect(session.error == "The selected provider could not write a pattern. Edit the intent to try again.")
        #expect(session.generated == nil)
        session.close()
    }
    @Test @MainActor func sheetHitStopsCascadeAndLongOrInvalidPatternsRemainVisible() async throws {
        _ = NSApplication.shared
        let entry = RegexSheetEntry(name: "Email", pattern: #"^[\w.+-]+@[\w-]+\.[\w.-]+$"#)
        let probe = RegexGeneratorProbe()
        let session = OmniRegexSession(entries: [entry], debounce: .milliseconds(1),
            generator: { await probe.run($0) }, add: { _, _ in false }, undo: { false })
        let window = OmniRegexWindowController(session: session, presentsInterface: false)
        window.show()
        #expect(session.selectedPattern == entry.pattern)
        capture(window.viewController.view, "sheet")
        session.inputChanged("emali")
        #expect(session.sheetRows == [entry] && !session.isGenerating)
        try await waitForRegex { session.analysis?.pattern == entry.pattern }
        #expect(descendants(window.viewController.view).contains { $0.accessibilityIdentifier() == "omni.regex.railroad" })
        let long = "^" + String(repeating: "a", count: 248) + "$"
        session.inputChanged(long)
        try await waitForRegex { session.analysis?.diagramStatus == .tooLong }
        #expect(session.summary.contains("no diagram · too long"))
        #expect(session.selectedPattern == long)
        session.inputChanged("[unclosed")
        try await waitForRegex { session.analysis?.compileFailure != nil }
        #expect(session.failure != nil)
        #expect(window.viewController.routeLabel.toolTip == session.failure)
        capture(window.viewController.view, "invalid")
        #expect(await probe.started == 0)
        window.dismiss()
    }
    @Test @MainActor func asyncRenderingPreservesProvisionalMarkedText() async throws {
        _ = NSApplication.shared
        let probe = RegexGeneratorProbe()
        let session = OmniRegexSession(entries: [], debounce: .milliseconds(1), generator: { await probe.run($0) },
            add: { _, _ in false }, undo: { false })
        let window = OmniRegexWindowController(session: session, presentsInterface: false)
        window.show(input: "postcode")
        try await waitForRegex { await probe.started == 1 }
        let editor = window.viewController.editor
        editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        let provisional = editor.string
        #expect(editor.hasMarkedText())
        await probe.finish(regexGenerated)
        try await waitForRegex { session.exampleEvaluation != nil }
        #expect(editor.hasMarkedText() && editor.string == provisional)
        var copied = false
        window.onCopy = { _ in copied = true }
        window.copyCurrentSelection()
        #expect(!copied && session.isOpen)
        editor.unmarkText()
        window.dismiss()
    }
    @Test @MainActor func diagramAndVerdictsAlwaysFollowSelectedPattern() async throws {
        let sheet = RegexSheetEntry(name: "postcode", pattern: #"^\d+$"#)
        let session = makeSession(entries: [sheet])
        session.open(input: "postcode letters", selection: "123\nno")
        try await waitForRegex { session.exampleEvaluation != nil }
        #expect(session.generatedIsSelected && session.analysis?.pattern == regexGenerated.pattern)
        session.select(0)
        #expect(session.selectedPattern == sheet.pattern)
        try await waitForRegex { session.analysis?.pattern == sheet.pattern }
        #expect(session.exampleEvaluation == nil && session.selectionMatches?.matchingLineCount == 1)
        session.select(session.sheetRows.count)
        try await waitForRegex { session.exampleEvaluation != nil }
        #expect(session.analysis?.pattern == regexGenerated.pattern)
        #expect(session.selectionMatches == nil)
        session.close()
    }
    @Test @MainActor func staleSavePreservesCurrentSheetSelectionAndProjection() async throws {
        let first = RegexSheetEntry(name: "letter digits", pattern: #"^\d+$"#)
        let second = RegexSheetEntry(name: "letter capitals", pattern: #"^[A-Z]+$"#)
        var written = [first, second]
        var saveContinuation: CheckedContinuation<Bool, Never>?
        let probe = RegexGeneratorProbe()
        let session = OmniRegexSession(entries: written, debounce: .milliseconds(1),
            generator: { input in input == "first unmatched" ? regexGenerated : await probe.run(input) },
            add: { entry, _ in
                written.append(entry)
                return await withCheckedContinuation { saveContinuation = $0 }
            }, undo: { false }, reload: { written })
        session.open(input: "first unmatched")
        try await waitForRegex { session.canAddSelected }
        #expect(session.addSelectedToSheet())
        try await waitForRegex { saveContinuation != nil }
        session.inputChanged("letter value")
        try await waitForRegex { await probe.started == 1 }
        session.select(1)
        try await waitForRegex { session.analysis?.pattern == second.pattern }
        saveContinuation?.resume(returning: true)
        try await waitForRegex { !session.isSaving && session.analysis?.pattern == second.pattern }
        #expect(session.selectedPattern == second.pattern && session.exampleEvaluation == nil)
        session.close()
        await probe.finish(regexGenerated)
    }
    @Test @MainActor func sharedPanelIsReusedAndClearingChipKeepsPattern() async throws {
        _ = NSApplication.shared
        let window = OmniRegexWindowController(session: makeSession(), presentsInterface: false)
        window.show(input: regexDates, selection: regexSelection, provenance: OmniPadProvenance(source: "Ghostty", wordCount: 4))
        try await waitForRegex { window.session.analysis != nil }
        window.viewController.provenanceChip.onClear?()
        #expect(window.session.selection == nil && window.session.input == regexDates)
        #expect(window.session.selectionMatches == nil)
        let shared = try #require(window.relinquishPanelForReplacement())
        window.dismiss()
        let next = OmniRegexWindowController(session: makeSession(), presentsInterface: false)
        next.show(reusing: shared)
        #expect(next.panel === shared)
        next.dismiss()
    }
    @MainActor private func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
    @MainActor private func capture(_ view: NSView, _ name: String) {
        guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            OmniNativeCaptureHarness.prepare(view, scenario: .longEditor, treatment: .opaqueFallback, appearance: appearance)
            let image = OmniNativeCaptureHarness.image(of: view)
            guard let bitmap = image.representations.first as? NSBitmapImageRep,
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: directory.appendingPathComponent("regex-\(name)-\(appearance.rawValue).png"))
        }
    }
}
