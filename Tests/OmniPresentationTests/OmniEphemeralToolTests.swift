import AppKit
import Foundation
@testable import OmniPresentation
import Testing

private actor ControlledEphemeralProducer {
    typealias DeltaSink = @Sendable (String) async -> Void

    private struct Request {
        let onDelta: DeltaSink
        let completion: CheckedContinuation<String, Error>
    }

    private var requests: [String: Request] = [:]
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var starts: [String: Int] = [:]

    func run(_ input: String, onDelta: @escaping DeltaSink) async throws -> String {
        try await withCheckedThrowingContinuation { completion in
            starts[input, default: 0] += 1
            requests[input] = Request(onDelta: onDelta, completion: completion)
            for waiter in startWaiters.removeValue(forKey: input) ?? [] { waiter.resume() }
        }
    }

    func waitUntilStarted(_ input: String) async {
        if requests[input] != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters[input, default: []].append(continuation)
        }
    }

    func emit(_ delta: String, for input: String) async {
        await requests[input]?.onDelta(delta)
    }

    func complete(_ output: String, for input: String) {
        requests.removeValue(forKey: input)?.completion.resume(returning: output)
    }

    func cancel(_ input: String) {
        requests.removeValue(forKey: input)?.completion.resume(throwing: CancellationError())
    }

    func startedCount(for input: String) -> Int { starts[input, default: 0] }
}

private func descriptor(id: String = "fixture", maximumInputCharacters: Int = 4_096) -> OmniEphemeralToolDescriptor {
    OmniEphemeralToolDescriptor(
        id: id,
        title: "Fixture \(id)",
        subtitle: "Disposable text tool",
        inputPlaceholder: "Type source text",
        emptyResultHint: "Result appears here",
        maximumInputCharacters: maximumInputCharacters,
        debounce: .zero
    )
}

private func replayDescriptor() -> OmniEphemeralToolDescriptor {
    OmniEphemeralToolDescriptor(
        id: "pronounce", title: "Pronounce", subtitle: "English pronunciation",
        inputPlaceholder: "Type a word or phrase", emptyResultHint: "IPA appears here",
        routeTitle: "Pronunciation", routeProviderLabel: "Dictionary + audio",
        interaction: .explicitReplay, debounce: .zero
    )
}

@MainActor
private func waitForSession(_ predicate: () -> Bool) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        await Task.yield()
    }
    Issue.record("Session did not reach the expected state")
}

@Test @MainActor
func ephemeralNewestEditWinsAndPreviousOutputCannotBeCopied() async {
    let producer = ControlledEphemeralProducer()
    let session = OmniEphemeralSession(descriptor: descriptor()) { input, onDelta in
        try await producer.run(input, onDelta: onDelta)
    }

    session.open(input: "first")
    await producer.waitUntilStarted("first")
    await producer.emit("old partial", for: "first")
    #expect(session.output == "old partial")
    #expect(session.copyableOutput == nil)

    await producer.complete("old complete", for: "first")
    await waitForSession { session.copyableOutput == "old complete" }
    #expect(session.copyableOutput == "old complete")

    session.inputChanged("second")
    #expect(session.output == "old complete")
    #expect(!session.outputIsCurrent)
    #expect(session.copyableOutput == nil)
    await producer.waitUntilStarted("second")
    await producer.emit("new ", for: "second")
    #expect(session.output == "new ")
    await producer.emit("partial", for: "second")
    #expect(session.output == "new partial")
    session.inputChanged("third")
    #expect(session.output == "new partial")
    #expect(session.copyableOutput == nil)
    await producer.waitUntilStarted("third")
    await producer.emit("late second", for: "second")
    await producer.complete("late second complete", for: "second")
    #expect(session.output == "new partial")
    await producer.emit("latest delta", for: "third")
    #expect(session.output == "latest delta")
    await producer.complete("latest complete", for: "third")
    await waitForSession { session.copyableOutput == "latest complete" }
    #expect(session.copyableOutput == "latest complete")
    session.close()
}

@Test @MainActor
func ephemeralCurrentProducerCancellationExitsWaitingButStaleCancellationIsIgnored() async {
    let producer = ControlledEphemeralProducer()
    let session = OmniEphemeralSession(descriptor: descriptor()) { input, onDelta in
        try await producer.run(input, onDelta: onDelta)
    }

    session.open(input: "first")
    await producer.waitUntilStarted("first")
    session.inputChanged("second")
    await producer.waitUntilStarted("second")
    await producer.cancel("first")
    #expect(session.phase == .waiting)

    await producer.cancel("second")
    await waitForSession { if case .failed = session.phase { return true }; return false }
    #expect(session.phase == .failed("Unable to complete this request. Try again."))
    #expect(session.copyableOutput == nil)
    session.close()
}

@Test @MainActor
func ephemeralConceptLensWaitsForWholeMapAndIgnoresStreamedFragments() async {
    let producer = ControlledEphemeralProducer()
    let lens = OmniEphemeralToolDescriptor(id: "concept-lens", title: "Concept Lens", subtitle: "", inputPlaceholder: "Concept",
        emptyResultHint: "", resultStyle: .drawnConcept, debounce: .zero)
    let session = OmniEphemeralSession(descriptor: lens) { input, delta in try await producer.run(input, onDelta: delta) }
    session.open(input: "diagnosis")
    await producer.waitUntilStarted("diagnosis")
    await producer.emit("{\"name\":", for: "diagnosis")
    #expect(session.output.isEmpty && session.conceptLens == nil)
    #expect(session.phase == .waiting && session.copyableOutput == nil)
    await producer.complete(diagnosisLensJSON, for: "diagnosis")
    await waitForSession { session.phase == .ready }
    #expect(session.conceptLens?.map?.name == "Diagnosis")
    #expect(session.copyableOutput?.hasPrefix("Name: Diagnosis") == true)
    session.close()
}

@Test @MainActor
func ephemeralCloseIgnoresLateOutputAndReopenStartsEmpty() async {
    _ = NSApplication.shared
    let producer = ControlledEphemeralProducer()
    let window = OmniEphemeralWindowController(
        descriptor: descriptor(id: "other-tool"),
        producer: { input, onDelta in try await producer.run(input, onDelta: onDelta) },
        presentsInterface: false
    )
    var copied: [String] = []
    window.onCopy = { copied.append($0) }

    window.show(input: "source")
    #expect(window.isVisible)
    #expect(window.session.isOpen)
    await producer.waitUntilStarted("source")
    window.dismiss()
    #expect(!window.isVisible)
    #expect(window.session.input.isEmpty)
    #expect(window.session.output.isEmpty)
    #expect(window.viewController.editor.string.isEmpty)

    await producer.emit("late delta", for: "source")
    await producer.complete("late complete", for: "source")
    await Task.yield()
    #expect(window.session.output.isEmpty)
    window.copyCurrentOutput()
    #expect(copied.isEmpty)

    window.show(input: "")
    #expect(window.session.phase == .empty)
    #expect(window.session.input.isEmpty)
    #expect(window.session.output.isEmpty)
    window.dismiss()
}

@Test @MainActor
func ephemeralOverlongInputIsVisibleAndDoesNotStartProducer() async {
    _ = NSApplication.shared
    let session = OmniEphemeralSession(descriptor: descriptor(maximumInputCharacters: 4)) { _, _ in
        Issue.record("Overlong input must not reach the producer")
        return "unexpected"
    }
    session.open(input: "longer than four")
    #expect(session.input == "longer than four")
    #expect(session.phase == .failed("Input is too long. Select or type less text."))
    #expect(session.copyableOutput == nil)
    session.close()
}

@Test @MainActor
func ephemeralDifferentToolCanBoundItsOutputAndFocusLossClearsIt() async {
    _ = NSApplication.shared
    let spec = OmniEphemeralToolDescriptor(
        id: "bounded-other-tool", title: "Other tool", subtitle: "Fixture",
        inputPlaceholder: "Input", emptyResultHint: "Output",
        maximumOutputCharacters: 4, debounce: .zero
    )
    let window = OmniEphemeralWindowController(
        descriptor: spec,
        producer: { _, delta in await delta("oversized"); return "oversized" },
        presentsInterface: false
    )
    window.show(input: "source")
    await waitForSession { window.session.phase == .failed("Result is too long to display.") }
    #expect(window.session.output.isEmpty)
    #expect(window.session.copyableOutput == nil)
    // Exercise the focus-loss hook without ever ordering the panel onscreen.
    window.panel?.resignKey()
    #expect(!window.session.isOpen)
    #expect(window.session.input.isEmpty)
}

@Test @MainActor
func ephemeralNarrowViewKeepsControlsInsideItsBounds() {
    _ = NSApplication.shared
    let window = OmniEphemeralWindowController(
        descriptor: descriptor(id: "narrow"),
        producer: { _, _ in "Result" },
        presentsInterface: false
    )
    window.show(input: "")
    let view = window.viewController.view
    view.frame.size = NSSize(width: 340, height: 300)
    view.layoutSubtreeIfNeeded()
    #expect(window.viewController.copyButton.frame.maxX <= view.bounds.maxX)
    #expect(window.viewController.keyHintsView.frame.minX >= view.bounds.minX)
    #expect(window.viewController.routeLabel.frame.maxX <= view.bounds.maxX)
    #expect(window.viewController.routeLabel.frame.minY > window.viewController.keyHintsView.frame.maxY)
    #expect((window.viewController.editor.enclosingScrollView?.frame.maxX ?? .infinity) <= view.bounds.maxX)
    #expect((window.viewController.resultTextView.enclosingScrollView?.frame.maxX ?? .infinity) <= view.bounds.maxX)
    window.dismiss()
}

@Test @MainActor
func ephemeralCompactResultKeepsOldTextUntilFirstNewChunkAndCopiesOnlyCurrentResult() async throws {
    _ = NSApplication.shared
    let producer = ControlledEphemeralProducer()
    let spec = OmniEphemeralToolDescriptor(
        id: "quick-question", title: "Quick Question", subtitle: "Ask and get a concise answer",
        inputPlaceholder: "Type a question", emptyResultHint: "", routeTitle: "Quick answer", debounce: .zero
    )
    let window = OmniEphemeralWindowController(
        descriptor: spec, producer: { input, onDelta in try await producer.run(input, onDelta: onDelta) },
        presentsInterface: false
    )
    var copied: [String] = []
    window.onCopy = { copied.append($0) }
    window.show(input: "")
    let view = window.viewController
    #expect(view.view.frame.width == 640)
    #expect(view.editor.placeholderString == "Type a question")
    #expect(view.routeLabel.stringValue == "Provider")
    #expect(view.toolPill.title == "Quick Question")
    #expect(view.toolPill.frame.height == 22)
    #expect(view.resultTextView.enclosingScrollView?.superview == nil)
    #expect(!view.copyButton.isEnabled)
    #expect(view.keyHintsView.hints == [.init("esc", "Close")])

    window.session.inputChanged("capital of azerbaijan")
    await producer.waitUntilStarted("capital of azerbaijan")
    await producer.emit("Baku", for: "capital of azerbaijan")
    #expect(view.resultTextView.string == "Baku")
    #expect(view.resultTextView.enclosingScrollView?.superview === view.view)
    #expect(view.resultTextView.alphaValue == 1)
    #expect(!view.copyButton.isEnabled)
    await producer.complete("Baku, Azerbaijan's capital", for: "capital of azerbaijan")
    await waitForSession { window.session.phase == .ready }
    #expect(view.copyButton.isEnabled)

    window.session.inputChanged("capital and population")
    #expect(view.resultTextView.string == "Baku, Azerbaijan's capital")
    #expect(view.resultTextView.alphaValue == 0.42)
    #expect(!view.copyButton.isEnabled)
    window.copyCurrentOutput()
    #expect(copied.isEmpty)
    #expect(window.session.isOpen)
    await producer.waitUntilStarted("capital and population")
    await producer.emit("Baku; ", for: "capital and population")
    #expect(view.resultTextView.string == "Baku; ")
    #expect(view.resultTextView.alphaValue == 1)
    await producer.complete("Baku; population about 2.3 million", for: "capital and population")
    await waitForSession { window.session.phase == .ready }
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    view.editor.keyDown(with: enter)
    #expect(copied == ["Baku; population about 2.3 million"])
    #expect(!window.session.isOpen)
    #expect(window.session.output.isEmpty)
}

@Test @MainActor
func toolPillReservesOnlyFirstLineAndLongInputUsesFullWidthBelow() throws {
    _ = NSApplication.shared
    let window = OmniEphemeralWindowController(
        descriptor: descriptor(id: "long-field"), producer: { _, _ in "unused" },
        presentsInterface: false)
    window.show(input: "")
    let view = window.viewController
    view.view.setFrameSize(NSSize(width: 360, height: view.view.frame.height))
    window.session.inputChanged(String(repeating: "A long question about how the trailing tool token behaves in a live input field. ", count: 5))
    view.render()

    let editor = view.editor
    let manager = try #require(editor.layoutManager)
    let container = try #require(editor.textContainer)
    manager.ensureLayout(for: container)
    var fragments: [NSRect] = []
    var index = 0
    while index < manager.numberOfGlyphs {
        var range = NSRange()
        fragments.append(manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range))
        index = NSMaxRange(range)
    }
    #expect(fragments.count >= 3)
    #expect(fragments[0].width + view.toolPill.fittingWidth < fragments[1].width)
    #expect(abs(fragments[1].width - editor.frame.width) < 2)
    #expect(editor.enclosingScrollView?.frame.height ?? 0 > 25)
    #expect(view.toolPill.frame.minX >= (editor.enclosingScrollView?.frame.minX ?? 0))
    #expect(view.toolPill.hitTest(NSPoint(x: 2, y: 2)) == nil)
    #expect(view.toolPill.isAccessibilityElement())
    #expect(view.toolPill.accessibilityLabel() == "Fixture long-field")
    #expect(!view.toolPill.acceptsFirstResponder)
    let scroll = try #require(editor.enclosingScrollView)
    let bottom = max(0, editor.frame.height - scroll.contentView.bounds.height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
    scroll.reflectScrolledClipView(scroll.contentView)
    manager.ensureLayout(for: container)
    let visibleTop = scroll.contentView.bounds.minY
    let exclusion = try #require(container.exclusionPaths.first?.bounds)
    #expect(abs(exclusion.minY - visibleTop) < 1)
    let firstVisibleGlyph = manager.glyphIndex(for: NSPoint(x: 0, y: visibleTop + 1), in: container)
    let firstVisibleLine = manager.lineFragmentRect(forGlyphAt: firstVisibleGlyph, effectiveRange: nil)
    #expect(firstVisibleLine.maxX <= exclusion.minX + 1)
    if let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            OmniNativeCaptureHarness.prepare(view.view, scenario: .longEditor,
                treatment: .opaqueFallback, appearance: appearance)
            let image = OmniNativeCaptureHarness.image(of: view.view)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("ephemeral-pill-scrolled-\(appearance.rawValue).png"))
        }
    }
    window.dismiss()
}

@Test @MainActor
func markedTextEscapeDoesNotCloseTheToolUntilCompositionEnds() throws {
    _ = NSApplication.shared
    let window = OmniEphemeralWindowController(
        descriptor: descriptor(id: "ime-escape"), producer: { _, _ in "unused" },
        presentsInterface: false)
    window.show(input: "")
    let editor = window.viewController.editor
    editor.setMarkedText("ä", selectedRange: NSRange(location: 1, length: 0),
                         replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.hasMarkedText())
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 53))
    editor.keyDown(with: escape)
    #expect(window.session.isOpen)
    #expect(!editor.hasMarkedText())
    editor.keyDown(with: escape)
    #expect(!window.session.isOpen)
}

@Test @MainActor
func explicitEphemeralWaitsForEnterAndReplaysUnchangedInput() async throws {
    _ = NSApplication.shared
    let producer = ControlledEphemeralProducer()
    let window = OmniEphemeralWindowController(
        descriptor: replayDescriptor(),
        producer: { input, onDelta in try await producer.run(input, onDelta: onDelta) },
        presentsInterface: false
    )
    var copied: [String] = []
    window.onCopy = { copied.append($0) }
    window.show(input: "first")
    let view = window.viewController
    #expect(view.routeLabel.stringValue == "Pronunciation · Dictionary + audio")
    #expect(view.copyButton.isEnabled)
    #expect(view.keyHintsView.hints == [.init("↩", "Pronounce"), .init("esc", "Stop and close")])
    window.session.inputChanged("word")
    for _ in 0..<10 { await Task.yield() }
    #expect(await producer.startedCount(for: "first") == 0)
    #expect(await producer.startedCount(for: "word") == 0)

    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    view.editor.keyDown(with: enter)
    await producer.waitUntilStarted("word")
    #expect(await producer.startedCount(for: "word") == 1)
    #expect(window.session.phase == .waiting)
    await producer.emit("/wɜːd/ · Wiktionary", for: "word")
    #expect(view.resultTextView.string == "/wɜːd/ · Wiktionary")
    #expect(window.session.phase == .streaming)
    await producer.complete("/wɜːd/ · Wiktionary", for: "word")
    await waitForSession { window.session.phase == .ready }
    #expect(view.keyHintsView.hints == [.init("↩", "Replay"), .init("esc", "Stop and close")])
    let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
        characters: "C", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    view.editor.keyDown(with: copy)
    #expect(copied == ["/wɜːd/ · Wiktionary"])
    #expect(window.session.isOpen)
    view.resultTextView.keyDown(with: enter)
    await producer.waitUntilStarted("word")
    #expect(await producer.startedCount(for: "word") == 2)
    #expect(window.session.isOpen)
    #expect(copied == ["/wɜːd/ · Wiktionary"])
    #expect(!window.session.outputIsCurrent)
    await producer.complete("/wɜːd/ · Wiktionary", for: "word")
    await waitForSession { window.session.phase == .ready }
    window.dismiss()
}

@Test @MainActor
func explicitEphemeralSelectedInputRunsOnceAndCloseRejectsLateOutput() async throws {
    _ = NSApplication.shared
    let producer = ControlledEphemeralProducer()
    let window = OmniEphemeralWindowController(
        descriptor: replayDescriptor(),
        producer: { input, onDelta in try await producer.run(input, onDelta: onDelta) },
        presentsInterface: false
    )
    window.show(input: "", submitImmediately: true)
    #expect(window.session.phase == .empty)
    #expect(await producer.startedCount(for: "") == 0)
    window.show(input: "selected", submitImmediately: true)
    await producer.waitUntilStarted("selected")
    #expect(await producer.startedCount(for: "selected") == 1)
    window.session.inputChanged("edited")
    await producer.emit("late selection", for: "selected")
    #expect(window.session.output.isEmpty)
    #expect(window.session.phase == .empty)

    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    window.viewController.editor.keyDown(with: enter)
    await producer.waitUntilStarted("edited")
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
    window.viewController.editor.keyDown(with: escape)
    await producer.emit("late edited", for: "edited")
    await producer.complete("late edited complete", for: "edited")
    await producer.complete("late selection complete", for: "selected")
    await Task.yield()
    #expect(!window.session.isOpen)
    #expect(window.session.output.isEmpty)
}

@Test @MainActor
func ephemeralCapturedSelectionClearsAndResizingKeepsSpotlightTop() async {
    _ = NSApplication.shared
    let window = OmniEphemeralWindowController(
        descriptor: descriptor(id: "translate"),
        producer: { _, _ in String(repeating: "Long result line with a few words.\n", count: 80) },
        presentsInterface: false
    )
    let capture = OmniPadProvenance(source: "Safari", detail: "Besserwisser – Wiktionary", wordCount: 1,
                                    bundleIdentifier: "com.apple.Safari")
    window.show(input: "Besserwisser", provenance: capture)
    let initialTop = window.panel?.frame.maxY
    #expect(window.viewController.provenance == capture)
    #expect(!window.viewController.provenanceChip.isHidden)
    await waitForSession { window.session.phase == .ready }
    #expect(window.panel?.frame.maxY == initialTop)
    let result = window.viewController.resultTextView
    #expect(result.frame.height > (result.enclosingScrollView?.contentView.bounds.height ?? .infinity))
    window.viewController.dropCapturedSelection()
    #expect(window.viewController.provenance == nil)
    #expect(window.viewController.provenanceChip.isHidden)
    #expect(window.session.input.isEmpty)
    #expect(window.session.output.isEmpty)
    #expect(window.panel?.frame.maxY == initialTop)
    window.dismiss()
}

@Test @MainActor
func ephemeralConceptResultUsesBodyHeadingsAndKeepsOriginalCopyText() {
    let source = "PRIMARY\n- Name: Construct validity\n- Definition: Measures the intended construct.\nNEAR MISSES\n- Reliability: consistency, not truth\nMAP\n- Parents: validity"
    let rendered = OmniEphemeralResultRenderer.attributed(source, style: .structured)
    #expect(rendered.string.contains("BEST NAME\nConstruct validity"))
    #expect(rendered.string.contains("DEFINITION\nMeasures the intended construct."))
    #expect(rendered.string.contains("NEAR MISSES"))
    #expect(rendered.string.contains("MAP"))
    #expect(!rendered.string.contains("- Name:"))
    #expect(source.contains("PRIMARY\n- Name:"))
}

/// Opt-in screenshots of real AppKit views with fake producers only. No window
/// is ordered and no provider or desktop application is activated.
@Test @MainActor
func ephemeralDesignCaptures() async throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return }
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let translation = OmniEphemeralToolDescriptor(
        id: "translate", title: "Translate", subtitle: "German → English",
        inputPlaceholder: "Type a German word or phrase", emptyResultHint: "",
        routeTitle: "German → English", debounce: .zero
    )
    let quick = OmniEphemeralToolDescriptor(
        id: "quick-question", title: "Quick Question", subtitle: "Ask and get a concise answer",
        inputPlaceholder: "Type a question", emptyResultHint: "",
        routeTitle: "Quick answer", debounce: .zero
    )
    let concept = OmniEphemeralToolDescriptor(
        id: "concept-lens", title: "Concept Lens", subtitle: "Name, define, and map a concept",
        inputPlaceholder: "Describe a concept or enter a term", emptyResultHint: "",
        routeTitle: "Concept lens", resultStyle: .drawnConcept, debounce: .zero
    )
    let emptyL = OmniEphemeralWindowController(
        descriptor: translation, producer: { _, _ in "unused" }, presentsInterface: false
    )
    emptyL.show(input: "")

    let staleProducer = ControlledEphemeralProducer()
    let staleK = OmniEphemeralWindowController(
        descriptor: quick,
        producer: { input, onDelta in try await staleProducer.run(input, onDelta: onDelta) },
        presentsInterface: false
    )
    staleK.show(input: "capital of azerbaijan")
    await staleProducer.waitUntilStarted("capital of azerbaijan")
    await staleProducer.complete("Baku", for: "capital of azerbaijan")
    await waitForSession { staleK.session.phase == .ready }
    staleK.session.inputChanged("capital of azerbaijan, and its popul")
    await staleProducer.waitUntilStarted("capital of azerbaijan, and its popul")
    for _ in 0..<4 { await Task.yield() }

    let completedL = OmniEphemeralWindowController(
        descriptor: translation,
        producer: { _, _ in "1. know-it-all · the everyday equivalent; mildly pejorative\n2. smart aleck · sharper and more informal\n3. wise guy · American, with a hint of insolence" },
        presentsInterface: false
    )
    completedL.show(input: "Besserwisser", provenance: OmniPadProvenance(
        source: "Safari", detail: "Besserwisser – Wiktionary", wordCount: 1,
        bundleIdentifier: "com.apple.Safari"))
    await waitForSession { completedL.session.phase == .ready }

    let structuredM = OmniEphemeralWindowController(
        descriptor: concept,
        producer: { _, _ in diagnosisLensJSON },
        presentsInterface: false
    )
    structuredM.show(input: "diagnosis")
    await waitForSession { structuredM.session.phase == .ready }

    let longResult = OmniEphemeralWindowController(
        descriptor: concept,
        producer: { _, _ in String(repeating: "- Related concept: a longer explanation that spans several lines in the result.\n", count: 40) },
        presentsInterface: false
    )
    longResult.show(input: "a dense concept map")
    await waitForSession { longResult.session.phase == .ready }

    let longField = OmniEphemeralWindowController(
        descriptor: quick, producer: { _, _ in "A concise answer." }, presentsInterface: false
    )
    longField.show(input: String(repeating: "How should this tool handle a long question while its identity stays at the field edge? ", count: 5))
    await waitForSession { longField.session.phase == .ready }

    for (name, window, scenario) in [
        ("empty-l", emptyL, OmniNativeCaptureScenario.emptyEditor),
        ("stale-k", staleK, .longEditor),
        ("completed-l-provenance", completedL, .longEditor),
        ("structured-m", structuredM, .longEditor),
        ("long-result-fade", longResult, .longEditor),
        ("long-input-pill-640", longField, .longEditor)
    ] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = window.viewController.view
            OmniNativeCaptureHarness.prepare(view, scenario: scenario, treatment: .opaqueFallback, appearance: appearance)
            let image = OmniNativeCaptureHarness.image(of: view)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("ephemeral-\(name)-\(appearance.rawValue).png"))
        }
        window.dismiss()
    }
    await staleProducer.complete("unused", for: "capital of azerbaijan, and its popul")
}
