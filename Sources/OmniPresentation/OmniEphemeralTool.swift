import Foundation

public enum OmniEphemeralResultStyle: Sendable, Equatable {
    case plain
    case structured
    case drawnConcept
    case pronunciation
    case express
}

public enum OmniEphemeralInteraction: Sendable, Equatable {
    case liveCopy
    case explicitReplay
}

/// A tool's pad abbreviation (quick-launch §1): when the whole field equals `letters`,
/// Tab opens the tool and the key hint names it. The registry is static.
public struct OmniQuickLaunch: Sendable, Equatable {
    public let letters: String
    /// The hint's name, `⇥ Quick answer`; not necessarily the summary title.
    public let title: String
    /// The destination the host opens; it may be a picker outside the ephemeral catalog.
    public let toolID: String

    public init(letters: String, title: String, toolID: String) {
        self.letters = letters
        self.title = title
        self.toolID = toolID
    }
}

/// Presentation configuration for a short-lived Omni tool. A descriptor does
/// not decide how input is produced or where output is sent.
public struct OmniEphemeralToolDescriptor: Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let inputPlaceholder: String
    public let emptyResultHint: String
    public var placeholder: String { inputPlaceholder }
    public let routeTitle: String
    public let routeProviderLabel: String
    public let resultStyle: OmniEphemeralResultStyle
    public let interaction: OmniEphemeralInteraction
    public let maximumInputCharacters: Int
    public let maximumOutputCharacters: Int
    /// Optional deterministic source, allowed to render before any input.
    public let corpusID: String?
    public let debounce: Duration
    /// Two letters that open this tool from the pad by Tab; nil for none.
    public let abbreviation: String?
    public let abbreviationTitle: String
    public var shortcutLabel: String?

    public var quickLaunch: OmniQuickLaunch? {
        abbreviation.map { OmniQuickLaunch(letters: $0, title: abbreviationTitle, toolID: id) }
    }

    public init(
        id: String,
        title: String,
        subtitle: String,
        inputPlaceholder: String,
        emptyResultHint: String,
        routeTitle: String? = nil,
        routeProviderLabel: String = "Provider",
        resultStyle: OmniEphemeralResultStyle = .plain,
        interaction: OmniEphemeralInteraction = .liveCopy,
        maximumInputCharacters: Int = 4_096,
        maximumOutputCharacters: Int = 20_000,
        debounce: Duration = .milliseconds(350),
        corpusID: String? = nil,
        abbreviation: String? = nil,
        abbreviationTitle: String? = nil,
        shortcutLabel: String? = nil
    ) {
        self.abbreviation = abbreviation
        self.abbreviationTitle = abbreviationTitle ?? title
        self.shortcutLabel = shortcutLabel
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.inputPlaceholder = inputPlaceholder
        self.emptyResultHint = emptyResultHint
        self.routeTitle = routeTitle ?? title
        self.routeProviderLabel = routeProviderLabel
        self.resultStyle = resultStyle
        self.interaction = interaction
        self.maximumInputCharacters = max(1, maximumInputCharacters)
        self.maximumOutputCharacters = max(1, maximumOutputCharacters)
        self.debounce = debounce
        self.corpusID = corpusID
    }
}

/// The callback receives text deltas. The returned string is the producer's
/// validated, complete output and supersedes accumulated deltas.
public typealias OmniEphemeralProducer = @Sendable (
    _ input: String,
    _ onDelta: @escaping @Sendable (String) async -> Void
) async throws -> String

/// Only explicit user-facing failures may reveal their message in the window.
public struct EphemeralToolFailure: Error, Sendable, Equatable {
    public let userMessage: String

    public init(_ userMessage: String) {
        self.userMessage = userMessage
    }
}

public enum OmniEphemeralPhase: Sendable, Equatable {
    case empty
    case waiting
    case streaming
    case ready
    case failed(String)
}

/// Owns one disposable interaction. The revision invalidates callbacks even
/// when an underlying provider cannot stop immediately after cancellation.
@MainActor
public final class OmniEphemeralSession {
    public let descriptor: OmniEphemeralToolDescriptor
    public var onChange: (@MainActor () -> Void)?

    public private(set) var input = ""
    public private(set) var output = ""
    public private(set) var phase: OmniEphemeralPhase = .empty
    public private(set) var notice: String?
    public private(set) var isOpen = false
    public private(set) var outputIsCurrent = false
    public private(set) var expressOptions: [ExpressOption] = []
    public private(set) var selectedExpressIndex: Int?
    public private(set) var conceptLens: OmniConceptLensProjection?

    public var copyableExpressResult: ExpressResult? {
        guard descriptor.resultStyle == .express, isOpen, outputIsCurrent, phase == .ready else { return nil }
        return OmniExpressProjection.decodeFinal(output)
    }

    public var copyableOutput: String? {
        if descriptor.resultStyle == .express {
            guard let result = copyableExpressResult, let selectedExpressIndex,
                  result.options.indices.contains(selectedExpressIndex) else { return nil }
            return result.options[selectedExpressIndex].phrase
        }
        guard isOpen, !output.isEmpty else { return nil }
        if descriptor.interaction == .explicitReplay, phase == .streaming { return output }
        guard outputIsCurrent, phase == .ready else { return nil }
        if descriptor.resultStyle == .drawnConcept { return conceptLens?.text }
        return output
    }

    public var canSubmit: Bool {
        guard isOpen, (descriptor.interaction == .explicitReplay || isManualMode),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.count <= descriptor.maximumInputCharacters else { return false }
        if descriptor.interaction == .explicitReplay { return phase != .waiting || producerTask == nil }
        switch phase {
        case .empty, .failed: return true
        case .waiting, .streaming, .ready: return false
        }
    }

    public var isManualMode: Bool {
        descriptor.interaction == .liveCopy && !automaticRequestsEnabled()
    }

    private let producer: OmniEphemeralProducer
    private let automaticRequestsEnabled: @MainActor () -> Bool
    private var lastAutomaticRequestsEnabled: Bool
    private var maximumOutputCharacters: Int { descriptor.maximumOutputCharacters }
    private var revision: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var producerTask: Task<Void, Never>?

    public convenience init(descriptor: OmniEphemeralToolDescriptor, producer: @escaping OmniEphemeralProducer) {
        self.init(descriptor: descriptor, producer: producer, automaticRequestsEnabled: { true })
    }

    public init(descriptor: OmniEphemeralToolDescriptor, producer: @escaping OmniEphemeralProducer,
                automaticRequestsEnabled: @escaping @MainActor () -> Bool) {
        self.descriptor = descriptor
        self.producer = producer
        self.automaticRequestsEnabled = automaticRequestsEnabled
        lastAutomaticRequestsEnabled = automaticRequestsEnabled()
    }

    public func open(input: String, notice: String? = nil) {
        invalidateWork()
        isOpen = true
        self.input = ""
        output = ""
        conceptLens = nil
        outputIsCurrent = false
        expressOptions = []
        selectedExpressIndex = nil
        phase = .empty
        self.notice = notice
        inputChanged(input, preservingNotice: true)
    }

    public func inputChanged(_ proposedInput: String) {
        inputChanged(proposedInput, preservingNotice: false)
    }

    /// Explicit tools run only after a deliberate submit. Submitting unchanged
    /// input starts a fresh invocation, which is how Enter replays audio.
    public func submit() {
        guard canSubmit else { return }
        invalidateWork()
        outputIsCurrent = false
        notice = nil
        phase = .waiting
        let currentRevision = revision
        onChange?()
        startProducer(input: input, revision: currentRevision)
    }

    public func close() {
        invalidateWork()
        isOpen = false
        input = ""
        output = ""
        conceptLens = nil
        notice = nil
        outputIsCurrent = false
        expressOptions = []
        selectedExpressIndex = nil
        phase = .empty
        onChange?()
    }

    public func refreshAutomaticRequestMode() {
        guard isOpen, descriptor.interaction == .liveCopy else { return }
        let enabled = automaticRequestsEnabled()
        guard enabled != lastAutomaticRequestsEnabled else { return }
        lastAutomaticRequestsEnabled = enabled
        if isManualMode {
            if phase == .waiting || phase == .streaming {
                invalidateWork()
                output = ""
                conceptLens = nil
                expressOptions = []
                selectedExpressIndex = nil
                outputIsCurrent = false
                phase = .empty
                onChange?()
            } else { onChange?() }
        } else if phase == .empty, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputChanged(input, preservingNotice: true)
        }
    }

    /// Stops an in-flight lookup/playback without closing its editable panel.
    /// An explicit replay after the setting change uses the new request policy.
    public func cancelCurrentRequestPreservingInput() {
        guard isOpen, phase == .waiting || phase == .streaming else { return }
        invalidateWork()
        output = ""
        conceptLens = nil
        expressOptions = []
        selectedExpressIndex = nil
        outputIsCurrent = false
        phase = .empty
        onChange?()
    }

    private func inputChanged(_ proposedInput: String, preservingNotice: Bool) {
        guard isOpen else { return }
        let nextInput = proposedInput
        guard nextInput != input || phase == .empty else { return }
        invalidateWork()
        input = nextInput
        if !preservingNotice { notice = nil }
        outputIsCurrent = false
        selectedExpressIndex = nil

        guard nextInput.count <= descriptor.maximumInputCharacters else {
            output = ""
            conceptLens = nil
            expressOptions = []
            phase = .failed("Input is too long. Select or type less text.")
            onChange?()
            return
        }

        guard !nextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            output = ""
            conceptLens = nil
            expressOptions = []
            phase = .empty
            onChange?()
            return
        }

        if descriptor.interaction == .explicitReplay || isManualMode {
            phase = .empty
            onChange?()
            return
        }

        phase = .waiting
        let currentRevision = revision
        onChange?()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.descriptor.debounce)
            } catch {
                return
            }
            guard !Task.isCancelled, self.isCurrent(currentRevision) else { return }
            self.startProducer(input: nextInput, revision: currentRevision)
        }
    }

    private func startProducer(input: String, revision: UInt64) {
        let producer = self.producer
        producerTask = Task { [weak self] in
            do {
                let completed = try await producer(input) { [weak self] delta in
                    await self?.receive(delta: delta, revision: revision)
                }
                self?.complete(completed, revision: revision)
            } catch is CancellationError {
                // A local edit or close changes the revision. An independently
                // cancelled current request must leave the waiting state.
                self?.fail(EphemeralToolFailure("Unable to complete this request. Try again."), revision: revision)
            } catch {
                self?.fail(error, revision: revision)
            }
        }
    }

    private func receive(delta: String, revision: UInt64) {
        guard isCurrent(revision), !delta.isEmpty else { return }
        // Drawn results mount atomically, even if an injected producer emits deltas.
        guard descriptor.resultStyle != .drawnConcept else { return }
        if phase != .streaming {
            output = ""
            expressOptions = []
            selectedExpressIndex = nil
            phase = .streaming
        }
        guard output.count + delta.count <= maximumOutputCharacters else {
            invalidateWork()
            output = ""
            expressOptions = []
            selectedExpressIndex = nil
            outputIsCurrent = false
            phase = .failed("Result is too long to display.")
            onChange?()
            return
        }
        output += delta
        if descriptor.resultStyle == .express {
            let previous = selectedExpressIndex.flatMap { expressOptions.indices.contains($0) ? expressOptions[$0] : nil }
            expressOptions = OmniExpressProjection.decodeStreaming(output)
            selectedExpressIndex = previous.flatMap { expressOptions.firstIndex(of: $0) }
                ?? expressOptions.firstIndex(where: { $0.group == .close })
                ?? (expressOptions.isEmpty ? nil : 0)
        }
        onChange?()
    }

    private func complete(_ completed: String, revision: UInt64) {
        guard isCurrent(revision) else { return }
        guard completed.count <= maximumOutputCharacters else {
            fail(EphemeralToolFailure("Result is too long to display."), revision: revision)
            return
        }
        guard !completed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(EphemeralToolFailure("No result was returned. Try again."), revision: revision)
            return
        }
        if descriptor.resultStyle == .express {
            guard let result = OmniExpressProjection.decodeFinal(completed) else {
                fail(EphemeralToolFailure("No usable alternatives were returned. Try again."), revision: revision)
                return
            }
            let previous = selectedExpressIndex.flatMap { expressOptions.indices.contains($0) ? expressOptions[$0] : nil }
            expressOptions = result.options
            selectedExpressIndex = previous.flatMap { expressOptions.firstIndex(of: $0) }
                ?? expressOptions.firstIndex(where: { $0.group == .close })
                ?? 0
        }
        if descriptor.resultStyle == .drawnConcept {
            conceptLens = OmniConceptLensProjection.project(completed, input: input)
        }
        output = completed
        outputIsCurrent = true
        phase = .ready
        producerTask = nil
        onChange?()
    }

    private func fail(_ error: Error, revision: UInt64) {
        guard isCurrent(revision) else { return }
        output = ""
        conceptLens = nil
        expressOptions = []
        selectedExpressIndex = nil
        outputIsCurrent = false
        phase = .failed((error as? EphemeralToolFailure)?.userMessage ?? "Unable to complete this request. Try again.")
        producerTask = nil
        onChange?()
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        isOpen && revision == candidate
    }

    public func moveExpressSelection(by offset: Int) {
        guard descriptor.resultStyle == .express, isOpen,
              (phase == .streaming || outputIsCurrent && phase == .ready),
              !expressOptions.isEmpty else { return }
        let current = selectedExpressIndex ?? 0
        selectedExpressIndex = max(0, min(expressOptions.count - 1, current + offset))
        onChange?()
    }

    public func selectExpressOption(at index: Int) {
        guard descriptor.resultStyle == .express, isOpen,
              (phase == .streaming || outputIsCurrent && phase == .ready),
              expressOptions.indices.contains(index) else { return }
        selectedExpressIndex = index
        onChange?()
    }

    private func invalidateWork() {
        revision &+= 1
        debounceTask?.cancel()
        producerTask?.cancel()
        debounceTask = nil
        producerTask = nil
    }
}
