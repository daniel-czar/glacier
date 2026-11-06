import Foundation
import HyperOverlayRuntime
import OmniAdapters
import OmniApplication
import OmniCore
import OmniModels
import OmniPresentation
import OmniRun

/// App-owned inputs to the native workspace. Composition and resource selection
/// live outside this target, so opening a window never discovers private data.
public struct GlacierWorkspaceConfiguration: Sendable {
    public let developmentRoot: URL
    public let allowedRoot: URL
    public let forbiddenRoots: [URL]
    public let recallSheet: URL
    public let regexSheet: URL
    public let pronunciationConfig: URL

    public init(root: URL, allowedRoot: URL, forbiddenRoots: [URL] = [],
                recallSheet: URL, regexSheet: URL, pronunciationConfig: URL) {
        developmentRoot = root
        self.allowedRoot = allowedRoot
        self.forbiddenRoots = forbiddenRoots
        self.recallSheet = recallSheet
        self.regexSheet = regexSheet
        self.pronunciationConfig = pronunciationConfig
    }
}

public protocol GlacierWorkspaceSettingsSaving: Sendable {
    @discardableResult
    func saveProviderSettings(_ candidate: ProviderRuntimeSettings) async throws -> RunID
}

public enum GlacierWorkspaceError: Error {
    case providerRuntimeUnavailable
}

public struct GlacierWorkspaceEnvironment: Sendable {
    public let configuration: GlacierWorkspaceConfiguration
    public let store: OmniRunStore
    public let service: OmniApplicationService
    public let modelGenerating: any ModelGenerating
    public let providerRuntime: ProviderRuntimeBrokerStore?
    public let platform: any RecordingPlatformActionPerforming
    public let settings: any GlacierWorkspaceSettingsSaving
    public let stashStack: OmniStashStack?
    public let findIndex: (any FindIndexProviding)?
    public let translationOptions: @Sendable () -> TranslationOptions
    public let profileID: @Sendable (String) -> String?
    public let automaticRequestsEnabled: @Sendable (String) -> Bool
    public let recallEnvironment: @Sendable () -> RecallEnvironment
    /// Returns a label only for an action whose global binding registered.
    public let shortcutLabel: @Sendable (String) -> String?
    public let remoteServicesEnabled: @Sendable () -> Bool
    public let isInstalled: Bool
    public let ownsStatusItem: Bool
    public let usesSampleReplies: Bool
    public var platformReachesTheOS: Bool { platform.mode == .live }

    public init(configuration: GlacierWorkspaceConfiguration, store: OmniRunStore,
                service: OmniApplicationService, modelGenerating: any ModelGenerating,
                providerRuntime: ProviderRuntimeBrokerStore?, platform: any RecordingPlatformActionPerforming,
                settings: any GlacierWorkspaceSettingsSaving, stashStack: OmniStashStack? = nil,
                findIndex: (any FindIndexProviding)? = nil, isInstalled: Bool = true,
                ownsStatusItem: Bool = true,
                usesSampleReplies: Bool = false,
                translationOptions: @escaping @Sendable () -> TranslationOptions = { .defaultToEnglish },
                profileID: @escaping @Sendable (String) -> String? = { _ in nil },
                automaticRequestsEnabled: @escaping @Sendable (String) -> Bool = { _ in true },
                shortcutLabel: @escaping @Sendable (String) -> String? = { _ in nil },
                remoteServicesEnabled: @escaping @Sendable () -> Bool = { true },
                recallEnvironment: @escaping @Sendable () -> RecallEnvironment = {
                    let version = ProcessInfo.processInfo.operatingSystemVersion
                    return RecallEnvironment(macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                                             availableTools: [])
                }) {
        self.configuration = configuration
        self.store = store
        self.service = service
        self.modelGenerating = modelGenerating
        self.providerRuntime = providerRuntime
        self.platform = platform
        self.settings = settings
        self.stashStack = stashStack
        self.findIndex = findIndex
        self.translationOptions = translationOptions
        self.profileID = profileID
        self.automaticRequestsEnabled = automaticRequestsEnabled
        self.shortcutLabel = shortcutLabel
        self.remoteServicesEnabled = remoteServicesEnabled
        self.recallEnvironment = recallEnvironment
        self.isInstalled = isInstalled
        self.ownsStatusItem = ownsStatusItem
        self.usesSampleReplies = usesSampleReplies
    }
}
