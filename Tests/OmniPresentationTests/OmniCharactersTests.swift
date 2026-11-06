import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

private actor CharacterSuggestionRecorder {
    private(set) var queries: [String] = []
    func record(_ query: String) { queries.append(query) }
}

@MainActor private func eventuallyCharacters(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@MainActor private func makeCharactersSession(frequent: [UInt32] = [],
    suggest: OmniCharactersSession.Suggest? = nil, debounce: Duration = .milliseconds(20)) throws -> OmniCharactersSession {
    let corpus = try CharacterCorpus.shared.get()
    return OmniCharactersSession(corpus: corpus, debounce: debounce,
        frequentSet: { frequent.compactMap { corpus.entry(for: $0) } }, suggest: suggest)
}

@Suite(.serialized) struct OmniCharactersSessionTests {
    @Test @MainActor func emptyFieldUsesSuppliedFrequentSet() throws {
        let session = try makeCharactersSession(frequent: [0x2191, 0x2665])
        session.open()
        #expect(session.rows.map(\.scalar) == [0x2191, 0x2665])
        #expect(session.selectedText == "↑")
        #expect(session.routeDetail == "↑ · Upwards arrow · U+2191 · Arrows")
        session.close()
        #expect(session.rows.isEmpty && session.selectedText == nil)
    }

    @Test @MainActor func searchAndGridMovementStayLocalInOfflineMode() throws {
        let session = try makeCharactersSession()
        session.open(input: "upward arrow")
        #expect(session.localRows.first?.scalar == 0x2191)
        #expect(session.identifiedEntry == nil)
        #expect(!session.isSuggesting && session.suggestedRows.isEmpty)
        session.moveSelection(columns: 1, rows: 0)
        #expect(session.selectedIndex == min(1, session.rows.count - 1))
        session.close()
    }

    @Test @MainActor func identifyCodePointAndGlyphSelectLiteralRepresentations() throws {
        let session = try makeCharactersSession()
        for input in ["2191", "U+2191", "0x2191", "↑"] {
            session.open(input: input)
            #expect(session.identifiedEntry?.scalar == 0x2191)
            #expect(session.selectedRepresentation?.label == "Glyph")
            #expect(session.selectedText == "↑")
            session.moveSelection(columns: 0, rows: 1)
            #expect(session.selectedRepresentation?.label == "Code point")
            #expect(session.selectedText == "U+2191")
            #expect(session.routeDetail?.hasPrefix("U+2191 · Upwards arrow") == true)
            let escapeIndex = try #require(session.representations.firstIndex { $0.label == "Escape" })
            session.selectRepresentation(escapeIndex)
            #expect(session.selectedText == "\\u2191")
            #expect(session.routeDetail?.hasPrefix("\\u2191 · Upwards arrow") == true)
            session.close()
        }
    }

    @Test @MainActor func emojiRefusalAndUnavailableNotice() throws {
        let session = try makeCharactersSession()
        session.open(input: "❤️")
        #expect(session.notice == "that's an emoji · try em")
        #expect(session.selectedEntry == nil)
        session.inputChanged("U+0378")
        #expect(session.notice == "No character for this input.")
        #expect(session.selectedEntry == nil)
        session.inputChanged("upward arrow")
        #expect(session.notice == nil)

        let unavailable = OmniCharactersSession(corpus: nil, initialNotice: "Character names are unavailable in this build.",
            frequentSet: { [] })
        unavailable.open()
        #expect(unavailable.notice == "Character names are unavailable in this build.")
        unavailable.inputChanged("x")
        #expect(unavailable.notice == nil)
    }

    @Test @MainActor func editingAndDismissalDropLateSuggestions() async throws {
        let corpus = try CharacterCorpus.shared.get()
        let recorder = CharacterSuggestionRecorder()
        let session = try makeCharactersSession(suggest: { query in
            await recorder.record(query)
            try await Task.sleep(for: .milliseconds(100))
            return [corpus.entry(for: 0x2191)].compactMap { $0 }
        })
        session.open(input: "wistful direction")
        try await eventuallyCharacters { session.isSuggesting }
        session.inputChanged("upward arrow")
        try await Task.sleep(for: .milliseconds(150))
        #expect(session.suggestedRows.isEmpty && session.localRows.first?.scalar == 0x2191)
        session.inputChanged("wistful direction")
        session.close()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!session.isOpen && session.rows.isEmpty && session.input.isEmpty)
    }
}

@Suite(.serialized) struct OmniCharactersViewTests {
    @Test @MainActor func gridReusesEmojiGeometryAndHasCharacterSummary() throws {
        _ = NSApplication.shared
        let session = try makeCharactersSession(frequent: [0x2191, 0x2665])
        let controller = OmniCharactersWindowController(session: session, presentsInterface: false)
        controller.show()
        let view = controller.viewController
        #expect(view.toolPill.title == "Characters")
        #expect(view.gridView.cellFrames.count == 2)
        #expect(view.gridView.sourceFrame == nil && view.gridView.hairlineFrame == nil)
        #expect(view.gridView.cellFrames[0].height == OmniEmojiGridView.cellHeight)
        #expect(view.gridView.cellFrames[1].minX - view.gridView.cellFrames[0].maxX == OmniEmojiGridView.gap)
        #expect(view.routeText == "↑ · Upwards arrow · U+2191 · Arrows")
        #expect(view.keyHintsView.hints == [.init("↩", "Insert and close"), .init("esc", "Close")])
        controller.dismiss()
    }

    @Test @MainActor func identifyRowsDriveInsertAndCopyIndependently() throws {
        _ = NSApplication.shared
        let session = try makeCharactersSession()
        let controller = OmniCharactersWindowController(session: session, presentsInterface: false)
        var inserted: [String] = []
        var copied: [String] = []
        controller.onInsert = { _, text in inserted.append(text) }
        controller.onCopy = { _, text in copied.append(text) }
        controller.show(input: "2191")
        let view = controller.viewController
        #expect(view.identifyView.rowFrames.count == session.representations.count)
        #expect(view.identifyView.rowFrames.count >= 5)
        #expect(view.routeText.hasPrefix("↑ · Upwards arrow"))
        session.moveSelection(columns: 0, rows: 1)
        #expect(view.routeText.hasPrefix("U+2191 · Upwards arrow"))
        #expect(controller.copySelection())
        #expect(copied == ["U+2191"] && session.isOpen)
        controller.insertSelectionAndClose()
        #expect(inserted == ["U+2191"] && session.isOpen)
        controller.hideForInsert()
        controller.dismiss()
        #expect(!session.isOpen)
    }

    @Test @MainActor func renderReferenceStatesWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNI_CHARACTERS_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let corpus = try CharacterCorpus.shared.get()
        let missing = CharacterEntry(scalar: 0x10FFFD, name: "Unrenderable glyph", aliases: [],
            block: "Private Use", category: "Other, private use", since: "1.1", htmlName: nil, confusables: [])
        let states: [(String, OmniCharactersSession, String)] = [
            ("characters-grid", OmniCharactersSession(corpus: corpus, frequentSet: { [] }), "upward arrow"),
            ("characters-identify", OmniCharactersSession(corpus: corpus, frequentSet: { [] }), "2191"),
            ("characters-mark", OmniCharactersSession(corpus: corpus, frequentSet: { [] }), "0301"),
            ("characters-tofu", OmniCharactersSession(corpus: CharacterCorpus(entries: [missing]),
                frequentSet: { [missing] }), "")
        ]
        for (name, session, input) in states {
            let controller = OmniCharactersWindowController(session: session, presentsInterface: false)
            controller.show(input: input)
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                controller.viewController.view.appearance = NSAppearance(named: appearance)
                (controller.viewController.view as? OmniFrostedSurface)?.apply(transparency: .opaqueFallback)
                let image = OmniNativeCaptureHarness.image(of: controller.viewController.view)
                let rep = try #require(image.representations.first as? NSBitmapImageRep)
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(name)-\(suffix).png"))
            }
            controller.dismiss()
        }
    }

    @Test @MainActor func gridModeDoesNotRegressEmojiRenderingState() throws {
        _ = NSApplication.shared
        let session = try makeCharactersSession(frequent: [0x2191])
        let controller = OmniCharactersWindowController(session: session, presentsInterface: false)
        controller.show(input: "2191")
        #expect(controller.viewController.gridView.cellFrames.isEmpty)
        session.inputChanged("")
        #expect(controller.viewController.identifyView.rowFrames.isEmpty)
        #expect(controller.viewController.gridView.cellFrames.count == 1)
        controller.dismiss()
    }
}
