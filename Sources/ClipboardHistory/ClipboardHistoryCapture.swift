import AppKit
import Foundation
import HyperOverlayRuntime
import ImageIO
import UniformTypeIdentifiers

/// A bounded, consistent read. Markers and source exclusions are checked before payload bytes.
@MainActor
public final class ClipboardHistoryCapture {
    public enum Read {
        case ignored
        case changedDuringRead
        case captured(ClipboardHistoryPayload, ClipboardHistorySource)
        case unavailable(String)
    }

    public static let privateMarker = RecallPasteboardMarker.type
    public static let excludedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "com.agilebits.onepassword", "net.antelle.keeweb",
        "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping", "Pasteboard generator type",
    ]
    private static let maxImageBytes = 12 * 1024 * 1024
    public let pasteboard: NSPasteboard
    private let currentSource: () -> ClipboardHistorySource
    public private(set) var lastChangeCount: Int
    private let maxItemBytes: Int
    private var lastObservedSource: ClipboardHistorySource
    private var sourceTransitionObserved = false

    public init(pasteboard: NSPasteboard, maxItemBytes: Int = 64 * 1024 * 1024,
                currentSource: @escaping () -> ClipboardHistorySource = {
                    let app = NSWorkspace.shared.frontmostApplication
                    return ClipboardHistorySource(bundleID: app?.bundleIdentifier, name: app?.localizedName)
                }) {
        self.pasteboard = pasteboard
        self.maxItemBytes = maxItemBytes
        self.currentSource = currentSource
        lastObservedSource = currentSource()
        lastChangeCount = pasteboard.changeCount
    }

    /// Baseline only: never read/backfill a value copied while stopped, paused or cleared.
    public func resetBaseline() {
        lastChangeCount = pasteboard.changeCount
        lastObservedSource = currentSource()
        sourceTransitionObserved = false
    }

    /// Activation notifications catch even an away-and-back switch between polls.
    public func noteSourceTransition() { sourceTransitionObserved = true }

    public func read(settings: ClipboardHistorySettings) -> Read {
        let revision = pasteboard.changeCount
        let before = currentSource()
        let sourceChanged = sourceTransitionObserved || before.bundleID != lastObservedSource.bundleID
        lastObservedSource = before
        sourceTransitionObserved = false
        guard revision != lastChangeCount else { return .ignored }
        lastChangeCount = revision
        guard !settings.paused else { return .ignored }
        let itemTypes = (pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        let types = Set((pasteboard.types ?? []).map(\.rawValue) + itemTypes)
        guard types.isDisjoint(with: Self.excludedTypes),
              !types.contains(Self.privateMarker.rawValue) else { return .ignored }
        let declared = pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        let excluded = Set(settings.excludedBundleIDs)
        if before.bundleID.map(excluded.contains) == true || declared.map(excluded.contains) == true { return .ignored }
        guard !sourceChanged || declared?.isEmpty == false else { return .changedDuringRead }

        let payload: ClipboardHistoryPayload
        // Item-declared representations precede server-synthesized conversions.
        let declaredImages = itemTypes.filter { UTType($0)?.conforms(to: .image) == true }
        let fallbackImages = types.sorted().filter { !declaredImages.contains($0) && UTType($0)?.conforms(to: .image) == true }
        if let identifier = (declaredImages + fallbackImages).first {
            let type = NSPasteboard.PasteboardType(identifier)
            guard let data = pasteboard.data(forType: type) else { return .unavailable("An image could not be read.") }
            guard data.count <= min(maxItemBytes, Self.maxImageBytes), Self.validImage(data) else {
                return .unavailable("An image was too large or unsupported; it was not saved.")
            }
            payload = .image(data: data, typeIdentifier: type.rawValue)
        } else {
            guard !types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) else { return .ignored }
            let rtf = pasteboard.data(forType: .rtf)
            let html = pasteboard.data(forType: .html)
            var plain = pasteboard.string(forType: .string)
            if plain == nil, let rtf {
                plain = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                documentAttributes: nil).string
            }
            guard let plain, !plain.isEmpty else { return .ignored }
            guard plain.utf8.count + (rtf?.count ?? 0) + (html?.count ?? 0) <= maxItemBytes else {
                return .unavailable("A text item was too large; it was not saved.")
            }
            payload = .text(plain: plain, rtf: rtf, html: html)
        }
        let after = currentSource()
        guard pasteboard.changeCount == revision, before.bundleID == after.bundleID else { return .changedDuringRead }
        // Recheck markers in case a writer published marker and data in separate operations.
        let finalTypes = Set((pasteboard.types ?? []).map(\.rawValue)
            + (pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        guard finalTypes.isDisjoint(with: Self.excludedTypes),
              !finalTypes.contains(Self.privateMarker.rawValue), pasteboard.changeCount == revision else { return .ignored }
        return .captured(payload, ClipboardHistorySource(bundleID: declared?.isEmpty == false ? declared : before.bundleID,
                                                         name: declared == nil || declared == before.bundleID ? before.name : declared))
    }

    private static func validImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = values[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        let pixels = width.doubleValue * height.doubleValue
        return pixels > 0 && pixels <= 100_000_000
    }

    /// Only history recall writes carry this marker; calculator/user copies remain eligible.
    public func write(_ payload: ClipboardHistoryPayload, formatted: Bool) -> Bool {
        let item = NSPasteboardItem()
        item.setData(Data(), forType: Self.privateMarker)
        switch payload {
        case .text(let plain, let rtf, let html):
            item.setString(plain, forType: .string)
            if formatted {
                if let rtf { item.setData(rtf, forType: .rtf) }
                if let html { item.setData(html, forType: .html) }
            }
        case .image(let data, let type):
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        pasteboard.clearContents()
        let result = pasteboard.writeObjects([item])
        resetBaseline()
        return result
    }
}
