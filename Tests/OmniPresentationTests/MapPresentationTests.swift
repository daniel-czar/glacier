import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

private actor MapFixtureProducer {
    private(set) var calls: [(String, OmniMapForm?)] = []
    func run(_ input: String, _ form: OmniMapForm?) -> OmniMapDocument {
        calls.append((input, form))
        return OmniMapSamples.document(for: OmniMapInput.parse(input, pinnedForm: form).pinnedForm ?? .matrix)
    }
    func count() -> Int { calls.count }
}

@MainActor private func mapSettled(_ session: OmniMapSession) async throws {
    for _ in 0..<500 {
        if session.phase == .ready || session.failureReason != nil { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Map did not finish")
}

@MainActor private func mapKey(_ code: UInt16, _ text: String = "") -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                     characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
}

@Suite(.serialized) struct MapPresentationTests {
    @Test @MainActor func emptyMapChoosesLocallyAndOnlyPinsAfterSelection() async throws {
        _ = NSApplication.shared
        let producer = MapFixtureProducer()
        let tool = OmniMapWindowController(producer: { await producer.run($0, $1) }, presentsInterface: false, debounce: .zero)
        defer { tool.dismiss() }
        tool.show()
        #expect(tool.viewController.chooser.cellFrames.count == 7)
        #expect(tool.viewController.chooser.cellFrames[4].minY > tool.viewController.chooser.cellFrames[3].minY)
        #expect(!tool.viewController.copyButton.isEnabled)
        #expect(tool.session.selectedForm == nil)
        tool.viewController.editor.keyDown(with: mapKey(124))
        #expect(tool.session.selectedForm == .tree)
        #expect(tool.session.summary == "Tree · selected form · type to fill it")
        #expect(await producer.count() == 0)
        tool.session.inputChanged("a useful library")
        try await mapSettled(tool.session)
        #expect(tool.session.document?.form == .tree)
        let calls = await producer.count()
        tool.viewController.editor.keyDown(with: mapKey(125))
        #expect(await producer.count() == calls, "arrows on a result must not ask again")
    }

    @Test @MainActor func refusalNeverAsksAndKeepsTheReferenceVisible() async {
        let producer = MapFixtureProducer()
        let tool = OmniMapWindowController(producer: { await producer.run($0, $1) }, presentsInterface: false, debounce: .zero)
        defer { tool.dismiss() }
        tool.show(input: "library as a venn")
        #expect(tool.session.summary == "Map · no native form for a Venn · try Matrix")
        #expect(tool.viewController.chooser.superview != nil)
        #expect(!tool.viewController.copyButton.isEnabled)
        #expect(await producer.count() == 0)
    }

    @Test @MainActor func choosingAnotherFormReasksPinnedAndUpdatesTheModeToken() async throws {
        let producer = MapFixtureProducer()
        let tool = OmniMapWindowController(producer: { await producer.run($0, $1) }, presentsInterface: false, debounce: .zero)
        defer { tool.dismiss() }
        tool.show(input: "scrum as a loop")
        try await mapSettled(tool.session)
        #expect(tool.session.document?.form == .loop)
        #expect(tool.session.summary == "Loop · arrows: increases · R = reinforcing")
        #expect(tool.viewController.drawing.accessibilityLabel()?.contains("Leaves out:") == true)
        tool.session.selectForm(.tree)
        #expect(tool.session.input == "scrum as tree")
        try await mapSettled(tool.session)
        #expect(tool.session.document?.form == .tree)
        #expect(await producer.count() == 2)
        #expect(tool.viewController.editor.string == "scrum as tree")
        #expect(tool.session.parsed.modeRange != nil)
    }

    @Test @MainActor func failedMapHasAFailureMarkAndANonemptyPad() async throws {
        let tool = OmniMapWindowController(producer: { _, _ in throw OmniMapValidationError(["honesty is required."]) },
                                          presentsInterface: false, debounce: .zero)
        defer { tool.dismiss() }
        tool.show(input: "scrum")
        try await mapSettled(tool.session)
        #expect(tool.viewController.routeLabel.stringValue.contains("●"))
        #expect(tool.viewController.routeLabel.toolTip?.contains("honesty") == true)
        #expect(tool.viewController.chooser.superview != nil)
        #expect(tool.session.copyableDocument == nil)
    }

    @Test @MainActor func currentMapCancellationExitsWaiting() async throws {
        let session = OmniMapSession(producer: { _, _ in throw CancellationError() }, debounce: .zero)
        session.open(input: "scrum")
        try await mapSettled(session)
        #expect(session.phase == .failed("Map is unavailable. Edit the question to try again."))
        #expect(session.copyableDocument == nil)
        session.close()
    }

    @Test @MainActor func enterCopiesOnePngAndTextItemAndCloses() async throws {
        let tool = OmniMapWindowController(producer: { _, _ in OmniMapSamples.document(for: .bridge) }, presentsInterface: false, debounce: .zero)
        var items: [NSPasteboardItem] = []
        tool.writePasteboardItem = { items.append($0); return true }
        tool.show(input: "explain git to a librarian")
        try await mapSettled(tool.session)
        tool.viewController.editor.keyDown(with: mapKey(36, "\r"))
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(Set(item.types) == [.png, .string])
        #expect(item.string(forType: .string)?.contains("Breaks at:") == true)
        let bitmap = try #require(item.data(forType: .png).flatMap(NSBitmapImageRep.init(data:)))
        #expect(bitmap.pixelsWide == 1280)
        #expect(!tool.session.isOpen)
    }

    @Test @MainActor func previewIsRemovedByEditingAndEscapeClosesPreviewFirst() async throws {
        let tool = OmniMapWindowController(producer: { _, _ in OmniMapSamples.document(for: .loop) }, presentsInterface: false, debounce: .zero)
        tool.show(input: "scrum")
        try await mapSettled(tool.session)
        #expect(tool.showLarger())
        let file = try #require(tool.viewController.drawnPreview.url)
        tool.viewController.editor.keyDown(with: mapKey(53, "\u{1b}"))
        #expect(tool.session.isOpen && !FileManager.default.fileExists(atPath: file.path))
        #expect(tool.showLarger())
        let nextFile = try #require(tool.viewController.drawnPreview.url)
        tool.session.inputChanged("new question")
        #expect(!FileManager.default.fileExists(atPath: nextFile.path))
        #expect(tool.session.copyableDocument == nil)
        tool.viewController.editor.keyDown(with: mapKey(53, "\u{1b}"))
        #expect(!tool.session.isOpen)
    }

    @Test @MainActor func allFormsExportDeterministicallyInLightAppearanceAndCapture() async throws {
        let folder = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for form in OmniMapForm.allCases {
            let document = OmniMapSamples.document(for: form)
            var light: Data?
            var dark: Data?
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = OmniMapCopyComposer.png(document) }
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = OmniMapCopyComposer.png(document) }
            #expect(light != nil && light == dark)
            if let folder, let light { try light.write(to: folder.appendingPathComponent("map-\(form.rawValue).png")) }
        }
        if let folder {
            for (name, input) in [("chooser", ""), ("loop-pad", "scrum as a loop"), ("refusal", "library as a venn")] {
                let tool = OmniMapWindowController(producer: { text, form in
                    OmniMapSamples.document(for: OmniMapInput.parse(text, pinnedForm: form).pinnedForm ?? .matrix)
                }, presentsInterface: false, debounce: .zero)
                tool.show(input: input)
                if name == "loop-pad" { try await mapSettled(tool.session) }
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    OmniNativeCaptureHarness.prepare(tool.viewController.view, scenario: .longEditor, treatment: .opaqueFallback, appearance: appearance)
                    let image = OmniNativeCaptureHarness.image(of: tool.viewController.view)
                    let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("map-\(name)-\(appearance.rawValue).png"))
                }
                tool.dismiss()
            }
        }
    }
}
