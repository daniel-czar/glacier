import Foundation
import OmniAdapters
import OmniCore
import Testing

@Test func freshAppRecallSheetHasOfflineCopyOnlyCommandsAndSupportsSaveUndo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-recall-seed-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let sheet = root.appendingPathComponent("recall/command-reference.json")
    #expect(try RecallCorpusStore.seedIfMissing(at: sheet))
    let store = RecallCorpusStore(url: sheet)
    let seeded = try store.load()
    #expect(seeded.map(\.command) == ["pwd", "git status --short", "git diff --", "find . -maxdepth 1 -type f"])
    #expect(seeded.allSatisfy { !$0.destructive })
    #expect(RecallMatcher.search("what changed", in: seeded).sheet.contains { $0.command == "git status --short" })

    let saved = RecallCommand(category: "Git", command: "git log -1 --oneline", label: "Latest commit")
    #expect(try store.add(saved, intent: "latest commit"))
    #expect(try store.load().contains { $0.command == saved.command })
    #expect(try store.undoLastAdd())
    #expect(try store.load() == seeded)
    let before = try Data(contentsOf: sheet)
    #expect(try !RecallCorpusStore.seedIfMissing(at: sheet))
    #expect(try Data(contentsOf: sheet) == before)
}
