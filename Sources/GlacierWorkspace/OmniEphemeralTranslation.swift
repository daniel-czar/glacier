import OmniCore
import OmniPresentation

/// Compatibility entry point for the original ephemeral translation surface.
/// New ephemeral tools share the catalog's provider and request pipeline.
public enum OmniEphemeralTranslation {
    public static var descriptor: OmniEphemeralToolDescriptor {
        OmniEphemeralToolKind.translation.descriptor
    }

    public static func producer(environment: GlacierWorkspaceEnvironment) -> OmniEphemeralProducer {
        OmniEphemeralTools.producer(for: .translation, environment: environment)
    }

    static func request(for text: String) throws -> ModelGenerationRequest {
        try OmniEphemeralTools.request(for: .translation, text: text)
    }
}
