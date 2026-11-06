import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

private let branch = RecallCommand(category: "git", command: "git branch --show-current",
    label: "current branch", note: "repo root or subdir")
private let lastCommit = RecallCommand(category: "git", command: "git log -1 --oneline",
    label: "last commit", note: "compact head check")
private let process = RecallCommand(category: "mac-process", command: "pgrep -fl <name>",
    label: "find pid and command", note: "cleaner process search")
private let generated = RecallCommand(category: "git", command: "git reset --soft HEAD~1",
    label: "undo commit, keep staged", note: "changes stay in the index")

private actor RecallGeneratorProbe {
    private var continuation: CheckedContinuation<[RecallCommand], Never>?
    private(set) var started = 0

    func run(_ query: String, _ sheet: [RecallCommand]) async -> [RecallCommand] {
        started += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ rows: [RecallCommand]) {
        continuation?.resume(returning: rows)
        continuation = nil
    }
}

@MainActor private func waitForRecall(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await predicate())
}

@Suite(.serialized) struct OmniRecallTests {
    @Test @MainActor func emptySheetIsGroupedAndStrongHitNeverStartsGenerator() async throws {
        _ = NSApplication.shared
        let probe = RecallGeneratorProbe()
        let session = OmniRecallSession(commands: [branch, process, lastCommit], debounce: .milliseconds(5),
            generator: { query, sheet in await probe.run(query, sheet) }, add: { _, _ in true }, undo: { true })
        session.open()
        #expect(session.rows.map(\.command.command) == [branch.command, lastCommit.command, process.command])
        #expect(session.selectedIndex == 0)
        #expect(session.selectedCommand == branch.command)
        #expect(!session.isGenerating)

        session.inputChanged("which branch am I on")
        #expect(session.sheetRows.first == branch)
        #expect(!session.isGenerating)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.started == 0)
        session.close()
    }

    @Test @MainActor func thinQueryGeneratesAfterDebounceAndStaleOutputIsIgnored() async throws {
        _ = NSApplication.shared
        let probe = RecallGeneratorProbe()
        let session = OmniRecallSession(commands: [branch, lastCommit], debounce: .milliseconds(20),
            generator: { query, sheet in await probe.run(query, sheet) }, add: { _, _ in true }, undo: { true })
        session.open(input: "undo last commit but keep changes")
        #expect(session.isGenerating)
        #expect(session.generatedRows.isEmpty)
        try await waitForRecall { await probe.started == 1 }
        session.inputChanged("which branch am I on")
        #expect(!session.isGenerating)
        await probe.finish([generated])
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.generatedRows.isEmpty)
        #expect(session.selectedCommand == branch.command)

        session.inputChanged("undo last commit but keep changes")
        try await waitForRecall { await probe.started == 2 }
        await probe.finish([generated])
        try await waitForRecall { session.generatedRows == [generated] }
        #expect(session.selectedRow?.origin == .generated)
        #expect(session.selectedCommand == generated.command)
        session.close()
    }

    @Test @MainActor func currentRecallCancellationExitsGenerating() async throws {
        let session = OmniRecallSession(commands: [], debounce: .zero,
            generator: { _, _ in throw CancellationError() }, add: { _, _ in true }, undo: { true })
        session.open(input: "undo last commit but keep changes")
        try await waitForRecall { !session.isGenerating }
        #expect(session.error == "Could not suggest a command. Sheet matches are still available.")
        #expect(session.generatedRows.isEmpty)
        session.close()
    }

    @Test @MainActor func addUndoAndNextKeyExpiryArePrecise() async throws {
        _ = NSApplication.shared
        let probe = RecallGeneratorProbe()
        var written: [(String, String)] = []
        var undoCount = 0
        let session = OmniRecallSession(commands: [lastCommit], debounce: .milliseconds(1),
            generator: { query, sheet in await probe.run(query, sheet) },
            add: { command, intent in written.append((command.command, intent)); return true },
            undo: { undoCount += 1; return true })
        let query = "undo last commit but keep changes"
        session.open(input: query)
        try await waitForRecall { await probe.started == 1 }
        await probe.finish([generated])
        try await waitForRecall { session.selectedRow?.origin == .generated }
        #expect(session.addSelectedToSheet())
        try await waitForRecall { !session.isSaving }
        #expect(session.selectedRow?.origin == .sheet)
        #expect(session.sheetRows.first?.command == generated.command)
        #expect(session.generatedRows.isEmpty)
        #expect(session.canUndoAdd)
        #expect(session.notice == "Added to Sheet · git")
        #expect(written.first?.0 == generated.command)
        #expect(written.first?.1 == query)
        #expect(session.undoAdd())
        try await waitForRecall { !session.isSaving }
        #expect(undoCount == 1)
        #expect(session.selectedRow?.origin == .generated)
        #expect(!session.canUndoAdd)

        #expect(session.addSelectedToSheet())
        try await waitForRecall { !session.isSaving }
        session.moveSelection(by: 1)
        #expect(!session.canUndoAdd)
        #expect(session.notice == nil)
        #expect(!session.undoAdd())
        session.close()
    }

    @Test @MainActor func canonicalReloadPreventsDuplicateRowsAndKeepsSourceMetadata() async throws {
        let canonical = RecallCommand(category: "saved-category", command: generated.command,
            label: "existing title", note: "existing note", intentAliases: ["unmatched intent"])
        var stored = [lastCommit, canonical]
        let session = OmniRecallSession(commands: [lastCommit], debounce: .milliseconds(1),
            generator: { _, _ in [generated] }, add: { _, _ in true },
            undo: { stored = [lastCommit]; return true }, reload: { stored })
        session.open(input: "unmatched intent")
        try await waitForRecall { !session.generatedRows.isEmpty }
        #expect(session.addSelectedToSheet())
        try await waitForRecall { !session.isSaving }
        #expect(session.commands.filter { $0.command == generated.command }.count == 1)
        #expect(session.selectedRow?.command == canonical)
        #expect(session.notice == "Added to Sheet · saved-category")
        #expect(session.undoAdd())
        try await waitForRecall { !session.isSaving }
        #expect(session.commands == [lastCommit])
        session.close()
    }

    @Test @MainActor func successfulWritesKeepUndoWhenRefreshFails() async throws {
        var saved = false
        let session = OmniRecallSession(commands: [], debounce: .milliseconds(1),
            generator: { _, _ in [generated] },
            add: { _, _ in saved = true; return true },
            undo: { saved = false; return true },
            reload: { throw EphemeralToolFailure("fixture read failed") })
        session.open(input: "new intent")
        try await waitForRecall { session.canAddSelected }
        #expect(session.addSelectedToSheet())
        try await waitForRecall { !session.isSaving }
        #expect(saved && session.canUndoAdd)
        #expect(session.error == nil)
        #expect(session.notice?.contains("Added to Sheet") == true)
        #expect(session.notice?.contains("refresh unavailable") == true)
        #expect(session.undoAdd())
        try await waitForRecall { !session.isSaving }
        #expect(!saved && !session.canUndoAdd)
        #expect(session.error == nil)
        #expect(session.notice?.contains("Removed from Sheet") == true)
        session.close()
    }

    @Test @MainActor func staleFailedSaveRefreshesTheCurrentAddHint() async throws {
        var completion: CheckedContinuation<Bool, Error>?
        let session = OmniRecallSession(commands: [], debounce: .milliseconds(1),
            generator: { _, _ in [generated] },
            add: { _, _ in try await withCheckedThrowingContinuation { completion = $0 } },
            undo: { false })
        var lastCanAdd = false
        session.onChange = { lastCanAdd = session.canAddSelected }
        session.open(input: "first unmatched intent")
        try await waitForRecall { session.canAddSelected }
        #expect(session.addSelectedToSheet())
        try await waitForRecall { completion != nil }
        session.inputChanged("another unmatched intent")
        try await waitForRecall { !session.generatedRows.isEmpty }
        #expect(!lastCanAdd)
        completion?.resume(throwing: EphemeralToolFailure("fixture failure"))
        try await waitForRecall { !session.isSaving }
        #expect(lastCanAdd)
        #expect(session.error == nil)
        session.close()
        session.onChange = nil
    }

    @Test @MainActor func nativeRowsFooterAndCopyCloseReflectSelection() throws {
        _ = NSApplication.shared
        let session = OmniRecallSession(commands: [branch, process, lastCommit],
            generator: { _, _ in [] }, add: { _, _ in true }, undo: { true })
        let window = OmniRecallWindowController(session: session, presentsInterface: false)
        var copied: [String] = []
        window.onCopy = { copied.append($0) }
        window.show()
        let view = window.viewController
        #expect(view.routeLabel.stringValue == "Sheet · 3 commands")
        #expect(descendants(of: view.view).compactMap { $0 as? OmniToolPillView }.count == 1)
        #expect(view.toolPill.title == "Recall")
        #expect(view.toolPill.frame.maxX == view.view.bounds.width - 18)
        #expect(view.keyHintsView.hints == [.init("↩", "Copy and close"), .init("esc", "Close")])
        #expect(view.view.subviews.contains { $0.accessibilityIdentifier() == "omni.recall.results" })
        #expect(view.view.subviews.contains { $0.accessibilityIdentifier() == "omni.recall.result-fade" })
        let firstRow = try #require(descendants(of: view.view).first {
            $0.accessibilityIdentifier() == "omni.recall.row.0"
        })
        let labels = firstRow.subviews.compactMap { $0 as? NSTextField }
        #expect(labels.count == 4)
        #expect(labels[0].frame.width == 92)
        #expect(labels[0].stringValue == "GIT")
        #expect(firstRow.isFlipped)
        #expect(labels[1].frame.maxY <= labels[2].frame.minY)
        #expect(labels[1].attributedStringValue.attribute(.font, at: 0,
            effectiveRange: nil) as? NSFont == NSFont.monospacedSystemFont(ofSize: 14.5, weight: .regular))
        #expect(view.view.bounds.width == OmniPadPlacement.width)
        #expect(view.view.bounds.height > 100)
        capture(view.view, "empty")
        session.moveSelection(by: 1)
        #expect(session.selectedCommand == lastCommit.command)
        window.copyCurrentSelection()
        #expect(copied == [lastCommit.command])
        #expect(!session.isOpen)
    }

    @Test @MainActor func longSheetScrollsUnderFadeAndGeneratedRowsGetHairline() async throws {
        _ = NSApplication.shared
        let many = (0..<15).map { number in
            RecallCommand(category: "git", command: "git show HEAD~\(number)",
                label: "show commit \(number)", note: "history")
        }
        let probe = RecallGeneratorProbe()
        let session = OmniRecallSession(commands: many, debounce: .milliseconds(1),
            generator: { query, sheet in await probe.run(query, sheet) },
            add: { _, _ in true }, undo: { true })
        let window = OmniRecallWindowController(session: session, presentsInterface: false)
        window.show()
        let view = window.viewController.view
        let scroll = try #require(descendants(of: view).first {
            $0.accessibilityIdentifier() == "omni.recall.results"
        } as? NSScrollView)
        let fade = try #require(descendants(of: view).first {
            $0.accessibilityIdentifier() == "omni.recall.result-fade"
        })
        #expect(scroll.documentView?.frame.height ?? 0 > scroll.contentView.bounds.height)
        #expect(!fade.isHidden)
        capture(view, "long-sheet")

        session.inputChanged("undo last commit but keep changes")
        try await waitForRecall { await probe.started == 1 }
        await probe.finish([generated])
        try await waitForRecall { session.generatedRows == [generated] }
        #expect(descendants(of: view).contains {
            $0.accessibilityIdentifier() == "omni.recall.generated-divider"
        })
        #expect(session.selectedRow?.origin == .generated)
        #expect(fade.isHidden)
        capture(view, "generated")
        #expect(session.addSelectedToSheet())
        try await waitForRecall { !session.isSaving }
        #expect(session.selectedRow?.origin == .sheet)
        capture(view, "added")
        session.inputChanged("show commit 4")
        capture(view, "filtered")
        window.dismiss()
    }

    @Test @MainActor func longQueryWrapsBelowTheRecallPill() throws {
        _ = NSApplication.shared
        let session = OmniRecallSession(commands: [branch], generator: { _, _ in [] },
            add: { _, _ in true }, undo: { true })
        let window = OmniRecallWindowController(session: session, presentsInterface: false)
        window.show()
        session.inputChanged(String(repeating: "a longer recall query with several descriptive words ", count: 5))
        let view = window.viewController
        let inputScroll = try #require(view.editor.enclosingScrollView)
        #expect(inputScroll.frame.height > 25)
        #expect(view.editor.textContainer.map { view.editor.layoutManager?.usedRect(for: $0).height ?? 0 } ?? 0 > 25)
        #expect(view.toolPill.frame.maxX == view.view.bounds.width - 18)
        capture(view.view, "long-query")
        window.dismiss()
    }

    @MainActor private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor private func capture(_ view: NSView, _ name: String) {
        guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            OmniNativeCaptureHarness.prepare(view, scenario: .longEditor,
                treatment: .opaqueFallback, appearance: appearance)
            let image = OmniNativeCaptureHarness.image(of: view)
            guard let bitmap = image.representations.first as? NSBitmapImageRep,
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: directory.appendingPathComponent("recall-\(name)-\(appearance.rawValue).png"))
        }
    }
}
