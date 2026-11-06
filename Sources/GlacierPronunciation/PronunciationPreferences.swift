import Foundation
import GlacierConnections

public enum PronunciationAccent: String, Codable, Sendable, CaseIterable {
    case us
    case uk
}

public enum PronunciationKeyProvider: String, Codable, Sendable, CaseIterable {
    case forvo
    case merriamWebster = "mw"
}

/// Only app preferences and opaque Keychain account IDs are persisted here.
public struct PronunciationPreferences: Codable, Sendable, Equatable {
    public var version = 1
    public var accent: PronunciationAccent = .us
    public var voice: String?
    public var ukVoice: String?
    public var wikimediaContact: String?
    public var forvoAccount: UUID?
    public var merriamWebsterAccount: UUID?

    public init() {}

    public func account(for provider: PronunciationKeyProvider) -> UUID? {
        switch provider {
        case .forvo: forvoAccount
        case .merriamWebster: merriamWebsterAccount
        }
    }

    mutating func setAccount(_ account: UUID?, for provider: PronunciationKeyProvider) {
        switch provider {
        case .forvo: forvoAccount = account
        case .merriamWebster: merriamWebsterAccount = account
        }
    }
}

public enum PronunciationSettingsError: Error, Sendable {
    case invalidLocation
    case invalidPreferences
    case invalidValue
    case credentialUnavailable
}

/// Owns a nonsecret JSON document and exact Keychain items in Glacier's
/// independent service. No key is written to disk, argv, or environment.
public actor PronunciationSettingsStore {
    private let fileURL: URL
    private let secrets: any SecretStore
    private var saved: PronunciationPreferences

    public init(directory: URL, secrets: any SecretStore = GlacierKeychainSecretStore()) throws {
        let file = directory.appendingPathComponent("preferences.json")
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              directory.standardizedFileURL == directory.resolvingSymlinksInPath(),
              file.standardizedFileURL == file.resolvingSymlinksInPath() else {
            throw PronunciationSettingsError.invalidLocation
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        fileURL = file
        self.secrets = secrets
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file), data.count <= 16_384,
                  let value = try? JSONDecoder().decode(PronunciationPreferences.self, from: data),
                  Self.validStored(value) else { throw PronunciationSettingsError.invalidPreferences }
            saved = value
        } else {
            saved = PronunciationPreferences()
        }
    }

    public func preferences() -> PronunciationPreferences { saved }

    public func updateAccent(_ accent: PronunciationAccent) throws {
        var next = saved
        next.accent = accent
        try persist(next)
    }

    public func updateVoice(_ voice: String?, accent: PronunciationAccent = .us) throws {
        let value = try Self.cleaned(voice, maxLength: 100)
        var next = saved
        if accent == .uk { next.ukVoice = value } else { next.voice = value }
        try persist(next)
    }

    public func updateWikimediaContact(_ contact: String?) throws {
        let value = try Self.cleaned(contact, maxLength: 256)
        guard Self.validContact(value) else { throw PronunciationSettingsError.invalidValue }
        var next = saved
        next.wikimediaContact = value
        try persist(next)
    }

    public func saveKey(provider: PronunciationKeyProvider, key: String) throws {
        let value = try Self.cleaned(key, maxLength: 4_096)
        guard let value else { throw PronunciationSettingsError.invalidValue }
        let account = UUID()
        do { try secrets.insert(value, account: account) }
        catch { throw PronunciationSettingsError.credentialUnavailable }
        let previous = saved.account(for: provider)
        var next = saved
        next.setAccount(account, for: provider)
        do { try persist(next) }
        catch {
            try? secrets.remove(account: account)
            throw error
        }
        if let previous { try? secrets.remove(account: previous) }
    }

    public func clearKey(provider: PronunciationKeyProvider) throws {
        guard let account = saved.account(for: provider) else { return }
        do { try secrets.remove(account: account) }
        catch { throw PronunciationSettingsError.credentialUnavailable }
        var next = saved
        next.setAccount(nil, for: provider)
        try persist(next)
    }

    /// Resolved secrets exist only in this transient request and are consumed
    /// by the owned helper through stdin. Offline skips Keychain reads entirely.
    public func requestPayload(term: String, offline: Bool) throws -> Data {
        let forvo: String?
        let mw: String?
        if offline {
            forvo = nil
            mw = nil
        } else {
            do {
                forvo = try saved.forvoAccount.map { try secrets.read(account: $0) }
                mw = try saved.merriamWebsterAccount.map { try secrets.read(account: $0) }
            } catch { throw PronunciationSettingsError.credentialUnavailable }
        }
        let request = PronunciationHelperRequest(
            term: term, offline: offline, accent: saved.accent,
            voice: saved.voice, ukVoice: saved.ukVoice,
            wikimediaUserAgent: offline ? nil : saved.wikimediaContact.map { "Glacier/0.1 contact=\($0)" },
            forvoKey: forvo, mwKey: mw
        )
        return try JSONEncoder().encode(request)
    }

    private func persist(_ next: PronunciationPreferences) throws {
        let data = try JSONEncoder().encode(next)
        guard data.count <= 16_384, fileURL.standardizedFileURL == fileURL.resolvingSymlinksInPath() else {
            throw PronunciationSettingsError.invalidLocation
        }
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        saved = next
    }

    private static func cleaned(_ value: String?, maxLength: Int) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.utf8.count <= maxLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PronunciationSettingsError.invalidValue
        }
        return trimmed
    }

    private static func validContact(_ contact: String?) -> Bool {
        guard let contact else { return true }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~:/@+%=-")
        return contact.unicodeScalars.allSatisfy(allowed.contains)
            && (contact.contains("@") || contact.hasPrefix("https://"))
    }

    private static func validStored(_ value: PronunciationPreferences) -> Bool {
        guard value.version == 1,
              (value.forvoAccount == nil || value.merriamWebsterAccount == nil
               || value.forvoAccount != value.merriamWebsterAccount) else { return false }
        do {
            let voice = try cleaned(value.voice, maxLength: 100)
            let ukVoice = try cleaned(value.ukVoice, maxLength: 100)
            let contact = try cleaned(value.wikimediaContact, maxLength: 256)
            return voice == value.voice && ukVoice == value.ukVoice
                && contact == value.wikimediaContact
                && validContact(value.wikimediaContact)
        } catch { return false }
    }
}

private struct PronunciationHelperRequest: Encodable {
    let term: String
    let offline: Bool
    let accent: PronunciationAccent
    let voice: String?
    let ukVoice: String?
    let wikimediaUserAgent: String?
    let forvoKey: String?
    let mwKey: String?

    enum CodingKeys: String, CodingKey {
        case term, offline, accent, voice
        case ukVoice = "uk_voice"
        case wikimediaUserAgent = "wikimedia_user_agent"
        case forvoKey = "forvo_key"
        case mwKey = "mw_key"
    }
}
