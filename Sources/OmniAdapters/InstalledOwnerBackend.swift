import Darwin
import Foundation
import OmniCore
import OmniRun

/// This dependency selects trusted implementation code, never owner destinations.
/// Production data paths are fixed by InstalledOwnerPaths and are not CLI inputs.
public struct InstalledOwnerDependencies: Sendable {
    public let bridgeScript: URL
    public let python: URL
    public let ledgerScript: URL

    public static let sourceTreeInstalled = InstalledOwnerDependencies(
        bridgeScript: OmniLayout.installedOwnerBridgeScript,
        python: OmniLayout.ownerPython,
        ledgerScript: OmniLayout.ledgerScript
    )

    public init(bridgeScript: URL, python: URL, ledgerScript: URL) {
        self.bridgeScript = bridgeScript
        self.python = python
        self.ledgerScript = ledgerScript
    }
}

public struct InstalledOwnerPaths: Sendable {
    public let root: URL
    public let base = OmniLayout.baseRoot
    public let ledger = OmniLayout.ledgerCapture
    public let queue = OmniLayout.officeQueue
    public var stash: URL { root.appendingPathComponent("current-stash.json") }
    public var settings: URL { root.appendingPathComponent("settings/config.json") }

    public init(installedRoot: URL) throws {
        let canonical = OmniLayout.installedRoot
        guard installedRoot.standardizedFileURL == canonical else {
            throw OmniAdapterError.unsafeInput("installed owners require the canonical installed support root")
        }
        try Self.requireUnaliased(canonical)
        root = canonical
    }

    static func requireUnaliased(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"),
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
        else { throw OmniAdapterError.unsafeInput("installed owner path aliases another target") }
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw OmniAdapterError.unsafeInput("installed owner path is a symlink") }
        }
    }
}

extension OmniInstalledAdapterGraph {
    /// Explicit activation for the installed host. The replica graph and its
    /// path guards remain independent and cannot select installed destinations.
    public init(
        installedRoot: URL,
        store: OmniRunStore,
        platform: any PlatformActionPerforming,
        retrieveResolver: RetrieveResolverDependencies? = nil,
        dependencies: InstalledOwnerDependencies = .sourceTreeInstalled
    ) throws {
        paths = try InstalledOwnerPaths(installedRoot: installedRoot)
        let sealed = try OmniInstalledAdapterGraph()
        bindings = sealed.bindings
        var executables: Set<URL> = [dependencies.python]
        if let retrieveResolver { executables.insert(retrieveResolver.uv) }
        let runner = BoundedOwnerProcessRunner(allowedExecutables: executables)
        let resolver = retrieveResolver.map { RetrieveIndexResolver(dependencies: $0, processRunner: runner) }
        registeredResolver = resolver?.descriptor
        let backend = InstalledOwnerBackend(paths: paths, dependencies: dependencies, runner: runner, platform: platform, resolver: resolver)
        let handles = bindings.map { binding in
            let idempotent = [.captureLink, .captureBaseNote, .replaceCurrentStash].contains(binding.operation)
            let reason = idempotent ? "deterministic owner identity or stash run marker" :
                (binding.operation.isMutation ? "no owner idempotency key; uncertain means no retry" : "read or platform action")
            return ReceiptAwareOwnerOperation(
                operation: binding.operation,
                target: OwnerTargetDescriptor(ownerID: binding.ownerID, operation: binding.operation, redactedTarget: "installed:\(binding.ownerID)", targetDigest: ReplicaOwnerBackend.digest(binding.canonicalTarget)),
                store: store, backend: backend, profile: .installedLive,
                idempotencyProven: idempotent, retrySafetyReason: reason
            ).handle()
        }
        environment = try CapabilityEnvironment(profile: .installedLive, installedPolicy: Set(bindings.map(\.operation)), handles: handles)
    }
}

private struct InstalledCaptureAcknowledgement: Decodable {
    let schema_version: Int
    let status: String
    let operation: String?
    let owner_id: String?
    let path: String?
}

actor InstalledOwnerBackend: ReceiptOwnerBackend {
    private let paths: InstalledOwnerPaths
    private let dependencies: InstalledOwnerDependencies
    private let runner: any OwnerProcessRunning
    private let platform: any PlatformActionPerforming
    private let resolver: (any RegisteredIndexResolving)?

    init(paths: InstalledOwnerPaths, dependencies: InstalledOwnerDependencies, runner: any OwnerProcessRunning, platform: any PlatformActionPerforming, resolver: (any RegisteredIndexResolving)?) {
        self.paths = paths
        self.dependencies = dependencies
        self.runner = runner
        self.platform = platform
        self.resolver = resolver
    }

    func perform(operation: OwnerOperation, request: OwnerOperationRequest, failure: OwnerFailurePoint) async -> OwnerCallResult {
        do {
            guard request.payload.utf8.count <= 256 * 1024 else { throw OmniAdapterError.unsafeInput("owner payload exceeds bound") }
            switch operation {
            case .captureLink, .captureBaseNote:
                return try await capture(operation, request: request, reconcile: false)
            case .appendLedger:
                return .succeeded(try await appendLedger(request))
            case .appendOfficeQueue:
                return .succeeded(try appendQueue(request))
            case .replaceCurrentStash:
                return .succeeded(try stash(request))
            case .openSearchURL:
                guard !request.offline, !request.payload.isEmpty else { throw OmniAdapterError.unsafeInput("search needs a query and online mode") }
                var parts = URLComponents(string: "https://www.google.com/search")!
                parts.queryItems = [URLQueryItem(name: "q", value: request.payload)]
                guard let url = parts.url else { throw OmniAdapterError.unsafeInput("invalid search query") }
                let ack = try await platform.perform(.openURL(url))
                return .succeeded(evidence("Opened Google search in the default browser", path: url.absoluteString, ack: ack.detail, actions: [.open, .dismiss]))
            case .readRegisteredIndex:
                let matches = try await resolve(request.payload, requireNamespace: false)
                let text = matches.map { "\($0.namespacedID) · \($0.title)\n\($0.path)" }.joined(separator: "\n")
                // The `/find` picker reads the rows; the text stays as before.
                let find = OmniFindResult.exactID(typed: request.payload, entries: matches)
                return .succeeded(OwnerEvidence(result: ModuleResult(summary: text.isEmpty ? "No registered matches" : text, allowedActions: text.isEmpty ? [.dismiss] : [.copy, .dismiss], fullText: text, find: find), ownerID: nil, ownerPath: nil, acknowledgement: "registered-resolver-count=\(matches.count)", boundedOutput: nil, idempotencyProven: false, retrySafetyReason: "read-only", reconciliationDisposition: "read-only"))
            case .openResolvedTarget, .revealResolvedTarget:
                let key = request.referenceID ?? request.payload
                let matches = try await resolve(key, requireNamespace: true)
                guard matches.count == 1 else {
                    throw matches.isEmpty ? OmniAdapterError.missingTarget(key) : OmniAdapterError.ambiguousTarget(key)
                }
                let path = URL(fileURLWithPath: matches[0].path)
                try InstalledOwnerPaths.requireUnaliased(path)
                guard FileManager.default.fileExists(atPath: path.path) else { throw OmniAdapterError.staleTarget(key) }
                let reveal = operation == .revealResolvedTarget
                let ack = try await platform.perform(reveal ? .revealFile(path) : .openFile(path))
                return .succeeded(evidence("\(reveal ? "Revealed" : "Opened") \(key)", path: path.path, ack: ack.identifier))
            case .openOmniSettings, .openModelSettings:
                let section = operation == .openModelSettings ? "models" : "general"
                let ack = try await platform.perform(.openSettings(section: section))
                return .succeeded(evidence("Opened settings: \(section)", ack: ack.identifier))
            case .saveSettings:
                guard request.explicitUserSave else { return .failed("Settings mutation requires an explicit user save", nil) }
                let data = Data(request.payload.utf8)
                guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    return .failed("Settings service must provide a validated JSON object", nil)
                }
                try InstalledOwnerPaths.requireUnaliased(paths.settings)
                try FileManager.default.createDirectory(at: paths.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: paths.settings, options: .atomic)
                guard try Data(contentsOf: paths.settings) == data else { throw OmniAdapterError.unavailable("settings readback mismatch") }
                return .succeeded(evidence("Saved model settings", path: paths.settings.path, ownerID: request.runID, ack: "explicit-user-save;atomic;readback=true"))
            case .translateLocal:
                return .failed("No installed local translation helper is bound", nil)
            }
        } catch let error as OmniAdapterError {
            if case .unsafeInput = error { return .failed(error.description, nil) }
            return operation.isMutation ? .uncertain(error.description, nil) : .failed(error.description, nil)
        } catch {
            return operation.isMutation ? .uncertain("Owner outcome could not be proved: \(error)", nil) : .failed(String(describing: error), nil)
        }
    }

    func reconcile(operation: OwnerOperation, runID: String) async -> OwnerCallResult {
        do {
            switch operation {
            case .captureLink, .captureBaseNote:
                return try await capture(operation, request: OwnerOperationRequest(runID: runID, payload: ""), reconcile: true)
            case .replaceCurrentStash:
                try InstalledOwnerPaths.requireUnaliased(paths.stash)
                guard OmniStashReceipt.proves(runID: runID, in: OmniStashStack(url: paths.stash))
                else { return .uncertain("The stash no longer proves this run", nil) }
                return .succeeded(evidence("Reconciled stash", path: paths.stash.path, ownerID: runID, ack: "run-marker-and-digest", idempotent: true, actions: [.copy, .dismiss]))
            default:
                return .uncertain("Owner has no crash-safe identity lookup; do not retry", nil)
            }
        } catch { return .uncertain("Owner reconciliation unavailable: \(error)", nil) }
    }

    private func capture(_ operation: OwnerOperation, request: OwnerOperationRequest, reconcile: Bool) async throws -> OwnerCallResult {
        try InstalledOwnerPaths.requireUnaliased(dependencies.bridgeScript)
        try InstalledOwnerPaths.requireUnaliased(paths.base)
        if !reconcile {
            guard !request.payload.isEmpty else { throw OmniAdapterError.unsafeInput("capture is empty") }
            if operation == .captureLink {
                guard let url = URL(string: request.payload), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                      request.payload.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                    throw OmniAdapterError.unsafeInput("favorite requires one HTTP(S) URL")
                }
            }
        }
        var arguments = ["-I", "-B", dependencies.bridgeScript.path, operation.rawValue, "--run-id", request.runID]
        arguments += reconcile ? ["--reconcile"] : ["--payload=\(request.payload)"]
        let result = try await runner.run(OwnerProcessSpec(executable: dependencies.python, arguments: arguments, environment: ownerEnvironment, timeout: .seconds(20)))
        guard !result.timedOut, !result.cancelled, result.processGroupIsolated, result.stoppedAndReaped,
              result.exitStatus == 0,
              let ack = try? JSONDecoder().decode(InstalledCaptureAcknowledgement.self, from: Data(result.stdout.utf8)),
              ack.schema_version == 1, ack.status == "succeeded", ack.operation == operation.rawValue,
              ack.owner_id == ReplicaOwnerBackend.digest("\(operation.rawValue)|\(request.runID)"),
              let path = ack.path
        else { return .uncertain("Capture did not return a provable owner acknowledgement", nil) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard (try? InstalledOwnerPaths.requireUnaliased(url)) != nil else {
            return .uncertain("Capture acknowledged an aliased owner target", nil)
        }
        let roots = operation == .captureLink ? [paths.base.appendingPathComponent("triage"), paths.base.appendingPathComponent("bookmarks")] : [paths.base, paths.base.appendingPathComponent("captures")]
        guard roots.contains(url.deletingLastPathComponent()), url.pathExtension == "md",
              url.lastPathComponent.hasSuffix("_\(ack.owner_id!).md") else { return .uncertain("Capture acknowledged an unexpected owner target", nil) }
        return .succeeded(evidence(operation == .captureLink ? "Captured through Link Collector" : "Captured through Base Capture", path: path, ownerID: ack.owner_id, ack: "typed-owner-acknowledged", idempotent: true, actions: [.open, .reveal, .dismiss]))
    }

    private var ownerEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": OmniLayout.homeDirectory.path, "PYTHONNOUSERSITE": "1", "PYTHONSAFEPATH": "1"]
    }

    private func appendLedger(_ request: OwnerOperationRequest) async throws -> OwnerEvidence {
        guard !request.payload.trimmingCharacters(in: .whitespaces).isEmpty, request.payload.rangeOfCharacter(from: .newlines) == nil else { throw OmniAdapterError.unsafeInput("Ledger task must be one non-empty line") }
        try InstalledOwnerPaths.requireUnaliased(paths.ledger)
        try InstalledOwnerPaths.requireUnaliased(dependencies.ledgerScript)
        let before = try existingData(paths.ledger)
        var environment = ownerEnvironment
        environment["LEDGER_DIR"] = paths.ledger.deletingLastPathComponent().path
        let result = try await runner.run(OwnerProcessSpec(executable: dependencies.python, arguments: ["-I", "-B", dependencies.ledgerScript.path, "add", request.payload], environment: environment))
        guard (try? InstalledOwnerPaths.requireUnaliased(paths.ledger)) != nil else {
            throw OmniAdapterError.unavailable("Ledger destination changed after dispatch; do not retry")
        }
        let after = try Data(contentsOf: paths.ledger)
        let expected = Data((request.payload.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
        guard !result.timedOut, !result.cancelled, result.processGroupIsolated, result.stoppedAndReaped, result.exitStatus == 0,
              after == before + expected else { throw OmniAdapterError.unavailable("Ledger append outcome is uncertain; do not retry") }
        return evidence("Added to Ledger", path: paths.ledger.path, ack: "ledger-add;exact-append-proof")
    }

    private func appendQueue(_ request: OwnerOperationRequest) throws -> OwnerEvidence {
        let value = request.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .newlines) == nil else { throw OmniAdapterError.unsafeInput("Office reminder must be one non-empty line") }
        try InstalledOwnerPaths.requireUnaliased(paths.queue)
        let fd = open(paths.queue.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OmniAdapterError.unavailable("Office queue could not be opened") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OmniAdapterError.unavailable("Office queue lock failed") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw OmniAdapterError.unavailable("Office queue is not a regular file") }
        let before = try Data(contentsOf: paths.queue)
        let separator = !before.isEmpty && before.last != 10 ? "\n" : ""
        let data = Data((separator + "- " + value + "\n").utf8)
        let count = data.withUnsafeBytes { buffer in Darwin.write(fd, buffer.baseAddress, buffer.count) }
        guard count == data.count, fsync(fd) == 0 else { throw OmniAdapterError.unavailable("Office queue append is uncertain; do not retry") }
        return evidence("Added to Office queue", path: paths.queue.path, ack: "append-only;fsync=true;length=\(data.count)")
    }

    private func stash(_ request: OwnerOperationRequest) throws -> OwnerEvidence {
        guard !request.payload.isEmpty else { throw OmniAdapterError.unsafeInput("stash is empty") }
        try InstalledOwnerPaths.requireUnaliased(paths.stash)
        let outcome: OmniStashPushOutcome
        do {
            outcome = try OmniStashReceipt.push(request.payload, runID: request.runID, source: request.source, into: OmniStashStack(url: paths.stash))
        } catch OmniStashError.empty {
            throw OmniAdapterError.unsafeInput("stash is empty")
        } catch OmniStashError.tooLarge {
            throw OmniAdapterError.unsafeInput("stash entry exceeds bound")
        } catch {
            throw OmniAdapterError.unavailable("stash push outcome is uncertain: \(error)")
        }
        return evidence(OmniStashReceipt.summary(for: outcome), path: paths.stash.path, ownerID: request.runID, ack: "stack-push;atomic;readback=true;dropped=\(outcome.dropped != nil)", idempotent: true, actions: [.copy, .dismiss])
    }

    private func resolve(_ value: String, requireNamespace: Bool) async throws -> [ReplicaIndexEntry] {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        let namespace: String?
        let id: String
        if parts.count == 2, ["doc", "run"].contains(String(parts[0])) {
            namespace = String(parts[0]); id = String(parts[1])
        } else if parts.count == 1, !requireNamespace {
            namespace = nil; id = key
        } else { throw OmniAdapterError.unsafeInput("target requires doc:<16-hex-id> or run:<16-hex-id>") }
        guard RegisteredIndexID.isExact(id) else { throw OmniAdapterError.unavailable("Installed retrieval currently requires an exact 16-hex ID") }
        guard let resolver else { throw OmniAdapterError.unavailable("No registered retrieval resolver is bound") }
        return try await resolver.resolve(id: id).filter { $0.id == id && ["doc", "run"].contains($0.namespace) && (namespace == nil || $0.namespace == namespace) }
    }

    private func existingData(_ url: URL) throws -> Data {
        if !FileManager.default.fileExists(atPath: url.path) { return Data() }
        return try Data(contentsOf: url)
    }

    private func evidence(_ summary: String, path: String? = nil, ownerID: String? = nil, ack: String, idempotent: Bool = false, actions: [ResultAction] = [.dismiss]) -> OwnerEvidence {
        OwnerEvidence(result: ModuleResult(summary: summary, artifactReference: path, allowedActions: actions), ownerID: ownerID, ownerPath: path, acknowledgement: ack, boundedOutput: nil, idempotencyProven: idempotent, retrySafetyReason: idempotent ? "deterministic owner identity or run marker" : "no mutation retry claim", reconciliationDisposition: "owner-acknowledged")
    }
}
