import Foundation
import GlacierConfiguration
@testable import GlacierSearch
import OmniCore
import Testing

private func fixtureDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Test func sourcePolicyAppliesRootOptionsAndProtectsAliases() throws {
    let temp = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let child = source.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let protected = source.appendingPathComponent("protected")
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
    let alias = source.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
    let root = GlacierSourceRoot(path: source.path, recursive: false,
                                 excludedNames: ["skip"], includeSourceFiles: false, includeHidden: false)
    let policy = SourcePolicy(roots: [root], protectedRoots: [protected])
    #expect(policy.permits(source.appendingPathComponent("readme.md").path))
    #expect(policy.permits(child.appendingPathComponent("nested.md").path) == false)
    #expect(policy.permits(source.appendingPathComponent("code.swift").path) == false)
    #expect(policy.permits(source.appendingPathComponent(".secret").path) == false)
    #expect(policy.permits(source.appendingPathComponent("skip").path) == false)
    #expect(policy.permits(protected.path) == false)
    #expect(policy.permits(alias.path) == false)
    #expect(policy.permits(source.appendingPathComponent("../protected").path) == false)

    let permissive = SourcePolicy(roots: [GlacierSourceRoot(path: source.path,
                                                             includeSourceFiles: true, includeHidden: true)],
                                  protectedRoots: [protected])
    #expect(permissive.permits(source.appendingPathComponent("code.swift").path))
    #expect(permissive.permits(source.appendingPathComponent(".secret").path))
    #expect(permissive.permits(source.appendingPathComponent(".git/config").path) == false)
    for secret in [".ssh/id_ed25519", ".aws/credentials", ".gnupg/private-keys-v1.d/key",
                   ".config/service/token", ".env", ".env.local", ".netrc", "secret.pem"] {
        #expect(permissive.permits(source.appendingPathComponent(secret).path) == false, "\(secret)")
    }
    #expect(permissive.permits(child.appendingPathComponent("nested.md").path))

    let disabledChild = GlacierSourceRoot(path: child.path, enabled: false)
    let overlap = SourcePolicy(roots: [GlacierSourceRoot(path: source.path), disabledChild],
                               protectedRoots: [protected])
    #expect(overlap.permits(child.appendingPathComponent("nested.md").path) == false)
    let duplicate = SourcePolicy(roots: [GlacierSourceRoot(path: source.path, enabled: true),
                                         GlacierSourceRoot(path: source.path, enabled: false)],
                                 protectedRoots: [protected])
    #expect(duplicate.permits(source.appendingPathComponent("readme.md").path) == false)
}

@Test func buildIndexesMetadataWithoutBodyAndReportsMissingRoots() async throws {
    let temp = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("source")
    let output = temp.appendingPathComponent("index")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let good = source.appendingPathComponent("good.md")
    try write("---\nid: 0123456789abcdef\ntitle: Found title\nkind: note\n---\nSECRET BODY\n", at: good)
    let tooLarge = source.appendingPathComponent("large.md")
    try write("---\n" + String(repeating: "x", count: 8_300) + "\nid: fedcba9876543210\n---\n", at: tooLarge)
    try write("let privateCode = 1", at: source.appendingPathComponent("code.swift"))
    try write("hidden", at: source.appendingPathComponent(".hidden"))
    let missing = temp.appendingPathComponent("missing")
    let policy = SourcePolicy(roots: [GlacierSourceRoot(path: source.path),
                                      GlacierSourceRoot(path: missing.path)],
                              protectedRoots: [output])
    let service = try GlacierSearchService(directory: output, policy: policy)
    let snapshot = try await service.build()
    #expect(snapshot.candidates.contains { $0.path == good.path && $0.documentID == "0123456789abcdef" && $0.title == "Found title" })
    #expect(snapshot.candidates.first { $0.path == tooLarge.path }?.documentID == nil)
    #expect(!snapshot.candidates.contains { $0.path.hasSuffix(".swift") })
    #expect(!snapshot.candidates.contains { $0.path == source.appendingPathComponent(".hidden").path })
    #expect(snapshot.stats.unreadableRoots == [missing.path])
    let index = try service.currentIndex()
    let allPrivate = index.documents.allSatisfy { $0.isPrivate }
    #expect(allPrivate)
    #expect(index.documents.contains { $0.documentID == "0123456789abcdef" })
    #expect(try Data(contentsOf: output.appendingPathComponent("metadata-index.json"))
        .range(of: Data("SECRET BODY".utf8)) == nil)
}

@Test func implicitAppRootsIndexOnlyAppsWhileExplicitFoldersRetainFilesAndRevocation() async throws {
    let temp = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let apps = temp.appendingPathComponent("Applications")
    let topApp = apps.appendingPathComponent("Top.app")
    let vendor = apps.appendingPathComponent("Vendor")
    let nestedApp = vendor.appendingPathComponent("Nested.app")
    let looseTop = apps.appendingPathComponent("texture.png")
    let looseNested = vendor.appendingPathComponent("level.dat")
    try write("app", at: topApp.appendingPathComponent("Contents/Info.plist"))
    try write("app", at: nestedApp.appendingPathComponent("Contents/Info.plist"))
    try write("asset", at: looseTop)
    try write("asset", at: looseNested)

    let output = temp.appendingPathComponent("index")
    let implicit = GlacierSourceRoot(path: apps.path, applicationDiscoveryOnly: true)
    let appPolicy = SourcePolicy(roots: [implicit], protectedRoots: [output])
    let service = try GlacierSearchService(directory: output, policy: appPolicy)
    let appsOnly = try await service.build()
    #expect(Set(appsOnly.candidates.map(\.path)) == Set([topApp.path, nestedApp.path]))
    #expect(appsOnly.candidates.allSatisfy { $0.kind == "app" && $0.source == .apps })
    #expect(appPolicy.permits(topApp.path) && appPolicy.permits(nestedApp.path))
    #expect(!appPolicy.permits(vendor.path) && !appPolicy.permits(looseTop.path))
    #expect(appPolicy.permitsTraversal(vendor.path))
    #expect(!appPolicy.permitsTraversal(looseNested.path))

    let newApp = vendor.appendingPathComponent("New.app")
    let newInfo = newApp.appendingPathComponent("Contents/Info.plist")
    try write("new app", at: newInfo)
    let added = try service.reconcile(paths: [newInfo.path], event: nil)
    #expect(Set(added.candidates.map(\.path)) == Set([topApp.path, nestedApp.path, newApp.path]))
    #expect(appPolicy.rescanPath(for: newInfo.path) == newApp.path)

    let embeddedApp = topApp.appendingPathComponent("Contents/Helpers/Helper.app")
    let embeddedInfo = embeddedApp.appendingPathComponent("Contents/Info.plist")
    try write("embedded", at: embeddedInfo)
    let afterEmbedded = try service.reconcile(paths: [embeddedInfo.path], event: nil)
    #expect(appPolicy.rescanPath(for: embeddedInfo.path) == topApp.path)
    #expect(Set(afterEmbedded.candidates.map(\.path)) == Set([topApp.path, nestedApp.path, newApp.path]))

    try FileManager.default.removeItem(at: newApp)
    let afterDeletion = try service.reconcile(paths: [newInfo.path], event: nil)
    #expect(appPolicy.rescanPath(for: newInfo.path) == newApp.path)
    #expect(Set(afterDeletion.candidates.map(\.path)) == Set([topApp.path, nestedApp.path]))

    let explicit = GlacierSourceRoot(path: vendor.path)
    try service.replacePolicy(SourcePolicy(roots: [implicit, explicit], protectedRoots: [output]))
    let withFiles = try await service.build()
    #expect(withFiles.candidates.contains { $0.path == looseNested.path })
    #expect(!withFiles.candidates.contains { $0.path == looseTop.path })
    #expect(withFiles.candidates.contains { $0.path == nestedApp.path })
    let nestedInfo = nestedApp.appendingPathComponent("Contents/Info.plist")
    let explicitPolicy = SourcePolicy(roots: [implicit, explicit], protectedRoots: [output])
    #expect(explicitPolicy.rescanPath(for: nestedInfo.path) == nestedApp.path)
    let afterExplicitBundleEvent = try service.reconcile(paths: [nestedInfo.path], event: nil)
    #expect(Set(afterExplicitBundleEvent.candidates.map(\.path)) == Set(withFiles.candidates.map(\.path)))
    #expect(!afterExplicitBundleEvent.candidates.contains { $0.path == nestedInfo.path })

    try service.replacePolicy(appPolicy)
    #expect(try service.load()?.candidates.isEmpty == true)
    #expect(!service.permits(looseNested.path))
    #expect(!(try service.currentIndex()).documents.contains { $0.path == looseNested.path })
    let revoked = try await service.build()
    #expect(Set(revoked.candidates.map(\.path)) == Set([topApp.path, nestedApp.path]))

    let disabledVendor = GlacierSourceRoot(path: vendor.path, enabled: false)
    try service.replacePolicy(SourcePolicy(roots: [implicit, disabledVendor], protectedRoots: [output]))
    #expect(try await service.build().candidates.map(\.path) == [topApp.path])

    let legacyOutput = temp.appendingPathComponent("legacy-index")
    let legacyRoot = GlacierSourceRoot(id: implicit.id, path: apps.path)
    let legacy = try GlacierSearchService(directory: legacyOutput,
        policy: SourcePolicy(roots: [legacyRoot], protectedRoots: [legacyOutput]))
    #expect(try await legacy.build().candidates.contains { $0.path == looseTop.path })
    let upgraded = try GlacierSearchService(directory: legacyOutput,
        policy: SourcePolicy(roots: [implicit], protectedRoots: [legacyOutput]))
    #expect(try upgraded.load()?.candidates.isEmpty == true)
    #expect(!(try upgraded.currentIndex()).documents.contains { $0.path == looseTop.path })
}

@Test func directAppRootRescansBundleWithoutExposingEmbeddedHelpers() async throws {
    let temp = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let finder = temp.appendingPathComponent("CoreServices/Finder.app")
    let info = finder.appendingPathComponent("Contents/Info.plist")
    let helper = finder.appendingPathComponent("Contents/Helpers/Helper.app")
    try write("finder", at: info)
    try write("helper", at: helper.appendingPathComponent("Contents/Info.plist"))
    let output = temp.appendingPathComponent("index")
    let appRoot = GlacierSourceRoot(path: finder.path, applicationDiscoveryOnly: true)
    let policy = SourcePolicy(roots: [appRoot], protectedRoots: [output])
    let service = try GlacierSearchService(directory: output, policy: policy)
    #expect(Set(try await service.build().candidates.map(\.path)) == [finder.path])
    #expect(policy.permits(finder.path))
    #expect(!policy.permits(helper.path) && !policy.permitsTraversal(info.path))
    #expect(policy.rescanPath(for: info.path) == finder.path)
    #expect(Set(try service.reconcile(paths: [info.path], event: nil).candidates.map(\.path)) == [finder.path])
    try service.replacePolicy(SourcePolicy(roots: [], protectedRoots: [output]))
    #expect(try service.load()?.candidates.isEmpty == true)
    #expect(!service.permits(finder.path))
}

@Test func revocationSurvivesRestartAndRejectsOldGenerationAfterABA() async throws {
    let temp = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("source")
    let output = temp.appendingPathComponent("index")
    let file = source.appendingPathComponent("visible.md")
    try write("hello", at: file)
    let allow = SourcePolicy(roots: [GlacierSourceRoot(path: source.path)], protectedRoots: [output])
    let deny = SourcePolicy(roots: [], protectedRoots: [output])
    let service = try GlacierSearchService(directory: output, policy: allow)
    let stale = try await service.build()
    #expect(stale.candidates.contains { $0.path == file.path })
    try service.replacePolicy(deny)
    #expect(try service.load()?.candidates.isEmpty == true)
    let deniedRestart = try GlacierSearchService(directory: output, policy: deny)
    #expect(try deniedRestart.load()?.candidates.isEmpty == true)
    try service.replacePolicy(allow)
    try service.save(stale)
    #expect(try service.load()?.candidates.isEmpty == true)
    let allowedRestart = try GlacierSearchService(directory: output, policy: allow)
    #expect(try allowedRestart.load()?.candidates.isEmpty == true)
    #expect(try await service.build().candidates.contains { $0.path == file.path })
}

@Test func markerAndSymlinkCannotExpandSearchAuthority() async throws {
    let temp = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("source")
    let nested = source.appendingPathComponent("marked")
    try write("", at: nested.appendingPathComponent(".nolaunch"))
    try write("private", at: nested.appendingPathComponent("no.md"))
    let outside = temp.appendingPathComponent("outside")
    try write("private", at: outside.appendingPathComponent("no.md"))
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("alias"),
                                                withDestinationURL: outside)
    let service = try GlacierSearchService(directory: temp.appendingPathComponent("index"),
                                           policy: SourcePolicy(roots: [GlacierSourceRoot(path: source.path)],
                                                                protectedRoots: [outside]))
    let snapshot = try await service.build()
    #expect(!snapshot.candidates.contains { $0.path == nested.appendingPathComponent("no.md").path })
    #expect(!snapshot.candidates.contains { $0.path.contains("alias") })
    #expect(!snapshot.candidates.contains { $0.path == outside.appendingPathComponent("no.md").path })
}

@Test func explicitlySelectedFileRootIsIndexedWithoutWalkingItsParent() async throws {
    let temp = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let chosen = temp.appendingPathComponent("chosen.md")
    let other = temp.appendingPathComponent("other.md")
    try write("chosen", at: chosen)
    try write("other", at: other)
    let output = temp.appendingPathComponent("index")
    let service = try GlacierSearchService(directory: output,
                                           policy: SourcePolicy(roots: [GlacierSourceRoot(path: chosen.path)],
                                                                protectedRoots: [output]))
    let snapshot = try await service.build()
    #expect(snapshot.candidates.map(\.path) == [chosen.path])
}

@Test func cachedFindIndexHandlesTenThousandSyntheticRows() throws {
    let temp = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("source")
    let output = temp.appendingPathComponent("index")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let service = try GlacierSearchService(directory: output,
                                           policy: SourcePolicy(roots: [GlacierSourceRoot(path: source.path)],
                                                                protectedRoots: [output]))
    let rows = (0..<10_000).map { index in
        LauncherCandidate(title: "Document \(index)",
                          path: source.appendingPathComponent("document-\(index).md").path,
                          kind: "md", source: .files)
    }
    let proposed = LauncherSnapshot(builtAt: Date(), docsGeneration: service.currentDocsGeneration(),
                                    buildMilliseconds: 0, stats: .init(), candidates: rows)
    try service.save(proposed)
    #expect(service.cachedIndex()?.documents.count == 10_000)
    #expect(service.cachedIndex()?.documents.count == 10_000)
}

@Test func searchStateModesAreTightenedWithoutFollowingForeignSymlinks() async throws {
    let temp = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("source")
    let output = temp.appendingPathComponent("index")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: output.path)
    let metadata = output.appendingPathComponent("metadata-index.json")
    try Data("{}".utf8).write(to: metadata)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: metadata.path)
    let policy = SourcePolicy(roots: [GlacierSourceRoot(path: source.path)], protectedRoots: [output])
    let service = try GlacierSearchService(directory: output, policy: policy)
    func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    #expect(try mode(output) == 0o700)
    #expect(try mode(metadata) == 0o600)
    _ = try await service.build()
    #expect(try mode(metadata) == 0o600)

    let foreign = temp.appendingPathComponent("foreign")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: foreign.path)
    let alias = temp.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
    do { _ = try GlacierSearchService(directory: alias, policy: policy); Issue.record("Search accepted a symlinked state directory") }
    catch { }
    #expect(try mode(foreign) == 0o777)

    let foreignFile = foreign.appendingPathComponent("foreign.json")
    try Data("{}".utf8).write(to: foreignFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: foreignFile.path)
    try FileManager.default.removeItem(at: metadata)
    try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: foreignFile)
    do { _ = try GlacierSearchService(directory: output, policy: policy); Issue.record("Search accepted a symlinked index") }
    catch { }
    #expect(try mode(foreignFile) == 0o666)
}
