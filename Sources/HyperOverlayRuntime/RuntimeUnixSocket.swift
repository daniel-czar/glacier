import Darwin
import Foundation
import HyperOverlayCore

/// What an accept loop does after one `accept` attempt.
public enum RuntimeAcceptOutcome: Equatable, Sendable {
    case connection(Int32)
    /// This connection could not be set up (errno); keep accepting.
    case dropped(Int32)
    /// Out of descriptors or kernel memory; pause, then keep accepting.
    case temporarilyExhausted
    /// The listener is closed or failed with this errno; stop accepting.
    case listenerFailed(Int32)
}

/// Counts dropped connections for stderr without flooding it: the first is
/// reported at once; later ones are counted and reported with the next drop
/// at least one interval after the last report. A host that drops every
/// connection then shows why it does not answer.
public struct DroppedConnectionReport: Sendable {
    private let interval: TimeInterval
    private var lastReport: TimeInterval?
    private var unreported = 0

    public init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    /// Records one drop with `errno` at `now` (monotonic seconds) and returns
    /// how many drops to report now, or nil. EINTR is a retry and ECONNABORTED
    /// is shutdown closing the listener under accept; neither is a client the
    /// host failed to set up, so neither counts.
    public mutating func record(errno code: Int32, at now: TimeInterval) -> Int? {
        guard code != EINTR, code != ECONNABORTED else { return nil }
        unreported += 1
        if let lastReport, now - lastReport < interval { return nil }
        lastReport = now
        defer { unreported = 0 }
        return unreported
    }
}

/// Runtime-facing socket surface. The transport implementation remains in Core
/// for protocol compatibility while every executable consumes this boundary.
public enum RuntimeUnixSocket {
    public static func validatePath(_ path: String) throws {
        try UnixSocket.validatePath(path)
    }

    public static func connect(path: String, timeoutSeconds: Int = 2) throws -> Int32 {
        try UnixSocket.connect(path: path, timeoutSeconds: timeoutSeconds)
    }

    public static func bindListener(path: String, backlog: Int32 = 16) throws -> Int32 {
        try UnixSocket.bindListener(path: path, backlog: backlog)
    }

    public static func accept(listener: Int32, timeoutSeconds: Int = 2) throws -> Int32 {
        try UnixSocket.accept(listener: listener, timeoutSeconds: timeoutSeconds)
    }

    /// One accept for a loop that must outlive any single client. A client that
    /// hangs up before it is accepted makes the read timeout fail with EINVAL;
    /// that connection is dropped (and closed), not the listener.
    public static func acceptNext(listener: Int32, timeoutSeconds: Int = 2) -> RuntimeAcceptOutcome {
        do {
            return .connection(try UnixSocket.accept(listener: listener, timeoutSeconds: timeoutSeconds))
        } catch UnixSocketError.acceptFailed(let code) where code == EINTR || code == ECONNABORTED {
            return .dropped(code)
        } catch UnixSocketError.acceptFailed(let code) where [EMFILE, ENFILE, ENOMEM, ENOBUFS].contains(code) {
            return .temporarilyExhausted
        } catch UnixSocketError.acceptFailed(let code) {
            return .listenerFailed(code)
        } catch UnixSocketError.socketFailed(let code) {
            return .dropped(code)
        } catch {
            return .dropped(0)
        }
    }

    public static func writeAll(fd: Int32, data: Data) throws {
        try UnixSocket.writeAll(fd: fd, data: data)
    }

    public static func readLine(fd: Int32, maxBytes: Int = 1_048_576) throws -> Data {
        try UnixSocket.readLine(fd: fd, maxBytes: maxBytes)
    }
}
