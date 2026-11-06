import Foundation
import XCTest
@testable import OmniCore

final class Phase4ProposalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    func testModelCommandsBecomeHashPinnedTypedAlternativeWithoutExecution() throws {
        let fixture = try makeFixture()
        let intent = fixture.parser.parse("/unknown @zoe /offline")
        let authority = fixture.validator.makeAuthoritySnapshot(
            allowedCapabilities: [.appendLedger, .appendOfficeQueue],
            allowedOwnerOperations: [.appendLedger, .appendOfficeQueue],
            offline: false
        )
        let envelope = try fixture.validator.decodeModelProposal(
            modelJSON("""
            {"alternatives":[
              {"id":"capture-sequence","title":"Capture both","commands":[
                "/todo buy milk @people:zoe /offline",
                "/remind call dentist /offline"
              ]},
              {"id":"todo-only","title":"Capture task","commands":["/todo buy milk @people:zoe /offline"]}
            ]}
            """),
            for: intent,
            authority: authority,
            now: now
        )

        XCTAssertEqual(envelope.rawText, "/unknown @zoe /offline")
        XCTAssertEqual(envelope.canonicalText, "/unknown @people:zoe /offline")
        XCTAssertEqual(envelope.alternatives.count, 2)
        let sequence = try XCTUnwrap(envelope.alternatives.first)
        XCTAssertEqual(sequence.steps.map(\.moduleID), ["capture.todo", "cache.remind"])
        XCTAssertEqual(sequence.steps.map(\.offline), [true, true])
        XCTAssertEqual(sequence.steps[0].input.payloadText, "buy milk @people:zoe")
        XCTAssertEqual(sequence.steps[0].input.references, [fixture.zoe])
        XCTAssertEqual(sequence.planHash.count, 64)

        // Validation and selection expose only a typed plan; neither invokes a module.
        XCTAssertNoThrow(try fixture.validator.validate(envelope: envelope, authority: authority, now: now))
        let selected = try fixture.validator.confirm(
            envelope: envelope,
            exactPlanHash: sequence.planHash,
            authority: authority,
            now: now
        )
        XCTAssertEqual(selected, sequence)
    }

    func testProposalStepsPreserveTranslateLangcode() throws {
        let commands = [
            ManifestCommand(
                token: "/translate",
                role: .primary,
                moduleID: "translate",
                execution: .modelBacked,
                capabilities: [.draftCommunication],
                acceptedModes: ["/offline"],
                value: TokenValueSpec(type: .langcode, required: false)
            ),
            ManifestCommand(token: "/offline", role: .mode, moduleID: "", execution: .policy, capabilities: [])
        ]
        let document = ManifestDocument(
            schemaVersion: 1,
            commands: commands,
            valueTypes: ManifestValueTypes(
                length: nil,
                langcode: ManifestValueTypes.LangcodeType(codes: ["de", "en", "en-GB", "en-US"]),
                enums: [:]
            )
        )
        let manifest = try CommandManifest(document: document)
        let parser = try OmniParser(manifest: manifest, references: ReferenceRegistry([]))
        let policies = ModulePolicies(
            input: InputPolicy(profile: "test"), authority: AuthorityPolicy(profile: "test"),
            model: ModelPolicy(profile: "none"), references: ReferencePolicy(profile: "test"),
            result: ResultPolicy(profile: "test"), retry: RetryPolicy(profile: "none"), timeout: TimeoutPolicy(profile: "test")
        )
        let registry = try ModuleRegistry([
            AnyCommandModuleFactory(moduleID: "translate") {
                ProposalFixtureModule(
                    descriptor: ModuleDescriptor(
                        moduleID: "translate",
                        moduleVersion: 1,
                        execution: .modelBacked,
                        capabilities: [.draftCommunication],
                        policies: policies
                    ),
                    operation: nil
                )
            }
        ])
        let validator = ProposalPlanValidator(parser: parser, registry: registry)
        let authority = validator.makeAuthoritySnapshot(
            allowedCapabilities: [.draftCommunication],
            allowedOwnerOperations: [],
            offline: false
        )
        let envelope = try validator.decodeModelProposal(
            modelJSON("""
            {"alternatives":[{"id":"de","title":"German","commands":["/translate:de hello /offline"]}]}
            """),
            for: parser.parse("translate this"),
            authority: authority,
            now: now
        )
        let step = try XCTUnwrap(envelope.alternatives.first?.steps.first)
        XCTAssertEqual(step.input.tokenValues["/translate"], .langcode("de"))
        XCTAssertEqual(step.input.payloadText, "hello")
    }

    func testModelSchemaAndCommandTextRejectCapabilityOrExecutionEscapeHatches() throws {
        let fixture = try makeFixture()
        let intent = fixture.parser.parse("unstructured request")
        let authority = fixture.authority

        for body in [
            "{\"alternatives\":[],\"capabilities\":[\"write-settings\"]}",
            "{\"alternatives\":[{\"id\":\"x\",\"title\":\"X\",\"commands\":[\"/todo --force\"]}]}",
            "{\"alternatives\":[{\"id\":\"x\",\"title\":\"X\",\"commands\":[\"/todo PATH=/tmp/unsafe\"]}]}",
            "{\"alternatives\":[{\"id\":\"x\",\"title\":\"X\",\"commands\":[\"/todo https://example.com\"]}]}",
            "{\"alternatives\":[{\"id\":\"x\",\"title\":\"X\",\"commands\":[\"/unknown do thing\"]}]}"
        ] {
            XCTAssertThrowsError(try fixture.validator.decodeModelProposal(
                Data(body.utf8), for: intent, authority: authority, now: now
            ), "expected rejection for \(body)")
        }
    }

    func testRevalidationRejectsStaleAuthorityExpiryAndEditedOrAdditionalReferences() throws {
        let fixture = try makeFixture(includeAdditionalReference: true)
        let source = fixture.parser.parse("/unknown @zoe /offline")
        let envelope = try fixture.validator.decodeModelProposal(
            modelJSON("""
            {"alternatives":[{"id":"todo","title":"Capture task","commands":["/todo buy milk @people:zoe /offline"]}]}
            """),
            for: source,
            authority: fixture.authority,
            now: now
        )
        let hash = try XCTUnwrap(envelope.alternatives.first?.planHash)
        XCTAssertThrowsError(try fixture.validator.confirm(
            envelope: envelope,
            exactPlanHash: hash,
            authority: fixture.validator.makeAuthoritySnapshot(
                allowedCapabilities: [.appendOfficeQueue],
                allowedOwnerOperations: [.appendOfficeQueue],
                offline: false
            ),
            now: now
        ))
        XCTAssertThrowsError(try fixture.validator.confirm(
            envelope: envelope,
            exactPlanHash: hash,
            authority: fixture.authority,
            now: now.addingTimeInterval(301)
        ))

        XCTAssertThrowsError(try fixture.validator.decodeModelProposal(
            modelJSON("""
            {"alternatives":[{"id":"ref","title":"Unexpected ref","commands":["/todo buy milk @people:alex /offline"]}]}
            """),
            for: source,
            authority: fixture.authority,
            now: now
        ))
        XCTAssertThrowsError(try fixture.validator.decodeModelProposal(
            modelJSON("""
            {"alternatives":[{"id":"offline","title":"Drops mode","commands":["/todo buy milk @people:zoe"]}]}
            """),
            for: source,
            authority: fixture.authority,
            now: now
        ))
    }

    func testDurableEnvelopeDecoderRejectsUnknownFieldsAndConfirmationRequiresExactHash() throws {
        let fixture = try makeFixture()
        let envelope = try fixture.validator.decodeModelProposal(
            modelJSON("""
            {"alternatives":[{"id":"todo","title":"Capture task","commands":["/todo buy milk"]}]}
            """),
            for: fixture.parser.parse("something unclear"),
            authority: fixture.authority,
            now: now
        )
        XCTAssertThrowsError(try fixture.validator.confirm(
            envelope: envelope,
            exactPlanHash: "edited-plan",
            authority: fixture.authority,
            now: now
        ))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        object["shell"] = "/bin/sh"
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProposalEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))

        var nested = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        var alternatives = try XCTUnwrap(nested["alternatives"] as? [[String: Any]])
        var first = try XCTUnwrap(alternatives.first)
        var steps = try XCTUnwrap(first["steps"] as? [[String: Any]])
        var step = try XCTUnwrap(steps.first)
        var input = try XCTUnwrap(step["input"] as? [String: Any])
        input["environment"] = ["PATH": "/tmp/unsafe"]
        step["input"] = input
        steps[0] = step
        first["steps"] = steps
        alternatives[0] = first
        nested["alternatives"] = alternatives
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProposalEnvelope.self,
            from: JSONSerialization.data(withJSONObject: nested)
        ))
        var valued = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        var valuedAlternatives = try XCTUnwrap(valued["alternatives"] as? [[String: Any]])
        var valuedFirst = try XCTUnwrap(valuedAlternatives.first)
        var valuedSteps = try XCTUnwrap(valuedFirst["steps"] as? [[String: Any]])
        var valuedStep = try XCTUnwrap(valuedSteps.first)
        var valuedInput = try XCTUnwrap(valuedStep["input"] as? [String: Any])
        valuedInput["tokenValues"] = ["/translate": ["type": "langcode", "value": "de", "shell": "/bin/sh"]]
        valuedStep["input"] = valuedInput
        valuedSteps[0] = valuedStep
        valuedFirst["steps"] = valuedSteps
        valuedAlternatives[0] = valuedFirst
        valued["alternatives"] = valuedAlternatives
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProposalEnvelope.self,
            from: JSONSerialization.data(withJSONObject: valued)
        ))
        XCTAssertNoThrow(try JSONDecoder().decode(ProposalEnvelope.self, from: JSONEncoder().encode(envelope)))
    }

    private func modelJSON(_ text: String) -> Data { Data(text.utf8) }

    private func makeFixture(includeAdditionalReference: Bool = false) throws -> ProposalFixture {
        let zoe = PinnedReference(
            id: "person_zoe",
            namespace: "people",
            key: "zoe",
            snapshot: ReferenceSnapshot(sourceVersion: "test-v1", resolvedAt: now)
        )
        let alex = PinnedReference(
            id: "person_alex",
            namespace: "people",
            key: "alex",
            snapshot: ReferenceSnapshot(sourceVersion: "test-v1", resolvedAt: now)
        )
        let commands = [
            ManifestCommand(token: "/todo", role: .primary, moduleID: "capture.todo", execution: .deterministicLocal, capabilities: [.appendLedger], acceptedModes: ["/offline"]),
            ManifestCommand(token: "/remind", role: .primary, moduleID: "cache.remind", execution: .deterministicLocal, capabilities: [.appendOfficeQueue], acceptedModes: ["/offline"]),
            ManifestCommand(token: "/offline", role: .mode, moduleID: "", execution: .policy, capabilities: [])
        ]
        let manifest = try CommandManifest(document: ManifestDocument(schemaVersion: 1, commands: commands))
        let parser = try OmniParser(manifest: manifest, references: ReferenceRegistry(includeAdditionalReference ? [zoe, alex] : [zoe]))
        let policies = ModulePolicies(
            input: InputPolicy(profile: "test"), authority: AuthorityPolicy(profile: "test"),
            model: ModelPolicy(profile: "none"), references: ReferencePolicy(profile: "test"),
            result: ResultPolicy(profile: "test"), retry: RetryPolicy(profile: "none"), timeout: TimeoutPolicy(profile: "test")
        )
        let registry = try ModuleRegistry([
            AnyCommandModuleFactory(moduleID: "capture.todo") {
                ProposalFixtureModule(
                    descriptor: ModuleDescriptor(moduleID: "capture.todo", moduleVersion: 1, execution: .deterministicLocal, capabilities: [.appendLedger], policies: policies),
                    operation: .appendLedger
                )
            },
            AnyCommandModuleFactory(moduleID: "cache.remind") {
                ProposalFixtureModule(
                    descriptor: ModuleDescriptor(moduleID: "cache.remind", moduleVersion: 1, execution: .deterministicLocal, capabilities: [.appendOfficeQueue], policies: policies),
                    operation: .appendOfficeQueue
                )
            }
        ])
        let validator = ProposalPlanValidator(parser: parser, registry: registry)
        let authority = validator.makeAuthoritySnapshot(
            allowedCapabilities: [.appendLedger, .appendOfficeQueue],
            allowedOwnerOperations: [.appendLedger, .appendOfficeQueue],
            offline: false
        )
        return ProposalFixture(parser: parser, validator: validator, authority: authority, zoe: zoe)
    }
}

private struct ProposalFixture {
    let parser: OmniParser
    let validator: ProposalPlanValidator
    let authority: ProposalAuthoritySnapshot
    let zoe: PinnedReference
}

private struct ProposalFixtureModule: CommandModule {
    let descriptor: ModuleDescriptor
    let operation: OwnerOperation?

    func validate(input: ModuleInput) throws {}

    func makePlan(input: ModuleInput) throws -> CommandPlan {
        CommandPlan(
            moduleID: descriptor.moduleID,
            input: input,
            capabilitySet: descriptor.capabilities,
            ownerOperation: operation,
            offline: input.modes.contains("/offline"),
            expectedEffectCount: operation == nil ? 0 : 1
        )
    }

    func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle {
        fatalError("proposal validation must not start a module")
    }

    func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition { .unavailable }
}
