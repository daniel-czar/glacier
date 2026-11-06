import Foundation

/// Cooperative pacing for resident full walks. Incremental hot-root patches
/// remain unpaced. This limits consecutive work, not measured process CPU.
public struct EverywhereWalkPacing: Sendable, Equatable {
    public let workInterval: TimeInterval
    public let restInterval: TimeInterval
    public let checkEvery: Int

    public static let background = EverywhereWalkPacing(workInterval: 0.01, restInterval: 0.04)

    public init(workInterval: TimeInterval, restInterval: TimeInterval, checkEvery: Int = 128) {
        precondition(workInterval > 0 && workInterval.isFinite)
        precondition(restInterval >= 0 && restInterval.isFinite)
        precondition(checkEvery > 0)
        self.workInterval = workInterval
        self.restInterval = restInterval
        self.checkEvery = checkEvery
    }
}

/// Confined to one synchronous crawler invocation, with no service lock held.
/// Injectable time and sleep keep budget/cancellation tests deterministic.
final class EverywhereWalkPacer {
    private let policy: EverywhereWalkPacing
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let cancelled: () -> Bool
    private var activeSince: TimeInterval
    private var steps = 0

    init(policy: EverywhereWalkPacing,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         cancelled: @escaping () -> Bool = { Task.isCancelled }) {
        self.policy = policy
        self.now = now
        self.sleep = sleep
        self.cancelled = cancelled
        activeSince = now()
    }

    /// True asks the caller to stop and close its open directory handles.
    func checkpoint(force: Bool = false) -> Bool {
        steps += 1
        guard force || steps >= policy.checkEvery else { return false }
        steps = 0
        if cancelled() { return true }
        if now() - activeSince >= policy.workInterval {
            sleep(policy.restInterval)
            activeSince = now()
        }
        return cancelled()
    }
}
