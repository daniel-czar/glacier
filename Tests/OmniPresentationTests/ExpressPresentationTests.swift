import AppKit
import Foundation
@testable import OmniPresentation
import Testing

private func expressDescriptor(maximumInputCharacters: Int = 4_096) -> OmniEphemeralToolDescriptor {
    OmniEphemeralToolDescriptor(id: "express", title: "Express", subtitle: "Conversational English",
        inputPlaceholder: "Type English or German", emptyResultHint: "",
        routeTitle: "Express", resultStyle: .express,
        maximumInputCharacters: maximumInputCharacters, debounce: .zero)
}

private let sampleOptions: [ExpressOption] = [
    .init(group: .close, phrase: "That's a good point.", cue: "neutral"),
    .init(group: .close, phrase: "I see what you mean.", cue: "warm"),
    .init(group: .broader, phrase: "Fair enough.", cue: "concedes a little")
]

private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private actor ExpressTestProducer {
    typealias Delta = @Sendable (String) async -> Void
    private struct Request {
        let delta: Delta
        let continuation: CheckedContinuation<String, Error>
    }
    private var requests: [String: Request] = [:]

    func run(_ input: String, delta: @escaping Delta) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            requests[input] = Request(delta: delta, continuation: continuation)
        }
    }

    func hasStarted(_ input: String) -> Bool { requests[input] != nil }
    func emit(_ line: String, for input: String) async { await requests[input]?.delta(line) }
    func finish(_ result: String, for input: String) {
        requests.removeValue(forKey: input)?.continuation.resume(returning: result)
    }
}

@MainActor private func awaitExpress(_ predicate: () -> Bool) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        await Task.yield()
    }
    Issue.record("Express state did not arrive")
}

@Test func expressProtocolValidatesFinalBeforeCopy() throws {
    let valid = ExpressResult(options: sampleOptions)
    #expect(OmniExpressProjection.decodeFinal(try json(valid)) == valid)
    #expect(OmniExpressProjection.decodeFinal("{\"options\":[]}") == nil)
    #expect(OmniExpressProjection.decodeFinal(try json(ExpressResult(options: [sampleOptions[0]]))) == nil)
    #expect(OmniExpressProjection.decodeFinal(try json(ExpressResult(options: [
        sampleOptions[0], .init(group: .broader, phrase: "Another way", cue: "")
    ]))) == nil)
    #expect(OmniExpressProjection.decodeFinal(try json(ExpressResult(options: Array(repeating: sampleOptions[0], count: 7)))) == nil)
    #expect(OmniExpressProjection.decodeFinal(try json(ExpressResult(options: [
        sampleOptions[0], .init(group: .broader, phrase: sampleOptions[0].phrase, cue: "wider")
    ]))) == nil)
    #expect(!OmniExpressProjection.validOption(.init(group: .broader, phrase: "Fine", cue: "")))
    #expect(!OmniExpressProjection.validOption(.init(group: .close, phrase: String(repeating: "x", count: 501), cue: "")))
    #expect(!OmniExpressProjection.validOption(.init(group: .close, phrase: "Line\nbreak", cue: "")))
    #expect(!OmniExpressProjection.validPrefix([sampleOptions[2], sampleOptions[0]]))
    #expect(!OmniExpressProjection.validPrefix(Array(repeating: sampleOptions[0], count: 4)))
    let all = OmniExpressProjection.formatAll(valid)
    #expect(all.contains("Close alternatives\n• That's a good point. — neutral"))
    #expect(all.contains("Broader options\n• Fair enough. — concedes a little"))
}

@Test func expressStreamingProjectsOnlyCompleteOptionEvents() throws {
    let first = try json(ExpressEvent(event: .option, option: sampleOptions[0]))
    let broader = try json(ExpressEvent(event: .option, option: sampleOptions[2]))
    let malformed = "{\"version\":1,\"event\":\"option\",\"option\":"
    #expect(OmniExpressProjection.decodeStreaming(first + "\n" + malformed) == [sampleOptions[0]])
    #expect(OmniExpressProjection.decodeStreaming(first + "\n" + broader + "\n") == [sampleOptions[0], sampleOptions[2]])
    let wrongVersion = try json(ExpressEvent(version: 2, event: .option, option: sampleOptions[1]))
    #expect(OmniExpressProjection.decodeStreaming(wrongVersion).isEmpty)
}

@Test @MainActor
func expressRowsSelectionAndCopyWaitForValidatedFinal() async throws {
    _ = NSApplication.shared
    let producer = ExpressTestProducer()
    let window = OmniEphemeralWindowController(descriptor: expressDescriptor(),
        producer: { input, delta in try await producer.run(input, delta: delta) },
        presentsInterface: false)
    var copied: [String] = []
    window.onCopy = { copied.append($0) }
    window.show(input: "ja, das stimmt")
    await awaitExpress { window.session.phase == .waiting }
    for _ in 0..<1_000 { if await producer.hasStarted("ja, das stimmt") { break }; await Task.yield() }
    for option in sampleOptions {
        await producer.emit(try json(ExpressEvent(event: .option, option: option)) + "\n", for: "ja, das stimmt")
    }
    #expect(window.session.phase == .streaming)
    #expect(window.session.expressOptions == sampleOptions)
    #expect(window.session.selectedExpressIndex == 0)
    #expect(window.session.copyableOutput == nil)
    #expect(window.viewController.expressResultsView.rowViews.count == 3)
    #expect(window.viewController.expressResultsView.rowViews[2].option.group == .broader)
    window.copyCurrentOutput()
    window.copyAllExpressOptions()
    #expect(copied.isEmpty)

    let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
        isARepeat: false, keyCode: 125))
    window.viewController.editor.keyDown(with: down)
    #expect(window.session.selectedExpressIndex == 1)
    window.viewController.expressResultsView.rowViews[2].onSelect?()
    #expect(window.session.selectedExpressIndex == 2)
    await producer.finish(try json(ExpressResult(options: sampleOptions)), for: "ja, das stimmt")
    await awaitExpress { window.session.phase == .ready }
    #expect(window.session.selectedExpressIndex == 2)
    #expect(window.session.copyableOutput == "Fair enough.")
    window.copyCurrentOutput()
    #expect(copied == ["Fair enough."])
    #expect(!window.session.isOpen)
}

@Test @MainActor
func expressEnterCopiesSelectedWordingAndCopyAllRemainsSecondary() async throws {
    _ = NSApplication.shared
    let producer = ExpressTestProducer()
    let window = OmniEphemeralWindowController(descriptor: expressDescriptor(),
        producer: { input, delta in try await producer.run(input, delta: delta) },
        presentsInterface: false)
    var copied: [String] = []
    window.onCopy = { copied.append($0) }
    window.show(input: "working")
    for _ in 0..<1_000 { if await producer.hasStarted("working") { break }; await Task.yield() }
    let view = window.viewController
    #expect(view.routeLabel.stringValue == "Provider")
    #expect(view.toolPill.title == "Express")
    #expect(view.view.subviews.allSatisfy { !($0 is NSButton && ($0 as? NSButton)?.title == "Copy All") })
    #expect(view.keyHintsView.hints.contains(.init("↩", "Copy")))
    #expect(view.keyHintsView.hints.contains(.init("⌥↩", "Copy all")))
    #expect(abs(view.routeLabel.frame.midY - view.keyHintsView.frame.midY) < 12)
    #expect(!view.copyButton.isEnabled)
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
            try png.write(to: directory.appendingPathComponent("express-pill-working-\(appearance.rawValue).png"))
        }
    }
    await producer.finish(try json(ExpressResult(options: sampleOptions)), for: "working")
    await awaitExpress { window.session.phase == .ready }
    #expect(view.keyHintsView.hints.contains(.init("↩", "Copy")))
    #expect(view.copyButton.isEnabled)
    #expect(view.copyButton.toolTip == "Copy selected wording and close")
    view.view.setFrameSize(NSSize(width: 360, height: view.view.frame.height))
    view.render()
    #expect(view.keyHintsView.fittingHeight(forWidth: view.keyHintsView.frame.width) <= view.keyHintsView.frame.height)
    #expect(view.keyHintsView.frame.maxY <= view.routeLabel.frame.minY - 4)
    window.session.selectExpressOption(at: 2)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    view.editor.keyDown(with: enter)
    #expect(copied == ["Fair enough."])
    #expect(!window.session.isOpen)

    let button = OmniEphemeralWindowController(descriptor: expressDescriptor(),
        producer: { _, _ in try json(ExpressResult(options: sampleOptions)) }, presentsInterface: false)
    var buttonCopy: [String] = []
    button.onCopy = { buttonCopy.append($0) }
    button.show(input: "button")
    await awaitExpress { button.session.phase == .ready }
    button.viewController.expressResultsView.rowViews[1].onSelect?()
    button.viewController.copyButton.onPress?()
    #expect(buttonCopy == ["I see what you mean."])
    #expect(!button.session.isOpen)

    let all = OmniEphemeralWindowController(descriptor: expressDescriptor(),
        producer: { _, _ in try json(ExpressResult(options: sampleOptions)) }, presentsInterface: false)
    var allCopy: [String] = []
    all.onCopy = { allCopy.append($0) }
    all.show(input: "all")
    await awaitExpress { all.session.phase == .ready }
    all.session.selectExpressOption(at: 2)
    let optionReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.option, .numericPad, .function], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 76))
    all.viewController.editor.keyDown(with: optionReturn)
    #expect(allCopy == [OmniExpressProjection.formatAll(ExpressResult(options: sampleOptions))])
    #expect(!all.session.isOpen)

    let selected = OmniEphemeralWindowController(descriptor: expressDescriptor(),
        producer: { _, _ in try json(ExpressResult(options: sampleOptions)) },
        presentsInterface: false)
    var selectedCopy: [String] = []
    selected.onCopy = { selectedCopy.append($0) }
    selected.show(input: "selected")
    await awaitExpress { selected.session.phase == .ready }
    selected.session.selectExpressOption(at: 2)
    let commandShiftC = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
        characters: "C", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    selected.viewController.editor.keyDown(with: commandShiftC)
    #expect(selectedCopy == ["Fair enough."])
    #expect(!selected.session.isOpen)
}

@Test @MainActor
func expressCopyAllShortcutRespectsMarkedText() throws {
    _ = NSApplication.shared
    let editor = OmniEphemeralTextView()
    var copyCount = 0
    editor.onCopyAll = { copyCount += 1 }
    editor.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    let optionReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    editor.keyDown(with: optionReturn)
    #expect(copyCount == 0)
}

@Test @MainActor
func expressManualModeKeepsGeneratePrimaryAndCopyAllNeverGeneratesPendingOutput() async throws {
    _ = NSApplication.shared
    let producer = ExpressTestProducer()
    let window = OmniEphemeralWindowController(descriptor: expressDescriptor(),
        producer: { input, delta in try await producer.run(input, delta: delta) },
        presentsInterface: false, automaticRequestsEnabled: { false })
    var copied: [String] = []
    window.onCopy = { copied.append($0) }
    window.show(input: "manual")
    let view = window.viewController
    #expect(window.session.phase == .empty)
    #expect(view.keyHintsView.hints.contains(.init("↩", "Generate")))
    let optionReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    view.editor.keyDown(with: optionReturn)
    #expect(window.session.phase == .empty)
    #expect(copied.isEmpty)
    view.copyButton.onPress?()
    await awaitExpress { window.session.phase == .waiting }
    for _ in 0..<1_000 { if await producer.hasStarted("manual") { break }; await Task.yield() }
    await producer.emit(try json(ExpressEvent(event: .option, option: sampleOptions[0])) + "\n", for: "manual")
    #expect(window.session.phase == .streaming)
    view.editor.keyDown(with: optionReturn)
    #expect(copied.isEmpty)
    await producer.finish(try json(ExpressResult(options: sampleOptions)), for: "manual")
    await awaitExpress { window.session.phase == .ready }
    window.session.selectExpressOption(at: 1)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    view.editor.keyDown(with: enter)
    #expect(copied == ["I see what you mean."])
    #expect(!window.session.isOpen)
}

@Test @MainActor
func expressPanelResponderRoutesEnterAndCopyAllToCurrentSelection() async throws {
    _ = NSApplication.shared
    let result = ExpressResult(options: sampleOptions)
    let selected = OmniEphemeralWindowController(descriptor: expressDescriptor(),
        producer: { _, _ in try json(result) }, presentsInterface: false)
    var selectedCopy: [String] = []
    selected.onCopy = { selectedCopy.append($0) }
    selected.show(input: "panel selected")
    await awaitExpress { selected.session.phase == .ready }
    selected.session.selectExpressOption(at: 2)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    let selectedPanel = try #require(selected.panel as? OmniEphemeralPanel)
    selectedPanel.keyDown(with: enter)
    #expect(selectedCopy == ["Fair enough."])

    let all = OmniEphemeralWindowController(descriptor: expressDescriptor(),
        producer: { _, _ in try json(result) }, presentsInterface: false)
    var allCopy: [String] = []
    all.onCopy = { allCopy.append($0) }
    all.show(input: "panel all")
    await awaitExpress { all.session.phase == .ready }
    let optionReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    let allPanel = try #require(all.panel as? OmniEphemeralPanel)
    allPanel.keyDown(with: optionReturn)
    #expect(allCopy == [OmniExpressProjection.formatAll(result)])
}

@Test @MainActor
func expressCopyAllAndEditingGateStaleRows() async throws {
    _ = NSApplication.shared
    let producer = ExpressTestProducer()
    let window = OmniEphemeralWindowController(descriptor: expressDescriptor(maximumInputCharacters: 4_096),
        producer: { input, delta in try await producer.run(input, delta: delta) },
        presentsInterface: false)
    var copied: [String] = []
    window.onCopy = { copied.append($0) }
    window.show(input: "first")
    for _ in 0..<1_000 { if await producer.hasStarted("first") { break }; await Task.yield() }
    await producer.finish(try json(ExpressResult(options: sampleOptions)), for: "first")
    await awaitExpress { window.session.phase == .ready }
    window.session.selectExpressOption(at: 2)
    window.session.inputChanged("second")
    #expect(window.session.phase == .waiting)
    #expect(window.session.selectedExpressIndex == nil)
    #expect(!window.session.outputIsCurrent)
    #expect(window.viewController.expressResultsView.rowViews.allSatisfy { $0.alphaValue < 1 })
    window.copyCurrentOutput()
    window.copyAllExpressOptions()
    let optionReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    window.viewController.editor.keyDown(with: optionReturn)
    #expect(copied.isEmpty)
    for _ in 0..<1_000 { if await producer.hasStarted("second") { break }; await Task.yield() }
    await producer.finish(try json(ExpressResult(options: sampleOptions)), for: "second")
    await awaitExpress { window.session.phase == .ready }
    #expect(window.session.selectedExpressIndex == 0)
    window.viewController.editor.keyDown(with: optionReturn)
    #expect(copied == [OmniExpressProjection.formatAll(ExpressResult(options: sampleOptions))])
    #expect(!window.session.isOpen)
}

@Test @MainActor
func expressInvalidFinalAndOverlongInputDoNotCopy() async throws {
    _ = NSApplication.shared
    let producer = ExpressTestProducer()
    let window = OmniEphemeralWindowController(descriptor: expressDescriptor(maximumInputCharacters: 4_096),
        producer: { input, delta in try await producer.run(input, delta: delta) },
        presentsInterface: false)
    var copied: [String] = []
    window.onCopy = { copied.append($0) }
    window.show(input: "short")
    for _ in 0..<1_000 { if await producer.hasStarted("short") { break }; await Task.yield() }
    await producer.emit(try json(ExpressEvent(event: .option, option: sampleOptions[0])) + "\n", for: "short")
    await producer.finish("{\"options\":[]}", for: "short")
    await awaitExpress { if case .failed = window.session.phase { return true }; return false }
    #expect(window.session.copyableOutput == nil)
    window.session.inputChanged(String(repeating: "a", count: 4_097))
    #expect(window.session.expressOptions.isEmpty)
    #expect(window.session.copyableOutput == nil)
    window.copyCurrentOutput()
    #expect(copied.isEmpty)
    window.dismiss()
}

@Test @MainActor
func expressLongRowsWrapAndKeyboardSelectionScrolls() async throws {
    _ = NSApplication.shared
    let longPhrase = String(repeating: "A conversational alternative with enough context to read clearly. ", count: 7)
        .trimmingCharacters(in: .whitespaces)
    let options: [ExpressOption] = [
        .init(group: .close, phrase: longPhrase, cue: String(repeating: "subtle context ", count: 6).trimmingCharacters(in: .whitespaces)),
        .init(group: .close, phrase: "I understand.", cue: "calm"),
        .init(group: .close, phrase: "I get it.", cue: "casual"),
        .init(group: .broader, phrase: "That makes sense.", cue: "accepting"),
        .init(group: .broader, phrase: "Fair enough.", cue: "conceding"),
        .init(group: .broader, phrase: "We can work with that.", cue: "practical")
    ]
    let window = OmniEphemeralWindowController(descriptor: expressDescriptor(),
        producer: { _, _ in try json(ExpressResult(options: options)) }, presentsInterface: false)
    window.show(input: "ein langer Satz")
    await awaitExpress { window.session.phase == .ready }
    let view = window.viewController
    view.view.setFrameSize(NSSize(width: 360, height: view.view.frame.height))
    view.render()
    let first = try #require(view.expressResultsView.rowViews.first)
    #expect(first.phraseLabel.stringValue == longPhrase)
    #expect(first.phraseLabel.frame.height > 40)
    #expect(first.cueLabel.frame.height > 16)
    let scroll = try #require(view.expressResultsView.enclosingScrollView)
    #expect(view.expressResultsView.contentHeight > scroll.contentView.bounds.height)
    for _ in 0..<5 { window.session.moveExpressSelection(by: 1) }
    #expect(window.session.selectedExpressIndex == 5)
    let selected = try #require(view.expressResultsView.rowViews.last)
    #expect(scroll.contentView.bounds.maxY >= selected.frame.maxY - 1)

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
            try png.write(to: directory.appendingPathComponent("express-long-selected-\(appearance.rawValue).png"))
        }
    }
    window.dismiss()
}
