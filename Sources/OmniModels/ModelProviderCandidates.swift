import Foundation
import OmniCore

/// Why a declared provider is intentionally unavailable. These reasons are
/// configuration facts, not a substitute for a runtime health probe.
public enum ModelProviderAvailabilityReason: String, Codable, Sendable, CaseIterable, Hashable {
    case explicitFiniteAuthorizationRequired
    case commandQualityEvidenceRequired
    case localSuitabilityUnproven
}

/// An inert provider declaration used by composition and settings surfaces.
/// It contains no credential source and cannot issue a request by itself.
public struct ModelProviderCandidateConfiguration: Sendable, Equatable {
    public let providerID: String
    public let providerClass: ModelProviderClass
    public let isRemote: Bool
    public let endpoint: URL?
    public let modelID: String?
    public let declaredCommandIDs: Set<String>
    public let availabilityReasons: Set<ModelProviderAvailabilityReason>

    public init(
        providerID: String,
        providerClass: ModelProviderClass,
        isRemote: Bool,
        endpoint: URL? = nil,
        modelID: String? = nil,
        declaredCommandIDs: Set<String>,
        availabilityReasons: Set<ModelProviderAvailabilityReason>
    ) {
        self.providerID = providerID
        self.providerClass = providerClass
        self.isRemote = isRemote
        self.endpoint = endpoint
        self.modelID = modelID
        self.declaredCommandIDs = declaredCommandIDs
        self.availabilityReasons = availabilityReasons
    }

    public var isAvailable: Bool { availabilityReasons.isEmpty }

    public func descriptor(qualityValidatedCommandIDs: Set<String> = []) -> ModelProviderDescriptor {
        ModelProviderDescriptor(
            providerID: providerID,
            providerClass: providerClass,
            isRemote: isRemote,
            isAvailable: isAvailable,
            qualityValidatedCommandIDs: qualityValidatedCommandIDs
        )
    }

    /// Only an explicitly authorized composition may use this descriptor to
    /// construct a real transport. Calling it does not grant authorization or
    /// qualify a command; those facts are supplied independently.
    public func activatedDescriptor(qualityValidatedCommandIDs: Set<String>) -> ModelProviderDescriptor {
        ModelProviderDescriptor(
            providerID: providerID,
            providerClass: providerClass,
            isRemote: isRemote,
            isAvailable: true,
            qualityValidatedCommandIDs: qualityValidatedCommandIDs
        )
    }
}

/// Historical policy 5.0.0 candidate identities, retained so older receipts
/// and the settings migration keep their original interpretation. Policy
/// 6.0.0 composition uses `ProviderRuntimeCatalog` and `ModelProviderRegistry`.
public enum Phase5ModelProviderMatrix {
    public static let cerebrasGemmaFast = ModelProviderCandidateConfiguration(
        providerID: "cerebras:gemma-4-31b:none",
        providerClass: .fastHosted,
        isRemote: true,
        endpoint: URL(string: "https://api.cerebras.ai/v1/chat/completions"),
        modelID: "gemma-4-31b",
        declaredCommandIDs: ["answer.quick", "translate"],
        availabilityReasons: [.explicitFiniteAuthorizationRequired, .commandQualityEvidenceRequired]
    )

    public static let chatGPTCodex = ModelProviderCandidateConfiguration(
        providerID: "codex-app-server:chatgpt",
        providerClass: .capableRemote,
        isRemote: true,
        modelID: nil,
        declaredCommandIDs: ["draft.email", "draft.message", "tier2.proposal"],
        availabilityReasons: [.explicitFiniteAuthorizationRequired, .commandQualityEvidenceRequired]
    )

    public static let observedQwenLocalFast = ModelProviderCandidateConfiguration(
        providerID: "ollama:qwen3:8b:local-fast",
        providerClass: .localFast,
        isRemote: false,
        endpoint: URL(string: "http://127.0.0.1:11434"),
        modelID: "qwen3:8b",
        declaredCommandIDs: ["answer.quick", "translate"],
        availabilityReasons: [.localSuitabilityUnproven, .commandQualityEvidenceRequired]
    )

    public static let observedQwenLocalCapable = ModelProviderCandidateConfiguration(
        providerID: "ollama:qwen3:8b:local-capable",
        providerClass: .localCapable,
        isRemote: false,
        endpoint: URL(string: "http://127.0.0.1:11434"),
        modelID: "qwen3:8b",
        declaredCommandIDs: ["draft.email", "draft.message", "tier2.proposal"],
        availabilityReasons: [.localSuitabilityUnproven, .commandQualityEvidenceRequired]
    )

    public static let candidates = [
        cerebrasGemmaFast,
        chatGPTCodex,
        observedQwenLocalFast,
        observedQwenLocalCapable,
    ]
}
