import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

@Test func recallRouteKeepsItsPayloadLiteral() {
    #expect(OmniRecallRoute.intent(in: "/recall") == "")
    #expect(OmniRecallRoute.intent(in: "  /recall  how to /g /rm @work") == "how to /g /rm @work")
    #expect(OmniRecallRoute.intent(in: "/recalls x") == nil)
    #expect(OmniRecallRoute.intent(in: "/qq /recall") == nil)
}

@Test @MainActor func recallPadConsumesLocallyAndSuppressesDurableRoute() throws {
    let manifest = try CommandManifest(data: FrozenContractCorpus().data(named: "manifest"))
    let parser = OmniParser(manifest: manifest, references: try ReferenceRegistry([]))
    let pad = OmniCommandPadViewController(parser: parser)
    pad.loadViewIfNeeded()
    var intents: [String] = []
    var durableSubmits = 0
    pad.onRecallRequested = { intents.append($0) }
    pad.onSubmit = { _, _ in durableSubmits += 1 }
    pad.editor.string = "/recall undo commit /g"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(!pad.isCompletionVisible)
    #expect(pad.footerState.runEnabled)
    #expect(pad.footerState.routeLine.text == "Recall · opens native panel")
    pad.submit(.enterShowHere)
    pad.submit(.enterShowHere)
    #expect(intents == ["undo commit /g"])
    #expect(durableSubmits == 0)
}
