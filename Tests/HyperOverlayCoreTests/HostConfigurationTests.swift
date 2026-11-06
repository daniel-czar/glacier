import Foundation
import Testing
@testable import HyperOverlayCore

@Test func legacyLaunchHasNoNativeHotkeysAndKeepsIdleExit() throws {
    let configuration = try HostConfiguration(environment: [:])
    #expect(!configuration.resident)
    #expect(!configuration.hotkeysEnabled)
    #expect(configuration.idleTimeout == 300)
}

@Test func residencyOverridesIdleTimeoutButDoesNotImplicitlyEnableHotkeys() throws {
    let configuration = try HostConfiguration(environment: [
        "HYPER_OVERLAY_RESIDENT": "1", "HYPER_OVERLAY_IDLE_SECONDS": "0.1"
    ])
    #expect(configuration.resident)
    #expect(configuration.idleTimeout == 0)
    #expect(!configuration.hotkeysEnabled)
}

@Test func explicitNativeSettingsAndManifestAreRespected() throws {
    let configuration = try HostConfiguration(environment: [
        "HYPER_OVERLAY_HOTKEYS": "1", "HYPER_OVERLAY_IDLE_SECONDS": "1.5",
        "HYPER_OVERLAY_MANIFEST": "/tmp/native manifest.json"
    ])
    #expect(configuration.hotkeysEnabled)
    #expect(configuration.idleTimeout == 1.5)
    #expect(configuration.manifestURL.path == "/tmp/native manifest.json")
}

@Test func retiredRailStatusIsIgnoredAndNotEmitted() throws {
    let legacy = Data(#"{"pid":1,"resident":true,"hotkeys_enabled":true,"registered_overlays":[],"manifest_path":"/m","rail":{"bad":"retired"}}"#.utf8)
    let legacyHost = try JSONDecoder().decode(OverlayHostStatus.self, from: legacy)
    #expect(legacyHost.releaseVersion == nil)
    #expect(legacyHost.sourceRevision == nil)
    let data = try OverlayProtocol.encoder.encode(legacyHost)
    #expect(!String(decoding: data, as: UTF8.self).contains("\"rail\""))
    #expect(try JSONDecoder().decode(OverlayHostStatus.self, from: data) == legacyHost)
}

@Test func packagedHostReleaseMetadataRoundTripsWithoutChangingLegacyWireShape() throws {
    let revision = String(repeating: "a", count: 40)
    let host = OverlayHostStatus(
        processID: 12, resident: true, hotkeysEnabled: true,
        registeredOverlays: [OverlayID.translate], manifestPath: "/tmp/manifest.json",
        hotkeyError: nil, appBundlePath: "/tmp/HyperOverlayHost.app",
        releaseVersion: "2026.10.0", sourceRevision: revision
    )
    let response = OverlayResponse(requestID: "versioned", status: .applied, state: .idle,
                                   overlay: nil, generation: 0, host: host)
    let encoded = try OverlayProtocol.encodeLine(response)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let hostJSON = try #require(json["host"] as? [String: Any])
    #expect(hostJSON["release_version"] as? String == "2026.10.0")
    #expect(hostJSON["source_revision"] as? String == revision)
    #expect(try OverlayProtocol.decodeResponse(encoded) == response)

    let legacyHost = OverlayHostStatus(
        processID: 12, resident: true, hotkeysEnabled: true,
        registeredOverlays: [], manifestPath: "/tmp/manifest.json",
        hotkeyError: nil, appBundlePath: nil
    )
    let legacyJSON = try #require(JSONSerialization.jsonObject(with: OverlayProtocol.encoder.encode(legacyHost)) as? [String: Any])
    #expect(legacyJSON["release_version"] == nil)
    #expect(legacyJSON["source_revision"] == nil)
}

@Test func malformedHostSettingsFailExplicitly() {
    for environment in [
        ["HYPER_OVERLAY_RESIDENT": "true"], ["HYPER_OVERLAY_HOTKEYS": "yes"],
        ["HYPER_OVERLAY_IDLE_SECONDS": "nan"], ["HYPER_OVERLAY_IDLE_SECONDS": "inf"],
        ["HYPER_OVERLAY_IDLE_SECONDS": "-1"], ["HYPER_OVERLAY_MANIFEST": "relative.json"]
    ] {
        #expect(throws: (any Error).self) { try HostConfiguration(environment: environment) }
    }
}

@Test func responsesRemainCompatibleWithLegacyClientsAndHosts() throws {
    let data = Data(#"{"request_id":"old","status":"applied","state":"idle","generation":0}"#.utf8)
    #expect(try OverlayProtocol.decodeResponse(data).host == nil)
    let host = OverlayHostStatus(processID: 12, resident: true, hotkeysEnabled: true,
                                 registeredOverlays: [OverlayID.translate], manifestPath: "/tmp/manifest.json",
                                 hotkeyError: nil, appBundlePath: "/tmp/Host.app")
    let response = OverlayResponse(requestID: "new", status: .applied, state: .idle,
                                   overlay: nil, generation: 0, host: host)
    #expect(try OverlayProtocol.decodeResponse(OverlayProtocol.encodeLine(response)) == response)
}
