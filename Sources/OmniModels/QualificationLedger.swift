import Foundation
import OmniCore

/// Durable command-specific qualification evidence for a support root. Entries
/// bind to the exact profile material; a changed selector or option leaves the
/// evidence in place but no longer covering the effective profile.
public struct ModelQualificationLedger: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let entries: [ModelQualification]

    public init(entries: [ModelQualification] = []) {
        schemaVersion = Self.schemaVersion
        self.entries = entries
    }

    public static func load(_ url: URL) throws -> ModelQualificationLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return ModelQualificationLedger() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(ModelQualificationLedger.self, from: data)
        guard ledger.schemaVersion == Self.schemaVersion else {
            throw ModelProviderRegistryError.invalidSettings("qualification ledger schema \(ledger.schemaVersion) is unsupported")
        }
        return ledger
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Adds or replaces the entry for one command/profile binding.
    public func recording(_ qualification: ModelQualification) -> ModelQualificationLedger {
        var kept = entries.filter { !($0.commandID == qualification.commandID && $0.profileID == qualification.profileID && $0.qualificationBinding == qualification.qualificationBinding) }
        kept.append(qualification)
        return ModelQualificationLedger(entries: kept.sorted { ($0.commandID, $0.profileID) < ($1.commandID, $1.profileID) })
    }
}
