import Foundation
import OmniCore

/// One run's activity as the status surfaces see it (interaction model §3, C10, C14).
public enum RunActivityPhase: Equatable, Sendable {
    /// Queued, running, proposing, confirmed, or generating an in-run follow-up.
    case active
    /// A proposal is ready and waits for the person's choice.
    case decision
    /// Finished and nothing is outstanding.
    case idle
    /// Failed or interrupted, or the last follow-up failed.
    case failed
    case cancelled
}

public enum RunActivityOutcome: Equatable, Sendable {
    case done
    case failed
    case cancelled
    case proposalReady
}

public enum RunActivityTransition: Equatable, Sendable {
    case started(runID: String)
    case finished(runID: String, outcome: RunActivityOutcome)
}

/// Turns successive history snapshots into lifecycle transitions. The host
/// polls the durable store; this type is the one place that decides a run
/// started or ended, so the menu bar, the launcher token and notifications
/// cannot disagree (one state, several views).
public struct RunActivityTracker: Sendable {
    public private(set) var phases: [String: RunActivityPhase] = [:]
    public private(set) var seeded = false
    /// The most recently submitted root run in the last snapshot (C15).
    public private(set) var latestSubmittedRunID: String?

    public init() {}

    public static func phase(of model: ResultViewModel) -> RunActivityPhase {
        if model.followUpKind == .pending { return .active }
        switch model.state {
        case .queued, .running, .proposing, .confirmed: return .active
        case .proposalReady: return .decision
        case .succeeded:
            switch model.followUpKind {
            case .failed: return .failed
            case .cancelled: return .cancelled
            case .pending, .none: return .idle
            }
        case .failed, .interrupted: return .failed
        case .cancelled: return .cancelled
        }
    }

    static func outcome(for phase: RunActivityPhase) -> RunActivityOutcome? {
        switch phase {
        case .active: nil
        case .idle: .done
        case .failed: .failed
        case .cancelled: .cancelled
        case .decision: .proposalReady
        }
    }

    /// The first snapshot seeds history without reporting anything: runs that
    /// finished before this host started are not arrivals.
    public mutating func observe(_ models: [ResultViewModel]) -> [RunActivityTransition] {
        latestSubmittedRunID = models.max { lhs, rhs in
            (lhs.submittedAt ?? .distantPast, lhs.runID) < (rhs.submittedAt ?? .distantPast, rhs.runID)
        }?.runID
        var transitions: [RunActivityTransition] = []
        var next = phases
        for model in models {
            let phase = Self.phase(of: model)
            let previous = phases[model.runID]
            next[model.runID] = phase
            guard seeded, previous != phase else { continue }
            if previous == nil {
                // Appeared between two polls: report the start and, when it
                // already ended, the end in the same tick.
                transitions.append(.started(runID: model.runID))
                if let outcome = Self.outcome(for: phase) {
                    transitions.append(.finished(runID: model.runID, outcome: outcome))
                }
            } else if phase == .active {
                transitions.append(.started(runID: model.runID))
            } else if let outcome = Self.outcome(for: phase) {
                transitions.append(.finished(runID: model.runID, outcome: outcome))
            }
        }
        phases = next
        seeded = true
        return transitions
    }
}

/// What the menu bar item shows (C8, C14).
public enum OmniStatusIndicator: Equatable, Sendable {
    case idle
    /// A dot stepping through four positions.
    case running(step: Int)
    /// A transient check after the last active run finished.
    case done
    /// A persistent mark until the failed run is opened.
    case failed
}

/// Pure state behind the menu bar indicator. The AppKit presenter asks it what
/// to draw for a given instant; tests drive it with explicit clocks.
public struct OmniStatusIndicatorModel: Equatable, Sendable {
    public static let stepCount = 4
    /// About one step per second (C8); tune by feel.
    public var stepInterval: TimeInterval
    public var doneDisplayDuration: TimeInterval
    public private(set) var activeRunIDs: Set<String> = []
    /// Failed runs nobody has opened yet, oldest first.
    public private(set) var unresolvedFailures: [String] = []
    private var runningSince: Date?
    private var doneUntil: Date?

    public init(stepInterval: TimeInterval = 1.0, doneDisplayDuration: TimeInterval = 4.0) {
        self.stepInterval = stepInterval
        self.doneDisplayDuration = doneDisplayDuration
    }

    public mutating func runStarted(_ runID: String, at now: Date) {
        if activeRunIDs.isEmpty { runningSince = now }
        activeRunIDs.insert(runID)
        doneUntil = nil
    }

    public mutating func runFinished(_ runID: String, outcome: RunActivityOutcome, at now: Date, announceOutcome: Bool = true) {
        activeRunIDs.remove(runID)
        if activeRunIDs.isEmpty { runningSince = nil }
        // H11: stop the stepping dot without a second arrival signal for a
        // result already seen in the pad or attached workspace.
        guard announceOutcome else { runOpened(runID); return }
        switch outcome {
        case .done:
            if activeRunIDs.isEmpty { doneUntil = now.addingTimeInterval(doneDisplayDuration) }
        case .failed:
            doneUntil = nil
            if !unresolvedFailures.contains(runID) { unresolvedFailures.append(runID) }
        case .cancelled, .proposalReady:
            break
        }
    }

    /// Opening a run clears its failure mark together with its notification (C6, C14).
    public mutating func runOpened(_ runID: String) {
        unresolvedFailures.removeAll { $0 == runID }
    }

    public func indicator(at now: Date) -> OmniStatusIndicator {
        if let runningSince, !activeRunIDs.isEmpty {
            let elapsed = max(0, now.timeIntervalSince(runningSince))
            return .running(step: Int(elapsed / stepInterval) % Self.stepCount)
        }
        // An unopened failure stays visible; the check only shows when nothing is owed (C14).
        if !unresolvedFailures.isEmpty { return .failed }
        if let doneUntil, now < doneUntil { return .done }
        return .idle
    }

    /// Whether the indicator changes on its own with time.
    public func isAnimating(at now: Date) -> Bool {
        switch indicator(at: now) {
        case .running, .done: true
        case .idle, .failed: false
        }
    }
}
