import Foundation
import GlacierConfiguration
import Testing

@Test func firstRunSettingsAreSafeAndPortable() throws {
    let settings = GlacierSettings()
    #expect(settings.version == GlacierSettings.currentVersion)
    #expect(settings.roots.sources.isEmpty)
    #expect(settings.roots.includeHome == false)
    #expect(settings.roots.captureDirectory == nil)
    #expect(settings.roots.linkDirectory == nil)
    #expect(settings.translation.sourceLanguage == "auto")
    #expect(settings.translation.targetLanguage == "en")
    #expect(settings.clipboard.captureEnabled == false)
    #expect(settings.shortcuts.isEmpty)
    #expect(settings.modules.isEmpty)
    #expect(try JSONDecoder().decode(GlacierSettings.self,
                                     from: JSONEncoder().encode(settings)) == settings)
}

@Test func legacySettingsMigrateWithStableRootIdentityAndSafeNewFields() throws {
    let legacy = """
    {"version":1,"modules":{"translation":{"enabled":false}},
     "roots":{"sources":[{"path":"/tmp/glacier-fixture"}],"includeHome":false}}
    """.data(using: .utf8)!
    let first = try JSONDecoder().decode(GlacierSettings.self, from: legacy)
    let second = try JSONDecoder().decode(GlacierSettings.self, from: legacy)
    #expect(first.version == 2)
    #expect(first.modules["translation"]?.enabled == false)
    #expect(first.modules["translation"]?.automaticRequests == false)
    #expect(first.roots.sources[0].id == second.roots.sources[0].id)
    #expect(first.roots.sources[0].includeHidden == false)
    #expect(first.roots.sources[0].includeSourceFiles == false)
    #expect(first.shortcuts.isEmpty)
    #expect(first.clipboard.captureEnabled == false)
}

@Test func retiredRailPreferencesAreDroppedWithoutResettingOtherChoices() throws {
    let legacy = """
    {"version":2,
     "modules":{"rail":{"enabled":"malformed"},"translation":{"enabled":false}},
     "shortcuts":{"rail.switch":{"enabled":true,"chord":"malformed"},
                  "tool.translate":{"enabled":true,"chord":{"keyCode":37,"modifiers":["command"]}}},
     "railApps":{"malformed":"retired"},
     "roots":{"sources":[{"path":"/tmp/glacier-fixture"}],"includeHome":false},
     "terminal":"ghostty","editorBundleID":"com.apple.TextEdit",
     "translation":{"sourceLanguage":"auto","targetLanguage":"fr"},
     "ai":{"paused":false,"offline":true},"clipboard":{"captureEnabled":false}}
    """.data(using: .utf8)!
    let settings = try JSONDecoder().decode(GlacierSettings.self, from: legacy)
    #expect(settings.modules["rail"] == nil)
    #expect(settings.shortcuts["rail.switch"] == nil)
    #expect(settings.modules["translation"]?.enabled == false)
    #expect(settings.shortcuts["tool.translate"]?.enabled == true)
    #expect(settings.shortcuts["tool.translate"]?.chord?.keyCode == 37)
    #expect(settings.roots.sources.map(\.path) == ["/tmp/glacier-fixture"])
    #expect(settings.terminal == .ghostty)
    #expect(settings.translation.targetLanguage == "fr")
    #expect(settings.ai.offline)
    let encoded = try JSONEncoder().encode(settings)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("railApps") && !text.contains("rail.switch") && !text.contains("\"rail\""))
    #expect(try JSONDecoder().decode(GlacierSettings.self, from: encoded) == settings)
}

@Test func storePublishesOnlyPersistedUpdatesAndNeverOverwritesInvalidJSON() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let paths = try GlacierPaths(home: temp, supportOverride: temp.appendingPathComponent("Glacier"))
    let store = try GlacierSettingsStore(paths: paths)
    let original = await store.snapshot()
    #expect(original.shortcuts.isEmpty)
    let changed = try await store.update { settings in
        settings.modules["translation"] = GlacierModuleSettings(enabled: false)
        settings.roots.sources = [GlacierSourceRoot(path: "/tmp/glacier-fixture")]
    }
    #expect(changed.modules["translation"]?.enabled == false)
    #expect(try JSONDecoder().decode(GlacierSettings.self,
                                     from: Data(contentsOf: paths.settings)) == changed)
    do {
        try await store.update { settings in
            settings.shortcuts["tool.translate"] = GlacierShortcutSettings(enabled: true)
        }
        Issue.record("Expected invalid shortcut rejection")
    } catch {
        #expect(error as? GlacierConfigurationError ==
                .invalidShortcut("Enabled shortcut tool.translate has no chord"))
    }
    #expect(await store.snapshot() == changed)
    #expect(try JSONDecoder().decode(GlacierSettings.self,
                                     from: Data(contentsOf: paths.settings)) == changed)

    try Data("{broken".utf8).write(to: paths.settings, options: .atomic)
    #expect(throws: DecodingError.self) { try GlacierSettingsStore(paths: paths) }
    #expect(try Data(contentsOf: paths.settings) == Data("{broken".utf8))

    let other = temp.appendingPathComponent("other.json")
    try Data("{}".utf8).write(to: other)
    try FileManager.default.removeItem(at: paths.settings)
    try FileManager.default.createSymbolicLink(at: paths.settings, withDestinationURL: other)
    #expect(throws: GlacierConfigurationError.self) { try GlacierSettingsStore(paths: paths) }
}

@Test func pathsRejectOmniStateAndSourceRootsIncludingSymlinks() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let live = temp.appendingPathComponent("Library/Application Support/Omni/Glacier")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    #expect(throws: GlacierConfigurationError.self) {
        try GlacierPaths(home: temp, supportOverride: live)
    }
    #expect(throws: GlacierConfigurationError.self) {
        try GlacierPaths(home: temp,
                         supportOverride: temp.appendingPathComponent("Library/Application Support"))
    }
    #expect(throws: GlacierConfigurationError.self) {
        try GlacierPaths(home: temp,
                         supportOverride: temp.appendingPathComponent("Library/Application Support/DanielTooling/Glacier"))
    }
    #expect(throws: GlacierConfigurationError.self) {
        try GlacierPaths(home: temp,
                         supportOverride: temp.appendingPathComponent("Tooling/apps/OmniIntentStandalone/Glacier"))
    }
    let source = temp.appendingPathComponent("omni-intent")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let link = temp.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: GlacierConfigurationError.self) {
        try GlacierPaths(home: temp, supportOverride: link.appendingPathComponent("Glacier"))
    }
    let safe = try GlacierPaths(home: temp)
    #expect(safe.support.path.hasSuffix("Application Support/Glacier"))
    #expect(safe.settings.lastPathComponent == "settings.json")
    let override = try GlacierPaths(home: temp, supportOverride: temp.appendingPathComponent("Glacier"))
    #expect(override.cache.path.hasPrefix(override.support.path + "/"))
    #expect(override.logs.path.hasPrefix(override.support.path + "/"))
    let chosenOutput = temp.appendingPathComponent("My Notes")
    #expect(try GlacierPaths.validateUserDirectory(chosenOutput) ==
            GlacierPaths.canonicalFileURL(chosenOutput))
    #expect(throws: GlacierConfigurationError.self) {
        try GlacierPaths.validateUserDirectory(temp.appendingPathComponent("Tooling/apps/omni-intent/captures"))
    }
}

@Test func futureSettingsVersionIsRejected() throws {
    let data = Data(#"{"version":999}"#.utf8)
    #expect(throws: GlacierConfigurationError.unsupportedVersion(999)) {
        try JSONDecoder().decode(GlacierSettings.self, from: data)
    }
}

@Test func sourceConfigurationRejectsVolumeRootAndDuplicateIdentity() throws {
    var settings = GlacierSettings()
    settings.roots.sources = [GlacierSourceRoot(path: "/")]
    #expect(throws: GlacierConfigurationError.invalidPath("/")) { try settings.validate() }
    let id = UUID()
    settings.roots.sources = [GlacierSourceRoot(id: id, path: "/tmp/one"),
                              GlacierSourceRoot(id: id, path: "/tmp/two")]
    #expect(throws: GlacierConfigurationError.invalidPath("Duplicate source identifier")) {
        try settings.validate()
    }
    settings.roots.sources = [GlacierSourceRoot(path: "/tmp/same", enabled: true),
                              GlacierSourceRoot(path: "/tmp/same", enabled: false)]
    #expect(throws: GlacierConfigurationError.invalidPath("Duplicate canonical source path")) {
        try settings.validate()
    }
}

@Test func existingAndReplacedSettingsUsePrivateModesWithoutFollowingSymlinks() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let support = temp.appendingPathComponent("Glacier")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: support.path)
    let settingsURL = support.appendingPathComponent("settings.json")
    try Data(#"{"version":2}"#.utf8).write(to: settingsURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: settingsURL.path)
    let paths = try GlacierPaths(home: temp, supportOverride: support)
    let store = try GlacierSettingsStore(paths: paths)
    func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    #expect(try mode(support) == 0o700)
    #expect(try mode(settingsURL) == 0o600)
    try await store.update { $0.modules["translation"] = .init(enabled: false) }
    #expect(try mode(settingsURL) == 0o600)

    let foreign = temp.appendingPathComponent("foreign")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: foreign.path)
    let alias = temp.appendingPathComponent("other/Glacier")
    try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
    #expect(throws: GlacierConfigurationError.self) {
        try GlacierPaths(home: temp, supportOverride: alias)
    }
    #expect(try mode(foreign) == 0o777)

    let source = temp.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceAlias = temp.appendingPathComponent("source-alias")
    try FileManager.default.createSymbolicLink(at: sourceAlias, withDestinationURL: source)
    var duplicateRoots = GlacierSettings()
    duplicateRoots.roots.sources = [GlacierSourceRoot(path: source.path),
                                    GlacierSourceRoot(path: sourceAlias.path, enabled: false)]
    #expect(throws: GlacierConfigurationError.invalidPath("Duplicate canonical source path")) {
        try duplicateRoots.validate()
    }
}
