import AppKit
import Foundation
import OmniCore

public struct OmniRegexRailroadScene: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public enum Style: Sendable, Equatable { case literal, characterClass, anchor, frame, caption, endpoint }
        public let frame: CGRect
        public let label: String
        public let raw: String
        public let style: Style
        public let dashed: Bool
    }

    public struct Segment: Sendable, Equatable {
        public let from: CGPoint
        public let to: CGPoint
    }

    public let size: CGSize
    public let nodes: [Node]
    public let segments: [Segment]
}

/// Pure layout in a top-left coordinate system. All drawing remains within 604 pt.
public enum OmniRegexRailroad {
    public static let width: CGFloat = 604

    public static func layout(_ ast: RegexNode) -> OmniRegexRailroadScene {
        let fragment = make(ast, limit: width - 48)
        let origin = CGPoint(x: 24, y: 12)
        let startY = origin.y + fragment.entryY
        let endY = origin.y + fragment.exitY
        let endpoints: [OmniRegexRailroadScene.Node] = [
            .init(frame: CGRect(x: 4, y: startY - 4, width: 8, height: 8),
                  label: "", raw: "", style: .endpoint, dashed: false),
            .init(frame: CGRect(x: origin.x + fragment.width + 12, y: endY - 4, width: 8, height: 8),
                  label: "", raw: "", style: .endpoint, dashed: false)
        ]
        return .init(size: CGSize(width: width, height: fragment.height + 24),
                     nodes: endpoints + fragment.nodes.map { node in
                         .init(frame: node.frame.offsetBy(dx: origin.x, dy: origin.y), label: node.label,
                               raw: node.raw, style: node.style, dashed: node.dashed)
                     },
                     segments: [.init(from: CGPoint(x: 12, y: startY), to: CGPoint(x: origin.x, y: startY)),
                                .init(from: CGPoint(x: origin.x + fragment.width, y: endY),
                                      to: CGPoint(x: origin.x + fragment.width + 12, y: endY))]
                         + fragment.segments.map { segment in
                         .init(from: CGPoint(x: segment.from.x + origin.x, y: segment.from.y + origin.y),
                               to: CGPoint(x: segment.to.x + origin.x, y: segment.to.y + origin.y))
                     })
    }

    private struct Fragment {
        var width: CGFloat
        var height: CGFloat
        var entryY: CGFloat
        var exitY: CGFloat
        var nodes: [OmniRegexRailroadScene.Node]
        var segments: [OmniRegexRailroadScene.Segment]

        mutating func append(_ other: Fragment, x: CGFloat, y: CGFloat) {
            nodes += other.nodes.map { node in
                .init(frame: node.frame.offsetBy(dx: x, dy: y), label: node.label,
                      raw: node.raw, style: node.style, dashed: node.dashed)
            }
            segments += other.segments.map { segment in
                .init(from: CGPoint(x: segment.from.x + x, y: segment.from.y + y),
                      to: CGPoint(x: segment.to.x + x, y: segment.to.y + y))
            }
        }

        mutating func connect(_ from: CGPoint, _ to: CGPoint) {
            segments.append(.init(from: from, to: to))
        }
    }

    private static func make(_ ast: RegexNode, limit: CGFloat) -> Fragment {
        switch ast.kind {
        case .sequence: return sequence(ast.children, limit: limit)
        case .alternation: return alternatives(ast, limit: limit)
        case .group(let label): return framed(ast, label: label, dashed: true, limit: limit)
        case .lookaround(let label): return framed(ast, label: label, dashed: false, limit: limit)
        case .quantified(let label, let minimum, let maximum):
            return quantified(ast, label: label, minimum: minimum, maximum: maximum, limit: limit)
        case .literal(let label): return atom(label, raw: ast.raw, style: .literal, limit: limit)
        case .characterClass(let label): return atom(label, raw: ast.raw, style: .characterClass, limit: limit)
        case .anchor: return atom(ast.raw, raw: ast.raw, style: .anchor, limit: limit)
        case .backreference(let number): return atom("= group \(number)", raw: ast.raw, style: .literal, limit: limit)
        case .namedBackreference(let name): return atom("= group \(name)", raw: ast.raw, style: .literal, limit: limit)
        case .flags(let flags): return atom("flags \(flags)", raw: ast.raw, style: .caption, limit: limit)
        }
    }

    private static func atom(_ label: String, raw: String, style: OmniRegexRailroadScene.Node.Style,
                             limit: CGFloat) -> Fragment {
        let shown = label == " " ? "␣" : label
        let width = min(max(24, CGFloat(shown.count) * 7 + 20), min(170, limit))
        let height: CGFloat = style == .anchor || style == .caption ? 22 : 26
        return .init(width: width, height: height, entryY: height / 2, exitY: height / 2,
                     nodes: [.init(frame: CGRect(x: 0, y: 0, width: width, height: height),
                                   label: shown, raw: raw, style: style, dashed: false)], segments: [])
    }

    private static func sequence(_ children: [RegexNode], limit: CGFloat) -> Fragment {
        let drawable = children.filter { if case .flags = $0.kind { false } else { true } }
        guard !drawable.isEmpty else {
            return .init(width: 12, height: 26, entryY: 13, exitY: 13, nodes: [],
                         segments: [.init(from: CGPoint(x: 0, y: 13), to: CGPoint(x: 12, y: 13))])
        }
        let gap: CGFloat = 18
        let rowGap: CGFloat = 16
        let gutter = padding(limit: limit, depth: 1 + (drawable.map(depth).max() ?? 0), preferred: 12)
        var rows: [[Fragment]] = [[]]
        var rowWidths: [CGFloat] = [0]
        for child in drawable {
            let fragment = make(child, limit: limit - gutter)
            let index = rows.count - 1
            let nextWidth = rowWidths[index] + (rows[index].isEmpty ? 0 : gap) + fragment.width
            if nextWidth > limit - gutter && !rows[index].isEmpty {
                rows.append([fragment]); rowWidths.append(fragment.width)
            } else {
                rows[index].append(fragment); rowWidths[index] = nextWidth
            }
        }
        var result = Fragment(width: rowWidths.max() ?? 12, height: 0, entryY: 0, exitY: 0,
                              nodes: [], segments: [])
        var previousExit: CGPoint?
        for (rowIndex, row) in rows.enumerated() {
            let baseline = row.map(\.entryY).max() ?? 13
            let rowHeight = baseline + (row.map { $0.height - $0.entryY }.max() ?? 13)
            var x: CGFloat = 0
            var firstEntry: CGPoint?
            var lastExit: CGPoint?
            for fragment in row {
                let y = result.height + baseline - fragment.entryY
                result.append(fragment, x: x, y: y)
                let entry = CGPoint(x: x, y: y + fragment.entryY)
                let exit = CGPoint(x: x + fragment.width, y: y + fragment.exitY)
                if firstEntry == nil { firstEntry = entry }
                if let lastExit { result.connect(lastExit, entry) }
                lastExit = exit
                x += fragment.width + gap
            }
            if let previousExit, let firstEntry {
                let railX = (rowWidths.max() ?? 0) + gutter
                let gutterY = result.height - rowGap / 2
                result.connect(previousExit, CGPoint(x: railX, y: previousExit.y))
                result.connect(CGPoint(x: railX, y: previousExit.y), CGPoint(x: railX, y: gutterY))
                result.connect(CGPoint(x: railX, y: gutterY), CGPoint(x: 0, y: gutterY))
                result.connect(CGPoint(x: 0, y: gutterY), firstEntry)
                result.width = max(result.width, railX)
            }
            previousExit = lastExit
            if rowIndex == 0 { result.entryY = firstEntry?.y ?? baseline }
            result.exitY = lastExit?.y ?? baseline
            result.height += rowHeight + rowGap
        }
        result.height -= rowGap
        if let previousExit, previousExit.x < result.width {
            result.connect(previousExit, CGPoint(x: result.width, y: previousExit.y))
        }
        return result
    }

    private static func framed(_ ast: RegexNode, label: String?, dashed: Bool,
                               limit: CGFloat) -> Fragment {
        let inset = padding(limit: limit, depth: depth(ast), preferred: 12)
        let titleHeight: CGFloat = label == nil ? 11 : 23
        let child = make(ast.children[0], limit: limit - 2 * inset)
        let width = min(limit, child.width + 2 * inset)
        let height = child.height + titleHeight + 12
        var fragment = Fragment(width: width, height: height,
                                entryY: titleHeight + child.entryY, exitY: titleHeight + child.exitY,
                                nodes: [.init(frame: CGRect(x: 0, y: 0, width: width, height: height),
                                              label: label ?? "", raw: ast.raw, style: .frame, dashed: dashed)],
                                segments: [])
        fragment.append(child, x: inset, y: titleHeight)
        fragment.connect(CGPoint(x: 0, y: fragment.entryY), CGPoint(x: inset, y: fragment.entryY))
        fragment.connect(CGPoint(x: inset + child.width, y: fragment.exitY),
                         CGPoint(x: width, y: fragment.exitY))
        return fragment
    }

    private static func quantified(_ ast: RegexNode, label: String, minimum: Int,
                                   maximum: Int?, limit: CGFloat) -> Fragment {
        if maximum == 0 {
            return atom("0×", raw: ast.raw, style: .caption, limit: limit)
        }
        let inset = padding(limit: limit, depth: depth(ast), preferred: 10)
        let child = make(ast.children[0], limit: limit - 2 * inset)
        let optional = minimum == 0
        let repeated = maximum == nil || (maximum ?? 1) > 1
        let titleHeight: CGFloat = repeated ? 24 : 4
        let width = min(limit, max(child.width + 2 * inset, CGFloat(label.count) * 7 + 12))
        let height = child.height + titleHeight + (optional ? 27 : 8)
        let childX = (width - child.width) / 2
        let entryY = titleHeight + child.entryY
        let exitY = titleHeight + child.exitY
        let captionY = optional && !repeated ? height - 15 : 0
        var fragment = Fragment(width: width, height: height, entryY: entryY, exitY: exitY,
                                nodes: [.init(frame: CGRect(x: 0, y: captionY, width: width, height: 17),
                                              label: label, raw: ast.raw, style: .caption, dashed: false)], segments: [])
        fragment.append(child, x: childX, y: titleHeight)
        fragment.connect(CGPoint(x: 0, y: entryY), CGPoint(x: childX, y: entryY))
        fragment.connect(CGPoint(x: childX + child.width, y: exitY), CGPoint(x: width, y: exitY))
        if optional {
            let y = height - 22
            fragment.connect(CGPoint(x: 0, y: entryY), CGPoint(x: 0, y: y))
            fragment.connect(CGPoint(x: 0, y: y), CGPoint(x: width, y: y))
            fragment.connect(CGPoint(x: width, y: y), CGPoint(x: width, y: exitY))
            if repeated {
                fragment.nodes.append(.init(frame: CGRect(x: 0, y: height - 15, width: width, height: 15),
                                            label: "optional", raw: ast.raw, style: .caption, dashed: false))
            }
        }
        if repeated {
            let y: CGFloat = 19
            fragment.connect(CGPoint(x: width, y: exitY), CGPoint(x: width, y: y))
            fragment.connect(CGPoint(x: width, y: y), CGPoint(x: 0, y: y))
            fragment.connect(CGPoint(x: 0, y: y), CGPoint(x: 0, y: entryY))
        }
        return fragment
    }

    private static func alternatives(_ ast: RegexNode, limit: CGFloat) -> Fragment {
        let inset = padding(limit: limit, depth: depth(ast), preferred: 18)
        let gap: CGFloat = 12
        let branches = ast.children.map { make($0, limit: limit - inset * 2) }
        let width = min(limit, (branches.map(\.width).max() ?? 12) + inset * 2)
        var fragment = Fragment(width: width, height: 0, entryY: branches[0].entryY,
                                exitY: branches[0].exitY, nodes: [], segments: [])
        for branch in branches {
            let y = fragment.height
            fragment.append(branch, x: inset, y: y)
            fragment.connect(CGPoint(x: 0, y: y + branch.entryY), CGPoint(x: inset, y: y + branch.entryY))
            fragment.connect(CGPoint(x: inset + branch.width, y: y + branch.exitY),
                             CGPoint(x: width, y: y + branch.exitY))
            fragment.height += branch.height + gap
        }
        fragment.height -= gap
        if branches.count > 1 {
            let lastEntry = fragment.height - branches.last!.height + branches.last!.entryY
            let lastExit = fragment.height - branches.last!.height + branches.last!.exitY
            fragment.connect(CGPoint(x: 0, y: fragment.entryY), CGPoint(x: 0, y: lastEntry))
            fragment.connect(CGPoint(x: width, y: fragment.exitY), CGPoint(x: width, y: lastExit))
        }
        return fragment
    }

    private static func depth(_ ast: RegexNode) -> Int {
        let childDepth = ast.children.map(depth).max() ?? 0
        switch ast.kind {
        case .sequence, .alternation, .quantified, .group, .lookaround: return 1 + childDepth
        default: return 0
        }
    }

    private static func padding(limit: CGFloat, depth: Int, preferred: CGFloat) -> CGFloat {
        min(preferred, max(0, (limit - 48) / CGFloat(max(1, depth * 2))))
    }
}

public final class OmniRegexRailroadView: NSView {
    public var scene: OmniRegexRailroadScene {
        didSet { frame.size = scene.size; invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    private var hoverNode: OmniRegexRailroadScene.Node?

    public init(scene: OmniRegexRailroadScene) {
        self.scene = scene
        super.init(frame: CGRect(origin: .zero, size: scene.size))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }
    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { scene.size }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let ink = OmniFrostedStyle.ink
        for segment in scene.segments {
            let path = NSBezierPath()
            path.move(to: segment.from)
            path.line(to: segment.to)
            path.lineWidth = 1
            ink.withAlphaComponent(0.55).setStroke()
            path.stroke()
        }
        for node in scene.nodes {
            if node.style == .endpoint {
                ink.setFill()
                NSBezierPath(ovalIn: node.frame).fill()
                continue
            }
            let radius: CGFloat = node.style == .characterClass || node.style == .anchor
                ? node.frame.height / 2 : node.style == .frame ? 7 : 3
            let path = NSBezierPath(roundedRect: node.frame, xRadius: radius, yRadius: radius)
            switch node.style {
            case .characterClass: OmniFrostedStyle.modeTokenFill.setFill()
            case .anchor: OmniFrostedStyle.unresolvedTokenFill.setFill()
            case .literal: OmniFrostedStyle.controlFill.setFill()
            case .frame, .caption, .endpoint: NSColor.clear.setFill()
            }
            if node.style != .caption {
                path.fill()
                if node.dashed { path.setLineDash([3, 3], count: 2, phase: 0) }
                (node.style == .characterClass ? OmniFrostedStyle.mode : ink.withAlphaComponent(0.52)).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            let font = node.style == .frame || node.style == .caption
                ? NSFont.systemFont(ofSize: 10, weight: .medium)
                : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            let textFrame = node.style == .frame
                ? CGRect(x: node.frame.minX + 4, y: node.frame.minY + 2,
                         width: node.frame.width - 8, height: 15)
                : node.frame.insetBy(dx: 4, dy: 4)
            let textInk: NSColor = node.style == .characterClass ? OmniFrostedStyle.mode
                : node.style == .anchor || node.style == .caption || node.style == .frame
                    ? OmniFrostedStyle.secondaryInk : ink
            (node.label as NSString).draw(in: textFrame,
                                          withAttributes: [.font: font, .foregroundColor: textInk,
                                                           .paragraphStyle: style])
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverNode = scene.nodes.reversed().first { !$0.raw.isEmpty && $0.frame.contains(point) }
        toolTip = hoverNode?.raw
    }
}
