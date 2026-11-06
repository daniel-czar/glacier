import AppKit
@testable import OmniPresentation
import Testing

private actor PronunciationViewProducer {
    private var emit: (@Sendable (String) async -> Void)?
    private var finish: CheckedContinuation<String, Never>?
    private(set) var starts = 0

    func run(_ input: String, delta: @escaping @Sendable (String) async -> Void) async -> String {
        starts += 1
        emit = delta
        return await withCheckedContinuation { finish = $0 }
    }
    func send(_ event: String) async { await emit?(event + "\n") }
    func complete(_ result: String) { finish?.resume(returning: result); finish = nil }
}

private let nonSequiturRows = #"[{"accent":"GA","ipa":"ˌnɑn ˈsɛkwɪtɚ","source":"wiktionary"},{"accent":"UK","ipa":"ˌnɒn ˈsɛkwɪtə","source":"wiktionary"}]"#
private let forvoAudio = #"{"source":"forvo","accent":"US","attribution":"Alice","online":true}"#
private let commonsAudio = #"{"source":"wiktionary","accent":"US","attribution":"Commons","path":"/fixture/read.wav","source_url":"https://commons.wikimedia.org/wiki/File:Read.wav"}"#

private func transcriptionEvent(_ rows: String) -> String {
    #"{"version":1,"event":"transcriptions","transcriptions":\#(rows)}"#
}
private func audioEvent(_ audio: String) -> String {
    #"{"version":1,"event":"audio","audio":\#(audio)}"#
}
private func resultJSON(rows: String, audio: String, played: String, errors: String = "[]", exit: Int = 0) -> String {
    #"{"transcriptions":\#(rows),"audio":[\#(audio)],"played":"\#(played)","errors":\#(errors),"exit_code":\#(exit)}"#
}

@MainActor private func pronunciationWindow(_ producer: PronunciationViewProducer) -> OmniEphemeralWindowController {
    _ = NSApplication.shared
    return OmniEphemeralWindowController(descriptor: OmniEphemeralToolDescriptor(
        id: "pronunciation", title: "Pronounce", subtitle: "", inputPlaceholder: "Enter a word or short phrase",
        emptyResultHint: "", routeProviderLabel: "", resultStyle: .pronunciation, interaction: .explicitReplay
    ), producer: { input, delta in await producer.run(input, delta: delta) }, presentsInterface: false)
}

@MainActor private func waitForPronunciation(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await predicate())
}

@MainActor private func capturePronunciationView(_ window: OmniEphemeralWindowController, _ name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let view = window.viewController.view
        OmniNativeCaptureHarness.prepare(view, scenario: .longEditor, treatment: .opaqueFallback, appearance: appearance)
        let image = OmniNativeCaptureHarness.image(of: view)
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("h13-\(name)-\(appearance.rawValue).png"))
    }
}

@Suite(.serialized) struct PronunciationViewTests {
    @Test @MainActor func fullAccentNamesKeepIPAInOneColumn() async throws {
        let rows = #"[{"accent":"GA","ipa":"first","source":"wiktionary"},{"accent":"UK","ipa":"second","source":"wiktionary"},{"accent":"Canada","ipa":"third","source":"wiktionary"},{"accent":"Australia","ipa":"fourth","source":"wiktionary"}]"#
        let producer = PronunciationViewProducer()
        let window = pronunciationWindow(producer)
        window.show(input: "non sequitur", submitImmediately: true)
        try await waitForPronunciation { await producer.starts == 1 }
        await producer.complete(resultJSON(rows: rows, audio: commonsAudio, played: "/fixture/read.wav"))
        try await waitForPronunciation { window.session.phase == .ready }
        let text = window.viewController.resultTextView
        let layout = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        layout.ensureLayout(for: container)
        let positions = ["/first/", "/second/", "/third/", "/fourth/"].map { ipa in
            let characters = (text.string as NSString).range(of: ipa)
            let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphs, in: container).minX
        }
        #expect(positions.allSatisfy { abs($0 - positions[0]) < 1 })
        #expect(positions[0] < 100)
        try capturePronunciationView(window, "full-accent-names")
        window.dismiss()
    }

    @Test @MainActor func lookupPlayingRestReplaySelectionAndEscape() async throws {
        let producer = PronunciationViewProducer()
        let window = pronunciationWindow(producer)
        let view = window.viewController
        window.show(input: "non sequitur", provenance: OmniPadProvenance(
            source: "TextEdit", detail: "Notes – Latin phrases", wordCount: 2), submitImmediately: true)
        try await waitForPronunciation { await producer.starts == 1 }
        #expect(view.routeLabel.stringValue == "Sources")
        #expect(view.toolPill.title == "Pronounce")
        #expect(view.keyHintsView.hints == [.init("esc", "Close")])
        #expect(!view.copyButton.isEnabled)
        #expect(view.resultTextView.enclosingScrollView?.superview == nil)
        #expect(view.view.subviews.contains { $0.accessibilityIdentifier() == "omni.ephemeral.working" })
        #expect(view.provenanceChip.attributedLabel?.string.contains("TextEdit · Notes – Latin phrases") == true)
        #expect(view.provenanceChip.attributedLabel?.string.contains("From") == false)
        try capturePronunciationView(window, "lookup")

        await producer.send(transcriptionEvent(nonSequiturRows))
        #expect(!view.copyButton.isEnabled)
        await producer.send(audioEvent(forvoAudio))
        #expect(view.copyButton.isEnabled)
        #expect(view.copyButton.symbolName == "speaker.wave.2")
        #expect(view.copyButton.isSymbolAnimating)
        #expect(view.keyHintsView.hints == [.init("↩", "Replay"), .init("esc", "Stop and close")])
        #expect(view.routeLabel.stringValue == "Wiktionary · Forvo")
        #expect(!view.view.subviews.contains { $0.accessibilityIdentifier() == "omni.ephemeral.working" })
        let text = view.resultTextView.attributedString()
        let ipaRange = (text.string as NSString).range(of: "/ˌnɑn ˈsɛkwɪtɚ/")
        #expect((text.attribute(.font, at: ipaRange.location, effectiveRange: nil) as? NSFont)?.pointSize == 23)
        let accentRange = (text.string as NSString).range(of: "GA")
        #expect((text.attribute(.font, at: accentRange.location, effectiveRange: nil) as? NSFont)?.pointSize == 11)
        let brandRange = (text.string as NSString).range(of: "Pronunciations by Forvo")
        #expect(text.attribute(.link, at: brandRange.location, effectiveRange: nil) as? URL == URL(string: "https://forvo.com"))
        #expect(!text.string.contains("▶") && !text.string.contains("https://") && !text.string.contains("online only"))
        view.resultTextView.setSelectedRange(ipaRange)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.resultTextView.selectedRange() == ipaRange)
        #expect(view.resultTextView.writeSelection(to: pasteboard, types: view.resultTextView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "/ˌnɑn ˈsɛkwɪtɚ/")
        try capturePronunciationView(window, "playing")

        let final = resultJSON(rows: nonSequiturRows, audio: forvoAudio, played: "forvo:online")
        await producer.complete(final)
        try await waitForPronunciation { window.session.phase == .ready }
        #expect(!view.copyButton.isSymbolAnimating)
        #expect(view.keyHintsView.hints == [.init("↩", "Replay"), .init("esc", "Close")])
        try capturePronunciationView(window, "rest")

        var copied: String?
        window.onCopy = { copied = $0 }
        window.copyCurrentOutput()
        #expect(copied?.contains("/ˌnɑn ˈsɛkwɪtɚ/") == true)
        #expect(copied?.contains("transcriptions") == false)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.resultTextView.keyDown(with: enter)
        try await waitForPronunciation { await producer.starts == 2 }
        #expect(!view.copyButton.isSymbolAnimating && !view.copyButton.isEnabled)
        await producer.send(transcriptionEvent(nonSequiturRows))
        await producer.send(audioEvent(forvoAudio))
        #expect(view.copyButton.isSymbolAnimating)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        view.editor.keyDown(with: escape)
        #expect(!window.session.isOpen && !view.copyButton.isSymbolAnimating)
        await producer.complete(final)
    }

    @Test @MainActor func homographMissAndFailedSourceCaptures() async throws {
        let readRows = #"[{"accent":"GA","ipa":"ɹiːd","source":"wiktionary","pos":"present"},{"accent":"GA","ipa":"ɹɛd","source":"wiktionary","pos":"past"}]"#
        let synthetic = #"{"source":"say","accent":"synthetic","attribution":"Samantha","synthetic":true}"#
        for (name, term, rows, audio, played, errors, code) in [
            ("homograph", "read", readRows, commonsAudio, "/fixture/read.wav", "[]", 0),
            ("miss", "Fuleihan", "[]", synthetic, "say:Samantha", "[]", 1),
            ("failure", "non sequitur", nonSequiturRows, commonsAudio, "/fixture/read.wav", #"[{"source":"forvo","message":"quota reached"}]"#, 2)
        ] {
            let producer = PronunciationViewProducer()
            let window = pronunciationWindow(producer)
            window.show(input: term, submitImmediately: true)
            try await waitForPronunciation { await producer.starts == 1 }
            if name == "miss" {
                await producer.send(transcriptionEvent("[]"))
                #expect(viewHasWorkingIndicator(window.viewController))
                #expect(!window.viewController.copyButton.isEnabled)
                await producer.send(audioEvent(synthetic))
                #expect(!viewHasWorkingIndicator(window.viewController))
                #expect(window.viewController.copyButton.isSymbolAnimating)
            }
            await producer.complete(resultJSON(rows: rows, audio: audio, played: played, errors: errors, exit: code))
            try await waitForPronunciation { window.session.phase == .ready }
            let view = window.viewController
            #expect(view.pronunciation?.exitCode == code)
            if name == "homograph" {
                #expect(view.pronunciation?.transcriptions.map(\.tag) == ["present", "past"])
            } else if name == "miss" {
                #expect(view.resultTextView.string.contains("no transcription"))
                #expect(view.resultTextView.string.contains("Wiktionary · CMUdict"))
                #expect(view.pronunciation?.attribution?.symbolName == "waveform")
                #expect(view.resultTextView.string.contains("Samantha · synthetic"))
            } else {
                let failed = try #require(view.pronunciationRoute.sourceLabels.first { $0.toolTip == "quota reached" })
                #expect(failed.stringValue.contains("● Forvo"))
                #expect(view.pronunciation?.attribution?.text.contains("Commons") == true)
            }
            try capturePronunciationView(window, name)
            view.view.frame.size.width = 340
            view.view.layoutSubtreeIfNeeded()
            #expect(view.pronunciationRoute.frame.maxX <= view.view.bounds.maxX)
            #expect(view.pronunciationRoute.frame.minY > view.keyHintsView.frame.maxY)
            #expect(view.copyButton.frame.maxX <= view.view.bounds.maxX)
            try capturePronunciationView(window, name + "-narrow")
            window.dismiss()
        }
    }
}

@MainActor private func viewHasWorkingIndicator(_ view: OmniEphemeralViewController) -> Bool {
    view.view.subviews.contains { $0.accessibilityIdentifier() == "omni.ephemeral.working" }
}
