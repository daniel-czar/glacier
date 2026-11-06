import AppKit

/// Fixed native geometry: content chooses labels, never positions or line meanings.
@MainActor
public final class OmniConceptLensDrawing: NSView {
    public static let drawingSize = NSSize(width: 604, height: 292)
    public struct Node: Equatable {
        public enum Kind { case concept, parent, sibling, child, nearMiss }
        public let kind: Kind
        public let frame: NSRect
        public let name: String
        public let detail: String?
    }
    public private(set) var nodes: [Node] = []
    public private(set) var contentHeight: CGFloat = 292
    public private(set) var map: OmniConceptLensMap?
    private var text = NSAttributedString(string: "")
    public override var isFlipped: Bool { true }

    public func display(_ map: OmniConceptLensMap?) {
        guard self.map != map else { return }
        self.map = map
        nodes = []
        removeAllToolTips()
        guard let map else { needsDisplay = true; return }
        nodes.append(Node(kind: .concept, frame: NSRect(x: 126, y: 90, width: 172, height: 42),
                          name: map.name, detail: map.field))
        let parentWidth: CGFloat = 128
        for (i, name) in map.parents.enumerated() {
            let x = centredX(index: i, count: map.parents.count, width: parentWidth, gap: 8)
            nodes.append(Node(kind: .parent, frame: NSRect(x: x, y: 8, width: parentWidth, height: 26), name: name, detail: nil))
        }
        for (i, name) in map.siblings.prefix(2).enumerated() {
            nodes.append(Node(kind: .sibling, frame: NSRect(x: i == 0 ? 8 : 322, y: 96, width: 100, height: 30), name: name, detail: nil))
        }
        for (i, name) in map.children.enumerated() {
            let x = centredX(index: i, count: map.children.count, width: 80, gap: 6)
            nodes.append(Node(kind: .child, frame: NSRect(x: x, y: 204, width: 80, height: 36), name: name, detail: nil))
        }
        for (i, miss) in map.nearMisses.enumerated() {
            nodes.append(Node(kind: .nearMiss, frame: NSRect(x: 454, y: 8 + CGFloat(i) * 68, width: 146, height: 26),
                              name: miss.name, detail: miss.distinction))
        }
        for (index, node) in nodes.enumerated() {
            var hoverFrame = node.frame
            if node.kind == .nearMiss { hoverFrame.size.height += 34 }
            addToolTip(hoverFrame, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        needsDisplay = true
    }

    private func centredX(index: Int, count: Int, width: CGFloat, gap: CGFloat) -> CGFloat {
        let total = CGFloat(count) * width + CGFloat(max(0, count - 1)) * gap
        return 212 - total / 2 + CGFloat(index) * (width + gap)
    }

    @objc public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                              userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        guard nodes.indices.contains(index) else { return "" }
        let node = nodes[index]
        return node.detail.map { node.name + " — " + $0 } ?? node.name
    }

    @discardableResult
    public func arrange(width: CGFloat) -> CGFloat {
        guard let map else { contentHeight = 0; return 0 }
        text = Self.footer(map)
        let footerHeight = ceil(text.boundingRect(with: NSSize(width: Self.drawingSize.width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin]).height)
        contentHeight = Self.drawingSize.height + footerHeight + 4
        // Keep type and geometry at full size; narrow displays scroll horizontally.
        frame.size = NSSize(width: max(width, Self.drawingSize.width), height: contentHeight)
        return contentHeight
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let map, let concept = nodes.first else { return }
        let ink = OmniFrostedStyle.ink
        let parents = nodes.filter { $0.kind == .parent }
        if let first = parents.first, let last = parents.last {
            let rail = NSBezierPath()
            rail.move(to: NSPoint(x: min(first.frame.midX, concept.frame.midX), y: 57))
            rail.line(to: NSPoint(x: max(last.frame.midX, concept.frame.midX), y: 57))
            for node in parents {
                rail.move(to: NSPoint(x: node.frame.midX, y: node.frame.maxY))
                rail.line(to: NSPoint(x: node.frame.midX, y: 57))
            }
            rail.move(to: NSPoint(x: concept.frame.midX, y: 57))
            rail.line(to: NSPoint(x: concept.frame.midX, y: concept.frame.minY))
            stroke(rail, color: ink.withAlphaComponent(0.5))
        }
        let children = nodes.filter { $0.kind == .child }
        if let first = children.first, let last = children.last {
            let rail = NSBezierPath()
            rail.move(to: NSPoint(x: concept.frame.midX, y: concept.frame.maxY))
            rail.line(to: NSPoint(x: concept.frame.midX, y: 184))
            rail.move(to: NSPoint(x: first.frame.midX, y: 184))
            rail.line(to: NSPoint(x: last.frame.midX, y: 184))
            for node in children {
                rail.move(to: NSPoint(x: node.frame.midX, y: 184))
                rail.line(to: NSPoint(x: node.frame.midX, y: node.frame.minY))
            }
            stroke(rail, color: ink.withAlphaComponent(0.5))
        }
        // Route through the gutters above/below the right sibling. No sibling lines.
        for (i, node) in nodes.filter({ $0.kind == .nearMiss }).enumerated() {
            let lane: CGFloat = [65, 76, 152, 166][i]
            let start = NSPoint(x: concept.frame.maxX, y: 98 + CGFloat(i) * 8)
            let curve = NSBezierPath()
            curve.move(to: start)
            curve.curve(to: NSPoint(x: 330, y: lane), controlPoint1: NSPoint(x: 314, y: start.y), controlPoint2: NSPoint(x: 306, y: lane))
            curve.line(to: NSPoint(x: 434, y: lane))
            curve.curve(to: NSPoint(x: node.frame.minX, y: node.frame.midY),
                        controlPoint1: NSPoint(x: 446, y: lane), controlPoint2: NSPoint(x: 442, y: node.frame.midY))
            curve.setLineDash([4, 4], count: 2, phase: 0)
            stroke(curve, color: ink.withAlphaComponent(0.42))
        }
        for node in nodes {
            OmniDrawnPrimitives.outline(node.frame, filled: node.kind == .concept,
                                        opacity: node.kind == .sibling ? 0.28 : 0.55)
            let color = node.kind == .concept ? NSColor.textBackgroundColor
                : ink.withAlphaComponent(node.kind == .sibling ? 0.55 : 1)
            if node.kind == .concept {
                label(node.name, frame: NSRect(x: node.frame.minX + 6, y: node.frame.minY + (map.field == nil ? 12 : 5),
                                              width: node.frame.width - 12, height: 17), size: 13, color: color, weight: .semibold)
                if let field = map.field {
                    label(field.uppercased(), frame: NSRect(x: node.frame.minX + 5, y: node.frame.minY + 24,
                                                          width: node.frame.width - 10, height: 13), size: 9.5, color: color.withAlphaComponent(0.7))
                }
            } else if node.kind == .child {
                let words = node.name.split(separator: " ").map(String.init)
                let lines = words.count > 1 ? [words[0], words.dropFirst().joined(separator: " ")] : words
                for (i, line) in lines.enumerated() {
                    label(line, frame: NSRect(x: node.frame.minX + 4, y: node.frame.minY + (lines.count == 1 ? 10 : 3 + CGFloat(i) * 14),
                                              width: node.frame.width - 8, height: 14), size: 10.5, color: color)
                }
            } else {
                label(node.name, frame: node.frame.insetBy(dx: 5, dy: (node.frame.height - 16) / 2), size: 11.5, color: color)
            }
            if node.kind == .nearMiss, let caption = node.detail {
                label(caption, frame: NSRect(x: node.frame.minX, y: node.frame.maxY + 5, width: node.frame.width, height: 29),
                      size: 10.5, color: ink.withAlphaComponent(0.58), centered: false, wraps: true)
            }
        }
        text.draw(with: NSRect(x: 0, y: Self.drawingSize.height, width: Self.drawingSize.width, height: max(0, contentHeight - Self.drawingSize.height)),
                  options: [.usesLineFragmentOrigin])
    }

    private func stroke(_ path: NSBezierPath, color: NSColor) {
        OmniDrawnPrimitives.stroke(path, color: color)
    }

    private func label(_ text: String, frame: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular,
                       centered: Bool = true, wraps: Bool = false) {
        OmniDrawnPrimitives.label(text, frame: frame, size: size, color: color, weight: weight,
                                 alignment: centered ? .center : .left, wraps: wraps)
    }

    private static func footer(_ map: OmniConceptLensMap) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (key, value, dimmed) in [("DEFINITION", map.definition, false),
                                    ("RELATED", map.related.isEmpty ? nil : map.related.joined(separator: " · "), true)] {
            guard let value else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 4
            result.append(NSAttributedString(string: key + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: OmniFrostedStyle.secondaryInk,
                .kern: 0.4, .paragraphStyle: paragraph,
            ]))
            result.append(NSAttributedString(string: value, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: dimmed ? OmniFrostedStyle.secondaryInk : OmniFrostedStyle.ink,
                .paragraphStyle: paragraph,
            ]))
        }
        return result
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .image }
    public override func accessibilityLabel() -> String? {
        map.map { OmniConceptLensProjection.projectedText($0) }
    }
}

@MainActor
public enum OmniConceptLensCopyComposer {
    /// Explicit pixel drawing avoids screen-scale and ambient dark-appearance differences.
    public static func png(_ map: OmniConceptLensMap) -> Data? {
        let drawing = OmniConceptLensDrawing()
        drawing.appearance = NSAppearance(named: .aqua)
        drawing.display(map)
        let height = drawing.arrange(width: 604)
        return OmniDrawnCopyComposer.png(contentHeight: height) { drawing.draw(drawing.bounds) }
    }

    public static func item(map: OmniConceptLensMap, text: String) -> NSPasteboardItem? {
        guard let data = png(map) else { return nil }
        return OmniDrawnCopyComposer.item(png: data, text: text)
    }
}
