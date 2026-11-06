import Foundation
import GlacierBuiltins
import GlacierConfiguration
import GlacierModuleKit
import OmniPresentation
import Testing

@Test func contributorModuleRegistersResolvesAndExecutesWithoutHostSwitch() async throws {
    #expect(ModuleRegistry.builtIn.descriptor(for: "tool.text.trim") == nil)
    let catalog = try GlacierToolCatalog(modules: [AnyGlacierToolModule(TextTrimModule())])
    let settings = GlacierSettings()
    #expect(catalog.registry.descriptor(for: "tool.text.trim")?.moduleID == "text.trim")
    #expect(catalog.quickLaunchDescriptors == [OmniQuickLaunch(letters: "trm", title: "Trim Text", toolID: "text.trim")])

    let typed = catalog.resolveTyped("trm", settings: settings)
    #expect(typed.resolution.status == .available)
    #expect(typed.module?.presentation.id == "text.trim")
    #expect(catalog.resolveTyped("trm extra", settings: settings).resolution.status == .unknown)

    let slash = catalog.resolveSlash("/trim  \n  hello world  ", settings: settings)
    #expect(slash.resolution.actionID == "tool.text.trim")
    #expect(slash.payload == " \n  hello world  ")
    #expect(try await slash.module?.run(input: .init(text: slash.payload)) == "hello world")
    #expect(catalog.resolveSlash("/trimmed text", settings: settings).resolution.status == .unknown)

    let producer = try #require(slash.module).makeProducer()
    let result = try await producer("  lines\n ", { _ in })
    #expect(result == "lines")
}

@Test func disabledModuleRemovesBothRoutesWithoutErasingDescriptor() throws {
    let catalog = try GlacierToolCatalog(modules: [AnyGlacierToolModule(TextTrimModule())])
    var settings = GlacierSettings()
    settings.modules["text.trim"] = GlacierModuleSettings(enabled: false)
    let typed = catalog.resolveTyped("trm", settings: settings)
    let slash = catalog.resolveSlash("/trim text", settings: settings)
    #expect(typed.resolution.status == .disabledModule)
    #expect(slash.resolution.status == .disabledModule)
    #expect(typed.module?.descriptor.id == nil)
    #expect(slash.module?.descriptor.id == nil)
    #expect(catalog.registry.descriptor(for: "tool.text.trim") != nil)
}

@Test func extensionCannotClaimExistingActionOrAlias() throws {
    let example = AnyGlacierToolModule(TextTrimModule())
    #expect(throws: ModuleRegistryError.duplicateID("tool.text.trim")) {
        try ModuleRegistry(descriptors: ModuleRegistry.builtInDescriptors + [example.descriptor, example.descriptor])
    }
    #expect(throws: ModuleRegistryError.duplicateID("tool.text.trim")) {
        try GlacierToolCatalog(modules: [example, example])
    }
}

@Test func producerEnforcesInputLimit() async throws {
    let module = AnyGlacierToolModule(TextTrimModule())
    await #expect(throws: GlacierToolError.inputTooLong) {
        try await module.run(input: .init(text: String(repeating: "a", count: 4_097)))
    }
}
