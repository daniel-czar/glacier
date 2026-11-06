import AppKit
@testable import OmniPresentation
import Testing

let diagnosisLensJSON = #"""
{"name":"Diagnosis","field":"Medicine · Clinical practice","definition":"Identifying the nature and cause of a disease from signs, symptoms and tests.","parents":["Clinical reasoning","Medical practice","Pathology"],"siblings":["Treatment","Prevention","Rehabilitation"],"children":["Differential diagnosis","Diagnostic criteria","Clinical judgment","Diagnostic testing","Syndrome recognition"],"related":["Etiology","Pathophysiology","Nosology","Clinical guidelines","Evidence-based medicine"],"nearMisses":[{"name":"Prognosis","distinction":"likely course, not the present cause"},{"name":"Differential diagnosis","distinction":"alternative causes, not the final identification"},{"name":"Syndrome","distinction":"a pattern, not its underlying cause"},{"name":"Assessment","distinction":"whole patient, not a single cause"}]}
"""#

@MainActor private func lensDescriptor() -> OmniEphemeralToolDescriptor {
    OmniEphemeralToolDescriptor(id: "concept-lens", title: "Concept Lens", subtitle: "", inputPlaceholder: "Concept",
                               emptyResultHint: "", resultStyle: .drawnConcept, debounce: .zero)
}

@MainActor private func settle(_ tool: OmniEphemeralWindowController) async {
    for _ in 0..<10_000 {
        if tool.session.phase == .ready { return }
        await Task.yield()
    }
    Issue.record("Concept lens did not complete")
}

@Suite(.serialized) struct ConceptLensDrawingTests {
    @Test @MainActor func diagnosisDrawsAllTiersWithinPadAndCopiesOneDualFlavorItem() async throws {
        _ = NSApplication.shared
        let tool = OmniEphemeralWindowController(descriptor: lensDescriptor(), producer: { _, delta in
            await delta("partial JSON must never appear")
            return diagnosisLensJSON
        }, presentsInterface: false)
        var written: [NSPasteboardItem] = []
        tool.writePasteboardItem = { written.append($0); return true }
        tool.show(input: "diagnosis")
        await settle(tool)
        let view = tool.viewController
        let nodes = view.conceptDrawing.nodes
        #expect(nodes.filter { $0.kind == .parent }.count == 3)
        #expect(nodes.filter { $0.kind == .sibling }.count == 2)
        #expect(nodes.filter { $0.kind == .child }.count == 5)
        #expect(nodes.filter { $0.kind == .nearMiss }.count == 4)
        #expect(view.view.frame.width == 640 && view.view.frame.height <= 640)
        #expect(view.resultTextView.string.isEmpty)
        #expect(view.keyHintsView.hints.contains(.init("␣", "Larger")))
        #expect(!view.conceptDrawing.accessibilityLabel()!.contains("Rehabilitation"))
        for (i, first) in nodes.enumerated() {
            for second in nodes.dropFirst(i + 1) { #expect(!first.frame.intersects(second.frame)) }
        }
        tool.copyCurrentOutput()
        let item = try #require(written.first)
        #expect(written.count == 1)
        #expect(Set(item.types) == [.png, .string])
        let text = try #require(item.string(forType: .string))
        #expect(text.contains("Definition: Identifying") && text.contains("Near misses:"))
        #expect(!text.contains("Rehabilitation"))
        let png = try #require(item.data(forType: .png))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == 1280)
        #expect(bitmap.pixelsHigh > 584)
        #expect(bitmap.colorAt(x: 0, y: 0)!.redComponent > 0.95)
        let pasteboard = NSPasteboard(name: .init("omni-lens-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([item]))
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.availableType(from: [.png, .string]) == .png)
        #expect(pasteboard.string(forType: .string) == text)
        #expect(!tool.session.isOpen)
    }

    @Test @MainActor func drawingAndPngAreDeterministicAndAlwaysLight() throws {
        let map = try #require(OmniConceptLensProjection.project(diagnosisLensJSON, input: "diagnosis").map)
        let first = OmniConceptLensDrawing()
        first.display(map)
        first.arrange(width: 604)
        let second = OmniConceptLensDrawing()
        second.display(map)
        second.arrange(width: 604)
        #expect(first.nodes == second.nodes)
        var light: Data?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = OmniConceptLensCopyComposer.png(map) }
        var dark: Data?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = OmniConceptLensCopyComposer.png(map) }
        #expect(light != nil && light == dark)
        if let folder = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], let light {
            let root = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try light.write(to: root.appendingPathComponent("concept-lens-diagnosis.png"))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                first.appearance = NSAppearance(named: appearance)
                let image = OmniNativeCaptureHarness.image(of: first)
                let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("concept-lens-\(appearance.rawValue).png"))
            }
        }
    }

    @Test @MainActor func fallbackShowsTextFailureMarkAndCanCopy() async {
        let tool = OmniEphemeralWindowController(descriptor: lensDescriptor(),
            producer: { _, _ in "Name: Diagnosis\nDefinition: Identifying a disease.\nParents: Clinical reasoning" }, presentsInterface: false)
        var copied: [String] = []
        tool.onCopy = { copied.append($0) }
        tool.show(input: "diagnosis")
        await settle(tool)
        #expect(tool.session.conceptLens?.map == nil)
        #expect(tool.viewController.resultTextView.string.contains("Identifying a disease."))
        #expect(tool.viewController.routeLabel.stringValue.hasPrefix("●"))
        #expect(tool.viewController.routeLabel.toolTip != nil)
        #expect(!tool.showLarger())
        tool.copyCurrentOutput()
        #expect(copied.count == 1 && copied[0].contains("Parents:"))
        #expect(!tool.session.isOpen)
    }

    @Test @MainActor func malformedJsonFallbackShowsAndCopiesOnlyReceivedText() async {
        let received = "{\"name\":\"Diagnosis\",\"definition\":"
        let tool = OmniEphemeralWindowController(descriptor: lensDescriptor(), producer: { _, _ in received }, presentsInterface: false)
        var copied: [String] = []
        tool.onCopy = { copied.append($0) }
        tool.show(input: "diagnosis")
        await settle(tool)
        #expect(tool.session.conceptLens?.map == nil)
        #expect(tool.viewController.resultTextView.string == received)
        #expect(tool.viewController.routeLabel.stringValue.hasPrefix("●"))
        #expect(tool.viewController.routeLabel.toolTip?.contains("invalid JSON") == true)
        #expect(!tool.showLarger())
        tool.copyCurrentOutput()
        #expect(copied == [received])
        #expect(!tool.session.isOpen)
    }

    @Test @MainActor func previewIsTransientAndEscapeClosesItBeforeTheTool() async throws {
        let tool = OmniEphemeralWindowController(descriptor: lensDescriptor(), producer: { _, _ in diagnosisLensJSON }, presentsInterface: false)
        tool.show(input: "diagnosis")
        await settle(tool)
        #expect(tool.showLarger())
        let preview = tool.viewController.conceptPreview
        let file = try #require(preview.url)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        tool.viewController.editor.keyDown(with: escape)
        #expect(tool.session.isOpen && preview.url == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        tool.viewController.editor.keyDown(with: escape)
        #expect(!tool.session.isOpen)
    }

    @Test @MainActor func editingDisablesCopyAndDiscardsPreview() async throws {
        let tool = OmniEphemeralWindowController(descriptor: lensDescriptor(), producer: { _, _ in diagnosisLensJSON }, presentsInterface: false)
        tool.show(input: "diagnosis")
        await settle(tool)
        #expect(tool.showLarger())
        let file = try #require(tool.viewController.conceptPreview.url)
        tool.session.inputChanged("new input")
        #expect(tool.session.copyableOutput == nil)
        #expect(tool.viewController.conceptPreview.url == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        tool.dismiss()
        #expect(tool.session.conceptLens == nil)
    }

    @Test @MainActor func emptyTransportResponseCannotBeCopiedAsAnAnswer() async {
        let tool = OmniEphemeralWindowController(descriptor: lensDescriptor(), producer: { _, _ in " " }, presentsInterface: false)
        tool.show(input: "diagnosis")
        for _ in 0..<10_000 {
            if case .failed = tool.session.phase { break }
            await Task.yield()
        }
        #expect(tool.session.phase == .failed("No result was returned. Try again."))
        #expect(tool.session.conceptLens == nil && tool.session.copyableOutput == nil)
        #expect(!tool.viewController.statusLabel.stringValue.isEmpty)
        #expect(!tool.viewController.copyButton.isEnabled)
        tool.dismiss()
    }
}
