import AppKit
import Foundation
import GlacierBuiltins
import GlacierRuntime

/// Run with `swift run --disable-index-store glacier-example`.
/// The one registration line adds module settings, typed/slash routes and a native tool window.
@main
struct GlacierExampleApp {
    @MainActor static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-module-example-" + UUID().uuidString).appendingPathComponent("Glacier")
        let app = GlacierDesktop(supportOverride: root, preview: true,
                                 additionalModules: [AnyGlacierToolModule(TextTrimModule())])
        NSApplication.shared.delegate = app
        NSApplication.shared.setActivationPolicy(.accessory)
        withExtendedLifetime(app) { NSApplication.shared.run() }
    }
}
