import AppKit
import Foundation
import OmniCore
import OmniRun

public enum ResultActionServiceError: Error, Sendable, Equatable {
    case missingRun(String)
    case actionNotAllowed(ResultAction)
    case resultNotSucceeded
    case missingStoredText
    case missingArtifact
    case unsafeArtifact(String)
    case unsafeURL(String)
    case composerNotAvailable(String?)
}

/// Resolves a result action from the persisted run alone. Callers provide only a
/// run ID and a typed action, so views cannot substitute text, files, or a
/// recipient into a platform request.
public struct ResultActionService: Sendable {
    private let store: OmniRunStore
    private let platform: any PlatformActionPerforming
    private let developmentRoot: OmniDevelopmentRoot
    private let installedOwnerDependencies: InstalledOwnerDependencies

    public init(
        store: OmniRunStore,
        platform: any PlatformActionPerforming,
        developmentRoot: OmniDevelopmentRoot,
        installedOwnerDependencies: InstalledOwnerDependencies = .sourceTreeInstalled
    ) {
        self.store = store
        self.platform = platform
        self.developmentRoot = developmentRoot
        self.installedOwnerDependencies = installedOwnerDependencies
    }

    public func perform(runID: RunID, action: ResultAction) async throws -> PlatformAcknowledgement {
        guard let receipt = await store.receipt(for: runID) else {
            throw ResultActionServiceError.missingRun(runID.rawValue)
        }
        guard receipt.status == .succeeded else { throw ResultActionServiceError.resultNotSucceeded }
        guard receipt.resultActions.contains(action.rawValue) else {
            throw ResultActionServiceError.actionNotAllowed(action)
        }
        let platformAction: PlatformAction
        if receipt.executionProfile == OmniExecutionProfile.installedLive.rawValue,
           receipt.moduleID == "capture.favorite", [.open, .reveal].contains(action) {
            let artifact = try await installedFavoriteArtifactURL(for: receipt)
            platformAction = action == .open ? .openFile(artifact) : .revealFile(artifact)
        } else {
            platformAction = try resolve(action: action, receipt: receipt)
        }
        let acknowledgement = try await platform.perform(platformAction)
        try await store.recordResultAction(
            runID,
            action: action.rawValue,
            acknowledgement: acknowledgement.detail
        )
        return acknowledgement
    }

    private func resolve(action: ResultAction, receipt: OmniRun.RunReceipt) throws -> PlatformAction {
        switch action {
        case .copy:
            return .copyText(try copyText(for: receipt))
        case .open:
            if receipt.moduleID == "open.search" {
                if receipt.executionProfile == OmniExecutionProfile.pureFake.rawValue {
                    return .openURL(try fakeSearchURL(for: receipt))
                }
                return .openURL(try acknowledgedSearchURL(for: receipt))
            }
            return .openFile(try artifactURL(for: receipt))
        case .reveal:
            return .revealFile(try artifactURL(for: receipt))
        case .openComposer:
            return .openComposer(try composerDraft(for: receipt))
        case .confirm, .retry, .cancel, .edit, .dismiss, .expand, .collapse:
            throw ResultActionServiceError.actionNotAllowed(action)
        }
    }

    private func copyText(for receipt: OmniRun.RunReceipt) throws -> String {
        if receipt.moduleID == "cache.stash" {
            return try currentStashText(for: receipt)
        }
        if let fullText = receipt.runtimeContext?.fullText, !fullText.isEmpty { return fullText }
        guard let summary = receipt.summary, !summary.isEmpty else {
            throw ResultActionServiceError.missingStoredText
        }
        return summary
    }

    private func acknowledgedSearchURL(for receipt: OmniRun.RunReceipt) throws -> URL {
        guard let reference = receipt.artifactReference,
              let components = URLComponents(string: reference),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "www.google.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.path == "/search",
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "q",
              let query = queryItems[0].value,
              !query.isEmpty,
              let url = components.url,
              hasAcknowledgedSearchURL(url, receipt: receipt)
        else { throw ResultActionServiceError.unsafeURL(receipt.artifactReference ?? "") }
        return url
    }

    private func fakeSearchURL(for receipt: OmniRun.RunReceipt) throws -> URL {
        guard receipt.moduleID == "open.search",
              let input = receipt.runtimeContext?.input
        else { throw ResultActionServiceError.unsafeURL(receipt.artifactReference ?? "") }
        var components = URLComponents(string: "https://www.google.com/search")
        let query = fixturePayload(from: input.canonicalText)
        components?.queryItems = [URLQueryItem(name: "q", value: query.isEmpty ? "fixture-search" : query)]
        guard let url = components?.url,
              receipt.artifactReference == url.absoluteString,
              hasFakeFixtureEvidence(moduleID: "open.search", receipt: receipt)
        else { throw ResultActionServiceError.unsafeURL(receipt.artifactReference ?? "") }
        return url
    }

    private func fixturePayload(from canonicalText: String) -> String {
        canonicalText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.hasPrefix("/") && !$0.hasPrefix("[fixture:") }
            .joined(separator: " ")
    }

    private func currentStashText(for receipt: OmniRun.RunReceipt) throws -> String {
        let artifact = try artifactURL(for: receipt)
        let isPureFake = receipt.executionProfile == OmniExecutionProfile.pureFake.rawValue
        let expected: URL
        if receipt.executionProfile == OmniExecutionProfile.installedLive.rawValue {
            expected = try InstalledOwnerPaths(installedRoot: developmentRoot.url).stash
        } else {
            expected = try developmentRoot.containedURL(relativePath: isPureFake
                ? "fake-owners/stash/current.json"
                : "replica-owners/stash/current.json")
        }
        let isAcknowledged = if isPureFake {
            hasFakeFixtureEvidence(moduleID: "cache.stash", receipt: receipt)
        } else {
            receipt.effects?.contains(where: {
                $0.status == "succeeded"
                    && $0.operationID == OwnerOperation.replaceCurrentStash.rawValue
                    && $0.ownerID == receipt.id.rawValue
                    && $0.ownerAcknowledgement?.isEmpty == false
                    && $0.ownerPath.map { URL(fileURLWithPath: $0).standardizedFileURL == artifact } == true
            }) == true
        }
        guard artifact == expected, isAcknowledged
        else { throw ResultActionServiceError.unsafeArtifact(receipt.artifactReference ?? "") }

        // The run's entry, found by its marker: once a later push or a drop
        // has taken it off the stack, Copy fails closed (as "replaced" did).
        let entry: OmniStashEntry?
        do {
            entry = try OmniStashStack(url: artifact).entry(runID: receipt.id.rawValue)
        } catch {
            throw ResultActionServiceError.unsafeArtifact(artifact.path)
        }
        guard let entry, !entry.text.isEmpty else { throw ResultActionServiceError.unsafeArtifact(artifact.path) }
        return entry.text
    }

    private func hasAcknowledgedSearchURL(_ url: URL, receipt: OmniRun.RunReceipt) -> Bool {
        let expectedAcknowledgements = [url.absoluteString, "openURL(\(url.absoluteString))"]
        return receipt.effects?.contains {
            $0.status == "succeeded"
                && $0.operationID == OwnerOperation.openSearchURL.rawValue
                && $0.ownerAcknowledgement.map(expectedAcknowledgements.contains) == true
        } ?? false
    }

    private func hasFakeFixtureEvidence(moduleID: String, receipt: OmniRun.RunReceipt) -> Bool {
        receipt.executionProfile == OmniExecutionProfile.pureFake.rawValue
            && receipt.effects?.contains {
                $0.status == "succeeded"
                    && $0.adapterID == "fixture.\(moduleID)"
                    && $0.operationID == "execute"
            } == true
    }

    private func composerDraft(for receipt: OmniRun.RunReceipt) throws -> ComposerDraft {
        guard let moduleID = receipt.moduleID,
              let body = receipt.runtimeContext?.fullText,
              !body.isEmpty
        else { throw ResultActionServiceError.missingStoredText }
        let channel: ComposerChannel
        switch moduleID {
        case "draft.email": channel = .email
        case "draft.message": channel = .message
        default: throw ResultActionServiceError.composerNotAvailable(moduleID)
        }
        return ComposerDraft(channel: channel, subject: nil, body: body)
    }

    private func artifactURL(for receipt: OmniRun.RunReceipt) throws -> URL {
        guard let reference = receipt.artifactReference, !reference.isEmpty else {
            throw ResultActionServiceError.missingArtifact
        }
        if receipt.executionProfile == OmniExecutionProfile.installedLive.rawValue,
           ["capture.favorite", "capture.base", "cache.stash"].contains(receipt.moduleID ?? "") {
            return try installedOwnerArtifactURL(for: receipt, reference: reference)
        }
        let root = developmentRoot.url.standardizedFileURL
        let candidate: URL
        if reference.hasPrefix("/") {
            candidate = URL(fileURLWithPath: reference).standardizedFileURL
        } else {
            candidate = try developmentRoot.containedURL(relativePath: reference)
        }
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw ResultActionServiceError.unsafeArtifact(reference)
        }
        let relative = String(candidate.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { throw ResultActionServiceError.unsafeArtifact(reference) }
        let contained = try developmentRoot.containedURL(relativePath: relative)
        let attachedArtifact = receipt.artifacts.contains(relative)
        let acknowledgedOwnerPath = receipt.effects?.contains { effect in
            effect.status == "succeeded" && effect.ownerPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path == candidate.path
            } == true
        } ?? false
        let pureFakeTypedArtifact = try expectedFakeArtifactURL(for: receipt).map {
            $0.standardizedFileURL == contained && hasFakeFixtureEvidence(moduleID: receipt.moduleID ?? "", receipt: receipt)
        } ?? false
        guard contained.standardizedFileURL == candidate,
              attachedArtifact || acknowledgedOwnerPath || pureFakeTypedArtifact,
              FileManager.default.fileExists(atPath: contained.path)
        else { throw ResultActionServiceError.unsafeArtifact(reference) }
        return contained
    }

    private func installedFavoriteArtifactURL(for receipt: OmniRun.RunReceipt) async throws -> URL {
        guard let reference = receipt.artifactReference else { throw ResultActionServiceError.missingArtifact }
        // The original receipt must acknowledge this run's deterministic ID and
        // exact owner path, even when normal enrichment has removed that path.
        _ = try installedOwnerArtifactURL(for: receipt, reference: reference, requireExisting: false)
        let paths = try InstalledOwnerPaths(installedRoot: developmentRoot.url)
        let backend = InstalledOwnerBackend(
            paths: paths, dependencies: installedOwnerDependencies,
            runner: BoundedOwnerProcessRunner(allowedExecutables: [installedOwnerDependencies.python]),
            platform: platform, resolver: nil
        )
        // Read-only owner reconciliation validates canonical ID/kind in the
        // exact triage/bookmarks directories and prefers the promoted bookmark.
        guard case .succeeded(let evidence) = await backend.reconcile(operation: .captureLink, runID: receipt.id.rawValue),
              let path = evidence.ownerPath else { throw ResultActionServiceError.unsafeArtifact(reference) }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func installedOwnerArtifactURL(for receipt: OmniRun.RunReceipt, reference: String, requireExisting: Bool = true) throws -> URL {
        let paths = try InstalledOwnerPaths(installedRoot: developmentRoot.url)
        guard reference.hasPrefix("/") else { throw ResultActionServiceError.unsafeArtifact(reference) }
        let candidate = URL(fileURLWithPath: reference).standardizedFileURL
        try InstalledOwnerPaths.requireUnaliased(candidate)
        let operation: OwnerOperation
        let expectedOwnerID: String
        switch receipt.moduleID {
        case "capture.favorite":
            operation = .captureLink
            expectedOwnerID = ReplicaOwnerBackend.digest("\(operation.rawValue)|\(receipt.id.rawValue)")
            guard [paths.base.appendingPathComponent("triage"), paths.base.appendingPathComponent("bookmarks")].contains(candidate.deletingLastPathComponent()),
                  candidate.lastPathComponent.hasSuffix("_\(expectedOwnerID).md") else { throw ResultActionServiceError.unsafeArtifact(reference) }
        case "capture.base":
            operation = .captureBaseNote
            expectedOwnerID = ReplicaOwnerBackend.digest("\(operation.rawValue)|\(receipt.id.rawValue)")
            guard candidate.deletingLastPathComponent() == paths.base,
                  candidate.lastPathComponent.hasSuffix("_\(expectedOwnerID).md") else { throw ResultActionServiceError.unsafeArtifact(reference) }
        case "cache.stash":
            operation = .replaceCurrentStash
            expectedOwnerID = receipt.id.rawValue
            guard candidate == paths.stash else { throw ResultActionServiceError.unsafeArtifact(reference) }
        default: throw ResultActionServiceError.unsafeArtifact(reference)
        }
        guard receipt.effects?.contains(where: { effect in
            effect.status == "succeeded" && effect.operationID == operation.rawValue
                && effect.ownerID == expectedOwnerID && effect.ownerAcknowledgement?.isEmpty == false
                && effect.ownerPath.map { URL(fileURLWithPath: $0).standardizedFileURL == candidate } == true
        }) == true
        else { throw ResultActionServiceError.unsafeArtifact(reference) }
        if requireExisting {
            guard try candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ResultActionServiceError.unsafeArtifact(reference)
            }
        }
        return candidate
    }

    private func expectedFakeArtifactURL(for receipt: OmniRun.RunReceipt) throws -> URL? {
        guard receipt.executionProfile == OmniExecutionProfile.pureFake.rawValue else { return nil }
        let relative: String
        switch receipt.moduleID {
        case "capture.favorite": relative = "fake-owners/favorites/\(receipt.id.rawValue).txt"
        case "capture.base": relative = "fake-owners/base-artifacts/\(receipt.id.rawValue).txt"
        case "cache.stash": relative = "fake-owners/stash/current.json"
        case "find.indexed": relative = "fake-owners/result-artifacts/fixture-find/\(receipt.id.rawValue).txt"
        case "open.target": relative = "fake-owners/result-artifacts/fixture-open/\(receipt.id.rawValue).txt"
        case "reveal.target": relative = "fake-owners/result-artifacts/fixture-reveal/\(receipt.id.rawValue).txt"
        default: return nil
        }
        return try developmentRoot.containedURL(relativePath: relative)
    }
}

/// Production-capable platform adapter. Development compositions inject the
/// recorder instead; this adapter exists to keep OS URL behavior typed and
/// testable without granting a model any platform surface.
public struct NSWorkspacePlatformAdapter: PlatformActionPerforming {
    public init() {}

    public func perform(_ action: PlatformAction) async throws -> PlatformAcknowledgement {
        switch action {
        case .copyText(let text):
            let copied = await MainActor.run { () -> Bool in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return pasteboard.setString(text, forType: .string)
            }
            guard copied else { throw OmniAdapterError.unavailable("pasteboard rejected result text") }
            return PlatformAcknowledgement(identifier: "platform-copy", detail: "copied-text")
        case .openComposer(let draft):
            let url = try ComposerURL.make(draft)
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            guard opened else { throw OmniAdapterError.unavailable("destination composer did not open") }
            return PlatformAcknowledgement(identifier: "platform-composer", detail: url.absoluteString)
        case .openURL(let url):
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            guard opened else { throw OmniAdapterError.unavailable("platform URL did not open") }
            return PlatformAcknowledgement(identifier: "platform-url", detail: url.absoluteString)
        case .openFile(let url):
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            guard opened else { throw OmniAdapterError.unavailable("platform file did not open") }
            return PlatformAcknowledgement(identifier: "platform-file", detail: url.path)
        case .revealFile(let url):
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return PlatformAcknowledgement(identifier: "platform-reveal", detail: url.path)
        case .openSettings(let section):
            return PlatformAcknowledgement(identifier: "platform-settings", detail: section)
        }
    }
}

/// Records every platform action like the replica recorder, then performs it
/// through `NSWorkspacePlatformAdapter`. Only OS-level, non-mutating actions
/// flow here (open URL/file, reveal, copy, composer); owner mutations remain
/// confined to the replica root regardless of this adapter.
public actor LivePlatformAdapter: RecordingPlatformActionPerforming {
    /// Acknowledgement identifiers from this adapter start with this prefix so
    /// owners can word their summary as performed rather than prepared.
    public static let acknowledgementPrefix = "live-"
    public nonisolated let mode: PlatformActionMode = .live
    private let live = NSWorkspacePlatformAdapter()
    private var actions: [PlatformAction] = []

    public init() {}

    public func perform(_ action: PlatformAction) async throws -> PlatformAcknowledgement {
        actions.append(action)
        let acknowledgement = try await live.perform(action)
        return PlatformAcknowledgement(identifier: "\(Self.acknowledgementPrefix)\(acknowledgement.identifier)-\(actions.count)", detail: acknowledgement.detail)
    }

    public func recordedActions() -> [PlatformAction] { actions }
}

enum ComposerURL {
    static func make(_ draft: ComposerDraft) throws -> URL {
        let body = percentEncode(draft.body)
        let value: String
        switch draft.channel {
        case .email:
            let subject = draft.subject.map { "subject=\(percentEncode($0))&" } ?? ""
            value = "mailto:?\(subject)body=\(body)"
        case .message:
            value = "sms:&body=\(body)"
        }
        guard let url = URL(string: value) else { throw OmniAdapterError.unsafeInput("unable to encode composer URL") }
        return url
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return value.utf8.map { byte in
            allowed.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }
}
