import Darwin
import Foundation
import OmniCore

public enum RecallCorpusError: Error, CustomStringConvertible {
    case malformedSheet
    case invalidCommand
    case regenerationFailed(String)
    case changedSinceAdd
    case sourceChanged
    case invalidSeedPath

    public var description: String {
        switch self {
        case .malformedSheet: "The command sheet is not an array of command objects"
        case .invalidCommand: "A command needs a category, command and label"
        case .regenerationFailed(let message): "Could not regenerate the command sheet: \(message)"
        case .changedSinceAdd: "The added command changed since it was saved; undo left it in place"
        case .sourceChanged: "The command sheet changed while Recall prepared the update; no change was applied"
        case .invalidSeedPath: "Recall's built-in sheet path is not an app-owned regular file"
        }
    }
}

/// The existing Keyboard Maestro JSON remains Recall's source of truth. The
/// generated HTML is a document output. All writes use atomic replacement.
public final class RecallCorpusStore: @unchecked Sendable {
    public static var production: RecallCorpusStore {
        RecallCorpusStore(url: OmniLayout.homeDirectory.appendingPathComponent("Library/Application Support/Glacier/recall.json"))
    }

    public let url: URL
    public let builderScript: URL?
    /// Store instances belong to sessions, but the installed JSON is shared.
    /// Serialize the whole read/modify/render/commit transaction in process.
    private static let sourceLock = NSLock()
    private var lastChange: Undo?

    private enum Undo {
        case inserted(id: String, snapshot: Data)
        case alias(id: String, previous: [String], hadID: Bool, snapshot: Data)
    }

    public init(url: URL, builderScript: URL? = nil) {
        self.url = url
        self.builderScript = builderScript
    }

    /// Creates a small, copy-only sheet only at the caller's app-owned default
    /// path. O_EXCL prevents a race from overwriting an existing user sheet.
    /// A selected external sheet must never call this API.
    @discardableResult
    public static func seedIfMissing(at url: URL) throws -> Bool {
        let directory = url.deletingLastPathComponent()
        guard url.isFileURL, !url.lastPathComponent.isEmpty else { throw RecallCorpusError.invalidSeedPath }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw RecallCorpusError.invalidSeedPath }
        defer { _ = Darwin.close(directoryFD) }
        var existing = stat()
        if fstatat(directoryFD, url.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw RecallCorpusError.invalidSeedPath }
            return false
        }
        guard errno == ENOENT else { throw RecallCorpusError.invalidSeedPath }
        let rows: [[String: Any]] = [
            ["category": "Folders", "title": "Show current folder", "command": "pwd",
             "note": "Print the working directory", "recall_intents": ["where am I", "current folder"]],
            ["category": "Git", "title": "See changed files", "command": "git status --short",
             "note": "List changed and untracked files", "recall_intents": ["what changed", "git status"]],
            ["category": "Git", "title": "Read unstaged changes", "command": "git diff --",
             "note": "Show changes without writing files", "recall_intents": ["inspect changes", "git diff"]],
            ["category": "Files", "title": "List file names here", "command": "find . -maxdepth 1 -type f",
             "note": "List regular files in the current folder", "recall_intents": ["file names", "files here"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        let temporaryName = ".recall-seed-" + UUID().uuidString
        let descriptor = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RecallCorpusError.invalidSeedPath }
        defer { _ = unlinkat(directoryFD, temporaryName, 0) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard linkat(directoryFD, temporaryName, directoryFD, url.lastPathComponent, 0) == 0 else {
            if errno == EEXIST {
                guard fstatat(directoryFD, url.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0,
                      existing.st_mode & S_IFMT == S_IFREG else { throw RecallCorpusError.invalidSeedPath }
                return false
            }
            throw RecallCorpusError.invalidSeedPath
        }
        return true
    }

    public func load() throws -> [RecallCommand] {
        // Atomic replacement makes reads coherent without waiting for an in-flight
        // document build. Opening a new panel must never block on its predecessor.
        try readSheet().rows.compactMap(Self.command)
    }

    /// Returns false when the exact command and intent were already present.
    /// A duplicate command with a new intent gets only a new alias.
    @discardableResult
    public func add(_ command: RecallCommand, intent: String) throws -> Bool {
        try Self.sourceLock.withLock {
            let category = command.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let line = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = command.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty, !line.isEmpty, !label.isEmpty else { throw RecallCorpusError.invalidCommand }
            let sheet = try readSheet()
            var rows = sheet.rows
            let normalizedIntent = intent.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = rows.firstIndex(where: { (($0["command"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == line }) {
                let before = rows[index]["recall_intents"] as? [String] ?? []
                guard !normalizedIntent.isEmpty, !before.contains(where: { $0.caseInsensitiveCompare(normalizedIntent) == .orderedSame }) else { return false }
                let hadID = rows[index]["recall_id"] != nil
                let id = (rows[index]["recall_id"] as? String) ?? UUID().uuidString.lowercased()
                rows[index]["recall_id"] = id
                rows[index]["recall_intents"] = before + [normalizedIntent]
                let snapshot = try Self.snapshot(rows[index])
                try writeAndRegenerate(rows, expectedSource: sheet.data)
                lastChange = .alias(id: id, previous: before, hadID: hadID, snapshot: snapshot)
                return true
            }
            let id = UUID().uuidString.lowercased()
            var row: [String: Any] = [
                "category": category,
                "title": label,
                "command": line,
                "note": command.note,
                "recall_id": id,
            ]
            let aliases = (command.intentAliases + [normalizedIntent]).filter { !$0.isEmpty }
            if !aliases.isEmpty { row["recall_intents"] = Array(NSOrderedSet(array: aliases)) }
            if command.destructive { row["destructive"] = true }
            rows.append(row)
            let snapshot = try Self.snapshot(row)
            try writeAndRegenerate(rows, expectedSource: sheet.data)
            lastChange = .inserted(id: id, snapshot: snapshot)
            return true
        }
    }

    /// Removes only the row or alias written by the preceding Add. Other
    /// source edits survive. A changed saved row is left untouched.
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
            guard let index = rows.firstIndex(where: { ($0["recall_id"] as? String) == id }) else {
                lastChange = nil
                return false
            }
            guard try Self.snapshot(rows[index]) == snapshot else { throw RecallCorpusError.changedSinceAdd }
            switch change {
            case .inserted:
                rows.remove(at: index)
            case .alias(_, let previous, let hadID, _):
                if previous.isEmpty { rows[index].removeValue(forKey: "recall_intents") }
                else { rows[index]["recall_intents"] = previous }
                if !hadID { rows[index].removeValue(forKey: "recall_id") }
            }
            try writeAndRegenerate(rows, expectedSource: sheet.data)
            lastChange = nil
            return true
        }
    }

    private func readSheet() throws -> (data: Data, rows: [[String: Any]]) {
        let data = try Data(contentsOf: url)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw RecallCorpusError.malformedSheet }
        return (data, rows)
    }

    private static func command(_ row: [String: Any]) -> RecallCommand? {
        guard let category = row["category"] as? String,
              let line = row["command"] as? String,
              let label = (row["title"] as? String) ?? (row["label"] as? String),
              !category.isEmpty, !line.isEmpty, !label.isEmpty
        else { return nil }
        return RecallCommand(
            category: category,
            command: line,
            label: label,
            note: (row["note"] as? String) ?? "",
            destructive: (row["destructive"] as? Bool) ?? false,
            intentAliases: (row["recall_intents"] as? [String]) ?? []
        )
    }

    private static func snapshot(_ row: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .fragmentsAllowed])
    }

    private func writeAndRegenerate(_ rows: [[String: Any]], expectedSource original: Data) throws {
        let updated = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        guard let builderScript else {
            guard try Data(contentsOf: url) == original else { throw RecallCorpusError.sourceChanged }
            try updated.write(to: url, options: .atomic)
            return
        }
        // Render against a private copy first. A bad template or failed
        // builder leaves all three installed files untouched.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("omni-recall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staged) }
        let sourceRoot = builderScript.deletingLastPathComponent()
        for name in [builderScript.lastPathComponent, "command-reference-prompt.template.html", "command-reference-sheet.template.html"] {
            try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent(name), to: staged.appendingPathComponent(name))
        }
        try updated.write(to: staged.appendingPathComponent("command-reference.json"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [staged.appendingPathComponent(builderScript.lastPathComponent).path]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw RecallCorpusError.regenerationFailed("builder timed out")
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "builder exited \(process.terminationStatus)"
            throw RecallCorpusError.regenerationFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let names = ["command-reference-prompt.html", "command-reference-sheet.html"]
        let outputs = try names.map { try Data(contentsOf: staged.appendingPathComponent($0)) }
        guard try Data(contentsOf: url) == original else { throw RecallCorpusError.sourceChanged }
        let destinations = names.map { sourceRoot.appendingPathComponent($0) }
        let previous = destinations.map { try? Data(contentsOf: $0) }
        do {
            try updated.write(to: url, options: .atomic)
            for (destination, data) in zip(destinations, outputs) {
                try data.write(to: destination, options: .atomic)
            }
        } catch {
            // Restore only values written by this Add; never overwrite an
            // intervening edit from another tool.
            if (try? Data(contentsOf: url)) == updated { try? original.write(to: url, options: .atomic) }
            for index in destinations.indices where (try? Data(contentsOf: destinations[index])) == outputs[index] {
                if let prior = previous[index] { try? prior.write(to: destinations[index], options: .atomic) }
                else { try? FileManager.default.removeItem(at: destinations[index]) }
            }
            throw error
        }
    }
}
