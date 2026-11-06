import Foundation

public enum GlacierConfigurationError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidPath(String)
    case invalidShortcut(String)
    case invalidLanguage(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Settings version \(version) is not supported by this build."
        case .invalidPath(let value): "Invalid location or configuration: \(value)"
        case .invalidShortcut(let reason): reason
        case .invalidLanguage(let reason): reason
        }
    }
}

public struct GlacierModuleSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Automatic provider calls require explicit connection setup and this opt-in.
    public var automaticRequests: Bool

    public init(enabled: Bool = true, automaticRequests: Bool = false) {
        self.enabled = enabled
        self.automaticRequests = automaticRequests
    }

    private enum CodingKeys: String, CodingKey { case enabled, automaticRequests }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.automaticRequests = try container.decodeIfPresent(Bool.self, forKey: .automaticRequests) ?? false
    }
}

public enum GlacierShortcutModifier: String, Codable, CaseIterable, Sendable {
    case command, option, control, shift
}

/// Physical key code plus modifiers. The display label is supplied by the keyboard-layout adapter.
public struct GlacierShortcutChord: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: [GlacierShortcutModifier]

    public init(keyCode: UInt16, modifiers: [GlacierShortcutModifier]) throws {
        guard keyCode <= 127, !modifiers.isEmpty,
              Set(modifiers).count == modifiers.count else {
            throw GlacierConfigurationError.invalidShortcut("Invalid key code or modifiers")
        }
        self.keyCode = keyCode
        self.modifiers = GlacierShortcutModifier.allCases.filter { modifiers.contains($0) }
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(keyCode: container.decode(UInt16.self, forKey: .keyCode),
                      modifiers: container.decode([GlacierShortcutModifier].self, forKey: .modifiers))
    }
}

public struct GlacierShortcutSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var chord: GlacierShortcutChord?

    public init(enabled: Bool = false, chord: GlacierShortcutChord? = nil) {
        self.enabled = enabled
        self.chord = chord
    }
}

public struct GlacierSourceRoot: Codable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var enabled: Bool
    public var recursive: Bool
    public var excludedNames: [String]
    public var includeSourceFiles: Bool
    public var includeHidden: Bool
    /// Runtime-only marker for implicit system app roots; user settings never encode it.
    public var applicationDiscoveryOnly: Bool
    public var bookmark: Data?

    public init(id: UUID = UUID(), path: String, enabled: Bool = true,
                recursive: Bool = true, excludedNames: [String] = [],
                includeSourceFiles: Bool = false, includeHidden: Bool = false,
                applicationDiscoveryOnly: Bool = false,
                bookmark: Data? = nil) {
        self.id = id
        self.path = path
        self.enabled = enabled
        self.recursive = recursive
        self.excludedNames = excludedNames
        self.includeSourceFiles = includeSourceFiles
        self.includeHidden = includeHidden
        self.applicationDiscoveryOnly = applicationDiscoveryOnly
        self.bookmark = bookmark
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, enabled, recursive, excludedNames, includeSourceFiles, includeHidden, bookmark
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        // Legacy v1 roots had no ID. Derive a stable ID from their path so reading
        // the same old file twice does not create different in-memory identities.
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? Self.legacyID(for: path)
        self.path = path
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? true
        self.excludedNames = try container.decodeIfPresent([String].self, forKey: .excludedNames) ?? []
        self.includeSourceFiles = try container.decodeIfPresent(Bool.self, forKey: .includeSourceFiles) ?? false
        self.includeHidden = try container.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? false
        self.applicationDiscoveryOnly = false
        self.bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
    }

    private static func legacyID(for path: String) -> UUID {
        // FNV-1a is sufficient for a migration identifier; no security property is assumed.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let tail = String(format: "%012llx", hash & 0xFFFF_FFFF_FFFF)
        return UUID(uuidString: "00000000-0000-4000-8000-\(tail)")!
    }
}

public struct GlacierRootSettings: Codable, Equatable, Sendable {
    /// Empty by default. Home requires an explicit user opt-in.
    public var sources: [GlacierSourceRoot]
    public var includeHome: Bool
    public var jumpToRoot: String?
    public var captureDirectory: String?
    public var linkDirectory: String?

    public init(sources: [GlacierSourceRoot] = [], includeHome: Bool = false,
                jumpToRoot: String? = nil, captureDirectory: String? = nil,
                linkDirectory: String? = nil) {
        self.sources = sources
        self.includeHome = includeHome
        self.jumpToRoot = jumpToRoot
        self.captureDirectory = captureDirectory
        self.linkDirectory = linkDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case sources, includeHome, jumpToRoot, captureDirectory, linkDirectory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sources = try container.decodeIfPresent([GlacierSourceRoot].self, forKey: .sources) ?? []
        self.includeHome = try container.decodeIfPresent(Bool.self, forKey: .includeHome) ?? false
        self.jumpToRoot = try container.decodeIfPresent(String.self, forKey: .jumpToRoot)
        self.captureDirectory = try container.decodeIfPresent(String.self, forKey: .captureDirectory)
        self.linkDirectory = try container.decodeIfPresent(String.self, forKey: .linkDirectory)
    }
}

public enum GlacierTerminalPreference: String, Codable, Sendable {
    case systemTerminal, ghostty
}

public struct GlacierTranslationSettings: Codable, Equatable, Sendable {
    public var sourceLanguage: String
    public var targetLanguage: String

    public init(sourceLanguage: String = "auto", targetLanguage: String = "en") {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public struct GlacierAISettings: Codable, Equatable, Sendable {
    public var paused: Bool
    public var offline: Bool

    public init(paused: Bool = false, offline: Bool = false) {
        self.paused = paused
        self.offline = offline
    }
}

public struct GlacierClipboardSettings: Codable, Equatable, Sendable {
    public var captureEnabled: Bool

    public init(captureEnabled: Bool = false) { self.captureEnabled = captureEnabled }
}

/// Schema v2. Missing v1 fields receive safe defaults; future versions are rejected.
public struct GlacierSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var modules: [String: GlacierModuleSettings]
    public var shortcuts: [String: GlacierShortcutSettings]
    public var roots: GlacierRootSettings
    public var terminal: GlacierTerminalPreference
    public var editorBundleID: String
    public var translation: GlacierTranslationSettings
    public var ai: GlacierAISettings
    public var clipboard: GlacierClipboardSettings

    public init(
        modules: [String: GlacierModuleSettings] = [:],
        shortcuts: [String: GlacierShortcutSettings] = [:],
        roots: GlacierRootSettings = .init(),
        terminal: GlacierTerminalPreference = .systemTerminal,
        editorBundleID: String = "com.apple.TextEdit",
        translation: GlacierTranslationSettings = .init(),
        ai: GlacierAISettings = .init(),
        clipboard: GlacierClipboardSettings = .init()
    ) {
        self.version = Self.currentVersion
        self.modules = modules.filter { $0.key != "rail" }
        self.shortcuts = shortcuts.filter { $0.key != "rail.switch" }
        self.roots = roots
        self.terminal = terminal
        self.editorBundleID = editorBundleID
        self.translation = translation
        self.ai = ai
        self.clipboard = clipboard
    }

    private enum CodingKeys: String, CodingKey {
        case version, modules, shortcuts, roots, terminal, editorBundleID, translation, ai, clipboard
    }

    private struct SettingName: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    /// Decode retained entries individually so even malformed retired Rail data
    /// cannot prevent an otherwise valid profile from opening.
    private static func decodeActive<Value: Decodable>(
        _ type: Value.Type, for key: CodingKeys, excluding retired: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String: Value] {
        if !container.contains(key) { return [:] }
        if try container.decodeNil(forKey: key) { return [:] }
        let entries = try container.nestedContainer(keyedBy: SettingName.self, forKey: key)
        var decoded: [String: Value] = [:]
        for name in entries.allKeys where name.stringValue != retired {
            decoded[name.stringValue] = try entries.decode(type, forKey: name)
        }
        return decoded
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentVersion).contains(storedVersion) else {
            throw GlacierConfigurationError.unsupportedVersion(storedVersion)
        }
        self.version = Self.currentVersion
        self.modules = try Self.decodeActive(GlacierModuleSettings.self, for: .modules, excluding: "rail", from: container)
        self.shortcuts = try Self.decodeActive(GlacierShortcutSettings.self, for: .shortcuts, excluding: "rail.switch", from: container)
        self.roots = try container.decodeIfPresent(GlacierRootSettings.self, forKey: .roots) ?? .init()
        self.terminal = try container.decodeIfPresent(GlacierTerminalPreference.self, forKey: .terminal) ?? .systemTerminal
        self.editorBundleID = try container.decodeIfPresent(String.self, forKey: .editorBundleID) ?? "com.apple.TextEdit"
        self.translation = try container.decodeIfPresent(GlacierTranslationSettings.self, forKey: .translation) ?? .init()
        self.ai = try container.decodeIfPresent(GlacierAISettings.self, forKey: .ai) ?? .init()
        self.clipboard = try container.decodeIfPresent(GlacierClipboardSettings.self, forKey: .clipboard) ?? .init()
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(modules.filter { $0.key != "rail" }, forKey: .modules)
        try container.encode(shortcuts.filter { $0.key != "rail.switch" }, forKey: .shortcuts)
        try container.encode(roots, forKey: .roots)
        try container.encode(terminal, forKey: .terminal)
        try container.encode(editorBundleID, forKey: .editorBundleID)
        try container.encode(translation, forKey: .translation)
        try container.encode(ai, forKey: .ai)
        try container.encode(clipboard, forKey: .clipboard)
    }

    public func validate() throws {
        guard !editorBundleID.isEmpty, editorBundleID.count <= 255,
              editorBundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw GlacierConfigurationError.invalidPath("Choose a valid editor app bundle identifier")
        }
        guard version == Self.currentVersion else { throw GlacierConfigurationError.unsupportedVersion(version) }
        for (id, shortcut) in shortcuts where shortcut.enabled && shortcut.chord == nil {
            throw GlacierConfigurationError.invalidShortcut("Enabled shortcut \(id) has no chord")
        }
        for root in roots.sources where !root.path.hasPrefix("/") || root.path == "/" ||
            URL(fileURLWithPath: root.path).standardizedFileURL.path != root.path {
            throw GlacierConfigurationError.invalidPath(root.path)
        }
        guard Set(roots.sources.map(\.id)).count == roots.sources.count else {
            throw GlacierConfigurationError.invalidPath("Duplicate source identifier")
        }
        let canonicalSources = roots.sources.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard Set(canonicalSources).count == canonicalSources.count else {
            throw GlacierConfigurationError.invalidPath("Duplicate canonical source path")
        }
        if let jump = roots.jumpToRoot, !jump.hasPrefix("/") || jump == "/" {
            throw GlacierConfigurationError.invalidPath(jump)
        }
        for path in [roots.captureDirectory, roots.linkDirectory].compactMap({ $0 })
            where !path.hasPrefix("/") || path == "/" {
            throw GlacierConfigurationError.invalidPath(path)
        }
        for root in roots.sources {
            for name in root.excludedNames where name.isEmpty || name == "." || name == ".." || name.contains("/") {
                throw GlacierConfigurationError.invalidPath(name)
            }
        }
        guard translation.sourceLanguage == "auto" || Self.validLanguage(translation.sourceLanguage),
              Self.validLanguage(translation.targetLanguage) else {
            throw GlacierConfigurationError.invalidLanguage("Use auto or a BCP-47 language code")
        }
    }

    private static func validLanguage(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy(\.isLetter) else { return false }
        return parts.dropFirst().allSatisfy { (2...8).contains($0.count) && $0.allSatisfy(\.isLetter) }
    }
}
