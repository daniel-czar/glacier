import Foundation

/// One collected item (Collect, H19). Each copy is one item, multiline text
/// and duplicates included; Finder selections are their paths, one per line.
public struct ClipboardBufferItem: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let collectedAt: Date

    public init(id: UUID = UUID(), text: String, collectedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.collectedAt = collectedAt
    }
}

/// The persisted queue, oldest first. `sending` names the items handed to a
/// paste whose consumption is not recorded yet; finding it at start-up, or
/// failing to record a send, pauses pasting until the person resumes it
/// (prefer a duplicate over a loss, never replay on our own).
public struct ClipboardBufferState: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var items: [ClipboardBufferItem]
    public var sending: [UUID]?
    public var paused: Bool

    public init(items: [ClipboardBufferItem] = [], sending: [UUID]? = nil, paused: Bool = false) {
        schemaVersion = Self.currentSchema
        self.items = items
        self.sending = sending
        self.paused = paused
    }
}

public enum ClipboardBufferError: Error, Equatable, Sendable {
    /// The file exists but cannot be read: nothing is replaced or cleared.
    case unreadable(String)
    case full
    case writeFailed(String)
}

/// Versioned JSON under the host's runtime root, replaced atomically with
/// private permissions. A corrupt file fails visibly and is never overwritten
/// with an empty queue. The ceiling refuses new items; it never evicts.
@MainActor
public final class ClipboardBufferStore {
    public static let maximumItems = 1_000
    public static let maximumBytes = 16 * 1024 * 1024

    public let url: URL
    public private(set) var state = ClipboardBufferState()
    /// Set when the file could not be read; every operation refuses.
    public private(set) var loadError: String?
    public var onChange: (@MainActor () -> Void)?

    public init(url: URL) {
        self.url = url
        load()
    }

    public var items: [ClipboardBufferItem] { state.items }
    public var count: Int { state.items.count }
    public var isPaused: Bool { state.paused }
    public var isReady: Bool { loadError == nil }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoded = try JSONDecoder.collect.decode(ClipboardBufferState.self, from: Data(contentsOf: url))
            guard decoded.schemaVersion == ClipboardBufferState.currentSchema else {
                loadError = "unsupported schema \(decoded.schemaVersion)"
                return
            }
            state = decoded
            if state.sending != nil, !state.paused {
                // A send began and its outcome was never recorded (a crash or
                // a kill): the item may or may not have been pasted.
                state.paused = true
                try? write(state)
            }
        } catch {
            loadError = "\(url.lastPathComponent) could not be read: \(error)"
        }
    }

    /// Applies `change` and persists it; on a failed write nothing changes.
    public func mutate(_ change: (inout ClipboardBufferState) throws -> Void) throws {
        if let loadError { throw ClipboardBufferError.unreadable(loadError) }
        var next = state
        try change(&next)
        try write(next)
        state = next
        onChange?()
    }

    /// After a dispatched paste whose consumption could not be written: the
    /// pause holds in memory even when the disk refuses it too.
    public func pauseAfterUnrecordedSend() {
        state.paused = true
        if loadError == nil { try? write(state) }
        onChange?()
    }

    public func append(_ text: String, at date: Date = Date()) throws {
        try mutate { state in
            let bytes = state.items.reduce(0) { $0 + $1.text.utf8.count } + text.utf8.count
            guard state.items.count < Self.maximumItems, bytes <= Self.maximumBytes else { throw ClipboardBufferError.full }
            state.items.append(ClipboardBufferItem(text: text, collectedAt: date))
        }
    }

    private func write(_ value: ClipboardBufferState) throws {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try JSONEncoder.collect.encode(value).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ClipboardBufferError.writeFailed(String(describing: error))
        }
    }
}

private extension JSONEncoder {
    static var collect: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var collect: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
