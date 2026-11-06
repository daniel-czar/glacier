import Foundation

// Settings window preferences (H20, C111–C116): the choices that have no
// owner of their own. Model routes stay in the provider settings document and
// clipboard capture and retention in the clipboard history manifest; this
// file holds the rest. Missing or unreadable fields take explicit defaults;
// Express's primary-language output is the new default behavior.

public enum OmniAppearance: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}

/// Return in Clipboard history and Stash: the copied flavours, or plain text.
/// ⇧↩ pastes plain text regardless.
public enum OmniPasteMode: String, Codable, Sendable, CaseIterable {
    case asCopied
    case plainText
}

/// Between items when Collect pastes a batch (O31).
public enum OmniBatchSeparator: String, Codable, Sendable, CaseIterable {
    case newLine
    case blankLine

    public var text: String { self == .newLine ? "\n" : "\n\n" }
}

/// Temperature and wind units in Weather. Follow system resolves from the
/// current locale when a reading is displayed, not when this value is saved.
public enum OmniWeatherUnits: String, Codable, Sendable, CaseIterable {
    case followSystem
    case metric
    case imperial
}

/// Express can rephrase in the primary language or translate between the pair.
public enum OmniExpressOutputMode: String, Codable, Sendable, CaseIterable {
    case primary
    case paired
}

/// The Fitzpatrick modifier Emoji applies to a toneable base emoji.
public enum OmniSkinTone: String, Codable, Sendable, CaseIterable {
    case none
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    public var modifier: Unicode.Scalar? {
        switch self {
        case .none: nil
        case .light: "\u{1F3FB}"
        case .mediumLight: "\u{1F3FC}"
        case .medium: "\u{1F3FD}"
        case .mediumDark: "\u{1F3FE}"
        case .dark: "\u{1F3FF}"
        }
    }

    /// `👍` → `👍🏽`. Only a single toneable scalar (with or without its
    /// emoji presentation selector) takes a tone; sequences and keycaps keep
    /// their default rendering rather than risk an invalid combination.
    public func apply(to emoji: String) -> String {
        guard let modifier else { return emoji }
        let scalars = emoji.unicodeScalars.filter { $0 != "\u{FE0F}" }
        guard scalars.count == 1, let base = scalars.first, base.properties.isEmojiModifierBase else { return emoji }
        return String(String.UnicodeScalarView([base, modifier]))
    }
}

public struct OmniPreferences: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var appearance: OmniAppearance
    /// One profile for the model-backed ephemeral tools (O34); nil keeps each
    /// tool's own pick (Translate's low-reasoning profile among them).
    public var ephemeralProfileID: String?
    public var pasteMode: OmniPasteMode
    public var batchSeparator: OmniBatchSeparator
    public var skinTone: OmniSkinTone
    public var weatherUnits: OmniWeatherUnits
    public var weatherUsesLocation: Bool = true
    /// Express languages are independent of Glacier's Translate source and target.
    public var expressLanguages: OmniLanguagePair
    public var expressOutputMode: OmniExpressOutputMode
    /// A command sheet chosen in Settings → Tools; nil is the built-in path.
    public var recallSheetPath: String?
    /// The pane Settings… reopens on.
    public var lastPane: String?

    public init(
        appearance: OmniAppearance = .system,
        ephemeralProfileID: String? = nil,
        pasteMode: OmniPasteMode = .asCopied,
        batchSeparator: OmniBatchSeparator = .newLine,
        skinTone: OmniSkinTone = .none,
        weatherUnits: OmniWeatherUnits = .followSystem,
        expressLanguages: OmniLanguagePair = OmniLanguagePair(),
        expressOutputMode: OmniExpressOutputMode = .primary,
        recallSheetPath: String? = nil,
        lastPane: String? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.appearance = appearance
        self.ephemeralProfileID = ephemeralProfileID
        self.pasteMode = pasteMode
        self.batchSeparator = batchSeparator
        self.skinTone = skinTone
        self.weatherUnits = weatherUnits
        self.expressLanguages = expressLanguages
        self.expressOutputMode = expressOutputMode
        self.recallSheetPath = recallSheetPath
        self.lastPane = lastPane
    }

    /// Unknown or missing fields take their defaults, so an older or newer
    /// file never loses the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OmniPreferences()
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? Self.schemaVersion
        appearance = (try? container.decode(OmniAppearance.self, forKey: .appearance)) ?? defaults.appearance
        ephemeralProfileID = try? container.decodeIfPresent(String.self, forKey: .ephemeralProfileID)
        pasteMode = (try? container.decode(OmniPasteMode.self, forKey: .pasteMode)) ?? defaults.pasteMode
        batchSeparator = (try? container.decode(OmniBatchSeparator.self, forKey: .batchSeparator)) ?? defaults.batchSeparator
        skinTone = (try? container.decode(OmniSkinTone.self, forKey: .skinTone)) ?? defaults.skinTone
        weatherUnits = (try? container.decode(OmniWeatherUnits.self, forKey: .weatherUnits)) ?? defaults.weatherUnits
        weatherUsesLocation = (try? container.decode(Bool.self, forKey: .weatherUsesLocation)) ?? true
        expressLanguages = (try? container.decode(OmniLanguagePair.self, forKey: .expressLanguages)) ?? defaults.expressLanguages
        expressOutputMode = (try? container.decode(OmniExpressOutputMode.self, forKey: .expressOutputMode)) ?? defaults.expressOutputMode
        recallSheetPath = try? container.decodeIfPresent(String.self, forKey: .recallSheetPath)
        lastPane = try? container.decodeIfPresent(String.self, forKey: .lastPane)
    }
}

/// `<root>/preferences/omni-preferences.json`, private to the user. Reads are
/// served from memory after the first load; each change is one atomic write.
public final class OmniPreferencesStore: @unchecked Sendable {
    public let url: URL?
    private let lock = NSLock()
    private var cached: OmniPreferences?

    /// A nil URL keeps preferences in memory only (tests, fixtures).
    public init(url: URL?) {
        self.url = url
    }

    public var current: OmniPreferences {
        lock.withLock {
            if let cached { return cached }
            let loaded = Self.read(url) ?? OmniPreferences()
            cached = loaded
            return loaded
        }
    }

    /// Applies `change` and writes the result; on a failed write the
    /// in-memory value is left as it was, so the caller can say so.
    @discardableResult
    public func update(_ change: (inout OmniPreferences) -> Void) throws -> OmniPreferences {
        try lock.withLock {
            var next = cached ?? Self.read(url) ?? OmniPreferences()
            change(&next)
            if let url { try Self.write(next, to: url) }
            cached = next
            return next
        }
    }

    private static func read(_ url: URL?) -> OmniPreferences? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OmniPreferences.self, from: data)
    }

    private static func write(_ preferences: OmniPreferences, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: url, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
