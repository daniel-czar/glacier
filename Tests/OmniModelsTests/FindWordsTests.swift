import Foundation
import OmniCore
@testable import OmniModels
import Testing

// `/find` in words (D2, tier 3, decision surface 569d5a7cf925cbd7): the
// model writes a query and never sees a row; typed filters are hard
// constraints; `/offline` falls back to plain terms with no model attempt.

private let index = FindIndex(documents: [
    FindDocument(path: "/Users/fixture/Base/a.md", title: "Adversarial review of an ML run", kind: "review", documentID: "569d5a7cf925cbd7", summary: "Helios trial", projectValues: ["project_helios"], tagValues: ["ml", "adversarial-review"]),
    FindDocument(path: "/Users/fixture/Base/b.md", title: "Helios ML report", kind: "report", summary: "ML run", projectValues: ["project_helios"], tagValues: ["ml"]),
    FindDocument(path: "/Users/fixture/Base/c.md", title: "Cassandra review", kind: "review", projectValues: ["project_cassandra"]),
])

private let policy = ModelRuntimePolicy(version: "test", commands: [.init(commandID: "find.indexed", primary: [.init(providerClass: .fastHosted)])])

private func broker(reply: String) -> RecordingGenerator {
    RecordingGenerator(inner: ModelBroker(policy: policy, providers: [FixedReplyProvider(descriptor: .init(providerID: "p", providerClass: .fastHosted, isRemote: true), reply: reply)]))
}

private func findModule(_ generator: any ModelGenerating) throws -> any CommandModule {
    let corpus = FrozenContractCorpus()
    return try FindModuleCatalog(manifest: try corpus.manifest(), declarations: try corpus.moduleDeclarations().declarations, index: StaticFindIndex(index), broker: generator).factory.build()
}

private func run(_ payload: String, modes: Set<String> = [], generator: any ModelGenerating) async throws -> ModuleExecutionOutcome {
    let module = try findModule(generator)
    let plan = try module.makePlan(input: ModuleInput(canonicalText: "/find \(payload)", rawText: "/find \(payload)", payloadText: payload, modes: modes))
    let handle = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: plan.capabilitySet), runID: "run-\(UUID().uuidString)")
    return await handle.value()
}

@Test func aReplyIsAQueryAndNothingElse() throws {
    let valid = try #require(FindQueryReply.parse(#"{"filters":"kind:review in:helios","terms":"adversarial ml"}"#))
    #expect(valid.filters == [FindFilter(facet: .kind, value: "review"), FindFilter(facet: .project, value: "helios")])
    #expect(valid.terms == ["adversarial", "ml"])
    #expect(FindQueryReply.parse("```json\n{\"filters\":\"kind:note\",\"terms\":\"\"}\n```") != nil, "a code fence is tolerated")
    #expect(FindQueryReply.parse(#"{"filters":"","terms":"helios"}"#)?.terms == ["helios"])
    #expect(FindQueryReply.parse(#"{"filters":"kind:note"}"#) != nil, "terms may be absent")
    #expect(FindQueryReply.parse(#"{"terms":"helios"}"#)?.terms == ["helios"], "filters may be absent")
    #expect(FindQueryReply.parse("{}")?.query.isEmpty == true)
    // Anything more is not a query.
    #expect(FindQueryReply.parse(#"{"filters":"kind:review","terms":"x","rows":["/Users/fixture/Base/a.md"]}"#) == nil)
    #expect(FindQueryReply.parse(#"{"filters":"kind:review","terms":"x","paths":"/etc"}"#) == nil)
    #expect(FindQueryReply.parse(#"Here is the query: {"filters":"kind:review","terms":""}"#) == nil, "prose around the object")
    #expect(FindQueryReply.parse(#"{"filters":"kind:review","terms":""} I hope this helps"#) == nil)
    #expect(FindQueryReply.parse(#"{"filters":"status:open","terms":""}"#) == nil, "unknown key")
    #expect(FindQueryReply.parse(#"{"filters":"kind:","terms":""}"#) == nil, "empty value")
    #expect(FindQueryReply.parse(#"{"filters":"review","terms":""}"#) == nil, "a bare word on the filters line")
    #expect(FindQueryReply.parse(#"{"filters":"","terms":"kind:review"}"#) == nil, "a filter among the terms")
    #expect(FindQueryReply.parse(#"{"filters":"kind:review\nin:helios","terms":""}"#) == nil, "one line")
    #expect(FindQueryReply.parse(#"{"filters":"","terms":""}"#)?.query.isEmpty == true, "nothing to add is still only a query")
    #expect(FindQueryReply.parse("{\"filters\":\"kind:review\",\"terms\":\"ml\u{202E}lmth\"}") == nil, "a bidi override")
    #expect(FindQueryReply.parse("{\"filters\":\"kind:review\",\"terms\":\"m\u{200B}l\"}") == nil, "a zero-width space")
    #expect(FindQueryReply.parse(#"{"filters":["kind:review"],"terms":""}"#) == nil, "strings only")
    #expect(FindQueryReply.parse(#"{"filters":"kind:review","terms":"\#(String(repeating: "x", count: 201))"}"#) == nil)
}

@Test func bothBrokersValidateTheFindQueryShape() async throws {
    let constraint = ModelOutputConstraint(shape: .findQuery, maximumCharacters: 800)
    #expect(ModelOutputShape.findQuery.requestsJSONObject)
    #expect(ProviderRuntimeBroker.valid(#"{"filters":"kind:review","terms":"ml"}"#, for: constraint))
    #expect(!ProviderRuntimeBroker.valid(#"{"filters":"kind:review","terms":"ml","rows":[]}"#, for: constraint))
    #expect(!ProviderRuntimeBroker.valid("kind:review ml", for: constraint))
    // The class-ladder broker shares the parser: it rejects the prose reply
    // itself, so the fallback answers (were the broker to pass prose through,
    // the module's own parse would fail the run instead).
    let ladder = ModelRuntimePolicy(version: "test", commands: [.init(commandID: "find.indexed", primary: [.init(providerClass: .fastHosted)], fallback: [.init(providerClass: .localCapable)])])
    let valid = #"{"filters":"kind:review","terms":""}"#
    let generator = RecordingGenerator(inner: ModelBroker(policy: ladder, providers: [
        FixedReplyProvider(descriptor: .init(providerID: "prose", providerClass: .fastHosted, isRemote: true), reply: "Try searching for reviews."),
        FixedReplyProvider(descriptor: .init(providerID: "query", providerClass: .localCapable, isRemote: false), reply: valid),
    ]))
    guard case .succeeded(let result) = try await run("adversarial reviews", generator: generator) else {
        Issue.record("the fallback's query must run")
        return
    }
    #expect(result.find?.modelOutput == valid)
    #expect(result.modelRecord?.attempts.count == 2)
    #expect(result.modelRecord?.attempts.first?.outcome != .succeeded)
}

@Test func aCannedReplyNeverYieldsARowAndTheRouteLineCarriesTheTranslatedQuery() async throws {
    // The reply names a path that is not in the index and a title that is:
    // only index rows come back, and only those the query matches.
    let reply = #"{"filters":"in:helios tags:ml","terms":"adversarial"}"#
    let generator = broker(reply: reply)
    guard case .succeeded(let result) = try await run("kind:review adversarial reviews of an ML run from Helios", generator: generator) else {
        Issue.record("expected rows")
        return
    }
    let find = try #require(result.find)
    #expect(find.tier == .words && find.ranModel)
    #expect(find.modelOutput == reply, "the model's output, exactly: a query")
    // The typed kind:review is a hard constraint; the model's filters join it.
    #expect(find.query == "kind:review in:helios tags:ml adversarial")
    let indexPaths = Set(index.documents.map(\.path))
    #expect(find.rows.allSatisfy { indexPaths.contains($0.path) }, "every row is a local index row")
    #expect(find.rows.map(\.path) == ["/Users/fixture/Base/a.md"])
    #expect(result.modelRecord != nil)
    #expect(result.summary == "1 found · kind:review in:helios tags:ml adversarial")
    // The pad's route line shows the translated query (D2).
    #expect(find.summary.hasSuffix("kind:review in:helios tags:ml adversarial"))
    // The prompt carried the vocabulary and the words, never a row.
    let request = try #require(await generator.requests().first)
    #expect(request.outputConstraint.shape == .findQuery)
    #expect(request.prompt.contains("Kinds: review, report"))
    #expect(request.prompt.contains("Projects (for in:): helios, cassandra"))
    #expect(request.prompt.contains("Already chosen by the user and kept as they are: kind:review. Do not add another filter on kind."))
    #expect(request.prompt.hasSuffix("Request: adversarial reviews of an ML run from Helios"))
    for document in index.documents {
        #expect(!request.prompt.contains(document.path) && !request.prompt.contains(document.title), "no row reaches the model")
    }
}

@Test func aModelFilterOnATypedKeyIsDroppedNotANDed() async throws {
    let generator = broker(reply: #"{"filters":"kind:report in:helios","terms":""}"#)
    guard case .succeeded(let result) = try await run("kind:review from helios", generator: generator) else {
        Issue.record("expected rows")
        return
    }
    #expect(result.find?.query == "kind:review in:helios")
    #expect(result.find?.rows.map(\.path) == ["/Users/fixture/Base/a.md"])
}

@Test func aModelFilterOnAValueTheIndexDoesNotHoldIsDroppedAndAnEmptiedQueryFallsBackToTheWords() async throws {
    // kind:adversarial-review is a tag here, not a kind: it moves to the
    // facet that holds it.
    let generator = broker(reply: #"{"filters":"kind:adversarial-review in:helios","terms":""}"#)
    guard case .succeeded(let result) = try await run("adversarial reviews from helios", generator: generator) else {
        Issue.record("expected rows")
        return
    }
    #expect(result.find?.query == "tags:adversarial-review in:helios")
    #expect(result.find?.rows.map(\.path) == ["/Users/fixture/Base/a.md"])
    // A value no facet holds is dropped, not ANDed into an empty result.
    let unknown = broker(reply: #"{"filters":"kind:nonexistent in:helios","terms":""}"#)
    guard case .succeeded(let dropped) = try await run("adversarial reviews from helios", generator: unknown) else {
        Issue.record("expected rows")
        return
    }
    #expect(dropped.find?.query == "in:helios")
    #expect(dropped.find?.rows.count == 2)
    // Only unknown values came back: the words run as plain terms, never an
    // empty query that would list the whole index.
    let empty = broker(reply: #"{"filters":"kind:nonexistent","terms":""}"#)
    guard case .succeeded(let fallback) = try await run("helios ml", generator: empty) else {
        Issue.record("expected rows")
        return
    }
    #expect(fallback.find?.query == "helios ml")
    #expect(fallback.find?.rows.map(\.path) == ["/Users/fixture/Base/a.md", "/Users/fixture/Base/b.md"])
    #expect(fallback.find?.tier == .words, "the model still ran")
}

@Test func withNoExactRowTheClosestComeBackUnderTheTypedFiltersAndTheQueryStaysAsWritten() async throws {
    // Nothing satisfies kind:review in:helios report. The typed kind:review
    // stays hard, so b.md (a helios report) is out however well it scores;
    // a.md satisfies the most of the rest.
    let reply = #"{"filters":"in:helios","terms":"reports"}"#
    guard case .succeeded(let result) = try await run("kind:review helios reports", generator: broker(reply: reply)) else {
        Issue.record("expected rows")
        return
    }
    let find = try #require(result.find)
    #expect(find.query == "kind:review in:helios reports", "the route line shows the query that ran, not a relaxed one")
    #expect(find.rows.map(\.path) == ["/Users/fixture/Base/a.md"])
    #expect(find.exact == 0 && find.isClosest)
    #expect(result.summary == "No exact match · 1 closest · kind:review in:helios reports")
    #expect(find.modelOutput == reply)
    // When rows satisfy all of it, the answer is exactly the strict one; a
    // plural term finds its singular.
    guard case .succeeded(let exact) = try await run("helios reports", generator: broker(reply: reply)) else {
        Issue.record("expected rows")
        return
    }
    #expect(exact.find?.rows.map(\.path) == ["/Users/fixture/Base/b.md"])
    #expect(exact.find?.exact == 1 && exact.find?.isClosest == false)
    #expect(exact.summary == "1 found · in:helios reports")
}

@Test func anEmptyReplyRunsTheTypedFiltersOrThePersonsWordsNeverTheWholeIndex() async throws {
    let empty = #"{"filters":"","terms":""}"#
    guard case .succeeded(let typed) = try await run("kind:review reviews", generator: broker(reply: empty)) else {
        Issue.record("the prompt asks for this reply: it must run")
        return
    }
    #expect(typed.find?.query == "kind:review")
    #expect(typed.find?.rows.map(\.path) == ["/Users/fixture/Base/a.md", "/Users/fixture/Base/c.md"])
    guard case .succeeded(let words) = try await run("helios ml", generator: broker(reply: empty)) else {
        Issue.record("expected rows")
        return
    }
    #expect(words.find?.query == "helios ml", "the words as plain terms")
    #expect(words.find?.rows.count == 2)
}

@Test func typedWordsSurviveAReplyThatAddsNothingUsable() async throws {
    // Every model filter is dropped (a value no facet lists) and no terms:
    // the person's words run beside the typed filter, not the filter alone.
    guard case .succeeded(let result) = try await run("kind:review helios ml", generator: broker(reply: #"{"filters":"in:heliosx","terms":""}"#)) else {
        Issue.record("expected rows")
        return
    }
    #expect(result.find?.query == "kind:review helios ml")
    #expect(result.find?.rows.map(\.path) == ["/Users/fixture/Base/a.md"])
}

@Test func anIDBesideWordsOrAKeyWithNoValueIsRefusedBeforeAnyModel() async throws {
    let generator = broker(reply: #"{"filters":"kind:review","terms":""}"#)
    for payload in ["569d5a7cf925cbd7 reviews", "reviews doc:569d5a7cf925cbd7", "kind:review run:0123456789abcdef"] {
        let query = FindQuery(payload: payload)
        #expect(query.refusal == "An id is found on its own · remove the other words")
        #expect(!query.asksModel)
        #expect(!query.terms.contains { OmniIDAddress($0) != nil }, "an id is never a term")
        #expect(throws: FindModuleError.unsupportedSyntax("An id is found on its own · remove the other words")) {
            try findModule(generator).makePlan(input: ModuleInput(canonicalText: "/find \(payload)", rawText: "/find \(payload)", payloadText: payload))
        }
    }
    for payload in ["kind:", "reviews in:"] {
        #expect(FindQuery(payload: payload).refusal?.hasPrefix("Pick a value for ") == true)
        #expect(!FindQuery(payload: payload).asksModel)
    }
    #expect(FindQuery(payload: "kind: review").refusal == "Pick a value for kind:")
    // The lone id is still tier 1, and words alone still ask.
    #expect(FindQuery(payload: "569d5a7cf925cbd7").refusal == nil)
    #expect(FindQuery(payload: "adversarial reviews").asksModel)
    #expect(await generator.requests().isEmpty)
}

@Test func privateRowsAreFoundButTheirValuesNeverReachThePrompt() async throws {
    let mixed = FindIndex(documents: index.documents + [
        FindDocument(path: "/Users/fixture/Base/p.md", title: "Private ledger", kind: "ledger", projectValues: ["project_secretive"], tagValues: ["hush"], isPrivate: true),
    ])
    #expect(mixed.facets.knows(FindFilter(facet: .kind, value: "ledger")))
    #expect(!mixed.promptFacets.knows(FindFilter(facet: .kind, value: "ledger")))
    #expect(mixed.query(filters: [FindFilter(facet: .kind, value: "ledger")], terms: []).rows.count == 1, "retrieve docs keeps private rows")
    let generator = broker(reply: #"{"filters":"","terms":"ledger"}"#)
    let module = try FindModuleCatalog(manifest: try FrozenContractCorpus().manifest(), declarations: try FrozenContractCorpus().moduleDeclarations().declarations, index: StaticFindIndex(mixed), broker: generator).factory.build()
    let plan = try module.makePlan(input: ModuleInput(canonicalText: "/find ledgers", rawText: "/find ledgers", payloadText: "ledgers"))
    _ = await (try module.start(plan: plan, capabilities: CapabilityBroker(declared: plan.capabilitySet), runID: "run-private")).value()
    let prompt = try #require(await generator.requests().first?.prompt)
    for value in ["ledger", "secretive", "hush"] { #expect(!prompt.contains(value + ",") && !prompt.contains(value + "\n")) }
}

@Test func aReplyCarryingRowsFailsAndNoRowComesBack() async throws {
    let generator = broker(reply: #"{"filters":"kind:review","terms":"","rows":["/Users/fixture/Base/c.md"]}"#)
    let outcome = try await run("reviews please", generator: generator)
    guard case .failed = outcome else {
        Issue.record("a reply with rows is not a query")
        return
    }
}

@Test func offlineWordsAreTermsWithNoModelAttemptAndIDsAndFiltersNeverAsk() async throws {
    let generator = broker(reply: #"{"filters":"kind:review","terms":""}"#)
    guard case .succeeded(let offline) = try await run("helios ml", modes: ["/offline"], generator: generator) else {
        Issue.record("expected rows")
        return
    }
    #expect(offline.find?.tier == .localTerms)
    #expect(offline.find?.rows.map(\.path) == ["/Users/fixture/Base/a.md", "/Users/fixture/Base/b.md"])
    #expect(offline.modelRecord == nil)
    // Offline words rank too: no row has both, the closest have one.
    guard case .succeeded(let closest) = try await run("cassandra adversarial", modes: ["/offline"], generator: generator) else {
        Issue.record("expected rows")
        return
    }
    #expect(closest.find?.rows.map(\.path) == ["/Users/fixture/Base/a.md", "/Users/fixture/Base/c.md"])
    #expect(closest.find?.isClosest == true)
    // Filters alone stay strict (retrieve parity): no closest rows.
    guard case .succeeded(let strict) = try await run("kind:report in:cassandra", generator: generator) else {
        Issue.record("expected an empty result")
        return
    }
    #expect(strict.find?.rows.isEmpty == true && strict.find?.exact == nil)
    #expect(strict.summary == "No match · kind:report in:cassandra")
    _ = try await run("kind:review in:helios", generator: generator)
    _ = try await run("569d5a7cf925cbd7", generator: generator)
    #expect(await generator.requests().isEmpty, "no request for offline words, filters or an id")
}

@Test func theFindRowNeedsQualificationAndAManualPickRuns() async throws {
    let declaration = try #require(try FrozenContractCorpus().moduleDeclarations().declarations.first { $0.moduleID == "find.indexed" })
    #expect(declaration.modelPolicy.profile == "quick", "amendment 1.5.0")
    let command = try #require(ModelProviderPolicy.v6.command(named: "find.indexed"))
    #expect(command.primaryProfileIDs == [ProviderRuntimeCatalog.cerebrasFastProfileID])
    #expect(command.outputShape == .findQuery)
    #expect(command.requiredCapabilities == [.structuredJSONObject])
    #expect(ModelProviderPolicy.v6.version == "6.0.0")
    #expect(ProviderRuntimeCatalog.profile(ProviderRuntimeCatalog.cerebrasFastProfileID)?.eligibleCommandIDs.contains("find.indexed") == true)
    #expect(ProviderRuntimeSettings.freshDefaults().command("find.indexed") != nil)
    let reply = #"{"filters":"kind:review","terms":""}"#
    let request = { (selection: ModelInvocationSelection?) in
        ModelGenerationRequest(runID: "run-f", commandID: "find.indexed", prompt: "p", offline: false, outputConstraint: .init(shape: .findQuery, maximumCharacters: 800), dispatch: ModelDispatchContext(generationID: "g", selection: selection))
    }
    // Unqualified: the automatic ladder has no candidate; a manual pick runs (C66, C67).
    let unqualified = try RoutingHarness(scripts: [.cerebrasHTTP: [.success(text: reply)]])
    let resolution = try await unqualified.broker().resolve(commandID: "find.indexed", offline: false, dispatch: nil)
    #expect(resolution.candidates.allSatisfy { if case .excluded = $0.verdict { true } else { false } })
    let manual = try await unqualified.broker().execute(request(ModelInvocationSelection(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID)))
    #expect(manual.record.attempts.last?.identity?.profileID == ProviderRuntimeCatalog.cerebrasFastProfileID)
    // Qualified on the fast profile, it enters the ladder.
    let qualified = try RoutingHarness(qualifications: standardQualifications() + [qualification(ProviderRuntimeCatalog.cerebrasFastProfileID, "find.indexed")], scripts: [.cerebrasHTTP: [.success(text: reply)]])
    let automatic = try await qualified.broker().execute(request(nil))
    #expect(automatic.record.attempts.last?.identity?.profileID == ProviderRuntimeCatalog.cerebrasFastProfileID)
}
