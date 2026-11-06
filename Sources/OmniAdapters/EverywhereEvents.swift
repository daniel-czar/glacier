import CoreServices
import Foundation
#if canImport(OmniCore)
import OmniCore
#endif

/// One replayable FSEvents stream with bounded, periodically checked native exclusions.
public final class FSEverywhereWatcher: EverywhereChangeWatching, @unchecked Sendable {
    public enum Failure: Error { case cannotCreateStream, cannotStartStream }
    private let paths: [String]
    private let policy: EverywhereWatcherExclusionPolicy
    private let exclusionCacheURL: URL?
    private let queue = DispatchQueue(label: "omni.everywhere.fsevents", qos: .utility)
    private let deliveryQueue = DispatchQueue(label: "omni.everywhere.fsevents.delivery", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let deliveryQueueKey = DispatchSpecificKey<Bool>()
    private let pendingLock = NSLock()
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var handler: (@Sendable (EverywhereFileChanges) -> Void)?
    private var known: Set<String> = []
    /// The flag remains true until an atomic service recovery acknowledgement
    /// exists. A filter can hide an event while unrelated paths advance the
    /// persisted cursor, so every later process start needs one recovery walk.
    private struct CacheState: Codable, Equatable {
        var schemaVersion = 1
        var everExcluded = false
        var roots: [String] = []
    }
    private var cacheState = CacheState()
    private var applied: [String] = []
    private var lastEventID: UInt64 = 0
    private var counters = EverywhereWatcherDiagnostics()
    private var pending: Pending?
    private var deliveryScheduled = false
    private var acceptingDelivery = false
    private var deliveryEpoch: UInt64 = 0
    private var retryExclusionsAfter = Date.distantPast

    private final class Callback: @unchecked Sendable {
        weak var watcher: FSEverywhereWatcher?
        init(_ watcher: FSEverywhereWatcher) { self.watcher = watcher }
    }

    private struct Pending {
        var paths: Set<String> = []
        var directories: Set<String> = []
        var discoverySample: [String] = []
        var sampleReplacementIndex = 0
        var eventID: UInt64 = 0
        var gap = false
        var historyDone = false
        mutating func merge(_ other: EverywhereFileChanges, sample: [String]) -> Bool {
            eventID = max(eventID, other.eventID)
            let overflow = !gap && !other.requiresFullScan && paths.count + other.paths.count > 2_048
            gap = gap || other.requiresFullScan
            historyDone = historyDone || other.historyDone
            for path in sample {
                if discoverySample.count < 128 { discoverySample.append(path) }
                else {
                    discoverySample[sampleReplacementIndex % 128] = path
                    sampleReplacementIndex &+= 1
                }
            }
            if gap || overflow {
                gap = true
                paths.removeAll()
                directories.removeAll()
            } else {
                paths.formUnion(other.paths)
                directories.formUnion(other.directoryPaths)
            }
            return overflow
        }
        var change: EverywhereFileChanges {
            EverywhereFileChanges(paths: paths.sorted(), eventID: eventID, requiresFullScan: gap,
                                  historyDone: historyDone, directoryPaths: directories.sorted())
        }
    }

    public init(paths: [String], exclusionCacheURL: URL? = nil) {
        let canonicalPaths = Array(Set(paths.map(EverywhereWatcherPath.physicalRoot))).sorted()
        self.paths = canonicalPaths
        policy = EverywhereWatcherExclusionPolicy(paths: canonicalPaths)
        self.exclusionCacheURL = exclusionCacheURL
        queue.setSpecific(key: queueKey, value: true)
        deliveryQueue.setSpecific(key: deliveryQueueKey, value: true)
    }

    public var diagnostics: EverywhereWatcherDiagnostics {
        if DispatchQueue.getSpecific(key: queueKey) == true { return counters }
        return queue.sync { counters }
    }

    static func needsFullScan(_ flags: FSEventStreamEventFlags) -> Bool {
        let mask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        return flags & mask != 0
    }

    public func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    public func start(after eventID: UInt64? = nil, handler: @escaping @Sendable (EverywhereFileChanges) -> Void) throws {
        try queue.sync {
            guard stream == nil else { return }
            known = []
            cacheState = CacheState()
            pendingLock.withLock { self.handler = handler }
            lastEventID = eventID ?? FSEventsGetCurrentEventId()
            let cachedExclusionsNeedRecovery = loadValidatedCache()
            do {
                let (created, exclusions) = try makeStream(since: eventID, exclusions: policy.ranked(known))
                stream = created
                applied = exclusions
                updateDiagnostics()
                pendingLock.withLock {
                    deliveryEpoch &+= 1
                    pending = nil
                    deliveryScheduled = false
                    acceptingDelivery = true
                }
                startTimer()
                if cachedExclusionsNeedRecovery {
                    // Even a still-valid marker may have been enrolled just
                    // before a crash and before its index patch persisted.
                    enqueue(EverywhereFileChanges(paths: [], eventID: lastEventID,
                                                  requiresFullScan: true))
                }
            } catch {
                pendingLock.withLock { self.handler = nil }
                throw error
            }
        }
    }

    private func makeStream(since eventID: UInt64?, exclusions: [String]) throws -> (FSEventStreamRef, [String]) {
        let callback = Unmanaged.passRetained(Callback(self))
        var context = FSEventStreamContext(version: 0, info: callback.toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Callback>.fromOpaque(info).release() } }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, { _, info, count, rawPaths, eventFlags, eventIDs in
            guard let info, let watcher = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().watcher else { return }
            let paths = unsafeBitCast(rawPaths, to: NSArray.self)
            watcher.receive(count: count, paths: paths, flags: eventFlags, ids: eventIDs)
        }, &context, paths as CFArray,
        eventID.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else {
            callback.release()
            throw Failure.cannotCreateStream
        }
        var accepted: [String] = []
        if !exclusions.isEmpty {
            if FSEventStreamSetExclusionPaths(created, exclusions as CFArray) { accepted = exclusions }
            else { counters.exclusionApplyFailures &+= 1 }
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw Failure.cannotStartStream
        }
        return (created, accepted)
    }

    /// The native callback only copies bounded paths and updates counters.
    private func receive(count: Int, paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>,
                         ids: UnsafePointer<FSEventStreamEventId>) {
        var batch = Pending()
        var sample: [String] = []
        let sampleStride = max(1, (count + 127) / 128)
        let droppedMask = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        counters.batches &+= 1
        counters.events &+= UInt64(count)
        for index in 0..<count {
            batch.eventID = max(batch.eventID, ids[index])
            if Self.needsFullScan(flags[index]) { batch.gap = true; counters.lossFlags &+= 1 }
            if flags[index] & droppedMask != 0 { counters.droppedEventFlags &+= 1 }
            if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0,
               flags[index] & droppedMask == 0 { counters.subtreeScanFlags &+= 1 }
            if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                batch.historyDone = true
            } else if index < paths.count && (!batch.gap || index % sampleStride == 0),
                      let path = paths[index] as? String {
                if index % sampleStride == 0 && sample.count < 128 { sample.append(path) }
                guard !batch.gap else { continue }
                if batch.paths.count >= 2_048 {
                    batch.gap = true
                    counters.deliveryOverflows &+= 1
                    batch.paths.removeAll()
                    batch.directories.removeAll()
                } else {
                    batch.paths.insert(path)
                    if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                        batch.directories.insert(path)
                    }
                }
            }
        }
        lastEventID = max(lastEventID, batch.eventID)
        enqueue(batch.change, discoverySample: sample)
    }

    private func enqueue(_ change: EverywhereFileChanges, discoverySample: [String] = []) {
        let (schedule, overflow, epoch) = pendingLock.withLock { () -> (Bool, Bool, UInt64) in
            guard acceptingDelivery else { return (false, false, deliveryEpoch) }
            if pending == nil { pending = Pending() }
            let overflow = pending!.merge(change, sample: discoverySample)
            guard !deliveryScheduled else { return (false, overflow, deliveryEpoch) }
            deliveryScheduled = true
            return (true, overflow, deliveryEpoch)
        }
        if overflow { counters.deliveryOverflows &+= 1 }
        if schedule { deliveryQueue.async { [weak self] in self?.drain(epoch: epoch) } }
    }

    private func drain(epoch: UInt64) {
        while true {
            let next = pendingLock.withLock { () -> (EverywhereFileChanges, [String], (@Sendable (EverywhereFileChanges) -> Void)?)? in
                guard epoch == deliveryEpoch else { return nil }
                guard acceptingDelivery, let pending else { deliveryScheduled = false; return nil }
                self.pending = nil
                return (pending.change, pending.discoverySample, handler)
            }
            guard let (change, sample, receiver) = next else { return }
            receiver?(change)
            guard pendingLock.withLock({ epoch == deliveryEpoch && acceptingDelivery }) else { return }
            let discovered = Set(sample.compactMap { policy.discover(from: $0) })
            if !discovered.isEmpty { queue.async { [weak self] in self?.learn(discovered) } }
        }
    }

    private func learn(_ discovered: Set<String>) {
        guard stream != nil, exclusionCacheURL != nil else { return }
        known.formUnion(discovered)
        if known.count > 32 { known = Set(policy.ranked(known)) }
        let wanted = policy.ranked(known)
        if wanted != applied { replaceStream(wanted) }
    }

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 15, repeating: 15)
        source.setEventHandler { [weak self] in self?.revalidate() }
        timer = source
        source.resume()
    }

    private func revalidate() {
        guard stream != nil else { return }
        counters.exclusionRevalidations &+= 1
        known = Set(known.filter { policy.reason(for: $0) != nil })
        let wanted = policy.ranked(known)
        if wanted != applied { replaceStream(wanted) }
    }

    /// Deterministic seam for marker restoration tests; production uses the timer.
    func revalidateNowForTests() { queue.sync { revalidate() } }

    /// Deterministic seam for native exclusion capacity tests; production learns from events.
    func learnNowForTests(_ discovered: Set<String>) { queue.sync { learn(discovered) } }

    /// Waits for deliveries queued by a completed test action, including a
    /// synthetic recovery; safe if a test calls it from the delivery callback.
    func drainDeliveryNowForTests() {
        guard DispatchQueue.getSpecific(key: deliveryQueueKey) != true else { return }
        deliveryQueue.sync {}
    }

    private func replaceStream(_ wanted: [String]) {
        guard let previous = stream else { return }
        guard Date() >= retryExclusionsAfter else { return }
        // Persist evidence before a new filter can hide any event. If the
        // cache cannot be written, enroll no new native exclusions.
        let safeWanted: [String]
        let historyPersisted = persistHistory(adding: wanted)
        if historyPersisted { safeWanted = wanted }
        else {
            safeWanted = []
            counters.exclusionApplyFailures &+= 1
            retryExclusionsAfter = Date().addingTimeInterval(60)
        }
        // Start from the last delivered ID before stopping the old stream.
        guard let (replacement, accepted) = try? makeStream(since: lastEventID, exclusions: safeWanted) else {
            counters.exclusionApplyFailures &+= 1
            retryExclusionsAfter = Date().addingTimeInterval(60)
            return
        }
        let removed = Set(applied).subtracting(accepted)
        stream = replacement
        applied = accepted
        if !safeWanted.isEmpty && accepted.isEmpty { retryExclusionsAfter = Date().addingTimeInterval(60) }
        updateDiagnostics()
        FSEventStreamStop(previous)
        FSEventStreamInvalidate(previous)
        FSEventStreamRelease(previous)
        // Check after the replacement starts: a marker removed during the
        // handoff must not be mistaken for a still-excluded capacity eviction.
        // Failed persistence or application remains a conservative recovery
        // case, even when a path still looks excluded on disk.
        let capacityEvictions = historyPersisted && accepted == wanted
            ? removed.filter { policy.reason(for: $0) != nil } : []
        counters.exclusionCapacityEvictions &+= UInt64(capacityEvictions.count)
        if capacityEvictions.count != removed.count {
            // The old filter can hide a marker removal. An old event ID cannot
            // reliably pass the service's full-build baseline, so a recovery
            // walk reconciles restored scope without advancing past events
            // still waiting for delivery.
            counters.exclusionScopeRecoveries &+= 1
            enqueue(EverywhereFileChanges(paths: [], eventID: lastEventID,
                                          requiresFullScan: true))
        }
    }

    private func updateDiagnostics() {
        counters.nativeExclusionPaths = applied
        counters.nativeExclusionCount = applied.count
    }

    private func loadValidatedCache() -> Bool {
        guard let exclusionCacheURL else { return false }
        guard let data = try? Data(contentsOf: exclusionCacheURL) else {
            let exists = FileManager.default.fileExists(atPath: exclusionCacheURL.path)
            if exists { cacheState.everExcluded = true }
            return exists
        }
        if let decoded = try? JSONDecoder().decode(CacheState.self, from: data), decoded.schemaVersion == 1 {
            cacheState = CacheState(everExcluded: decoded.everExcluded || !decoded.roots.isEmpty,
                                    roots: Array(decoded.roots.prefix(8)))
        } else if let legacy = try? JSONDecoder().decode([String].self, from: data) {
            cacheState = CacheState(everExcluded: !legacy.isEmpty, roots: Array(legacy.prefix(8)))
        } else {
            cacheState = CacheState(everExcluded: true)
        }
        known = Set(cacheState.roots.filter { policy.reason(for: $0) != nil })
        return cacheState.everExcluded
    }

    private func persistHistory(adding wanted: [String]) -> Bool {
        guard let exclusionCacheURL else { return wanted.isEmpty }
        let next = CacheState(everExcluded: cacheState.everExcluded || !wanted.isEmpty || !applied.isEmpty,
                              roots: Array(wanted.prefix(8)))
        guard next != cacheState || !FileManager.default.fileExists(atPath: exclusionCacheURL.path) else { return true }
        guard let data = try? JSONEncoder().encode(next) else { return false }
        do {
            try FileManager.default.createDirectory(at: exclusionCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: exclusionCacheURL, options: .atomic)
            cacheState = next
            return true
        } catch { return false }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopStream() }
        else { queue.sync { stopStream() } }
    }

    private func stopStream() {
        timer?.cancel()
        timer = nil
        pendingLock.withLock {
            deliveryEpoch &+= 1
            acceptingDelivery = false
            pending = nil
            deliveryScheduled = false
            handler = nil
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
