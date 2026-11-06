import AppKit
import ImageIO
import OmniCore

/// One list row for copied or kept material (C85): kind cell · content ·
/// `source · when` beneath, and an optional trailing token. Stash uses it
/// now; Clipboard's rebuild (H16) is meant to adopt it unchanged.
public struct OmniKindRowContent: Equatable {
    public let kind: OmniContentKind
    public let text: String
    public let detail: String
    /// The slash command that imports this row (`/stash`, `/stash:3`).
    public let token: String?
    public let tokenDimmed: Bool
    /// Up to three lines instead of one (the stash's active top row, C93).
    public let emphasized: Bool
    public let imageData: Data?
    /// Names the image for the thumbnail cache (an entry id), so a re-render
    /// never decodes the same image twice.
    public let imageKey: String?

    public init(kind: OmniContentKind, text: String, detail: String, token: String? = nil,
                tokenDimmed: Bool = false, emphasized: Bool = false, imageData: Data? = nil, imageKey: String? = nil) {
        self.kind = kind
        self.text = text
        self.detail = detail
        self.token = token
        self.tokenDimmed = tokenDimmed
        self.emphasized = emphasized
        self.imageData = imageData
        self.imageKey = imageKey
    }
}

@MainActor
public final class OmniKindRowView: NSView {
    public static let rowHeight: CGFloat = 50
    public static let maximumEmphasizedLines = 3
    public override var isFlipped: Bool { true }
    public let content: OmniKindRowContent
    public var onSelect: (() -> Void)?
    public var onActivate: (() -> Void)?
    let kindCell = OmniKindCell()
    let primary = NSTextField(wrappingLabelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let token = NSTextField(labelWithString: "")

    public init(content: OmniKindRowContent, selected: Bool) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = selected ? OmniFrostedStyle.selectedFill.cgColor : NSColor.clear.cgColor
        kindCell.configure(kind: content.kind, text: content.text, imageData: content.imageData, imageKey: content.imageKey)
        primary.attributedStringValue = Self.primaryText(content)
        primary.maximumNumberOfLines = content.emphasized ? Self.maximumEmphasizedLines : 1
        primary.lineBreakMode = .byTruncatingTail
        primary.cell?.truncatesLastVisibleLine = true
        primary.isSelectable = false
        detail.stringValue = content.detail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = OmniFrostedStyle.secondaryInk
        detail.lineBreakMode = .byTruncatingTail
        token.stringValue = content.token ?? ""
        token.font = .systemFont(ofSize: 12, weight: content.tokenDimmed ? .medium : .semibold)
        token.textColor = content.tokenDimmed ? OmniFrostedStyle.command.withAlphaComponent(0.55) : OmniFrostedStyle.command
        token.alignment = .right
        token.isHidden = content.token == nil
        for child in [kindCell, primary, detail, token] as [NSView] { addSubview(child) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([content.token, OmniStashText.excerpt(content.text, limit: 120), content.detail]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onActivate?() } else { onSelect?() }
    }

    /// The emphasized row grows with its text, up to three lines.
    public static func height(for content: OmniKindRowContent, width: CGFloat) -> CGFloat {
        guard content.emphasized else { return rowHeight }
        let textWidth = max(1, width - textInset - trailingWidth(for: content) - 8)
        let font = primaryFont(content)
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 3
        let measured = (content.text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]
        ).height
        let lines = min(CGFloat(maximumEmphasizedLines), max(1, ceil(measured / lineHeight - 0.05)))
        return max(rowHeight, 10 + lines * lineHeight + 2 + 16 + 10)
    }

    public func layoutContent() {
        let tokenWidth = Self.trailingWidth(for: content)
        kindCell.frame = NSRect(x: 8, y: content.emphasized ? 9 : 7, width: 36, height: 36)
        let textWidth = max(1, bounds.width - Self.textInset - tokenWidth - 8)
        let primaryHeight = max(18, bounds.height - (content.emphasized ? 10 : 7) - 7 - 18)
        primary.frame = NSRect(x: Self.textInset, y: content.emphasized ? 9 : 7, width: textWidth,
                               height: content.emphasized ? primaryHeight : 18)
        detail.frame = NSRect(x: Self.textInset, y: primary.frame.maxY + 2, width: textWidth, height: 16)
        token.frame = NSRect(x: bounds.width - tokenWidth - 8, y: content.emphasized ? 11 : 9,
                             width: tokenWidth, height: 16)
    }

    static let textInset: CGFloat = 56
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    private static func trailingWidth(for content: OmniKindRowContent) -> CGFloat {
        guard let token = content.token else { return 0 }
        return ceil((token as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width) + 12
    }

    private static func primaryFont(_ content: OmniKindRowContent) -> NSFont {
        if content.kind == .code { return .monospacedSystemFont(ofSize: 13, weight: .regular) }
        return .systemFont(ofSize: content.emphasized ? 15 : 14)
    }

    private static func primaryText(_ content: OmniKindRowContent) -> NSAttributedString {
        let shown: String
        switch content.kind {
        case .image: shown = content.text.isEmpty ? "Image" : content.text
        default:
            // Lines read as lines only on the top row; elsewhere one line.
            shown = content.emphasized ? content.text : content.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = content.emphasized ? 1.12 : 1
        style.lineBreakMode = content.emphasized ? .byWordWrapping : .byTruncatingTail
        return NSAttributedString(string: shown, attributes: [
            .font: primaryFont(content),
            .foregroundColor: OmniFrostedStyle.ink,
            .paragraphStyle: style,
        ])
    }
}

/// The 36 pt kind cell: a glyph, an image thumbnail, or a colour swatch.
@MainActor
final class OmniKindCell: NSView {
    private let glyph = NSImageView()
    private var swatch: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = OmniFrostedStyle.secondaryInk.withAlphaComponent(0.66)
        addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(kind: OmniContentKind, text: String, imageData: Data?, imageKey: String? = nil) {
        swatch = kind == .colour ? Self.colour(from: text) : nil
        if kind == .image, let imageData, let image = OmniKindThumbnail.cached(imageData, key: imageKey, maxPixels: 96) {
            glyph.image = image
            glyph.imageScaling = .scaleProportionallyUpOrDown
        } else if swatch == nil {
            glyph.image = NSImage(systemSymbolName: Self.symbol(for: kind), accessibilityDescription: kind.rawValue)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            glyph.imageScaling = .scaleNone
        } else {
            glyph.image = nil
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        glyph.frame = glyph.imageScaling == .scaleNone ? bounds : bounds.insetBy(dx: 2, dy: 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        (swatch ?? OmniFrostedStyle.ink.withAlphaComponent(0.06)).setFill()
        bounds.fill()
    }

    static func symbol(for kind: OmniContentKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .colour: "paintpalette"
        }
    }

    static func colour(from text: String) -> NSColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("#") else { return nil }
        var digits = String(value.dropFirst())
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let raw = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let r = CGFloat((raw >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let g = CGFloat((raw >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let b = CGFloat((raw >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let a = hasAlpha ? CGFloat(raw & 0xff) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

@MainActor
enum OmniKindThumbnail {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func cached(_ data: Data, key: String?, maxPixels: Int) -> NSImage? {
        guard let key else { return image(data, maxPixels: maxPixels) }
        let name = "\(key)|\(maxPixels)" as NSString
        if let hit = cache.object(forKey: name) { return hit }
        let made = image(data, maxPixels: maxPixels)
        if let made { cache.setObject(made, forKey: name) }
        return made
    }

    nonisolated static func image(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// `source · when` (C85): today shows the time, then `yesterday`, a weekday
/// within the week, and a short date beyond it.
public enum OmniRelativeTime {
    public static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "today " + date.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let start = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: start), date >= weekAgo, date < start {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Space = preview (C86): a popover anchored to the row with the whole text,
/// or the image larger. A popover keeps the tool key; Quick Look's panel
/// would take key and the tool closes on focus loss.
@MainActor
public final class OmniContentPreview {
    private var popover: NSPopover?
    public var isShown: Bool { popover?.isShown == true }

    public init() {}

    public func toggle(text: String, kind: OmniContentKind, imageData: Data?, relativeTo view: NSView) {
        if isShown { close(); return }
        let controller = NSViewController()
        if kind == .image, let imageData, let image = OmniKindThumbnail.image(imageData, maxPixels: 1200) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            let scale = min(1, 520 / max(1, image.size.width), 420 / max(1, image.size.height))
            imageView.frame = NSRect(x: 0, y: 0, width: max(80, image.size.width * scale), height: max(60, image.size.height * scale))
            controller.view = imageView
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let textView = NSTextView(frame: scroll.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.font = kind == .code ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
            textView.textColor = .labelColor
            textView.string = text
            textView.autoresizingMask = [.width]
            textView.setAccessibilityIdentifier("omni.preview.text")
            scroll.documentView = textView
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
                let used = textView.layoutManager?.usedRect(for: container).height ?? 200
                scroll.frame.size.height = min(360, max(60, used + 24))
            }
            controller.view = scroll
        }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentViewController = controller
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        self.popover = popover
    }

    public func close() {
        popover?.performClose(nil)
        popover = nil
    }
}
