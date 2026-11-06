import Foundation
import Testing
import GlacierConfiguration
import GlacierRuntime
import OmniAdapters

@Suite("Detached runtime integration")
struct CompositionTests {
    @Test func implicitApplicationRootsRemainInternalAndExplicitOverlapOwnsFiles() throws {
        let home = URL(fileURLWithPath: "/tmp/glacier-app-root-fixture")
        let apps = home.appendingPathComponent("Applications")
        let implicit = try #require(GlacierComposition.appSources([apps]).first)
        #expect(implicit.applicationDiscoveryOnly)
        #expect(implicit.recursive)
        let encoded = try JSONEncoder().encode(implicit)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("applicationDiscoveryOnly"))
        #expect(!(try JSONDecoder().decode(GlacierSourceRoot.self, from: encoded)).applicationDiscoveryOnly)

        var settings = GlacierSettings()
        settings.roots.sources = [GlacierSourceRoot(path: apps.path)]
        let selected = GlacierComposition.sources(settings: settings, home: home, applicationRoots: [apps])
        #expect(selected.count == 1)
        #expect(selected.first?.path == apps.path)
        #expect(selected.first?.applicationDiscoveryOnly == false)

        let defaults = GlacierComposition.sources(settings: GlacierSettings(), home: home)
        #expect(Set(defaults.map(\.path)) == Set([
            "/Applications", "/System/Applications",
            "/System/Library/CoreServices/Applications",
            "/System/Library/CoreServices/Finder.app", apps.path,
        ]))
        #expect(defaults.allSatisfy { $0.applicationDiscoveryOnly })
        #expect(GlacierComposition.sources(settings: GlacierSettings(), home: home, applicationRoots: []).isEmpty)
    }

    @Test @MainActor func productionCompositionIndexesAdditionalAppRootsAndQueriesFinder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-app-discovery-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let userApps = home.appendingPathComponent("Applications")
        let systemApps = root.appendingPathComponent("System/Library/CoreServices/Applications")
        let finder = root.appendingPathComponent("System/Library/CoreServices/Finder.app")
        for app in [userApps.appendingPathComponent("User Tool.app"),
                    systemApps.appendingPathComponent("System Tool.app"), finder] {
            let info = app.appendingPathComponent("Contents/Info.plist")
            try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: info)
        }
        let helper = finder.appendingPathComponent("Contents/Helpers/Hidden Helper.app")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let paths = try GlacierPaths(home: home, supportOverride: root.appendingPathComponent("Glacier"))
        let composition = try await GlacierComposition.make(
            paths: paths, home: home, hostActions: GlacierHostActions(),
            applicationRoots: [userApps, systemApps, finder],
            platform: RecordingPlatformAdapter(), fileEffect: { _, _ in })
        let snapshot = try await composition.search.build()
        #expect(Set(snapshot.candidates.map(\.path)) == Set([
            userApps.appendingPathComponent("User Tool.app").path,
            systemApps.appendingPathComponent("System Tool.app").path, finder.path,
        ]))
        #expect(snapshot.candidates.allSatisfy { $0.kind == "app" && $0.source == .apps })
        #expect(!composition.search.permits(helper.path))
        composition.launcher.publish(snapshot)
        #expect(composition.launcher.query("Finder").rows.contains { $0.candidate.path == finder.path })
        #expect(composition.launcher.query("System Tool").rows.contains { $0.candidate.path == systemApps.appendingPathComponent("System Tool.app").path })
        #expect(composition.snapshot.permits("launcher.open"))
        var disabled = composition.snapshot.read()
        disabled.modules["launcher"] = .init(enabled: false)
        composition.snapshot.replace(disabled)
        #expect(!composition.snapshot.permits("launcher.open"))
        _ = await composition.service.shutdown()
    }

    @Test func realLocalCommandWithoutSecretsNetworkOrHotkeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-integration-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await GlacierSmoke.check(root: root)
        #expect(result.localCommandSucceeded)
        #expect(result.networkRequests == 0)
        #expect(result.configuredSecretReferences == 0)
        #expect(result.registeredGlobalShortcuts == 0)
        #expect(URL(fileURLWithPath: result.supportRoot).standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
    }
    @Test func disabledModuleStopsEphemeralAndDurableRoutes() {
        var settings = GlacierSettings()
        settings.modules["translation"] = .init(enabled: false)
        let state = RuntimeSnapshot(settings)
        #expect(!state.permits("tool.translate"))
        #expect(!state.permits("command.translate"))
        #expect(!state.permits("command.translate:en"))
        #expect(state.permits("settings.open"))
        #expect(state.permits("command.settings"))
        #expect(!state.permits("command.todo"))
        #expect(!state.automaticRequests("tool.quick-question"))
    }
    @Test func normalizeRetainsShellContinuationsAndJoinsWrappedPaths() {
        #expect(GlacierTextNormalizer.normalize("./project/\n  src/\n  main.swift\n") == "./project/src/main.swift\n")
        #expect(GlacierTextNormalizer.normalize("./command \\\n  --flag\n") == "./command \\\n  --flag\n")
        #expect(GlacierTextNormalizer.normalize("ordinary prose\ncontinues here\n") == "ordinary prose\ncontinues here\n")
        #expect(GlacierTextNormalizer.normalize("/a/part-    02/file.txt") == "/a/part-02/file.txt")
    }
}

@Test @MainActor func clipboardCaptureCannotResumeBehindDisabledModuleOrPreview() {
    var saved = GlacierSettings()
    saved.clipboard.captureEnabled = true
    #expect(GlacierDesktop.effectiveClipboardCapture(settings: saved, preview: false))
    saved.modules["clipboard"] = .init(enabled: false)
    #expect(!GlacierDesktop.effectiveClipboardCapture(settings: saved, preview: false))
    saved.modules["clipboard"] = .init(enabled: true)
    #expect(!GlacierDesktop.effectiveClipboardCapture(settings: saved, preview: true))
    saved.clipboard.captureEnabled = false
    #expect(!GlacierDesktop.effectiveClipboardCapture(settings: saved, preview: false))
}
