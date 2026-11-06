import AppKit
import OmniPresentation
import Testing

@MainActor
private func writePNG(_ view: NSView, name: String, appearance: NSAppearance.Name, directory: URL,
                      treatment: OmniMaterialTreatment = .opaqueFallback) throws {
    view.appearance = NSAppearance(named: appearance)
    func applyTreatment(_ candidate: NSView) {
        (candidate as? OmniFrostedSurface)?.apply(transparency: treatment)
        candidate.subviews.forEach(applyTreatment)
    }
    applyTreatment(view)
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

/// Opt-in design captures: `GLACIER_CAPTURE_DIR=/some/dir swift test --filter designCapture`
/// renders the sidebar and pad states to PNG for a look
/// against the canvas. Without the variable these tests do nothing.
private func captureDirectory() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["GLACIER_CAPTURE_DIR"], !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor private func viewWithIdentifier(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = viewWithIdentifier(id, in: child) { return found }
    }
    return nil
}

@Test @MainActor func designCaptureWorkspaceSidebar() throws {
    guard let out = captureDirectory() else { return }
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    let now = Date()
    let rows: [OmniWorkspaceRunRow] = [
        OmniWorkspaceRunRow(id: "r1", title: "Reply · Coffee on Thursday", status: "done", summary: "Hi Mira, Thursday at 15:30 works. Looking forward to coffee.", token: "/email", submittedAt: now.addingTimeInterval(-60), activity: .done),
        OmniWorkspaceRunRow(id: "r2", title: "gartenschlauch", status: "done", summary: "garden hose", token: "/translate", submittedAt: now.addingTimeInterval(-300), activity: .done),
        OmniWorkspaceRunRow(id: "r3", title: "summarise this note", status: "running", summary: "Working…", token: "/qq", submittedAt: now.addingTimeInterval(-400), activity: .running),
        OmniWorkspaceRunRow(id: "r4", title: "Could you confirm the delivery", status: "failed", summary: "Route unavailable", token: "/translate", submittedAt: now.addingTimeInterval(-700), activity: .failed),
        OmniWorkspaceRunRow(id: "r5", title: "Check the revised agenda", status: "done", summary: "Kept in mind", token: "/remind", submittedAt: now.addingTimeInterval(-86_400 * 1.2), activity: .done),
        OmniWorkspaceRunRow(id: "r6", title: "Zoe · proposed time", status: "done", summary: "Hi Zoe — I can't make the proposed time, could we do Friday?", token: "/msg", submittedAt: now.addingTimeInterval(-86_400 * 2.5), activity: .done),
    ]
    workspace.displayRuns(rows, selectedID: "r1")
    workspace.displayResult(
        runID: "r1", title: "Reply · Coffee on Thursday", status: "done",
        versions: [OmniWorkspaceVersion(number: 1, inputText: "/email accept the invitation", resultText: "Hi Mira,\n\nThursday at 15:30 works. Looking forward to coffee.\n\nBest,\nDaniel", operation: "initial")],
        selectedVersion: 1
    )
    let panel = try #require(workspace.workspacePanel.contentView)
    try writePNG(panel, name: "workspace-light", appearance: .aqua, directory: out)
}

import OmniCore

@MainActor
private func scratchParser() throws -> OmniParser {
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let snapshot = ReferenceSnapshot(sourceVersion: "fixture", resolvedAt: Date(timeIntervalSince1970: 0))
    let references = try ReferenceRegistry([PinnedReference(id: "person_1", namespace: "people", key: "zoe", snapshot: snapshot)])
    return OmniParser(manifest: manifest, references: references)
}

@Test @MainActor func designCapturePadStates() throws {
    guard let out = captureDirectory() else { return }
    _ = NSApplication.shared
    let controller = OmniCommandPadViewController(parser: try scratchParser())
    controller.loadView()
    let pad = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { controller.closeAnnotationPanels(); pad.orderOut(nil) }
    _ = pad
    var route = OmniPadRoute(providerName: "Cerebras")
    controller.onResolveRoute = { _, _ in route }
    let change = Notification(name: NSText.didChangeNotification)
    func set(_ text: String) {
        controller.editor.string = text
        controller.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        controller.textDidChange(change)
    }

    set("")
    try writePNG(controller.view, name: "pad-1-empty", appearance: .aqua, directory: out)

    let mail = "Hey Daniel — would you like to grab coffee Thursday afternoon? I wanted to bounce the Bessel draft sequencing off you before Friday.\n\nI can do 15:30 near the office, or later if that's kinder to your stack.\n\nMira"
    controller.setProvenance(OmniPadProvenance(source: "Mail", detail: "Mira Chen", wordCount: 40))
    set(mail)
    try writePNG(controller.view, name: "pad-2-selection", appearance: .aqua, directory: out)

    set(mail + "\n\n/email accept the invitation /formal")
    try writePNG(controller.view, name: "pad-6-composed", appearance: .aqua, directory: out)
    try writePNG(controller.view, name: "pad-6-composed-dark", appearance: .darkAqua, directory: out)
    try writePNG(controller.view, name: "pad-6-composed-native-light", appearance: .aqua, directory: out, treatment: .nativeMaterial)
    try writePNG(controller.view, name: "pad-6-composed-native-dark", appearance: .darkAqua, directory: out, treatment: .nativeMaterial)

    controller.showTransientNotice("Replaced your unsent draft · ⌘Z restores it")
    try writePNG(controller.view, name: "pad-3-replaced", appearance: .aqua, directory: out)

    controller.setProvenance(nil)
    set("/t")
    try writePNG(controller.view, name: "pad-5-typing", appearance: .aqua, directory: out)
    if let menu = controller.completionMenu?.contentView {
        try writePNG(menu, name: "pad-5-menu", appearance: .aqua, directory: out)
    }
    controller.dismissCompletion()

    set("/summarise the thread and find a coffee place near the office")
    try writePNG(controller.view, name: "pad-7a-unknown", appearance: .aqua, directory: out)

    route = OmniPadRoute(providerName: "Local", scope: .thisRunOnly)
    set("/email accept the invitation /formal /offline")
    try writePNG(controller.view, name: "pad-8-override", appearance: .aqua, directory: out)

    route = OmniPadRoute(providerName: nil, unavailable: "Cerebras isn't set up for /email")
    set("/email accept the invitation /formal")
    try writePNG(controller.view, name: "pad-9-not-ready", appearance: .aqua, directory: out)

    route = OmniPadRoute(providerName: "Cerebras")
    set("/summarise the thread and find a coffee place near the office")
    controller.beginWorking(runID: "p", requestText: controller.editor.string)
    try writePNG(controller.view, name: "pad-7-waiting", appearance: .aqua, directory: out)
    controller.showProposalChooser(runID: "p", alternatives: [
        OmniPadAlternative(id: "a", planHash: "1", title: "Summarise the thread", steps: ["/qq summarise the thread"]),
        OmniPadAlternative(id: "b", planHash: "2", title: "Coffee near the office", steps: ["/g coffee near the office"]),
        OmniPadAlternative(id: "c", planHash: "3", title: "Both, in that order", steps: ["/qq summarise the thread", "/g coffee near the office"]),
    ])
    try writePNG(controller.view, name: "pad-7b-chooser", appearance: .aqua, directory: out)
    controller.returnToComposing()
}

@Test @MainActor func designCaptureAnnotationStates() throws {
    guard let out = captureDirectory() else { return }
    _ = NSApplication.shared
    let controller = OmniCommandPadViewController(parser: try scratchParser())
    controller.loadView()
    let pad = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { controller.closeAnnotationPanels(); pad.orderOut(nil) }
    _ = pad
    controller.onResolveRoute = { _, _ in OmniPadRoute(providerName: "Cerebras") }
    let mail = "Hey Daniel — would you like to grab coffee Thursday afternoon? I wanted to bounce the Bessel draft sequencing off you before Friday.\n\nI can do 15:30 near the office, or later if that's kinder to your stack.\n\nMira\n\n/email accept the invitation /formal"
    controller.setProvenance(OmniPadProvenance(source: "Mail", detail: "Mira Chen", wordCount: 40))
    controller.editor.string = mail
    controller.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.editor))
    let source = mail as NSString
    let bessel = OmniTextAnnotation(range: source.range(of: "I wanted to bounce the Bessel draft sequencing off you before Friday."), guidance: "Keep the Bessel reference — it's the reason for the meeting.")
    let time = OmniTextAnnotation(range: source.range(of: "I can do 15:30 near the office, or later if that's kinder to your stack."), guidance: "Decline this part politely — I can't do Thursday before 16:00.")
    controller.setAnnotations([bessel, time])

    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        controller.editor.setSelectedRange(NSRange(location: source.length, length: 0))
        controller.editor.activeAnnotationID = nil
        try writePNG(controller.view, name: "annotations-tinted-\(suffix)", appearance: appearance, directory: out)

        controller.editor.setSelectedRange(time.range)
        controller.openAnnotationForSelection()
        try writePNG(controller.view, name: "annotations-card-pad-\(suffix)", appearance: appearance, directory: out)
        let card = try #require(controller.annotationCardPanel?.contentView)
        try writePNG(card, name: "annotations-card-\(suffix)", appearance: appearance, directory: out)
        controller.closeAnnotationPanels()

        controller.showAnnotationHover(bessel.id)
        try writePNG(controller.view, name: "annotations-hover-pad-\(suffix)", appearance: appearance, directory: out)
        let hover = try #require(controller.annotationHoverPanel?.contentView)
        try writePNG(hover, name: "annotations-hover-\(suffix)", appearance: appearance, directory: out)
        controller.closeAnnotationPanels()

        controller.notesButton.performClick(nil)
        let overview = try #require(controller.annotationOverviewPanel?.contentView)
        let secondRow = try #require(viewWithIdentifier("omni.annotation.overview-row.1", in: overview))
        let mouseEnter = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.annotationOverviewPanel?.windowNumber ?? 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        secondRow.mouseEntered(with: mouseEnter)
        #expect(controller.editor.activeAnnotationID == time.id)
        try writePNG(controller.view, name: "annotations-overview-pad-\(suffix)", appearance: appearance, directory: out)
        try writePNG(overview, name: "annotations-overview-\(suffix)", appearance: appearance, directory: out)
        secondRow.mouseExited(with: mouseEnter)
        controller.closeAnnotationPanels()
    }
}

/// H11: the seven required results-in-pad design states in both appearances.
@Test @MainActor func designCaptureH11ResultsInPad() throws {
    guard let out = captureDirectory() else { return }
    _ = NSApplication.shared
    let prose = "Dear Mira,\n\nThank you for the invitation. Thursday at 15:30 near the office suits me well, and I would be glad to go through the Bessel draft sequencing with you before Friday.\n\n" + String(repeating: "We can take the time to discuss the details and agree on the next steps.\n\n", count: 8) + "Kind regards,\nDaniel"
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let controller = OmniCommandPadViewController(parser: try scratchParser())
        controller.loadView()
        controller.view.appearance = NSAppearance(named: appearance)
        let panel = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { controller.closeAnnotationPanels(); panel.orderOut(nil) }
        func begin(_ request: String, summary: String, annotations: [OmniTextAnnotation] = [], provenance: OmniPadProvenance? = nil) {
            controller.returnToComposing()
            controller.setProvenance(provenance)
            controller.editor.string = request
            controller.beginWorking(runID: "h11", requestText: request, annotations: annotations, summary: summary, provenance: provenance)
            controller.editor.string = ""
            controller.setProvenance(nil)
        }
        begin("/translate gartenschlauch", summary: "Translation · Cerebras")
        try writePNG(controller.view, name: "h11-working-\(suffix)", appearance: appearance, directory: out)
        controller.showResult(runID: "h11", result: OmniPadResult(kind: .text, body: "garden hose", summary: "Translation · Cerebras"))
        try writePNG(controller.view, name: "h11-text-one-line-\(suffix)", appearance: appearance, directory: out)

        begin("Hey Daniel — would you like to grab coffee Thursday afternoon?\n\nI can do 15:30 near the office.\n\nMira\n\n/email accept the invitation /formal", summary: "Email draft · formal · Cerebras", provenance: OmniPadProvenance(source: "Mail", detail: "Mira Chen", wordCount: 40))
        controller.showResult(runID: "h11", result: OmniPadResult(kind: .text, body: prose, summary: "Email draft · formal · Cerebras"))
        try writePNG(controller.view, name: "h11-text-long-\(suffix)", appearance: appearance, directory: out)

        begin("/todo Review the Bessel draft tomorrow", summary: "Todo · Ledger")
        controller.showResult(runID: "h11", result: OmniPadResult(kind: .confirmation, body: "/todo · added to Ledger", summary: "Saved · Ledger"))
        try writePNG(controller.view, name: "h11-confirmation-\(suffix)", appearance: appearance, directory: out)

        begin("/email accept the invitation /formal", summary: "Email draft · Cerebras")
        controller.showResult(runID: "h11", result: OmniPadResult(kind: .failure(retryAllowed: true), body: "The provider could not finish this request. Try again when the connection is available.", summary: "Unable to finish"))
        try writePNG(controller.view, name: "h11-failure-retry-\(suffix)", appearance: appearance, directory: out)

        begin("Summarise the thread and find a coffee place", summary: "Proposal")
        controller.showProposalChooser(runID: "h11", alternatives: [
            OmniPadAlternative(id: "a", planHash: "a", title: "Summarise the thread", steps: ["/qq summarise the thread"]),
            OmniPadAlternative(id: "b", planHash: "b", title: "Coffee near the office", steps: ["/g coffee near the office"]),
            OmniPadAlternative(id: "c", planHash: "c", title: "Both, in that order", steps: ["/qq summarise the thread", "/g coffee near the office"]),
        ])
        try writePNG(controller.view, name: "h11-proposal-result-\(suffix)", appearance: appearance, directory: out)

        let request = "/email Politely decline Thursday before 16:00 /formal"
        let note = OmniTextAnnotation(range: (request as NSString).range(of: "Thursday before 16:00"), guidance: "Keep this timing constraint.")
        begin(request, summary: "Email draft · formal · Cerebras", annotations: [note], provenance: OmniPadProvenance(source: "Mail", detail: "Mira Chen", wordCount: 40))
        controller.showResult(runID: "h11", result: OmniPadResult(kind: .text, body: "Dear Mira,\n\nThank you for the invitation. I can join after 16:00 on Thursday.\n\nKind regards,\nDaniel", summary: "Email draft · formal · Cerebras"))
        try writePNG(controller.view, name: "h11-annotated-request-\(suffix)", appearance: appearance, directory: out)
    }
}

/// Decision step (D3, D6): the offer row, the positions with noticed ticks,
/// the edit-first state and the draft's route line, in both appearances.
@Test @MainActor func designCaptureDecisionStep() throws {
    guard let out = captureDirectory() else { return }
    _ = NSApplication.shared
    let controller = OmniCommandPadViewController(parser: try scratchParser())
    controller.loadView()
    let pad = OmniPanelFactory.makePad(controller: controller, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { controller.closeAnnotationPanels(); pad.orderOut(nil) }
    controller.onResolveRoute = { _, _ in OmniPadRoute(providerName: "Cerebras") }
    let change = Notification(name: NSText.didChangeNotification)
    func set(_ text: String) {
        controller.editor.string = text
        controller.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        controller.textDidChange(change)
    }
    func both(_ name: String) throws {
        try writePNG(controller.view, name: name, appearance: .aqua, directory: out)
        try writePNG(controller.view, name: name + "-dark", appearance: .darkAqua, directory: out)
    }
    let mail = "Hey Daniel — would you like to grab coffee Thursday afternoon? I wanted to bounce the Bessel draft sequencing off you before Friday.\n\nI can do 15:30 near the office, or later if that's kinder to your stack.\n\nMira"
    controller.setProvenance(OmniPadProvenance(source: "Mail", detail: "Mira Chen", wordCount: 40))
    set(mail)
    try both("decision-1-offer-row")

    controller.beginWorking(runID: "s", requestText: mail + " /stance", summary: "Positions")
    controller.showOptions(runID: "s", options: OmniPadOptions(
        heading: "POSITIONS · PICK ONE",
        options: [
            .init(id: "1", title: "Accept 15:30 near the office", detail: "Say yes to the time Mira offered, plainly, and keep the Bessel topic."),
            .init(id: "2", title: "Decline without a reason", detail: "Say you can't make Thursday; add no reason and no alternative."),
            .init(id: "3", title: "Ask for later in the day", detail: "Take up her 'or later' offer and ask what later means for her."),
            .init(id: "4", title: "Hold briefly", detail: "A short note that you'll confirm tomorrow."),
        ],
        noticed: [
            .init(id: "a", label: "Suppression", note: "Mira plays down her own constraint.", quote: "if that's kinder to your stack"),
            .init(id: "b", label: "Purpose or lifecycle", note: "The meeting exists for the Bessel sequencing before Friday."),
        ],
        summary: "Positions · a pick drafts an email",
        pickVerb: "Draft"
    ))
    controller.toggleNoticed(index: 1)
    try both("decision-2-positions-ticks")

    controller.returnToComposing()
    set(mail + " /email ✗")
    controller.setAnnotations([.request(guidance: "Reply declining.", origin: .proposed, label: "Decline without a reason")])
    try both("decision-3-edit-first")

    controller.beginWorking(runID: "d", requestText: controller.editor.string, annotations: controller.annotations, summary: "Email draft · Decline without a reason")
    controller.showResult(runID: "d", result: OmniPadResult(kind: .text, body: "Hi Mira,\n\nI can't make Thursday.\n\nDaniel", summary: "Email draft · Decline without a reason"))
    try both("decision-4-draft-route-line")

    controller.returnToComposing()
    controller.setProvenance(nil)
    set("Receipts make agents honest because nobody can rewrite what already happened /expand")
    controller.editor.onSubmit?(.enterShowHere)
    try both("decision-5-expand-lenses")
    _ = controller.dismissLocalOptions()
}

/// The three H17 states (stack, workspace row, pad import) for a look against
/// `assets/stash-reference/StashStack.dc.html`.
@Test @MainActor func designCaptureStashStates() throws {
    guard let out = captureDirectory() else { return }
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stash-capture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stack = OmniStashStack(url: directory.appendingPathComponent("current.json"))
    let now = Date()
    for (text, source, age) in [
        ("Besserwisser → know-it-all · smart aleck · wise guy", "Translate", 86_400.0 * 3),
        ("https://api.forvo.com/documentation/branding/", "Safari", 86_400.0),
        ("find . -type f -exec basename {} \\;", "Recall", 86_400.0 * 1.1),
        ("Coordinator: your D-18 hook at 0558 is confirmed; the hangar brief moves to 0530 and transport will collect from the north gate. Bring the signed route card and the spare radio battery.", "Claude", 600.0),
    ] {
        try stack.push(OmniStashEntry(text: text, source: source, createdAt: now.addingTimeInterval(-age)))
    }
    let tool = OmniStashWindowController(session: OmniStashSession(stack: stack), presentsInterface: false)
    tool.show()
    tool.viewController.view.setFrameSize(NSSize(width: 640, height: tool.viewController.view.frame.height))
    tool.viewController.render()
    try writePNG(tool.viewController.view, name: "stash-1-stack-dark", appearance: .darkAqua, directory: out)
    try writePNG(tool.viewController.view, name: "stash-1-stack-light", appearance: .aqua, directory: out)
    tool.session.moveSelection(by: 1)
    _ = tool.session.dropSelected()
    try writePNG(tool.viewController.view, name: "stash-2-dropped-dark", appearance: .darkAqua, directory: out)

    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    workspace.displayRuns([OmniWorkspaceRunRow(id: "r1", title: "gartenschlauch", status: "done", summary: "garden hose", token: "/translate", submittedAt: now)], selectedID: nil)
    let entries = try stack.entries()
    workspace.displayStash(entries.enumerated().map { index, entry in
        OmniWorkspaceStashEntry(id: entry.id, token: index == 0 ? "/stash" : "/stash:\(index + 1)", text: entry.text, kind: entry.kind,
                                detail: "\(entry.source) · \(OmniRelativeTime.label(for: entry.createdAt, now: now))", isEditable: entry.isEditable)
    })
    workspace.showStash()
    let panel = try #require(workspace.workspacePanel.contentView)
    try writePNG(panel, name: "stash-3-workspace-light", appearance: .aqua, directory: out)

    let pad = OmniCommandPadViewController(parser: try scratchParser())
    pad.loadView()
    let window = OmniPanelFactory.makePad(controller: pad, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { pad.closeAnnotationPanels(); window.orderOut(nil) }
    pad.onResolveRoute = { _, _ in OmniPadRoute(providerName: "Cerebras") }
    pad.onResolveStashImport = { position in
        guard entries.indices.contains(position - 1) else { return nil }
        let entry = entries[position - 1]
        return OmniPadStashImport(position: position, text: entry.text, source: entry.source, lineCount: entry.lineCount)
    }
    pad.editor.string = "/stash:2 /qq what does the exec flag do here"
    pad.editor.setSelectedRange(NSRange(location: (pad.editor.string as NSString).length, length: 0))
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    try writePNG(pad.view, name: "stash-4-pad-import-dark", appearance: .darkAqua, directory: out)
    pad.editor.string = "/stash:9 /qq hi"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    try writePNG(pad.view, name: "stash-5-pad-unresolved-dark", appearance: .darkAqua, directory: out)
}
