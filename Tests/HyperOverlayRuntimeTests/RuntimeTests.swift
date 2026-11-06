import AppKit
import Darwin
import HyperOverlayCore
import HyperOverlayRuntime
import Testing

@Test func clipboardHandoffKeepsCapturedExternalTargetAndNeverSubstitutesHost() {
    #expect(HostSurfaceRouting.clipboardOrigin(
        explicitPID: 42, omniVisible: true, omniOriginPID: 7,
        frontmostPID: 99, hostPID: 99) == 42)
    #expect(HostSurfaceRouting.clipboardOrigin(
        explicitPID: nil, explicitOrigin: true, omniVisible: false, omniOriginPID: nil,
        frontmostPID: 99, hostPID: 99) == nil)
    #expect(HostSurfaceRouting.clipboardOrigin(
        explicitPID: nil, omniVisible: true, omniOriginPID: 7,
        frontmostPID: 99, hostPID: 99) == 7)
    #expect(HostSurfaceRouting.clipboardOrigin(
        explicitPID: nil, omniVisible: true, omniOriginPID: nil,
        frontmostPID: 99, hostPID: 99) == nil)
    #expect(HostSurfaceRouting.clipboardOrigin(
        explicitPID: nil, omniVisible: false, omniOriginPID: nil,
        frontmostPID: 9) == 9)
}

@Test func backgroundWorkspaceCannotOverrideCurrentExternalPasteTarget() {
    #expect(HostSurfaceRouting.clipboardOrigin(
        explicitPID: nil, omniVisible: true, omniOriginPID: 7,
        frontmostPID: 9, hostPID: 99) == 9)
    #expect(HostSurfaceRouting.clipboardOrigin(
        explicitPID: nil, omniVisible: false, omniOriginPID: nil,
        frontmostPID: 99, hostPID: 99) == nil)
}

@MainActor
@Test func foregroundArbitratorPreservesToggleReplacementAndGenerationGuards() {
    let foreground = ForegroundArbitrator(allowedOverlays: ["reference", "help"])

    let opened = foreground.show("reference")
    #expect(opened.kind == .opened("reference"))
    #expect(foreground.isCurrent(overlay: "reference", generation: 1))

    let replaced = foreground.show("help")
    #expect(replaced.kind == .replaced(from: "reference", to: "help"))
    #expect(!foreground.isCurrent(overlay: "reference", generation: 1))
    #expect(foreground.isCurrent(overlay: "help", generation: 2))

    let closed = foreground.show("help")
    #expect(closed.kind == .closed)
    #expect(foreground.state == .idle)
    #expect(foreground.generation == 3)
}

@MainActor
@Test func livenessLeasesSuppressIdleExitUntilEveryLeaseIsReleased() {
    let registry = RunLivenessRegistry()
    let first = registry.acquire()
    let second = registry.acquire()

    #expect(registry.suppressesIdleExit)
    #expect(registry.activeLeaseCount == 2)

    registry.release(first)
    #expect(registry.suppressesIdleExit)
    registry.release(second)
    #expect(!registry.suppressesIdleExit)
}

@Test func socketPathValidationRejectsOverlongPathWithoutBinding() {
    let path = "/tmp/" + String(repeating: "x", count: 256)
    #expect(throws: UnixSocketError.self) {
        try RuntimeUnixSocket.validatePath(path)
    }
}

/// The host's late reply to a client that already hung up. The disposition is
/// left ignored afterwards: restoring the default could race another test's
/// write and end the whole test process.
@Test func ignoredBrokenPipesTurnALateSocketReplyIntoAnEPIPEError() throws {
    ProcessSignals.ignoreBrokenPipes()
    var action = sigaction()
    try #require(sigaction(SIGPIPE, nil, &action) == 0)
    // Stop here rather than let the write below end the whole test process.
    try #require(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self))

    var descriptors: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    defer { close(descriptors[0]) }
    close(descriptors[1])
    do {
        try RuntimeUnixSocket.writeAll(fd: descriptors[0], data: Data("late reply\n".utf8))
        Issue.record("a write to a closed peer succeeded")
    } catch UnixSocketError.writeFailed(let code) {
        #expect(code == EPIPE)
    }
}

/// A client that hangs up before the host accepts it makes SO_RCVTIMEO fail
/// with EINVAL. Before `acceptNext`, that ended the host's accept loop and
/// left a live host that never accepted again.
@Test func acceptNextDropsAClientThatHungUpBeforeAcceptAndKeepsServing() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("acc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("s").path
    let listener = try RuntimeUnixSocket.bindListener(path: path)
    defer { close(listener) }

    let early = try RuntimeUnixSocket.connect(path: path)
    try RuntimeUnixSocket.writeAll(fd: early, data: Data("early\n".utf8))
    close(early)
    #expect(RuntimeUnixSocket.acceptNext(listener: listener) == .dropped(EINVAL))

    let late = try RuntimeUnixSocket.connect(path: path)
    defer { close(late) }
    try RuntimeUnixSocket.writeAll(fd: late, data: Data("late\n".utf8))
    guard case .connection(let accepted) = RuntimeUnixSocket.acceptNext(listener: listener) else {
        Issue.record("the client after the hang-up was not accepted")
        return
    }
    defer { close(accepted) }
    #expect(try RuntimeUnixSocket.readLine(fd: accepted) == Data("late".utf8))

    let notListening = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(notListening >= 0)
    defer { close(notListening) }
    #expect(RuntimeUnixSocket.acceptNext(listener: notListening) == .listenerFailed(EINVAL))
}

/// A host that drops every connection must say so, without flooding stderr.
@Test func droppedConnectionsAreReportedAtOnceThenAtMostOncePerInterval() {
    var report = DroppedConnectionReport(interval: 60)
    #expect(report.record(errno: EINVAL, at: 100) == 1)
    #expect(report.record(errno: EINVAL, at: 110) == nil)
    #expect(report.record(errno: EINVAL, at: 150) == nil)
    #expect(report.record(errno: EINVAL, at: 161) == 3)
    #expect(report.record(errno: EINVAL, at: 162) == nil)
}

/// Neither a retry nor shutdown closing the listener is a dropped client;
/// counting them logged a false drop on every quit.
@Test func droppedConnectionReportIgnoresRetriesAndShutdown() {
    var report = DroppedConnectionReport(interval: 60)
    #expect(report.record(errno: EINTR, at: 100) == nil)
    #expect(report.record(errno: ECONNABORTED, at: 101) == nil)
    #expect(report.record(errno: EINVAL, at: 102) == 1)
}

@Test func runtimePathsPreserveLegacyDefaultAndRejectRelativeOverride() throws {
    let legacy = try RuntimePaths.resolve(environment: [:])
    #expect(legacy.rootURL.path.hasSuffix("Library/Application Support/DanielTooling/hyper-overlay"))

    #expect(throws: RuntimePathError.self) {
        try RuntimePaths.resolve(environment: [RuntimePaths.runtimeRootEnvironment: "relative/runtime"])
    }
}

@Test func panelPlacementCentersAndClampsInsideVisibleFrame() {
    let frame = OverlayPanelPlacement.frame(
        size: NSSize(width: 400, height: 300),
        visibleFrame: NSRect(x: 10, y: 20, width: 300, height: 200)
    )

    #expect(frame.origin.x == 22)
    #expect(frame.origin.y == 32)
    #expect(frame.size == NSSize(width: 400, height: 300))
}

private struct FakeCancellationDriver: ProcessGroupCancellationDriving {
    let termResult: Bool
    let killResult: Bool
    let waits: [Bool]
    private let index = LockingIndex()

    func send(signal: Int32, toProcessGroup processGroupID: pid_t) -> Bool {
        signal == SIGTERM ? termResult : killResult
    }

    func waitForStopAndReap(timeout: TimeInterval) -> Bool {
        index.next(from: waits)
    }
}

private final class LockingIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next(from values: [Bool]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value < values.count else { return false }
        defer { value += 1 }
        return values[value]
    }
}

@Test func helperCancellationAcknowledgesReapedOrReportsUncertainty() {
    let reaped = ProcessGroupSupervisor(
        processGroupID: 42,
        driver: FakeCancellationDriver(termResult: true, killResult: true, waits: [false, true])
    )
    #expect(reaped.cancelAndAcknowledge() == .stoppedAndReaped)

    let uncertain = ProcessGroupSupervisor(
        processGroupID: 42,
        driver: FakeCancellationDriver(termResult: true, killResult: true, waits: [false, false, false])
    )
    #expect(uncertain.cancelAndAcknowledge() == .uncertain("process-group-did-not-stop-and-reap"))
}

@MainActor
@Test func ownedProcessGroupsKeepHangingFixturesOwnedThroughGroupShutdown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let readyFiles = [root.appendingPathComponent("one.ready"), root.appendingPathComponent("two.ready")]
    let registry = OwnedProcessGroups()
    let helpers = try [
        registry.start(makeHangingProcessFixture(readyFile: readyFiles[0])),
        registry.start(makeHangingProcessFixture(readyFile: readyFiles[1]))
    ]
    for helper in helpers {
        #expect(getpgid(helper.processGroupID) == helper.processGroupID)
    }
    defer {
        for helper in helpers {
            _ = ProcessGroupSupervisor(process: helper.process, processGroupID: helper.processGroupID)
                .cancelAndAcknowledge()
        }
    }

    let deadline = Date().addingTimeInterval(5)
    while !readyFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(readyFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

    #expect(registry.activeCount == 2)
    #expect(Set(registry.snapshot().map(\.processGroupID)) == Set(helpers.map(\.processGroupID)))
    #expect(registry.beginShutdown().count == 2)
    let lateProcess = makeHangingProcessFixture(readyFile: root.appendingPathComponent("late.ready"))
    #expect(throws: (any Error).self) { try registry.start(lateProcess) }
    #expect(!lateProcess.isRunning)

    for helper in helpers {
        registry.forget(helper)
    }
    #expect(registry.activeCount == 2)

    let acknowledgements = await withTaskGroup(
        of: ProcessGroupCancellationAcknowledgement.self,
        returning: [ProcessGroupCancellationAcknowledgement].self
    ) { group in
        for helper in helpers {
            group.addTask {
                ProcessGroupSupervisor(process: helper.process, processGroupID: helper.processGroupID)
                    .cancelAndAcknowledge()
            }
        }
        var values: [ProcessGroupCancellationAcknowledgement] = []
        for await acknowledgement in group {
            values.append(acknowledgement)
        }
        return values
    }
    #expect(acknowledgements.allSatisfy { $0 == .stoppedAndReaped })

    for helper in helpers {
        registry.forget(helper)
    }
    #expect(registry.activeCount == 0)
    for helper in helpers {
        #expect(Darwin.kill(-helper.processGroupID, 0) == -1)
        #expect(errno == ESRCH)
    }
}

private func makeHangingProcessFixture(readyFile: URL) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-c",
        """
        import os, subprocess, sys, time
        os.setpgrp()
        subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        with open(sys.argv[1], "w") as handle:
            handle.write("child-started")
        time.sleep(60)
        """,
        readyFile.path
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return process
}

@MainActor
@Test(arguments: [false, true])
func shutdownWaitsForDescendantAfterGroupLeaderExits(leaderAlreadyExited: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("child.ready")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", """
        import subprocess, sys, time
        child = "import os, signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(sys.argv[1], 'w').write(str(os.getpid())); time.sleep(60)"
        subprocess.Popen([sys.executable, "-c", child, sys.argv[1]])
        time.sleep(60)
        """, ready.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let registry = OwnedProcessGroups()
    let helper = try registry.start(process)
    defer {
        _ = Darwin.kill(-helper.processGroupID, SIGKILL)
        process.waitUntilExit()
    }
    #expect(getpgid(helper.processGroupID) == helper.processGroupID)
    let readyDeadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let childPID = try #require(Int32(String(contentsOf: ready, encoding: .utf8)))
    #expect(getpgid(childPID) == helper.processGroupID)

    if leaderAlreadyExited {
        #expect(Darwin.kill(helper.processGroupID, SIGTERM) == 0)
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!process.isRunning)
        registry.forget(helper)
        #expect(registry.activeCount == 1)
    }

    let acknowledgement = await Task.detached {
        ProcessGroupSupervisor(process: process, processGroupID: helper.processGroupID,
                               terminateGrace: 0.1, killGrace: 1.0).cancelAndAcknowledge()
    }.value
    #expect(acknowledgement == .stoppedAndReaped)
    #expect(Darwin.kill(-helper.processGroupID, 0) == -1)
    #expect(errno == ESRCH)
    #expect(Darwin.kill(childPID, 0) == -1)
    registry.forget(helper)
    #expect(registry.activeCount == 0)
}
