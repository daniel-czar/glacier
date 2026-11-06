import AppKit
@testable import HyperOverlayRuntime
import Testing

@MainActor
private func insertionTarget() throws -> PasteTarget {
    let app = NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
    return try #require(PasteTarget(app?.processIdentifier))
}

@MainActor
private final class InsertionFixture {
    var trusted = true
    var available = true
    var frontmost: pid_t?
    var axResult: AXInsertionResult = .inserted
    var pasteResult: TargetedPasteFailure?
    var axCalls = 0
    var pasteCalls = 0
    var activations = 0
    var onAX: (() -> Void)?

    func effects() -> TextInsertionEffects {
        TextInsertionEffects(
            trusted: { self.trusted },
            available: { _ in self.available },
            activate: { target in self.activations += 1; self.frontmost = target.pid; return true },
            frontmostPID: { self.frontmost },
            insertAX: { _, _, _ in self.axCalls += 1; self.onAX?(); return self.axResult },
            paste: { _, write, _ in
                self.pasteCalls += 1
                if let pasteResult = self.pasteResult { return pasteResult }
                return write() ? nil : .writeFailed
            }
        )
    }
}

@Suite(.serialized) @MainActor struct TextInsertionTests {
    @Test func axSuccessDoesNotPasteOrCopy() async throws {
        let target = try insertionTarget()
        let fixture = InsertionFixture()
        var hides = 0
        var writes = 0
        let result = await TextInsertion.perform(text: "é", into: target,
            hide: { hides += 1 }, write: { writes += 1; return true },
            isCurrent: { true }, effects: fixture.effects())
        #expect(result == .inserted)
        #expect(hides == 1 && writes == 0)
        #expect(fixture.axCalls == 1 && fixture.pasteCalls == 0)
    }

    @Test func unsupportedAXUsesTargetedPaste() async throws {
        let target = try insertionTarget()
        let fixture = InsertionFixture()
        fixture.axResult = .unsupported
        var writes = 0
        let result = await TextInsertion.perform(text: "→", into: target,
            hide: {}, write: { writes += 1; return true },
            isCurrent: { true }, effects: fixture.effects())
        #expect(result == .inserted)
        #expect(fixture.axCalls == 1 && fixture.pasteCalls == 1)
        #expect(writes == 1)
    }

    @Test func ambiguousAXFailureCannotDoubleInsert() async throws {
        let target = try insertionTarget()
        let fixture = InsertionFixture()
        fixture.axResult = .ambiguous
        var writes = 0
        let result = await TextInsertion.perform(text: "∞", into: target,
            hide: {}, write: { writes += 1; return true },
            isCurrent: { true }, effects: fixture.effects())
        #expect(result == .copied(reason: TextInsertion.copyNotice))
        #expect(fixture.pasteCalls == 0 && writes == 1)
    }

    @Test func focusChangeDuringAXAvoidsPaste() async throws {
        let target = try insertionTarget()
        let fixture = InsertionFixture()
        fixture.axResult = .unsupported
        fixture.onAX = { fixture.frontmost = nil }
        var writes = 0
        let result = await TextInsertion.perform(text: "λ", into: target,
            hide: {}, write: { writes += 1; return true },
            isCurrent: { true }, effects: fixture.effects())
        #expect(result == .copied(reason: TextInsertion.copyNotice))
        #expect(fixture.pasteCalls == 0 && writes == 1)
    }

    @Test func supersededDuringAXCancelsWithoutSideEffects() async throws {
        let target = try insertionTarget()
        let fixture = InsertionFixture()
        fixture.axResult = .unsupported
        var current = true
        fixture.onAX = { current = false }
        var writes = 0
        let result = await TextInsertion.perform(text: "§", into: target,
            hide: {}, write: { writes += 1; return true },
            isCurrent: { current }, effects: fixture.effects())
        #expect(result == .cancelled)
        #expect(fixture.pasteCalls == 0 && writes == 0)
    }

    @Test func missingTargetOrTrustCopies() async throws {
        let target = try insertionTarget()
        let fixture = InsertionFixture()
        var writes = 0
        let missing = await TextInsertion.perform(text: "a", into: nil,
            hide: {}, write: { writes += 1; return true },
            isCurrent: { true }, effects: fixture.effects())
        fixture.trusted = false
        let untrusted = await TextInsertion.perform(text: "a", into: target,
            hide: {}, write: { writes += 1; return true },
            isCurrent: { true }, effects: fixture.effects())
        #expect(missing == .copied(reason: TextInsertion.copyNotice))
        #expect(untrusted == .copied(reason: TextInsertion.copyNotice))
        #expect(writes == 2 && fixture.activations == 0 && fixture.axCalls == 0)
    }
}
