import Foundation

/// Direction for a translation request. `nil` source means detect the
/// predominant language from the supplied text, including mixed-language text.
public struct TranslationOptions: Codable, Sendable, Equatable {
    public let sourceLanguageCode: String?
    public let targetLanguageCode: String

    public init(sourceLanguageCode: String? = nil, targetLanguageCode: String = "en") {
        let source = sourceLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.sourceLanguageCode = source == "auto" || source == "" ? nil : source
        self.targetLanguageCode = targetLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static let defaultToEnglish = TranslationOptions()

    public var directionInstruction: String {
        let source = sourceLanguageCode.map { "The source language is \(Self.name(for: $0)) (\($0))." }
            ?? "Detect the predominant source language from the text. Borrowed words, names, code, and short quotations do not by themselves change the source language."
        return "\(source) Translate into \(Self.name(for: targetLanguageCode)) (\(targetLanguageCode)). If the text is already in the target language, preserve its meaning and wording instead of translating it into another language. Preserve code identifiers, names, numbers, URLs, and English fragments already suitable for the target language. Translate meaningful non-target-language fragments in mixed text."
    }

    private static func name(for code: String) -> String {
        let known = ["en": "English", "de": "German", "en-gb": "British English", "en-us": "American English"]
        if let name = known[code] { return name }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}
