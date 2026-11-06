import Darwin
import Foundation
import OmniCore
import OmniRun

public enum OmniAdapterError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidReplicaRoot(String)
    case forbiddenReplicaRoot(String)
    case symlinkEscape(String)
    case unsafeInput(String)
    case missingOwnerOperation(String)
    case executableNotAllowed(String)
    case processFailed(Int32, String)
    case processTimedOut
    case malformedAcknowledgement
    case ambiguousTarget(String)
    case missingTarget(String)
    case staleTarget(String)
    case explicitSaveRequired
    case unavailable(String)

    public var description: String {
        switch self {
        case .invalidReplicaRoot(let value): "invalid replica root: \(value)"
        case .forbiddenReplicaRoot(let value): "forbidden replica root: \(value)"
        case .symlinkEscape(let value): "replica path escapes through a symlink: \(value)"
        case .unsafeInput(let value): "unsafe owner input: \(value)"
        case .missingOwnerOperation(let value): "owner operation missing: \(value)"
        case .executableNotAllowed(let value): "owner executable is not allowlisted: \(value)"
        case .processFailed(let status, let message): "owner process failed (\(status)): \(message)"
        case .processTimedOut: "owner process timed out and was reaped"
        case .malformedAcknowledgement: "owner returned a malformed acknowledgement"
        case .ambiguousTarget(let value): "target is ambiguous: \(value)"
        case .missingTarget(let value): "target is missing: \(value)"
        case .staleTarget(let value): "target is stale: \(value)"
        case .explicitSaveRequired: "settings mutation requires an explicit user save"
        case .unavailable(let value): value
        }
    }
}

public enum OwnerFailurePoint: String, Sendable, CaseIterable {
    case none
    case beforeAttempt
    case afterAttemptBeforeOwnerCall
    case duringOwnerWork
    case afterOwnerMutationBeforeAcknowledgement
    case afterAcknowledgementBeforeOutcome
}

public actor OwnerFailureController {
    private var values: [OwnerOperation: OwnerFailurePoint] = [:]

    public init() {}

    public func set(_ point: OwnerFailurePoint, for operation: OwnerOperation) {
        values[operation] = point
    }

    func point(for operation: OwnerOperation) -> OwnerFailurePoint {
        values[operation] ?? .none
    }
}

public enum PlatformAction: Sendable, Equatable {
    case openURL(URL)
    case openFile(URL)
    case revealFile(URL)
    case openSettings(section: String)
    case copyText(String)
    case openComposer(ComposerDraft)
}

public struct PlatformAcknowledgement: Sendable, Equatable {
    public let identifier: String
    public let detail: String

    public init(identifier: String, detail: String) {
        self.identifier = identifier
        self.detail = detail
    }
}

public protocol PlatformActionPerforming: Sendable {
    func perform(_ action: PlatformAction) async throws -> PlatformAcknowledgement
}

/// A platform adapter whose every requested action stays inspectable. The
/// recorder only records; `LivePlatformAdapter` records and then performs.
public protocol RecordingPlatformActionPerforming: PlatformActionPerforming {
    /// Stable label for status surfaces: `recorded` or `live`.
    var mode: PlatformActionMode { get }
    func recordedActions() async -> [PlatformAction]
}

public enum PlatformActionMode: String, Sendable, Equatable, Codable {
    /// Actions are recorded and acknowledged without touching the OS.
    case recorded
    /// Non-mutating actions (open URL/file, reveal, copy, composer) reach the
    /// OS through `NSWorkspacePlatformAdapter`; owner mutations stay replica.
    case live
}

public actor RecordingPlatformAdapter: RecordingPlatformActionPerforming {
    public nonisolated let mode: PlatformActionMode = .recorded
    private var actions: [PlatformAction] = []

    public init() {}

    public func perform(_ action: PlatformAction) async throws -> PlatformAcknowledgement {
        actions.append(action)
        return PlatformAcknowledgement(identifier: "replica-platform-ack-\(actions.count)", detail: String(describing: action))
    }

    public func recordedActions() -> [PlatformAction] { actions }
}

public protocol TranslationProviding: Sendable {
    func translate(_ text: String) async throws -> String
}

public struct UnavailableTranslationProvider: TranslationProviding {
    public init() {}
    public func translate(_ text: String) async throws -> String {
        throw OmniAdapterError.unavailable("no injected local translation provider is configured")
    }
}

public struct ClosureTranslationProvider: TranslationProviding {
    private let implementation: @Sendable (String) async throws -> String

    public init(_ implementation: @escaping @Sendable (String) async throws -> String) {
        self.implementation = implementation
    }

    public func translate(_ text: String) async throws -> String {
        try await implementation(text)
    }
}

public struct OwnerProcessSpec: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let timeout: Duration
    public let outputLimit: Int

    public init(executable: URL, arguments: [String], environment: [String: String], timeout: Duration = .seconds(10), outputLimit: Int = 64 * 1024) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.outputLimit = outputLimit
    }
}

public struct OwnerProcessResult: Sendable, Equatable {
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let processGroupIsolated: Bool
    public let stoppedAndReaped: Bool
    public let cancelled: Bool

    public init(exitStatus: Int32, stdout: String, stderr: String, timedOut: Bool, processGroupIsolated: Bool, stoppedAndReaped: Bool, cancelled: Bool = false) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.processGroupIsolated = processGroupIsolated
        self.stoppedAndReaped = stoppedAndReaped
        self.cancelled = cancelled
    }
}

public protocol OwnerProcessRunning: Sendable {
    func run(_ spec: OwnerProcessSpec) async throws -> OwnerProcessResult
}

public struct BoundedOwnerProcessRunner: OwnerProcessRunning {
    private let allowedExecutables: Set<String>

    public init(allowedExecutables: Set<URL>) {
        self.allowedExecutables = Set(allowedExecutables.map { $0.standardizedFileURL.path })
    }

    public func run(_ spec: OwnerProcessSpec) async throws -> OwnerProcessResult {
        guard allowedExecutables.contains(spec.executable.standardizedFileURL.path) else {
            throw OmniAdapterError.executableNotAllowed(spec.executable.path)
        }
        let supervisor = OwnerProcessSupervisor(spec: spec)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try supervisor.runBlocking()
            }.value
        } onCancel: {
            supervisor.cancel()
        }
    }
}

private final class OwnerProcessSupervisor: @unchecked Sendable {
    private let spec: OwnerProcessSpec
    private let lock = NSLock()
    private var processID: pid_t = 0
    private var cancellationRequested = false

    init(spec: OwnerProcessSpec) { self.spec = spec }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let processID = self.processID
        lock.unlock()
        guard processID > 0 else { return }
        _ = kill(-processID, SIGTERM)
    }

    func runBlocking() throws -> OwnerProcessResult {
        let output = Pipe()
        let errors = Pipe()
        let stdoutBuffer = LockedDataBuffer(limit: spec.outputLimit)
        let stderrBuffer = LockedDataBuffer(limit: spec.outputLimit)
        let endedStreams = EndedStreams()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; endedStreams.end(STDOUT_FILENO) } else { stdoutBuffer.append(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; endedStreams.end(STDERR_FILENO) } else { stderrBuffer.append(data) }
        }
        lock.lock()
        let cancelledBeforeLaunch = cancellationRequested
        lock.unlock()
        if cancelledBeforeLaunch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            return OwnerProcessResult(exitStatus: SIGTERM, stdout: "", stderr: "", timedOut: false, processGroupIsolated: false, stoppedAndReaped: true, cancelled: true)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            throw OmniAdapterError.processFailed(errno, "unable to initialize process-group spawn")
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }
        let outputRead = output.fileHandleForReading.fileDescriptor
        let outputWrite = output.fileHandleForWriting.fileDescriptor
        let errorRead = errors.fileHandleForReading.fileDescriptor
        let errorWrite = errors.fileHandleForWriting.fileDescriptor
        var defaultSignals = sigset_t()
        var emptySignalMask = sigset_t()
        // Every signal starts at its default, as Foundation's Process does. The
        // host ignores SIGPIPE, SIGTERM and SIGINT, and an ignored signal
        // survives exec: cancel's SIGTERM would not stop an inheriting child.
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        sigemptyset(&emptySignalMask)
        // Only stdin (/dev/null, as launchd gives the host), stdout and stderr
        // reach the child. Otherwise it would also keep the original pipe write
        // ends, plus any other run's, and hold those outputs open.
        let spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        guard posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, errorWrite, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&fileActions, outputRead) == 0,
              posix_spawn_file_actions_addclose(&fileActions, errorRead) == 0,
              posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(spawnFlags)) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &emptySignalMask) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw OmniAdapterError.processFailed(errno, "unable to configure isolated process-group spawn")
        }

        var processID: pid_t = 0
        let arguments = [spec.executable.path] + spec.arguments
        let environment = spec.environment.keys.sorted().map { "\($0)=\(spec.environment[$0]!)" }
        let spawnStatus = withMutableCStringArray(arguments) { argumentPointers in
            withMutableCStringArray(environment) { environmentPointers in
                spec.executable.path.withCString { executablePointer in
                    posix_spawn(
                        &processID,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        guard spawnStatus == 0 else {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw OmniAdapterError.processFailed(spawnStatus, String(cString: strerror(spawnStatus)))
        }
        let isolated = getpgid(processID) == processID
        guard isolated else {
            _ = kill(processID, SIGKILL)
            var rejectedStatus: Int32 = 0
            while waitpid(processID, &rejectedStatus, 0) == -1, errno == EINTR {}
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw OmniAdapterError.processFailed(EPERM, "owner process did not enter its isolated group at spawn")
        }
        lock.lock()
        self.processID = processID
        let cancelAfterLaunch = cancellationRequested
        lock.unlock()
        if cancelAfterLaunch {
            _ = kill(-processID, SIGTERM)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: spec.timeout)
        var cancellationDeadline: ContinuousClock.Instant?
        var timedOut = false
        var waitStatus: Int32 = 0
        var reaped = false
        while !reaped, clock.now < deadline {
            let waitResult = waitpid(processID, &waitStatus, WNOHANG)
            if waitResult == processID {
                reaped = true
                break
            }
            if waitResult == -1, errno != EINTR {
                break
            }
            lock.lock()
            let cancelNow = cancellationRequested
            lock.unlock()
            if cancelNow, cancellationDeadline == nil {
                cancellationDeadline = clock.now.advanced(by: .milliseconds(250))
            }
            if let cancellationDeadline, clock.now >= cancellationDeadline {
                _ = kill(-processID, SIGKILL)
            }
            usleep(5_000)
        }
        if !reaped {
            timedOut = true
            _ = kill(-processID, SIGTERM)
            let grace = clock.now.advanced(by: .milliseconds(250))
            while !reaped, clock.now < grace {
                let waitResult = waitpid(processID, &waitStatus, WNOHANG)
                if waitResult == processID { reaped = true }
                if waitResult == -1, errno != EINTR { break }
                if !reaped { usleep(5_000) }
            }
            if !reaped { _ = kill(-processID, SIGKILL) }
        }
        while !reaped {
            let waitResult = waitpid(processID, &waitStatus, 0)
            if waitResult == processID { reaped = true }
            if waitResult == -1, errno != EINTR { break }
        }
        lock.lock()
        let stopRequested = timedOut || cancellationRequested
        lock.unlock()
        // The leader can die on SIGTERM before a group member that ignores it.
        if stopRequested {
            stopGroup(processID)
        }
        // Drain to EOF, bounded by the run's deadline and by cancellation: a
        // member that ignores SIGTERM, or a writer that left the group, can
        // hold the pipes open after the leader exits.
        var drainLimit: ContinuousClock.Instant?
        while !endedStreams.contains(STDOUT_FILENO, STDERR_FILENO) {
            // Sleep first: the handlers may not have seen EOF yet just after the reap.
            usleep(5_000)
            if endedStreams.contains(STDOUT_FILENO, STDERR_FILENO) { break }
            if let drainLimit {
                if clock.now >= drainLimit { break }
            } else {
                lock.lock()
                let cancelNow = cancellationRequested
                lock.unlock()
                let expired = clock.now >= deadline
                if expired { timedOut = true }
                if cancelNow || expired {
                    stopGroup(processID)
                    drainLimit = clock.now.advanced(by: .seconds(1))
                }
            }
        }
        let outputEnded = endedStreams.contains(STDOUT_FILENO, STDERR_FILENO)
        // A handler may still be running; the handles close when the pipes are
        // released, not here.
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let wasCancelled = cancellationRequested
        self.processID = 0
        lock.unlock()
        let groupGone = kill(-processID, 0) == -1 && errno == ESRCH
        return OwnerProcessResult(
            exitStatus: processExitStatus(waitStatus),
            stdout: stdoutBuffer.string,
            stderr: stderrBuffer.string,
            timedOut: timedOut,
            processGroupIsolated: true,
            // A writer that left the group and still holds the output is still running.
            stoppedAndReaped: reaped && groupGone && outputEnded,
            cancelled: wasCancelled
        )
    }

    private func stopGroup(_ processGroupID: pid_t) {
        // An empty group's ID can be reused; never signal one.
        guard kill(-processGroupID, 0) == 0 else { return }
        _ = kill(-processGroupID, SIGTERM)
        if !waitForGroupExit(processGroupID, within: .milliseconds(250)) {
            _ = kill(-processGroupID, SIGKILL)
            _ = waitForGroupExit(processGroupID, within: .seconds(1))
        }
    }

    private func waitForGroupExit(_ processGroupID: pid_t, within limit: Duration) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while true {
            if kill(-processGroupID, 0) == -1, errno == ESRCH { return true }
            guard clock.now < deadline else { return false }
            usleep(5_000)
        }
    }

    private func processExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    private func withMutableCStringArray<Result>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> Result
    ) rethrows -> Result {
        let pointers = values.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var terminated = pointers + [nil]
        return try terminated.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress)
        }
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var value = Data()

    init(limit: Int) { self.limit = max(0, limit) }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - value.count)
        if remaining > 0 { value.append(data.prefix(remaining)) }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: value, as: UTF8.self)
    }
}

/// The output streams whose readability handlers have seen EOF.
private final class EndedStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = Set<Int32>()

    func end(_ stream: Int32) {
        lock.lock()
        defer { lock.unlock() }
        ended.insert(stream)
    }

    func contains(_ streams: Int32...) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return streams.allSatisfy(ended.contains)
    }
}

/// The executable and owner source inputs required by the isolated adapter graph.
///
/// A packaged candidate supplies one non-symlink resource root.  The source-tree
/// value is retained only so existing development callers keep their historic
/// behavior; it is deliberately not inferred from a caller's environment.
public struct ReplicaOwnerDependencies: Sendable, Equatable {
    public let bridgeScript: URL
    public let python: URL
    public let ledgerScript: URL
    public let ownerResourceRoot: URL?

    public static let sourceTreeDevelopment = ReplicaOwnerDependencies(
        bridgeScript: OmniLayout.ownerBridgeScript,
        python: OmniLayout.ownerPython,
        ledgerScript: OmniLayout.ledgerScript,
        ownerResourceRoot: nil
    )

    public init(bridgeScript: URL, python: URL, ledgerScript: URL, ownerResourceRoot: URL? = nil) {
        self.bridgeScript = bridgeScript.standardizedFileURL
        self.python = python.standardizedFileURL
        self.ledgerScript = ledgerScript.standardizedFileURL
        self.ownerResourceRoot = ownerResourceRoot?.standardizedFileURL
    }

    public init(packagedResourceRoot: URL, python: URL) {
        let root = packagedResourceRoot.standardizedFileURL
        self.init(
            bridgeScript: root.appendingPathComponent("owner-bridge/omni_owner_bridge.py"),
            python: python,
            ledgerScript: root.appendingPathComponent("bin/ledger.py"),
            ownerResourceRoot: root
        )
    }

    public func validate() throws {
        try Self.requireRegularFile(bridgeScript, label: "owner bridge")
        try Self.requirePythonRuntime(python)
        try Self.requireRegularFile(ledgerScript, label: "Ledger script")
        guard let ownerResourceRoot else { return }
        try Self.requireDirectory(ownerResourceRoot, label: "owner resource root")
        let expectedBridge = ownerResourceRoot.appendingPathComponent("owner-bridge/omni_owner_bridge.py")
        let expectedLedger = ownerResourceRoot.appendingPathComponent("bin/ledger.py")
        guard bridgeScript == expectedBridge, ledgerScript == expectedLedger else {
            throw OmniAdapterError.unavailable("packaged owner executables must remain inside their resource root")
        }
        try Self.requireContainedRegularFile(bridgeScript, root: ownerResourceRoot, label: "owner bridge")
        try Self.requireContainedRegularFile(ledgerScript, root: ownerResourceRoot, label: "Ledger script")
        let required = [
            "owners/base-capture/src/base_capture/__init__.py",
            "owners/base-capture/src/base_capture/capture.py",
            "owners/link-collector/src/link_collector/__init__.py",
            "owners/link-collector/src/link_collector/capture.py",
            "owners/link-collector/src/link_collector/enrich.py",
            "owners/frontmatter/src/tooling_frontmatter/__init__.py",
            "owners/frontmatter/src/tooling_frontmatter/generator.py",
            "owners/frontmatter/src/tooling_frontmatter/identity.py",
            "owners/frontmatter/src/tooling_frontmatter/models.py",
            "owners/frontmatter/src/tooling_frontmatter/parser.py",
            "owners/frontmatter/src/tooling_frontmatter/registry.py",
            "owners/frontmatter/src/tooling_frontmatter/validator.py",
            "owners/frontmatter/registry/frontmatter-registry.json",
            "owners/frontmatter/registry/frontmatter-contract.md"
        ]
        for relative in required {
            let candidate = ownerResourceRoot.appendingPathComponent(relative)
            try Self.requireContainedRegularFile(candidate, root: ownerResourceRoot, label: "owner resource")
        }
    }

    private static func requireRegularFile(_ url: URL, label: String) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { throw OmniAdapterError.unavailable("\(label) is unavailable: \(url.path)") }
    }

    private static func requirePythonRuntime(_ url: URL) throws {
        let manager = FileManager.default
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard manager.fileExists(atPath: url.path),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { throw OmniAdapterError.unavailable("owner Python runtime is unavailable: \(url.path)") }
    }

    private static func requireDirectory(_ url: URL, label: String) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL
        else { throw OmniAdapterError.unavailable("\(label) is unavailable or aliases another path: \(url.path)") }
    }

    private static func requireContainedRegularFile(_ url: URL, root: URL, label: String) throws {
        let requested = url.standardizedFileURL
        let canonicalRoot = root.standardizedFileURL
        guard requested.path.hasPrefix(canonicalRoot.path + "/") else {
            throw OmniAdapterError.unavailable("\(label) escapes its resource root: \(requested.path)")
        }
        var cursor = canonicalRoot
        let relative = String(requested.path.dropFirst(canonicalRoot.path.count + 1))
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw OmniAdapterError.unavailable("\(label) traverses a symlink: \(cursor.path)")
            }
        }
        try requireRegularFile(requested, label: label)
    }
}

public struct ReplicaOwnerPaths: Sendable, Equatable {
    public let root: URL
    public let linkTriage: URL
    public let ledger: URL
    public let office: URL
    public let stash: URL
    public let base: URL
    public let index: URL
    public let settings: URL
    /// The replica stash stack (one file; the directory predates the stack).
    public var stashStack: URL { stash.appendingPathComponent("current.json") }

    public init(developmentRoot: OmniDevelopmentRoot) throws {
        root = try developmentRoot.containedURL(relativePath: "replica-owners")
        linkTriage = root.appendingPathComponent("link-collector/triage", isDirectory: true)
        ledger = root.appendingPathComponent("ledger", isDirectory: true)
        office = root.appendingPathComponent("office", isDirectory: true)
        stash = root.appendingPathComponent("stash", isDirectory: true)
        base = root.appendingPathComponent("base", isDirectory: true)
        index = root.appendingPathComponent("index/entries.json")
        settings = root.appendingPathComponent("settings/config.json")
        for directory in [root, linkTriage, ledger, office, stash, base, index.deletingLastPathComponent(), settings.deletingLastPathComponent()] {
            try Self.prepareDirectory(directory, envelope: developmentRoot.url)
        }
    }

    private static func prepareDirectory(_ candidate: URL, envelope: URL) throws {
        let manager = FileManager.default
        let base = envelope.standardizedFileURL.resolvingSymlinksInPath()
        let requested = candidate.standardizedFileURL
        guard requested.path.hasPrefix(base.path + "/") else {
            throw OmniAdapterError.forbiddenReplicaRoot(requested.path)
        }
        let relative = String(requested.path.dropFirst(base.path.count + 1))
        var cursor = base
        for component in relative.split(separator: "/").map(String.init) {
            cursor.appendPathComponent(component, isDirectory: true)
            if manager.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true else { throw OmniAdapterError.symlinkEscape(cursor.path) }
                guard values.isDirectory == true else { throw OmniAdapterError.invalidReplicaRoot(cursor.path) }
            } else {
                try manager.createDirectory(at: cursor, withIntermediateDirectories: false)
            }
            let resolved = cursor.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == base.path || resolved.hasPrefix(base.path + "/") else {
                throw OmniAdapterError.symlinkEscape(resolved)
            }
        }
    }
}

public struct ReplicaIndexEntry: Codable, Sendable, Equatable {
    public let namespace: String
    public let id: String
    public let title: String
    public let path: String

    public init(namespace: String, id: String, title: String, path: String) {
        self.namespace = namespace
        self.id = id
        self.title = title
        self.path = path
    }

    public var namespacedID: String { "\(namespace):\(id)" }
}

/// Read-only resolution of one exact 16-hex frontmatter/run ID against the
/// user's registered retrieval surfaces. This is the first owner reach that
/// leaves the replica root: it reads, never writes, and only answers exact IDs.
public protocol RegisteredIndexResolving: Sendable {
    /// Human-readable binding for status surfaces.
    var descriptor: String { get }
    func resolve(id: String) async throws -> [ReplicaIndexEntry]
}

public enum RegisteredIndexID {
    /// `retrieve` accepts exactly sixteen lowercase hex characters.
    public static func isExact(_ value: String) -> Bool {
        value.count == 16 && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// Binding of the local `retrieve` front door: `uv run --project <retrieval>
/// python <retrieval>/retrieve …`. Construction validates paths only.
public struct RetrieveResolverDependencies: Sendable, Equatable {
    public let uv: URL
    public let retrievalRoot: URL

    public init(uv: URL, retrievalRoot: URL) {
        self.uv = uv.standardizedFileURL
        self.retrievalRoot = retrievalRoot.standardizedFileURL
    }

    public var script: URL { retrievalRoot.appendingPathComponent("retrieve") }

    /// Daniel's Tooling layout. `nil` when either binary or script is absent,
    /// so composition can report the resolver as unavailable instead of failing.
    public static func locate(home: URL = OmniLayout.homeDirectory) -> RetrieveResolverDependencies? {
        let root = home.appendingPathComponent("Tooling/retrieval", isDirectory: true)
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", home.appendingPathComponent(".local/bin/uv").path]
        guard let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let dependencies = RetrieveResolverDependencies(uv: URL(fileURLWithPath: uv), retrievalRoot: root)
        guard FileManager.default.isReadableFile(atPath: dependencies.script.path) else { return nil }
        return dependencies
    }
}

public struct RetrieveIndexResolver: RegisteredIndexResolving {
    private let dependencies: RetrieveResolverDependencies
    private let processRunner: any OwnerProcessRunning
    private let home: URL

    public init(dependencies: RetrieveResolverDependencies, processRunner: any OwnerProcessRunning, home: URL = OmniLayout.homeDirectory) {
        self.dependencies = dependencies
        self.processRunner = processRunner
        self.home = home
    }

    public var descriptor: String { "retrieve · \(dependencies.script.path)" }

    /// Frontmatter documents (`retrieve docs resolve-id`) and agent-output runs
    /// (`retrieve runs show`) are queried concurrently; either may be absent.
    public func resolve(id: String) async throws -> [ReplicaIndexEntry] {
        guard RegisteredIndexID.isExact(id) else { throw OmniAdapterError.unsafeInput("registered lookup requires one 16-hex ID") }
        async let document = run(["docs", "resolve-id", id])
        async let run = run(["runs", "show", id])
        let (documentResult, runResult) = try await (document, run)
        var entries: [ReplicaIndexEntry] = []
        if documentResult.exitStatus == 0, let path = Self.firstLine(documentResult.stdout), path.hasPrefix("/") {
            entries.append(ReplicaIndexEntry(namespace: "doc", id: id, title: URL(fileURLWithPath: path).lastPathComponent, path: path))
        } else if documentResult.stderr.contains("index unavailable") {
            throw OmniAdapterError.unavailable("retrieve docs index unavailable; run `retrieve refresh`")
        }
        if runResult.exitStatus == 0 {
            let lines = runResult.stdout.split(whereSeparator: \.isNewline).map(String.init)
            if let path = lines.first(where: { $0.hasPrefix("path: ") }).map({ String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }), path.hasPrefix("/") {
                entries.append(ReplicaIndexEntry(namespace: "run", id: id, title: lines.first ?? id, path: path))
            }
        }
        return entries
    }

    private func run(_ arguments: [String]) async throws -> OwnerProcessResult {
        let result = try await processRunner.run(OwnerProcessSpec(
            executable: dependencies.uv,
            arguments: ["run", "--no-sync", "--project", dependencies.retrievalRoot.path, "python", dependencies.script.path] + arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "UV_NO_PROGRESS": "1", "PYTHONNOUSERSITE": "1"],
            timeout: .seconds(20)
        ))
        if result.timedOut { throw OmniAdapterError.processTimedOut }
        if result.cancelled { throw OmniAdapterError.unavailable("retrieve was cancelled") }
        guard result.stoppedAndReaped, result.processGroupIsolated else {
            throw OmniAdapterError.unavailable("retrieve supervision acknowledgement incomplete")
        }
        return result
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

private struct BridgeAcknowledgement: Decodable {
    let schemaVersion: Int
    let status: String
    let operation: String?
    let ownerID: String?
    let path: String?
    let idempotentReplay: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status, operation, path, error
        case ownerID = "owner_id"
        case idempotentReplay = "idempotent_replay"
    }
}

struct OwnerEvidence: Sendable {
    let result: ModuleResult
    let ownerID: String?
    let ownerPath: String?
    let acknowledgement: String
    let boundedOutput: String?
    let idempotencyProven: Bool
    let retrySafetyReason: String
    let reconciliationDisposition: String
}

enum OwnerCallResult: Sendable {
    case succeeded(OwnerEvidence)
    case failed(String, OwnerEvidence?)
    case uncertain(String, OwnerEvidence?)
}

protocol ReceiptOwnerBackend: Sendable {
    func perform(operation: OwnerOperation, request: OwnerOperationRequest, failure: OwnerFailurePoint) async -> OwnerCallResult
    func reconcile(operation: OwnerOperation, runID: String) async -> OwnerCallResult
}

public actor ReplicaOwnerBackend: ReceiptOwnerBackend {
    public nonisolated let paths: ReplicaOwnerPaths
    private let processRunner: any OwnerProcessRunning
    private let platform: any PlatformActionPerforming
    private let translation: any TranslationProviding
    private let dependencies: ReplicaOwnerDependencies
    private let registeredResolver: (any RegisteredIndexResolving)?

    public init(
        paths: ReplicaOwnerPaths,
        processRunner: any OwnerProcessRunning,
        platform: any PlatformActionPerforming,
        translation: any TranslationProviding = UnavailableTranslationProvider(),
        dependencies: ReplicaOwnerDependencies = .sourceTreeDevelopment,
        registeredResolver: (any RegisteredIndexResolving)? = nil
    ) {
        self.paths = paths
        self.processRunner = processRunner
        self.platform = platform
        self.translation = translation
        self.dependencies = dependencies
        self.registeredResolver = registeredResolver
    }

    func perform(operation: OwnerOperation, request: OwnerOperationRequest, failure: OwnerFailurePoint) async -> OwnerCallResult {
        if failure == .duringOwnerWork {
            return .uncertain("injected interruption during owner work", nil)
        }
        do {
            let result: OwnerEvidence
            switch operation {
            case .openSearchURL: result = try await openSearch(request)
            case .captureLink: result = try await bridgeCapture(operation: operation, root: paths.linkTriage, request: request)
            case .appendLedger: result = try await appendLedger(request)
            case .appendOfficeQueue: result = try appendOfficeQueue(request)
            case .replaceCurrentStash: result = try replaceStash(request)
            case .captureBaseNote: result = try await bridgeCapture(operation: operation, root: paths.base, request: request)
            case .readRegisteredIndex: result = try await readIndex(request)
            case .openResolvedTarget: result = try await openTarget(request, reveal: false)
            case .revealResolvedTarget: result = try await openTarget(request, reveal: true)
            case .openOmniSettings: result = try await openSettings(section: "general")
            case .openModelSettings: result = try await openSettings(section: "models")
            case .saveSettings: result = try saveSettings(request)
            case .translateLocal: result = try await translate(request)
            }
            if failure == .afterOwnerMutationBeforeAcknowledgement, operation.isMutation {
                return .uncertain("injected loss after owner mutation before acknowledgement", result)
            }
            return .succeeded(result)
        } catch let error as OmniAdapterError {
            if operation.isMutation {
                switch error {
                case .processTimedOut, .malformedAcknowledgement, .unavailable:
                    return .uncertain(error.description, nil)
                default:
                    break
                }
            }
            return .failed(error.description, nil)
        } catch {
            return .uncertain("owner error with ambiguous effect: \(error)", nil)
        }
    }

    func reconcile(operation: OwnerOperation, runID: String) async -> OwnerCallResult {
        do {
            switch operation {
            case .captureLink:
                return try reconcileDeterministicCapture(operation: operation, root: paths.linkTriage, runID: runID)
            case .captureBaseNote:
                return try reconcileDeterministicCapture(operation: operation, root: paths.base, runID: runID)
            case .replaceCurrentStash:
                let url = paths.stashStack
                guard OmniStashReceipt.proves(runID: runID, in: OmniStashStack(url: url))
                else { return .uncertain("stash run marker not found", nil) }
                return .succeeded(OwnerEvidence(result: ModuleResult(summary: "Reconciled stash", artifactReference: url.path, allowedActions: [.copy, .dismiss]), ownerID: runID, ownerPath: url.path, acknowledgement: "stash-run-marker", boundedOutput: nil, idempotencyProven: true, retrySafetyReason: "stash run marker proves same logical effect", reconciliationDisposition: "proved-success"))
            case .appendLedger, .appendOfficeQueue, .saveSettings:
                return .uncertain("owner exposes no honest crash-safe identity lookup", nil)
            default:
                return .failed("read/open operation does not require mutation reconciliation", nil)
            }
        } catch {
            return .uncertain("reconciliation failed: \(error)", nil)
        }
    }

    private func openSearch(_ request: OwnerOperationRequest) async throws -> OwnerEvidence {
        guard !request.payload.isEmpty else { throw OmniAdapterError.unsafeInput("search query is empty") }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: request.payload)]
        guard let url = components?.url, url.scheme == "https", url.host == "www.google.com" else {
            throw OmniAdapterError.unsafeInput("search URL construction failed")
        }
        let ack = try await platform.perform(.openURL(url))
        let summary = ack.identifier.hasPrefix(LivePlatformAdapter.acknowledgementPrefix) ? "Opened Google search in the default browser" : "Prepared search URL"
        return OwnerEvidence(result: ModuleResult(summary: summary, artifactReference: url.absoluteString, allowedActions: [.open, .dismiss]), ownerID: ack.identifier, ownerPath: nil, acknowledgement: ack.detail, boundedOutput: nil, idempotencyProven: false, retrySafetyReason: "platform open is not a mutation retry claim", reconciliationDisposition: "platform-acknowledged")
    }

    private func bridgeCapture(operation: OwnerOperation, root: URL, request: OwnerOperationRequest) async throws -> OwnerEvidence {
        let spec = OwnerProcessSpec(
            executable: dependencies.python,
            arguments: ["-I", "-B", dependencies.bridgeScript.path, operation.rawValue, "--root", root.path, "--replica-owner-root", paths.root.path, "--run-id", request.runID, "--payload", request.payload]
                + (dependencies.ownerResourceRoot.map { ["--owner-resources", $0.path] } ?? []),
            environment: ["PATH": "/usr/bin:/bin", "PYTHONPATH": "", "PYTHONNOUSERSITE": "1", "PYTHONSAFEPATH": "1"],
            timeout: .seconds(10)
        )
        let process = try await processRunner.run(spec)
        if process.timedOut { throw OmniAdapterError.processTimedOut }
        // The cancel may or may not have cut the capture short, whatever it acknowledged.
        if process.cancelled { throw OmniAdapterError.unavailable("capture was cancelled; its outcome is uncertain") }
        guard process.stoppedAndReaped, process.processGroupIsolated else {
            // Something from the run may still be running: not a proved failure.
            throw OmniAdapterError.unavailable("capture process supervision outcome is uncertain")
        }
        guard let data = process.stdout.data(using: .utf8),
              let acknowledgement = try? JSONDecoder().decode(BridgeAcknowledgement.self, from: data),
              acknowledgement.schemaVersion == 1
        else { throw OmniAdapterError.malformedAcknowledgement }
        guard process.exitStatus == 0, acknowledgement.status == "succeeded",
              acknowledgement.operation == operation.rawValue,
              let ownerID = acknowledgement.ownerID,
              let ownerPath = acknowledgement.path
        else {
            throw OmniAdapterError.unavailable(
                "owner did not provide a provable success acknowledgement: \(acknowledgement.error ?? process.stderr)"
            )
        }
        let expectedOwnerID = Self.digest("\(operation.rawValue)|\(request.runID)")
        guard ownerID == expectedOwnerID else {
            throw OmniAdapterError.unavailable("owner acknowledgement does not match this Omni run")
        }
        let suppliedURL = URL(fileURLWithPath: ownerPath).standardizedFileURL
        let resolved = suppliedURL.resolvingSymlinksInPath()
        // Resolve the parent separately: Foundation may leave a missing final
        // file's whole URL unresolved, including its existing symlinked parent.
        let resolvedParent = suppliedURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        // Do not resolve a mutable captures symlink into a newly allowed root.
        let allowedParentPaths: Set<String> = operation == .captureBaseNote
            ? [canonicalRoot.path, canonicalRoot.appendingPathComponent("captures").path]
            : [canonicalRoot.path]
        guard allowedParentPaths.contains(resolvedParent.path),
              resolvedParent.path == resolved.deletingLastPathComponent().path,
              resolved.pathExtension == "md", resolved.lastPathComponent.hasSuffix("_\(ownerID).md")
        else { throw OmniAdapterError.symlinkEscape(ownerPath) }
        let owner = operation == .captureLink ? "Link Collector" : "Base Capture"
        return OwnerEvidence(
            result: ModuleResult(summary: "Captured through \(owner)", artifactReference: ownerPath, allowedActions: operation == .captureLink ? [.open, .dismiss] : [.open, .reveal, .dismiss]),
            ownerID: ownerID,
            ownerPath: ownerPath,
            acknowledgement: "schema=1;status=succeeded;reaped=true",
            boundedOutput: String(process.stdout.prefix(1000)),
            idempotencyProven: true,
            retrySafetyReason: "deterministic owner identity derived from the Omni run ID",
            reconciliationDisposition: acknowledgement.idempotentReplay == true ? "same-run-owner-replay" : "owner-acknowledged"
        )
    }

    private func appendLedger(_ request: OwnerOperationRequest) async throws -> OwnerEvidence {
        guard !request.payload.isEmpty, request.payload.rangeOfCharacter(from: .newlines) == nil else {
            throw OmniAdapterError.unsafeInput("Ledger item must be one non-empty line")
        }
        let capture = paths.ledger.appendingPathComponent("capture.txt")
        let before = (try? Data(contentsOf: capture)) ?? Data()
        let result = try await processRunner.run(OwnerProcessSpec(
            executable: dependencies.python,
            arguments: ["-I", "-B", dependencies.ledgerScript.path, "add", request.payload],
            environment: ["PATH": "/usr/bin:/bin", "LEDGER_DIR": paths.ledger.path],
            timeout: .seconds(10)
        ))
        let after = (try? Data(contentsOf: capture)) ?? Data()
        let expected = Data((request.payload.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
        guard !result.timedOut, !result.cancelled, result.processGroupIsolated, result.stoppedAndReaped else {
            throw OmniAdapterError.unavailable("Ledger process supervision outcome is uncertain")
        }
        guard result.exitStatus == 0,
              after.count == before.count + expected.count,
              after.suffix(expected.count) == expected
        else {
            if after == before { throw OmniAdapterError.processFailed(result.exitStatus, result.stderr) }
            throw OmniAdapterError.unavailable("Ledger outcome is ambiguous after a possible append")
        }
        return OwnerEvidence(result: ModuleResult(summary: "Added to replica Ledger", artifactReference: capture.path, allowedActions: [.dismiss]), ownerID: nil, ownerPath: capture.path, acknowledgement: "exit=0;exact-offset=\(before.count);reaped=true", boundedOutput: String(result.stdout.prefix(1000)), idempotencyProven: false, retrySafetyReason: "Ledger has no owner-issued idempotency key; uncertain outcomes cannot retry", reconciliationDisposition: "exact-post-call-append-proof")
    }

    private func appendOfficeQueue(_ request: OwnerOperationRequest) throws -> OwnerEvidence {
        let item = request.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty, item.rangeOfCharacter(from: .newlines) == nil, !item.hasPrefix("#") else {
            throw OmniAdapterError.unsafeInput("Office reminder must be one non-heading line")
        }
        let queue = paths.office.appendingPathComponent("QUEUE.md")
        let line = "- \(item)\n"
        if !FileManager.default.fileExists(atPath: queue.path) { FileManager.default.createFile(atPath: queue.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: queue)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.synchronize()
        return OwnerEvidence(result: ModuleResult(summary: "Added to replica Office queue", artifactReference: queue.path, allowedActions: [.dismiss]), ownerID: nil, ownerPath: queue.path, acknowledgement: "fsync=true;offset=\(offset);length=\(line.utf8.count)", boundedOutput: nil, idempotencyProven: false, retrySafetyReason: "queue has no owner-issued identity; uncertain outcomes cannot retry", reconciliationDisposition: "owner-write-acknowledged")
    }

    private func replaceStash(_ request: OwnerOperationRequest) throws -> OwnerEvidence {
        guard !request.payload.isEmpty else { throw OmniAdapterError.unsafeInput("stash value is empty") }
        let destination = paths.stashStack
        let outcome: OmniStashPushOutcome
        do {
            outcome = try OmniStashReceipt.push(request.payload, runID: request.runID, source: request.source, into: OmniStashStack(url: destination))
        } catch OmniStashError.empty, OmniStashError.tooLarge {
            throw OmniAdapterError.unsafeInput("stash value is empty or exceeds the bound")
        } catch {
            throw OmniAdapterError.unavailable("stash push outcome is uncertain: \(error)")
        }
        return OwnerEvidence(result: ModuleResult(summary: OmniStashReceipt.summary(for: outcome), artifactReference: destination.path, allowedActions: [.copy, .dismiss]), ownerID: request.runID, ownerPath: destination.path, acknowledgement: "stack-push=true;readback=true;digest=\(outcome.entry.digest);dropped=\(outcome.dropped != nil)", boundedOutput: nil, idempotencyProven: true, retrySafetyReason: "run marker makes a same-run push idempotent", reconciliationDisposition: "run-marker-acknowledged")
    }

    private func readIndex(_ request: OwnerOperationRequest) async throws -> OwnerEvidence {
        let query = request.payload.lowercased()
        // An exact 16-hex ID is resolved through the registered resolver
        // (`retrieve`) in addition to the replica index; anything else stays a
        // replica-index substring search.
        if RegisteredIndexID.isExact(query) {
            guard let registeredResolver else {
                throw OmniAdapterError.unavailable("no registered resolver is bound; exact-ID lookup needs `retrieve`")
            }
            let replica = try indexMatches(query: query)
            let registered = try await registeredResolver.resolve(id: query)
            let matches = replica + registered
            guard !matches.isEmpty else {
                return OwnerEvidence(result: ModuleResult(summary: "No registered target for \(query)", allowedActions: [.dismiss], find: OmniFindResult.exactID(typed: query, entries: [])), ownerID: nil, ownerPath: nil, acknowledgement: "registered-resolver-count=0", boundedOutput: registeredResolver.descriptor, idempotencyProven: false, retrySafetyReason: "read-only operation", reconciliationDisposition: "read-only")
            }
            let summary = matches.map { "\($0.namespace) · \($0.title)" }.joined(separator: "\n")
            let paths = matches.map(\.path).joined(separator: "\n")
            // Resolved targets live outside the replica root, so the result
            // exposes their paths for copying rather than open/reveal actions
            // that the confined artifact resolver would refuse.
            return OwnerEvidence(result: ModuleResult(summary: summary, artifactReference: nil, allowedActions: [.copy, .dismiss], fullText: paths, find: OmniFindResult.exactID(typed: query, entries: matches)), ownerID: matches.count == 1 ? matches[0].namespacedID : nil, ownerPath: nil, acknowledgement: "registered-resolver-count=\(matches.count)", boundedOutput: String(paths.prefix(4000)), idempotencyProven: false, retrySafetyReason: "read-only operation", reconciliationDisposition: "read-only")
        }
        let matches = try indexMatches(query: request.payload)
        let summary = matches.isEmpty ? "No registered matches" : matches.map { "\($0.namespacedID) · \($0.title)" }.joined(separator: "\n")
        return OwnerEvidence(result: ModuleResult(summary: summary, artifactReference: matches.count == 1 ? matches[0].path : nil, allowedActions: matches.count == 1 ? [.open, .dismiss] : [.dismiss]), ownerID: matches.count == 1 ? matches[0].namespacedID : nil, ownerPath: matches.count == 1 ? matches[0].path : nil, acknowledgement: "registered-index-count=\(matches.count)", boundedOutput: String(summary.prefix(4000)), idempotencyProven: false, retrySafetyReason: "read-only operation", reconciliationDisposition: "read-only")
    }

    private func openTarget(_ request: OwnerOperationRequest, reveal: Bool) async throws -> OwnerEvidence {
        let key = request.referenceID ?? request.payload
        let entries = try allIndexEntries().filter { $0.namespacedID == key }
        guard !entries.isEmpty else { throw OmniAdapterError.missingTarget(key) }
        guard entries.count == 1 else { throw OmniAdapterError.ambiguousTarget(key) }
        let entry = entries[0]
        let url = URL(fileURLWithPath: entry.path).standardizedFileURL.resolvingSymlinksInPath()
        let replicaRoot = paths.root.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(replicaRoot + "/") else { throw OmniAdapterError.forbiddenReplicaRoot(url.path) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw OmniAdapterError.staleTarget(key) }
        let acknowledgement = try await platform.perform(reveal ? .revealFile(url) : .openFile(url))
        return OwnerEvidence(result: ModuleResult(summary: reveal ? "Revealed \(key)" : "Opened \(key)", artifactReference: url.path, allowedActions: [reveal ? .reveal : .open, .dismiss]), ownerID: key, ownerPath: url.path, acknowledgement: acknowledgement.identifier, boundedOutput: acknowledgement.detail, idempotencyProven: false, retrySafetyReason: "platform action is not a mutation retry claim", reconciliationDisposition: "platform-acknowledged")
    }

    private func openSettings(section: String) async throws -> OwnerEvidence {
        let acknowledgement = try await platform.perform(.openSettings(section: section))
        return OwnerEvidence(result: ModuleResult(summary: "Opened replica settings: \(section)", allowedActions: [.dismiss]), ownerID: acknowledgement.identifier, ownerPath: nil, acknowledgement: acknowledgement.detail, boundedOutput: nil, idempotencyProven: false, retrySafetyReason: "opening settings is non-mutating", reconciliationDisposition: "platform-acknowledged")
    }

    private func saveSettings(_ request: OwnerOperationRequest) throws -> OwnerEvidence {
        guard request.explicitUserSave else { throw OmniAdapterError.explicitSaveRequired }
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "saved_by_run": request.runID, "value": request.payload], options: [.sortedKeys])
        try data.write(to: paths.settings, options: .atomic)
        return OwnerEvidence(result: ModuleResult(summary: "Saved replica settings", artifactReference: paths.settings.path, allowedActions: [.dismiss]), ownerID: request.runID, ownerPath: paths.settings.path, acknowledgement: "explicit-save=true;atomic=true", boundedOutput: nil, idempotencyProven: true, retrySafetyReason: "same run atomically replaces the one settings document", reconciliationDisposition: "owner-acknowledged")
    }

    private func translate(_ request: OwnerOperationRequest) async throws -> OwnerEvidence {
        guard !request.payload.isEmpty else { throw OmniAdapterError.unsafeInput("translation input is empty") }
        let result = try await translation.translate(request.payload)
        guard result.utf8.count <= 64 * 1024 else { throw OmniAdapterError.unsafeInput("translation output exceeds bound") }
        return OwnerEvidence(result: ModuleResult(summary: result, allowedActions: [.copy, .dismiss]), ownerID: nil, ownerPath: nil, acknowledgement: "injected-local-provider", boundedOutput: String(result.prefix(4000)), idempotencyProven: false, retrySafetyReason: "read/model-only operation", reconciliationDisposition: "provider-acknowledged")
    }

    private func allIndexEntries() throws -> [ReplicaIndexEntry] {
        guard FileManager.default.fileExists(atPath: paths.index.path) else { return [] }
        return try JSONDecoder().decode([ReplicaIndexEntry].self, from: Data(contentsOf: paths.index))
    }

    private func indexMatches(query: String) throws -> [ReplicaIndexEntry] {
        let needle = query.lowercased()
        return try allIndexEntries().filter {
            needle.isEmpty || $0.namespacedID.lowercased().contains(needle) || $0.title.lowercased().contains(needle)
        }.sorted { $0.namespacedID < $1.namespacedID }
    }

    private func reconcileDeterministicCapture(operation: OwnerOperation, root: URL, runID: String) throws -> OwnerCallResult {
        let ownerID = Self.digest("\(operation.rawValue)|\(runID)").prefix(16)
        let searchRoots = operation == .captureBaseNote
            ? [root, root.appendingPathComponent("captures", isDirectory: true)]
            : [root]
        var matches: [URL] = []
        for searchRoot in searchRoots {
            guard FileManager.default.fileExists(atPath: searchRoot.path) else { continue }
            let rootValues = try searchRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                return .uncertain("deterministic owner search root is not a confined directory", nil)
            }
            matches.append(contentsOf: try FileManager.default.contentsOfDirectory(at: searchRoot, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix("_\(ownerID).md") })
        }
        guard matches.count == 1 else {
            return .uncertain(matches.isEmpty ? "deterministic owner ID not found" : "deterministic owner ID is ambiguous", nil)
        }
        let candidate = matches[0]
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              candidate.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        else { return .uncertain("deterministic owner artifact is not a confined regular file", nil) }
        let path = candidate.path
        let owner = operation == .captureLink ? "Link Collector" : "Base Capture"
        return .succeeded(OwnerEvidence(result: ModuleResult(summary: "Reconciled \(owner) capture", artifactReference: path, allowedActions: [.open, .dismiss]), ownerID: String(ownerID), ownerPath: path, acknowledgement: "deterministic-owner-id-lookup", boundedOutput: nil, idempotencyProven: true, retrySafetyReason: "owner identity is derived from run ID", reconciliationDisposition: "proved-success"))
    }

    static func digest(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }
}

public actor ReceiptAwareOwnerOperation {
    public nonisolated let operation: OwnerOperation
    public nonisolated let target: OwnerTargetDescriptor
    private let store: OmniRunStore
    private let backend: any ReceiptOwnerBackend
    private let profile: OmniExecutionProfile
    private let failureController: OwnerFailureController
    private let idempotencyProven: Bool
    private let retrySafetyReason: String

    public init(operation: OwnerOperation, target: OwnerTargetDescriptor, store: OmniRunStore, backend: ReplicaOwnerBackend, failureController: OwnerFailureController, idempotencyProven: Bool, retrySafetyReason: String) {
        self.profile = .replica
        self.operation = operation
        self.target = target
        self.store = store
        self.backend = backend
        self.failureController = failureController
        self.idempotencyProven = idempotencyProven
        self.retrySafetyReason = retrySafetyReason
    }

    init(operation: OwnerOperation, target: OwnerTargetDescriptor, store: OmniRunStore, backend: any ReceiptOwnerBackend, profile: OmniExecutionProfile, idempotencyProven: Bool, retrySafetyReason: String) {
        self.operation = operation
        self.target = target
        self.store = store
        self.backend = backend
        self.profile = profile
        self.failureController = OwnerFailureController()
        self.idempotencyProven = idempotencyProven
        self.retrySafetyReason = retrySafetyReason
    }

    public nonisolated func handle() -> OwnerOperationHandle {
        OwnerOperationHandle(
            operation: operation,
            profile: profile,
            target: target,
            invoke: { [self] request in await invoke(request) },
            reconcile: { [self] runID, plan in await reconcile(runID: runID, plan: plan) }
        )
    }

    private func invoke(_ request: OwnerOperationRequest) async -> ModuleExecutionOutcome {
        let failure = await failureController.point(for: operation)
        if failure == .beforeAttempt { return .failed(summary: "injected pre-effect failure") }
        let effectID = "owner:\(operation.rawValue):\(request.runID)"
        if operation.requiresReceiptBoundary {
            do {
                guard let runID = RunID(rawValue: request.runID) else { return .failed(summary: "invalid run ID") }
                try await store.recordEffectAttempt(
                    runID,
                    effectID: effectID,
                    adapterID: target.ownerID,
                    operationID: operation.rawValue,
                    idempotencyKey: idempotencyProven ? request.runID : nil,
                    idempotencyProven: idempotencyProven,
                    redactedTarget: target.redactedTarget,
                    targetDigest: target.targetDigest,
                    retrySafetyReason: retrySafetyReason
                )
                if failure == .afterAttemptBeforeOwnerCall {
                    return await persist(
                        .uncertain("injected interruption after durable attempt before owner call", nil),
                        runID: runID,
                        effectID: effectID
                    )
                }
                let ownerResult = await backend.perform(operation: operation, request: request, failure: failure)
                if failure == .afterAcknowledgementBeforeOutcome, case .succeeded = ownerResult {
                    let uncertain: OwnerCallResult
                    if case .succeeded(let evidence) = ownerResult {
                        uncertain = .uncertain("owner acknowledged but effect outcome persistence was interrupted", evidence)
                    } else {
                        uncertain = .uncertain("owner outcome persistence was interrupted", nil)
                    }
                    return await persist(uncertain, runID: runID, effectID: effectID)
                }
                return await persist(ownerResult, runID: runID, effectID: effectID)
            } catch {
                return .interrupted(effectCertainty: .uncertain)
            }
        }
        return Self.moduleOutcome(from: await backend.perform(operation: operation, request: request, failure: failure))
    }

    private func persist(_ result: OwnerCallResult, runID: RunID, effectID: String) async -> ModuleExecutionOutcome {
        switch result {
        case .succeeded(let evidence):
            do {
                try await store.recordEffectOutcome(runID, effectID: effectID, outcome: .succeeded, certainty: .certain, ownerID: evidence.ownerID, ownerPath: evidence.ownerPath, ownerAcknowledgement: evidence.acknowledgement, boundedOutput: evidence.boundedOutput, retrySafetyReason: evidence.retrySafetyReason, recoveryDisposition: evidence.reconciliationDisposition)
                return .succeeded(evidence.result)
            } catch { return .interrupted(effectCertainty: .uncertain) }
        case .failed(let summary, let evidence):
            try? await store.recordEffectOutcome(runID, effectID: effectID, outcome: .failed, certainty: .certain, ownerID: evidence?.ownerID, ownerPath: evidence?.ownerPath, ownerAcknowledgement: evidence?.acknowledgement, boundedOutput: evidence?.boundedOutput, retrySafetyReason: evidence?.retrySafetyReason ?? retrySafetyReason, recoveryDisposition: evidence?.reconciliationDisposition ?? "proved-failure")
            return .failed(summary: summary)
        case .uncertain(_, let evidence):
            try? await store.recordEffectOutcome(runID, effectID: effectID, outcome: .unknown, certainty: .uncertain, ownerID: evidence?.ownerID, ownerPath: evidence?.ownerPath, ownerAcknowledgement: evidence?.acknowledgement, boundedOutput: evidence?.boundedOutput, retrySafetyReason: evidence?.retrySafetyReason ?? retrySafetyReason, recoveryDisposition: "reconcile-required")
            return .interrupted(effectCertainty: .uncertain)
        }
    }

    private func reconcile(runID value: String, plan: CommandPlan) async -> ReconciliationDisposition {
        guard operation.isMutation, let runID = RunID(rawValue: value), plan.ownerOperation == operation else { return .unavailable }
        guard let attempt = await store.effectAttemptNeedingReconciliation(for: runID),
              let effectID = attempt.payload.effectID
        else { return .unavailable }
        switch await backend.reconcile(operation: operation, runID: value) {
        case .succeeded(let evidence):
            do {
                try await store.recordEffectOutcome(runID, effectID: effectID, outcome: .succeeded, certainty: .certain, ownerID: evidence.ownerID, ownerPath: evidence.ownerPath, ownerAcknowledgement: evidence.acknowledgement, boundedOutput: evidence.boundedOutput, retrySafetyReason: evidence.retrySafetyReason, recoveryDisposition: evidence.reconciliationDisposition, actor: .recovery)
                return .completed(evidence.result)
            } catch { return .interrupted(effectCertainty: .uncertain) }
        case .failed:
            try? await store.recordEffectOutcome(runID, effectID: effectID, outcome: .failed, certainty: .certain, retrySafetyReason: retrySafetyReason, recoveryDisposition: "proved-failure", actor: .recovery)
            return .interrupted(effectCertainty: .certain)
        case .uncertain:
            if await store.unmatchedEffectAttempts(for: runID).contains(where: { $0.payload.effectID == effectID }) {
                try? await store.recordEffectOutcome(runID, effectID: effectID, outcome: .unknown, certainty: .uncertain, retrySafetyReason: retrySafetyReason, recoveryDisposition: "remains-uncertain", actor: .recovery)
            }
            return .interrupted(effectCertainty: .uncertain)
        }
    }

    private static func moduleOutcome(from result: OwnerCallResult) -> ModuleExecutionOutcome {
        switch result {
        case .succeeded(let evidence): .succeeded(evidence.result)
        case .failed(let summary, _): .failed(summary: summary)
        case .uncertain: .interrupted(effectCertainty: .uncertain)
        }
    }
}

public struct OmniReplicaAdapterGraph: Sendable {
    public let paths: ReplicaOwnerPaths
    public let environment: CapabilityEnvironment
    public let failureController: OwnerFailureController
    public let platform: any RecordingPlatformActionPerforming
    /// Status label of the bound exact-ID resolver, `nil` when none is bound.
    public let registeredResolver: String?

    public static func make(
        developmentRoot: OmniDevelopmentRoot,
        store: OmniRunStore,
        translation: any TranslationProviding = UnavailableTranslationProvider(),
        dependencies: ReplicaOwnerDependencies? = nil,
        platform: (any RecordingPlatformActionPerforming)? = nil,
        retrieveResolver: RetrieveResolverDependencies? = nil
    ) throws -> OmniReplicaAdapterGraph {
        let dependencies = dependencies ?? .sourceTreeDevelopment
        try dependencies.validate()
        let paths = try ReplicaOwnerPaths(developmentRoot: developmentRoot)
        let platform: any RecordingPlatformActionPerforming = platform ?? RecordingPlatformAdapter()
        let failureController = OwnerFailureController()
        var executables: Set<URL> = [dependencies.python]
        if let retrieveResolver { executables.insert(retrieveResolver.uv) }
        let runner = BoundedOwnerProcessRunner(allowedExecutables: executables)
        let resolver = retrieveResolver.map { RetrieveIndexResolver(dependencies: $0, processRunner: runner) }
        let backend = ReplicaOwnerBackend(paths: paths, processRunner: runner, platform: platform, translation: translation, dependencies: dependencies, registeredResolver: resolver)
        let policies: [(OwnerOperation, String, Bool, String)] = [
            (.openSearchURL, "web-search", false, "non-mutating platform action"),
            (.captureLink, "link-collector", true, "deterministic owner identity"),
            (.appendLedger, "ledger", false, "no owner idempotency key; uncertain means no retry"),
            (.appendOfficeQueue, "office-queue", false, "no owner idempotency key; uncertain means no retry"),
            (.replaceCurrentStash, "omni-stash", true, "five-deep stack with run marker"),
            (.captureBaseNote, "base-capture", true, "deterministic owner identity"),
            (.readRegisteredIndex, "registered-index", false, "read-only"),
            (.openResolvedTarget, "platform-open", false, "non-mutating platform action"),
            (.revealResolvedTarget, "platform-reveal", false, "non-mutating platform action"),
            (.openOmniSettings, "omni-settings", false, "opening settings is non-mutating"),
            (.openModelSettings, "model-settings", false, "opening settings is non-mutating"),
            (.saveSettings, "omni-settings-save", true, "one atomic settings document"),
            (.translateLocal, "local-translation", false, "injected local provider only")
        ]
        let handles = policies.map { operation, ownerID, idempotent, reason in
            let target = OwnerTargetDescriptor(ownerID: ownerID, operation: operation, redactedTarget: "replica:\(ownerID)", targetDigest: ReplicaOwnerBackend.digest("\(paths.root.path)|\(operation.rawValue)"))
            return ReceiptAwareOwnerOperation(operation: operation, target: target, store: store, backend: backend, failureController: failureController, idempotencyProven: idempotent, retrySafetyReason: reason).handle()
        }
        let environment = try CapabilityEnvironment(profile: .replica, installedPolicy: Set(OwnerOperation.allCases), handles: handles)
        return OmniReplicaAdapterGraph(paths: paths, environment: environment, failureController: failureController, platform: platform, registeredResolver: resolver?.descriptor)
    }
}

public enum InstalledOwnerAdapterKind: String, Sendable, Equatable {
    case platformAction
    case linkCollectorAPI
    case ledgerExecutable
    case officeQueue
    case omniStash
    case baseCaptureAPI
    case registeredIndex
    case settingsStore
    case localTranslationHelper
}

public struct InstalledOwnerAdapterBinding: Sendable, Equatable {
    public let operation: OwnerOperation
    public let ownerID: String
    public let kind: InstalledOwnerAdapterKind
    public let canonicalTarget: String

    public init(operation: OwnerOperation, ownerID: String, kind: InstalledOwnerAdapterKind, canonicalTarget: String) {
        self.operation = operation
        self.ownerID = ownerID
        self.kind = kind
        self.canonicalTarget = canonicalTarget
    }
}

/// Installed-live owner bindings. The zero-argument initializer remains sealed;
/// the installed host explicitly supplies its root, store, and platform to
/// activate real typed operations through the separate installed backend.
public struct OmniInstalledAdapterGraph: Sendable {
    public let profile: OmniExecutionProfile = .installedLive
    public let paths: InstalledOwnerPaths
    public let bindings: [InstalledOwnerAdapterBinding]
    public let environment: CapabilityEnvironment
    public let registeredResolver: String?

    public init() throws {
        paths = try InstalledOwnerPaths(installedRoot: OmniLayout.installedRoot)
        registeredResolver = nil
        bindings = [
            .init(operation: .openSearchURL, ownerID: "system-default-opener", kind: .platformAction, canonicalTarget: "https://www.google.com/search"),
            .init(operation: .captureLink, ownerID: "link-collector", kind: .linkCollectorAPI, canonicalTarget: "~/Base/triage"),
            .init(operation: .appendLedger, ownerID: "ledger", kind: .ledgerExecutable, canonicalTarget: "~/.ledger/capture.txt"),
            .init(operation: .appendOfficeQueue, ownerID: "office-queue", kind: .officeQueue, canonicalTarget: "~/Tooling/office/QUEUE.md"),
            .init(operation: .replaceCurrentStash, ownerID: "omni-stash", kind: .omniStash, canonicalTarget: "~/Library/Application Support/DanielTooling/omni-intent/current-stash.json"),
            .init(operation: .captureBaseNote, ownerID: "base-capture", kind: .baseCaptureAPI, canonicalTarget: "~/Base/captures"),
            .init(operation: .readRegisteredIndex, ownerID: "registered-index", kind: .registeredIndex, canonicalTarget: "registered resolver sources"),
            .init(operation: .openResolvedTarget, ownerID: "system-default-opener", kind: .platformAction, canonicalTarget: "resolved namespaced target"),
            .init(operation: .revealResolvedTarget, ownerID: "finder-reveal", kind: .platformAction, canonicalTarget: "resolved namespaced target"),
            .init(operation: .openOmniSettings, ownerID: "omni-settings", kind: .settingsStore, canonicalTarget: "Omni settings surface"),
            .init(operation: .openModelSettings, ownerID: "model-settings", kind: .settingsStore, canonicalTarget: "model settings surface"),
            .init(operation: .saveSettings, ownerID: "omni-settings-save", kind: .settingsStore, canonicalTarget: "explicit settings save"),
            .init(operation: .translateLocal, ownerID: "local-translation", kind: .localTranslationHelper, canonicalTarget: "declared local helper"),
        ]
        let handles = bindings.map { binding in
            OwnerOperationHandle(
                operation: binding.operation,
                profile: .installedLive,
                target: OwnerTargetDescriptor(
                    ownerID: binding.ownerID,
                    operation: binding.operation,
                    redactedTarget: "installed:\(binding.ownerID)",
                    targetDigest: ReplicaOwnerBackend.digest("\(binding.kind.rawValue)|\(binding.canonicalTarget)")
                ),
                invoke: { _ in
                    .failed(summary: "installed-live adapter activation remains sealed in Phase 3")
                }
            )
        }
        environment = try CapabilityEnvironment(
            profile: .installedLive,
            installedPolicy: Set(bindings.map(\.operation)),
            handles: handles
        )
    }
}
