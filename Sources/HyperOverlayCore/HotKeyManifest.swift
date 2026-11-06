import Foundation

public enum HotKeyModifier: String, Codable, Sendable, CaseIterable {
    case command
    case option
    case control
    case shift
}

public struct HotKeyChord: Codable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: [HotKeyModifier]

    enum CodingKeys: String, CodingKey {
        case keyCode = "key_code"
        case modifiers
    }

    public init(keyCode: UInt32, modifiers: [HotKeyModifier]) {
        self.keyCode = keyCode
        self.modifiers = Self.canonicalModifiers(modifiers)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let modifiers = try container.decode([HotKeyModifier].self, forKey: .modifiers)

        try Self.validate(keyCode: keyCode, modifiers: modifiers)
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
    }

    private static func validate(keyCode: UInt32, modifiers: [HotKeyModifier]) throws {
        guard (0...127).contains(keyCode) else {
            throw HotKeyManifestValidationError.invalidKeyCode(keyCode)
        }
        guard !modifiers.isEmpty else {
            throw HotKeyManifestValidationError.emptyModifiers
        }
        guard Set(modifiers).count == modifiers.count else {
            throw HotKeyManifestValidationError.duplicateModifiers
        }
    }

    private static func canonicalModifiers(_ modifiers: [HotKeyModifier]) -> [HotKeyModifier] {
        HotKeyModifier.allCases.filter { modifiers.contains($0) }
    }
}

public struct OverlayHotKeyBinding: Equatable, Sendable {
    public let overlayID: String
    public let chord: HotKeyChord

    public init(overlayID: String, chord: HotKeyChord) {
        self.overlayID = overlayID
        self.chord = chord
    }
}

public enum HotKeyManifest {
    public static func load(from url: URL) throws -> [OverlayHotKeyBinding] {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> [OverlayHotKeyBinding] {
        let entries = try JSONDecoder().decode([ManifestEntry].self, from: data)
        var seenIDs: Set<String> = []
        var seenChords: Set<HotKeyChord> = []

        for entry in entries {
            guard seenIDs.insert(entry.id).inserted else {
                throw HotKeyManifestValidationError.duplicateOverlayID(entry.id)
            }
            // A retained disabled launcher may keep its former chord for rollback.
            // Only enabled bindings claim a key; re-enabling a collision still fails.
            guard !entry.nativeHotkey.enabled || seenChords.insert(entry.nativeHotkey.chord).inserted else {
                throw HotKeyManifestValidationError.duplicateChord(entry.nativeHotkey.chord)
            }
        }

        let entryIDs = Set(entries.map(\.id))
        guard entryIDs == OverlayID.hotkeyIDs else {
            throw HotKeyManifestValidationError.overlayParityMismatch
        }

        let nativeImplementedIDs = Set(entries.lazy.filter(\.nativeImplemented).map(\.id))
        guard nativeImplementedIDs == OverlayID.hotkeyIDs else {
            throw HotKeyManifestValidationError.nativeImplementationParityMismatch
        }

        return entries.compactMap { entry in
            guard entry.nativeHotkey.enabled else {
                return nil
            }
            return OverlayHotKeyBinding(overlayID: entry.id, chord: entry.nativeHotkey.chord)
        }
    }
}

private struct ManifestEntry: Decodable {
    let id: String
    let nativeImplemented: Bool
    let nativeHotkey: NativeHotkey

    enum CodingKeys: String, CodingKey {
        case id
        case nativeImplemented = "native_implemented"
        case nativeHotkey = "native_hotkey"
    }
}

private struct NativeHotkey: Decodable {
    let chord: HotKeyChord
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case keyCode = "key_code"
        case modifiers
        case enabled
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chord = try HotKeyChord(from: decoder)
        enabled = try container.decode(Bool.self, forKey: .enabled)
    }
}

private enum HotKeyManifestValidationError: Error {
    case invalidKeyCode(UInt32)
    case emptyModifiers
    case duplicateModifiers
    case duplicateOverlayID(String)
    case duplicateChord(HotKeyChord)
    case overlayParityMismatch
    case nativeImplementationParityMismatch
}
