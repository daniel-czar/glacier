import Foundation
import Testing
@testable import ClipboardHistory

private final class HistoryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(hours: Int) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(Double(hours) * 3_600)
    }

    func advance(days: Int) { advance(hours: days * 24) }
}

private struct HistoryTestRoot {
    let envelope: URL
    let directory: URL

    init() throws {
        envelope = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipboard-history-tests-\(UUID().uuidString)", isDirectory: true)
        directory = envelope.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: envelope, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: envelope) }

    var assets: URL { directory.appendingPathComponent("assets", isDirectory: true) }

    func assetNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: assets.path).sorted()
    }
}

@Test func settingsPersistAndPauseRejectsNewCaptures() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let store = try ClipboardHistoryStore(directory: root.directory)
    let settings = ClipboardHistorySettings(
        paused: true, retentionHours: 21 * 24, excludedBundleIDs: ["com.example.private"])
    try await store.updateSettings(settings)
    #expect(try await store.settings() == settings)
    await #expect(throws: ClipboardHistoryStoreError.paused) {
        _ = try await store.save(payload: .text(plain: "do not save"))
    }
    let reopened = try ClipboardHistoryStore(directory: root.directory)
    #expect(try await reopened.settings() == settings)
    #expect(try await reopened.load().isEmpty)
}

@Test func exactTextAndRichRepresentationsSurviveRestartAndSearch() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let store = try ClipboardHistoryStore(directory: root.directory)
    let plain = "  Leading\n\n\tindented αβ\r\nTrailing  \n"
    let rtf = Data("{\\rtf1\\ansi αβ}".utf8)
    let html = Data("<p>αβ&nbsp;value</p>".utf8)
    let expected = ClipboardHistoryPayload.text(plain: plain, rtf: rtf, html: html)
    let saved = try await store.save(payload: expected,
        source: ClipboardHistorySource(bundleID: "com.example.editor", name: "Editor"))
    #expect(saved.kind == .text)
    #expect(saved.hasFormatting)
    #expect(saved.byteCount == plain.utf8.count + rtf.count + html.count)
    #expect(saved.sourceBundleID == "com.example.editor")
    #expect(try await store.list(query: "INDENTED").map(\.id) == [saved.id])
    #expect(try await store.list(query: "absent").isEmpty)

    let reopened = try ClipboardHistoryStore(directory: root.directory)
    #expect(try await reopened.payload(id: saved.id) == expected)
    #expect(try await reopened.load().map(\.id) == [saved.id])

    // Exact consecutive copies coalesce, but a change only in formatting is distinct.
    let repeated = try await reopened.save(payload: expected)
    #expect(repeated.id == saved.id)
    let changed = try await reopened.save(payload: .text(plain: plain, rtf: rtf, html: nil))
    #expect(changed.id != saved.id)
    #expect(try await reopened.load().count == 2)
}

@Test func imageListUsesMetadataAndPayloadReturnsOriginalBytes() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let store = try ClipboardHistoryStore(directory: root.directory)
    let image = Data((0..<20_000).map { UInt8($0 % 251) })
    let saved = try await store.save(payload: .image(data: image, typeIdentifier: "public.png"))
    #expect(saved.kind == .image)
    #expect(saved.byteCount == image.count)
    #expect(try root.assetNames().count == 1)
    #expect(try await store.list().map(\.id) == [saved.id])
    #expect(try await store.payload(id: saved.id) == .image(data: image, typeIdentifier: "public.png"))

    // A loaded store can list summaries without reopening image bytes.
    let asset = try #require(root.assetNames().first)
    try FileManager.default.removeItem(at: root.assets.appendingPathComponent(asset))
    #expect(try await store.list().map(\.id) == [saved.id])
    await #expect(throws: ClipboardHistoryStoreError.corruptStore) {
        _ = try await store.payload(id: saved.id)
    }
}

@Test func expiryAppliesAfterOfflineTimeAndRetentionChanges() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = try ClipboardHistoryStore(directory: root.directory, now: { clock.now() })
    try await store.updateSettings(.init(retentionHours: 7 * 24))
    let old = try await store.save(payload: .image(data: Data(repeating: 7, count: 400), typeIdentifier: "public.png"))
    clock.advance(days: 6)
    let recent = try await store.save(payload: .text(plain: "recent", html: Data("<b>recent</b>".utf8)))
    clock.advance(days: 2)
    let reopened = try ClipboardHistoryStore(directory: root.directory, now: { clock.now() })
    #expect(try await reopened.load().map(\.id) == [recent.id])
    #expect(try await reopened.payload(id: old.id) == nil)
    #expect(try root.assetNames().allSatisfy { $0.hasSuffix(".html") })

    try await reopened.updateSettings(.init(retentionHours: 24))
    #expect(try await reopened.load().isEmpty)
    #expect(try root.assetNames().isEmpty)
}

@Test func deleteAndClearRemoveOnlySavedAssetsAcrossRestart() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let store = try ClipboardHistoryStore(directory: root.directory)
    let first = try await store.save(payload: .image(data: Data([1, 2, 3]), typeIdentifier: "public.png"))
    let second = try await store.save(payload: .text(plain: "other", rtf: Data([4, 5])))
    #expect(try root.assetNames().count == 2)
    try await store.delete(id: first.id)
    #expect(try root.assetNames().count == 1)
    #expect(try await store.load().map(\.id) == [second.id])
    let reopened = try ClipboardHistoryStore(directory: root.directory)
    #expect(try await reopened.load().map(\.id) == [second.id])
    try await reopened.clear()
    #expect(try root.assetNames().isEmpty)
    #expect(try await store.payload(id: first.id) == nil)
    let afterClear = try ClipboardHistoryStore(directory: root.directory)
    #expect(try await afterClear.load().isEmpty)
}

@Test func rollingCapacityEvictsOldestAndPrunesAssetsAcrossRestart() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let store = try ClipboardHistoryStore(directory: root.directory, maxStorageBytes: 10)
    let first = try await store.save(payload: .image(data: Data(repeating: 1, count: 4), typeIdentifier: "public.png"))
    let second = try await store.save(payload: .image(data: Data(repeating: 2, count: 4), typeIdentifier: "public.png"))
    let third = try await store.save(payload: .image(data: Data(repeating: 3, count: 7), typeIdentifier: "public.png"))
    #expect(try await store.payload(id: first.id) == nil)
    #expect(try await store.payload(id: second.id) == nil)
    #expect(try root.assetNames().count == 1)
    let reopened = try ClipboardHistoryStore(directory: root.directory, maxStorageBytes: 10)
    #expect(try await reopened.load().map(\.id) == [third.id])
    #expect(try await reopened.payload(id: third.id) == .image(data: Data(repeating: 3, count: 7), typeIdentifier: "public.png"))
    #expect(try await reopened.storageUsage().usedBytes == 7)
}

@Test func oversizedItemDoesNotEvictOrTruncateRetainedHistory() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let store = try ClipboardHistoryStore(directory: root.directory, maxStorageBytes: 10)
    let first = try await store.save(payload: .image(data: Data(repeating: 1, count: 8), typeIdentifier: "public.png"))
    await #expect(throws: ClipboardHistoryStoreError.capacityExceeded(requiredBytes: 11, availableBytes: 10)) {
        _ = try await store.save(payload: .image(data: Data(repeating: 2, count: 11), typeIdentifier: "public.png"))
    }
    #expect(try await store.load().map(\.id) == [first.id])
    #expect(try root.assetNames().count == 1)
    #expect(try await store.payload(id: first.id) == .image(data: Data(repeating: 1, count: 8), typeIdentifier: "public.png"))
}

@Test func equalTimestampEvictionUsesStableIDOrderAndDuplicateRefreshDoesNotEvict() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = try ClipboardHistoryStore(directory: root.directory, now: { clock.now() }, maxStorageBytes: 6)
    let first = try await store.save(payload: .text(plain: "one"))
    let second = try await store.save(payload: .text(plain: "two"))
    let newest = first.id.uuidString > second.id.uuidString ? first : second
    let newestText = newest.id == first.id ? "one" : "two"
    let repeated = try await store.save(payload: .text(plain: newestText))
    #expect(repeated.id == newest.id)
    #expect(try await store.load().count == 2)
    clock.advance(hours: 1)
    let third = try await store.save(payload: .text(plain: "tri"))
    let retained = try await store.load().map(\.id)
    let olderID = first.id.uuidString < second.id.uuidString ? first.id : second.id
    #expect(!retained.contains(olderID))
    #expect(retained.contains(third.id))
}

@Test func expiredPayloadFreesCapacityBeforeNextSave() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = try ClipboardHistoryStore(directory: root.directory, now: { clock.now() }, maxStorageBytes: 10)
    _ = try await store.save(payload: .text(plain: "12345678"))
    #expect(try await store.storageUsage().usedBytes == 8)
    clock.advance(hours: 36)
    _ = try await store.save(payload: .text(plain: "abc"))
    let usage = try await store.storageUsage()
    #expect(usage.usedBytes == 3)
    #expect(usage.capacityBytes == 10)
    #expect(try await store.list().count == 1)
}

@Test func defaultRetentionExpiresAtExact36HourBoundaryAfterRestart() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = try ClipboardHistoryStore(directory: root.directory, now: { clock.now() })
    _ = try await store.save(payload: .text(plain: "retained"))
    #expect(try await store.settings().retentionHours == 36)
    clock.advance(hours: 35)
    let reopened = try ClipboardHistoryStore(directory: root.directory, now: { clock.now() })
    #expect(try await reopened.list().count == 1)
    clock.advance(hours: 1)
    #expect(try await reopened.list().isEmpty)
}

@Test func legacyDayRetentionDecodesWithoutShorteningUntilExplicitChange() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let store = try ClipboardHistoryStore(directory: root.directory)
    _ = try await store.save(payload: .text(plain: "retained"))
    let file = root.directory.appendingPathComponent("history.json")
    let data = try Data(contentsOf: file)
    var manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var settings = try #require(manifest["settings"] as? [String: Any])
    settings.removeValue(forKey: "retentionHours")
    settings["retentionDays"] = 7
    manifest["settings"] = settings
    try JSONSerialization.data(withJSONObject: manifest).write(to: file)

    let reopened = try ClipboardHistoryStore(directory: root.directory)
    #expect(try await reopened.settings().retentionHours == 168)
    #expect(try await reopened.list().count == 1)
    try await reopened.updateSettings(.init(retentionHours: 36))
    let migrated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let migratedSettings = try #require(migrated["settings"] as? [String: Any])
    #expect(migratedSettings["retentionHours"] as? Int == 36)
    #expect(migratedSettings["retentionDays"] == nil)
}

@Test func interruptedAssetWriteIsPrunedAndCorruptManifestIsReported() async throws {
    let root = try HistoryTestRoot()
    defer { root.remove() }
    let store = try ClipboardHistoryStore(directory: root.directory)
    let retained = try await store.save(payload: .image(data: Data([8]), typeIdentifier: "public.png"))
    try Data([1, 2]).write(to: root.assets.appendingPathComponent("unreferenced.image"))
    try Data([3]).write(to: root.assets.appendingPathComponent(".interrupted.tmp"))
    let reopened = try ClipboardHistoryStore(directory: root.directory)
    #expect(try await reopened.load().map(\.id) == [retained.id])
    #expect(try root.assetNames().count == 1)

    let manifest = root.directory.appendingPathComponent("history.json")
    try Data("{not valid json".utf8).write(to: manifest)
    let corrupt = try ClipboardHistoryStore(directory: root.directory)
    await #expect(throws: ClipboardHistoryStoreError.corruptStore) {
        _ = try await corrupt.load()
    }
    // Failed decoding must not delete the last known payload asset.
    #expect(try root.assetNames().count == 1)
}
