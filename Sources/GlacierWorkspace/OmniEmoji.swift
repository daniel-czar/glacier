import Foundation
import OmniAdapters
import OmniCore
import OmniModels
import OmniPresentation
import OmniRun

/// Composes the Emoji tool: the bundled corpus, the frequent-set table (its
/// only stored state, under the environment's own root) and `emoji.suggest`.
public enum OmniEmoji {
    @MainActor
    public static func makeSession(environment: GlacierWorkspaceEnvironment, preferences: OmniPreferencesStore? = nil) -> OmniEmojiSession {
        let corpus = try? EmojiCorpus.shared.get()
        let store = frequencyStore(environment: environment)
        let table = FrequencyBox(store?.load() ?? EmojiFrequency())
        let runtime = environment.providerRuntime
        return OmniEmojiSession(
            corpus: corpus,
            skinTone: preferences?.current.skinTone ?? .none,
            initialNotice: corpus == nil ? "Emoji names are unavailable in this build." : nil,
            frequentSet: { corpus.map { table.value.frequentSet(in: $0, at: Date()) } ?? [] },
            record: { entry in
                table.value.record(entry.emoji, at: Date())
                // A few hundred bytes; ordered writes matter more than the main thread here.
                try? store?.save(table.value)
            },
            automaticRequestsEnabled: { environment.automaticRequestsEnabled("tool.emoji") },
            suggest: { description in
                guard let runtime, let corpus else { throw EphemeralToolFailure("Emoji suggestions need a configured language provider.") }
                do {
                    return try await EmojiSuggestionGenerator.generate(
                        description: description, corpus: corpus, broker: runtime,
                        runID: "ephemeral-emoji-" + UUID().uuidString.lowercased(),
                        profileID: environment.profileID("emoji.suggest") ?? preferences?.current.ephemeralProfileID ?? ProviderRuntimeCatalog.cerebrasFastProfileID
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Remote errors may echo the description. Never show their text.
                    throw EphemeralToolFailure("The selected provider could not suggest emoji.")
                }
            }
        )
    }

    /// `<root>/emoji/frequent.json`; nil when the root cannot hold it.
    static func frequencyStore(environment: GlacierWorkspaceEnvironment) -> EmojiFrequencyStore? {
        guard let root = try? OmniDevelopmentRoot(validating: environment.configuration.developmentRoot,
                                                  allowedRoot: environment.configuration.allowedRoot),
              let url = try? root.containedURL(relativePath: "emoji/frequent.json") else { return nil }
        return EmojiFrequencyStore(url: url)
    }
}

@MainActor private final class FrequencyBox {
    var value: EmojiFrequency
    init(_ value: EmojiFrequency) { self.value = value }
}
