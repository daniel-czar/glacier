import Foundation
import OmniAdapters
import OmniCore
import OmniPresentation
import OmniRun

/// Offline composition. A future suggestion adapter can use the session's
/// narrow seam; v1 captures no provider runtime and constructs no request.
public enum OmniCharacters {
    @MainActor
    public static func makeSession(environment: GlacierWorkspaceEnvironment) -> OmniCharactersSession {
        let corpus = try? CharacterCorpus.shared.get()
        let store = frequencyStore(environment: environment)
        let table = CharacterFrequencyBox(store?.load() ?? EmojiFrequency())
        return OmniCharactersSession(
            corpus: corpus,
            initialNotice: corpus == nil ? "Character names are unavailable in this build." : nil,
            frequentSet: {
                guard let corpus else { return [] }
                let ranked = table.value.ranked(at: Date())
                let seeds = ["↑", "→", "↓", "←", "°", "±", "×", "÷", "≤", "≥", "≠", "≈", "∞", "α", "β", "π", "µ", "©", "®", "♥"]
                var seen = Set<UInt32>()
                return Array((ranked + seeds).compactMap { glyph -> CharacterEntry? in
                    guard let scalar = glyph.unicodeScalars.first?.value, let entry = corpus.entry(for: scalar),
                          seen.insert(scalar).inserted else { return nil }
                    return entry
                }.prefix(EmojiFrequency.setSize))
            },
            record: { entry in
                table.value.record(entry.glyph, at: Date())
                try? store?.save(table.value)
            }
        )
    }

    /// Same decaying count-table shape as Emoji, with an independent file.
    static func frequencyStore(environment: GlacierWorkspaceEnvironment) -> EmojiFrequencyStore? {
        guard let root = try? OmniDevelopmentRoot(validating: environment.configuration.developmentRoot,
                                                  allowedRoot: environment.configuration.allowedRoot),
              let url = try? root.containedURL(relativePath: "characters/frequent.json") else { return nil }
        return EmojiFrequencyStore(url: url)
    }
}

@MainActor private final class CharacterFrequencyBox {
    var value: EmojiFrequency
    init(_ value: EmojiFrequency) { self.value = value }
}
