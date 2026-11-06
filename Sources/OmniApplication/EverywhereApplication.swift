import Foundation
import OmniCore

/// W2's durable index lifecycle. Full walks and event scans run on utility
/// tasks. Each result is merged under one short lock and published whole;
/// callbacks and snapshot writes run after that lock on serial queues.
public final class EverywhereService: @unchecked Sendable {
    private struct EventBatch {
        let eventID: UInt64
        var remaining: Int
        var failed = false
        var changed = false
    }

    private struct AppliedPatch {
        let sequence: UInt64
        let eventID: UInt64
        let patch: EverywhereIndexPatch
    }

    private struct AppliedRoot {
        let eventID: UInt64
        let replaceDescendants: Bool
    }

    private let builder: any EverywhereIndexBuilding
    private let snapshots: any EverywhereSnapshotStoring
    private let watcher: any EverywhereChangeWatching
    private let home: String
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private let saveQueue = DispatchQueue(label: "omni.everywhere.snapshot-save", qos: .utility)
    private let callbackQueue = DispatchQueue(label: "omni.everywhere.publication", qos: .utility)
    private var onChange: (@Sendable ([LauncherCandidate]) -> Void)?
    private var publicationVersion: UInt64 = 0
    private var published: EverywhereSnapshot?
    private var loaded = false
    private var fullReady = false
    private var watcherStarting = false
    private var watcherStarted = false
    private var stopped = false
    private var fullBuilding = false
    /// Incremented before each census; a maintenance scan from an older
    /// generation cannot overwrite that census or enter its replay list.
    private var fullGeneration: UInt64 = 0
    private let recoveryCooldown: TimeInterval
    private let recoverySleep: @Sendable (TimeInterval) async throws -> Void
    private var recoveryTimer: Task<Void, Never>?
    private var recoveryTimerID: UUID?
    private var recoveryRequired = false
    private var safeCheckpoint: UInt64?
    private var recoveryRevision: UInt64 = 0
    private var pendingRecoveryReason: String?
    private var nextRecoveryAt: Date?
    private var consecutiveUnresolvedBuilds = 0
    private var diagnostics = EverywhereRecoveryDiagnostics()
    private var fullTask: Task<Void, Never>?
    private var lastFullStarted: Date?
    private var maintenanceRunning = false
    private var maintenanceAgain = false
    private var maintenanceTask: Task<Void, Never>?
    private var lastPermissionRetry: Date?
    private var lastDocsFailure: Date?
    private var lastErrorValue: String?
    private var watcherError: String?
    private var cursor: UInt64?
    private var latestObservedEventID: UInt64 = 0
    private var minimumAcceptedEventID: UInt64 = 0
    private var nextSequence: UInt64 = 1
    private var nextCommittedSequence: UInt64 = 1
    private var batches: [UInt64: EventBatch] = [:]
    private var completedIDs: [UInt64: UInt64] = [:]
    private var rootTasks: [String: Task<Void, Never>] = [:]
    private var rootTaskSequences: [String: UInt64] = [:]
    /// Event scans are separate from maintenance tasks so neither can hide
    /// the other from overlap checks or cancellation.
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var pendingEventScans: [String: [UInt64]] = [:]
    private var lastAppliedByRoot: [String: AppliedRoot] = [:]
    private var patchesDuringFull: [AppliedPatch] = []

    public init(
        builder: any EverywhereIndexBuilding,
        snapshots: any EverywhereSnapshotStoring,
        watcher: any EverywhereChangeWatching,
        home: String,
        clock: @escaping @Sendable () -> Date = Date.init,
        recoveryCooldown: TimeInterval = 120,
        recoverySleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        onChange: (@Sendable ([LauncherCandidate]) -> Void)? = nil
    ) {
        self.builder = builder
        self.snapshots = snapshots
        self.watcher = watcher
        self.home = home
        self.clock = clock
        self.onChange = onChange
        self.recoveryCooldown = max(1, recoveryCooldown)
        self.recoverySleep = recoverySleep
    }

    /// Attach the owning launcher after both services exist. The immediate
    /// replay makes wiring order independent of persisted-snapshot loading.
    public func setOnChange(_ handler: @escaping @Sendable ([LauncherCandidate]) -> Void) {
        lock.withLock {
            onChange = handler
            if let existing = published?.candidates { notifyLocked(existing) }
        }
    }

    public var candidates: [LauncherCandidate] { lock.withLock { published?.candidates ?? [] } }
    public var isReady: Bool { lock.withLock { fullReady } }
    public var snapshot: EverywhereSnapshot? { lock.withLock { published } }
    public var stats: EverywhereWalkStats? { lock.withLock { published?.stats } }
    public var lastError: String? { lock.withLock { watcherError ?? lastErrorValue } }
    public var watcherDiagnostics: EverywhereWatcherDiagnostics { watcher.diagnostics }
    public var recoveryDiagnostics: EverywhereRecoveryDiagnostics {
        lock.withLock {
            var result = diagnostics
            result.pendingReason = pendingRecoveryReason
            result.nextEligibleRecoveryAt = nextRecoveryAt
            result.state = stopped ? "stopped" : fullBuilding ? "building" : pendingRecoveryReason != nil ? "cooldown" : "idle"
            result.cursor = recoveryRequired ? safeCheckpoint : cursor
            result.recoveryRequired = recoveryRequired
            return result
        }
    }
    public var healthLine: String? {
        lock.withLock {
            if watcherError != nil { return "Everywhere freshness unavailable" }
            if recoveryRequired, published?.candidates.isEmpty == false { return "Everywhere index is catching up" }
            guard published?.candidates.isEmpty != false else { return nil }
            if fullBuilding || !fullReady { return "Everywhere index is loading" }
            return lastErrorValue == nil ? "Everywhere index is empty" : "Everywhere index unavailable"
        }
    }

    /// Whether agent-output document ids may be missing: no snapshot yet, or
    /// one written before the exact-id lane (D1).
    public var documentIDsPending: Bool {
        lock.withLock { published?.carriesDocumentIDs != true }
    }

    /// Cheap persisted publication. A missing or incompatible snapshot leaves
    /// the service cold and the next refresh starts a full walk.
    public func loadPersisted() {
        let shouldLoad = lock.withLock { () -> Bool in
            guard !loaded else { return false }
            loaded = true
            return true
        }
        guard shouldLoad else { return }
        do {
            guard let snapshot = try snapshots.load() else { return }
            lock.withLock {
                guard published == nil else { return }
                published = snapshot
                cursor = snapshot.lastEventID
                fullReady = snapshot.lastEventID != nil
                recoveryRequired = snapshot.recoveryRequired == true
                safeCheckpoint = snapshot.lastEventID
                // Persist cooldown across ordinary restarts; clamp corrupt or
                // far-future values so they cannot suppress recovery forever.
                nextRecoveryAt = snapshot.recoveryNotBefore.map { min($0, clock().addingTimeInterval(900)) }
                if recoveryRequired { pendingRecoveryReason = "persisted-gap" }
                if !snapshot.stats.unreadableRoots.isEmpty { lastPermissionRetry = snapshot.builtAt }
                notifyLocked(snapshot.candidates)
            }
        } catch {
            recordError("everywhere snapshot unreadable: \(error)")
        }
    }

    /// Start the stream before a cold walk. Later docs-index and permission
    /// recovery use only the affected subtrees; full walks are for first
    /// build, a history gap, or the home-root opt-out exception.
    @discardableResult
    public func refreshIfDue(force: Bool = false) -> Task<Void, Never>? {
        loadPersisted()
        startWatcherIfNeeded()
        let now = clock()
        let generation = builder.currentDocsGeneration()
        let fullState = lock.withLock { (stopped, fullReady, fullBuilding) }
        if fullState.0 { return nil }
        if force { return requestRecovery(reason: "explicit-refresh") }
        if !fullState.1 {
            return lock.withLock {
                guard !fullBuilding else { return nil }
                if pendingRecoveryReason == nil { pendingRecoveryReason = "cold-start" }
                return scheduleRecoveryLocked()
            }
        }
        let recovery = lock.withLock { scheduleRecoveryLocked() }
        if let recovery { return recovery }
        let homeRecoveryDue = lock.withLock { () -> Bool in
            guard !fullBuilding, let snapshot = published,
                  snapshot.stats.unreadableRoots.contains(home) else { return false }
            return now.timeIntervalSince(lastPermissionRetry ?? snapshot.builtAt) >= 600
        }
        if homeRecoveryDue {
            // If the first home enumeration was denied, no child list exists
            // to patch. The first accessible census is a necessary exception
            // to W2's otherwise incremental recovery; it stays off actor and
            // event patches still publish while it runs.
            lock.withLock { lastPermissionRetry = now }
            return requestRecovery(reason: "home-permission")
        }
        let roots = lock.withLock { () -> [String] in
            guard !stopped, !fullBuilding else { return [] }
            var selected: [String] = []
            if generation != published?.docsGeneration,
               lastDocsFailure.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                selected.append(home + "/Tooling/agent-output")
            }
            // Written before the exact-id lane (D1): agent-output is re-read
            // until a patch brings its document ids (the marker), throttled
            // like any failed docs re-read.
            if published?.carriesDocumentIDs != true,
               lastDocsFailure.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                selected.append(home + "/Tooling/agent-output")
            }
            if let snapshot = published, !snapshot.stats.unreadableRoots.isEmpty,
               now.timeIntervalSince(lastPermissionRetry ?? snapshot.builtAt) >= 600 {
                selected.append(contentsOf: snapshot.stats.unreadableRoots.filter { $0 != home })
            }
            return Array(Set(selected)).sorted()
        }
        guard !roots.isEmpty else { return nil }
        return startMaintenance(roots: roots)
    }

    public func stop() {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            stopped = true
            pendingEventScans.removeAll()
            recoveryTimerID = nil
            recoveryTimer?.cancel()
            recoveryTimer = nil
            return Array(rootTasks.values) + Array(eventTasks.values) +
                (fullTask.map { [$0] } ?? []) + (maintenanceTask.map { [$0] } ?? [])
        }
        watcher.stop()
        for task in tasks { task.cancel() }
    }

    private func startMaintenance(roots: [String]) -> Task<Void, Never>? {
        let reservation = lock.withLock { () -> (sequence: UInt64, generation: UInt64)? in
            guard !stopped else { return nil }
            guard !maintenanceRunning else { maintenanceAgain = true; return nil }
            maintenanceRunning = true
            if !Set(published?.stats.unreadableRoots ?? []).isDisjoint(with: roots) { lastPermissionRetry = clock() }
            let sequence = nextSequence
            nextSequence &+= 1
            // A maintenance scan represents no new FSEvents ID; reserving a
            // sequence still orders its patch against live event patches.
            completedIDs[sequence] = cursor ?? 0
            advanceCursorLocked()
            return (sequence, fullGeneration)
        }
        guard let reservation else { return nil }
        let sequence = reservation.sequence
        var tasks: [Task<Void, Never>] = []
        for root in roots {
            let task = lock.withLock { () -> Task<Void, Never> in
                let earlier = (rootTasks.map { ($0.key, $0.value) } + eventTasks.map { ($0.key, $0.value) })
                    .compactMap { other, task -> Task<Void, Never>? in
                        overlaps(other, root) ? task : nil
                    }
                let task = Task.detached(priority: .utility) { [self] in
                    for previous in earlier { await previous.value }
                    guard !Task.isCancelled else { return }
                    do {
                        let patch = try builder.patch(root: root)
                        try Task.checkCancellation()
                        let currentGeneration = patch.updatesDocsGeneration ? builder.currentDocsGeneration() : nil
                        completeMaintenance(sequence: sequence, generation: reservation.generation, root: root,
                                            patch: patch, currentGeneration: currentGeneration, error: nil)
                    } catch {
                        completeMaintenance(sequence: sequence, generation: reservation.generation, root: root,
                                            patch: nil, currentGeneration: nil, error: error)
                    }
                }
                rootTasks[root] = task
                rootTaskSequences[root] = sequence
                return task
            }
            tasks.append(task)
        }
        let group = Task.detached(priority: .utility) { [self] in
            for task in tasks { await task.value }
            let again = lock.withLock { () -> Bool in
                maintenanceRunning = false
                maintenanceTask = nil
                let again = maintenanceAgain
                maintenanceAgain = false
                return again
            }
            if again { _ = refreshIfDue() }
        }
        lock.withLock { maintenanceTask = group }
        return group
    }

    private func completeMaintenance(sequence: UInt64, generation: UInt64, root: String,
                                     patch: EverywhereIndexPatch?, currentGeneration: String?, error: Error?) {
        lock.withLock {
            guard !stopped else { return }
            if rootTaskSequences[root] == sequence {
                rootTasks[root] = nil
                rootTaskSequences[root] = nil
            }
            defer { startPendingEventScansLocked() }
            guard generation == fullGeneration else { return }
            if let error {
                lastErrorValue = "everywhere subtree recovery failed: \(error)"
                if root.hasSuffix("/agent-output") { lastDocsFailure = clock() }
                return
            }
            guard let patch, let base = published else { return }
            let replacement = base.applying(patch, home: home, at: clock(), eventID: cursor)
            if fullBuilding { patchesDuringFull.append(AppliedPatch(sequence: sequence, eventID: UInt64.max, patch: patch)) }
            // A newer census owns durable publication. Persisting a live
            // patch while that census reconciles a history gap could advance
            // the cursor past missing events before the walk succeeds.
            publishLocked(replacement, persist: fullReady && !fullBuilding)
            if patch.updatesDocsGeneration {
                lastDocsFailure = nil
                if currentGeneration != patch.docsGeneration { maintenanceAgain = true }
            }
        }
    }

    private func startWatcherIfNeeded() {
        let checkpoint = lock.withLock { () -> UInt64? in
            guard !stopped, !watcherStarted, !watcherStarting else { return nil }
            watcherStarting = true
            return cursor ?? watcher.currentEventID()
        }
        guard let checkpoint else { return }
        do {
            try watcher.start(after: checkpoint) { [weak self] changes in self?.receive(changes) }
            lock.withLock {
                watcherStarting = false
                watcherStarted = true
                watcherError = nil
                cursor = max(cursor ?? 0, checkpoint)
            }
        } catch {
            lock.withLock {
                watcherStarting = false
                watcherError = "everywhere event stream unavailable: \(error)"
            }
        }
    }

    private func requestRecovery(reason: String) -> Task<Void, Never>? {
        lock.withLock {
            guard !stopped else { return nil }
            markRecoveryLocked(reason: reason)
            return scheduleRecoveryLocked()
        }
    }

    /// Called in the same critical section that receives a loss batch, before
    /// any ignored event or hot patch can complete its checkpoint obligation.
    private func markRecoveryLocked(reason: String) {
        diagnostics.recoveryRequests &+= 1
        if fullBuilding || pendingRecoveryReason != nil { diagnostics.coalescedRecoveryRequests &+= 1 }
        recoveryRevision &+= 1
        let firstUnresolvedRequest = !recoveryRequired
        if firstUnresolvedRequest { safeCheckpoint = cursor }
        recoveryRequired = true
        pendingRecoveryReason = reason
        // The marker is durable even if the process stops during cooldown.
        // A cold hot-patch publication is incomplete and must never be saved.
        if firstUnresolvedRequest, fullReady, let current = published { queueSaveLocked(current) }
    }

    /// One timer and one full walk at most. New requests never move the timer
    /// farther out, so a sustained event stream cannot starve a scheduled try.
    private func scheduleRecoveryLocked() -> Task<Void, Never>? {
        guard !stopped, !fullBuilding, let reason = pendingRecoveryReason else { return nil }
        let now = clock()
        if let nextRecoveryAt, nextRecoveryAt > now {
            guard recoveryTimer == nil else { return nil }
            let timerID = UUID()
            recoveryTimerID = timerID
            let delay = nextRecoveryAt.timeIntervalSince(now)
            let sleep = recoverySleep
            recoveryTimer = Task.detached(priority: .utility) { [weak self] in
                do { try await sleep(delay); try Task.checkCancellation() }
                catch { return }
                self?.recoveryTimerFired(timerID)
            }
            return nil
        }
        recoveryTimer?.cancel()
        recoveryTimer = nil
        recoveryTimerID = nil
        fullBuilding = true
        fullGeneration &+= 1
        pendingRecoveryReason = nil
        lastFullStarted = now
        nextRecoveryAt = now.addingTimeInterval(recoveryCooldown)
        patchesDuringFull = []
        diagnostics.fullStarts &+= 1
        diagnostics.currentReason = reason
        let revision = recoveryRevision
        // Delivered-event watermark is conservative: later stream delivery
        // is patched/replayed even if the filesystem already has newer IDs.
        let baseline = max(cursor ?? 0, latestObservedEventID)
        if fullReady, recoveryRequired, let current = published { queueSaveLocked(current) }
        let task = Task.detached(priority: .utility) { [self] in
            do {
                try Task.checkCancellation()
                let rebuilt = try builder.build()
                try Task.checkCancellation()
                finishFullBuild(rebuilt, baseline: baseline, revision: revision)
            } catch {
                lock.withLock {
                    fullBuilding = false
                    fullTask = nil
                    guard !stopped else { return }
                    diagnostics.fullFailures &+= 1
                    finishTimingLocked(unresolved: true)
                    lastErrorValue = "everywhere full walk failed: \(error)"
                    markRecoveryLocked(reason: "full-walk-failed")
                    if fullReady, let current = published { queueSaveLocked(current) }
                    _ = scheduleRecoveryLocked()
                }
            }
        }
        fullTask = task
        return task
    }

    private func recoveryTimerFired(_ timerID: UUID) {
        lock.withLock {
            guard !stopped, recoveryTimerID == timerID else { return }
            recoveryTimer = nil
            recoveryTimerID = nil
            _ = scheduleRecoveryLocked()
        }
    }

    private func finishTimingLocked(unresolved: Bool) {
        let now = clock()
        diagnostics.lastFullDuration = lastFullStarted.map { max(0, now.timeIntervalSince($0)) }
        diagnostics.currentReason = nil
        consecutiveUnresolvedBuilds = unresolved ? min(consecutiveUnresolvedBuilds + 1, 4) : 0
        let multiplier = pow(2.0, Double(max(0, consecutiveUnresolvedBuilds - 1)))
        // Rest after completion as well as spacing starts: a slow census must
        // not turn the cooldown into a permanently occupied utility worker.
        nextRecoveryAt = now.addingTimeInterval(min(900, recoveryCooldown * multiplier))
    }

    private func finishFullBuild(_ rebuilt: EverywhereSnapshot, baseline: UInt64, revision: UInt64) {
        let docsMovedDuringWalk = builder.currentDocsGeneration() != rebuilt.docsGeneration
        lock.withLock {
            guard !stopped else { fullBuilding = false; fullTask = nil; return }
            minimumAcceptedEventID = max(minimumAcceptedEventID, baseline)
            cursor = max(cursor ?? 0, baseline)
            let covered = batches.filter { $0.value.eventID <= baseline }
            for (sequence, batch) in covered {
                completedIDs[sequence] = batch.eventID
                batches[sequence] = nil
            }
            advanceCursorLocked()
            var merged = rebuilt
            for item in patchesDuringFull.sorted(by: { $0.sequence < $1.sequence }) where item.eventID > baseline {
                merged = merged.applying(item.patch, home: home, at: clock(), eventID: cursor)
            }
            // A loss received during this walk may describe a path already
            // visited. Only a later census may clear that new obligation.
            recoveryRequired = revision != recoveryRevision
            if !recoveryRequired {
                safeCheckpoint = cursor
                pendingRecoveryReason = nil
            }
            fullReady = true
            fullBuilding = false
            fullTask = nil
            diagnostics.fullFinishes &+= 1
            finishTimingLocked(unresolved: recoveryRequired)
            merged = merged.withEventID(cursor).withRecovery(required: recoveryRequired, notBefore: nextRecoveryAt)
            lastPermissionRetry = merged.stats.unreadableRoots.isEmpty ? nil : merged.builtAt
            patchesDuringFull = []
            lastErrorValue = nil
            publishLocked(merged, persist: true)
            _ = scheduleRecoveryLocked()
        }
        if docsMovedDuringWalk { _ = refreshIfDue() }
    }

    private func receive(_ changes: EverywhereFileChanges) {
        let directoryPaths = Set(changes.directoryPaths)
        let roots = Array(Set(changes.paths.compactMap {
            builder.affectedRoot(for: $0, isDirectory: directoryPaths.contains($0))
        })).sorted()
        let sequence = lock.withLock { () -> UInt64? in
            guard !stopped else { return nil }
            let sequence = nextSequence
            nextSequence &+= 1
            latestObservedEventID = max(latestObservedEventID, changes.eventID)
            batches[sequence] = EventBatch(eventID: changes.eventID, remaining: roots.count)
            if changes.requiresFullScan || changes.paths.contains(home + "/.nolaunch") || changes.paths.contains(home + "/.git") {
                if changes.requiresFullScan { diagnostics.lossBatches &+= 1 }
                markRecoveryLocked(reason: changes.requiresFullScan ? "event-history-gap" : "home-scope-change")
                _ = scheduleRecoveryLocked()
            }
            return sequence
        }
        guard let sequence else { return }
        if changes.paths.contains(home + "/Tooling/retrieval/.index/docs.meta.json") ||
           changes.paths.contains(home + "/Tooling/retrieval/.index/docs.jsonl") {
            _ = refreshIfDue()
        }
        if roots.isEmpty {
            completeIgnoredEvent(sequence: sequence)
            return
        }
        lock.withLock {
            for root in roots { enqueueEventScanLocked(root: root, sequence: sequence) }
            startPendingEventScansLocked()
        }
    }

    private func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private func canMergeScans(_ lhs: String, _ rhs: String) -> Bool {
        // The ordinary home patch replaces only loose files. It cannot
        // discharge an event for a descendant partition.
        overlaps(lhs, rhs) && (lhs == rhs || (lhs != home && rhs != home))
    }

    /// Keep at most one pending scan for each overlapping subtree. A broader
    /// root covers every narrower request, while the sequence list retains
    /// each event batch's checkpoint obligation.
    private func enqueueEventScanLocked(root: String, sequence: UInt64) {
        if let covering = pendingEventScans.keys.first(where: {
            $0 == root || ($0 != home && root.hasPrefix($0 + "/"))
        }) {
            pendingEventScans[covering, default: []].append(sequence)
            return
        }
        var scanRoot = root
        var sequences = [sequence]
        while let other = pendingEventScans.keys.first(where: { canMergeScans($0, scanRoot) }) {
            if scanRoot.hasPrefix(other + "/") { scanRoot = other }
            sequences += pendingEventScans.removeValue(forKey: other) ?? []
        }
        pendingEventScans[scanRoot] = sequences
    }

    private func startPendingEventScansLocked() {
        guard !stopped else { return }
        for root in pendingEventScans.keys.sorted() {
            guard !eventTasks.keys.contains(where: { overlaps($0, root) }),
                  !rootTasks.keys.contains(where: { overlaps($0, root) }),
                  let sequences = pendingEventScans.removeValue(forKey: root) else { continue }
            let task = Task.detached(priority: .utility) { [self] in
                do {
                    let patch = try builder.patch(root: root)
                    try Task.checkCancellation()
                    let docsMoved = patch.updatesDocsGeneration && builder.currentDocsGeneration() != patch.docsGeneration
                    completeEventScan(root: root, sequences: sequences, patch: patch,
                                      docsMoved: docsMoved, error: nil)
                } catch {
                    completeEventScan(root: root, sequences: sequences, patch: nil,
                                      docsMoved: false, error: error)
                }
            }
            eventTasks[root] = task
        }
    }

    private func completeEventScan(root: String, sequences: [UInt64], patch: EverywhereIndexPatch?,
                                   docsMoved: Bool, error: Error?) {
        let forceRebuild = lock.withLock { () -> Bool in
            eventTasks[root] = nil
            guard !stopped else { return false }
            let live = sequences.sorted().filter { batches[$0] != nil }
            let eventID = live.compactMap { batches[$0]?.eventID }.max() ?? 0
            let patchSequence = live.last
            var changed = false
            if let error, !live.isEmpty {
                lastErrorValue = "everywhere subtree refresh failed: \(error)"
            }
            if let patch, let patchSequence, eventID > minimumAcceptedEventID,
               !newerOverlappingPatchExists(patch: patch, eventID: eventID) {
                let base = published ?? EverywhereSnapshot(
                    builtAt: clock(), docsGeneration: builder.currentDocsGeneration(),
                    lastEventID: cursor, stats: EverywhereWalkStats(), candidates: []
                )
                let replacement = base.applying(patch, home: home, at: clock(), eventID: cursor)
                lastAppliedByRoot[patch.root] = AppliedRoot(eventID: eventID, replaceDescendants: patch.replaceDescendants)
                if fullBuilding { patchesDuringFull.append(AppliedPatch(sequence: patchSequence, eventID: eventID, patch: patch)) }
                publishLocked(replacement, persist: false)
                changed = true
            }
            for sequence in live {
                guard var batch = batches[sequence] else { continue }
                if error != nil { batch.failed = true }
                batch.remaining -= 1
                if batch.remaining <= 0 && !batch.failed {
                    batches[sequence] = nil
                    completedIDs[sequence] = batch.eventID
                } else {
                    batches[sequence] = batch
                }
            }
            let advanced = advanceCursorLocked()
            if advanced, let current = published { published = current.withEventID(cursor) }
            // A newer overlapping patch may already have published the rows.
            // Completing this older scan can still close the cursor gap, and
            // that new checkpoint must become durable.
            if (changed || advanced), fullReady, !fullBuilding, let current = published { queueSaveLocked(current) }
            startPendingEventScansLocked()
            return error != nil && !live.isEmpty
        }
        if forceRebuild { _ = requestRecovery(reason: "subtree-refresh-failed") }
        else if docsMoved { _ = refreshIfDue() }
    }

    private func completeIgnoredEvent(sequence: UInt64) {
        lock.withLock {
            guard !stopped, let batch = batches.removeValue(forKey: sequence) else { return }
            completedIDs[sequence] = batch.eventID
            if advanceCursorLocked(), let current = published {
                published = current.withEventID(cursor)
            }
        }
    }

    private func newerOverlappingPatchExists(patch: EverywhereIndexPatch, eventID: UInt64) -> Bool {
        lastAppliedByRoot.contains { other, applied in
            guard applied.eventID > eventID, overlaps(other, patch.root) else { return false }
            // An ordinary home patch changes loose files only. It neither
            // covers nor can overwrite a descendant partition. An opt-out
            // home patch explicitly replaces descendants and does overlap.
            if other == home && patch.root != home && !applied.replaceDescendants { return false }
            if patch.root == home && other != home && !patch.replaceDescendants { return false }
            return true
        }
    }

    @discardableResult
    private func advanceCursorLocked() -> Bool {
        var advanced = false
        while let eventID = completedIDs.removeValue(forKey: nextCommittedSequence) {
            cursor = max(cursor ?? 0, eventID)
            nextCommittedSequence &+= 1
            advanced = true
        }
        return advanced
    }

    private func publishLocked(_ snapshot: EverywhereSnapshot, persist: Bool) {
        published = snapshot
        notifyLocked(snapshot.candidates)
        if persist { queueSaveLocked(snapshot) }
    }

    private func notifyLocked(_ candidates: [LauncherCandidate]) {
        publicationVersion &+= 1
        let version = publicationVersion
        if let handler = onChange {
            callbackQueue.async { [self] in
                guard lock.withLock({ publicationVersion == version }) else { return }
                handler(candidates)
            }
        }
    }

    private func queueSaveLocked(_ snapshot: EverywhereSnapshot) {
        let snapshot = snapshot.withEventID(recoveryRequired ? safeCheckpoint : snapshot.lastEventID)
            .withRecovery(required: recoveryRequired, notBefore: nextRecoveryAt)
        saveQueue.async { [self] in
            do { try snapshots.save(snapshot) }
            catch { recordError("everywhere snapshot not saved: \(error)") }
        }
    }

    private func recordError(_ message: String) {
        lock.withLock { lastErrorValue = message }
    }
}
