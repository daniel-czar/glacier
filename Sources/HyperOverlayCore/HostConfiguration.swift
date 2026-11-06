import Foundation

public struct HostConfiguration: Sendable {
    public let resident: Bool
    public let hotkeysEnabled: Bool
    public let omniInstalledLive: Bool
    public let idleTimeout: TimeInterval
    public let manifestURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        func flag(_ name: String) throws -> Bool {
            guard let value = environment[name] else { return false }
            guard value == "0" || value == "1" else {
                throw ConfigurationError.invalid("\(name) must be 0 or 1")
            }
            return value == "1"
        }
        resident = try flag("HYPER_OVERLAY_RESIDENT")
        hotkeysEnabled = try flag("HYPER_OVERLAY_HOTKEYS")
        omniInstalledLive = try flag("OMNI_INSTALLED_LIVE")
        if omniInstalledLive && !resident {
            throw ConfigurationError.invalid("OMNI_INSTALLED_LIVE requires HYPER_OVERLAY_RESIDENT=1")
        }
        let configuredTimeout: TimeInterval
        if let value = environment["HYPER_OVERLAY_IDLE_SECONDS"] {
            guard let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 else {
                throw ConfigurationError.invalid("HYPER_OVERLAY_IDLE_SECONDS must be finite and nonnegative")
            }
            configuredTimeout = seconds
        } else {
            configuredTimeout = 300
        }
        idleTimeout = resident ? 0 : configuredTimeout
        if let value = environment["HYPER_OVERLAY_MANIFEST"] {
            guard value.hasPrefix("/") else {
                throw ConfigurationError.invalid("HYPER_OVERLAY_MANIFEST must be an absolute path")
            }
            manifestURL = URL(fileURLWithPath: value)
        } else {
            manifestURL = OverlayPaths.keyboardMaestroRoot.appendingPathComponent("hyper-overlays.json")
        }
    }
}

public enum ConfigurationError: Error, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self { case .invalid(let detail): return detail }
    }
}
