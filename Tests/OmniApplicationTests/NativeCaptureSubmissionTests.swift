import Foundation
import OmniApplication
import OmniCore
import OmniFixtures
import OmniRun
import Testing

@Test func nativeCaptureSubmitsLiteralNoteAndNormalizedLinkThroughFixedRoutes() async throws {
    let envelope = FileManager.default.temporaryDirectory.appendingPathComponent("omni-native-capture-\(UUID().uuidString)")
    let root = envelope.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: envelope) }
    let corpus = FrozenContractCorpus()
    let manifest = try corpus.manifest()
    let declarations = try corpus.moduleDeclarations().declarations
    let catalog = try FixtureModuleCatalog(manifest: manifest, declarations: declarations,
        developmentRoot: try OmniDevelopmentRoot(validating: root, allowedRoot: envelope))
    let store = try OmniRunStore(developmentRoot: root, allowedRoot: envelope)
    let service = OmniApplicationService(parser: OmniParser(manifest: manifest, references: try ReferenceRegistry([])),
        registry: catalog.registry, proposalSource: FakeTier2ProposalSource(), store: store)

    let literal = "First line /todo /fav @work ✓\nSecond line"
    let note = try await service.submitCapture(literal)
    let noteID = try #require(note.runID)
    #expect(note.kind == .tier1Queued)
    #expect((try await service.waitForTerminal(runID: noteID)).state == .succeeded)
    #expect((await store.receipt(for: noteID))?.moduleID == "capture.base")
    #expect((await store.receipt(for: noteID))?.runtimeContext?.input?.payloadText == literal)
    // The legacy fake owner tokenizes canonical text. Literal file preservation
    // is checked through the real replica owner in OmniAdaptersTests.

    let link = try await service.submitCapture("www.example.com/a?x=1")
    let linkID = try #require(link.runID)
    #expect((try await service.waitForTerminal(runID: linkID)).state == .succeeded)
    #expect((await store.receipt(for: linkID))?.moduleID == "capture.favorite")
    #expect(try await catalog.owner.contents(relativePath: "favorites/\(linkID.rawValue).txt") == "https://www.example.com/a?x=1")
}

@Test func emptyNativeCaptureNeverCreatesARun() async throws {
    let envelope = FileManager.default.temporaryDirectory.appendingPathComponent("omni-empty-capture-\(UUID().uuidString)")
    let root = envelope.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: envelope) }
    let corpus = FrozenContractCorpus()
    let manifest = try corpus.manifest()
    let declarations = try corpus.moduleDeclarations().declarations
    let catalog = try FixtureModuleCatalog(manifest: manifest, declarations: declarations,
        developmentRoot: try OmniDevelopmentRoot(validating: root, allowedRoot: envelope))
    let store = try OmniRunStore(developmentRoot: root, allowedRoot: envelope)
    let service = OmniApplicationService(parser: OmniParser(manifest: manifest, references: try ReferenceRegistry([])),
        registry: catalog.registry, proposalSource: FakeTier2ProposalSource(), store: store)
    await #expect(throws: OmniApplicationError.emptyCapture) { _ = try await service.submitCapture(" \n") }
    #expect(await store.recentRuns(limit: 10).isEmpty)
}
