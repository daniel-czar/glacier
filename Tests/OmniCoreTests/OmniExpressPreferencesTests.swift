import Foundation
import OmniCore
import Testing

@Test func expressPreferencesDefaultForOlderFilesAndRoundTrip() throws {
    let legacy = Data(#"{"schemaVersion":1,"appearance":"dark"}"#.utf8)
    let decoded = try JSONDecoder().decode(OmniPreferences.self, from: legacy)
    #expect(decoded.appearance == .dark)
    #expect(decoded.expressLanguages == OmniLanguagePair())
    #expect(decoded.expressOutputMode == .primary)

    let configured = OmniPreferences(expressLanguages: .init(primary: "fr", secondary: "it"),
                                     expressOutputMode: .paired)
    let restored = try JSONDecoder().decode(OmniPreferences.self, from: JSONEncoder().encode(configured))
    #expect(restored.expressLanguages == configured.expressLanguages)
    #expect(restored.expressOutputMode == .paired)
}

@Test func expressLanguagePairRejectsUnsupportedCodesWithoutLosingOtherChoice() throws {
    let pair = OmniLanguagePair(primary: "en", secondary: "de")
    #expect(pair.withPrimary(" FR ").primary == "fr")
    #expect(pair.withSecondary("xx").secondary == "de")
    let decoded = try JSONDecoder().decode(OmniLanguagePair.self,
                                           from: Data(#"{"primary":"invalid","secondary":"es"}"#.utf8))
    #expect(decoded.primary == "en")
    #expect(decoded.secondary == "es")
}
