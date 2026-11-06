import AppKit
import OmniCore

@MainActor
public final class OmniMapDrawing: NSView {
    public private(set) var document: OmniMapDocument?
    public private(set) var scene = OmniMapScene(size: CGSize(width: 604, height: 292), nodes: [], paths: [], texts: [])
    public private(set) var contentHeight: CGFloat = 292
    private var honesty = NSAttributedString(string: "")
    private var hoverDetails: [String] = []
    public override var isFlipped: Bool { true }

    public func display(_ document: OmniMapDocument?) {
        guard self.document != document else { return }
        self.document = document
        removeAllToolTips()
        hoverDetails = []
        guard let document else { needsDisplay = true; return }
        scene = OmniMapLayouts.layout(document)
        for (frame, label) in scene.nodes.map({ ($0.frame, $0.label) }) + scene.texts.map({ ($0.frame, $0.label) }) {
            hoverDetails.append(label)
            addToolTip(frame, owner: self, userData: UnsafeMutableRawPointer(bitPattern: hoverDetails.count))
        }
        needsDisplay = true
    }

    @objc public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                          userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        return hoverDetails.indices.contains(index) ? hoverDetails[index] : ""
    }

    @discardableResult
    public func arrange(width: CGFloat) -> CGFloat {
        guard let document else { contentHeight = 0; return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let text = NSMutableAttributedString(string: document.honesty.kind == .leavesOut ? "LEAVES OUT  " : "BREAKS AT  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: OmniFrostedStyle.secondaryInk,
            .kern: 0.4, .paragraphStyle: paragraph,
        ])
        text.append(NSAttributedString(string: document.honesty.text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.ink, .paragraphStyle: paragraph,
        ]))
        honesty = text
        let height = ceil(text.boundingRect(with: NSSize(width: 604, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
        contentHeight = scene.size.height + 12 + height + 4
        frame.size = NSSize(width: max(604, width), height: contentHeight)
        return contentHeight
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard document != nil else { return }
        Self.draw(scene)
        honesty.draw(with: NSRect(x: 0, y: scene.size.height + 12, width: 604, height: max(0, contentHeight - scene.size.height - 12)),
                     options: [.usesLineFragmentOrigin])
    }

    /// Full-size results and miniatures use the identical scene and native renderer.
    public static func draw(_ scene: OmniMapScene) {
        let ink = OmniFrostedStyle.ink
        for path in scene.paths {
            let line = NSBezierPath()
            var cursor = CGPoint.zero
            var tangent = CGPoint.zero
            for segment in path.segments {
                switch segment {
                case .move(let point): line.move(to: point); cursor = point
                case .line(let point): tangent = cursor; line.line(to: point); cursor = point
                case .curve(let to, let c1, let c2):
                    tangent = c2
                    line.curve(to: to, controlPoint1: c1, controlPoint2: c2)
                    cursor = to
                }
            }
            if path.dashed { line.setLineDash([4, 4], count: 2, phase: 0) }
            let color = ink.withAlphaComponent(path.dimmed ? 0.25 : 0.55)
            OmniDrawnPrimitives.stroke(line, color: color)
            if path.arrow {
                let angle = atan2(cursor.y - tangent.y, cursor.x - tangent.x)
                let head = NSBezierPath()
                for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    head.move(to: cursor)
                    head.line(to: CGPoint(x: cursor.x - 6 * cos(angle + offset), y: cursor.y - 6 * sin(angle + offset)))
                }
                OmniDrawnPrimitives.stroke(head, color: color)
            }
        }
        for node in scene.nodes {
            OmniDrawnPrimitives.outline(node.frame, filled: node.filled, opacity: node.dimmed ? 0.25 : 0.55,
                                        circle: node.shape == .circle)
            let color = node.filled ? NSColor.textBackgroundColor : ink.withAlphaComponent(node.dimmed ? 0.5 : 1)
            guard node.frame.width >= 32, node.frame.height >= 16 else { continue }
            let height: CGFloat = 16
            OmniDrawnPrimitives.label(node.label, frame: CGRect(x: node.frame.minX + 5, y: node.frame.midY - height / 2,
                                                               width: max(1, node.frame.width - 10), height: height),
                                      size: 11.5, color: color, weight: node.filled ? .semibold : .regular)
        }
        for text in scene.texts {
            let heading = text.role == .heading
            let caption = text.role == .caption
            let alignment: NSTextAlignment = text.alignment == .leading ? .left : text.alignment == .trailing ? .right : .center
            OmniDrawnPrimitives.label(heading ? text.label.uppercased() : text.label, frame: text.frame,
                                      size: heading ? 9.5 : caption ? 10.5 : 11.5,
                                      color: ink.withAlphaComponent(text.dimmed ? 0.42 : heading || caption ? 0.62 : 1),
                                      alignment: alignment, wraps: caption, smallCaps: heading)
        }
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .image }
    public override func accessibilityLabel() -> String? { document.map(OmniMapTextOutline.format) }
}

@MainActor
public enum OmniMapCopyComposer {
    public static func png(_ document: OmniMapDocument) -> Data? {
        let drawing = OmniMapDrawing()
        drawing.appearance = NSAppearance(named: .aqua)
        drawing.display(document)
        let height = drawing.arrange(width: 604)
        return OmniDrawnCopyComposer.png(contentHeight: height) { drawing.draw(drawing.bounds) }
    }

    public static func item(_ document: OmniMapDocument) -> NSPasteboardItem? {
        guard let png = png(document) else { return nil }
        return OmniDrawnCopyComposer.item(png: png, text: OmniMapTextOutline.format(document))
    }
}

public enum OmniMapTextOutline {
    public static func format(_ document: OmniMapDocument) -> String {
        var lines = [document.title, document.form.title + " · " + document.lineMeaning]
        switch document.data {
        case .tree(let tree):
            lines.append(tree.rootLabel)
            func appendChildren(of parent: String?, depth: Int) {
                guard depth < 3 else { return }
                for node in tree.nodes where node.parent == parent {
                    lines.append(String(repeating: "  ", count: depth) + (node.edge == .dashed ? "- Objects to: " : "- ") + node.label)
                    appendChildren(of: node.id, depth: depth + 1)
                }
            }
            appendChildren(of: nil, depth: 0)
        case .radial(let radial):
            lines.append(radial.hub)
            for spoke in radial.spokes {
                lines.append("- " + spoke.label + (spoke.edgeLabel.map { " (" + $0 + ")" } ?? ""))
                lines.append(contentsOf: spoke.children.map { "  - " + $0 })
            }
        case .bridge(let bridge):
            lines.append("New: " + bridge.newSide + " · Familiar: " + bridge.familiarSide)
            lines.append(contentsOf: bridge.pairs.map { $0.new + " → " + $0.familiar })
            lines.append("Correspondence, not equivalence.")
        case .matrix(let matrix):
            lines.append(([""] + matrix.criteria).joined(separator: "\t"))
            for (i, row) in matrix.rows.enumerated() {
                let cells = matrix.cells.indices.contains(i) ? matrix.cells[i] : []
                lines.append(([row + (matrix.offered.contains(i) ? " (offered)" : "")] + cells).joined(separator: "\t"))
            }
        case .spectrum(let spectrum):
            lines.append(spectrum.axis.low + " → " + spectrum.axis.high)
            if let axis2 = spectrum.axis2 { lines.append(axis2.low + " → " + axis2.high) }
            for point in spectrum.points {
                lines.append("- " + point.label + ": " + String(point.x) + (point.y.map { ", " + String($0) } ?? ""))
            }
        case .loop(let loop):
            for link in loop.links where loop.variables.indices.contains(link.from) && loop.variables.indices.contains(link.to) {
                lines.append(loop.variables[link.from] + " —(" + link.sign.rawValue + ")→ " + loop.variables[link.to])
            }
            lines.append(loop.polarity == .reinforcing ? "R = reinforcing" : "B = balancing")
        case .flow(let flow):
            lines.append(flow.steps.joined(separator: " → "))
            if let branch = flow.branch, flow.steps.indices.contains(branch.at) {
                lines.append("Fork at " + flow.steps[branch.at] + " (" + branch.label + "): " + branch.steps.joined(separator: " → "))
            }
        }
        lines.append((document.honesty.kind == .leavesOut ? "Leaves out: " : "Breaks at: ") + document.honesty.text)
        return lines.joined(separator: "\n")
    }
}
