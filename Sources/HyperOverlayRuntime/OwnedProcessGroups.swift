import Darwin
import Foundation
import HyperOverlayCore

public final class OwnedProcessGroup: @unchecked Sendable {
    public let process: Process
    public let processGroupID: pid_t

    fileprivate init(process: Process) {
        self.process = process
        self.processGroupID = process.processIdentifier
    }
}

@MainActor
public final class OwnedProcessGroups {
    private var groups: [pid_t: OwnedProcessGroup] = [:]
    private var acceptingStarts = true

    public init() {}

    public var activeCount: Int {
        pruneFinishedGroups()
        return groups.count
    }

    @discardableResult
    public func start(_ process: Process) throws -> OwnedProcessGroup {
        guard acceptingStarts else { throw ConfigurationError.invalid("host is shutting down") }
        pruneFinishedGroups()
        try process.run()
        let group = OwnedProcessGroup(process: process)
        groups[group.processGroupID] = group
        return group
    }

    public func snapshot() -> [OwnedProcessGroup] {
        pruneFinishedGroups()
        return Array(groups.values)
    }

    public func beginShutdown() -> [OwnedProcessGroup] {
        acceptingStarts = false
        return snapshot()
    }

    public func forget(_ group: OwnedProcessGroup) {
        guard groups[group.processGroupID]?.process === group.process,
              !group.process.isRunning,
              processGroupIsAbsent(group.processGroupID)
        else {
            return
        }
        group.process.waitUntilExit()
        groups.removeValue(forKey: group.processGroupID)
    }

    private func pruneFinishedGroups() {
        for group in Array(groups.values) { forget(group) }
    }
}
