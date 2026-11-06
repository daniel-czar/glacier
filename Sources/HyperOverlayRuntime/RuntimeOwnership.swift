import AppKit
import Darwin
import Foundation
import HyperOverlayCore

public enum RuntimePathError: Error, CustomStringConvertible, Equatable {
    case runtimeRootMustBeAbsolute(String)
    case runtimeRootIsNotDirectory(String)

    public var description: String {
        switch self {
        case .runtimeRootMustBeAbsolute(let value):
            return "HYPER_OVERLAY_RUNTIME_ROOT must be an absolute path: \(value)"
        case .runtimeRootIsNotDirectory(let value):
            return "HYPER_OVERLAY_RUNTIME_ROOT is not a directory: \(value)"
        }
    }
}

/// Isolates socket and lock state for uninstalled-runtime tests. The legacy
/// location remains exact when the override is absent; an invalid override is
/// always an error and is never silently ignored.
public struct RuntimePaths: Sendable, Equatable {
    public static let runtimeRootEnvironment = "HYPER_OVERLAY_RUNTIME_ROOT"

    public let rootURL: URL

    public var socketURL: URL {
        rootURL.appendingPathComponent("hyper-overlay.sock")
    }

    public var lockURL: URL {
        rootURL.appendingPathComponent("hyper-overlay.lock")
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RuntimePaths {
        if let override = environment[runtimeRootEnvironment] {
            guard override.hasPrefix("/") else {
                throw RuntimePathError.runtimeRootMustBeAbsolute(override)
            }
            let rootURL = URL(fileURLWithPath: override).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw RuntimePathError.runtimeRootIsNotDirectory(rootURL.path)
            }
            let paths = RuntimePaths(rootURL: rootURL)
            try UnixSocket.validatePath(paths.socketURL.path)
            return paths
        }

        let paths = RuntimePaths(rootURL: OverlayPaths.runtimeDirectory)
        try UnixSocket.validatePath(paths.socketURL.path)
        return paths
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

public final class RuntimeSingleInstanceLock {
    private let fd: Int32
    public let paths: RuntimePaths

    private init(fd: Int32, paths: RuntimePaths) {
        self.fd = fd
        self.paths = paths
    }

    deinit {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    public static func acquire() throws -> RuntimeSingleInstanceLock {
        let paths = try RuntimePaths.resolve()
        try paths.ensureDirectory()

        let fd = open(paths.lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw UnixSocketError.socketFailed(errno: errno) }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw UnixSocketError.bindFailed(errno: code)
        }

        let metadata = "pid=\(getpid())\nstarted_at=\(ISO8601DateFormatter().string(from: Date()))\n"
        _ = ftruncate(fd, 0)
        _ = metadata.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        return RuntimeSingleInstanceLock(fd: fd, paths: paths)
    }
}

public final class FocusOriginTracker {
    private var processID: pid_t?
    private let frontmostProcessID: @MainActor () -> pid_t?

    /// Narrow handoff for another surface on the same resident host.
    @MainActor public var capturedProcessID: pid_t? { processID }

    public init(frontmostProcessID: @escaping @MainActor () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }) {
        self.frontmostProcessID = frontmostProcessID
    }

    @MainActor public func captureOrigin(excluding currentProcessID: pid_t,
                                         preserveExistingWhenExcluded: Bool = true) {
        guard let frontmost = frontmostProcessID(), frontmost != currentProcessID else {
            if !preserveExistingWhenExcluded { processID = nil }
            return
        }
        processID = frontmost
    }

    /// Transfer an explicit external origin between surfaces owned by one host.
    /// This does not activate or read the application's selection.
    @MainActor public func adoptOrigin(_ origin: pid_t?, excluding currentProcessID: pid_t) {
        processID = origin == currentProcessID ? nil : origin
    }

    @MainActor public func restoreOrigin() {
        defer { processID = nil }
        guard let processID else { return }
        let application = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == processID && !$0.isTerminated
        }
        application?.activate(options: [.activateAllWindows])
    }
}

/// Explicit host copies advertise their source before restoring another app.
/// This is separate from the private marker used to suppress history recall.
@MainActor public enum HostPasteboardWriter {
    @discardableResult
    public static func writeText(_ text: String, to pasteboard: NSPasteboard = .general,
                                 sourceBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let sourceBundleID {
            item.setString(sourceBundleID, forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

public final class RuntimeOverlayPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}

@MainActor
public enum OverlayPanelFactory {
    public static func makePanel(size: NSSize) -> NSPanel {
        let panel = RuntimeOverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "Hyper Overlay"
        panel.setAccessibilityIdentifier("daniel.hyper-overlay.panel")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

public enum OverlayPanelPlacement {
    public static func frame(size: NSSize, visibleFrame: NSRect, margin: CGFloat = 12) -> NSRect {
        let maxX = max(visibleFrame.minX + margin, visibleFrame.maxX - size.width - margin)
        let maxY = max(visibleFrame.minY + margin, visibleFrame.maxY - size.height - margin)
        let centered = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        let origin = CGPoint(
            x: min(max(centered.x, visibleFrame.minX + margin), maxX),
            y: min(max(centered.y, visibleFrame.minY + margin), maxY)
        )
        return NSRect(origin: origin, size: size)
    }
}
