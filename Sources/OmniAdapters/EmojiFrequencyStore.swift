import Foundation
import OmniCore

/// The Emoji tool's frequent-set table on disk: bare emoji, a decaying count
/// and the last pick time. It is the only thing the tool stores; no queries,
/// results or clipboard contents are written.
public struct EmojiFrequencyStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// A missing or unreadable table is an empty one: the tool still works.
    public func load() -> EmojiFrequency {
        guard let data = try? Data(contentsOf: url) else { return EmojiFrequency() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(EmojiFrequency.self, from: data)) ?? EmojiFrequency()
    }

    public func save(_ table: EmojiFrequency) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(table).write(to: url, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
