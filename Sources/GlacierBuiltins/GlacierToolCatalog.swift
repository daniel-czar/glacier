import Foundation
import GlacierConfiguration
import GlacierModuleKit
import OmniPresentation

public struct GlacierToolMatch: Sendable {
    public let resolution: ModuleResolution
    /// Present only when the route is effectively available.
    public let module: AnyGlacierToolModule?
    /// The literal payload after a slash token, or empty for a whole-field Tab alias.
    public let payload: String
}

/// A fork registers modules here, then passes the catalogue into app composition.
/// The core registry still owns enablement and alias conflict checks.
public struct GlacierToolCatalog: Sendable {
    public let modules: [AnyGlacierToolModule]
    public let registry: ModuleRegistry
    private let byActionID: [String: AnyGlacierToolModule]

    public init(modules: [AnyGlacierToolModule]) throws {
        let registry = try ModuleRegistry(descriptors: modules.map(\.descriptor))
        var presentationIDs: Set<String> = []
        for module in modules {
            let action = module.descriptor
            guard action.kind == .ephemeralTool,
                  action.id.hasPrefix("tool."), action.id.count > 5,
                  action.moduleID.contains("."),
                  module.presentation.id == String(action.id.dropFirst(5)),
                  module.presentation.abbreviation == action.typedAliases.first,
                  presentationIDs.insert(module.presentation.id).inserted else {
                throw GlacierToolError.invalidDescriptor(action.id)
            }
        }
        self.registry = registry
        self.modules = modules
        self.byActionID = Dictionary(uniqueKeysWithValues: modules.map { ($0.descriptor.id, $0) })
    }

    /// These are the aliases actually registered in ModuleKit, not a parallel hint list.
    public var quickLaunchDescriptors: [OmniQuickLaunch] {
        modules.flatMap { module in
            module.descriptor.typedAliases.map {
                OmniQuickLaunch(letters: $0, title: module.presentation.abbreviationTitle,
                                toolID: module.presentation.id)
            }
        }
    }

    /// Tab requires an exact whole-field alias. Enter semantics remain with the host.
    public func resolveTyped(_ text: String, settings: GlacierSettings,
                             unavailable: [String: String] = [:]) -> GlacierToolMatch {
        match(registry.resolveTyped(text, settings: settings, unavailable: unavailable), payload: "")
    }

    /// The slash token must lead the field; subsequent text becomes tool input.
    public func resolveSlash(_ text: String, settings: GlacierSettings,
                             unavailable: [String: String] = [:]) -> GlacierToolMatch {
        let leading = text.drop(while: \.isWhitespace)
        guard leading.hasPrefix("/") else {
            return match(.init(actionID: nil, status: .unknown), payload: "")
        }
        let token = String(leading.prefix { !$0.isWhitespace })
        let remainder = leading.dropFirst(token.count)
        let tail = String(remainder.first?.isWhitespace == true ? remainder.dropFirst() : remainder)
        return match(registry.resolveSlash(token, settings: settings, unavailable: unavailable),
                     payload: tail)
    }

    private func match(_ resolution: ModuleResolution, payload: String) -> GlacierToolMatch {
        let module = resolution.status == .available ? resolution.actionID.flatMap { byActionID[$0] } : nil
        return GlacierToolMatch(resolution: resolution, module: module, payload: payload)
    }
}
