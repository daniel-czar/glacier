import AppKit
import Foundation
import OmniCore
@testable import OmniPresentation
import Testing

@MainActor private func polishPad() throws -> OmniCommandPadViewController {
    _ = NSApplication.shared
    let corpus = FrozenContractCorpus()
    let parser = OmniParser(
        manifest: try CommandManifest(data: corpus.data(named: "manifest")),
        references: try ReferenceRegistry([])
    )
    let pad = OmniCommandPadViewController(parser: parser)
    pad.loadView()
    pad.onResolveRoute = { _, id in
        OmniPadRoute(
            providerName: id == nil ? "Cerebras" : "ChatGPT",
            scope: id == nil ? .policyDefault : .thisRunOnly,
            displayName: id == nil ? "Cerebras Qwen 3.8 27B" : "ChatGPT GPT-5.6 medium"
        )
    }
    pad.setModelChoices([
        .init(id: "chatgpt-capable", label: "ChatGPT GPT-5.6 medium"),
        .init(id: "disabled", label: "Anthropic API Claude Sonnet 4.5 medium", unavailabilityReason: "Anthropic API: connection is off"),
    ])
    return pad
}

@Test @MainActor func padPolishMenuRetainsFullIdentityAndUnavailableReason() throws {
    let pad = try polishPad()
    let item = try #require(pad.modelPopUp.item(at: 3))
    #expect(item.title == "Anthropic API Claude Sonnet 4.5 medium — Anthropic API: connection is off")
    #expect(item.attributedTitle?.string == item.title)
    #expect(item.toolTip == "Anthropic API: connection is off")
    #expect(!item.isEnabled)
    #expect(pad.modelPopUp.item(at: 0)?.image != nil)
    #expect(pad.modelPopUp.titleOfSelectedItem == "⌄")
}

@Test @MainActor func padPolishConstrainedFooterKeepsEveryControlInsideAndApart() throws {
    let pad = try polishPad()
    pad.editor.string = "/email accept the invitation /style:formal"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    pad.selectModelProfile(id: "chatgpt-capable")
    pad.notesButton.title = "12 notes"
    pad.notesButton.isHidden = false
    pad.settingsButton.isHidden = false
    pad.statusLabel.attributedStringValue = OmniCommandPadViewController.attributedRouteLine(
        .attention("The selected model is unavailable for this command · Open settings")
    )
    for width: CGFloat in [320, 400, 640] {
        pad.view.frame.size.width = width
        pad.layoutPad(width: width)
        let controls: [NSView] = [
            pad.statusLabel, pad.notesButton, pad.settingsButton, pad.keyHintsView, pad.runButton,
        ]
        for (index, control) in controls.enumerated() {
            #expect(control.frame.minX >= 16)
            #expect(control.frame.maxX <= width - 16)
            #expect(control.frame.maxY <= pad.editorScrollView!.frame.minY)
            for other in controls.dropFirst(index + 1) {
                #expect(!control.frame.intersects(other.frame))
            }
        }
        // C116: a one-run override no longer shows in the footer.
        #expect(pad.modelPopUp.isHidden && pad.modelOverrideLabel.isHidden && pad.clearModelButton.isHidden)
    }
}

@Test @MainActor func padPolishLongKeyHintGroupsWrapWithinTheFooter() throws {
    let pad = try polishPad()
    pad.editor.string = "/lorem explain the thought"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    pad.modelPopUp.isHidden = true
    pad.modelOverrideLabel.isHidden = true
    pad.clearModelButton.isHidden = true
    pad.keyHintsView.hints = OmniPadKeyHint.proposalResult
    pad.view.frame.size.width = 320
    pad.layoutPad(width: 320)
    #expect(pad.keyHintsView.frame.minX >= 16)
    #expect(pad.keyHintsView.frame.height > 20)
    #expect(!pad.statusLabel.frame.intersects(pad.keyHintsView.frame))
    #expect(pad.statusLabel.frame.minY >= pad.keyHintsView.frame.maxY)
    #expect(pad.keyHintsView.hints == OmniPadKeyHint.proposalResult)
}

@Test @MainActor func padPolishTextUsesTheSharedContentInset() throws {
    let pad = try polishPad()
    #expect(pad.editor.textContainerInset.width == 2)
    #expect(pad.editor.textContainer?.lineFragmentPadding == 0)
    #expect(pad.editorScrollView?.frame.minX == pad.statusLabel.frame.minX)
}

@Test @MainActor func padPolishNativeCaptures() throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let pad = try polishPad()
        let panel = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }
        pad.editor.string = "/lorem"
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
        try capturePolishedPad(pad.view, name: "pad-polish-propose-\(suffix)", appearance: appearance, directory: directory)
        pad.editor.string = "/email accept the invitation /style:formal"
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
        pad.selectModelProfile(id: "chatgpt-capable")
        try capturePolishedPad(pad.view, name: "pad-polish-override-\(suffix)", appearance: appearance, directory: directory)
        pad.notesButton.title = "12 notes"
        pad.notesButton.isHidden = false
        pad.settingsButton.isHidden = false
        panel.setContentSize(NSSize(width: 320, height: pad.view.bounds.height))
        pad.view.frame.size.width = 320
        pad.layoutPad(width: 320)
        #expect(pad.view.bounds.width == 320)
        try capturePolishedPad(pad.view, name: "pad-polish-narrow-\(suffix)", appearance: appearance, directory: directory)
    }
}

@MainActor private func capturePolishedPad(_ view: NSView, name: String, appearance: NSAppearance.Name, directory: URL) throws {
    OmniNativeCaptureHarness.prepare(view, scenario: .constrainedScreen, treatment: .opaqueFallback, appearance: appearance)
    let image = OmniNativeCaptureHarness.image(of: view)
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent("\(name).png"))
}
