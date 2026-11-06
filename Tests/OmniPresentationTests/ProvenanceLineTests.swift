import AppKit
import OmniPresentation
import Testing

// The provenance grammar (D3, decision surface 569d5a7cf925cbd7): one
// formatter for the workspace header, the pad chip and the notification.

private let attachmentCharacter = "\u{FFFC}"

/// The attributed line with its icon attachment shown as `⌘`, the glyph the
/// decision surface uses for the app icon.
private func visible(_ text: NSAttributedString) -> String {
    text.string.replacingOccurrences(of: attachmentCharacter, with: "⌘")
}

@MainActor
private func view(in root: NSView, identifier: String) -> NSView? {
    if root.accessibilityIdentifier() == identifier { return root }
    for child in root.subviews {
        if let found = view(in: child, identifier: identifier) { return found }
    }
    return nil
}

@Test func anIdenticalWindowTitleRendersOnce() throws {
    let line = try #require(OmniProvenanceLine(appName: "Claude", windowTitle: "Claude"))
    #expect(line.text == "From Claude")
    #expect(line.windowTitle == nil)
    // Case and padding do not make a repeat a new title.
    #expect(OmniProvenanceLine(appName: "Claude", windowTitle: "  claude ")?.text == "From Claude")
}

@Test func aDifferingTitleRendersInQuotes() throws {
    let line = try #require(OmniProvenanceLine(appName: "Mail", windowTitle: "Re: invoice", bundleIdentifier: "com.apple.mail"))
    #expect(line.text == "From Mail “Re: invoice”")
    #expect(line.source == "Mail “Re: invoice”")
    #expect(line.bundleIdentifier == "com.apple.mail")
}

@Test func anEmptyTitleRendersNothing() {
    #expect(OmniProvenanceLine(appName: "Mail", windowTitle: "")?.text == "From Mail")
    #expect(OmniProvenanceLine(appName: "Mail", windowTitle: "   ")?.text == "From Mail")
    #expect(OmniProvenanceLine(appName: "Mail", windowTitle: nil)?.text == "From Mail")
    #expect(OmniProvenanceLine(appName: nil, windowTitle: nil) == nil)
    #expect(OmniProvenanceLine(appName: " ", windowTitle: "") == nil)
    #expect(OmniProvenanceLine(appName: nil, windowTitle: "Notes draft")?.text == "From “Notes draft”")
    #expect(OmniProvenanceLine(appName: "Mail", windowTitle: nil, bundleIdentifier: "  ")?.bundleIdentifier == nil)
}

@Test @MainActor func theAttributedLineDrawsTheIconBetweenPrepositionAndName() throws {
    let line = try #require(OmniProvenanceLine(appName: "Claude", windowTitle: "Claude"))
    let attributed = line.attributed(attributes: [.font: NSFont.systemFont(ofSize: 12)], iconSize: 14)
    #expect(visible(attributed) == "From ⌘Claude")
    let mail = try #require(OmniProvenanceLine(appName: "Mail", windowTitle: "Re: invoice"))
    #expect(visible(mail.attributed(attributes: [:], iconSize: 14)) == "From ⌘Mail “Re: invoice”")
    var attachments = 0
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if let attachment = value as? NSTextAttachment, attachment.image != nil { attachments += 1 }
    }
    #expect(attachments == 1)
    // A bare title has no app, so no icon.
    let untitled = try #require(OmniProvenanceLine(appName: nil, windowTitle: "Notes draft"))
    #expect(visible(untitled.attributed(attributes: [:], iconSize: 14)) == "From “Notes draft”")
}

@Test @MainActor func iconsComeFromTheBundleThenTheNameThenAGenericDocument() {
    var bundleLookups = 0
    let resolver = OmniAppIconResolver(
        applicationURLForBundleIdentifier: { identifier in
            bundleLookups += 1
            return identifier == "com.apple.mail" ? URL(fileURLWithPath: "/System/Applications/Mail.app") : nil
        },
        applicationURLForName: { name in name == "Notes" ? URL(fileURLWithPath: "/System/Applications/Notes.app") : nil },
        iconForFile: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
        genericIcon: { NSImage(size: NSSize(width: 8, height: 8)) }
    )
    #expect(resolver.source(bundleIdentifier: "com.apple.mail", appName: "Mail") == .bundleIdentifier("com.apple.mail"))
    // Records from before bundle identifiers were captured: name lookup.
    #expect(resolver.source(bundleIdentifier: nil, appName: "Notes") == .appName("Notes"))
    // An identifier that no longer resolves falls through to the name.
    #expect(resolver.source(bundleIdentifier: "com.example.gone", appName: "Notes") == .appName("Notes"))
    #expect(resolver.source(bundleIdentifier: nil, appName: "Unknown Tool") == .generic)
    #expect(resolver.icon(bundleIdentifier: nil, appName: "Unknown Tool").size == NSSize(width: 8, height: 8))
    // Cached per key: the header redraws on every results poll.
    let before = bundleLookups
    _ = resolver.icon(bundleIdentifier: "com.apple.mail", appName: "Mail")
    #expect(bundleLookups == before)
}

@Test @MainActor func thePadChipAndTheHeaderShareOneFormatter() throws {
    let provenance = OmniPadProvenance(source: "Claude", detail: "Claude", wordCount: 3, bundleIdentifier: "com.anthropic.claudefordesktop")
    let line = try #require(provenance.line)
    #expect(provenance.label == line.text)
    #expect(provenance.label == "From Claude")
    let chip = OmniProvenanceChip()
    chip.provenance = provenance
    #expect(visible(try #require(chip.attributedLabel)) == "From ⌘Claude")
    #expect(chip.accessibilityLabel() == "From Claude. Remove imported text")
    #expect(chip.fittingWidth > 0)

    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    let submitted = Date()
    workspace.displayResult(
        runID: "run-1",
        title: "Find",
        status: "succeeded",
        versions: [],
        selectedVersion: 0,
        header: OmniWorkspaceRunHeader(token: "/find", provenance: line, submittedAt: submitted, route: OmniWorkspaceRunHeader.localRoute)
    )
    let content = try #require(workspace.workspacePanel.contentView)
    let subtitle = try #require(view(in: content, identifier: "omni.workspace.result-subtitle") as? NSTextField)
    let rendered = visible(subtitle.attributedStringValue)
    #expect(rendered == "/find · From ⌘Claude · On this Mac", "the chain ends at the route")
    // The time is its own label, right-aligned on the same row.
    let time = try #require(view(in: content, identifier: "omni.workspace.result-time") as? NSTextField)
    #expect(time.stringValue.hasPrefix("Today, ") && time.alignment == .right)
    #expect(time.frame.minY == subtitle.frame.minY && time.frame.minX >= subtitle.frame.maxX)
    // The header's provenance segment is the chip's text, byte for byte.
    #expect(rendered.contains(visible(try #require(chip.attributedLabel))))
}

@Test @MainActor func aModelRunNamesItsProviderAndATitleRendersInQuotesInTheHeader() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    workspace.displayResult(
        runID: "run-2",
        title: "Reply",
        status: "succeeded",
        versions: [OmniWorkspaceVersion(number: 1, inputText: "/email yes", resultText: "Yes.", operation: "initial")],
        selectedVersion: 1,
        header: OmniWorkspaceRunHeader(
            token: "/email",
            provenance: OmniProvenanceLine(appName: "Mail", windowTitle: "Re: invoice", bundleIdentifier: "com.apple.mail"),
            submittedAt: Date(),
            route: "Cerebras"
        )
    )
    let content = try #require(workspace.workspacePanel.contentView)
    let subtitle = try #require(view(in: content, identifier: "omni.workspace.result-subtitle") as? NSTextField)
    #expect(visible(subtitle.attributedStringValue) == "/email · From ⌘Mail “Re: invoice” · Cerebras")
}

@Test @MainActor func aLongWindowTitleShortensBeforeTheRouteAndTheTimeIsNeverCut() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    let title = String(repeating: "Quarterly planning notes and follow-ups ", count: 8).trimmingCharacters(in: .whitespaces)
    workspace.displayResult(
        runID: "run-3",
        title: "Reply",
        status: "succeeded",
        versions: [OmniWorkspaceVersion(number: 1, inputText: "/email yes", resultText: "Yes.", operation: "initial")],
        selectedVersion: 1,
        header: OmniWorkspaceRunHeader(
            token: "/email",
            provenance: OmniProvenanceLine(appName: "Mail", windowTitle: title, bundleIdentifier: "com.apple.mail"),
            submittedAt: Date(),
            route: "Cerebras"
        )
    )
    let content = try #require(workspace.workspacePanel.contentView)
    let subtitle = try #require(view(in: content, identifier: "omni.workspace.result-subtitle") as? NSTextField)
    let time = try #require(view(in: content, identifier: "omni.workspace.result-time") as? NSTextField)
    let rendered = visible(subtitle.attributedStringValue)
    #expect(rendered.hasPrefix("/email · From ⌘Mail “Quarterly"))
    #expect(rendered.hasSuffix("…” · Cerebras"), "the title shortens, the route stays")
    #expect(subtitle.attributedStringValue.size().width <= subtitle.frame.width)
    #expect(time.stringValue.hasPrefix("Today, "))
    #expect(time.frame.width >= ceil(time.attributedStringValue.size().width) + 4, "room for the last digit beyond the cell inset")
    // VoiceOver reads the whole chain and the time, not the shortened form.
    #expect(subtitle.accessibilityLabel()?.contains(title) == true)
    #expect(subtitle.accessibilityLabel()?.hasSuffix(time.stringValue) == true)
}

@Test @MainActor func theHeaderRefitsOnResizeAndAnOriginShortensBeforeTheRoute() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    let title = "Re: Quarterly planning for the Q4 board meeting"
    workspace.displayResult(
        runID: "run-4",
        title: "Reply",
        status: "succeeded",
        versions: [OmniWorkspaceVersion(number: 1, inputText: "/email yes", resultText: "Yes.", operation: "initial")],
        selectedVersion: 1,
        header: OmniWorkspaceRunHeader(
            token: "/email",
            provenance: OmniProvenanceLine(appName: "Mail", windowTitle: title, bundleIdentifier: "com.apple.mail"),
            submittedAt: Date(),
            route: "Cerebras"
        )
    )
    let content = try #require(workspace.workspacePanel.contentView)
    let subtitle = try #require(view(in: content, identifier: "omni.workspace.result-subtitle") as? NSTextField)
    let full = visible(subtitle.attributedStringValue)
    #expect(full == "/email · From ⌘Mail “\(title)” · Cerebras", "fits when wide")
    // A narrower row (the sidebar opened, the window narrowed) refits: the
    // title shortens, the route stays; widening restores it.
    subtitle.setFrameSize(NSSize(width: 260, height: subtitle.frame.height))
    let narrow = visible(subtitle.attributedStringValue)
    #expect(narrow.hasSuffix("…” · Cerebras") && narrow.count < full.count)
    #expect(subtitle.attributedStringValue.size().width <= 260)
    subtitle.setFrameSize(NSSize(width: 900, height: subtitle.frame.height))
    #expect(visible(subtitle.attributedStringValue) == full)
    // With no title to shorten, a long origin shortens before the route.
    workspace.displayResult(
        runID: "run-5",
        title: "Reply",
        status: "succeeded",
        versions: [OmniWorkspaceVersion(number: 1, inputText: "/email yes", resultText: "Yes.", operation: "initial")],
        selectedVersion: 1,
        header: OmniWorkspaceRunHeader(
            token: "/email",
            provenance: OmniProvenanceLine(appName: "Mail", windowTitle: nil, bundleIdentifier: "com.apple.mail"),
            submittedAt: Date(),
            origin: "from /stance · " + String(repeating: "Decline politely but keep the door open ", count: 3),
            route: "Cerebras"
        )
    )
    let origin = try #require(view(in: content, identifier: "omni.workspace.result-subtitle") as? NSTextField)
    origin.setFrameSize(NSSize(width: 320, height: origin.frame.height))
    let shortened = visible(origin.attributedStringValue)
    #expect(shortened.hasSuffix("· From ⌘Mail · Cerebras"), "\(shortened)")
    #expect(shortened.contains("…"))
}
