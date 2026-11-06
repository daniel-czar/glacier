import Foundation
import GlacierConfiguration
import GlacierConnections
import GlacierRuntime
import OmniAdapters
import OmniCore
import OmniModels
import OmniRun
import Testing

private final class ForbiddenSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func insert(_ secret: String, account: UUID) throws { throw ConnectionError.credentialUnavailable }
    func read(account: UUID) throws -> String {
        lock.withLock { reads += 1 }
        throw ConnectionError.credentialUnavailable
    }
    func remove(account: UUID) throws { throw ConnectionError.credentialUnavailable }
    var readCount: Int { lock.withLock { reads } }
}

private actor PolicyNetwork: ConnectionNetworkTransport {
    private var posts: [URLRequest] = []
    private var probes: [URLRequest] = []
    private let holdPost: Int?
    private var secondStarted: CheckedContinuation<Void, Never>?
    private var secondResult: CheckedContinuation<ModelHTTPExchange, Never>?
    private var secondReturned = false
    private var returnedWaiter: CheckedContinuation<Void, Never>?

    init(holdPost: Int? = nil) { self.holdPost = holdPost }

    func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        guard let url = request.url, url.host == "127.0.0.1" || url.host == "localhost" else {
            throw ConnectionError.unsafeDestination
        }
        if request.httpMethod == "GET", url.path.hasSuffix("/api/tags") {
            probes.append(request)
            return ModelHTTPExchange(statusCode: 200,
                body: Data(#"{"models":[{"model":"qwen3:8b"}]}"#.utf8))
        }
        guard request.httpMethod == "POST", url.path.hasSuffix("/api/generate") else {
            throw ConnectionError.unsafeDestination
        }
        posts.append(request)
        if let holdPost, posts.count == holdPost {
            secondStarted?.resume()
            secondStarted = nil
            let response = await withCheckedContinuation { continuation in secondResult = continuation }
            secondReturned = true
            returnedWaiter?.resume()
            returnedWaiter = nil
            return response
        }
        return Self.reply("First local draft")
    }

    func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream {
        throw ConnectionError.unsafeDestination
    }

    func waitForSecondPost() async {
        if posts.count >= (holdPost ?? 2) { return }
        await withCheckedContinuation { secondStarted = $0 }
    }

    func releaseSecond(text: String = "Late rewrite that must not appear") {
        secondResult?.resume(returning: Self.reply(text))
        secondResult = nil
    }

    func waitForSecondReturn() async {
        if secondReturned { return }
        await withCheckedContinuation { returnedWaiter = $0 }
    }

    var postCount: Int { posts.count }
    var probeCount: Int { probes.count }
    var postHosts: [String?] { posts.map { $0.url?.host } }

    private static func reply(_ text: String) -> ModelHTTPExchange {
        let object: [String: Any] = ["model": "qwen3:8b", "response": text,
                                     "done": true, "prompt_eval_count": 8, "eval_count": 6]
        let bytes = try! JSONSerialization.data(withJSONObject: object)
        return ModelHTTPExchange(statusCode: 200, body: bytes)
    }
}

@MainActor
private func policyComposition(network: PolicyNetwork, secrets: ForbiddenSecrets,
                               root: URL) async throws -> GlacierComposition {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = try GlacierPaths(home: root, supportOverride: root.appendingPathComponent("Glacier"))
    let composition = try await GlacierComposition.make(
        paths: paths, home: root, hostActions: GlacierHostActions(), applicationRoots: [],
        network: network, secrets: secrets, platform: RecordingPlatformAdapter(),
        fileEffect: { _, _ in throw ConnectionError.unsafeDestination })
    let route = ModelCommandRouteSettings(commandID: "draft.message",
                                         savedProfileID: ProviderRuntimeCatalog.localFastProfileID)
    let candidate = await composition.connections.runtimeSettings(commands: [route])
    try await composition.broker.applySettings(candidate)
    composition.snapshot.setProfiles([route])
    await composition.refreshReadiness()
    return composition
}

@Test @MainActor func productionCompositionRunsSpanOffsetsWithoutAProvider() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-span-\(UUID())").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let network = PolicyNetwork()
    let secrets = ForbiddenSecrets()
    let composition = try await policyComposition(network: network, secrets: secrets, root: root)
    for (command, block, summary) in [
        ("/span 5 months after 19 october 2026", "Result: 19 Mar 2027\n5 months after 19 Oct 2026", "19 Mar 2027 · 5 months after 19 Oct 2026"),
        ("/span 5 months before 19 october 2026 /offline", "Result: 19 May 2026\n5 months before 19 Oct 2026", "19 May 2026 · 5 months before 19 Oct 2026"),
    ] {
        let submission = try await composition.service.submit(command)
        let id = try #require(submission.runID)
        let terminal = try await composition.service.waitForTerminal(runID: id)
        #expect(terminal.state == .succeeded)
        let receipt = try #require(await composition.store.receipt(for: id))
        #expect(receipt.moduleID == "compute.span")
        #expect(receipt.runtimeContext?.fullText == block)
        #expect(receipt.summary == summary)
        #expect(receipt.runtimeContext?.modelRecords.isEmpty == true)
        #expect(receipt.runtimeContext?.resultVersions.isEmpty == true)
    }
    #expect(await network.postCount == 0)
    #expect(await network.probeCount == 0)
    #expect(secrets.readCount == 0)
    _ = await composition.service.shutdown()
}

@Test @MainActor func compositionDispatchesDraftAndFidelityReviewToSelectedLocalModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-policy-\(UUID())").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let network = PolicyNetwork()
    let secrets = ForbiddenSecrets()
    let composition = try await policyComposition(network: network, secrets: secrets, root: root)
    #expect(composition.snapshot.permits("command.msg"))
    let submission = try await composition.service.submit("/msg Hello team")
    let id = try #require(submission.runID)
    let receipt = try await composition.service.waitForTerminal(runID: id)
    #expect(receipt.state == .succeeded)
    let postCount = await network.postCount
    let postHosts = await network.postHosts
    #expect(postCount == 2)
    #expect(postHosts == ["127.0.0.1", "127.0.0.1"])
    #expect(receipt.modelRecord?.attempts.count == 2)
    #expect(secrets.readCount == 0)
    let versions = try await composition.service.resultVersions(runID: id)
    #expect(versions.count == 1)
    #expect(versions.first?.resultText == "First local draft")
}

@Test @MainActor func disablingWritingCancelsFollowUpOnSucceededParentDespiteLateNetworkReply() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-policy-\(UUID())").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let network = PolicyNetwork(holdPost: 3)
    let composition = try await policyComposition(network: network, secrets: ForbiddenSecrets(), root: root)
    let submission = try await composition.service.submit("/msg Hello team")
    let id = try #require(submission.runID)
    let first = try await composition.service.waitForTerminal(runID: id)
    #expect(first.state == .succeeded)
    let initialVersions = try await composition.service.resultVersions(runID: id)
    #expect(initialVersions.count == 1)

    try await composition.service.submitFollowUp(runID: id, sourceVersion: 1,
                                                 visibleText: "Make this shorter /shorter")
    await network.waitForSecondPost()
    let pending = await composition.service.followUpState(runID: id)
    #expect(pending?.kind == .pending)
    var disabled = composition.snapshot.read()
    disabled.modules["writing"] = .init(enabled: false)
    await composition.applyRuntimePolicy(disabled)
    let cancelled = await composition.service.followUpState(runID: id)
    let parentAfterDisable = await composition.store.receipt(for: id)
    #expect(cancelled?.kind == .cancelled)
    #expect(parentAfterDisable?.status == .succeeded)

    await network.releaseSecond()
    await network.waitForSecondReturn()
    for _ in 0..<50 { await Task.yield() }
    let lateVersions = try await composition.service.resultVersions(runID: id)
    let lateState = await composition.service.followUpState(runID: id)
    let parentAfterLateReply = await composition.store.receipt(for: id)
    let totalPosts = await network.postCount
    #expect(lateVersions.count == 1)
    #expect(lateState?.kind == .cancelled)
    #expect(parentAfterLateReply?.status == .succeeded)
    #expect(totalPosts == 3)
}

@Test func modelAuthorityLeaseRejectsLateResultAfterDisableAndReenable() {
    let state = RuntimeSnapshot(GlacierSettings())
    let before = state.modelLease("draft.message")
    var disabled = state.read()
    disabled.modules["writing"] = .init(enabled: false)
    state.replace(disabled)
    var enabled = disabled
    enabled.modules["writing"] = .init(enabled: true)
    state.replace(enabled)
    #expect(state.permitsModel("draft.message"))
    #expect(state.modelLease("draft.message") != before)
}

@Test @MainActor func disablingLauncherCancelsSuspendedProposalWithNoModuleID() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-proposal-\(UUID())").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let network = PolicyNetwork(holdPost: 3)
    let composition = try await policyComposition(network: network, secrets: ForbiddenSecrets(), root: root)
    let firstSubmission = try await composition.service.submit("/msg Seed local request")
    let firstID = try #require(firstSubmission.runID)
    let first = try await composition.service.waitForTerminal(runID: firstID)
    try #require(first.state == .succeeded)
    let routes = [ModelCommandRouteSettings(commandID: "tier2.proposal", savedProfileID: ProviderRuntimeCatalog.localFastProfileID)]
    try await composition.broker.applySettings(await composition.connections.runtimeSettings(commands: routes))
    composition.snapshot.setProfiles(routes)
    await composition.refreshReadiness()
    let proposed = try await composition.service.submit("Help me phrase a short reply")
    let id = try #require(proposed.runID)
    await network.waitForSecondPost()
    let proposing = await composition.store.receipt(for: id)
    #expect(proposing?.moduleID == nil)
    #expect(proposing?.status == .proposing)
    var settings = composition.snapshot.read()
    settings.modules["launcher"] = .init(enabled: false)
    await composition.applyRuntimePolicy(settings)
    let cancelled = await composition.store.receipt(for: id)
    #expect(cancelled?.status == .cancelled)
    await network.releaseSecond(text: #"{"alternatives":[{"id":"reply","title":"Reply","commands":["/msg Hi"]}]}"#)
    await network.waitForSecondReturn()
    for _ in 0..<50 { await Task.yield() }
    let late = await composition.store.receipt(for: id)
    #expect(late?.status == .cancelled)
    #expect(late?.runtimeContext?.proposal == nil)
}
