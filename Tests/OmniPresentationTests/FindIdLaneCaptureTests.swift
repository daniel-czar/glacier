import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

// Opt-in design captures for the find id lane programme (decision surface
// 2222222222222222): `OMNI_CAPTURE_DIR=/dir … --filter designCaptureFind`.
// Without the variable these tests do nothing.

@MainActor
private func writeCapture(_ view: NSView, name: String, appearance: NSAppearance.Name, directory: URL) throws {
    view.appearance = NSAppearance(named: appearance)
    func opaque(_ candidate: NSView) {
        (candidate as? OmniFrostedSurface)?.apply(transparency: .opaqueFallback)
        candidate.subviews.forEach(opaque)
    }
    opaque(view)
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds.integral
    let scale: CGFloat = 2
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    representation.size = bounds.size
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: bounds, to: representation)
    }
    let png = try #require(representation.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent("\(name).png"))
}

/// Paints the window background in the view's own appearance.
private final class OmniCaptureBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

@MainActor private func captureView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = captureView(id, in: child) { return found }
    }
    return nil
}

private func findCaptureDirectory() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// M0: the preposition-led header for a local `/find` from Claude and a
/// model `/email` from Mail, plus the pad chip drawn by the same formatter.
@Test @MainActor func designCaptureFindHeader() throws {
    guard let out = findCaptureDirectory() else { return }
    _ = NSApplication.shared
    let cases: [(name: String, token: String, line: OmniProvenanceLine?, route: String, result: String)] = [
        ("header-find-claude", "/find", OmniProvenanceLine(appName: "Claude", windowTitle: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop"), OmniWorkspaceRunHeader.localRoute, "/Users/example/Tooling/agent-output/1111111111111111_demo-search"),
        ("header-email-mail", "/email", OmniProvenanceLine(appName: "Mail", windowTitle: "Re: invoice", bundleIdentifier: "com.apple.mail"), "Cerebras", "Hi Sam,\n\nThanks, the invoice is paid.\n\nBest,\nDaniel"),
    ]
    for item in cases {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // A fresh panel per appearance: the workspace draws its text with
            // dynamic colours resolved when the detail is built.
            let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
            workspace.workspacePanel.appearance = NSAppearance(named: appearance)
            workspace.displayRuns([OmniWorkspaceRunRow(id: "r1", title: item.name, status: "done", summary: item.result, token: item.token, submittedAt: Date(), activity: .done)], selectedID: "r1")
            workspace.displayResult(
                runID: "r1", title: item.token == "/find" ? "Find · adversarial reviews" : "Reply · Re: invoice", status: "done",
                versions: [OmniWorkspaceVersion(number: 1, inputText: item.token, resultText: item.result, operation: "initial")],
                selectedVersion: 1,
                header: OmniWorkspaceRunHeader(token: item.token, provenance: item.line, submittedAt: Date(), route: item.route),
                // A /find run is a picker of its rows, with no Continue (C80).
                pickerRows: item.token == "/find" ? [OmniFindRow(path: item.result, title: "Omni find id lane", kind: "run-folder", namespace: .run, id: "0c0af4acc2caeaed")] : []
            )
            let panel = try #require(workspace.workspacePanel.contentView)
            if appearance == .aqua {
                try writeCapture(panel, name: "\(item.name)-\(suffix)", appearance: appearance, directory: out)
            }
            // The workspace's system material does not render through
            // cacheDisplay, so the header line is also captured on its own
            // over the window background, in both appearances.
            let subtitle = try #require(captureView("omni.workspace.result-subtitle", in: panel) as? NSTextField)
            let time = try #require(captureView("omni.workspace.result-time", in: panel) as? NSTextField)
            let line = NSTextField(labelWithAttributedString: subtitle.attributedStringValue)
            let clock = NSTextField(labelWithString: time.stringValue)
            clock.font = time.font
            clock.textColor = time.textColor
            clock.alignment = .right
            let host = OmniCaptureBackground(frame: NSRect(x: 0, y: 0, width: 560, height: 40))
            let clockWidth = ceil(clock.intrinsicContentSize.width)
            clock.frame = NSRect(x: 544 - clockWidth, y: 11, width: clockWidth, height: 18)
            line.frame = NSRect(x: 16, y: 11, width: 528 - clockWidth - 16, height: 18)
            host.addSubview(line)
            host.addSubview(clock)
            try writeCapture(host, name: "\(item.name)-line-\(suffix)", appearance: appearance, directory: out)
        }
    }
    let chip = OmniProvenanceChip()
    chip.provenance = OmniPadProvenance(source: "Mail", detail: "Re: invoice", wordCount: 42, bundleIdentifier: "com.apple.mail")
    chip.frame = NSRect(x: 0, y: 0, width: chip.fittingWidth, height: 26)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: chip.fittingWidth + 24, height: 42))
    chip.frame.origin = NSPoint(x: 12, y: 8)
    host.addSubview(chip)
    try writeCapture(host, name: "pad-chip-mail-light", appearance: .aqua, directory: out)
    try writeCapture(host, name: "pad-chip-mail-dark", appearance: .darkAqua, directory: out)
}

@MainActor
private func captureParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    return OmniParser(manifest: manifest, references: try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)]))
}

/// M1: the exact-id lane's hit (document then run folder, ready) and miss.
@Test @MainActor func designCaptureFindIDLane() throws {
    guard let out = findCaptureDirectory() else { return }
    _ = NSApplication.shared
    let id = "2222222222222222"
    let surface = LauncherCandidate(title: "Demo search — design notes", path: "/Users/example/Tooling/agent-output/1111111111111111_demo-search/demo-search-design_\(id).md", kind: "spec", source: .docsIndex, modified: Date().addingTimeInterval(-3_600), documentID: id)
    let run = LauncherCandidate(title: "\(id)_demo-search", path: "/Users/example/Tooling/agent-output/\(id)_demo-search", kind: "run-folder", source: .roots, modified: Date().addingTimeInterval(-600))
    let map = LauncherIDMap(curated: [], everywhere: [surface, run])
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let controller = OmniCommandPadViewController(parser: try captureParser())
        controller.loadView()
        let panel = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { panel.orderOut(nil) }
        controller.launcherHome = "/Users/example"
        controller.onLauncherQuery = { [weak controller] text in
            guard let controller, let address = OmniIDAddress(text) else { return }
            controller.showLauncherResults(map.results(for: address, query: LauncherQuery(text).text, lane: controller.launcherLane))
        }
        controller.launcherEnabled = true
        for (name, text) in [("id-lane-hit", id), ("id-lane-miss", "0123456789abcdef")] {
            controller.editor.string = text
            controller.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            controller.textDidChange(Notification(name: NSText.didChangeNotification))
            try writeCapture(controller.view, name: "\(name)-\(suffix)", appearance: appearance, directory: out)
        }
    }
}

/// M2: the facet menu at both levels, and the `/find` picker in the pad.
@Test @MainActor func designCaptureFindFacetsAndPicker() throws {
    guard let out = findCaptureDirectory() else { return }
    _ = NSApplication.shared
    let facets = FindFacets(
        kinds: [FindFacetValue(value: "note", count: 120), FindFacetValue(value: "adr", count: 80), FindFacetValue(value: "review", count: 42), FindFacetValue(value: "report", count: 18), FindFacetValue(value: "spec", count: 16)],
        projects: [FindFacetValue(value: "sample-project", count: 90), FindFacetValue(value: "example-project", count: 24)],
        tags: [FindFacetValue(value: "ml", count: 35), FindFacetValue(value: "adversarial-review", count: 12)]
    )
    let rows = [
        OmniFindRow(path: "/Users/example/Tooling/agent-output/3333333333333333_demo-writing/demo-writing-review_4444444444444444.md", title: "Demo writing — review", kind: "review", id: "4444444444444444", modified: Date().addingTimeInterval(-86_400 * 3)),
        OmniFindRow(path: "/Users/example/Tooling/agent-output/5555555555555555_demo-layout/review/6666666666666666_demo-layout-review.md", title: "Demo layout review", kind: "review", id: "6666666666666666", modified: Date().addingTimeInterval(-86_400 * 9)),
    ]
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let controller = OmniCommandPadViewController(parser: try captureParser())
        controller.loadView()
        let panel = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { panel.orderOut(nil) }
        controller.completionScreenTop = 2_000
        controller.launcherHome = "/Users/example"
        controller.onRequestFindFacets = { facets }
        func set(_ text: String) {
            controller.editor.string = text
            controller.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            controller.textDidChange(Notification(name: NSText.didChangeNotification))
        }
        set("/find ")
        _ = controller.editor.onTab?()
        if let menu = controller.completionMenu?.contentView {
            try writeCapture(menu, name: "find-facets-\(suffix)", appearance: appearance, directory: out)
        }
        _ = controller.acceptCompletion()
        if let menu = controller.completionMenu?.contentView {
            try writeCapture(menu, name: "find-facet-values-\(suffix)", appearance: appearance, directory: out)
        }
        controller.dismissCompletion()
        set("/find kind:review in:sample-project ")
        try writeCapture(controller.view, name: "find-composed-\(suffix)", appearance: appearance, directory: out)
        // M4: pills over the complete, known filters; the half-typed value
        // and the free words stay plain.
        set("/find kind:review in:sample-project tags:rev adversarial ML run")
        try writeCapture(controller.view, name: "find-pills-\(suffix)", appearance: appearance, directory: out)
        set("/find kind:review in:sample-project ")
        controller.beginWorking(runID: "capture", requestText: controller.editor.string)
        controller.showPicker(runID: "capture", find: OmniFindResult(tier: .filters, typed: "kind:review in:sample-project", query: "kind:review in:sample-project", rows: rows, total: 2))
        try writeCapture(controller.view, name: "find-picker-\(suffix)", appearance: appearance, directory: out)
    }
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    workspace.displayRuns([OmniWorkspaceRunRow(id: "r1", title: "Find · kind:review in:sample-project", status: "done", summary: rows[0].path, token: "/find", submittedAt: Date(), activity: .done)], selectedID: "r1")
    workspace.displayResult(
        runID: "r1", title: "Find · kind:review in:sample-project", status: "done",
        versions: [OmniWorkspaceVersion(number: 1, inputText: "/find kind:review in:sample-project", resultText: rows.map(\.path).joined(separator: "\n"), operation: "initial")],
        selectedVersion: 1,
        header: OmniWorkspaceRunHeader(token: "/find", provenance: nil, submittedAt: Date(), route: OmniWorkspaceRunHeader.localRoute),
        pickerRows: rows
    )
    let content = try #require(workspace.workspacePanel.contentView)
    try writeCapture(content, name: "find-workspace-light", appearance: .aqua, directory: out)
}
