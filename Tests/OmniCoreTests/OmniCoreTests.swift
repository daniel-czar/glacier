import Foundation
import XCTest
@testable import OmniCore

final class OmniCoreTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtures: URL {
        packageRoot.appendingPathComponent("Sources/OmniCore/Resources/ContractFixtures")
    }

    private func manifest() throws -> CommandManifest {
        try CommandManifest(data: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
    }

    private func declarations() throws -> [ModuleDeclaration] {
        try JSONDecoder().decode(
            ModuleDeclarationDocument.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("module-declarations.json"))
        ).declarations
    }

    private func parser(_ references: [PinnedReference] = []) throws -> OmniParser {
        try OmniParser(manifest: manifest(), references: ReferenceRegistry(references))
    }

    private func reference(_ namespace: String = "people", key: String = "zoe", id: String = "person_1") -> PinnedReference {
        PinnedReference(
            id: id,
            namespace: namespace,
            key: key,
            snapshot: ReferenceSnapshot(sourceVersion: "fixture-v1", resolvedAt: Date(timeIntervalSince1970: 0))
        )
    }

    func testRuntimeContextRejectsUnknownFutureEnvelopeAndParsesScopedFollowUps() throws {
        let future = Data("{\"version\":3}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RuntimeRunContext.self, from: future)) { error in
            XCTAssertEqual(error as? RuntimeRunContextError, .unsupportedVersion(3))
        }
        XCTAssertEqual(try OmniFollowUpOperation.parse(visibleText: "Keep greeting /shorter").operation, .shorter)
        XCTAssertEqual(try OmniFollowUpOperation.parse(visibleText: "Keep greeting /shorter:25%").length?.canonical, "25%")
        XCTAssertEqual(try OmniFollowUpOperation.parse(visibleText: "Keep greeting /shorter:0.25").length?.canonical, "25%")
        XCTAssertEqual(try OmniFollowUpOperation.parse(visibleText: "/style:formal Keep greeting").operation, .formal)
        XCTAssertThrowsError(try OmniFollowUpOperation.parse(visibleText: "Keep greeting /shorter:nope"))
        XCTAssertEqual(try OmniFollowUpOperation.parse(visibleText: "/formal Keep greeting").editedSourceText, "Keep greeting")
        XCTAssertThrowsError(try OmniFollowUpOperation.parse(visibleText: "draft /shorter /formal"))
        XCTAssertThrowsError(try OmniFollowUpOperation.parse(visibleText: "/shorter"))
        XCTAssertEqual(
            try OmniFollowUpOperation.parse(visibleText: "Read https://example.test/shorter docs /shorter").editedSourceText,
            "Read https://example.test/shorter docs"
        )
        XCTAssertEqual(
            try OmniFollowUpOperation.parse(visibleText: "Read /usr/bin docs /formal").editedSourceText,
            "Read /usr/bin docs"
        )
        XCTAssertThrowsError(try OmniFollowUpOperation.parse(visibleText: "Read docs /polish"))
        var invalid = RuntimeRunContext()
        invalid.version = 0
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
    }

    func testCopiedFixtureSetMatchesPhaseOneCorpusSchema() throws {
        let corpus = FrozenContractCorpus()
        XCTAssertEqual(try corpus.manifest().primaryTokens.count, 20)
        XCTAssertEqual(try corpus.moduleDeclarations().declarations.count, 21)
        let data = try Data(contentsOf: fixtures.appendingPathComponent("contract-corpus-schema.json"))
        let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let required = try XCTUnwrap(schema?["required_fixtures"] as? [String])
        XCTAssertEqual(Set(required), Set([
            "manifest.json", "grammar-cases.json", "module-declarations.json",
            "reference-rules.json", "authority-policy.json", "tier2-proposals.json",
            "lifecycle-events.json", "foreground-transitions.json", "storage-semantics.json"
        ]))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(names.count, 11)
        XCTAssertTrue(names.contains("freeze-index.json"))
    }

    func testGrammarAndVisibleRewriteCorpus() throws {
        let parser = try parser([reference()])
        let cases = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtures.appendingPathComponent("grammar-cases.json"))
        ) as? [[String: Any]] ?? []
        XCTAssertEqual(cases.count, 42)
        for entry in cases {
            let input = try XCTUnwrap(entry["input"] as? String)
            let expected = try XCTUnwrap(entry["canonical"] as? String)
            let expectedTier = try XCTUnwrap(entry["tier"] as? Int)
            let intent = parser.parse(input)
            XCTAssertEqual(intent.canonicalText, expected, input)
            switch (expectedTier, SubmissionClassifier().classify(intent)) {
            case (1, .tier1), (2, .tier2): break
            default: XCTFail("unexpected tier for \(input)")
            }
            if let values = entry["tokenValues"] as? [String: String] {
                for (token, canonical) in values {
                    XCTAssertEqual(intent.tokenValues[token]?.canonical, canonical, input)
                }
            }
        }
        let alias = parser.parse("/formal hello")
        XCTAssertEqual(alias.visibleRewrites, [VisibleRewrite(from: "/formal", to: "/style:formal")])
        // Command-set amendment 1.2.0: `/retrieve` is a primary alias of `/find`
        // and `/slug` is a model-backed primary on the quick ladder.
        let retrieve = parser.parse("/retrieve 5c3059324fcbf75b")
        XCTAssertEqual(retrieve.visibleRewrites, [VisibleRewrite(from: "/retrieve", to: "/find")])
        XCTAssertEqual(retrieve.canonicalText, "/find 5c3059324fcbf75b")
        XCTAssertEqual(retrieve.dispatchToken, "/find")
        XCTAssertTrue(retrieve.diagnostics.isEmpty)
        let slug = parser.parse("/slug The European languages are members of the same family. /offline")
        XCTAssertEqual(slug.dispatchToken, "/slug")
        XCTAssertEqual(slug.modes, ["/offline"])
        XCTAssertTrue(slug.diagnostics.isEmpty)
        let slugCommand = try XCTUnwrap(manifest().command(for: "/slug"))
        XCTAssertEqual(slugCommand.moduleID, "title.slug")
        XCTAssertEqual(slugCommand.execution, ExecutionPath.modelBacked)
        XCTAssertEqual(try declarations().first { $0.moduleID == "find.indexed" }?.tokens.aliases, ["/retrieve"])
        XCTAssertEqual(try FrozenContractCorpus().moduleDeclarations().fixtureVersion, "1.7.0")
        XCTAssertEqual(try FrozenContractCorpus().manifest().fixtureVersion, "1.7.0")
        // Command-set amendment 1.7.0: `/stash:N` names a stack position 1-5.
        let stashImport = parser.parse("/stash:3 /qq what is this")
        XCTAssertEqual(stashImport.tokenValues["/stash"], .enumMember("3"))
        XCTAssertTrue(parser.parse("/stash:9").diagnostics.contains(.invalidValue("/stash:9", "9")))
        let unexpected = parser.parse("/remind:15:00 buy milk")
        XCTAssertTrue(unexpected.diagnostics.contains(.unexpectedValue("/remind", "15:00")))
        XCTAssertTrue(unexpected.diagnostics.contains(.unknownSlash("/remind:15:00")))
        XCTAssertTrue(unexpected.primaryTokens.isEmpty)
        let plain = parser.parse("https://example.com /usr/bin/open ./notes $foo")
        XCTAssertTrue(plain.diagnostics.isEmpty)
    }

    func testReferenceResolutionPinsIDAndSnapshotAndAmbiguityStopsRun() throws {
        let pinned = reference()
        let parser = try parser([pinned])
        let unique = parser.parse("/email @zoe hello")
        XCTAssertEqual(unique.canonicalText, "/email @people:zoe hello")
        XCTAssertEqual(unique.references, [.binding(pinned)])
        XCTAssertEqual(SubmissionClassifier().classify(unique), .tier1(dispatchToken: "/email"))
        XCTAssertEqual(parser.parse("/qq @unknown").references, [.plainText("@unknown")])

        let ambiguous = try self.parser([pinned, reference("projects", key: "zoe", id: "project_1")])
        XCTAssertEqual(SubmissionClassifier().classify(ambiguous.parse("/email @zoe")), .referenceChoice)
        XCTAssertEqual(
            ambiguous.selectAmbiguousReference(key: "zoe", namespace: "people"),
            VisibleRewrite(from: "@zoe", to: "@people:zoe")
        )
    }

    func testManifestDeclarationsAndRegistryRemainInParityWithoutTokenSwitches() throws {
        let manifest = try manifest()
        let declarations = try declarations()
        XCTAssertEqual(manifest.primaryTokens.count, 20)
        XCTAssertNil(manifest.command(for: "/save"))
        XCTAssertEqual(manifest.command(for: "/shorter")?.execution, .policy)
        XCTAssertEqual(manifest.command(for: "/style")?.value?.type, .enumRegistry)
        let registry = try fixtureRegistry(for: declarations, manifest: manifest)
        XCTAssertNoThrow(try ManifestParityValidator().validate(
            manifest: manifest,
            declarations: declarations,
            registry: registry
        ))
        let router = Tier1Router(manifest: manifest, registry: registry)
        XCTAssertEqual(try router.module(for: "/todo").descriptor.moduleID, "capture.todo")
        XCTAssertThrowsError(try router.module(for: "/offline"))
        XCTAssertThrowsError(try router.module(for: "/shorter"))
    }

    func testTierClassifierAndTierTwoConfirmationValidateModuleAuthority() throws {
        let manifest = try manifest()
        let declarations = try declarations()
        let registry = try fixtureRegistry(for: declarations, manifest: manifest)
        let parser = try parser()
        XCTAssertEqual(SubmissionClassifier().classify(parser.parse("/email /qq")), .tier2)
        XCTAssertEqual(SubmissionClassifier().classify(parser.parse("/save inactive")), .tier2)
        XCTAssertEqual(SubmissionClassifier().classify(parser.parse("   ")), .disabled)

        let proposal = Tier2Proposal(moduleID: "capture.todo", capabilities: [.appendLedger], input: "buy milk")
        let validator = Tier2PlanValidator(registry: registry)
        XCTAssertNoThrow(try validator.confirm(proposal, exactPlanHash: proposal.planHash))
        XCTAssertThrowsError(try validator.confirm(proposal, exactPlanHash: "edited-plan"))
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal)) as? [String: Any])
        encoded["input"] = "edited input"
        let tampered = try JSONDecoder().decode(
            Tier2Proposal.self,
            from: JSONSerialization.data(withJSONObject: encoded)
        )
        XCTAssertThrowsError(try validator.validate(tampered))
        let overprivileged = Tier2Proposal(moduleID: "capture.todo", capabilities: [.appendLedger, .writeSettings], input: "buy milk")
        XCTAssertThrowsError(try validator.validate(overprivileged))
        XCTAssertThrowsError(try Tier2PlanValidator(registry: registry).validate(
            Tier2Proposal(moduleID: "unknown", capabilities: [], input: "x")
        ))
    }

    func testCapabilityBrokerCannotConstructUndeclaredHandle() throws {
        let broker = CapabilityBroker(declared: [.appendLedger])
        XCTAssertEqual(try broker.handle(for: .appendLedger).capability, .appendLedger)
        XCTAssertThrowsError(try broker.handle(for: .writeSettings))
        XCTAssertEqual(broker.handles().map(\.capability), [.appendLedger])
    }

    func testAddingModuleNeedsFactoryAndManifestParityNotParserOrRouterEdits() throws {
        let manifest = try manifest()
        let declarations = try declarations()
        let original = try fixtureRegistry(for: declarations, manifest: manifest)
        XCTAssertThrowsError(try ManifestParityValidator().validate(
            manifest: manifest,
            declarations: declarations,
            registry: try ModuleRegistry([])
        ))
        XCTAssertEqual(original.moduleIDs.count, declarations.count)
    }

    func testPhaseFiveModelPolicyLocksLanesWithoutRewritingPhaseFour() throws {
        XCTAssertEqual(ModelRuntimePolicy.phase4V1.version, "4.0.0")
        XCTAssertEqual(ModelRuntimePolicy.phase4V1.command(named: "draft.message")?.primary.first?.providerClass, .localCapable)

        let phaseFive = ModelRuntimePolicy.phase5V1
        XCTAssertEqual(phaseFive.version, "5.0.0")
        XCTAssertEqual(phaseFive.command(named: "answer.quick")?.primary, [.init(providerClass: .fastHosted, requiresQualityEvidence: true)])
        XCTAssertEqual(phaseFive.command(named: "translate")?.fallback, [.init(providerClass: .localFast, requiresQualityEvidence: true)])
        XCTAssertEqual(phaseFive.command(named: "draft.email")?.primary, [.init(providerClass: .capableRemote, requiresQualityEvidence: true)])
        XCTAssertEqual(phaseFive.command(named: "draft.message")?.fallback, [.init(providerClass: .localCapable, requiresQualityEvidence: true)])
        XCTAssertEqual(phaseFive.command(named: "tier2.proposal")?.offline, [.init(providerClass: .localCapable, requiresQualityEvidence: true)])
    }

    private func fixtureRegistry(for declarations: [ModuleDeclaration], manifest: CommandManifest) throws -> ModuleRegistry {
        try ModuleRegistry(declarations.map { declaration in
            let manifestCommand = manifest.command(for: declaration.tokens.canonical)!
            let descriptor = ModuleDescriptor(
                moduleID: declaration.moduleID,
                moduleVersion: declaration.moduleVersion,
                execution: declaration.executionPath.kind,
                capabilities: Set(manifestCommand.capabilities),
                policies: declaration.typedPolicies
            )
            return AnyCommandModuleFactory(moduleID: declaration.moduleID) {
                FixtureModule(descriptor: descriptor)
            }
        })
    }
}

private struct FixtureModule: CommandModule {
    let descriptor: ModuleDescriptor

    func validate(input: ModuleInput) throws {}

    func makePlan(input: ModuleInput) throws -> CommandPlan {
        CommandPlan(moduleID: descriptor.moduleID, input: input, capabilitySet: descriptor.capabilities)
    }

    func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle {
        FixtureHandle(runID: runID, outcome: .succeeded(ModuleResult(summary: "fixture")))
    }

    func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition {
        .unavailable
    }
}

private struct FixtureHandle: RunExecutionHandle {
    let runID: String
    let outcome: ModuleExecutionOutcome

    func value() async -> ModuleExecutionOutcome { outcome }

    func requestCancellation() async -> CancellationAcknowledgement {
        CancellationAcknowledgement(
            requestObserved: true,
            taskOrProcessStopped: true,
            ownerAcknowledged: true,
            effectCertainty: .certain
        )
    }
}
