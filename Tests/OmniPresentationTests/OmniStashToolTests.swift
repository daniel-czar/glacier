import AppKit
import Foundation
import OmniCore
@testable import OmniPresentation
import Testing

@MainActor private func stack(with texts: [(String, String)]) throws -> (OmniStashStack, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stash-tool-\(UUID().uuidString)", isDirectory: true)
    let stack = OmniStashStack(url: directory.appendingPathComponent("current.json"))
    for (text, source) in texts.reversed() { try stack.push(OmniStashEntry(text: text, source: source)) }
    return (stack, directory)
}

@MainActor private func key(_ view: NSTextView, _ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    view.keyDown(with: event)
}

@Suite(.serialized) @MainActor struct OmniStashToolTests {
    @Test func stackViewShowsTopEmphasizedTokensAndSummary() throws {
        let (store, directory) = try stack(with: [
            ("Coordinator: your D-18 hook at 0558 is confirmed;\nthe hangar brief moves to 0530.\nBring the route card.\nAnd the spare battery.", "Claude"),
            ("find . -type f -exec basename {} \\;", "Recall"),
            ("https://api.forvo.com/documentation/branding/", "Safari"),
            ("Besserwisser → know-it-all · smart aleck · wise guy", "Translate"),
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = OmniStashWindowController(session: OmniStashSession(stack: store), presentsInterface: false)
        tool.show()
        let controller = tool.viewController
        #expect(controller.editor.placeholderString == "Search the stash")
        #expect(controller.toolPill.title == "Stash")
        #expect(controller.routeLabel.stringValue == "4 of 5")
        #expect(controller.keyHintsView.hints == [.init("↩", "Paste"), .init("⌘↩", "Edit"), .init("esc", "Close")])
        #expect(controller.pasteButton.symbolName == "arrow.turn.down.left")
        let contents = controller.rowViews.map(\.content)
        #expect(contents.map(\.token) == ["/stash", "/stash:2", "/stash:3", "/stash:4"])
        #expect(contents.map(\.tokenDimmed) == [false, true, true, true])
        #expect(contents.map(\.emphasized) == [true, false, false, false])
        #expect(contents.map(\.kind) == [.text, .code, .link, .text])
        #expect(contents[1].detail.hasPrefix("Recall · today "))
        #expect(controller.rowViews[0].primary.maximumNumberOfLines == 3)
        #expect(controller.rowViews[1].primary.maximumNumberOfLines == 1)
        // The top row keeps three lines whichever row is selected (C93).
        tool.session.moveSelection(by: 2)
        #expect(controller.rowViews[0].content.emphasized)
        #expect(OmniKindRowView.height(for: controller.rowViews[0].content, width: 620) > OmniKindRowView.rowHeight)
        #expect(tool.session.selectedRow?.position == 3)
    }

    @Test func emptyStackHasNoResultRegionAndSaysZeroOfFiveWithTheChord() throws {
        let (store, directory) = try stack(with: [])
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = OmniStashWindowController(session: OmniStashSession(stack: store), presentsInterface: false)
        tool.show()
        #expect(tool.viewController.rowViews.isEmpty)
        #expect(tool.viewController.routeLabel.stringValue == "0 of 5 · ⌘Y in Glacier or Clipboard stashes")
        #expect(tool.viewController.keyHintsView.hints == [.init("esc", "Close")])
        #expect(!tool.viewController.pasteButton.isEnabled)
    }

    @Test func filterKeepsStackPositionsAndIsDeterministic() throws {
        let (store, directory) = try stack(with: [("alpha one", "Mail"), ("beta two", "Safari"), ("alpha three", "Notes")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = OmniStashSession(stack: store)
        session.open()
        session.inputChanged("alpha")
        #expect(session.rows.map(\.position) == [1, 3])
        #expect(session.rows.map(\.token) == ["/stash", "/stash:3"])
        session.inputChanged("safari")
        #expect(session.rows.map(\.position) == [2])
        session.inputChanged("alpha three")
        #expect(session.rows.map(\.entry.text) == ["alpha three"])
        #expect(session.summary == "3 of 5")
    }

    @Test func backspaceDropsWithNoticeAndCommandZRestores() throws {
        let (store, directory) = try stack(with: [("first", "Mail"), ("second", "Safari"), ("third", "Notes")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = OmniStashWindowController(session: OmniStashSession(stack: store), presentsInterface: false)
        tool.show()
        let editor = tool.viewController.editor
        key(editor, "\u{F701}", 125)
        #expect(tool.session.selectedRow?.entry.text == "second")
        key(editor, "\u{7F}", 51)
        #expect(try store.entries().map(\.text) == ["first", "third"])
        #expect(tool.session.notice == "Dropped · second")
        #expect(tool.viewController.routeLabel.stringValue == "Dropped · second   ⌘Z")
        // The next keystroke clears the notice; the undo manager still holds.
        key(editor, "\u{F700}", 126)
        #expect(tool.session.notice == nil)
        key(editor, "z", 6, .command)
        #expect(try store.entries().map(\.text) == ["first", "second", "third"])
        key(editor, "Z", 6, [.command, .shift])
        #expect(try store.entries().map(\.text) == ["first", "third"])
        key(editor, "z", 6, .command)
        #expect(try store.entries().map(\.text) == ["first", "second", "third"])

        // ⌘⌫ clears the stack, also undoable.
        key(editor, "\u{7F}", 51, .command)
        #expect(try store.entries().isEmpty)
        #expect(tool.session.notice == "Cleared · 3 entries")
        key(editor, "z", 6, .command)
        #expect(try store.entries().map(\.text) == ["first", "second", "third"])

        // With a query, ⌫ edits the query and drops nothing.
        editor.string = "th"
        tool.viewController.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        key(editor, "\u{7F}", 51)
        #expect(try store.entries().count == 3)

        // Closing ends the undo history.
        tool.dismiss()
        #expect(!tool.session.undoManager.canUndo)
    }

    @Test func returnPastesOptionReturnCopiesCommandReturnEditsAndNothingPops() throws {
        let (store, directory) = try stack(with: [("first", "Mail"), ("second", "Safari")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = OmniStashWindowController(session: OmniStashSession(stack: store), presentsInterface: false)
        var pasted: [String] = [], copied: [String] = [], edited: [String] = []
        tool.onPaste = { pasted.append($0.text) }
        tool.onCopyOnly = { copied.append($0.text) }
        tool.onEdit = { edited.append($0.text) }
        tool.show()
        let editor = tool.viewController.editor
        key(editor, "\r", 36)
        key(editor, "\u{F701}", 125)
        key(editor, "\r", 36, .option)
        key(editor, "\r", 36, .command)
        #expect(pasted == ["first"])
        #expect(copied == ["second"])
        #expect(edited == ["second"])
        #expect(try store.entries().count == 2, "Paste is apply, not pop")
    }

    @Test func shiftReturnPastesPlainTextWhateverSettingsSays() throws {
        let (store, directory) = try stack(with: [("first", "Mail")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = OmniStashWindowController(session: OmniStashSession(stack: store), presentsInterface: false)
        var pasted: [String] = [], plain: [String] = []
        tool.onPaste = { pasted.append($0.text) }
        tool.onPastePlain = { plain.append($0.text) }
        tool.show()
        key(tool.viewController.editor, "\r", 36, .shift)
        #expect(plain == ["first"] && pasted.isEmpty)
    }

    @Test func storeChangesElsewhereReachTheOpenView() throws {
        let (store, directory) = try stack(with: [("first", "Mail")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = OmniStashWindowController(session: OmniStashSession(stack: store), presentsInterface: false)
        tool.show()
        try store.push(OmniStashEntry(text: "pushed elsewhere", source: "Clipboard"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(tool.session.rows.map(\.entry.text) == ["pushed elsewhere", "first"])
        #expect(tool.viewController.routeLabel.stringValue == "2 of 5")
    }

    @Test func relativeTimeReadsTodayYesterdayWeekdayThenDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let monday = calendar.date(byAdding: .day, value: -3, to: now)!
        let older = calendar.date(byAdding: .day, value: -20, to: now)!
        #expect(OmniRelativeTime.label(for: now, now: now, calendar: calendar).hasPrefix("today "))
        #expect(OmniRelativeTime.label(for: yesterday, now: now, calendar: calendar) == "yesterday")
        #expect(!OmniRelativeTime.label(for: monday, now: now, calendar: calendar).hasPrefix("today"))
        #expect(OmniRelativeTime.label(for: older, now: now, calendar: calendar) != "yesterday")
    }
}
