import Foundation

/// Advisory filesystem events. A gap requires a fresh walk; the checkpoint
/// advances only after the corresponding candidate changes are published.
public struct EverywhereFileChanges: Sendable, Equatable {
    public let paths: [String]
    /// Paths FSEvents identified as directories, including deleted paths
    /// whose extension would otherwise look like an unsupported file type.
    public let directoryPaths: [String]
    public let eventID: UInt64
    public let requiresFullScan: Bool
    public let historyDone: Bool

    public init(paths: [String], eventID: UInt64, requiresFullScan: Bool = false, historyDone: Bool = false,
                directoryPaths: [String] = []) {
        self.paths = paths
        self.directoryPaths = directoryPaths
        self.eventID = eventID
        self.requiresFullScan = requiresFullScan
        self.historyDone = historyDone
    }
}

/// Cumulative counters for the current watcher lifetime. Native paths are
/// deliberately bounded by FSEvents' eight-directory exclusion limit.
public struct EverywhereWatcherDiagnostics: Codable, Sendable, Equatable {
    public var batches: UInt64
    public var events: UInt64
    public var lossFlags: UInt64
    public var droppedEventFlags: UInt64
    public var subtreeScanFlags: UInt64
    public var deliveryOverflows: UInt64
    public var nativeExclusionCount: Int
    public var exclusionApplyFailures: UInt64
    public var exclusionRevalidations: UInt64
    /// Removed native filters whose paths still satisfy crawler exclusion policy.
    public var exclusionCapacityEvictions: UInt64
    /// Full recovery requests caused by restored or uncertain exclusion scope.
    public var exclusionScopeRecoveries: UInt64
    public var nativeExclusionPaths: [String]

    public init(batches: UInt64 = 0, events: UInt64 = 0, lossFlags: UInt64 = 0,
                droppedEventFlags: UInt64 = 0, subtreeScanFlags: UInt64 = 0,
                deliveryOverflows: UInt64 = 0,
                nativeExclusionCount: Int = 0, exclusionApplyFailures: UInt64 = 0,
                exclusionRevalidations: UInt64 = 0, nativeExclusionPaths: [String] = [],
                exclusionCapacityEvictions: UInt64 = 0, exclusionScopeRecoveries: UInt64 = 0) {
        self.batches = batches
        self.events = events
        self.lossFlags = lossFlags
        self.droppedEventFlags = droppedEventFlags
        self.subtreeScanFlags = subtreeScanFlags
        self.deliveryOverflows = deliveryOverflows
        self.nativeExclusionCount = nativeExclusionCount
        self.exclusionApplyFailures = exclusionApplyFailures
        self.exclusionRevalidations = exclusionRevalidations
        self.exclusionCapacityEvictions = exclusionCapacityEvictions
        self.exclusionScopeRecoveries = exclusionScopeRecoveries
        self.nativeExclusionPaths = nativeExclusionPaths
    }
}

public protocol EverywhereChangeWatching: Sendable {
    /// Capture before a cold walk so events during that walk are replayed.
    func currentEventID() -> UInt64
    func start(after eventID: UInt64?, handler: @escaping @Sendable (EverywhereFileChanges) -> Void) throws
    func stop()
    var diagnostics: EverywhereWatcherDiagnostics { get }
}

public extension EverywhereChangeWatching {
    var diagnostics: EverywhereWatcherDiagnostics { EverywhereWatcherDiagnostics() }
}
