import Foundation

/// A bounded child process for the direct actions' helpers: Equalize's
/// normaliser, the path, URL and root extractors, gather and the Finder
/// query.
/// - Stdin goes in; stdout and stderr come out.
/// - The input is written on its own queue with SIGPIPE off for that pipe.
/// - The bound starts before the write.
/// - The child leads its own process group, so a timeout or a cancelled task
///   signals the whole tree: zsh and the `find` or `mdfind` under it.
/// - The blocking waits run on a GCD queue, never on a Swift concurrency
///   thread.
public enum HelperProcess {
    public struct Result: Sendable, Equatable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    /// The resident host's minimal environment; callers add `HOME` where a
    /// helper resolves paths under it.
    public static let baseEnvironment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONIOENCODING": "utf-8",
        "LC_ALL": "en_US.UTF-8",
    ]

    /// Cancelling the calling task ends the helper's process group at once.
    public static func run(_ executable: URL, arguments: [String] = [], stdin: String,
                           environment: [String: String], timeout: TimeInterval) async -> Result? {
        let handle = Handle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runBlocking(executable, arguments: arguments, stdin: stdin,
                                                               environment: environment, timeout: timeout, handle: handle))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Nil when the helper cannot start, outlives its bound, is cancelled,
    /// dies on a signal, or writes output that is not UTF-8.
    nonisolated static func runBlocking(_ executable: URL, arguments: [String], stdin: String,
                                        environment: [String: String], timeout: TimeInterval,
                                        handle: Handle = Handle()) -> Result? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            handle.exited()
            finished.signal()
        }
        // The deadline starts before any write: a helper that neither reads
        // nor exits cannot hold the lane.
        let deadline = DispatchTime.now() + timeout
        guard handle.launch(process) else { return nil }
        let collected = OutputBox(), diagnostics = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.data = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            diagnostics.data = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        // The throwing API on its own queue, and no SIGPIPE on this pipe: a
        // helper that exits unread is an EPIPE error here, never an uncaught
        // exception or a signal in the resident host.
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global().async {
            try? writer.write(contentsOf: Data(stdin.utf8))
            try? writer.close()
        }
        guard finished.wait(timeout: deadline) == .success else {
            Handle.signalTree(process.processIdentifier, SIGTERM)
            if finished.wait(timeout: .now() + 0.5) != .success { Handle.signalTree(process.processIdentifier, SIGKILL) }
            return nil
        }
        // A grandchild still holding a pipe: give up rather than read a box a
        // reader thread may still be writing.
        guard group.wait(timeout: .now() + 1) == .success,
              !handle.wasCancelled,
              process.terminationReason == .exit,
              let stdout = String(data: collected.data ?? Data(), encoding: .utf8)
        else { return nil }
        let stderr = String(data: diagnostics.data ?? Data(), encoding: .utf8) ?? ""
        return Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// The running helper, shared with the cancellation handler.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var cancelled = false

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        /// Starts the process unless the task was already cancelled.
        func launch(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            do { try process.run() } catch { return false }
            pid = process.processIdentifier
            return true
        }

        /// The child is reaped: never signal its pid again.
        func exited() {
            lock.lock()
            pid = 0
            lock.unlock()
        }

        /// SIGTERM to the group now, SIGKILL to whatever of it is left after
        /// the same 0.5 s grace the bound gives.
        func cancel() {
            lock.lock()
            cancelled = true
            let running = pid
            if running > 0 { Self.signalTree(running, SIGTERM) }
            lock.unlock()
            guard running > 0 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if kill(-running, 0) == 0 { kill(-running, SIGKILL) }
            }
        }

        /// `Process` makes the child its own group leader; the group reaches
        /// whatever the helper spawned.
        static func signalTree(_ pid: pid_t, _ signal: Int32) {
            guard pid > 0 else { return }
            if getpgid(pid) == pid { kill(-pid, signal) } else { kill(pid, signal) }
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    var data: Data?
}
