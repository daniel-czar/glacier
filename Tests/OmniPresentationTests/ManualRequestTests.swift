import Foundation
import OmniPresentation
import Testing

private actor RequestProbe {
    private(set) var started = 0
    private(set) var cancelled = 0
    func start() { started += 1 }
    func cancel() { cancelled += 1 }
}

@MainActor
@Test func toolPillShowsOnlyRegisteredShortcutLabel() {
    let pill = OmniToolPillView(title: "Translate")
    #expect(pill.title == "Translate")
    pill.shortcutLabel = "⌃⌥T"
    #expect(pill.title == "Translate · ⌃⌥T")
    pill.shortcutLabel = nil
    #expect(pill.title == "Translate")
}

@MainActor
@Test func manualEphemeralInputDoesNotDispatchUntilSubmit() async {
    let probe = RequestProbe()
    let descriptor = OmniEphemeralToolDescriptor(
        id: "manual-test", title: "Manual", subtitle: "", inputPlaceholder: "",
        emptyResultHint: "", debounce: .milliseconds(1))
    let session = OmniEphemeralSession(descriptor: descriptor, producer: { _, _ in
        await probe.start()
        return "answer"
    }, automaticRequestsEnabled: { false })
    session.open(input: "question")
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await probe.started == 0)
    #expect(session.isManualMode)
    #expect(session.canSubmit)
    session.submit()
    for _ in 0..<100 {
        if session.phase == .ready { break }
        await Task.yield()
    }
    #expect(await probe.started == 1)
    #expect(session.copyableOutput == "answer")
    #expect(!session.canSubmit)
}

@MainActor
@Test func closingManualToolCancelsItsExplicitRequest() async {
    let probe = RequestProbe()
    let descriptor = OmniEphemeralToolDescriptor(
        id: "manual-test", title: "Manual", subtitle: "", inputPlaceholder: "",
        emptyResultHint: "")
    let session = OmniEphemeralSession(descriptor: descriptor, producer: { _, _ in
        await probe.start()
        do { try await Task.sleep(for: .seconds(10)) }
        catch { await probe.cancel(); throw error }
        return "late"
    }, automaticRequestsEnabled: { false })
    session.open(input: "question")
    session.submit()
    for _ in 0..<100 {
        if await probe.started > 0 { break }
        await Task.yield()
    }
    #expect(await probe.started == 1)
    session.close()
    for _ in 0..<100 {
        if await probe.cancelled > 0 { break }
        await Task.yield()
    }
    #expect(await probe.cancelled == 1)
    #expect(!session.isOpen)
    #expect(session.copyableOutput == nil)
}

@MainActor
@Test func manualMapDoesNotStartWhileTypingButCanGenerate() async {
    let probe = RequestProbe()
    let session = OmniMapSession(producer: { _, _ in
        await probe.start()
        throw EphemeralToolFailure("synthetic failure")
    }, debounce: .milliseconds(1), automaticRequestsEnabled: { false })
    session.open(input: "Map how a request moves through a server")
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await probe.started == 0)
    #expect(session.canSubmit)
    session.submit()
    for _ in 0..<100 {
        if await probe.started > 0 { break }
        await Task.yield()
    }
    #expect(await probe.started == 1)
    session.close()
}

@MainActor
@Test func pronunciationOfflineTransitionCancelsPlaybackAndKeepsInput() async {
    let probe = RequestProbe()
    let descriptor = OmniEphemeralToolDescriptor(
        id: "pronunciation", title: "Pronounce", subtitle: "", inputPlaceholder: "",
        emptyResultHint: "", resultStyle: .pronunciation, interaction: .explicitReplay)
    let session = OmniEphemeralSession(descriptor: descriptor, producer: { _, _ in
        await probe.start()
        do { try await Task.sleep(for: .seconds(10)) }
        catch { await probe.cancel(); throw error }
        return "late"
    })
    session.open(input: "epitome")
    session.submit()
    for _ in 0..<100 {
        if await probe.started > 0 { break }
        await Task.yield()
    }
    session.cancelCurrentRequestPreservingInput()
    for _ in 0..<100 {
        if await probe.cancelled > 0 { break }
        await Task.yield()
    }
    #expect(await probe.cancelled == 1)
    #expect(session.isOpen)
    #expect(session.input == "epitome")
    #expect(session.phase == .empty)
    session.close()
}
