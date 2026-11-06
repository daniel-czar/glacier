import AppKit
import Foundation
import GlacierConfiguration
import GlacierModuleKit
import GlacierPlatform
import HyperOverlayCore
import HyperOverlayRuntime
import Testing

private actor FinderProbe {
    private(set) var inputs: [String] = []
    func record(_ input: String) { inputs.append(input) }
}

@MainActor
private final class FakeShortcutRegistrar: ShortcutRegistering {
    private(set) var bindings: [OverlayHotKeyBinding] = []
    private(set) var replacements = 0
    var failNext = false
    var mutateThenFailNext = false

    func replace(with bindings: [OverlayHotKeyBinding]) throws {
        replacements += 1
        if failNext { failNext = false; throw ShortcutControllerError.duplicateChord }
        if mutateThenFailNext {
            mutateThenFailNext = false
            self.bindings = bindings
            throw ShortcutControllerError.registrationFailed("synthetic cleanup failure")
        }
        self.bindings = bindings
    }

    func stop() -> [String] { bindings = []; return [] }
}

@MainActor
private struct FakeLabels: ShortcutLabeling {
    func keyLabel(for keyCode: UInt16) -> String { keyCode == 44 ? "/" : "Key \(keyCode)" }
}

private actor FakeScriptRunner: AppleScriptRunning {
    private(set) var calls: [(String, [String])] = []
    func run(script: String, arguments: [String], timeout: TimeInterval) async -> Bool {
        calls.append((script, arguments))
        return true
    }
    func lastArguments() -> [String]? { calls.last?.1 }
    func lastScript() -> String? { calls.last?.0 }
}

@MainActor
@Test func previewNeverRegistersAndFailedSaveRollsBack() async throws {
    let registrar = FakeShortcutRegistrar()
    var settings = GlacierSettings()
    settings.shortcuts["launcher.open"] = .init(enabled: true,
        chord: try GlacierShortcutChord(keyCode: 44, modifiers: [.command, .option]))
    let preview = ShortcutController(settings: settings, safePreview: true, registrar: registrar)
    #expect(registrar.replacements == 0)
    #expect(throws: ShortcutControllerError.self) {
        try preview.activate(registry: .builtIn)
    }
    #expect(registrar.replacements == 0)

    let active = ShortcutController(settings: settings, registrar: registrar)
    try active.activate(registry: .builtIn)
    #expect(registrar.bindings.map(\.overlayID) == ["launcher.open"])
    #expect(active.helpEntries(registry: .builtIn).first { $0.descriptor.id == "launcher.open" }?.registeredChord != nil)
    var changed = settings
    changed.shortcuts["launcher.open"] = .init(enabled: true,
        chord: try GlacierShortcutChord(keyCode: 0, modifiers: [.command, .option]))
    struct SaveFailure: Error {}
    await #expect(throws: SaveFailure.self) {
        try await active.apply(changed, registry: .builtIn, save: { _ in throw SaveFailure() })
    }
    #expect(registrar.bindings.first?.chord.keyCode == 44)
    #expect(active.helpEntries(registry: .builtIn).first { $0.descriptor.id == "launcher.open" }?.registeredChord?.keyCode == 44)
}

@MainActor
@Test func disabledModuleRemovesOnlyItsShortcut() async throws {
    let registrar = FakeShortcutRegistrar()
    var settings = GlacierSettings()
    settings.shortcuts["launcher.open"] = .init(enabled: true,
        chord: try GlacierShortcutChord(keyCode: 44, modifiers: [.command, .option]))
    settings.shortcuts["tool.recall"] = .init(enabled: true,
        chord: try GlacierShortcutChord(keyCode: 15, modifiers: [.command, .option]))
    let controller = ShortcutController(settings: settings, registrar: registrar)
    try controller.activate(registry: .builtIn)
    #expect(controller.registeredActionIDs.count == 2)
    var changed = settings
    changed.modules["recall"] = .init(enabled: false)
    try await controller.apply(changed, registry: .builtIn, save: { _ in })
    #expect(controller.registeredActionIDs == ["launcher.open"])
    #expect(registrar.bindings.map(\.overlayID) == ["launcher.open"])
}

@MainActor
@Test func registrationFailureAfterMutationRestoresPreviousBinding() async throws {
    let registrar = FakeShortcutRegistrar()
    var settings = GlacierSettings()
    settings.shortcuts["launcher.open"] = .init(enabled: true,
        chord: try GlacierShortcutChord(keyCode: 44, modifiers: [.command, .option]))
    let controller = ShortcutController(settings: settings, registrar: registrar)
    try controller.activate(registry: .builtIn)
    var changed = settings
    changed.shortcuts["launcher.open"] = .init(enabled: true,
        chord: try GlacierShortcutChord(keyCode: 0, modifiers: [.command, .option]))
    registrar.mutateThenFailNext = true
    var saved = false
    await #expect(throws: ShortcutControllerError.self) {
        try await controller.apply(changed, registry: .builtIn, save: { _ in saved = true })
    }
    #expect(!saved)
    #expect(registrar.bindings.first?.chord.keyCode == 44)
    #expect(controller.helpEntries(registry: .builtIn).first { $0.descriptor.id == "launcher.open" }?.registeredChord?.keyCode == 44)
}

@MainActor
@Test func labelsUseInjectedKeyboardLayoutAndDoNotAssumeCapsHyper() throws {
    let chord = try GlacierShortcutChord(keyCode: 44, modifiers: [.command, .option])
    let projection = ShortcutLabelProjection(labeler: FakeLabels())
    #expect(projection.label(chord) == "⌘⌥/")
    let layout = projection.keyboardLayout()
    #expect(layout.cap(forKeyCode: 44)?.glyph == "/")
    #expect(layout.cap(id: "caps")?.glyph == "caps lock")
}

@MainActor
@Test func overlayRepresentsTwoModifierGroupsOnOnePhysicalKey() throws {
    let registrar = FakeShortcutRegistrar()
    var settings = GlacierSettings()
    settings.shortcuts["launcher.open"] = .init(enabled: true,
        chord: try GlacierShortcutChord(keyCode: 44, modifiers: [.command, .option]))
    settings.shortcuts["tool.recall"] = .init(enabled: true,
        chord: try GlacierShortcutChord(keyCode: 44, modifiers: [.control, .shift]))
    let controller = ShortcutController(settings: settings, registrar: registrar)
    try controller.activate(registry: .builtIn)
    let layout = ShortcutLabelProjection(labeler: FakeLabels()).keyboardLayout()
    let catalog = controller.overlayCatalog(registry: .builtIn, layout: layout)
    let capID = try #require(layout.cap(forKeyCode: 44)?.id)
    let combined = try #require(catalog.bindings[capID])
    #expect(combined.actionCount == 2)
    #expect(combined.label == "2 actions")
    #expect(combined.description.contains("Launcher"))
    #expect(combined.description.contains("Recall"))
    #expect(combined.chordLabel?.contains("⌘⌥/") == true)
    #expect(combined.chordLabel?.contains("⌃⇧/") == true)
    #expect(catalog.problems.isEmpty)
}

@MainActor
@Test func terminalUsesOneStructuredFolderArgumentAndGhosttyVersionGate() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glacier terminal ' \" ; \n \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let runner = FakeScriptRunner()
    let terminal = TerminalAdapter(preference: .systemTerminal, runner: runner)
    try await terminal.open(folder: folder)
    #expect(await runner.lastArguments() == [folder.path])
    #expect(await runner.lastScript() == TerminalAdapter.terminalScript)
    let oldGhostty = TerminalAdapter(preference: .ghostty, runner: runner, ghosttyVersion: { "1.2.9" })
    await #expect(throws: TerminalOpenError.self) { try await oldGhostty.open(folder: folder) }
    #expect(TerminalAdapter.supportsGhosttyAppleScript("1.3.0"))
    #expect(!TerminalAdapter.supportsGhosttyAppleScript("1.2.9"))
}

@MainActor
@Test func portableHelpersUseExplicitInputs() {
    #expect(PortableKeyActionEffects.webURL(in: "see https://example.org/x).") == "https://example.org/x")
    #expect(PortableKeyActionEffects.existingPath(in: "a relative/path") == nil)
    let fenced = PortableKeyActionEffects.markdownFence("before ``` inside")
    #expect(fenced.hasPrefix("````\n"))
}

@MainActor
@Test func markdownLocalDestinationsWinOverLabelsAndSearch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-links-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("actual (draft) file.md")
    let parenthesized = root.appendingPathComponent("actual(draft).md")
    let other = root.appendingPathComponent("label.md")
    let literalSuffix = root.appendingPathComponent("literal.md:42")
    let literalHeading = root.appendingPathComponent("literal.md#heading")
    let literalPercent = root.appendingPathComponent("literal%20name.md")
    let spaced = root.appendingPathComponent("literal name.md")
    try Data().write(to: target)
    try Data().write(to: parenthesized)
    try Data().write(to: other)
    try Data().write(to: literalSuffix)
    try Data().write(to: literalHeading)
    try Data().write(to: literalPercent)
    try Data().write(to: spaced)
    let label = "[\(other.path)](<\(target.path)>)"
    #expect(PortableKeyActionEffects.existingPath(in: label) == target.path)
    let escaped = parenthesized.path.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
    #expect(PortableKeyActionEffects.existingPath(in: "[name](\(escaped))") == parenthesized.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](<\(target.path)>)") == target.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](<\(target.path)> \"Title\")") == target.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](\(target.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))") == target.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](\(target.absoluteString))") == target.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](<\(target.path):42>)") == target.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](<\(target.path)#L42>)") == target.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](<\(target.path)#heading>)") == target.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](<\(literalSuffix.path)>)") == literalSuffix.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](<\(literalHeading.path)>)") == literalHeading.path)
    #expect(PortableKeyActionEffects.existingPath(in: literalPercent.path) == literalPercent.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](\(literalPercent.path))") == spaced.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](\(literalPercent.absoluteString))") == literalPercent.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[name](file://remotehost\(target.path))") == nil)
    #expect(PortableKeyActionEffects.existingPath(in: "](<\(target.path)>)") == nil)
    #expect(PortableKeyActionEffects.existingPath(in: "[see [label.md] now](<\(target.path)>)") == target.path)
    #expect(PortableKeyActionEffects.existingPath(in: "[escaped \\] label](<\(target.path)>)") == target.path)
    #expect(MarkdownLocalLink.remainingText(in: "before[link](<\(target.path)>)after") == "before after")
    #expect(PortableKeyActionEffects.existingPath(in: "[\(other.path)](/missing/fixture.md)") == nil)

    let probe = FinderProbe()
    let collect = CollectSystemEffects(pasteboard: NSPasteboard(name: .init("glacier-link-\(UUID().uuidString)")), onFailure: { _ in })
    let effects = PortableKeyActionEffects(collect: collect, settings: GlacierSettings(),
        fileFinder: { text in await probe.record(text); return text == other.path ? [other] : [] }, onFailure: { _ in }, onNotice: { _ in })
    #expect(await effects.helper(.extractPath, input: label) == .value(target.path))
    #expect(await effects.helper(.gather, input: label) == .value(target.path))
    #expect(await effects.helper(.gather, input: "!" + label) == .value(target.path))
    #expect(await probe.inputs.isEmpty)
    #expect(await effects.helper(.gather, input: "[see [\(other.path)] now](<\(target.path)>)") == .value(target.path))
    #expect(await probe.inputs.isEmpty)
    #expect(await effects.helper(.gather, input: "[\(other.path)](/missing/fixture.md)") == .none)
    #expect(await probe.inputs.isEmpty)
    #expect(await effects.helper(.gather, input: label + "\n" + other.path) == .value(target.path + "\n" + other.path))
    #expect(await probe.inputs == [other.path])
}
