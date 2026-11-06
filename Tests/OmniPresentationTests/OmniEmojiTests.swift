import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

private actor SuggestRecorder {
    private(set) var descriptions: [String] = []
    func record(_ description: String) { descriptions.append(description) }
}

@MainActor private func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@MainActor private func makeSession(
    frequent: [String] = [], debounce: Duration = .milliseconds(20),
    recorder: SuggestRecorder = SuggestRecorder(), picks: [String] = [], delay: Duration = .zero
) throws -> OmniEmojiSession {
    let corpus = try EmojiCorpus.shared.get()
    return OmniEmojiSession(
        corpus: corpus, debounce: debounce,
        frequentSet: { frequent.compactMap { corpus.entry(for: $0) } },
        suggest: { description in
            await recorder.record(description)
            if delay > .zero { try await Task.sleep(for: delay) }
            return picks.compactMap { corpus.entry(named: $0) }
        }
    )
}

@Suite(.serialized) struct OmniEmojiSessionTests {
    @Test @MainActor func emptyFieldShowsFrequentSetOrNothing() throws {
        let fresh = try makeSession()
        fresh.open()
        #expect(fresh.rows.isEmpty && fresh.selectedEntry == nil && fresh.routeDetail == nil)

        let used = try makeSession(frequent: ["😄", "👍", "🙏"])
        used.open()
        #expect(used.rows.map(\.emoji) == ["😄", "👍", "🙏"])
        #expect(used.selectedIndex == 0)
        #expect(used.routeDetail == "Grinning face with smiling eyes")
    }

    @Test @MainActor func nameSearchIsLocalAndNeverAsksTheModel() async throws {
        let recorder = SuggestRecorder()
        let session = try makeSession(recorder: recorder)
        session.open()
        session.inputChanged("hand")
        #expect(session.localRows.first?.emoji == "👋")
        #expect(session.localRows.count >= 30)
        #expect(session.selectedIndex == 0)
        #expect(session.routeDetail == "Waving hand")
        #expect(!session.isSuggesting)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await recorder.descriptions.isEmpty)
    }

    @Test @MainActor func thinDescriptionAsksOnceAndSelectsTheFirstPickBelowTheHairline() async throws {
        let recorder = SuggestRecorder()
        let session = try makeSession(recorder: recorder, picks: ["smirking face", "face exhaling", "face with rolling eyes", "unamused face", "melting face"])
        session.open()
        session.inputChanged("smug but tired")
        let weak = session.localRows
        #expect(weak.contains { $0.emoji == "😏" })
        #expect(session.isSuggesting)
        try await eventually { !session.suggestedRows.isEmpty }
        #expect(await recorder.descriptions == ["smug but tired"])
        #expect(session.localRows == weak)
        // A pick already shown above the hairline is not repeated below it.
        #expect(!session.suggestedRows.contains { $0.emoji == "😏" })
        #expect(session.suggestedRows.map(\.emoji) == ["😮‍💨", "🙄", "😒", "🫠"])
        #expect(session.selectedIndex == weak.count)
        #expect(session.selectedOrigin == .suggested)
        #expect(session.routeDetail == "Provider · Face exhaling")
        session.moveSelection(columns: 0, rows: -1)
        #expect(session.selectedOrigin == .corpus)
        #expect(session.routeDetail?.hasPrefix("Cerebras") == false)
    }

    @Test @MainActor func editingAndClosingDropLateReplies() async throws {
        let recorder = SuggestRecorder()
        let session = try makeSession(recorder: recorder, picks: ["smirking face"], delay: .milliseconds(120))
        session.open()
        session.inputChanged("smug but tired")
        try await eventually { true }
        try await Task.sleep(for: .milliseconds(40))
        session.inputChanged("hand")
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.suggestedRows.isEmpty)
        #expect(session.localRows.first?.emoji == "👋")

        session.inputChanged("quiet wistful spaceship")
        session.close()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!session.isOpen && session.rows.isEmpty && session.input.isEmpty && session.notice == nil)
    }

    @Test @MainActor func arrowsMoveInTwoDimensionsAcrossTheHairline() async throws {
        let session = try makeSession(picks: ["smirking face", "melting face"])
        session.open()
        session.inputChanged("hand")
        let count = session.rows.count
        session.moveSelection(columns: 1, rows: 0)
        #expect(session.selectedIndex == 1)
        session.moveSelection(columns: 0, rows: 1)
        #expect(session.selectedIndex == 11)
        session.moveSelection(columns: 0, rows: -1)
        session.moveSelection(columns: 0, rows: -1)
        #expect(session.selectedIndex == 1)
        session.moveSelection(columns: -5, rows: 0)
        #expect(session.selectedIndex == 0)
        for _ in 0..<40 { session.moveSelection(columns: 0, rows: 1) }
        let lastRow = try #require(session.gridRows.last)
        #expect(lastRow.contains(try #require(session.selectedIndex)))
        session.moveSelection(columns: 50, rows: 0)
        #expect(session.selectedIndex == count - 1)
    }

    @Test @MainActor func unavailableCorpusSaysSoAndClearsOnTheNextKeystroke() throws {
        let session = OmniEmojiSession(corpus: nil, initialNotice: "Emoji names are unavailable in this build.",
                                       frequentSet: { [] }, suggest: { _ in [] })
        session.open()
        #expect(session.notice == "Emoji names are unavailable in this build.")
        #expect(session.rows.isEmpty)
        session.inputChanged("t")
        #expect(session.notice == nil && session.rows.isEmpty)
    }
}

@Suite(.serialized) struct OmniEmojiViewTests {
    @Test @MainActor func gridMatchesReferenceGeometryAndSummaryCarriesTheName() throws {
        _ = NSApplication.shared
        let session = try makeSession(frequent: ["😄", "👍"])
        let controller = OmniEmojiWindowController(session: session, presentsInterface: false)
        controller.show()
        let view = controller.viewController
        #expect(view.view.frame.width == OmniPadPlacement.width)
        #expect(view.editor.placeholderString == "Name, keyword or description")
        #expect(view.routeText == "Grinning face with smiling eyes")
        #expect(view.view.subviews.compactMap { $0 as? OmniToolPillView }.count == 1)
        #expect(view.toolPill.title == "Emoji")
        #expect(view.toolPill.frame.maxX == view.view.bounds.width - 18)
        #expect(view.keyHintsView.hints == [.init("↩", "Copy and close"), .init("esc", "Close")])
        #expect(view.copyButton.isEnabled)

        session.inputChanged("hand")
        let frames = view.gridView.cellFrames
        #expect(frames.count == session.rows.count)
        #expect(frames.allSatisfy { $0.height == OmniEmojiGridView.cellHeight })
        #expect(frames[1].minX - frames[0].maxX == OmniEmojiGridView.gap)
        #expect(frames[10].minY - frames[0].maxY == OmniEmojiGridView.gap)
        #expect(Set(frames.prefix(10).map(\.minY)).count == 1 && frames[10].minX == frames[0].minX)
        #expect(view.routeText == "Waving hand")
        #expect(view.view.frame.height <= 52 + 372 + 54 + 0.5)

        session.inputChanged("zzqx")
        #expect(view.gridView.cellFrames.isEmpty)
        #expect(!view.copyButton.isEnabled)
        #expect(view.keyHintsView.hints == [.init("esc", "Close")])
        controller.dismiss()
    }

    @Test @MainActor func suggestionsSitBelowAHairlineWithTheirSource() async throws {
        _ = NSApplication.shared
        let session = try makeSession(picks: ["face exhaling", "melting face"])
        let controller = OmniEmojiWindowController(session: session, presentsInterface: false)
        controller.show(input: "smug but tired")
        try await eventually { !session.suggestedRows.isEmpty }
        let grid = controller.viewController.gridView
        let hairline = try #require(grid.hairlineFrame)
        let firstSuggested = grid.cellFrames[session.localRows.count]
        #expect(hairline.minY > grid.cellFrames[session.localRows.count - 1].maxY)
        #expect(firstSuggested.minY > hairline.maxY)
        #expect(try #require(grid.sourceFrame).minY > firstSuggested.maxY)
        #expect(controller.viewController.routeText == "Provider · Face exhaling")
        controller.dismiss()
    }

    @Test @MainActor func enterCopiesAndClosesAndCommandCCopiesAndStays() throws {
        _ = NSApplication.shared
        let session = try makeSession(frequent: ["👍", "😄"])
        let controller = OmniEmojiWindowController(session: session, presentsInterface: false)
        var copied: [String] = []
        var closed = 0
        controller.onCopy = { copied.append($0.emoji) }
        controller.onCloseRequested = { closed += 1; controller.dismiss() }
        controller.show()
        let editor = controller.viewController.editor
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
        editor.keyDown(with: right)
        #expect(session.selectedEntry?.emoji == "😄")
        editor.copy(nil)
        #expect(copied == ["😄"])
        #expect(session.isOpen && closed == 0)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        editor.keyDown(with: enter)
        #expect(copied == ["😄", "😄"])
        #expect(closed == 1 && !session.isOpen)
    }

    @Test @MainActor func longEmojiQueryWrapsBelowItsPill() throws {
        _ = NSApplication.shared
        let session = try makeSession(frequent: ["😄"])
        let controller = OmniEmojiWindowController(session: session, presentsInterface: false)
        controller.show()
        session.inputChanged(String(repeating: "a cheerful but complicated emoji description ", count: 5))
        let view = controller.viewController
        let inputScroll = try #require(view.editor.enclosingScrollView)
        #expect(inputScroll.frame.height > 25)
        #expect(view.editor.textContainer.map { view.editor.layoutManager?.usedRect(for: $0).height ?? 0 } ?? 0 > 25)
        #expect(view.toolPill.frame.maxX == view.view.bounds.width - 18)
        controller.dismiss()
    }

    @Test @MainActor func lightAndDarkCapturesWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"] else { return }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let states: [(String, String, [String], [String])] = [
            ("emoji-frequent", "", ["😄", "👍", "🙏", "😂", "❤️", "🎉", "👀", "🤔", "✅", "🔥", "😅", "🫡", "🚀", "☕️", "🍀", "👋", "💡", "🧠", "🎯", "😮‍💨"], []),
            ("emoji-hand", "hand", [], []),
            ("emoji-suggested", "smug but tired", [], ["smirking face", "face exhaling", "face with rolling eyes", "unamused face", "melting face"]),
            ("emoji-long-query", String(repeating: "a cheerful but complicated emoji description ", count: 5), ["😄"], []),
        ]
        for (name, input, frequent, picks) in states {
            let session = try makeSession(frequent: frequent, picks: picks)
            let controller = OmniEmojiWindowController(session: session, presentsInterface: false)
            controller.show(input: input, provenance: name == "emoji-frequent" ? OmniPadProvenance(source: "Safari", detail: "Article", wordCount: 3) : nil)
            if !picks.isEmpty { try await eventually { !session.suggestedRows.isEmpty } }
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                controller.viewController.view.appearance = NSAppearance(named: appearance)
                (controller.viewController.view as? OmniFrostedSurface)?.apply(transparency: .opaqueFallback)
                let image = OmniNativeCaptureHarness.image(of: controller.viewController.view)
                let rep = try #require(image.representations.first as? NSBitmapImageRep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(suffix).png"))
            }
            controller.dismiss()
        }
    }
}
