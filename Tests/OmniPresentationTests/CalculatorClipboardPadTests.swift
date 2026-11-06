import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

@MainActor
private func localRoutePad() throws -> OmniCommandPadViewController {
    _ = NSApplication.shared
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let parser = OmniParser(manifest: manifest, references: try ReferenceRegistry([]))
    let pad = OmniCommandPadViewController(parser: parser)
    pad.loadView()
    pad.launcherEnabled = true
    return pad
}

@MainActor
private func type(_ text: String, in pad: OmniCommandPadViewController) {
    pad.editor.string = text
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
}

@Test @MainActor func calculatorPreviewAndEnterCopyUseOneLocalAction() throws {
    let pad = try localRoutePad()
    var copied: [String] = []
    var submitted: [String] = []
    var queried: [String] = []
    pad.onCalculatorCopy = { copied.append($0) }
    pad.onSubmit = { text, _ in submitted.append(text) }
    pad.onLauncherQuery = { queried.append($0) }

    type("2 + 3 * 4", in: pad)
    #expect(pad.mode == .composing)
    #expect(pad.routeLine == .outcome("= 14"))
    #expect(pad.footerState.keyHints == OmniPadKeyHint.calculator)
    #expect(queried.isEmpty)
    pad.editor.onSubmit?(.enterShowHere)
    pad.editor.onSubmit?(.enterShowHere)
    #expect(copied == ["14"])
    #expect(submitted.isEmpty)

    type("/calc 0.1 + 0.2", in: pad)
    #expect(pad.routeLine == .outcome("= 0.3"))
    pad.editor.onSubmit?(.enterShowHere)
    #expect(copied == ["14", "0.3"])
    #expect(submitted.isEmpty)
}

@Test @MainActor func calculatorPartialAndFailureCannotFallThrough() throws {
    let pad = try localRoutePad()
    var submitted = 0
    var copied = 0
    pad.onSubmit = { _, _ in submitted += 1 }
    pad.onCalculatorCopy = { _ in copied += 1 }
    for text in ["2 +", "/calc", "/calc 2 / 0", "2 + * 3"] {
        type(text, in: pad)
        #expect(pad.mode == .composing, "\(text)")
        #expect(!pad.footerState.runEnabled, "\(text)")
        pad.editor.onSubmit?(.enterShowHere)
    }
    #expect(submitted == 0)
    #expect(copied == 0)
}

@Test @MainActor func clipboardAliasesOpenHistoryWithLiteralQueryOnce() throws {
    let pad = try localRoutePad()
    var queries: [String] = []
    var submitted: [String] = []
    pad.onClipboardRequested = { queries.append($0) }
    pad.onSubmit = { text, _ in submitted.append(text) }
    type("/cl", in: pad)
    #expect(pad.routeLine == .outcome("Clipboard history · opens picker"))
    #expect(pad.footerState.keyHints == OmniPadKeyHint.clipboard)
    pad.editor.onSubmit?(.enterShowHere)
    pad.editor.onSubmit?(.enterShowHere)
    #expect(queries == [""])
    type("/clipboard project /literal words", in: pad)
    pad.editor.onSubmit?(.enterShowHere)
    #expect(queries == ["", "project /literal words"])
    type("/clipboard /formal ", in: pad)
    #expect(pad.editor.string == "/clipboard /formal ")
    pad.editor.onSubmit?(.enterShowHere)
    #expect(queries == ["", "project /literal words", "/formal"])
    type("/cl /retrieve", in: pad)
    #expect(pad.editor.string == "/cl /retrieve")
    pad.editor.onSubmit?(.enterShowHere)
    #expect(queries == ["", "project /literal words", "/formal", "/retrieve"])
    #expect(submitted.isEmpty)
}

@Test @MainActor func localRoutesAreInCompletionHelpAndDoNotStealOtherInput() throws {
    let pad = try localRoutePad()
    let items = OmniCommandPadViewController.paletteItems(for: "/c", manifest: pad.parser.manifest)
    #expect(items.contains { $0.choice.canonicalText == "/calc" })
    #expect(items.contains { $0.choice.canonicalText == "/cl" })
    #expect(items.contains { $0.choice.canonicalText == "/clipboard" })
    #expect(items.first { $0.choice.canonicalText == "/calc" }?.help.body.contains("Enter copies") == true)

    var submitted: [String] = []
    pad.onSubmit = { text, _ in submitted.append(text) }
    type("2026-10-21", in: pad)
    #expect(pad.mode == .suggesting)
    type("/pron hello", in: pad)
    #expect(pad.routeLine == .outcome("Pronunciation · opens native panel"))
    #expect(submitted.isEmpty)
}

@Test @MainActor func activeCompletionHidesDisabledModulesAndSettingsRoutes() throws {
    let pad = try localRoutePad()
    let available: @MainActor @Sendable (String) -> Bool = {
        !["tool.regex", "command.find", "settings.open"].contains($0)
    }
    let regex = OmniCommandPadViewController.paletteItems(for: "/reg", manifest: pad.parser.manifest,
                                                            isActionAvailable: available)
    #expect(!regex.contains { $0.choice.canonicalText == "/regex" })
    let find = OmniCommandPadViewController.paletteItems(for: "/fi", manifest: pad.parser.manifest,
                                                           isActionAvailable: available)
    #expect(!find.contains { $0.choice.canonicalText == "/find" })
    let settings = OmniCommandPadViewController.paletteItems(for: "/set", manifest: pad.parser.manifest,
                                                               isActionAvailable: available)
    #expect(!settings.contains { $0.choice.canonicalText == "/settings" })
    let allowed = OmniCommandPadViewController.paletteItems(for: "/ma", manifest: pad.parser.manifest,
                                                              isActionAvailable: available)
    #expect(allowed.contains { $0.choice.canonicalText == "/map" })
}

@Test @MainActor func importedArithmeticRemainsMaterialUnlessExplicitlyForced() throws {
    let pad = try localRoutePad()
    pad.setProvenance(OmniPadProvenance(source: "Notes", detail: nil, wordCount: 3, bundleIdentifier: nil))
    type("2 + 3", in: pad)
    #expect(pad.routeLine != .outcome("= 5"))
    type("/calc 2 + 3", in: pad)
    #expect(pad.routeLine == .outcome("= 5"))
}
