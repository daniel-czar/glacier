import AppKit
import ApplicationServices

/// Resolved app identity. The manifest stores only bundle IDs; names and icons
/// are display facts from LaunchServices, never persisted by this palette.
public struct LaunchApplication {
    public let bundleID: String
    public let name: String
    public let url: URL
    public let icon: NSImage
    public let key: String?

    public init(bundleID: String, name: String, url: URL, icon: NSImage, key: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
        self.icon = icon
        self.key = key
    }
}

public struct LaunchPaletteLoadProblem: Equatable, Sendable {
    public let bundleID: String
    public let message: String

    public init(bundleID: String, message: String) {
        self.bundleID = bundleID
        self.message = message
    }
}

/// The keys track positions, not app names. Two rows are used whenever there
/// are more than one row's worth of entries; no cell is manufactured for a gap.
public enum LaunchPaletteLayout {
    public static let cellHeight: CGFloat = 136
    public static let cellWidth: CGFloat = 141
    public static let gap: CGFloat = 12
    public static let padding: CGFloat = 20

    public static func columns(forCount count: Int) -> Int {
        switch count {
        case ...2: return max(1, count)
        case 3...4: return 2
        case 5...6: return 3
        default: return 4
        }
    }

    public static func keys(forCount count: Int) -> [String] {
        let top = ["Q", "W", "E", "R"]
        let bottom = ["A", "S", "D", "F"]
        let bounded = min(max(count, 0), 8)
        let columns = columns(forCount: bounded)
        return Array((top.prefix(columns) + bottom.prefix(max(0, bounded - columns))).prefix(bounded))
    }

    public static func keys(for applications: [LaunchApplication]) -> [String] {
        let defaults = keys(forCount: applications.count)
        return applications.enumerated().map { index, app in
            app.key.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() } ?? defaults[index]
        }
    }

    public static func keyProblems(for applications: [LaunchApplication]) -> [LaunchPaletteLoadProblem] {
        var problems: [LaunchPaletteLoadProblem] = []
        var seen = Set<String>()
        if applications.count > 8 {
            problems.append(.init(bundleID: "", message: "Launch accepts at most eight applications"))
        }
        for (index, key) in keys(for: Array(applications.prefix(8))).enumerated() {
            let id = applications[index].bundleID
            guard key.count == 1, let character = key.first, character >= "A", character <= "Z" else {
                problems.append(.init(bundleID: id, message: "Launch key for \(id) must be one letter A–Z"))
                continue
            }
            if !seen.insert(key).inserted {
                problems.append(.init(bundleID: id, message: "Launch key \(key) is assigned more than once"))
            }
        }
        return problems
    }

    public static func index(forKeyCode keyCode: UInt16, count: Int) -> Int? {
        keys(forCount: count).firstIndex { physicalKeyCodes[$0] == keyCode }
    }

    public static func index(forKeyCode keyCode: UInt16, applications: [LaunchApplication]) -> Int? {
        keys(for: applications).firstIndex { physicalKeyCodes[$0] == keyCode }
    }

    private static let physicalKeyCodes: [String: UInt16] = [
        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4,
        "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35,
        "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7,
        "Y": 16, "Z": 6
    ]

    public static func size(forCount count: Int) -> NSSize {
        let bounded = min(max(count, 0), 8)
        let columns = columns(forCount: bounded)
        let rows = bounded > columns ? 2 : 1
        return NSSize(width: padding * 2 + CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gap,
                      height: padding * 2 + CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gap)
    }
}

@MainActor
public protocol LaunchApplicationEffects {
    func resolve(bundleID: String) -> LaunchApplication?
    func isRunning(bundleID: String) -> Bool
    func isFrontmost(bundleID: String) -> Bool
    func activate(_ app: LaunchApplication, completion: @escaping @MainActor (Error?) -> Void)
}

/// Real workspace effects. A running app receives Dock-like all-window
/// activation and its minimized AX windows are restored before activation.
@MainActor
public struct SystemLaunchApplicationEffects: LaunchApplicationEffects {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    public func resolve(bundleID: String) -> LaunchApplication? {
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: url.path)
        return LaunchApplication(bundleID: bundleID, name: name, url: url, icon: workspace.icon(forFile: url.path))
    }

    public func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    public func isFrontmost(bundleID: String) -> Bool {
        workspace.frontmostApplication?.bundleIdentifier == bundleID
    }

    public func activate(_ app: LaunchApplication, completion: @escaping @MainActor (Error?) -> Void) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .first(where: { !$0.isTerminated }) {
            Self.unminimizeWindows(pid: running.processIdentifier)
            _ = running.activate(options: [.activateAllWindows])
            // LaunchServices supplies Dock-click activation semantics even if
            // a background app ignores cooperative NSRunningApplication.
            open(app, completion: completion)
            return
        }
        open(app, completion: completion)
    }

    private func open(_ app: LaunchApplication, completion: @escaping @MainActor (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        workspace.openApplication(at: app.url, configuration: configuration) { _, error in
            Task { @MainActor in completion(error) }
        }
    }

    private static func unminimizeWindows(pid: pid_t) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.25)
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }
}
