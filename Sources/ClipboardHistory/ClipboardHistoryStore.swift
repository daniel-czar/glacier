import Darwin
import Foundation

public enum ClipboardHistoryPayload: Sendable, Equatable {
    case text(plain: String, rtf: Data? = nil, html: Data? = nil)
    case image(data: Data, typeIdentifier: String)
}

public struct ClipboardHistorySource: Sendable, Equatable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String? = nil, name: String? = nil) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct ClipboardHistorySettings: Codable, Sendable, Equatable {
    public var paused: Bool
    public var retentionHours: Int
    public var excludedBundleIDs: [String]

    public init(paused: Bool = false, retentionHours: Int = 36, excludedBundleIDs: [String] = []) {
        self.paused = paused
        self.retentionHours = retentionHours
        self.excludedBundleIDs = excludedBundleIDs
    }

    private enum CodingKeys: String, CodingKey {
        case paused, retentionHours, retentionDays, excludedBundleIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paused = try values.decode(Bool.self, forKey: .paused)
        excludedBundleIDs = try values.decode([String].self, forKey: .excludedBundleIDs)
        if let hours = try values.decodeIfPresent(Int.self, forKey: .retentionHours) {
            retentionHours = hours
        } else {
            let days = try values.decode(Int.self, forKey: .retentionDays)
            guard (1...3650).contains(days) else {
                throw DecodingError.dataCorruptedError(forKey: .retentionDays, in: values,
                    debugDescription: "Retention days are out of range")
            }
            retentionHours = days * 24
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(paused, forKey: .paused)
        try values.encode(retentionHours, forKey: .retentionHours)
        try values.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
    }
}

public enum ClipboardHistoryKind: String, Codable, Sendable {
    case text
    case image
}

public struct ClipboardHistorySummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: ClipboardHistoryKind
    public let copiedAt: Date
    public let sourceBundleID: String?
    public let sourceName: String?
    public let preview: String
    public let byteCount: Int
    public let hasFormatting: Bool
}

public enum ClipboardHistoryStoreError: Error, Sendable, Equatable {
    case invalidDirectory
    case invalidCapacity
    case invalidRetentionDays
    case paused
    case capacityExceeded(requiredBytes: Int, availableBytes: Int)
    case corruptStore
}

/// Owns only local history persistence. Clipboard observation and paste effects belong to the host.
public actor ClipboardHistoryStore {
    private struct Manifest: Codable {
        var version: Int = 1
        var settings = ClipboardHistorySettings()
        var entries: [StoredEntry] = []
    }

    private struct StoredEntry: Codable {
        var id: UUID
        var kind: ClipboardHistoryKind
        var copiedAt: Date
        var sourceBundleID: String?
        var sourceName: String?
        var plain: String?
        var typeIdentifier: String?
        var assetName: String?
        var richName: String?
        var htmlName: String?
        var byteCount: Int

        var summary: ClipboardHistorySummary {
            ClipboardHistorySummary(
                id: id,
                kind: kind,
                copiedAt: copiedAt,
                sourceBundleID: sourceBundleID,
                sourceName: sourceName,
                preview: kind == .text ? String((plain ?? "").prefix(160)) : "Image",
                byteCount: byteCount,
                hasFormatting: richName != nil || htmlName != nil
            )
        }
    }

    private let directory: URL
    private let assetsDirectory: URL
    private let manifestURL: URL
    private let now: @Sendable () -> Date
    private let maxStorageBytes: Int
    private var manifest: Manifest?
    private var cleanupPending = false

    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        maxStorageBytes: Int = 2 * 1024 * 1024 * 1024
    ) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), maxStorageBytes > 0 else {
            throw directory.isFileURL && directory.path.hasPrefix("/")
                ? ClipboardHistoryStoreError.invalidCapacity : ClipboardHistoryStoreError.invalidDirectory
        }
        self.directory = directory.standardizedFileURL
        self.assetsDirectory = self.directory.appendingPathComponent("assets", isDirectory: true)
        self.manifestURL = self.directory.appendingPathComponent("history.json")
        self.now = now
        self.maxStorageBytes = maxStorageBytes
        try Self.preparePrivateDirectory(self.directory)
        try Self.preparePrivateDirectory(self.assetsDirectory)
    }

    /// Opens the persisted store and applies elapsed expiry before returning any entries.
    public func load() throws -> [ClipboardHistorySummary] {
        try ensureLoaded()
        try expire()
        return sortedSummaries()
    }

    public func list(query: String = "") throws -> [ClipboardHistorySummary] {
        try ensureLoaded()
        try expire()
        let entries = manifest!.entries
        let matches = query.isEmpty ? entries : entries.filter { entry in
            guard entry.kind == .text, let plain = entry.plain else { return false }
            return plain.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return matches.sorted(by: Self.newestFirst).map(\.summary)
    }

    /// Content-free capacity facts for host status and diagnostics.
    public func storageUsage() throws -> (usedBytes: Int, capacityBytes: Int) {
        try ensureLoaded()
        try expire()
        let used = manifest!.entries.reduce(0) { $0 + $1.byteCount }
        return (used, maxStorageBytes)
    }

    @discardableResult
    public func save(
        payload: ClipboardHistoryPayload,
        source: ClipboardHistorySource? = nil,
        copiedAt: Date? = nil
    ) throws -> ClipboardHistorySummary {
        try ensureLoaded()
        try expire()
        guard manifest!.settings.paused == false else { throw ClipboardHistoryStoreError.paused }
        let date = copiedAt ?? now()
        let size = Self.payloadSize(payload)
        guard let size else { throw ClipboardHistoryStoreError.capacityExceeded(requiredBytes: Int.max, availableBytes: 0) }

        // A repeated *copy* refreshes recency. Browsing and recalling never call save.
        if let newest = manifest!.entries.sorted(by: Self.newestFirst).first,
           try samePayload(payload, as: newest) {
            var next = manifest!
            let index = next.entries.firstIndex(where: { $0.id == newest.id })!
            next.entries[index].copiedAt = date
            next.entries[index].sourceBundleID = source?.bundleID
            next.entries[index].sourceName = source?.name
            try commit(next)
            return next.entries[index].summary
        }

        // A single item over the total budget cannot fit, even in an empty store.
        guard size <= maxStorageBytes else {
            throw ClipboardHistoryStoreError.capacityExceeded(requiredBytes: size, availableBytes: maxStorageBytes)
        }
        var next = manifest!
        var used = next.entries.reduce(into: 0) { $0 += $1.byteCount }
        let targetUsage = maxStorageBytes - size
        // Evict oldest first. The existing UUID tie-breaker makes equal-time order stable.
        for old in next.entries.sorted(by: { Self.newestFirst($1, $0) }) {
            guard used > targetUsage else { break }
            next.entries.removeAll { $0.id == old.id }
            used -= old.byteCount
        }
        let evicted = next.entries.count != manifest!.entries.count

        let id = UUID()
        var createdAssets: [URL] = []
        let entry: StoredEntry
        do {
            switch payload {
            case let .text(plain, rtf, html):
                let richName = rtf.map { _ in "\(id.uuidString).rtf" }
                let htmlName = html.map { _ in "\(id.uuidString).html" }
                if let rtf, let richName {
                    let url = assetsDirectory.appendingPathComponent(richName)
                    try Self.writePrivateAtomically(rtf, to: url)
                    createdAssets.append(url)
                }
                if let html, let htmlName {
                    let url = assetsDirectory.appendingPathComponent(htmlName)
                    try Self.writePrivateAtomically(html, to: url)
                    createdAssets.append(url)
                }
                entry = StoredEntry(id: id, kind: .text, copiedAt: date,
                    sourceBundleID: source?.bundleID, sourceName: source?.name,
                    plain: plain, typeIdentifier: nil, assetName: nil,
                    richName: richName, htmlName: htmlName, byteCount: size)
            case let .image(data, typeIdentifier):
                let name = "\(id.uuidString).image"
                let url = assetsDirectory.appendingPathComponent(name)
                try Self.writePrivateAtomically(data, to: url)
                createdAssets.append(url)
                entry = StoredEntry(id: id, kind: .image, copiedAt: date,
                    sourceBundleID: source?.bundleID, sourceName: source?.name,
                    plain: nil, typeIdentifier: typeIdentifier, assetName: name,
                    richName: nil, htmlName: nil, byteCount: size)
            }
            next.entries.append(entry)
            try commit(next)
        } catch {
            for url in createdAssets { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        // The new manifest is durable. Cleanup failures retry on the next store operation.
        if evicted { try? pruneOrphanAssets() }
        return entry.summary
    }

    public func payload(id: UUID) throws -> ClipboardHistoryPayload? {
        try ensureLoaded()
        try expire()
        guard let entry = manifest!.entries.first(where: { $0.id == id }) else { return nil }
        switch entry.kind {
        case .text:
            guard let plain = entry.plain else { throw ClipboardHistoryStoreError.corruptStore }
            let rtf = try entry.richName.map { try readAsset($0) }
            let html = try entry.htmlName.map { try readAsset($0) }
            return .text(plain: plain, rtf: rtf, html: html)
        case .image:
            guard let name = entry.assetName, let typeIdentifier = entry.typeIdentifier else {
                throw ClipboardHistoryStoreError.corruptStore
            }
            return .image(data: try readAsset(name), typeIdentifier: typeIdentifier)
        }
    }

    public func delete(id: UUID) throws {
        try ensureLoaded()
        try expire()
        var next = manifest!
        next.entries.removeAll { $0.id == id }
        guard next.entries.count != manifest!.entries.count else { return }
        try commit(next)
        try pruneOrphanAssets()
    }

    public func clear() throws {
        try ensureLoaded()
        var next = manifest!
        next.entries = []
        try commit(next)
        try pruneOrphanAssets()
    }

    public func settings() throws -> ClipboardHistorySettings {
        try ensureLoaded()
        try expire()
        return manifest!.settings
    }

    public func updateSettings(_ settings: ClipboardHistorySettings) throws {
        try ensureLoaded()
        guard (1...87_600).contains(settings.retentionHours) else {
            throw ClipboardHistoryStoreError.invalidRetentionDays
        }
        var next = manifest!
        next.settings = settings
        // A shorter retention takes effect in the same durable transaction.
        next.entries.removeAll { Self.isExpired($0, at: now(), retentionHours: settings.retentionHours) }
        try commit(next)
        try pruneOrphanAssets()
    }

    private func ensureLoaded() throws {
        guard manifest == nil else {
            if cleanupPending { try pruneOrphanAssets() }
            return
        }
        let loaded: Manifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            guard let values = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ClipboardHistoryStoreError.corruptStore
            }
            let data = try Data(contentsOf: manifestURL)
            guard let decoded = try? JSONDecoder().decode(Manifest.self, from: data),
                  decoded.version == 1,
                  (1...87_600).contains(decoded.settings.retentionHours),
                  Set(decoded.entries.map(\.id)).count == decoded.entries.count else {
                throw ClipboardHistoryStoreError.corruptStore
            }
            loaded = decoded
        } else {
            loaded = Manifest()
        }
        var totalBytes = 0
        for entry in loaded.entries {
            guard entry.byteCount >= 0 else { throw ClipboardHistoryStoreError.corruptStore }
            let (next, overflow) = totalBytes.addingReportingOverflow(entry.byteCount)
            guard !overflow else { throw ClipboardHistoryStoreError.corruptStore }
            totalBytes = next
        }
        // Validate retained assets only. Old expired entries can be removed even if their
        // files were lost while the host was offline.
        for entry in loaded.entries where !Self.isExpired(entry, at: now(), retentionHours: loaded.settings.retentionHours) {
            switch entry.kind {
            case .text:
                guard entry.plain != nil, entry.assetName == nil else { throw ClipboardHistoryStoreError.corruptStore }
            case .image:
                guard entry.plain == nil, entry.assetName == "\(entry.id.uuidString).image",
                      entry.typeIdentifier != nil else { throw ClipboardHistoryStoreError.corruptStore }
            }
            if let name = entry.assetName { try validateAsset(name) }
            if let name = entry.richName {
                guard name == "\(entry.id.uuidString).rtf" else { throw ClipboardHistoryStoreError.corruptStore }
                try validateAsset(name)
            }
            if let name = entry.htmlName {
                guard entry.kind == .text, name == "\(entry.id.uuidString).html" else {
                    throw ClipboardHistoryStoreError.corruptStore
                }
                try validateAsset(name)
            }
        }
        manifest = loaded
        try expire()
        try pruneOrphanAssets()
    }

    private func expire() throws {
        guard let current = manifest else { return }
        var next = current
        next.entries.removeAll { Self.isExpired($0, at: now(), retentionHours: current.settings.retentionHours) }
        guard next.entries.count != current.entries.count else { return }
        try commit(next)
        try pruneOrphanAssets()
    }

    private static func isExpired(_ entry: StoredEntry, at date: Date, retentionHours: Int) -> Bool {
        date.timeIntervalSince(entry.copiedAt) >= Double(retentionHours) * 3_600
    }

    private static func newestFirst(_ lhs: StoredEntry, _ rhs: StoredEntry) -> Bool {
        lhs.copiedAt == rhs.copiedAt ? lhs.id.uuidString > rhs.id.uuidString : lhs.copiedAt > rhs.copiedAt
    }

    private func sortedSummaries() -> [ClipboardHistorySummary] {
        manifest!.entries.sorted(by: Self.newestFirst).map(\.summary)
    }

    private static func payloadSize(_ payload: ClipboardHistoryPayload) -> Int? {
        switch payload {
        case let .text(plain, rtf, html):
            let plainCount = plain.utf8.count
            let richCount = rtf?.count ?? 0
            let htmlCount = html?.count ?? 0
            let (first, firstOverflow) = plainCount.addingReportingOverflow(richCount)
            let (sum, secondOverflow) = first.addingReportingOverflow(htmlCount)
            return firstOverflow || secondOverflow ? nil : sum
        case let .image(data, _):
            return data.count
        }
    }

    private func samePayload(_ payload: ClipboardHistoryPayload, as entry: StoredEntry) throws -> Bool {
        switch payload {
        case let .text(plain, rtf, html):
            guard entry.kind == .text, entry.plain == plain else { return false }
            if let richName = entry.richName {
                guard let rtf, try readAsset(richName) == rtf else { return false }
            } else if rtf != nil { return false }
            if let htmlName = entry.htmlName {
                guard let html, try readAsset(htmlName) == html else { return false }
            } else if html != nil { return false }
            return true
        case let .image(data, typeIdentifier):
            guard entry.kind == .image, entry.typeIdentifier == typeIdentifier,
                  let name = entry.assetName, entry.byteCount == data.count else { return false }
            return try readAsset(name) == data
        }
    }

    private func commit(_ next: Manifest) throws {
        let data = try JSONEncoder().encode(next)
        try Self.writePrivateAtomically(data, to: manifestURL)
        manifest = next
    }

    private func readAsset(_ name: String) throws -> Data {
        try validateAsset(name)
        return try Data(contentsOf: assetsDirectory.appendingPathComponent(name))
    }

    private func validateAsset(_ name: String) throws {
        guard !name.contains("/"), !name.contains("..") else { throw ClipboardHistoryStoreError.corruptStore }
        let url = assetsDirectory.appendingPathComponent(name)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ClipboardHistoryStoreError.corruptStore
        }
    }

    private func pruneOrphanAssets() throws {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: assetsDirectory.path)
            let used = Set(manifest!.entries.flatMap { [$0.assetName, $0.richName, $0.htmlName].compactMap { $0 } })
            for name in names where !used.contains(name) {
                try FileManager.default.removeItem(at: assetsDirectory.appendingPathComponent(name))
            }
            cleanupPending = false
        } catch {
            cleanupPending = true
            throw error
        }
    }

    private static func preparePrivateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                throw ClipboardHistoryStoreError.invalidDirectory
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func writePrivateAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                    guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    written += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard Darwin.close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let directoryDescriptor = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY)
            if directoryDescriptor >= 0 { _ = Darwin.fsync(directoryDescriptor); _ = Darwin.close(directoryDescriptor) }
        } catch {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
