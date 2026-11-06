import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

@Test func regexRouteKeepsRawPatternCharacters() {
    #expect(OmniRegexRoute.input(in: "/regex") == "")
    #expect(OmniRegexRoute.input(in: "/regex ") == "")
    #expect(OmniRegexRoute.input(in: "  /regex  ^[A-Z]{1,2}\\d+$  \n") == " ^[A-Z]{1,2}\\d+$  \n")
    #expect(OmniRegexRoute.input(in: "/regex\n(?<name>\\w+) /qr") == "(?<name>\\w+) /qr")
    #expect(OmniRegexRoute.input(in: "/regexes x") == nil)
    #expect(OmniRegexRoute.input(in: "plain /regex x") == nil)
}

@Test @MainActor func regexPadOpensLocallyWithLiteralPattern() throws {
    let parser = OmniParser(manifest: try CommandManifest(data: FrozenContractCorpus().data(named: "manifest")),
                            references: try ReferenceRegistry([]))
    let pad = OmniCommandPadViewController(parser: parser)
    pad.loadViewIfNeeded()
    var inputs: [String] = []
    var durableSubmits = 0
    pad.onRegexRequested = { inputs.append($0) }
    pad.onSubmit = { _, _ in durableSubmits += 1 }
    pad.editor.string = "/regex ^[A-Z]{2}\\d+$ /qr  "
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(!pad.isCompletionVisible)
    #expect(pad.footerState.routeLine.text == "Regex · opens native panel")
    pad.submit(.enterShowHere)
    pad.submit(.enterShowHere)
    #expect(inputs == ["^[A-Z]{2}\\d+$ /qr  "])
    #expect(durableSubmits == 0)
}
