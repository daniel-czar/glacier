import Foundation

/// Cheap service-local counters; no filesystem probing or candidate copying.
public struct EverywhereRecoveryDiagnostics: Codable, Sendable, Equatable {
    public var fullStarts: UInt64 = 0
    public var fullFinishes: UInt64 = 0
    public var fullFailures: UInt64 = 0
    public var recoveryRequests: UInt64 = 0
    public var coalescedRecoveryRequests: UInt64 = 0
    public var lossBatches: UInt64 = 0
    public var currentReason: String?
    public var pendingReason: String?
    public var lastFullDuration: TimeInterval?
    public var nextEligibleRecoveryAt: Date?
    public var state: String = "idle"
    public var cursor: UInt64?
    public var recoveryRequired: Bool = false

    public init() {}
}
