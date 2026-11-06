import Foundation
import OmniCore

/// One complete, validated map per invocation. Retry belongs to the model producer.
public typealias OmniMapProducer = @Sendable (String, OmniMapForm?) async throws -> OmniMapDocument

@MainActor
public final class OmniMapSession {
    public var onChange: (@MainActor () -> Void)?
    public private(set) var input = ""
    public private(set) var isOpen = false
    public private(set) var document: OmniMapDocument?
    public private(set) var phase: OmniEphemeralPhase = .empty
    public private(set) var selectedForm: OmniMapForm?
    public private(set) var outputIsCurrent = false
    public private(set) var failureReason: String?
    public private(set) var notice: String?
    public var parsed: OmniMapParsedInput { OmniMapInput.parse(input, pinnedForm: selectedForm) }
    public var isEmpty: Bool { input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var copyableDocument: OmniMapDocument? { isOpen && outputIsCurrent && phase == .ready ? document : nil }
    public var isManualMode: Bool { !automaticRequestsEnabled() }
    public var canSubmit: Bool {
        guard isOpen, isManualMode, !isEmpty, input.count <= 4_096, parsed.refusal == nil else { return false }
        switch phase {
        case .empty, .failed: return true
        case .waiting, .streaming, .ready: return false
        }
    }
    public var summary: String {
        if let refusal = parsed.refusal { return refusal }
        if failureReason != nil { return "Map · could not draw this map" }
        if let document { return document.form.title + " · " + document.lineMeaning }
        if let selectedForm { return selectedForm.title + " · selected form · type to fill it" }
        return "Map · choose a form or type a question"
    }

    private let producer: OmniMapProducer
    private let debounce: Duration
    private let automaticRequestsEnabled: @MainActor () -> Bool
    private var lastAutomaticRequestsEnabled: Bool
    private var task: Task<Void, Never>?
    private var revision: UInt64 = 0

    public init(producer: @escaping OmniMapProducer, debounce: Duration = .milliseconds(350),
                automaticRequestsEnabled: @escaping @MainActor () -> Bool = { true }) {
        self.producer = producer
        self.debounce = debounce
        self.automaticRequestsEnabled = automaticRequestsEnabled
        lastAutomaticRequestsEnabled = automaticRequestsEnabled()
    }

    public func open(input: String = "", notice: String? = nil) {
        invalidate()
        isOpen = true
        document = nil
        selectedForm = nil
        self.input = ""
        self.notice = notice
        inputChanged(input, preservingNotice: true)
    }

    public func close() {
        invalidate()
        isOpen = false
        input = ""
        document = nil
        selectedForm = nil
        outputIsCurrent = false
        failureReason = nil
        notice = nil
        phase = .empty
        onChange?()
    }

    public func refreshAutomaticRequestMode() {
        guard isOpen else { return }
        let enabled = automaticRequestsEnabled()
        guard enabled != lastAutomaticRequestsEnabled else { return }
        lastAutomaticRequestsEnabled = enabled
        if isManualMode, phase == .waiting {
            invalidate()
            phase = .empty
            failureReason = nil
            onChange?()
        } else if !isManualMode, phase == .empty, !isEmpty {
            inputChanged(input, preservingNotice: true)
        } else { onChange?() }
    }

    public func inputChanged(_ text: String) { inputChanged(text, preservingNotice: false) }

    private func inputChanged(_ text: String, preservingNotice: Bool, immediate: Bool = false,
                              explicit: Bool = false) {
        guard isOpen else { return }
        invalidate()
        input = text
        outputIsCurrent = false
        failureReason = nil
        if !preservingNotice { notice = nil }
        if isEmpty {
            document = nil
            phase = .empty
            onChange?()
            return
        }
        guard text.count <= 4_096 else {
            failureReason = "Input is too long. Select or type less text."
            phase = .failed(failureReason!)
            onChange?()
            return
        }
        guard parsed.refusal == nil else {
            document = nil
            phase = .empty
            onChange?()
            return
        }
        if !explicit && isManualMode {
            phase = .empty
            onChange?()
            return
        }
        phase = .waiting
        let current = revision
        let pinned = selectedForm
        onChange?()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if !immediate { try await Task.sleep(for: self.debounce) }
                guard self.isCurrent(current), !Task.isCancelled else { return }
                let result = try await self.producer(text, pinned)
                guard self.isCurrent(current), !Task.isCancelled else { return }
                self.document = result
                self.outputIsCurrent = true
                self.phase = .ready
                self.task = nil
                self.onChange?()
            } catch is CancellationError {
                guard self.isCurrent(current) else { return }
                let reason = "Map is unavailable. Edit the question to try again."
                self.failureReason = reason
                self.phase = .failed(reason)
                self.task = nil
                self.onChange?()
            } catch {
                guard self.isCurrent(current), !Task.isCancelled else { return }
                let reason: String
                if let validation = error as? OmniMapValidationError {
                    reason = "Map could not be drawn after validation: " + validation.errors.joined(separator: "; ")
                } else if let failure = error as? EphemeralToolFailure {
                    reason = failure.userMessage
                } else {
                    reason = "Map is unavailable. Edit the question to try again."
                }
                self.failureReason = reason
                self.phase = .failed(reason)
                self.task = nil
                self.onChange?()
            }
        }
    }

    public func submit() {
        guard canSubmit else { return }
        inputChanged(input, preservingNotice: false, immediate: true, explicit: true)
    }

    /// Empty chooser arrows select locally. A result never cycles forms by arrow.
    @discardableResult
    public func moveSelection(columns: Int, rows: Int) -> Bool {
        guard isOpen, isEmpty else { return false }
        let forms = OmniMapForm.allCases
        let index = selectedForm.flatMap { forms.firstIndex(of: $0) }
        let next = index.map { max(0, min(forms.count - 1, $0 + columns + rows * 4)) } ?? 0
        selectForm(forms[next])
        return true
    }

    public func selectForm(_ form: OmniMapForm) {
        guard isOpen else { return }
        selectedForm = form
        if isEmpty { onChange?(); return }
        // Keep an explicit mode token truthful when the popover replaces it.
        var nextInput = input
        if let range = OmniMapInput.parse(input).modeRange, let swiftRange = Range(range, in: input) {
            nextInput.replaceSubrange(swiftRange, with: "as " + form.rawValue)
        }
        inputChanged(nextInput, preservingNotice: false, immediate: true)
    }

    private func invalidate() { revision &+= 1; task?.cancel(); task = nil }
    private func isCurrent(_ candidate: UInt64) -> Bool { isOpen && revision == candidate }
}
