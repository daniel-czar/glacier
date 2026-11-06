import Darwin
import Foundation

public struct RunLivenessLease: Hashable, Sendable {
    fileprivate let id: UUID
}

public final class RunLivenessRegistry {
    private var activeLeases: Set<RunLivenessLease> = []

    public init() {}

    @MainActor public var suppressesIdleExit: Bool { !activeLeases.isEmpty }
    @MainActor public var activeLeaseCount: Int { activeLeases.count }

    @discardableResult
    @MainActor public func acquire() -> RunLivenessLease {
        let lease = RunLivenessLease(id: UUID())
        activeLeases.insert(lease)
        return lease
    }

    @MainActor public func release(_ lease: RunLivenessLease) {
        activeLeases.remove(lease)
    }
}

public enum ProcessGroupCancellationAcknowledgement: Equatable, Sendable {
    case stoppedAndReaped
    case uncertain(String)
}

public protocol ProcessGroupCancellationDriving: Sendable {
    func send(signal: Int32, toProcessGroup processGroupID: pid_t) -> Bool
    func waitForStopAndReap(timeout: TimeInterval) -> Bool
}

public struct ProcessGroupSupervisor: Sendable {
    private let processGroupID: pid_t
    private let driver: any ProcessGroupCancellationDriving
    private let terminateGrace: TimeInterval
    private let killGrace: TimeInterval

    public init(
        processGroupID: pid_t,
        driver: any ProcessGroupCancellationDriving,
        terminateGrace: TimeInterval = 1.0,
        killGrace: TimeInterval = 1.0
    ) {
        self.processGroupID = processGroupID
        self.driver = driver
        self.terminateGrace = terminateGrace
        self.killGrace = killGrace
    }

    public init(process: Process, processGroupID: pid_t, terminateGrace: TimeInterval = 1.0, killGrace: TimeInterval = 1.0) {
        self.init(
            processGroupID: processGroupID,
            driver: FoundationProcessGroupCancellationDriver(process: process, processGroupID: processGroupID),
            terminateGrace: terminateGrace,
            killGrace: killGrace
        )
    }

    public func cancelAndAcknowledge() -> ProcessGroupCancellationAcknowledgement {
        if driver.waitForStopAndReap(timeout: 0) {
            return .stoppedAndReaped
        }
        guard driver.send(signal: SIGTERM, toProcessGroup: processGroupID) else {
            return .uncertain("could-not-send-SIGTERM")
        }
        if driver.waitForStopAndReap(timeout: terminateGrace) {
            return .stoppedAndReaped
        }
        guard driver.send(signal: SIGKILL, toProcessGroup: processGroupID) else {
            return .uncertain("could-not-send-SIGKILL")
        }
        if driver.waitForStopAndReap(timeout: killGrace) {
            return .stoppedAndReaped
        }
        return .uncertain("process-group-did-not-stop-and-reap")
    }
}

func processGroupIsAbsent(_ processGroupID: pid_t) -> Bool {
    guard processGroupID > 0 else { return false }
    return Darwin.kill(-processGroupID, 0) == -1 && errno == ESRCH
}

private final class FoundationProcessGroupCancellationDriver: ProcessGroupCancellationDriving, @unchecked Sendable {
    private let process: Process
    private let processGroupID: pid_t

    init(process: Process, processGroupID: pid_t) {
        self.process = process
        self.processGroupID = processGroupID
    }

    func send(signal: Int32, toProcessGroup processGroupID: pid_t) -> Bool {
        guard processGroupID > 0 else { return false }
        return Darwin.kill(-processGroupID, signal) == 0 || errno == ESRCH
    }

    func waitForStopAndReap(timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while true {
            if !process.isRunning {
                process.waitUntilExit()
                // The leader can exit before a child that ignores SIGTERM.
                if processGroupIsAbsent(processGroupID) { return true }
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
        }
    }
}
