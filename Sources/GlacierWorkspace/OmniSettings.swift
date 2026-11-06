import AppKit
import Foundation
import OmniCore
import OmniModels
import OmniPresentation
import OmniRun
import UniformTypeIdentifiers

/// What the resident host adds to Settings: services this module never
/// links (clipboard history, Collect, the Hyper overlay). The development
/// host leaves it nil and those rows read as facts about where they run.
public struct OmniSettingsHostHooks {
    public var clipboard: OmniClipboardSettingsHost?
    /// `On · launch agent` or `Off`: the host is a KeepAlive launch agent.
    public var openAtLogin: (@MainActor () -> String)?
    public var shortcutsManifest: URL?
    public var overlaySize: NSSize
    public var makeOverlayView: (@MainActor () -> NSView)?

    public init(clipboard: OmniClipboardSettingsHost? = nil, openAtLogin: (@MainActor () -> String)? = nil,
                shortcutsManifest: URL? = nil, overlaySize: NSSize = .zero, makeOverlayView: (@MainActor () -> NSView)? = nil) {
        self.clipboard = clipboard
        self.openAtLogin = openAtLogin
        self.shortcutsManifest = shortcutsManifest
        self.overlaySize = overlaySize
        self.makeOverlayView = makeOverlayView
    }
}

public extension OmniPreferencesStore {
    /// `<root>/preferences/omni-preferences.json`; memory only when the root
    /// cannot hold it.
    static func forEnvironment(_ environment: GlacierWorkspaceEnvironment) -> OmniPreferencesStore {
        let url = (try? OmniDevelopmentRoot(validating: environment.configuration.developmentRoot,
                                            allowedRoot: environment.configuration.allowedRoot))
            .flatMap { try? $0.containedURL(relativePath: "preferences/omni-preferences.json") }
        return OmniPreferencesStore(url: url)
    }
}
