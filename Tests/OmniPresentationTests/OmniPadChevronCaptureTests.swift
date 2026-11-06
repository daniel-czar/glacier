import AppKit
import OmniCore
import OmniPresentation
import Testing

/// Opt-in H12 captures: OMNI_CAPTURE_DIR=/some/dir swift test --filter designCaptureH12PadChevron
@Test @MainActor func designCaptureH12PadChevron() throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    let references = try ReferenceRegistry([
        PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)
    ])
    let parser = OmniParser(manifest: manifest, references: references)

    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let pad = OmniCommandPadViewController(parser: parser)
        pad.loadView()
        let panel = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }
        pad.setModelChoices([OmniModelChoice(id: "claude-capable", label: "Claude Sonnet medium")])
        pad.onResolveRoute = { _, id in
            OmniPadRoute(
                providerName: id == nil ? "Cerebras" : "Claude",
                scope: id == nil ? .policyDefault : .thisRunOnly,
                displayName: id == nil ? "Cerebras Qwen 3.8 27B" : "Claude Sonnet medium"
            )
        }
        pad.editor.string = "/email accept the invitation /style:formal"
        pad.textDidChange(Notification(name: NSText.didChangeNotification))

        try captureChevron(pad.view, name: "h12-chevron-default-\(suffix)", appearance: appearance, directory: directory)
        pad.selectModelProfile(id: "claude-capable")
        try captureChevron(pad.view, name: "h12-chevron-override-\(suffix)", appearance: appearance, directory: directory)
    }
}

/// H13 captures use the native pad and the actual popup's item data. The list
/// specimen is an offscreen AppKit rendering, not an OS-menu screenshot.
@Test @MainActor func designCaptureH13Readiness() throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let corpus = FrozenContractCorpus()
    let parser = OmniParser(manifest: try CommandManifest(data: corpus.data(named: "manifest")), references: try ReferenceRegistry([]))
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let pad = OmniCommandPadViewController(parser: parser)
        pad.loadView()
        let panel = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { pad.closeAnnotationPanels(); panel.orderOut(nil) }
        let choices = ProviderRuntimeCatalog.profiles.map { profile in
            let reason: String? = if profile.id == "local-fast" {
                "Local: service is not running"
            } else if let connection = ProviderRuntimeCatalog.connection(profile.connectionID), !connection.enabled {
                "\(connection.displayName): connection is off"
            } else { nil }
            return OmniModelChoice(id: profile.id, label: profile.displayName, unavailabilityReason: reason)
        }
        pad.setModelChoices(choices)
        var blocked = false
        pad.onResolveRoute = { _, _ in
            blocked
                ? OmniPadRoute(providerName: nil, scope: .thisRunOnly, displayName: "Claude Sonnet medium", unavailable: "Claude: not logged in", recoveryHint: "Log in with the Claude CLI")
                : OmniPadRoute(providerName: "Claude", scope: .thisRunOnly, displayName: "Claude Sonnet medium")
        }
        pad.editor.string = "/email accept the invitation /style:formal"
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
        pad.selectModelProfile(id: "claude-capable")
        try captureChevron(pad.view, name: "h13-route-override-\(suffix)", appearance: appearance, directory: directory)
        blocked = true
        pad.editor.string = "synthesize this idea"
        pad.textDidChange(Notification(name: NSText.didChangeNotification))
        try captureChevron(pad.view, name: "h13-route-physical-block-\(suffix)", appearance: appearance, directory: directory)

        let entries = Array(pad.modelPopUp.itemArray.dropFirst())
        let menu = OmniFrostedSurface(frame: NSRect(x: 0, y: 0, width: 730, height: CGFloat(entries.count * 34 + 20)), cornerRadius: 8)
        for (index, entry) in entries.enumerated() {
            let label = NSTextField(labelWithString: entry.title)
            label.font = .menuFont(ofSize: 14)
            label.textColor = entry.isEnabled ? .labelColor : .disabledControlTextColor
            label.frame = NSRect(x: 16, y: menu.bounds.height - CGFloat((index + 1) * 34) - 2, width: 698, height: 22)
            menu.addSubview(label)
        }
        try captureChevron(menu, name: "h13-model-list-specimen-\(suffix)", appearance: appearance, directory: directory)
    }
}

@MainActor private func captureChevron(_ view: NSView, name: String, appearance: NSAppearance.Name, directory: URL) throws {
    view.appearance = NSAppearance(named: appearance)
    func opaque(_ candidate: NSView) {
        (candidate as? OmniFrostedSurface)?.apply(transparency: .opaqueFallback)
        candidate.subviews.forEach(opaque)
    }
    opaque(view)
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds.integral
    let scale: CGFloat = 2
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    bitmap.size = bounds.size
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: bounds, to: bitmap)
    }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent("\(name).png"))
}
