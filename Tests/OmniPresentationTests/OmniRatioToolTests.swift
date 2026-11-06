import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

@MainActor private func key(_ code: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}

@MainActor private func makeTool(copied: @escaping (String) -> Void = { _ in }) throws -> OmniRatioWindowController {
    let tool = OmniRatioWindowController(session: OmniRatioSession(tables: try RatioTables.shared.get()), presentsInterface: false)
    tool.onCopy = copied
    return tool
}

@MainActor private func type(_ text: String, into tool: OmniRatioWindowController) {
    let editor = tool.viewController.editor
    editor.string = text
    editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    tool.viewController.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
}

@Suite(.serialized) struct OmniRatioToolTests {
    @Test @MainActor func emptyOpensTheReferenceToScaleWithSquareSelected() throws {
        var copied: [String] = []
        let tool = try makeTool { copied.append($0) }
        tool.show()
        let controller = tool.viewController
        #expect(controller.toolPill.title == "Ratio")
        #expect(controller.editor.placeholderString == "16:9, 1200×628, 16:9 at 1200 wide, or a name")
        let cells = controller.resultView.cellFrames
        #expect(cells.count == 13)
        // Same height, width proportional to the ratio: 9:16 narrow, cinema wide.
        #expect(Set(cells.map(\.height)).count == 1)
        #expect(cells.first!.width < cells.last!.width)
        #expect(controller.resultView.drawingFrame == nil && controller.resultView.rowFrames.isEmpty)
        #expect(tool.session.copyText == "1:1")
        #expect(controller.routeText == "1:1 · square · 1080 × 1080")
        #expect(controller.keyHintsView.hints == [.init("↩", "Copy and close"), .init("esc", "Close")])
        #expect(controller.copyButton.symbolName == "doc.on.doc" && controller.copyButton.isEnabled)
        tool.copySelectionAndClose()
        #expect(copied == ["1:1"])
        #expect(!tool.session.isOpen)
    }

    @Test @MainActor func arrowsMoveInTwoDimensionsOverTheWrappedGrid() throws {
        let tool = try makeTool()
        tool.show()
        let controller = tool.viewController
        let editor = controller.editor
        let start = try #require(tool.session.selectedIndex)
        editor.keyDown(with: key(124))
        #expect(tool.session.copyText == "5:4")
        editor.keyDown(with: key(123))
        editor.keyDown(with: key(123))
        #expect(tool.session.copyText == "4:5")
        #expect(tool.session.selectedIndex == start - 1)
        // Down lands in the next visual line on the cell nearest this one's centre.
        let frames = controller.resultView.cellFrames
        let before = try #require(tool.session.selectedIndex)
        editor.keyDown(with: key(125))
        let after = try #require(tool.session.selectedIndex)
        #expect(frames[after].minY > frames[before].minY)
        let line = frames.indices.filter { frames[$0].minY == frames[after].minY }
        let nearest = line.min { abs(frames[$0].midX - frames[before].midX) < abs(frames[$1].midX - frames[before].midX) }
        #expect(after == nearest)
        editor.keyDown(with: key(126))
        #expect(frames[try #require(tool.session.selectedIndex)].minY == frames[before].minY)
        // Up on the first line stays put.
        tool.session.select(0)
        editor.keyDown(with: key(126))
        #expect(tool.session.selectedIndex == 0)
        #expect(tool.session.copyText == "9:16")
    }

    @Test @MainActor func aSizeDrawsToThePadWidthAndCopiesTheDecimal() throws {
        var copied: [String] = []
        let tool = try makeTool { copied.append($0) }
        tool.show()
        type("1200x628", into: tool)
        let controller = tool.viewController
        let drawing = try #require(controller.resultView.drawingFrame)
        #expect(drawing.size == NSSize(width: 382, height: 200))
        #expect(controller.resultView.rowFrames.count == tool.session.result.rows.count)
        #expect(controller.routeText == "1200 × 628 · 1.91:1")
        // ↑↓ walk the rows; the summary follows and still names the copy text.
        controller.editor.keyDown(with: key(125))
        #expect(controller.routeText == "1200 × 628 · 2:1")
        controller.editor.keyDown(with: key(126))
        tool.copySelectionAndClose()
        #expect(copied == ["1.91:1"])
    }

    @Test @MainActor func aRatioAtAWidthSelectsTheAnswer() throws {
        var copied: [String] = []
        let tool = try makeTool { copied.append($0) }
        tool.show(input: "16:9 at 1200 wide")
        let controller = tool.viewController
        #expect(controller.resultView.drawingFrame?.size == NSSize(width: 356, height: 200))
        #expect(controller.routeText == "16:9 at 1200 wide · 1200 × 675")
        tool.copySelectionAndClose()
        #expect(copied == ["1200 × 675"])
    }

    @Test @MainActor func aNameListsPresetRowsWithoutADrawing() throws {
        var copied: [String] = []
        let tool = try makeTool { copied.append($0) }
        tool.show()
        type("instagram", into: tool)
        let controller = tool.viewController
        #expect(controller.resultView.drawingFrame == nil)
        #expect(controller.resultView.rowFrames.count == 4)
        #expect(controller.routeText == "Post · 1:1 · 1080 × 1080")
        // ⌘C with nothing selected in the field copies and stays open.
        #expect(controller.editor.selectedRange().length == 0)
        controller.editor.copy(nil)
        #expect(copied == ["1080 × 1080"])
        #expect(tool.session.isOpen)
    }

    @Test @MainActor func unparsableInputHasNoResultRegionAndSaysSo() throws {
        var copied: [String] = []
        let tool = try makeTool { copied.append($0) }
        tool.show()
        let referenceHeight = tool.viewController.view.frame.height
        type("hello", into: tool)
        let controller = tool.viewController
        #expect(controller.resultView.cellFrames.isEmpty && controller.resultView.rowFrames.isEmpty)
        #expect(controller.view.frame.height < referenceHeight)
        #expect(controller.routeText == "no ratio in \u{201C}hello\u{201D}")
        #expect(controller.keyHintsView.hints == [.init("esc", "Close")])
        #expect(!controller.copyButton.isEnabled)
        tool.copySelectionAndClose()
        #expect(copied.isEmpty && tool.session.isOpen)
    }

    @Test @MainActor func missingTablesSayWhyInsteadOfShowingNothing() {
        let tool = OmniRatioWindowController(session: OmniRatioSession(tables: nil), presentsInterface: false)
        tool.show()
        #expect(tool.viewController.routeText == "Ratio tables are unavailable in this build.")
        #expect(tool.session.copyText == nil)
    }
}

@Test func ratioRouteKeepsItsPayload() {
    #expect(OmniRatioRoute.query(in: "/ratio") == "")
    #expect(OmniRatioRoute.query(in: "  /ratio  16:9 at 1200 wide ") == "16:9 at 1200 wide")
    #expect(OmniRatioRoute.query(in: "/ratios x") == nil)
    #expect(OmniRatioRoute.query(in: "/qq /ratio") == nil)
}

@Test @MainActor func ratioPadConsumesLocallyAndSuppressesDurableRoute() throws {
    let manifest = try CommandManifest(data: FrozenContractCorpus().data(named: "manifest"))
    let parser = OmniParser(manifest: manifest, references: try ReferenceRegistry([]))
    let pad = OmniCommandPadViewController(parser: parser)
    pad.loadViewIfNeeded()
    var queries: [String] = []
    var durableSubmits = 0
    pad.onRatioRequested = { queries.append($0) }
    pad.onSubmit = { _, _ in durableSubmits += 1 }
    pad.editor.string = "/ratio 1200x628"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(!pad.isCompletionVisible)
    #expect(pad.footerState.runEnabled)
    #expect(pad.footerState.routeLine.text == "Ratio · opens native panel")
    pad.submit(.enterShowHere)
    pad.submit(.enterShowHere)
    #expect(queries == ["1200x628"])
    #expect(durableSubmits == 0)
}
