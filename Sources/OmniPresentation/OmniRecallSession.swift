import Foundation
import OmniCore

public enum OmniRecallOrigin: Sendable, Equatable {
    case sheet
    case generated
}

public struct OmniRecallRow: Sendable, Equatable {
    public let command: RecallCommand
    public let origin: OmniRecallOrigin

    public init(command: RecallCommand, origin: OmniRecallOrigin) {
        self.command = command
        self.origin = origin
    }
}

/// A sheet-first interaction. Each edit invalidates the debounce and any late
/// model completion, including providers that do not cooperate with cancellation.
@MainActor
public final class OmniRecallSession {
    public typealias Generator = @Sendable (String, [RecallCommand]) async throws -> [RecallCommand]
    public typealias Add = @MainActor (RecallCommand, String) async throws -> Bool
    public typealias Undo = @MainActor () async throws -> Bool
    public typealias Reload = @MainActor () async throws -> [RecallCommand]

    public var onChange: (@MainActor () -> Void)?
    public private(set) var input = ""
    public private(set) var commands: [RecallCommand]
    public private(set) var sheetRows: [RecallCommand] = []
    public private(set) var generatedRows: [RecallCommand] = []
    public private(set) var selectedIndex: Int? = nil
    public private(set) var isGenerating = false
    public var canGenerateManually: Bool {
        isOpen && !automaticRequestsEnabled() && !isGenerating && input.count <= 4_096
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && RecallMatcher.search(input, in: commands).shouldGenerate
    }
    public private(set) var isSaving = false
    public private(set) var isOpen = false
    public private(set) var notice: String?
    public private(set) var error: String?

    public var rows: [OmniRecallRow] {
        sheetRows.map { OmniRecallRow(command: $0, origin: .sheet) }
            + generatedRows.map { OmniRecallRow(command: $0, origin: .generated) }
    }

    public var selectedRow: OmniRecallRow? {
        guard let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    public var selectedCommand: String? { isOpen ? selectedRow?.command.command : nil }
    public var canAddSelected: Bool { isOpen && !isSaving && selectedRow?.origin == .generated }
    public var canUndoAdd: Bool { isOpen && !isSaving && undoSnapshot != nil }

    private let generator: Generator
    private let automaticRequestsEnabled: @MainActor () -> Bool
    private var lastAutomaticRequestsEnabled: Bool
    private let add: Add
    private let undo: Undo
    private let reload: Reload?
    private let debounce: Duration
    private let initialNotice: String?
    private var revision: UInt64 = 0
    private var work: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var undoSnapshot: (stored: RecallCommand, generated: RecallCommand, generatedIndex: Int, previous: RecallCommand?)?

    public init(
        commands: [RecallCommand],
        debounce: Duration = .milliseconds(350),
        initialNotice: String? = nil,
        automaticRequestsEnabled: @escaping @MainActor () -> Bool = { true },
        generator: @escaping Generator,
        add: @escaping Add,
        undo: @escaping Undo,
        reload: Reload? = nil
    ) {
        self.commands = commands
        self.debounce = debounce
        self.initialNotice = initialNotice
        self.generator = generator
        self.automaticRequestsEnabled = automaticRequestsEnabled
        lastAutomaticRequestsEnabled = automaticRequestsEnabled()
        self.add = add
        self.undo = undo
        self.reload = reload
    }

    public func open(input: String = "", notice: String? = nil) {
        invalidate()
        isOpen = true
        self.input = ""
        generatedRows = []
        self.notice = notice ?? initialNotice
        error = nil
        undoSnapshot = nil
        inputChanged(input, preservingNotice: true)
    }

    public func close() {
        invalidate()
        isOpen = false
        input = ""
        sheetRows = []
        generatedRows = []
        selectedIndex = nil
        notice = nil
        error = nil
        undoSnapshot = nil
        // A started write is allowed to finish; its revision guard prevents
        // completion from restoring dismissed or edited UI state.
        onChange?()
    }

    public func inputChanged(_ next: String) {
        inputChanged(next, preservingNotice: false)
    }

    private func inputChanged(_ next: String, preservingNotice: Bool, forceGeneration: Bool = false) {
        guard isOpen else { return }
        invalidate()
        input = next
        if !preservingNotice { notice = nil }
        error = nil
        undoSnapshot = nil
        generatedRows = []
        guard next.count <= 4_096 else {
            sheetRows = []
            selectedIndex = nil
            error = "Input is too long. Type less text."
            onChange?()
            return
        }
        let match = RecallMatcher.search(next, in: commands)
        sheetRows = match.sheet
        selectedIndex = sheetRows.isEmpty ? nil : 0
        guard match.shouldGenerate, !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onChange?()
            return
        }
        if !forceGeneration && !automaticRequestsEnabled() { onChange?(); return }
        isGenerating = true
        let requestRevision = revision
        let sheet = commands
        onChange?()
        work = Task { [weak self, generator, debounce] in
            do {
                if !forceGeneration { try await Task.sleep(for: debounce) }
                guard !Task.isCancelled, let self, self.isCurrent(requestRevision) else { return }
                let candidates = try await generator(next, sheet)
                guard !Task.isCancelled, self.isCurrent(requestRevision) else { return }
                self.generatedRows = Array(candidates.prefix(3))
                self.isGenerating = false
                if !self.generatedRows.isEmpty { self.selectedIndex = self.sheetRows.count }
                self.onChange?()
            } catch is CancellationError {
                guard let self, self.isCurrent(requestRevision) else { return }
                self.isGenerating = false
                self.work = nil
                self.error = "Could not suggest a command. Sheet matches are still available."
                self.onChange?()
            } catch {
                guard let self, self.isCurrent(requestRevision) else { return }
                self.isGenerating = false
                self.error = "Could not suggest a command. Sheet matches are still available."
                self.onChange?()
            }
        }
    }

    public func generateNow() {
        guard canGenerateManually else { return }
        inputChanged(input, preservingNotice: true, forceGeneration: true)
    }

    public func refreshAutomaticRequestMode() {
        guard isOpen else { return }
        let enabled = automaticRequestsEnabled()
        guard enabled != lastAutomaticRequestsEnabled else { return }
        lastAutomaticRequestsEnabled = enabled
        if !enabled { if isGenerating { invalidate() }; onChange?() }
        else { inputChanged(input, preservingNotice: true) }
    }

    public func moveSelection(by offset: Int) {
        guard isOpen, !rows.isEmpty else { return }
        notice = nil
        undoSnapshot = nil
        let index = selectedIndex ?? 0
        selectedIndex = max(0, min(rows.count - 1, index + offset))
        onChange?()
    }

    public func select(_ index: Int) {
        guard isOpen, rows.indices.contains(index) else { return }
        selectedIndex = index
        onChange?()
    }

    @discardableResult
    public func addSelectedToSheet() -> Bool {
        guard canAddSelected, let selectedIndex,
              generatedRows.indices.contains(selectedIndex - sheetRows.count) else { return false }
        let generatedIndex = selectedIndex - sheetRows.count
        let selected = generatedRows[generatedIndex]
        let previous = commands.first { $0.command == selected.command }
        let source = previous ?? selected
        let accepted = RecallCommand(category: source.category, command: source.command,
            label: source.label, note: source.note, destructive: source.destructive,
            intentAliases: source.intentAliases + [input])
        let currentRevision = revision
        let intent = input
        isSaving = true
        onChange?()
        saveTask = Task { [weak self, add] in
            do {
                guard try await add(selected, intent) else {
                    self?.finishSave(error: "This command is already in Sheet.", revision: currentRevision)
                    return
                }
                guard let self else { return }
                let refreshed = try? await self.reload?()
                let refreshFailed = self.reload != nil && refreshed == nil
                self.isSaving = false
                if let refreshed { self.commands = refreshed }
                else {
                    self.commands.removeAll { $0.command == accepted.command }
                    self.commands.insert(accepted, at: 0)
                }
                let stored = self.commands.first { $0.command == selected.command } ?? accepted
                guard self.isCurrent(currentRevision) else {
                    if self.isOpen { self.refreshCurrentSheet() }
                    return
                }
            // Keep this transaction visible immediately. The corpus writer
            // persists the intent alias for subsequent openings.
                self.sheetRows.removeAll { $0.command == stored.command }
                self.sheetRows.insert(stored, at: 0)
                self.generatedRows.remove(at: generatedIndex)
                self.selectedIndex = 0
                self.undoSnapshot = (stored, selected, generatedIndex, previous)
                self.notice = "Added to Sheet · \(stored.category)" + (refreshFailed ? " · refresh unavailable" : "")
                self.error = nil
                self.onChange?()
            } catch {
                self?.finishSave(error: "Could not add this command to Sheet.", revision: currentRevision)
            }
        }
        return true
    }

    @discardableResult
    public func undoAdd() -> Bool {
        guard canUndoAdd, let undoSnapshot else { return false }
        let currentRevision = revision
        isSaving = true
        onChange?()
        saveTask = Task { [weak self, undo] in
            do {
                guard try await undo() else {
                    self?.finishSave(error: "Could not undo the Sheet addition.", revision: currentRevision)
                    return
                }
                guard let self else { return }
                let refreshed = try? await self.reload?()
                let refreshFailed = self.reload != nil && refreshed == nil
                self.isSaving = false
                if let refreshed { self.commands = refreshed }
                else {
                    self.commands.removeAll { $0.command == undoSnapshot.stored.command }
                    if let previous = undoSnapshot.previous { self.commands.insert(previous, at: 0) }
                }
                guard self.isCurrent(currentRevision) else {
                    if self.isOpen { self.refreshCurrentSheet() }
                    return
                }
                self.sheetRows = RecallMatcher.search(self.input, in: self.commands).sheet
                self.generatedRows.insert(undoSnapshot.generated,
                at: min(undoSnapshot.generatedIndex, generatedRows.count))
                self.selectedIndex = self.sheetRows.count + min(undoSnapshot.generatedIndex, self.generatedRows.count - 1)
                self.undoSnapshot = nil
                self.notice = "Removed from Sheet" + (refreshFailed ? " · refresh unavailable" : "")
                self.error = nil
                self.onChange?()
            } catch {
                self?.finishSave(error: "Could not undo the Sheet addition.", revision: currentRevision)
            }
        }
        return true
    }

    private func finishSave(error message: String, revision candidate: UInt64) {
        isSaving = false
        guard isOpen else { return }
        if isCurrent(candidate) { error = message }
        onChange?()
    }

    private func refreshCurrentSheet() {
        let selected = selectedCommand
        sheetRows = RecallMatcher.search(input, in: commands).sheet
        generatedRows.removeAll { generated in commands.contains { $0.command == generated.command } }
        selectedIndex = selected.flatMap { command in rows.firstIndex { $0.command.command == command } }
            ?? (rows.isEmpty ? nil : 0)
        onChange?()
    }

    private func isCurrent(_ candidate: UInt64) -> Bool { isOpen && revision == candidate }

    private func invalidate() {
        revision &+= 1
        work?.cancel()
        work = nil
        isGenerating = false
    }
}
