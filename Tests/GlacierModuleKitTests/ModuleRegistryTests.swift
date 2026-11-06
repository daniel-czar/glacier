import Foundation
import GlacierConfiguration
import GlacierModuleKit
import Testing

@Test func builtInCatalogueCoversToolsAndExcludesZoxide() {
    let registry = ModuleRegistry.builtIn
    let tools = registry.descriptors.filter { $0.kind == .ephemeralTool }
    #expect(tools.count == 14)
    #expect(Set(tools.compactMap { $0.typedAliases.first }) ==
            Set(["qq", "tr", "ln", "pr", "ex", "rc", "em", "st", "ra", "mp", "ch", "we", "qr", "rx"]))
    #expect(registry.resolveTyped("cl", settings: .init()).actionID == "clipboard.history")
    #expect(registry.descriptor(for: "native.jump-to-root") != nil)
    #expect(registry.descriptor(for: "rail.switch") == nil)
    #expect(!registry.descriptors.contains { $0.moduleID == "rail" })
    #expect(!registry.descriptors.contains { $0.id.contains("zoxide") })
    #expect(registry.resolveSlash("/retrieve", settings: .init()).actionID == "command.find")
}

@Test func disablingModuleClosesEveryRouteButDisablingShortcutDoesNot() throws {
    let registry = ModuleRegistry.builtIn
    var settings = GlacierSettings()
    settings.modules["translation"] = GlacierModuleSettings(enabled: false)
    let chord = try GlacierShortcutChord(keyCode: 37, modifiers: [.command, .option])
    settings.shortcuts["tool.translate"] = GlacierShortcutSettings(enabled: true, chord: chord)
    #expect(registry.resolveTyped("tr", settings: settings).status == .disabledModule)
    #expect(registry.resolveSlash("/translate", settings: settings).status == .disabledModule)
    #expect(registry.resolveAction("tool.translate", settings: settings).status == .disabledModule)
    #expect(registry.resolveShortcut(chord, settings: settings,
                                     registered: ["tool.translate"]).status == .disabledModule)
    #expect(!registry.helpEntries(settings: settings).contains { $0.descriptor.id == "tool.translate" })
    #expect(registry.helpEntries(settings: settings, includeDisabled: true)
        .first { $0.descriptor.id == "tool.translate" }?.status == .disabledModule)

    settings.modules["translation"] = GlacierModuleSettings(enabled: true)
    settings.shortcuts["tool.translate"] = GlacierShortcutSettings(enabled: false, chord: chord)
    #expect(registry.resolveTyped("tr", settings: settings).status == .available)
    #expect(registry.resolveSlash("/translate", settings: settings).status == .available)
    #expect(registry.shortcutState(for: "tool.translate", settings: settings).status == .disabledShortcut)

    settings.shortcuts["tool.translate"] = GlacierShortcutSettings(enabled: true, chord: chord)
    settings.shortcuts["launcher.open"] = GlacierShortcutSettings(enabled: true, chord: chord)
    settings.modules["translation"] = GlacierModuleSettings(enabled: false)
    #expect(registry.shortcutConflicts(settings: settings).isEmpty)
    #expect(registry.resolveShortcut(chord, settings: settings,
                                     registered: ["launcher.open"]).actionID == "launcher.open")
}

@Test func helpNeverClaimsAnUnregisteredOrConflictingBinding() throws {
    let registry = ModuleRegistry.builtIn
    var settings = GlacierSettings()
    let chord = try GlacierShortcutChord(keyCode: 49, modifiers: [.command, .option])
    #expect(registry.shortcutState(for: "launcher.open", settings: settings).status == .disabledShortcut)
    settings.shortcuts["launcher.open"] = GlacierShortcutSettings(enabled: true, chord: chord)
    #expect(registry.shortcutState(for: "launcher.open", settings: settings).status == .unregisteredShortcut)
    #expect(registry.helpEntries(settings: settings).first { $0.descriptor.id == "launcher.open" }?.registeredChord == nil)
    #expect(registry.helpEntries(settings: settings, registeredShortcuts: ["launcher.open"])
        .first { $0.descriptor.id == "launcher.open" }?.registeredChord == chord)

    settings.shortcuts["help.pin"] = GlacierShortcutSettings(enabled: true, chord: chord)
    #expect(registry.shortcutConflicts(settings: settings)[chord] == ["launcher.open", "help.pin"])
    #expect(registry.resolveShortcut(chord, settings: settings,
                                     registered: ["launcher.open", "help.pin"]).status == .conflictingShortcut)
    #expect(registry.helpEntries(settings: settings, registeredShortcuts: ["launcher.open", "help.pin"])
        .first { $0.descriptor.id == "launcher.open" }?.registeredChord == nil)
}

@Test func offlineAndAIPauseOnlyGateRelevantActions() {
    let registry = ModuleRegistry.builtIn
    var settings = GlacierSettings()
    settings.ai.paused = true
    #expect(registry.resolveTyped("qq", settings: settings).status == .unavailable("AI paused"))
    #expect(registry.resolveTyped("em", settings: settings).status == .available)
    #expect(registry.resolveTyped("we", settings: settings).status == .available)
    settings.ai.paused = false
    settings.ai.offline = true
    #expect(registry.resolveTyped("we", settings: settings).status == .available)
    #expect(registry.resolveTyped("qr", settings: settings).status == .available)
    #expect(registry.resolveTyped("pr", settings: settings).status == .available)
    #expect(registry.resolveSlash("/slug", settings: settings).status == .unavailable("Offline mode"))
    #expect(registry.resolveSlash("/offline", settings: settings).status == .available)
}

@Test func duplicateRoutesAreRejectedBeforeRuntime() {
    let first = ModuleDescriptor(id: "a", moduleID: "one", title: "A", kind: .ephemeralTool,
                                 typedAliases: ["aa"])
    let second = ModuleDescriptor(id: "b", moduleID: "two", title: "B", kind: .ephemeralTool,
                                  typedAliases: ["aa"])
    #expect(throws: ModuleRegistryError.duplicateTypedAlias("aa")) {
        try ModuleRegistry(descriptors: [first, second])
    }
}

@Test func suggestedHyperLayoutHasNoZoxideAndNoDuplicateChords() throws {
    let proposed = try SuggestedHyperPreset.applying(to: GlacierSettings())
    #expect(ModuleRegistry.builtIn.shortcutConflicts(settings: proposed).isEmpty)
    #expect(proposed.shortcuts.values.allSatisfy { $0.chord?.keyCode != 6 })
    #expect(proposed.shortcuts["tool.quick-question"] == nil)
    #expect(proposed.shortcuts["rail.switch"] == nil)
    #expect(ModuleRegistry.builtIn.shortcutState(for: "launcher.open", settings: proposed).status == .unregisteredShortcut)
}
