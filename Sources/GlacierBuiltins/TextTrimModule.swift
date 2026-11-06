import Foundation
import GlacierModuleKit
import OmniPresentation

/// Small, local contributor example. It is exported but never registered by default.
public struct TextTrimModule: GlacierToolModule {
    public init() {}

    public let descriptor = ModuleDescriptor(
        id: "tool.text.trim", moduleID: "text.trim", title: "Trim Text", kind: .ephemeralTool,
        typedAliases: ["trm"], slashTokens: ["/trim"]
    )

    public let presentation = OmniEphemeralToolDescriptor(
        id: "text.trim", title: "Trim Text", subtitle: "Remove surrounding whitespace",
        inputPlaceholder: "Type or paste text to trim", emptyResultHint: "The trimmed text appears here.",
        routeTitle: "Trim Text", routeProviderLabel: "On this Mac",
        maximumInputCharacters: 4_096, maximumOutputCharacters: 4_096,
        abbreviation: "trm"
    )

    public func run(input: GlacierToolInput) async throws -> String {
        input.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
