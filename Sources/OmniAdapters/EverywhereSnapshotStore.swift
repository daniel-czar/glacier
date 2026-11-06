import Foundation
import OmniCore

/// A separate atomic snapshot beside the curated launcher's snapshot.
public struct FileEverywhereSnapshotStore: EverywhereSnapshotStoring {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("everywhere-index-snapshot.json")
    }

    public func load() throws -> EverywhereSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(EverywhereSnapshot.self, from: Data(contentsOf: url))
        return snapshot.schemaVersion == EverywhereSnapshot.schemaVersion ? snapshot : nil
    }

    public func save(_ snapshot: EverywhereSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(snapshot).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
