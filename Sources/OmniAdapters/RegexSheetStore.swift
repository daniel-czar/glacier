import Darwin
import Foundation
import OmniCore

public enum RegexSheetStoreError: Error, CustomStringConvertible {
    case malformedSheet
    case invalidEntry
    case changedSinceAdd
    case sourceChanged

    public var description: String {
        switch self {
        case .malformedSheet: "The regex sheet is not an array of valid pattern rows"
        case .invalidEntry: "A sheet entry needs a name and a valid ICU pattern"
        case .changedSinceAdd: "The saved pattern changed since it was added; undo left it in place"
        case .sourceChanged: "The regex sheet changed while the update was prepared; no change was applied"
        }
    }
}

/// A separate JSON sheet with Recall's row shape. Creation seeds six useful
/// patterns only when the file does not exist; a malformed existing file is
/// reported to the UI and is never replaced.
public final class RegexSheetStore: @unchecked Sendable {
    public static var production: RegexSheetStore {
        RegexSheetStore(url: OmniLayout.installedRoot.appendingPathComponent("regex-sheet.json"))
    }

    public static let defaults: [RegexSheetEntry] = [
        .init(name: "Email", pattern: #"(?i)^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, note: "Common address shape", intentAliases: ["email address", "email addresses"]),
        .init(name: "URL", pattern: #"^https?://[^\s]+$"#, note: "HTTP or HTTPS URL", intentAliases: ["web address", "http url"]),
        .init(name: "ISO date", pattern: #"^\d{4}-\d{2}-\d{2}$"#, note: "YYYY-MM-DD shape", intentAliases: ["date iso", "iso 8601 date"]),
        .init(name: "IPv4", pattern: #"^(?:(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)$"#, note: "Four octets, 0–255", intentAliases: ["ip address", "ipv4 address"]),
        .init(name: "UUID", pattern: #"(?i)^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$"#, note: "Hyphenated UUID shape", intentAliases: ["guid"]),
        .init(name: "Hex colour", pattern: #"(?i)^#(?:[0-9a-f]{3}|[0-9a-f]{6})$"#, note: "Three or six hex digits", intentAliases: ["hex color", "css colour", "css color"]),
    ]

    public let url: URL
    private static let sourceLock = NSLock()
    private var lastChange: Undo?

    private enum Undo {
        case inserted(id: String, snapshot: Data)
        case alias(id: String, previous: [String], hadID: Bool, snapshot: Data)
    }

    public init(url: URL) { self.url = url }

    public func load() throws -> [RegexSheetEntry] {
        try Self.sourceLock.withLock {
            try ensureSeeded()
            return try readSheet().rows.map(Self.entry)
        }
    }

    /// An existing pattern receives a new intent alias; no duplicate row is
    /// written. The whole transaction is locked across store instances.
    @discardableResult
    public func add(_ entry: RegexSheetEntry, intent: String) throws -> Bool {
        try Self.sourceLock.withLock {
            try ensureSeeded()
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = entry.pattern
            guard !name.isEmpty, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (try? NSRegularExpression(pattern: pattern)) != nil else { throw RegexSheetStoreError.invalidEntry }
            let sheet = try readSheet()
            var rows = sheet.rows
            let normalizedIntent = intent.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = rows.firstIndex(where: { ($0["command"] as? String) == pattern }) {
                let previous = rows[index]["regex_intents"] as? [String] ?? []
                guard !normalizedIntent.isEmpty,
                      !previous.contains(where: { $0.caseInsensitiveCompare(normalizedIntent) == .orderedSame })
                else { return false }
                let hadID = rows[index]["regex_id"] != nil
                let id = (rows[index]["regex_id"] as? String) ?? UUID().uuidString.lowercased()
                rows[index]["regex_id"] = id
                rows[index]["regex_intents"] = previous + [normalizedIntent]
                let snapshot = try Self.snapshot(rows[index])
                try write(rows, expectedSource: sheet.data)
                lastChange = .alias(id: id, previous: previous, hadID: hadID, snapshot: snapshot)
                return true
            }
            let id = UUID().uuidString.lowercased()
            var row: [String: Any] = ["category": "regex", "title": name, "command": pattern, "note": entry.note, "regex_id": id]
            let aliases = (entry.intentAliases + [normalizedIntent]).filter { !$0.isEmpty }
            if !aliases.isEmpty { row["regex_intents"] = Array(NSOrderedSet(array: aliases)) }
            rows.append(row)
            let snapshot = try Self.snapshot(row)
            try write(rows, expectedSource: sheet.data)
            lastChange = .inserted(id: id, snapshot: snapshot)
            return true
        }
    }

    /// Undo changes only the preceding Add. Unrelated external row edits stay.
    @discardableResult
    public func undoLastAdd() throws -> Bool {
        try Self.sourceLock.withLock {
            guard let change = lastChange else { return false }
            let sheet = try readSheet()
            var rows = sheet.rows
            let id: String
            let snapshot: Data
            switch change {
            case .inserted(let value, let data), .alias(let value, _, _, let data):
                id = value
                snapshot = data
            }
            guard let index = rows.firstIndex(where: { ($0["regex_id"] as? String) == id }) else {
                lastChange = nil
                return false
            }
            guard try Self.snapshot(rows[index]) == snapshot else { throw RegexSheetStoreError.changedSinceAdd }
            switch change {
            case .inserted:
                rows.remove(at: index)
            case .alias(_, let previous, let hadID, _):
                if previous.isEmpty { rows[index].removeValue(forKey: "regex_intents") }
                else { rows[index]["regex_intents"] = previous }
                if !hadID { rows[index].removeValue(forKey: "regex_id") }
            }
            try write(rows, expectedSource: sheet.data)
            lastChange = nil
            return true
        }
    }

    private func ensureSeeded() throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let rows = Self.defaults.map { entry -> [String: Any] in
            ["category": "regex", "title": entry.name, "command": entry.pattern, "note": entry.note, "regex_intents": entry.intentAliases]
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A fully written sibling is linked into place only if no file exists.
        // This avoids exposing a partly seeded sheet to another process.
        let staged = url.deletingLastPathComponent().appendingPathComponent(".regex-sheet-\(UUID().uuidString).json")
        try data.write(to: staged, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        defer { try? FileManager.default.removeItem(at: staged) }
        guard link(staged.path, url.path) == 0 else {
            if errno == EEXIST { return }
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func readSheet() throws -> (data: Data, rows: [[String: Any]]) {
        let data = try Data(contentsOf: url)
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.allSatisfy({ (try? Self.entry($0)) != nil })
        else { throw RegexSheetStoreError.malformedSheet }
        return (data, rows)
    }

    private static func entry(_ row: [String: Any]) throws -> RegexSheetEntry {
        guard let name = row["title"] as? String,
              let pattern = row["command"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? NSRegularExpression(pattern: pattern)) != nil,
              let note = row["note"] as? String,
              (row["category"] as? String) == "regex"
        else { throw RegexSheetStoreError.malformedSheet }
        if row["regex_intents"] != nil, row["regex_intents"] as? [String] == nil {
            throw RegexSheetStoreError.malformedSheet
        }
        if row["regex_id"] != nil, row["regex_id"] as? String == nil {
            throw RegexSheetStoreError.malformedSheet
        }
        let aliases = row["regex_intents"] as? [String] ?? []
        return RegexSheetEntry(name: name, pattern: pattern, note: note, intentAliases: aliases)
    }

    private static func snapshot(_ row: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .fragmentsAllowed])
    }

    private func write(_ rows: [[String: Any]], expectedSource original: Data) throws {
        guard try Data(contentsOf: url) == original else { throw RegexSheetStoreError.sourceChanged }
        let updated = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        try updated.write(to: url, options: .atomic)
    }
}
