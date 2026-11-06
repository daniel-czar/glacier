import Foundation
import OmniCore
import Testing

private func temporaryStack() throws -> (OmniStashStack, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omni-stash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (OmniStashStack(url: directory.appendingPathComponent("current.json")), directory)
}

private func entry(_ text: String, source: String = "Safari", runID: String? = nil) -> OmniStashEntry {
    OmniStashEntry(text: text, source: source, runID: runID)
}

@Test func stackPushesOnTopAndASixthPushDropsTheOldest() throws {
    let (stack, directory) = try temporaryStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 1...5 {
        let outcome = try stack.push(entry("entry \(index)"))
        #expect(outcome.dropped == nil)
    }
    #expect(try stack.entries().map(\.text) == ["entry 5", "entry 4", "entry 3", "entry 2", "entry 1"])
    let sixth = try stack.push(entry("entry 6"))
    #expect(sixth.dropped?.text == "entry 1")
    #expect(OmniStashReceipt.summary(for: sixth) == "Stashed · oldest dropped")
    #expect(try stack.entries().map(\.text) == ["entry 6", "entry 5", "entry 4", "entry 3", "entry 2"])
    #expect(OmniStashStack.capacity == 5)

    // ⌘Z after the sixth push: the new top goes, the oldest comes back.
    #expect(try stack.undoPush(sixth))
    #expect(try stack.entries().map(\.text) == ["entry 5", "entry 4", "entry 3", "entry 2", "entry 1"])
}

@Test func runMarkerMakesARetriedPushIdempotentAndProvesTheRun() throws {
    let (stack, directory) = try temporaryStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try OmniStashReceipt.push("kept text", runID: "run-1", source: nil, into: stack)
    #expect(first.entry.source == "Omni")
    let retry = try OmniStashReceipt.push("kept text", runID: "run-1", source: "Mail", into: stack)
    #expect(retry.alreadyPresent)
    #expect(try stack.entries().count == 1)
    #expect(OmniStashReceipt.proves(runID: "run-1", in: stack))
    #expect(!OmniStashReceipt.proves(runID: "run-2", in: stack))
    _ = try stack.remove(id: first.entry.id)
    #expect(!OmniStashReceipt.proves(runID: "run-1", in: stack))
}

@Test func dropRestoreEditAndClearKeepPositions() throws {
    let (stack, directory) = try temporaryStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    for text in ["c", "b", "a"] { try stack.push(entry(text)) }
    let middle = try #require(try stack.entry(at: 2))
    let removed = try #require(try stack.remove(id: middle.id))
    #expect(removed.index == 1)
    #expect(try stack.entries().map(\.text) == ["a", "c"])
    #expect(try stack.restore(removed.entry, at: removed.index))
    #expect(try stack.entries().map(\.text) == ["a", "b", "c"])

    let edited = try #require(try stack.updateText(id: middle.id, text: "b, edited\nsecond line"))
    #expect(edited.editedAt != nil)
    #expect(edited.lineCount == 2)
    #expect(try stack.entry(at: 2)?.text == "b, edited\nsecond line")

    let cleared = try stack.clear()
    #expect(cleared.map(\.text) == ["a", "b, edited\nsecond line", "c"])
    #expect(try stack.entries().isEmpty)
    for (index, value) in cleared.enumerated() { #expect(try stack.restore(value, at: index)) }
    #expect(try stack.entries().map(\.text) == ["a", "b, edited\nsecond line", "c"])
}

@Test func restoreRefusesRatherThanEvictWhenTheStackFilledSince() throws {
    let (stack, directory) = try temporaryStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 1...5 { try stack.push(entry("entry \(index)")) }
    let top = try #require(try stack.entry(at: 1))
    let removed = try #require(try stack.remove(id: top.id))
    try stack.push(entry("newer"))
    #expect(try stack.restore(removed.entry, at: removed.index) == false)
    #expect(try stack.entries().count == 5)
}

@Test func singleSlotStashMigratesToTheFirstEntryWithItsRunMarker() throws {
    let (stack, directory) = try temporaryStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy: [String: Any] = ["schema_version": 1, "run_id": "oi_legacy", "digest": "x", "value": "old slot"]
    try JSONSerialization.data(withJSONObject: legacy).write(to: stack.url)
    #expect(try stack.entries().map(\.text) == ["old slot"])
    #expect(try stack.entry(runID: "oi_legacy")?.source == "Stash")
    // Before the first write, every read names the same entry, so a drop or
    // an edit of the migrated slot finds it.
    let id = try #require(try stack.entries().first?.id)
    #expect(try stack.entries().first?.id == id)
    #expect(try stack.updateText(id: id, text: "old slot, edited") != nil)
    #expect(try stack.entries().map(\.text) == ["old slot, edited"])
    try stack.push(entry("new"))
    let stored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stack.url)) as? [String: Any])
    #expect(stored["schema_version"] as? Int == 2)
    #expect(try stack.entries().map(\.text) == ["new", "old slot, edited"])
}

@Test func storePreservesRepresentationsAndRejectsCorruptFiles() throws {
    let (stack, directory) = try temporaryStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rtf = OmniStashRepresentation(type: "public.rtf", data: Data("{\\rtf1 hi}".utf8))
    try stack.push(OmniStashEntry(text: "hi", representations: [rtf], source: "TextEdit"))
    let png = OmniStashRepresentation(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
    try stack.push(OmniStashEntry(text: "", representations: [png], source: "Preview"))
    let entries = try stack.entries()
    #expect(entries[0].kind == .image)
    #expect(!entries[0].isEditable)
    #expect(entries[1].representations == [rtf])
    // A hand edit keeps only the text.
    #expect(try stack.updateText(id: entries[1].id, text: "hello")?.representations.isEmpty == true)
    #expect(throws: OmniStashError.empty) { try stack.push(OmniStashEntry(text: "", source: "Omni")) }

    // An unreadable file is moved aside, never left to block every write.
    try Data("not json".utf8).write(to: stack.url)
    #expect(try stack.entries().isEmpty)
    let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("current.json.unreadable-") }
    #expect(aside.count == 1)
    try stack.push(entry("fresh start"))
    #expect(try stack.entries().map(\.text) == ["fresh start"])
}

@Test func aPushOffTheMainThreadNeverWaitsOnAMainQueueObserverThatReads() async throws {
    let (stack, directory) = try temporaryStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The owner backends push from an actor; the workspace observes on main
    // and reads the stack. Posting under the lock deadlocked the two.
    let token = NotificationCenter.default.addObserver(forName: OmniStashStack.didChange, object: nil, queue: .main) { _ in
        _ = try? stack.entries()
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let pushed = Task.detached { try stack.push(OmniStashEntry(text: "from an actor", source: "Omni")) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline, (try? stack.entries().count) != 1 {
        try await Task.sleep(for: .milliseconds(20))
    }
    _ = try await pushed.value
    #expect(try stack.entries().map(\.text) == ["from an actor"])
}

@Test func undoingAClearKeepsNewerPushesOnTopAndSaysWhatDidNotFit() throws {
    let (stack, directory) = try temporaryStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    for text in ["e", "d", "c", "b", "a"] { try stack.push(entry(text)) }
    let cleared = try stack.clear()
    try stack.push(entry("x"))
    #expect(try stack.restoreAll(cleared) == 4)
    #expect(try stack.entries().map(\.text) == ["x", "a", "b", "c", "d"])
}

@Test func everyChangePostsOneNotificationAndNoChangePostsNone() throws {
    let (stack, directory) = try temporaryStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    nonisolated(unsafe) var count = 0
    let token = NotificationCenter.default.addObserver(forName: OmniStashStack.didChange, object: nil, queue: nil) { note in
        if note.userInfo?["path"] as? String == stack.url.path { count += 1 }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let pushed = try stack.push(entry("a"))
    #expect(count == 1)
    _ = try stack.updateText(id: pushed.entry.id, text: "a")
    _ = try stack.remove(id: "missing")
    #expect(count == 1)
    _ = try stack.clear()
    #expect(count == 2)
}

@Test func kindsAreDetectedDeterministically() {
    #expect(OmniContentKind.classify(text: "https://api.forvo.com/documentation/branding/") == .link)
    #expect(OmniContentKind.classify(text: "find . -type f -exec basename {} \\;") == .code)
    #expect(OmniContentKind.classify(text: "#3d8bff") == .colour)
    #expect(OmniContentKind.classify(text: "Besserwisser → know-it-all · smart aleck · wise guy") == .text)
    #expect(OmniContentKind.classify(text: "Coordinator: your D-18 hook at 0558 is confirmed; the hangar brief moves to 0530.") == .text)
    #expect(OmniContentKind.classify(text: "", types: ["public.png"]) == .image)
    #expect(OmniContentKind.classify(text: "/Users/me/a.txt", types: ["public.file-url"]) == .file)
}

@Test func stashPayloadKeepsLinesAndDropsOnlyTheAtoms() {
    #expect(OmniStashText.payload(fromCommandText: "line one\n  line two /stash") == "line one\n  line two")
    #expect(OmniStashText.payload(fromCommandText: "/stash keep this") == "keep this")
    #expect(OmniStashText.payload(fromCommandText: "first\n\nthird\n/stash /offline") == "first\n\nthird")
}

@Test func stashReadingDecidesPushOrImport() {
    #expect(OmniStashCommand.reading(of: "some text /stash", otherPrimaryTokens: []) == .push)
    #expect(OmniStashCommand.reading(of: "/stash", otherPrimaryTokens: []) == .import(position: 1, literal: "/stash"))
    #expect(OmniStashCommand.reading(of: "/stash /qq what is this", otherPrimaryTokens: ["/qq"]) == .import(position: 1, literal: "/stash"))
    #expect(OmniStashCommand.reading(of: "/stash:3 /qq what", otherPrimaryTokens: ["/qq"]) == .import(position: 3, literal: "/stash:3"))
    #expect(OmniStashCommand.reading(of: "/stash:9", otherPrimaryTokens: []) == .import(position: 9, literal: "/stash:9"))
    #expect(OmniStashCommand.reading(of: "/qq hello", otherPrimaryTokens: ["/qq"]) == .none)
    let composed = try! #require(OmniStashCommand.replacingImport("/stash:2", in: "/stash:2 /qq what does the exec flag do here", with: "find . -type f"))
    #expect(composed.text == "find . -type f /qq what does the exec flag do here")
    #expect(composed.edit == NSRange(location: 0, length: 8))
    #expect(composed.replacementLength == 14)
    // Only a whole atom matches: `/stash:2x` and `a/stash:2` are not the import.
    #expect(OmniStashCommand.range(of: "/stash:2", in: "/stash:2x a/stash:2 /stash:2") == NSRange(location: 20, length: 8))
    #expect(OmniStashCommand.removingImport("/stash:3", from: "/stash:3 /qq hi") == "/qq hi")
    #expect(OmniStashCommand.removingImport("/stash", from: "/stash") == "")
}

@Test func receiptWordingFollowsTheSummary() {
    #expect(OmniStashReceipt.wording(summary: "Stashed") == "stashed")
    #expect(OmniStashReceipt.wording(summary: "Stashed · oldest dropped") == "stashed · oldest dropped")
    #expect(OmniStashReceipt.wording(summary: nil) == "stashed")
}
