import Foundation
import OmniApplication
import OmniCore
import OmniFixtures
import OmniRun
import Testing

/// A minimal rig mirroring `ApplicationTestRig` in OmniApplicationTests.swift
/// (that type is file-private there, so it cannot be reused directly here).
private struct ProvenanceTestRig {
    let envelope: URL
    let store: OmniRunStore
    let service: OmniApplicationService

    static func make() async throws -> ProvenanceTestRig {
        let envelope = FileManager.default.temporaryDirectory.appendingPathComponent("omni-provenance-tests-\(UUID().uuidString)", isDirectory: true)
        let root = envelope.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corpus = FrozenContractCorpus()
        let manifest = try corpus.manifest()
        let declarations = try corpus.moduleDeclarations().declarations
        let validatedRoot = try OmniDevelopmentRoot(validating: root, allowedRoot: envelope)
        let catalog = try FixtureModuleCatalog(manifest: manifest, declarations: declarations, developmentRoot: validatedRoot)
        let references = try ReferenceRegistry([])
        let store = try OmniRunStore(developmentRoot: root, allowedRoot: envelope)
        let service = OmniApplicationService(
            parser: OmniParser(manifest: manifest, references: references),
            registry: catalog.registry,
            proposalSource: FakeTier2ProposalSource(),
            store: store,
            executionTimeout: .seconds(5)
        )
        return ProvenanceTestRig(envelope: envelope, store: store, service: service)
    }

    func remove() { try? FileManager.default.removeItem(at: envelope) }
}

@Test func submissionWithProvenanceStoresItOnTheReceiptAndSurfacesItOnResultViewModel() async throws {
    let rig = try await ProvenanceTestRig.make()
    defer { rig.remove() }
    let provenance = OmniRunProvenance(appName: "Mail", windowTitle: "Re: Quarterly plan", wordCount: 40)

    let submission = try await rig.service.submit("/todo buy milk", provenance: provenance)
    let runID = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: runID)

    let receipt = try #require(await rig.store.receipt(for: runID))
    #expect(receipt.runtimeContext?.provenance == provenance)

    let viewModel = try #require(await rig.service.resultViewModel(runID: runID))
    #expect(viewModel.provenance == provenance)
}

@Test func submissionWithoutProvenanceLeavesItNilEverywhere() async throws {
    let rig = try await ProvenanceTestRig.make()
    defer { rig.remove() }

    let submission = try await rig.service.submit("/todo buy milk")
    let runID = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: runID)

    let receipt = try #require(await rig.store.receipt(for: runID))
    #expect(receipt.runtimeContext?.provenance == nil)
    #expect((await rig.service.resultViewModel(runID: runID))?.provenance == nil)
}

@Test func reconstructRecentResultsSurfacesProvenanceAfterARestart() async throws {
    let rig = try await ProvenanceTestRig.make()
    defer { rig.remove() }
    let provenance = OmniRunProvenance(appName: "Notes", windowTitle: nil, wordCount: 12)

    let submission = try await rig.service.submit("/todo write proposal", provenance: provenance)
    let runID = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: runID)

    let results = try await rig.service.reconstructRecentResults()
    let restored = try #require(results.first { $0.runID == runID.rawValue })
    #expect(restored.provenance == provenance)
}

@Test func retryCarriesTheOriginalRunsProvenanceIntoTheNewRun() async throws {
    let rig = try await ProvenanceTestRig.make()
    defer { rig.remove() }
    let provenance = OmniRunProvenance(appName: "Mail", windowTitle: "Re: Quarterly plan", wordCount: 40)

    let submission = try await rig.service.submit("/qq [fixture:execution-failure] explain", provenance: provenance)
    let runID = try #require(submission.runID)
    let failed = try await rig.service.waitForTerminal(runID: runID)
    #expect(failed.state == .failed)

    let retrySubmission = try await rig.service.retry(runID: runID)
    let retryID = try #require(retrySubmission.runID)
    let retryReceipt = try #require(await rig.store.receipt(for: retryID))
    #expect(retryReceipt.runtimeContext?.provenance == provenance)
}

@Test func submissionPersistsAnnotationsAndRetryCarriesOnlyExactRawRanges() async throws {
    let rig = try await ProvenanceTestRig.make()
    defer { rig.remove() }
    let text = "/qq [fixture:execution-failure] explain"
    let note = OmniTextAnnotation(range: NSRange(location: 32, length: 7), guidance: "Use plain language")
    let submission = try await rig.service.submit(text, annotations: [note])
    let runID = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: runID)
    #expect((await rig.store.receipt(for: runID))?.runtimeContext?.annotations == [note])

    let retry = try await rig.service.retry(runID: runID)
    let retryID = try #require(retry.runID)
    #expect(retry.annotationNotice == nil)
    #expect((await rig.store.receipt(for: retryID))?.runtimeContext?.annotations == [note])

    var tampered = try #require(await rig.store.receipt(for: runID)?.runtimeContext)
    tampered.annotations = [OmniTextAnnotation(range: NSRange(location: 1000, length: 2), guidance: "Cannot map")]
    try await rig.store.updateRuntimeContext(runID, context: tampered)
    let dropped = try await rig.service.retry(runID: runID)
    let droppedID = try #require(dropped.runID)
    #expect(dropped.annotationNotice != nil)
    #expect((await rig.store.receipt(for: droppedID))?.runtimeContext?.annotations.isEmpty == true)
}

@Test func submissionSurfacesAndStoresNoticeForRejectedAnnotationRanges() async throws {
    let rig = try await ProvenanceTestRig.make()
    defer { rig.remove() }
    let invalid = OmniTextAnnotation(range: NSRange(location: 999, length: 2), guidance: "Impossible")
    let submission = try await rig.service.submit("/todo buy milk", annotations: [invalid])
    let runID = try #require(submission.runID)
    #expect(submission.annotationNotice != nil)
    let context = try #require(await rig.store.receipt(for: runID)?.runtimeContext)
    #expect(context.annotations.isEmpty)
    #expect(context.annotationNotice == submission.annotationNotice)
}
