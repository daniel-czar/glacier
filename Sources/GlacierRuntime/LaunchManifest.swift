import Foundation

/// Glacier's pinned-app list is independent of search, Rail and run history.
/// Lint rejects rows individually so a bad entry never disables valid apps.
public struct LaunchManifest: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let bundleID: String
        public let key: String?
        public init(bundleID: String, key: String? = nil) { self.bundleID = bundleID; self.key = key }
    }

    public let entries: [Entry]
    public let problems: [String]
    public var bundleIDs: [String] { entries.map(\.bundleID) }
    public var keyOverrides: [String: String] {
        Dictionary(entries.compactMap { entry in entry.key.map { (entry.bundleID, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    public init(entries: [Entry], problems: [String] = []) {
        self.entries = entries
        self.problems = problems
    }

    public static func decode(_ data: Data) throws -> LaunchManifest {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let document = root as? [String: Any] else {
            return .init(entries: [], problems: ["Manifest must be a JSON object with a launch list"])
        }
        guard let raw = document["launch"] else { return .init(entries: []) }
        guard let rows = raw as? [Any] else {
            return .init(entries: [], problems: ["launch must be an array of {bundleID} entries"])
        }
        var entries: [Entry] = []
        var problems: [String] = []
        var seenIDs = Set<String>()
        var seenKeys = Set<String>()
        for (offset, row) in rows.enumerated() {
            let fields = row as? [String: Any]
            let id = fields?["bundleID"] as? String
            let location = "launch[\(offset + 1)]\(id.map { " (\($0))" } ?? "")"
            guard offset < 8 else {
                problems.append("\(location): refused; Launch supports at most eight apps")
                continue
            }
            guard let id, !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines) else {
                problems.append("\(location): bundleID must be a nonempty bundle identifier without surrounding whitespace")
                continue
            }
            guard !seenIDs.contains(id) else {
                problems.append("\(location): duplicate bundleID; the first entry wins")
                continue
            }
            let key: String?
            if let rawKey = fields?["key"] {
                guard let value = rawKey as? String, value.utf8.count == 1,
                      let byte = value.uppercased().utf8.first, (65...90).contains(byte) else {
                    problems.append("\(location): key must be one letter A–Z")
                    continue
                }
                let normalized = value.uppercased()
                guard seenKeys.insert(normalized).inserted else {
                    problems.append("\(location): duplicate key \(normalized); the first entry wins")
                    continue
                }
                key = normalized
            } else { key = nil }
            seenIDs.insert(id)
            entries.append(.init(bundleID: id, key: key))
        }
        return .init(entries: entries, problems: problems)
    }

    public static func load(from url: URL) throws -> LaunchManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(entries: []) }
        return try decode(Data(contentsOf: url))
    }
}
