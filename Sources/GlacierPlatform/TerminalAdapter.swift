import AppKit
import Foundation
import GlacierConfiguration
import HyperOverlayRuntime

public enum TerminalOpenError: Error, LocalizedError, Equatable {
    case invalidFolder
    case appUnavailable
    case unsupportedGhosttyVersion
    case automationUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidFolder: "Choose an accessible folder."
        case .appUnavailable: "The selected terminal app is unavailable."
        case .unsupportedGhosttyVersion: "Ghostty 1.3 or later is required to open a window at a folder."
        case .automationUnavailable: "The terminal did not accept the folder request. Check Automation access."
        }
    }
}

public protocol AppleScriptRunning: Sendable {
    func run(script: String, arguments: [String], timeout: TimeInterval) async -> Bool
}

public struct BoundedAppleScriptRunner: AppleScriptRunning {
    public init() {}

    public func run(script: String, arguments: [String], timeout: TimeInterval = 30) async -> Bool {
        let result = await HelperProcess.run(URL(fileURLWithPath: "/usr/bin/osascript"),
                                             arguments: ["-e", script] + arguments,
                                             stdin: "", environment: HelperProcess.baseEnvironment,
                                             timeout: timeout)
        return result?.status == 0
    }
}

/// Accepts a structured file URL. Folder bytes are passed as one osascript
/// argument, never interpolated into AppleScript source or a shell argv.
@MainActor
public struct TerminalAdapter {
    public let preference: GlacierTerminalPreference
    private let runner: any AppleScriptRunning
    private let ghosttyVersion: @MainActor () -> String?

    public init(preference: GlacierTerminalPreference,
                runner: any AppleScriptRunning = BoundedAppleScriptRunner(),
                ghosttyVersion: @escaping @MainActor () -> String? = {
                    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty"),
                          let bundle = Bundle(url: app) else { return nil }
                    return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
                }) {
        self.preference = preference
        self.runner = runner
        self.ghosttyVersion = ghosttyVersion
    }

    public func open(folder: URL) async throws {
        guard folder.isFileURL, !folder.path.isEmpty else { throw TerminalOpenError.invalidFolder }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalOpenError.invalidFolder
        }
        switch preference {
        case .systemTerminal:
            guard await runner.run(script: Self.terminalScript, arguments: [folder.path], timeout: 30) else {
                throw TerminalOpenError.automationUnavailable
            }
        case .ghostty:
            guard let version = ghosttyVersion() else { throw TerminalOpenError.appUnavailable }
            guard Self.supportsGhosttyAppleScript(version) else { throw TerminalOpenError.unsupportedGhosttyVersion }
            guard await runner.run(script: Self.ghosttyScript, arguments: [folder.path], timeout: 30) else {
                throw TerminalOpenError.automationUnavailable
            }
        }
    }

    public static func supportsGhosttyAppleScript(_ version: String) -> Bool {
        let numbers = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard numbers.count >= 2 else { return false }
        return numbers[0] > 1 || (numbers[0] == 1 && numbers[1] >= 3)
    }

    /// `quoted form` is performed inside AppleScript on the typed argv value.
    /// Swift never concatenates a folder into shell or script source.
    public static let terminalScript = """
    on run argv
        set folderPath to item 1 of argv
        tell application id "com.apple.Terminal"
            activate
            do script ("cd " & quoted form of folderPath)
        end tell
    end run
    """

    /// Ghostty 1.3+ exposes `initial working directory` directly, with no
    /// shell command. Version is probed before the Apple Event is attempted.
    public static let ghosttyScript = """
    on run argv
        set folderPath to item 1 of argv
        tell application id "com.mitchellh.ghostty"
            activate
            set cfg to new surface configuration
            set initial working directory of cfg to folderPath
            new window with configuration cfg
        end tell
    end run
    """
}
