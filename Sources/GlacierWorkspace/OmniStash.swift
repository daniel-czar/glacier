import AppKit
import HyperOverlayRuntime
import OmniCore
import OmniPresentation

/// Writes a stash entry back to a pasteboard with every flavour it kept.
/// The recall marker keeps Clipboard from taking the write in as a new copy.
@MainActor
public enum OmniStashPasteboard {
    @discardableResult
    /// `plainText` (Settings → Clipboard → Paste) drops the rich flavours of
    /// an entry that has text; an image or file entry pastes as copied.
    public static func write(_ entry: OmniStashEntry, plainText: Bool = false, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        item.setData(Data(), forType: RecallPasteboardMarker.type)
        if !entry.text.isEmpty { item.setString(entry.text, forType: .string) }
        let flavours = plainText && !entry.text.isEmpty ? [] : entry.representations
        for representation in flavours where representation.type != NSPasteboard.PasteboardType.string.rawValue {
            item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
