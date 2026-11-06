import Foundation
import Testing
@testable import HyperOverlayCore

private struct OverlayManifestFixtureRow: Codable {
    var id: String
    var nativeImplemented: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case nativeImplemented = "native_implemented"
    }
}

@Test func requestRoundTripUsesSnakeCaseKeys() throws {
    let request = OverlayRequest(command: .show, overlay: OverlayID.reference, requestID: "abc")
    let data = try OverlayProtocol.encodeLine(request)
    let decoded = try OverlayProtocol.decodeRequest(Data(data.dropLast()))

    #expect(decoded.command == .show)
    #expect(decoded.overlay == OverlayID.reference)
    #expect(decoded.requestID == "abc")
}

@Test func responseRoundTripPreservesState() throws {
    let response = OverlayResponse(
        requestID: "abc",
        status: .applied,
        state: .showing,
        overlay: OverlayID.reference,
        generation: 3
    )
    let data = try OverlayProtocol.encodeLine(response)
    let decoded = try OverlayProtocol.decodeResponse(Data(data.dropLast()))

    #expect(decoded == response)
}

@Test func indexingStatusIsOptionalAndPreservesDiagnosticCounters() throws {
    let old = try JSONDecoder().decode(OverlayOmniStatus.self,
        from: Data(#"{"active":true,"support_root":"/fixture"}"#.utf8))
    #expect(old.indexing == nil)
    let diagnostics = OverlayIndexingStatus(
        state: "cooldown", recoveryRequired: true, cursor: 42,
        pendingReason: "event-loss", lastFullSeconds: 3.5, nextRecoveryUnix: 1234,
        counters: ["full_starts": 2, "watcher_events": 40_000],
        nativeExclusions: ["/fixture/excluded"]
    )
    let value = OverlayOmniStatus(active: true, supportRoot: "/fixture", error: nil, indexing: diagnostics)
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(OverlayOmniStatus.self, from: data) == value)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let indexing = try #require(object["indexing"] as? [String: Any])
    #expect(indexing["recovery_required"] as? Bool == true)
    #expect(indexing["next_recovery_unix"] as? Double == 1234)
}

@Test func implementedOverlaysAreManifestMembers() {
    for overlay in OverlayID.implemented {
        #expect(OverlayID.manifest.contains(overlay))
    }
}

@Test func everyManifestOverlayIsImplemented() {
    #expect(OverlayID.implemented == OverlayID.manifest)
}

/// The owner's live Keyboard Maestro manifest. Tests that read it are parity
/// checks against the installed machine and skip where the file is absent.
private let liveCutoverManifestURL = ProcessInfo.processInfo.environment["HYPER_OVERLAY_TEST_MANIFEST"]
    .map { URL(fileURLWithPath: $0) }
    ?? OverlayPaths.keyboardMaestroRoot.appendingPathComponent("hyper-overlays.json")

@Test(.enabled(if: FileManager.default.fileExists(atPath: liveCutoverManifestURL.path), "live Keyboard Maestro manifest is not installed on this machine"))
func realCutoverManifestMatchesImplementedOverlays() throws {
    let rows = try JSONDecoder().decode([OverlayManifestFixtureRow].self, from: Data(contentsOf: liveCutoverManifestURL))
    let nativeIDs = Set(rows.filter(\.nativeImplemented).map(\.id))

    #expect(nativeIDs == OverlayID.hotkeyIDs)
}

@Test func directActionsAreHotkeysButNeverOverlays() {
    #expect(OverlayID.directActions.count == 13)
    #expect(OverlayID.collectActions.count == 5 && OverlayID.keyActions.count == 8)
    #expect(OverlayID.directActions.isDisjoint(with: OverlayID.implemented))
    #expect(OverlayID.directActions.isDisjoint(with: OverlayID.manifest))
    #expect(OverlayID.hotkeyIDs == OverlayID.implemented.union(OverlayID.directActions))
}

@Test func lifecycleTogglesSameOverlayClosed() {
    var lifecycle = OverlayLifecycle(allowedOverlays: OverlayID.implemented)

    let open = lifecycle.show(OverlayID.reference)
    #expect(open.kind == .opened(OverlayID.reference))
    #expect(open.state == .showing)
    #expect(open.generation == 1)

    let close = lifecycle.show(OverlayID.reference)
    #expect(close.kind == .closed)
    #expect(close.state == .idle)
    #expect(close.overlay == nil)
    #expect(close.generation == 2)
}

@Test func lifecycleReplacesDifferentOverlay() {
    var lifecycle = OverlayLifecycle(allowedOverlays: OverlayID.implemented)

    _ = lifecycle.show(OverlayID.reference)
    let replacement = lifecycle.show(OverlayID.referenceSheet)

    #expect(replacement.kind == .replaced(from: OverlayID.reference, to: OverlayID.referenceSheet))
    #expect(replacement.state == .showing)
    #expect(replacement.overlay == OverlayID.referenceSheet)
    #expect(replacement.generation == 2)
}

@Test func lifecycleRejectsUnimplementedOverlayWithoutChangingState() {
    var lifecycle = OverlayLifecycle(allowedOverlays: OverlayID.implemented)

    let rejected = lifecycle.show("not-in-overlay-manifest")

    #expect(rejected.kind == .rejected("unknown-or-unimplemented-overlay"))
    #expect(rejected.state == .idle)
    #expect(rejected.overlay == nil)
    #expect(rejected.generation == 0)
}
