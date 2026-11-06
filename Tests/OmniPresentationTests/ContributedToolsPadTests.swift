import AppKit
import Foundation
import OmniCore
@testable import OmniPresentation
import Testing

@MainActor
private func contributorPad() throws -> OmniCommandPadViewController {
    _ = NSApplication.shared
    let corpus = FrozenContractCorpus()
    let manifest = try CommandManifest(data: corpus.data(named: "manifest"))
    let parser = OmniParser(manifest: manifest, references: try ReferenceRegistry([]))
    let pad = OmniCommandPadViewController(parser: parser)
    pad.loadView()
    pad.contributedSlashRoutes = [OmniContributedSlashRoute(
        token: "/trim", toolID: "text.trim", title: "Trim text", detail: "Removes surrounding whitespace locally.")]
    return pad
}

@Test @MainActor func contributedSlashUsesLocalWindowRouteBeforeUnknownParser() throws {
    let pad = try contributorPad()
    var opened: String?
    var durable: String?
    pad.onContributedSlashRequested = { raw in opened = raw; return true }
    pad.onSubmit = { text, _ in durable = text }
    pad.editor.string = "/trim  keep  this  "
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    pad.editor.onSubmit?(.enterShowHere)
    #expect(opened == "/trim  keep  this  ")
    #expect(durable == nil)
}

@Test @MainActor func disabledContributedSlashDisappearsFromActiveHelp() throws {
    let pad = try contributorPad()
    var opened = false
    pad.onContributedSlashRequested = { _ in opened = true; return true }
    pad.isActionAvailable = { $0 != "tool.text.trim" }
    pad.editor.string = "/tr"
    pad.editor.setSelectedRange(NSRange(location: 3, length: 0))
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(!pad.completionChoices.contains { $0.canonicalText == "/trim" })
    pad.editor.string = "/trim hello"
    pad.textDidChange(Notification(name: NSText.didChangeNotification))
    pad.editor.onSubmit?(.enterShowHere)
    #expect(!opened)
}
