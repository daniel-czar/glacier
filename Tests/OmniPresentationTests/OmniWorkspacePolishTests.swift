import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

@MainActor
func polishCapture(_ view: NSView, name: String, appearance: NSAppearance.Name) throws {
    guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

@MainActor
private func polishView(_ identifier: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == identifier { return root }
    for child in root.subviews {
        if let found = polishView(identifier, in: child) { return found }
    }
    return nil
}

@MainActor
private func resizeWorkspaceToMinimum(_ workspace: OmniWorkspace) {
    let panel = workspace.workspacePanel
    let frame = panel.frame
    panel.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 760, height: 600), display: true)
    panel.contentView?.layoutSubtreeIfNeeded()
}

@Test @MainActor func workspacePolishManyVersionsStayInsideReachableStrip() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 760, height: 600))
    defer { workspace.hideWorkspace() }
    resizeWorkspaceToMinimum(workspace)
    let versions = (1...8).map { number in
        OmniWorkspaceVersion(
            number: number,
            inputText: "/email version \(number)",
            resultText: "Result for version \(number)",
            operation: number == 1 ? "initial" : "a longer continuation",
            sourceVersion: number == 8 ? 2 : number - 1
        )
    }
    workspace.displayResult(runID: "polish-versions", title: "Versions", status: "done", versions: versions, selectedVersion: 8)
    let content = try #require(workspace.workspacePanel.contentView)
    content.layoutSubtreeIfNeeded()
    let detail = try #require(polishView("omni.workspace.detail", in: content))
    #expect(detail.bounds.width <= 500)
    let strip = try #require(polishView("omni.workspace.version-strip", in: detail) as? NSScrollView)
    let row = try #require(strip.documentView)
    let pills = row.subviews.compactMap { $0 as? OmniVersionPill }
    #expect(pills.count == 8)
    #expect(strip.frame.maxX <= detail.bounds.maxX - 20)
    #expect(row.frame.width > strip.frame.width)
    let selected = try #require(pills.first { $0.isSelected })
    #expect(selected.title.contains("on v2"))
    #expect(strip.contentView.bounds.intersects(selected.frame))
    let first = try #require(pills.first { $0.title.hasPrefix("v1 ") })
    strip.contentView.scroll(to: .zero)
    strip.reflectScrolledClipView(strip.contentView)
    #expect(strip.contentView.bounds.intersects(first.frame))
    var requestedVersion: Int?
    workspace.onSelectVersion = { requestedVersion = $0 }
    first.performClick(nil)
    #expect(requestedVersion == 1)
    #expect(polishView("omni.workspace.version-result", in: detail) is OmniSelectableTextView)
    let disclosure = try #require(polishView("omni.workspace.input-disclosure", in: detail))
    try polishCapture(disclosure, name: "workspace-polish-disclosure-light", appearance: .aqua)
    try polishCapture(detail, name: "workspace-polish-many-versions-light", appearance: .aqua)
    try polishCapture(detail, name: "workspace-polish-many-versions-dark", appearance: .darkAqua)
}

@Test @MainActor func workspacePolishRegularScrollerKeepsFullPillHeight() {
    _ = NSApplication.shared
    let strip = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
    strip.borderType = .noBorder
    strip.hasHorizontalScroller = true
    strip.autohidesScrollers = true
    strip.scrollerStyle = .legacy
    strip.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 24))
    let scrollerHeight = OmniWorkspace.fitVersionStrip(strip, top: 100, width: 240)
    #expect(scrollerHeight > 0)
    #expect(strip.contentSize.height >= 24)
    #expect(strip.frame.maxY == 100)
}

@Test @MainActor func workspacePolishNormalAndAnnotatedFollowupFooterAtMinimumWidth() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 760, height: 600))
    defer { workspace.hideWorkspace() }
    resizeWorkspaceToMinimum(workspace)
    let source = "Continue from v7 · edit the text and add /formal or /shorter"
    workspace.showComposer(text: "/shorter Keep the Bessel reference", runID: "polish-followup", sourceVersion: 7, sourceLabel: source)
    let content = try #require(workspace.workspacePanel.contentView)
    content.layoutSubtreeIfNeeded()
    var detail = try #require(polishView("omni.workspace.detail", in: content))
    #expect(detail.bounds.width <= 500)
    let subtitle = try #require(detail.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == source })
    #expect(subtitle.textColor == .secondaryLabelColor)
    let normalRoute = try #require(polishView("omni.workspace.composer-route", in: detail))
    let normalDiscard = try #require(polishView("omni.workspace.discard-draft", in: detail))
    #expect(normalRoute.frame.maxX + 8 <= normalDiscard.frame.minX)
    try polishCapture(detail, name: "workspace-polish-normal-followup-light", appearance: .aqua)
    try polishCapture(detail, name: "workspace-polish-normal-followup-dark", appearance: .darkAqua)

    let note = OmniTextAnnotation(range: NSRange(location: 9, length: 4), guidance: "Keep the reference")
    workspace.showComposer(text: "/shorter Keep the Bessel reference", runID: "polish-followup", sourceVersion: 7, sourceLabel: source, annotations: [note])
    workspace.showComposerNotice("Follow-up · a long route description that must yield to the note and keyboard controls")
    content.layoutSubtreeIfNeeded()
    detail = try #require(polishView("omni.workspace.detail", in: content))
    let route = try #require(polishView("omni.workspace.composer-route", in: detail))
    let notes = try #require(polishView("omni.workspace.notes", in: detail))
    let discard = try #require(polishView("omni.workspace.discard-draft", in: detail))
    let hints = try #require(detail.subviews.first { $0 is OmniKeyHintsView })
    let apply = try #require(polishView("omni.workspace.apply", in: detail))
    let rule = try #require(polishView("omni.workspace.composer-rule", in: detail))
    let composerScroll = try #require(polishView("omni.workspace.composer-scroll", in: detail))
    #expect(!notes.isHidden)
    #expect(route.frame.minY == 16)
    #expect(route.frame.maxX + 8 <= notes.frame.minX)
    #expect(notes.frame.maxX + 8 <= discard.frame.minX)
    #expect(discard.frame.maxX + 12 <= hints.frame.minX)
    #expect(hints.frame.maxX + 12 <= apply.frame.minX)
    try polishCapture(detail, name: "workspace-polish-annotated-narrow-light", appearance: .aqua)
    try polishCapture(detail, name: "workspace-polish-annotated-narrow-dark", appearance: .darkAqua)
    let split = try #require(workspace.workspacePanel.contentViewController as? NSSplitViewController)
    split.splitView.setPosition(340, ofDividerAt: 0)
    content.layoutSubtreeIfNeeded()
    #expect(detail.bounds.width <= 425)
    #expect(route.frame.width >= 300)
    #expect(route.frame.minY > notes.frame.maxY)
    #expect(route.frame.maxY < rule.frame.minY)
    #expect(composerScroll.frame.minY >= rule.frame.maxY)
    #expect(notes.frame.maxX + 8 <= discard.frame.minX)
    #expect(discard.frame.maxX + 12 <= hints.frame.minX)
    try polishCapture(detail, name: "workspace-polish-annotated-expanded-sidebar-light", appearance: .aqua)
    try polishCapture(detail, name: "workspace-polish-annotated-expanded-sidebar-dark", appearance: .darkAqua)

    let originalText = workspace.editor.string
    let selection = NSRange(location: 9, length: 4)
    workspace.editor.setSelectedRange(selection)
    let retainedFocus = workspace.workspacePanel.firstResponder === workspace.editor
    workspace.setAnnotations([])
    content.layoutSubtreeIfNeeded()
    #expect(notes.isHidden)
    #expect(route.frame.minY == 16)
    #expect(route.frame.maxX + 8 <= discard.frame.minX)
    #expect(workspace.editor.string == originalText)
    #expect(workspace.editor.selectedRange() == selection)
    #expect((workspace.workspacePanel.firstResponder === workspace.editor) == retainedFocus)
    #expect(polishView("omni.workspace.composer-scroll", in: detail) === composerScroll)
    try polishCapture(detail, name: "workspace-polish-expanded-sidebar-no-notes-light", appearance: .aqua)

    workspace.setAnnotations([note])
    content.layoutSubtreeIfNeeded()
    #expect(!notes.isHidden)
    #expect(route.frame.width >= 300)
    #expect(route.frame.minY > notes.frame.maxY)
    #expect(workspace.editor.string == originalText)
    #expect(workspace.editor.selectedRange() == selection)
    #expect((workspace.workspacePanel.firstResponder === workspace.editor) == retainedFocus)
    #expect(polishView("omni.workspace.composer-scroll", in: detail) === composerScroll)
}

@Test @MainActor func workspacePolishSidebarRowsTrackActualResizeWithoutReplacingFollowup() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1040, height: 740))
    defer { workspace.hideWorkspace() }
    let row = OmniWorkspaceRunRow(
        id: "resize-run", title: "A longer subject that should gain visible room", status: "done",
        summary: "A result excerpt with enough words to use the additional width", token: "/email",
        submittedAt: Date()
    )
    workspace.displayRuns([row], selectedID: row.id)
    let note = OmniTextAnnotation(range: NSRange(location: 9, length: 4), guidance: "Retain this")
    workspace.showComposer(text: "/shorter Keep this reference", runID: row.id, sourceVersion: 1, annotations: [note])
    let content = try #require(workspace.workspacePanel.contentView)
    content.layoutSubtreeIfNeeded()
    let scroll = try #require(polishView("omni.workspace.run-scroll", in: content) as? NSScrollView)
    let stack = try #require(scroll.documentView as? NSStackView)
    let button = try #require(polishView("omni.workspace.run.resize-run", in: stack) as? NSButton)
    let group = try #require(polishView("omni.workspace.run-group", in: stack))
    let composerScroll = try #require(polishView("omni.workspace.composer-scroll", in: content))
    let narrowWidth = scroll.contentView.bounds.width
    #expect(abs(stack.frame.width - narrowWidth) < 1)
    #expect(abs(button.frame.width - narrowWidth) < 1)
    #expect(abs((group.superview?.frame.width ?? 0) - narrowWidth) < 1)
    #expect(abs(group.frame.width - (narrowWidth - 24)) < 1)
    #expect(button.state == .on)
    try polishCapture(scroll, name: "workspace-polish-sidebar-default-light", appearance: .aqua)

    workspace.editor.setSelectedRange(NSRange(location: 9, length: 4))
    let editor = workspace.editor
    let split = try #require(workspace.workspacePanel.contentViewController as? NSSplitViewController)
    split.splitView.setPosition(340, ofDividerAt: 0)
    content.layoutSubtreeIfNeeded()
    scroll.layoutSubtreeIfNeeded()
    stack.layoutSubtreeIfNeeded()
    let expandedWidth = scroll.contentView.bounds.width
    #expect(expandedWidth > narrowWidth + 50)
    #expect(abs(stack.frame.width - expandedWidth) < 1)
    #expect(abs(button.frame.width - expandedWidth) < 1)
    #expect(abs((group.superview?.frame.width ?? 0) - expandedWidth) < 1)
    #expect(abs(group.frame.width - (expandedWidth - 24)) < 1)
    #expect(button.state == .on)
    #expect(polishView("omni.workspace.run.resize-run", in: stack) === button)
    #expect(polishView("omni.workspace.composer-scroll", in: content) === composerScroll)
    #expect(editor.string == "/shorter Keep this reference")
    #expect(editor.selectedRange() == NSRange(location: 9, length: 4))
    #expect(editor.annotations == [note])
    #expect(workspace.selectedRunID == row.id)
    try polishCapture(scroll, name: "workspace-polish-sidebar-expanded-light", appearance: .aqua)

    var selected: String?
    workspace.onSelectRun = { selected = $0 }
    button.performClick(nil)
    #expect(selected == row.id)
}

@Test @MainActor func workspacePolishResultMeasureAndFullTextSurviveWindowResize() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 800))
    defer { workspace.hideWorkspace() }
    let longToken = String(repeating: "abcdef0123456789", count: 20)
    let result = (0..<20).map { index in
        "Paragraph \(index): A complete answer with enough ordinary words to wrap across several lines. /Users/example/Tooling/agent-output/\(longToken)"
    }.joined(separator: "\n\n") + "\nLAST-RESULT-MARKER"
    let versions = [
        OmniWorkspaceVersion(number: 1, inputText: "/email first", resultText: "Earlier", operation: "initial"),
        OmniWorkspaceVersion(number: 2, inputText: "/shorter second", resultText: result, operation: "shorter", sourceVersion: 1),
    ]
    workspace.displayResult(runID: "measure-run", title: "Long result", status: "done", versions: versions, selectedVersion: 2)
    let content = try #require(workspace.workspacePanel.contentView)
    let panel = workspace.workspacePanel
    panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.minY, width: 1512, height: 740), display: true)
    content.layoutSubtreeIfNeeded()
    let scroll = try #require(polishView("omni.workspace.version-result", in: content)?.enclosingScrollView)
    let text = try #require(scroll.documentView as? OmniSelectableTextView)
    let container = try #require(text.textContainer)
    let layout = try #require(text.layoutManager)
    scroll.layoutSubtreeIfNeeded()
    #expect(scroll.frame.width > 620)
    #expect(text.frame.width <= 620)
    #expect(text.frame.width >= 600)
    #expect(layout.usedRect(for: container).width <= container.containerSize.width + 1)
    #expect(text.string == result)
    #expect(workspace.selectedVersion == 2)
    try polishCapture(scroll, name: "workspace-polish-result-wide-light", appearance: .aqua)

    panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.minY, width: 760, height: 600), display: true)
    content.layoutSubtreeIfNeeded()
    scroll.layoutSubtreeIfNeeded()
    #expect(text.frame.width < 620)
    #expect(abs(text.frame.width - scroll.contentSize.width) < 1)
    #expect(layout.usedRect(for: container).width <= container.containerSize.width + 1)
    #expect(text.string.hasSuffix("LAST-RESULT-MARKER"))
    #expect(layout.glyphRange(for: container).length == (result as NSString).length)
    #expect(text.frame.height > scroll.contentSize.height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: text.frame.maxY - scroll.contentSize.height))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(scroll.contentView.bounds.maxY >= text.frame.maxY - 1)
    text.setSelectedRange(NSRange(location: 0, length: (result as NSString).length))
    #expect(text.selectedRange().length == (result as NSString).length)
    var copied: (String, Int)?
    workspace.onCopy = { copied = ($0, $1) }
    workspace.copySelectedResult()
    #expect(copied?.0 == "measure-run")
    #expect(copied?.1 == 2)
    try polishCapture(scroll, name: "workspace-polish-result-narrow-light", appearance: .aqua)
}
