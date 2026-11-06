import Foundation
import OmniCore

/// Disposable Regex state. Only an explicit sheet addition reaches a writer.
@MainActor
public final class OmniRegexSession {
    public typealias Generator = @Sendable (String) async throws -> RegexGeneratedPattern
    public typealias Add = @MainActor (RegexSheetEntry, String) async throws -> Bool
    public typealias Undo = @MainActor () async throws -> Bool
    public typealias Reload = @MainActor () async throws -> [RegexSheetEntry]

    public var onChange: (@MainActor () -> Void)?
    public private(set) var input = ""
    public private(set) var selection: String?
    public private(set) var entries: [RegexSheetEntry]
    public private(set) var sheetRows: [RegexSheetEntry] = []
    public private(set) var generated: RegexGeneratedPattern?
    public private(set) var selectedIndex: Int?
    public private(set) var classification: RegexInputClassification = .prose
    public private(set) var analysis: RegexAnalysis?
    public private(set) var selectionMatches: RegexSelectionMatches?
    public private(set) var exampleEvaluation: RegexExampleEvaluation?
    public private(set) var isGenerating = false
    public var canGenerateManually: Bool {
        isOpen && !automaticRequestsEnabled() && !isGenerating && !isReadMode
            && input.count <= 4_096
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && RegexSheetMatcher.search(input, in: entries).shouldGenerate
    }
    public private(set) var isAnalyzing = false
    public private(set) var isSaving = false
    public private(set) var isOpen = false
    public private(set) var notice: String?
    public private(set) var error: String?

    public var isReadMode: Bool { classification != .prose }
    public var inputIsPattern: Bool { classification == .pattern }
    public var rowCount: Int { sheetRows.count + (generated == nil ? 0 : 1) }
    public var generatedIsSelected: Bool { generated != nil && selectedIndex == sheetRows.count }
    public var canAddSelected: Bool { isOpen && !isSaving && !isAnalyzing && generatedIsSelected && analysis != nil && analysis?.compileFailure == nil }
    public var canUndoAdd: Bool { isOpen && !isSaving && undoEntry != nil }
    public var selectedPattern: String? {
        guard isOpen else { return nil }
        if isReadMode { return input.isEmpty ? nil : input }
        if generatedIsSelected { return generated?.pattern }
        guard let selectedIndex, sheetRows.indices.contains(selectedIndex) else { return nil }
        return sheetRows[selectedIndex].pattern
    }
    public var failure: String? {
        error ?? analysis?.compileFailure ?? analysis?.parseFailure ?? selectionMatches?.matchFailure
            ?? exampleEvaluation?.compileError ?? (exampleEvaluation?.timedOut == true ? "Example checking stopped after time limit" : nil)
    }
    public var summary: String {
        if let notice { return notice }
        if isReadMode, let analysis {
            if analysis.compileFailure != nil { return "ICU" }
            var parts = ["\(analysis.groupCount) \(analysis.groupCount == 1 ? "group" : "groups")"]
            if analysis.metadataIsReliable { parts.append(analysis.anchored ? "anchored" : "unanchored") }
            parts += ["ICU"] + (analysis.metadataIsReliable ? analysis.flagsSummary : [])
            if analysis.diagramStatus == .tooLong { parts += ["no diagram", "too long"] }
            return parts.joined(separator: " · ")
        }
        if generatedIsSelected {
            var text = "Sheet · Provider"
            if let evaluation = exampleEvaluation {
                let failures = evaluation.disagreementCount
                if failures > 0 { text += " · \(failures) \(failures == 1 ? "example fails" : "examples fail")" }
            }
            if analysis?.diagramStatus == .tooLong { text += " · no diagram · too long" }
            return text
        }
        return input.isEmpty ? "Sheet · \(entries.count) patterns · ICU" : "Sheet"
    }

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
    private var analysisWork: Task<Void, Never>?
    private var projectionRevision: UInt64 = 0
    private var saveTask: Task<Void, Never>?
    private var undoEntry: (entry: RegexSheetEntry, generated: RegexGeneratedPattern, previous: RegexSheetEntry?)?

    public init(entries: [RegexSheetEntry], debounce: Duration = .milliseconds(350), initialNotice: String? = nil,
                automaticRequestsEnabled: @escaping @MainActor () -> Bool = { true },
                generator: @escaping Generator, add: @escaping Add, undo: @escaping Undo, reload: Reload? = nil) {
        self.entries = entries
        self.debounce = debounce
        self.initialNotice = initialNotice
        self.generator = generator
        self.automaticRequestsEnabled = automaticRequestsEnabled
        lastAutomaticRequestsEnabled = automaticRequestsEnabled()
        self.add = add
        self.undo = undo
        self.reload = reload
    }

    public func open(input: String = "", selection: String? = nil, notice: String? = nil) {
        invalidate()
        isOpen = true
        self.selection = selection.flatMap { $0.isEmpty ? nil : $0 }
        self.notice = notice ?? initialNotice
        undoEntry = nil
        inputChanged(input, preservingNotice: true)
    }

    public func close() {
        invalidate()
        isOpen = false
        input = ""
        selection = nil
        sheetRows = []
        generated = nil
        selectedIndex = nil
        classification = .prose
        analysis = nil
        selectionMatches = nil
        exampleEvaluation = nil
        notice = nil
        error = nil
        undoEntry = nil
        onChange?()
    }

    public func clearSelection() {
        selection = nil
        selectionMatches = nil
        onChange?()
    }

    public func inputChanged(_ next: String) { inputChanged(next, preservingNotice: false) }

    private func inputChanged(_ next: String, preservingNotice: Bool, forceGeneration: Bool = false) {
        guard isOpen else { return }
        invalidate()
        input = next
        if !preservingNotice { notice = nil }
        error = nil
        undoEntry = nil
        generated = nil
        analysis = nil
        selectionMatches = nil
        exampleEvaluation = nil
        sheetRows = []
        selectedIndex = nil
        guard next.count <= 4_096 else {
            classification = .prose
            error = "Input is too long. Type less text."
            onChange?()
            return
        }
        classification = RegexInputClassification.classify(next)
        if isReadMode {
            analyze(pattern: next, revision: revision, selection: selection)
            return
        }
        let match = RegexSheetMatcher.search(next, in: entries)
        sheetRows = match.sheet
        selectedIndex = sheetRows.isEmpty ? nil : 0
        guard match.shouldGenerate, !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !next.isEmpty, let selected = sheetRows.first {
                analyze(pattern: selected.pattern, revision: revision, selection: selection)
                return
            }
            onChange?()
            return
        }
        if !forceGeneration && !automaticRequestsEnabled() { onChange?(); return }
        isGenerating = true
        let current = revision
        onChange?()
        work = Task { [weak self, generator, debounce] in
            do {
                if !forceGeneration { try await Task.sleep(for: debounce) }
                let value = try await generator(next)
                try Task.checkCancellation()
                guard let self, self.isCurrent(current) else { return }
                self.generated = value
                self.selectedIndex = self.sheetRows.count
                self.isGenerating = false
                self.analyze(pattern: value.pattern, revision: current, selection: nil)
            } catch is CancellationError {
                guard let self, self.isCurrent(current) else { return }
                self.isGenerating = false
                self.work = nil
                self.error = "The selected provider could not write a pattern. Edit the intent to try again."
                self.onChange?()
            } catch {
                guard let self, self.isCurrent(current) else { return }
                self.isGenerating = false
                self.error = (error as? EphemeralToolFailure)?.userMessage ?? "The selected provider could not write a pattern. Edit the intent to try again."
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

    private func analyze(pattern: String, revision current: UInt64, selection: String?) {
        isAnalyzing = true
        analysis = nil
        selectionMatches = nil
        exampleEvaluation = nil
        projectionRevision &+= 1
        let projection = projectionRevision
        analysisWork?.cancel()
        onChange?()
        let generated = generatedIsSelected ? self.generated : nil
        analysisWork = Task { [weak self] in
            let result = await Task.detached {
                let analysis = RegexAnalysis(pattern: pattern)
                let matches = selection.map { RegexSelectionMatches.evaluate(pattern: pattern, selection: $0) }
                return (analysis, matches, generated?.evaluateExamples())
            }.value
            guard let self, !Task.isCancelled, self.isCurrent(current), self.projectionRevision == projection else { return }
            self.analysis = result.0
            self.selectionMatches = self.selection == nil ? nil : result.1
            self.exampleEvaluation = result.2
            self.isAnalyzing = false
            self.onChange?()
        }
    }

    public func moveSelection(by offset: Int) {
        guard isOpen, !isReadMode, rowCount > 0 else { return }
        selectedIndex = max(0, min(rowCount - 1, (selectedIndex ?? 0) + offset))
        analyzeSelectedRow()
        onChange?()
    }

    public func select(_ index: Int) {
        guard isOpen, !isReadMode, (0..<rowCount).contains(index) else { return }
        selectedIndex = index
        analyzeSelectedRow()
        onChange?()
    }

    private func analyzeSelectedRow() {
        if generatedIsSelected, let generated {
            analyze(pattern: generated.pattern, revision: revision, selection: nil)
            return
        }
        guard !input.isEmpty, let selectedIndex, sheetRows.indices.contains(selectedIndex) else { return }
        analyze(pattern: sheetRows[selectedIndex].pattern, revision: revision, selection: selection)
    }

    @discardableResult public func addSelectedToSheet() -> Bool {
        guard canAddSelected, let generated else { return false }
        let entry = RegexSheetEntry(name: generated.name, pattern: generated.pattern, note: generated.note ?? "")
        let current = revision
        let intent = input
        let previous = entries.first { $0.pattern == entry.pattern }
        isSaving = true
        onChange?()
        saveTask = Task { [weak self, add] in
            do {
                guard try await add(entry, intent) else {
                    self?.finishSave(error: "This pattern is already in Sheet.", revision: current)
                    return
                }
                guard let self else { return }
                let refreshed = try? await self.reload?()
                let accepted = RegexSheetEntry(name: previous?.name ?? entry.name, pattern: entry.pattern,
                    note: previous?.note ?? entry.note, intentAliases: (previous?.intentAliases ?? entry.intentAliases) + [intent])
                self.entries = refreshed ?? ([accepted] + self.entries.filter { $0.pattern != entry.pattern })
                self.isSaving = false
                guard self.isCurrent(current) else { self.refreshSheet(); return }
                self.sheetRows.removeAll { $0.pattern == entry.pattern }
                self.sheetRows.insert(self.entries.first { $0.pattern == entry.pattern } ?? accepted, at: 0)
                self.generated = nil
                self.analysis = nil
                self.exampleEvaluation = nil
                self.selectedIndex = 0
                self.undoEntry = (entry, generated, previous)
                self.notice = "Added to sheet ⌘Z"
                self.analyzeSelectedRow()
                self.onChange?()
            } catch { self?.finishSave(error: "Could not add this pattern to Sheet.", revision: current) }
        }
        return true
    }

    @discardableResult public func undoAdd() -> Bool {
        guard canUndoAdd, let saved = undoEntry else { return false }
        let current = revision
        isSaving = true
        onChange?()
        saveTask = Task { [weak self, undo] in
            do {
                guard try await undo() else {
                    self?.finishSave(error: "Could not undo the Sheet addition.", revision: current)
                    return
                }
                guard let self else { return }
                let refreshed = try? await self.reload?()
                self.entries = refreshed ?? self.entries.filter { $0.pattern != saved.entry.pattern }
                if refreshed == nil, let previous = saved.previous { self.entries.insert(previous, at: 0) }
                self.isSaving = false
                guard self.isCurrent(current) else { self.refreshSheet(); return }
                self.sheetRows = RegexSheetMatcher.search(self.input, in: self.entries).sheet
                self.generated = saved.generated
                self.selectedIndex = self.sheetRows.count
                self.undoEntry = nil
                self.notice = "Removed from sheet"
                self.analyze(pattern: saved.generated.pattern, revision: current, selection: nil)
            } catch { self?.finishSave(error: "Could not undo the Sheet addition.", revision: current) }
        }
        return true
    }

    private func refreshSheet() {
        guard isOpen, !isReadMode else { return }
        let previousPattern = selectedPattern
        sheetRows = RegexSheetMatcher.search(input, in: entries).sheet
        let patterns = sheetRows.map(\.pattern) + (generated.map { [$0.pattern] } ?? [])
        selectedIndex = previousPattern.flatMap { patterns.firstIndex(of: $0) } ?? (patterns.isEmpty ? nil : 0)
        if !input.isEmpty { analyzeSelectedRow() }
        else { analysis = nil; selectionMatches = nil; exampleEvaluation = nil }
        onChange?()
    }
    private func finishSave(error message: String, revision current: UInt64) {
        isSaving = false
        guard isOpen else { return }
        if isCurrent(current) { error = message }
        onChange?()
    }
    private func isCurrent(_ value: UInt64) -> Bool { isOpen && revision == value }
    private func invalidate() {
        revision &+= 1
        work?.cancel()
        analysisWork?.cancel()
        projectionRevision &+= 1
        work = nil
        analysisWork = nil
        isGenerating = false
        isAnalyzing = false
    }
}
