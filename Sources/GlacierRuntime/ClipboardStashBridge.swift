import ClipboardHistory
import Foundation
import OmniCore

/// Clipboard's ⌘Y (C95, D5): a copied item joins Glacier's stash whole, every
/// flavour it kept, with its source app and copy time. The host composes
/// both services, so the bridge lives here and neither depends on the other.
enum ClipboardStashBridge {
    @MainActor
    static func push(_ payload: ClipboardHistoryPayload, _ summary: ClipboardHistorySummary, into stack: OmniStashStack) -> ClipboardStashPush? {
        let source = summary.sourceName ?? summary.sourceBundleID ?? "Clipboard"
        let entry: OmniStashEntry
        switch payload {
        case .text(let plain, let rtf, let html):
            var representations: [OmniStashRepresentation] = []
            if let rtf { representations.append(OmniStashRepresentation(type: "public.rtf", data: rtf)) }
            if let html { representations.append(OmniStashRepresentation(type: "public.html", data: html)) }
            entry = OmniStashEntry(text: plain, representations: representations, source: source,
                                   sourceBundleID: summary.sourceBundleID, createdAt: summary.copiedAt)
        case .image(let data, let typeIdentifier):
            entry = OmniStashEntry(text: "", representations: [OmniStashRepresentation(type: typeIdentifier, data: data)], kind: .image,
                                   source: source, sourceBundleID: summary.sourceBundleID, createdAt: summary.copiedAt)
        }
        guard let outcome = try? stack.push(entry) else { return nil }
        return ClipboardStashPush(droppedOldest: outcome.dropped != nil) { (try? stack.undoPush(outcome)) == true }
    }
}
