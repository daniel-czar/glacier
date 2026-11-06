import OmniCore
@testable import OmniModels
import Testing

private let highDraftProfileID = ProviderRuntimeCatalog.cerebrasDraftProfileID
private let draftCommandIDs = ["draft.email", "draft.message"]

@Test func directDraftPolicyUsesDedicatedHighReasoningProfileWithoutOnlineDowngrade() throws {
    let high = try #require(ProviderRuntimeCatalog.profile(highDraftProfileID))
    #expect(high.options == .init(reasoning: .high, maximumOutputTokens: 16_384, temperature: 0.1))
    for commandID in draftCommandIDs {
        let policy = try #require(ModelProviderPolicy.v6.command(named: commandID))
        #expect(policy.primaryProfileIDs == [highDraftProfileID])
        #expect(policy.fallbackProfileIDs.isEmpty)
        #expect(policy.offlineProfileIDs == [ProviderRuntimeCatalog.localFastProfileID])
        #expect(high.eligibleCommandIDs.contains(commandID))
    }
}

@Test func directDraftDefaultRequiresExactQualificationAndDoesNotDowngradeOnline() throws {
    for commandID in draftCommandIDs {
        let qualified = try RoutingHarness(qualifications: [qualification(highDraftProfileID, commandID)]).broker()
        let chosen = try qualified.resolve(commandID: commandID, offline: false, dispatch: nil)
        #expect(chosen.selectionSource == .policyDefault)
        #expect(chosen.effectiveProfileID == highDraftProfileID)
        #expect(chosen.candidates.map(\.profileID) == [highDraftProfileID])

        let unqualified = try RoutingHarness(qualifications: []).broker()
        let unavailable = try unqualified.resolve(commandID: commandID, offline: false, dispatch: nil)
        #expect(unavailable.effectiveProfileID == nil)
        #expect(unavailable.candidates.map(\.profileID) == [highDraftProfileID])
        guard case .excluded(.unqualified, _) = unavailable.candidates[0].verdict else {
            Issue.record("A high-reasoning default without quality evidence must be unavailable")
            return
        }
    }
}

@Test func directDraftDefaultPreservesSavedExplicitAndOfflineRoutes() throws {
    for commandID in draftCommandIDs {
        let saved = settingsDocument(revision: 2, commands: [
            .init(commandID: commandID, savedProfileID: ProviderRuntimeCatalog.cerebrasFastProfileID)
        ])
        let broker = try RoutingHarness(qualifications: [
            qualification(highDraftProfileID, commandID),
            qualification(ProviderRuntimeCatalog.localFastProfileID, commandID)
        ]).broker(settings: saved)
        let savedRoute = try broker.resolve(commandID: commandID, offline: false, dispatch: nil)
        #expect(savedRoute.selectionSource == .savedCommandOptIn(settingsRevision: 2))
        #expect(savedRoute.effectiveProfileID == ProviderRuntimeCatalog.cerebrasFastProfileID)

        let explicit = try broker.resolve(commandID: commandID, offline: false, dispatch: .init(
            generationID: "draft-choice",
            selection: .init(profileID: ProviderRuntimeCatalog.cerebrasCarefulProfileID)
        ))
        #expect(explicit.selectionSource == .invocationOverride(generationID: "draft-choice"))
        #expect(explicit.effectiveProfileID == ProviderRuntimeCatalog.cerebrasCarefulProfileID)

        let offline = try broker.resolve(commandID: commandID, offline: true, dispatch: nil)
        #expect(offline.effectiveProfileID == ProviderRuntimeCatalog.localFastProfileID)
        #expect(offline.candidates.allSatisfy { $0.connectionID != ProviderRuntimeCatalog.cerebrasConnectionID || !$0.isEligible })
    }
}
