import AppKit

/// Shared native ink vocabulary for Concept Lens and Map.
@MainActor
enum OmniDrawnPrimitives {
    static func stroke(_ path: NSBezierPath, color: NSColor) {
        color.setStroke()
        path.lineWidth = 1.1
        path.stroke()
    }

    static func outline(_ frame: NSRect, filled: Bool, opacity: CGFloat = 0.55, circle: Bool = false) {
        let rect = frame.insetBy(dx: 0.55, dy: 0.55)
        let path = circle ? NSBezierPath(ovalIn: rect) : NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if filled { OmniFrostedStyle.ink.setFill(); path.fill() }
        else { stroke(path, color: OmniFrostedStyle.ink.withAlphaComponent(opacity)) }
    }

    static func label(_ text: String, frame: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular,
                      alignment: NSTextAlignment = .center, wraps: Bool = false, smallCaps: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if smallCaps { attributes[.kern] = 0.5 }
        (text as NSString).draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

/// One 2× light PNG with the same margins, independent of ambient appearance.
@MainActor
public enum OmniDrawnCopyComposer {
    public static func png(contentHeight: CGFloat, draw: () -> Void) -> Data? {
        var result: Data?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let size = NSSize(width: 640, height: ceil(contentHeight + 32))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 2, y: 2)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            context.cgContext.translateBy(x: 18, y: size.height - 16)
            context.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            draw()
            result = bitmap.representation(using: .png, properties: [:])
        }
        return result
    }

    public static func item(png: Data, text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString(text, forType: .string)
        return item
    }
}
