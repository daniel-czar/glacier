import Darwin
import Foundation
import OmniCore

// MARK: - Allowlisted child environment

public enum CLIChildEnvironmentError: Error, Sendable, Equatable, CustomStringConvertible {
    case forbiddenVariable(String)
    case missingExecutable(String)

    public var description: String {
        switch self {
        case .forbiddenVariable(let name): "child environment must not carry \(name)"
        case .missingExecutable(let name): "CLI executable not found: \(name)"
        }
    }
}

/// Builds the exact environment handed to an owned CLI process. Inheritance is
/// an allowlist; nothing that looks like a key, token, secret or vendor
/// endpoint/backends selector can pass, and the caller's additions are checked
/// by the same rule. `HOME` is supplied explicitly by the driver, and `USER`
/// comes from the current OS account rather than the parent environment.
public enum CLIChildEnvironment {
    public static let inheritedKeys: Set<String> = ["TERM", "LANG", "LC_ALL", "TMPDIR"]
    public static let forbiddenPrefixes: [String] = ["OPENAI_", "ANTHROPIC_", "CLAUDE_CODE_USE_", "AWS_", "GOOGLE_", "AZURE_", "CEREBRAS_"]
    public static let forbiddenSubstrings: [String] = ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "BASE_URL", "PROXY"]
    public static let forbiddenExact: Set<String> = ["ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH"]

    public static func build(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        home: String,
        executableDirectory: String,
        additions: [String: String]
    ) throws -> [String: String] {
        var environment: [String: String] = [:]
        for key in inheritedKeys {
            if let value = parent[key], !value.isEmpty { environment[key] = value }
        }
        for (key, value) in additions { environment[key] = value }
        environment["PATH"] = ([executableDirectory] + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        environment["HOME"] = home
        environment["USER"] = NSUserName()
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        try verify(environment)
        return environment
    }

    /// Bidirectional check: anything forbidden anywhere in the map fails.
    public static func verify(_ environment: [String: String]) throws {
        for key in environment.keys {
            let upper = key.uppercased()
            if forbiddenExact.contains(upper) { throw CLIChildEnvironmentError.forbiddenVariable(key) }
            if forbiddenPrefixes.contains(where: { upper.hasPrefix($0) }) { throw CLIChildEnvironmentError.forbiddenVariable(key) }
            if forbiddenSubstrings.contains(where: { upper.contains($0) }) { throw CLIChildEnvironmentError.forbiddenVariable(key) }
        }
    }

    public static func isAllowlisted(_ environment: [String: String]) -> Bool {
        (try? verify(environment)) != nil
    }
}

public enum CLIExecutableResolver {
    /// Resolves a configured executable without invoking a shell. Relative
    /// names search the host process PATH and fixed user binary directories.
    /// LaunchAgents have a deliberately small PATH, so installed CLIs need
    /// these locations without changing the host's environment.
    public static func resolve(
        _ configured: String,
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        userLocalBin: URL = OmniLayout.homeDirectory.appendingPathComponent(".local/bin")
    ) -> URL? {
        let expanded = OmniLayout.expandingCurrentUserTilde(configured)
        if expanded.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        guard !configured.contains("/") else { return nil }
        let directories = (searchPath ?? "").split(separator: ":").map(String.init) + [
            userLocalBin.path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(configured)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

// MARK: - Owned directories

public enum CLIOwnedDirectoryError: Error, Sendable, Equatable, CustomStringConvertible {
    case notADirectory(String)
    case symlinkEscape(String)
    case hostileContent(String)

    public var description: String {
        switch self {
        case .notADirectory(let path): "owned path is not a directory: \(path)"
        case .symlinkEscape(let path): "owned path traverses a symlink: \(path)"
        case .hostileContent(let what): "owned directory contains ambient configuration: \(what)"
        }
    }
}

public enum CLIOwnedDirectory {
    /// Creates (0700) or verifies an owned directory that must not be a symlink.
    public static func ensure(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CLIOwnedDirectoryError.notADirectory(url.path) }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw CLIOwnedDirectoryError.symlinkEscape(url.path)
        }
    }

    /// A neutral request workspace contains nothing a CLI could interpret as
    /// project instructions, configuration, hooks, skills or a repository.
    public static let ambientProjectEntries: Set<String> = [
        "AGENTS.md", "CLAUDE.md", ".codex", ".claude", ".mcp.json", ".git", "skills", "hooks", "hooks.json", "plugins", "rules", ".agents", "settings.local.json", "commands", "agents",
    ]

    public static func verifyNeutralWorkspace(_ url: URL) throws {
        try ensure(url)
        let entries = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let hostile = entries.filter { ambientProjectEntries.contains($0) }
        guard hostile.isEmpty else { throw CLIOwnedDirectoryError.hostileContent(hostile.sorted().joined(separator: ",") + " in workspace") }
    }
}

// MARK: - Owned process

public enum CLIProcessError: Error, Sendable, Equatable, CustomStringConvertible {
    case launchFailed(String)
    case streamClosed
    case deadlineExceeded
    case outputTooLarge

    public var description: String {
        switch self {
        case .launchFailed(let reason): "CLI launch failed: \(reason)"
        case .streamClosed: "CLI stream closed"
        case .deadlineExceeded: "CLI deadline exceeded"
        case .outputTooLarge: "CLI output exceeds bound"
        }
    }
}

/// Bounded, deadline-aware line queue fed by a pump task reading a pipe.
actor CLILineQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Data?, any Error>
    }

    private var lines: [Data] = []
    private var finished = false
    private var waiters: [Waiter] = []
    private let maximumBufferedBytes: Int
    private var bufferedBytes = 0

    init(maximumBufferedBytes: Int = 4_000_000) {
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    private var overflowed = false

    func push(_ line: Data) {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: line)
            return
        }
        bufferedBytes += line.count
        if bufferedBytes > maximumBufferedBytes {
            // Unread output exceeded the bound: fail every reader, now and later.
            overflowed = true
            finished = true
            lines.removeAll()
            let all = waiters
            waiters.removeAll()
            for waiter in all { waiter.continuation.resume(throwing: CLIProcessError.outputTooLarge) }
            return
        }
        lines.append(line)
    }

    func finish() {
        finished = true
        let all = waiters
        waiters.removeAll()
        for waiter in all { waiter.continuation.resume(returning: nil) }
    }

    /// Returns the next line, `nil` at end of stream, or throws on deadline,
    /// output overflow or task cancellation.
    func next(until deadline: ContinuousClock.Instant) async throws -> Data? {
        if overflowed { throw CLIProcessError.outputTooLarge }
        if !lines.isEmpty {
            let line = lines.removeFirst()
            bufferedBytes -= line.count
            return line
        }
        if finished { return nil }
        try Task.checkCancellation()
        let id = UUID()
        let timeout = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.expire(id, error: CLIProcessError.deadlineExceeded)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { [weak self] in await self?.expire(id, error: CancellationError()) }
        }
    }

    private func expire(_ id: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: error)
    }
}

/// Thread-safe bounded capture of a child's stderr for safe diagnostics. Only
/// a bounded tail is retained and it is never written into receipts verbatim.
final class CLIBoundedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int

    init(limit: Int = 16_384) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        if buffer.count > limit { buffer = buffer.suffix(limit) }
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Process abstraction so fixture tests can script a CLI's stdout/exit without
/// launching anything. The real implementation is `CLIOwnedProcess`.
public protocol CLIProcessHandle: Sendable {
    func start() throws
    func write(_ data: Data) throws
    func closeStdin()
    func nextLine(until deadline: ContinuousClock.Instant) async throws -> Data?
    func terminate(graceful: Duration, interruptFirst: Bool) async
    func waitForExit(_ limit: Duration) async -> Bool
    var terminationStatus: Int32? { get }
    func stderrTail() -> String
}

/// One owned child process with allowlisted environment, explicit working
/// directory, line-oriented stdout and bounded stderr. Termination escalates
/// SIGINT -> SIGTERM -> SIGKILL and reaps the process.
public final class CLIOwnedProcess: CLIProcessHandle, @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    let stdout = CLILineQueue()
    private let stderrCapture = CLIBoundedCapture()
    private var pumpTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var stdinClosed = false
    private var terminated = false
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) throws {
        try CLIChildEnvironment.verify(environment)
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }
    public var terminationStatus: Int32? { process.isRunning ? nil : process.terminationStatus }
    public func stderrTail() -> String { stderrCapture.text() }

    public func start() throws {
        do { try process.run() } catch { throw CLIProcessError.launchFailed(String(describing: error)) }
        let stderrHandle = stderrPipe.fileHandleForReading
        let capture = stderrCapture
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { capture.append(data) }
        }
        let queue = stdout
        let handle = stdoutPipe.fileHandleForReading
        // Split on 0x0A bytes only. `AsyncLineSequence` would also break on
        // U+2028/U+2029/NEL, which JSON encoders may emit raw inside strings.
        pumpTask = Task.detached {
            var pending = Data()
            do {
                for try await byte in handle.bytes {
                    if byte == 0x0A {
                        if pending.last == 0x0D { pending.removeLast() }
                        await queue.push(pending)
                        pending = Data()
                    } else {
                        pending.append(byte)
                        if pending.count > 8_000_000 {
                            await queue.push(pending)
                            pending = Data()
                        }
                    }
                }
            } catch {}
            if !pending.isEmpty { await queue.push(pending) }
            await queue.finish()
        }
    }

    public func writeLine(_ data: Data) throws {
        stateLock.lock()
        let closed = stdinClosed
        stateLock.unlock()
        guard !closed, process.isRunning else { throw CLIProcessError.streamClosed }
        var payload = data
        payload.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
    }

    public func write(_ data: Data) throws {
        stateLock.lock()
        let closed = stdinClosed
        stateLock.unlock()
        guard !closed, process.isRunning else { throw CLIProcessError.streamClosed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func closeStdin() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdinPipe.fileHandleForWriting.close()
    }

    public func nextLine(until deadline: ContinuousClock.Instant) async throws -> Data? {
        try await stdout.next(until: deadline)
    }

    private func markTerminated() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let already = terminated
        terminated = true
        return already
    }

    /// Ends the process and drains streams. Safe to call repeatedly.
    public func terminate(graceful: Duration = .milliseconds(800), interruptFirst: Bool = false) async {
        let already = markTerminated()
        closeStdin()
        if !already, process.isRunning {
            if interruptFirst {
                kill(process.processIdentifier, SIGINT)
                if await waitForExit(graceful) { await finishStreams(); return }
            }
            process.terminate()
            if await waitForExit(graceful) { await finishStreams(); return }
            kill(process.processIdentifier, SIGKILL)
            _ = await waitForExit(.seconds(2))
        }
        await finishStreams()
    }

    private func finishStreams() async {
        pumpTask?.cancel()
        try? stdoutPipe.fileHandleForReading.close()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stderrPipe.fileHandleForReading.close()
        await stdout.finish()
    }

    /// Waits for natural exit; returns false at the deadline. The wait ignores
    /// the caller's cancellation so teardown never hot-polls.
    public func waitForExit(_ limit: Duration) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: limit)
        while process.isRunning {
            if ContinuousClock().now >= deadline { return false }
            await Self.uncancellablePause(milliseconds: 20)
        }
        return true
    }

    static func uncancellablePause(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}
