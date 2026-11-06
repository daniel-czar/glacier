import Foundation

/// What copied or kept material looks like in a list (C85's kind cell). Detection is
/// deterministic and local; it only picks the cell and the font.
public enum OmniContentKind: String, Codable, Sendable, Equatable, CaseIterable {
    case text, code, link, image, file, colour

    /// Classifies stored material. Pasteboard types win over the text: an
    /// image or a file reference is that kind whatever string rides along.
    public static func classify(text: String, types: [String] = []) -> OmniContentKind {
        if types.contains(where: OmniStashRepresentation.isImageType) && text.isEmpty { return .image }
        if types.contains("public.file-url") { return .file }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return types.contains(where: OmniStashRepresentation.isImageType) ? .image : .text }
        if isColour(trimmed) { return .colour }
        if isLink(trimmed) { return .link }
        if isCode(trimmed) { return .code }
        return .text
    }

    static func isLink(_ text: String) -> Bool {
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: text), let scheme = url.scheme?.lowercased()
        else { return false }
        if ["http", "https"].contains(scheme) { return url.host?.isEmpty == false }
        return ["mailto", "tel", "file", "ftp", "ssh"].contains(scheme)
    }

    static func isColour(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.hasPrefix("#") {
            let digits = lowered.dropFirst()
            return [3, 4, 6, 8].contains(digits.count) && digits.allSatisfy(\.isHexDigit)
        }
        for prefix in ["rgb(", "rgba(", "hsl(", "hsla("] where lowered.hasPrefix(prefix) {
            return lowered.hasSuffix(")") && lowered.count < 48
        }
        return false
    }

    /// Code is recognised by shape, never by guessing a language: shell
    /// commands that start with a common tool, or text dense in syntax
    /// characters. A false negative only costs the monospaced font.
    static func isCode(_ text: String) -> Bool {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let leading = firstLine.split(separator: " ").first.map(String.init) ?? ""
        let tools: Set<String> = [
            "$", "git", "cd", "ls", "find", "grep", "rg", "sed", "awk", "cat", "echo", "curl", "ssh", "scp",
            "sudo", "brew", "npm", "npx", "pnpm", "yarn", "uv", "uvx", "pip", "python", "python3", "swift",
            "xcrun", "make", "docker", "kubectl", "rm", "cp", "mv", "mkdir", "chmod", "export", "open", "defaults",
            "launchctl", "jq", "ffmpeg", "tar", "zip", "unzip", "ps", "kill", "pkill", "cargo", "go", "node",
        ]
        if tools.contains(leading), firstLine.contains(" ") { return true }
        let syntax: Set<Character> = ["{", "}", ";", "(", ")", "[", "]", "=", "<", ">", "|", "&", "$", "\\", "`"]
        let count = text.filter { syntax.contains($0) }.count
        let words = max(1, text.split(whereSeparator: \.isWhitespace).count)
        return count >= 4 && Double(count) / Double(words) >= 0.5
    }
}

/// One pasteboard flavour kept beside the plain text (RTF, HTML, an image).
/// `Data` encodes as base64 in the store's JSON.
public struct OmniStashRepresentation: Codable, Sendable, Equatable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }

    public static func isImageType(_ type: String) -> Bool {
        ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif", "com.compuserve.gif", "public.image", "org.webmproject.webp"].contains(type)
    }
}

/// A stash entry: what was kept, what it looks like, where it came from and
/// when. `runID` is set only when a `/stash` run pushed it; it is the run
/// marker that receipts, retries and reconciliation look for.
public struct OmniStashEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public private(set) var text: String
    public private(set) var representations: [OmniStashRepresentation]
    public private(set) var kind: OmniContentKind
    public let source: String
    public let sourceBundleID: String?
    public let createdAt: Date
    public private(set) var editedAt: Date?
    public let runID: String?
    public private(set) var digest: String

    enum CodingKeys: String, CodingKey {
        case id, text, representations, kind, source
        case sourceBundleID = "source_bundle_id"
        case createdAt = "created_at"
        case editedAt = "edited_at"
        case runID = "run_id"
        case digest
    }

    public init(
        id: String = UUID().uuidString,
        text: String,
        representations: [OmniStashRepresentation] = [],
        kind: OmniContentKind? = nil,
        source: String,
        sourceBundleID: String? = nil,
        createdAt: Date = Date(),
        runID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.representations = representations
        self.kind = kind ?? OmniContentKind.classify(text: text, types: representations.map(\.type))
        self.source = source
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        editedAt = nil
        self.runID = runID
        digest = Self.digest(text)
    }

    /// A hand edit keeps only the text: rich flavours no longer describe it.
    public func edited(text newText: String, at date: Date = Date()) -> OmniStashEntry {
        var copy = self
        copy.text = newText
        copy.representations = []
        copy.kind = OmniContentKind.classify(text: newText)
        copy.editedAt = date
        copy.digest = Self.digest(newText)
        return copy
    }

    public var isEditable: Bool { kind != .image }
    public var byteCount: Int { text.utf8.count + representations.reduce(0) { $0 + $1.data.count } }

    /// FNV-1a, the same 64-bit digest the owner backends use for run markers.
    public static func digest(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }

    public var lineCount: Int { max(1, text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count) }
    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

public struct OmniStashPushOutcome: Sendable, Equatable {
    public let entry: OmniStashEntry
    /// The bottom entry a sixth push removed.
    public let dropped: OmniStashEntry?
    /// A retried `/stash` run found its own marker already on the stack.
    public let alreadyPresent: Bool
}

public enum OmniStashError: Error, Sendable, Equatable, CustomStringConvertible {
    case empty
    case tooLarge(Int)
    case corrupt(String)
    case readbackMismatch

    public var description: String {
        switch self {
        case .empty: "stash is empty"
        case .tooLarge(let bytes): "stash entry of \(bytes) bytes exceeds the bound"
        case .corrupt(let reason): "stash store is unreadable: \(reason)"
        case .readbackMismatch: "stash readback mismatch"
        }
    }
}

/// The stash: an ordered stack, top first, at most five deep (C92, O28). It
/// is scratch, not an archive: a sixth push drops the oldest. One JSON file
/// holds the whole stack, so every change is one atomic replace.
///
/// The owner backends (`/stash`), the `st` tool, the workspace row and
/// Clipboard's ⌘Y all write in the same process; every read-modify-write
/// holds one lock per file, and every change posts `didChange`.
public final class OmniStashStack: Sendable {
    public static let capacity = 5
    /// Clipboard keeps images up to 12 MiB; the stash takes what it can hold.
    public static let maximumEntryBytes = 16 * 1024 * 1024
    public static let didChange = Notification.Name("OmniStashStackDidChange")
    public static let schemaVersion = 2

    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    // MARK: Reads

    public func entries() throws -> [OmniStashEntry] {
        try Self.withLock(url) { try load() }
    }

    public func entry(at position: Int) throws -> OmniStashEntry? {
        let entries = try entries()
        guard position >= 1, position <= entries.count else { return nil }
        return entries[position - 1]
    }

    public func entry(runID: String) throws -> OmniStashEntry? {
        try entries().first { $0.runID == runID }
    }

    // MARK: Writes

    /// Pushes onto the top. A run's second push of its own marker is the
    /// same logical effect and changes nothing.
    @discardableResult
    public func push(_ entry: OmniStashEntry) throws -> OmniStashPushOutcome {
        guard !entry.text.isEmpty || !entry.representations.isEmpty else { throw OmniStashError.empty }
        guard entry.byteCount <= Self.maximumEntryBytes else { throw OmniStashError.tooLarge(entry.byteCount) }
        return try mutate { entries in
            if let runID = entry.runID, let existing = entries.first(where: { $0.runID == runID }) {
                return OmniStashPushOutcome(entry: existing, dropped: nil, alreadyPresent: true)
            }
            entries.insert(entry, at: 0)
            let dropped = entries.count > Self.capacity ? entries.removeLast() : nil
            return OmniStashPushOutcome(entry: entry, dropped: dropped, alreadyPresent: false)
        }
    }

    /// Removes one entry; returns it with the position it held (0-based), so
    /// an undo can put it back where it was.
    @discardableResult
    public func remove(id: String) throws -> (entry: OmniStashEntry, index: Int)? {
        try mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
            return (entries.remove(at: index), index)
        }
    }

    /// Puts an entry back at a 0-based index (undo of drop or clear). Refuses
    /// rather than evicting when the stack has filled since: an undo never
    /// silently costs another entry.
    @discardableResult
    public func restore(_ entry: OmniStashEntry, at index: Int) throws -> Bool {
        try mutate { entries in
            guard !entries.contains(where: { $0.id == entry.id }) else { return true }
            guard entries.count < Self.capacity else { return false }
            entries.insert(entry, at: min(max(0, index), entries.count))
            return true
        }
    }

    /// Undo of a clear: entries pushed since stay on top, the cleared ones
    /// return beneath them in their order, and what no longer fits stays
    /// out. Returns how many came back, so the caller can say what did not.
    @discardableResult
    public func restoreAll(_ cleared: [OmniStashEntry]) throws -> Int {
        try mutate { entries in
            let missing = cleared.filter { entry in !entries.contains { $0.id == entry.id } }
            let room = max(0, Self.capacity - entries.count)
            let restored = Array(missing.prefix(room))
            entries.append(contentsOf: restored)
            return restored.count + (cleared.count - missing.count)
        }
    }

    /// Undo of a push: removes the pushed entry and, when the push dropped
    /// the oldest, returns that one to the bottom.
    @discardableResult
    public func undoPush(_ outcome: OmniStashPushOutcome) throws -> Bool {
        guard !outcome.alreadyPresent else { return false }
        return try mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == outcome.entry.id }) else { return false }
            entries.remove(at: index)
            if let dropped = outcome.dropped, entries.count < Self.capacity, !entries.contains(where: { $0.id == dropped.id }) {
                entries.append(dropped)
            }
            return true
        }
    }

    @discardableResult
    public func updateText(id: String, text: String) throws -> OmniStashEntry? {
        try mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isEditable,
                  entries[index].text != text
            else { return nil }
            entries[index] = entries[index].edited(text: text)
            return entries[index]
        }
    }

    /// Empties the stack; returns what it held, top first, for undo.
    @discardableResult
    public func clear() throws -> [OmniStashEntry] {
        try mutate { entries in
            let removed = entries
            entries.removeAll()
            return removed
        }
    }

    // MARK: Storage

    private func mutate<T>(_ change: (inout [OmniStashEntry]) throws -> T) throws -> T {
        let (result, changed) = try Self.withLock(url) { () throws -> (T, Bool) in
            var entries = try load()
            let before = entries
            let result = try change(&entries)
            guard entries != before else { return (result, false) }
            try save(entries)
            return (result, true)
        }
        // Posted after the lock is released: an observer on the main queue
        // reads the stack, and a post from an owner actor waits for it.
        if changed { NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["path": url.path]) }
        return result
    }

    /// Schema 2 decodes in one pass. A v1 slot becomes the one entry. A file
    /// that is neither (corrupt, or written by a newer build) is moved aside
    /// as `current.json.unreadable-<time>` and the stash starts empty, so one
    /// bad file never disables `/stash`, the tool and the workspace for good.
    private func load() throws -> [OmniStashEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        if let document = try? Self.decoder.decode(Document.self, from: data), document.schemaVersion == Self.schemaVersion {
            return document.entries
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["schema_version"] as? Int == 1 {
            // The single slot (C42) becomes the one entry of the stack. Its
            // run marker survives, so the old receipt's Copy still resolves,
            // and its id is derived, so every read before the first write
            // names the same entry.
            guard let value = object["value"] as? String, !value.isEmpty else { return [] }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let runID = object["run_id"] as? String
            return [OmniStashEntry(id: "v1-" + (runID ?? OmniStashEntry.digest(value)), text: value, source: "Stash", createdAt: modified, runID: runID)]
        }
        let aside = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + ".unreadable-" + String(Int(Date().timeIntervalSince1970)))
        try FileManager.default.moveItem(at: url, to: aside)
        return []
    }

    private func save(_ entries: [OmniStashEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Document(schemaVersion: Self.schemaVersion, capacity: Self.capacity, entries: entries))
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else { throw OmniStashError.readbackMismatch }
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let capacity: Int
        let entries: [OmniStashEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case capacity, entries
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSRecursiveLock] = [:]

    private static func withLock<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        registryLock.lock()
        let lock = locks[url.path] ?? {
            let created = NSRecursiveLock()
            locks[url.path] = created
            return created
        }()
        registryLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// What a `/stash` run reports (C97). The owner's summary carries the
/// outcome, so the pad confirmation and the notification read one string.
public enum OmniStashReceipt {
    public static let stashed = "Stashed"
    public static let oldestDropped = "oldest dropped"

    public static func summary(for outcome: OmniStashPushOutcome) -> String {
        outcome.dropped == nil ? stashed : "\(stashed) · \(oldestDropped)"
    }

    /// `stashed`, or `stashed · oldest dropped` when the run's summary says
    /// the push cost the bottom entry.
    public static func wording(summary: String?) -> String {
        summary?.hasPrefix("\(stashed) · \(oldestDropped)") == true ? "stashed · \(oldestDropped)" : "stashed"
    }

    /// The owner side of `/stash`, shared by the installed and replica
    /// backends: push with the run marker, prove it by reading it back.
    public static func push(_ payload: String, runID: String, source: String?, into stack: OmniStashStack) throws -> OmniStashPushOutcome {
        let entry = OmniStashEntry(text: payload, source: source?.isEmpty == false ? source! : "Omni", runID: runID)
        let outcome = try stack.push(entry)
        guard try stack.entry(runID: runID)?.digest == outcome.entry.digest else { throw OmniStashError.readbackMismatch }
        return outcome
    }

    /// A run is proved when its marker is still on the stack with the digest
    /// of its text. A dropped entry no longer proves anything.
    public static func proves(runID: String, in stack: OmniStashStack) -> Bool {
        guard let entry = try? stack.entry(runID: runID) else { return false }
        return entry.digest == OmniStashEntry.digest(entry.text)
    }
}

/// The text a `/stash` run keeps. `ModuleInput.payloadText` joins every atom
/// with one space; the stash keeps the material's lines, so the payload is
/// read from the raw text with only the slash atoms taken out (the `/span`
/// precedent, amendment 1.6.0).
public enum OmniStashText {
    /// A line that loses a word is rejoined with single spaces; others keep
    /// their whitespace.
    public static func payload(fromCommandText text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let kept = words.filter { !isDropped($0) }
            guard kept.count != words.count else { return String(line) }
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            return kept.isEmpty ? "" : String(indentation) + kept.joined(separator: " ")
        }
        var trimmed = lines[...]
        while let first = trimmed.first, first.trimmingCharacters(in: .whitespaces).isEmpty { trimmed = trimmed.dropFirst() }
        while let last = trimmed.last, last.trimmingCharacters(in: .whitespaces).isEmpty { trimmed = trimmed.dropLast() }
        return trimmed.joined(separator: "\n").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    /// The words `payload(fromCommandText:)` takes out: slash atoms and the
    /// ✓ ✗ intent markers, in order.
    public static func droppedWords(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).filter { isDropped($0) }.map(String.init)
    }

    private static func isDropped(_ word: Substring) -> Bool {
        word == "✓" || word == "✗" || SlashAtom.parse(String(word)) != nil
    }

    /// One short line for rows, receipts and the sidebar.
    public static func excerpt(_ text: String, limit: Int = 80) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let head = collapsed.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return String(cut) + "…"
    }
}

/// How `/stash` is read in a request (C43, C96). Pure. The pad reads with
/// it; the service pushes only a bare `/stash` with text and refuses
/// `/stash:N`, so the two cannot disagree on a push.
public enum OmniStashCommand {
    public static let token = "/stash"

    public enum Reading: Sendable, Equatable {
        /// `/stash` with material and no other command: push the material.
        case push
        /// `/stash` without material, `/stash:N`, or `/stash` beside another
        /// command: import entry N (1 = top) as source.
        case `import`(position: Int, literal: String)
        /// No `/stash` atom.
        case none
    }

    /// `primaryTokens` are the request's other primary command tokens.
    public static func reading(of text: String, otherPrimaryTokens: [String]) -> Reading {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let atom = words.compactMap(SlashAtom.parse).first(where: { $0.token == token }) else { return .none }
        if let value = atom.value {
            return .import(position: Int(value) ?? 0, literal: atom.literal)
        }
        let material = !SlashTokenSyntax.payloadText(from: text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if otherPrimaryTokens.isEmpty && material { return .push }
        return .import(position: 1, literal: atom.literal)
    }

    /// The first whole-atom occurrence of `literal`, in UTF-16 units.
    public static func range(of literal: String, in text: String) -> NSRange? {
        let source = text as NSString
        var search = NSRange(location: 0, length: source.length)
        while true {
            let found = source.range(of: literal, options: [], range: search)
            guard found.location != NSNotFound else { return nil }
            let before = found.location == 0 ? " " : source.substring(with: NSRange(location: found.location - 1, length: 1))
            let after = NSMaxRange(found) >= source.length ? " " : source.substring(with: NSRange(location: NSMaxRange(found), length: 1))
            if before.rangeOfCharacter(from: .whitespacesAndNewlines) != nil, after.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                return found
            }
            search = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
        }
    }

    /// The request with the import atom replaced by the imported text, in
    /// place: the material stands where its token stood (leading, as typed,
    /// like a selection), and the rest parses on its own. The edit is
    /// returned so span notes can be remapped across it.
    public static func replacingImport(_ literal: String, in text: String, with material: String) -> (text: String, edit: NSRange, replacementLength: Int)? {
        guard let found = range(of: literal, in: text) else { return nil }
        let composed = (text as NSString).replacingCharacters(in: found, with: material)
        return (composed, found, (material as NSString).length)
    }

    /// The request without the import atom: what the pad parses for routes.
    public static func removingImport(_ literal: String, from text: String) -> String {
        guard let found = range(of: literal, in: text) else { return text }
        return (text as NSString).replacingCharacters(in: found, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
