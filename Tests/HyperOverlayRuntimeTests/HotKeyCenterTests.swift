import Testing
import HyperOverlayCore
@testable import HyperOverlayRuntime

@MainActor
private final class FakeHotKeyBackend: HotKeyBackend {
    var active: [UInt32: HotKeyChord] = [:]
    var blocked: Set<HotKeyChord> = []
    var handler: (@MainActor (UInt32, Bool) -> Void)?
    var registerCount = 0
    var refuseUnregister: Set<HotKeyChord> = []

    func start(handler: @escaping @MainActor (UInt32, Bool) -> Void) throws { self.handler = handler }
    func register(_ chord: HotKeyChord, id: UInt32) throws {
        if blocked.contains(chord) { throw HotKeyError.registration("fixture conflict", -9878) }
        active[id] = chord
        registerCount += 1
    }
    func unregister(id: UInt32) throws {
        if let chord = active[id], refuseUnregister.contains(chord) {
            throw HotKeyError.registration("fixture unregister failure", -1)
        }
        active.removeValue(forKey: id)
    }
    func stop() -> [String] {
        var failures: [String] = []
        for id in Array(active.keys) {
            do { try unregister(id: id) }
            catch { failures.append(String(describing: error)) }
        }
        handler = nil
        return failures
    }
    func id(for chord: HotKeyChord) -> UInt32 { active.first { $0.value == chord }!.key }
}

private func binding(_ overlay: String, _ key: UInt32) -> OverlayHotKeyBinding {
    OverlayHotKeyBinding(overlayID: overlay, chord: HotKeyChord(keyCode: key, modifiers: [.command, .control]))
}

@Test @MainActor func hotkeysDispatchOncePerPressAndIgnoreUnknownEvents() throws {
    let backend = FakeHotKeyBackend()
    var fired: [String] = []
    let center = HotKeyCenter(backend: backend) { fired.append($0) }
    defer { center.stop() }
    let translate = binding(OverlayID.translate, 37)
    try center.replace(with: [translate])
    let id = backend.id(for: translate.chord)
    backend.handler?(id, true)
    backend.handler?(id, true)
    backend.handler?(id, false)
    backend.handler?(id, true)
    backend.handler?(999, true)
    #expect(fired == [OverlayID.translate, OverlayID.translate])
}

@Test @MainActor func failedReloadRetainsOldBindingsAndReleasesPartialAcquisitions() throws {
    let backend = FakeHotKeyBackend()
    var fired: [String] = []
    let center = HotKeyCenter(backend: backend) { fired.append($0) }
    defer { center.stop() }
    let original = binding(OverlayID.translate, 37)
    let acquired = binding(OverlayID.help, 4)
    let conflict = binding(OverlayID.reference, 30)
    try center.replace(with: [original])
    let oldID = backend.id(for: original.chord)
    backend.blocked.insert(conflict.chord)
    #expect(throws: (any Error).self) { try center.replace(with: [acquired, conflict]) }
    #expect(center.bindings == [original])
    #expect(backend.active == [oldID: original.chord])
    backend.handler?(oldID, true)
    #expect(fired == [OverlayID.translate])
}

@Test @MainActor func reloadReusesChordsAndUpdatesTheirMeaningWithoutGaps() throws {
    let backend = FakeHotKeyBackend()
    var fired: [String] = []
    let center = HotKeyCenter(backend: backend) { fired.append($0) }
    defer { center.stop() }
    let original = binding(OverlayID.translate, 37)
    try center.replace(with: [original])
    let id = backend.id(for: original.chord)
    try center.replace(with: [binding(OverlayID.help, 37)])
    #expect(backend.registerCount == 1)
    backend.handler?(id, true)
    #expect(fired == [OverlayID.help])
    try center.replace(with: [])
    #expect(backend.active.isEmpty)
    backend.handler?(id, false)
    backend.handler?(id, true)
    #expect(fired.count == 1)
}

@Test @MainActor func stopReleasesKeysAndASecondStartHasNoStalePressState() throws {
    let backend = FakeHotKeyBackend()
    var fired: [String] = []
    let center = HotKeyCenter(backend: backend) { fired.append($0) }
    let original = binding(OverlayID.translate, 37)
    try center.replace(with: [original])
    let staleID = backend.id(for: original.chord)
    backend.handler?(staleID, true)
    center.stop()
    #expect(backend.active.isEmpty)
    try center.replace(with: [original])
    backend.handler?(staleID, true)
    backend.handler?(backend.id(for: original.chord), true)
    #expect(fired.count == 2)
    center.stop()
}

@Test @MainActor func invalidBindingSetsNeverReachTheOS() throws {
    let backend = FakeHotKeyBackend()
    let center = HotKeyCenter(backend: backend) { _ in }
    defer { center.stop() }
    #expect(throws: (any Error).self) {
        try center.replace(with: [binding("a", 4), binding("b", 4)])
    }
    #expect(throws: (any Error).self) {
        try center.replace(with: [binding("a", 4), binding("a", 5)])
    }
    #expect(backend.active.isEmpty)
}

@Test @MainActor func failedUnregisterRemainsTrackedAndBlocksReloadUntilCleaned() throws {
    let backend = FakeHotKeyBackend()
    let center = HotKeyCenter(backend: backend) { _ in }
    defer { center.stop() }
    let original = binding(OverlayID.translate, 37)
    let partial = binding(OverlayID.help, 4)
    let conflict = binding(OverlayID.reference, 30)
    try center.replace(with: [original])
    backend.blocked.insert(conflict.chord)
    backend.refuseUnregister.insert(partial.chord)
    #expect(throws: (any Error).self) { try center.replace(with: [partial, conflict]) }
    #expect(center.bindings == [original])
    #expect(backend.active.count == 2)
    #expect(throws: (any Error).self) { try center.replace(with: [original]) }
    backend.refuseUnregister.removeAll()
    try center.replace(with: [original])
    #expect(backend.active.count == 1)
    #expect(center.bindings == [original])
}

@Test @MainActor func removalCleanupFailureIsReportedAndRetryCanFinish() throws {
    let backend = FakeHotKeyBackend()
    let center = HotKeyCenter(backend: backend) { _ in }
    defer { center.stop() }
    let original = binding(OverlayID.translate, 37)
    try center.replace(with: [original])
    backend.refuseUnregister.insert(original.chord)
    #expect(throws: (any Error).self) { try center.replace(with: []) }
    #expect(backend.active.count == 1)
    #expect(!center.stop().isEmpty)
    backend.refuseUnregister.removeAll()
    try center.replace(with: [original])
    #expect(backend.active.count == 1)
    #expect(center.bindings == [original])
}

@Test @MainActor func optionalBindingRegistersAlongsideTheRequiredSet() throws {
    let backend = FakeHotKeyBackend()
    let center = HotKeyCenter(backend: backend) { _ in }
    defer { center.stop() }
    let required = [binding(OverlayID.translate, 37), binding(OverlayID.help, 4)]
    let optional = binding(OverlayID.stash, 2)
    #expect(try center.replace(required: required, optional: optional) == nil)
    #expect(center.bindings == required + [optional])
    #expect(backend.active.count == 3)
}

@Test @MainActor func optionalBindingFailureLeavesTheRequiredSetRegisteredAndFiringOnAFreshStart() throws {
    let backend = FakeHotKeyBackend()
    var fired: [String] = []
    let center = HotKeyCenter(backend: backend) { fired.append($0) }
    defer { center.stop() }
    let required = [binding(OverlayID.translate, 37), binding(OverlayID.help, 4)]
    let optional = binding(OverlayID.stash, 2)
    backend.blocked.insert(optional.chord)
    let reason = try center.replace(required: required, optional: optional)
    #expect(reason?.contains("registered the required set only") == true)
    #expect(center.bindings == required)
    #expect(Set(backend.active.values) == Set(required.map(\.chord)))
    // The fallback re-registers under fresh ids; the trigger map must follow.
    backend.handler?(backend.id(for: required[0].chord), true)
    backend.handler?(backend.id(for: required[1].chord), true)
    #expect(fired == [OverlayID.translate, OverlayID.help])
}

@Test @MainActor func optionalBindingCollidingByOverlayIDIsRejectedAndNilOptionalIsPlainReplace() throws {
    let backend = FakeHotKeyBackend()
    let center = HotKeyCenter(backend: backend) { _ in }
    defer { center.stop() }
    let required = [binding(OverlayID.translate, 37)]
    let reason = try center.replace(required: required, optional: binding(OverlayID.translate, 2))
    #expect(reason?.contains("collides with \(OverlayID.translate)") == true)
    #expect(backend.active.count == 1)
    #expect(try center.replace(required: required, optional: nil) == nil)
    #expect(center.bindings == required)
    #expect(backend.registerCount == 1)
}

@Test @MainActor func optionalBindingCollidingWithARequiredChordNeverReachesTheOS() throws {
    let backend = FakeHotKeyBackend()
    let center = HotKeyCenter(backend: backend) { _ in }
    defer { center.stop() }
    let required = [binding(OverlayID.translate, 37)]
    let reason = try center.replace(required: required, optional: binding(OverlayID.stash, 37))
    #expect(reason?.contains("collides with \(OverlayID.translate)") == true)
    #expect(center.bindings == required)
    #expect(backend.registerCount == 1)
}

@Test @MainActor func requiredFailureStillThrowsWhenAnOptionalBindingIsPresent() throws {
    let backend = FakeHotKeyBackend()
    let center = HotKeyCenter(backend: backend) { _ in }
    defer { center.stop() }
    let required = [binding(OverlayID.translate, 37)]
    backend.blocked.insert(required[0].chord)
    #expect(throws: (any Error).self) {
        try center.replace(required: required, optional: binding(OverlayID.stash, 2))
    }
    #expect(center.bindings.isEmpty)
    #expect(backend.active.isEmpty)
}
