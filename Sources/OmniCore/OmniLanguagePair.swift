import Foundation

/// Express's selected primary and secondary output languages.
/// The same language may occupy both positions for rephrasing in one language.
public struct OmniLanguagePair: Codable, Sendable, Equatable {
    public struct Choice: Sendable, Equatable {
        public let code: String
        public let name: String

        public init(code: String, name: String) {
            self.code = code
            self.name = name
        }
    }

    public static let choices: [Choice] = [
        Choice(code: "en", name: "English"), Choice(code: "de", name: "German"),
        Choice(code: "fr", name: "French"), Choice(code: "es", name: "Spanish"),
        Choice(code: "it", name: "Italian"), Choice(code: "pt", name: "Portuguese"),
        Choice(code: "nl", name: "Dutch"), Choice(code: "pl", name: "Polish"),
        Choice(code: "cs", name: "Czech"), Choice(code: "sk", name: "Slovak"),
        Choice(code: "sv", name: "Swedish"), Choice(code: "da", name: "Danish"),
        Choice(code: "no", name: "Norwegian"), Choice(code: "fi", name: "Finnish"),
        Choice(code: "el", name: "Greek"), Choice(code: "hu", name: "Hungarian"),
        Choice(code: "ro", name: "Romanian"), Choice(code: "bg", name: "Bulgarian"),
        Choice(code: "hr", name: "Croatian"), Choice(code: "sr", name: "Serbian"),
        Choice(code: "sl", name: "Slovenian"), Choice(code: "ru", name: "Russian"),
        Choice(code: "uk", name: "Ukrainian"), Choice(code: "tr", name: "Turkish"),
        Choice(code: "ar", name: "Arabic"), Choice(code: "he", name: "Hebrew"),
        Choice(code: "fa", name: "Persian"), Choice(code: "hi", name: "Hindi"),
        Choice(code: "zh", name: "Chinese"), Choice(code: "ja", name: "Japanese"),
        Choice(code: "ko", name: "Korean"), Choice(code: "vi", name: "Vietnamese"),
        Choice(code: "th", name: "Thai"), Choice(code: "id", name: "Indonesian"),
        Choice(code: "ms", name: "Malay"),
    ]

    public let primary: String
    public let secondary: String
    public var primaryName: String { Self.name(for: primary) }
    public var secondaryName: String { Self.name(for: secondary) }

    public init(primary: String = "en", secondary: String = "de") {
        self.primary = Self.normalized(primary) ?? "en"
        self.secondary = Self.normalized(secondary) ?? "de"
    }

    public func withPrimary(_ code: String) -> Self { Self(primary: code, secondary: secondary) }
    public func withSecondary(_ code: String) -> Self { Self(primary: primary, secondary: code) }

    private static func normalized(_ code: String) -> String? {
        let candidate = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return choices.contains(where: { $0.code == candidate }) ? candidate : nil
    }

    private static func name(for code: String) -> String {
        choices.first(where: { $0.code == code })?.name ?? code
    }

    private enum CodingKeys: String, CodingKey { case primary, secondary }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            primary: (try? container.decode(String.self, forKey: .primary)) ?? "en",
            secondary: (try? container.decode(String.self, forKey: .secondary)) ?? "de"
        )
    }
}
