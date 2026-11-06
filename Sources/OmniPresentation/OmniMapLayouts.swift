import CoreGraphics
import Foundation
import OmniCore

/// Renderer-independent, top-left-origin drawing instructions for a native map.
public struct OmniMapScene: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public enum Shape: Sendable, Equatable { case rounded, circle }
        public var frame: CGRect
        public var label: String
        public var filled: Bool
        public var dimmed: Bool
        public var shape: Shape

        public init(frame: CGRect, label: String, filled: Bool = false, dimmed: Bool = false,
                    shape: Shape = .rounded) {
            self.frame = frame
            self.label = label
            self.filled = filled
            self.dimmed = dimmed
            self.shape = shape
        }
    }

    public enum Segment: Sendable, Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
    }

    public struct Path: Sendable, Equatable {
        public var segments: [Segment]
        public var dashed: Bool
        public var arrow: Bool
        public var dimmed: Bool

        public init(segments: [Segment], dashed: Bool = false, arrow: Bool = false,
                    dimmed: Bool = false) {
            self.segments = segments
            self.dashed = dashed
            self.arrow = arrow
            self.dimmed = dimmed
        }
    }

    public struct Text: Sendable, Equatable {
        public enum Role: Sendable, Equatable { case body, caption, heading }
        public enum Alignment: Sendable, Equatable { case leading, center, trailing }
        public var frame: CGRect
        public var label: String
        public var role: Role
        public var dimmed: Bool
        public var alignment: Alignment

        public init(frame: CGRect, label: String, role: Role = .body, dimmed: Bool = false,
                    alignment: Alignment = .center) {
            self.frame = frame
            self.label = label
            self.role = role
            self.dimmed = dimmed
            self.alignment = alignment
        }
    }

    public var size: CGSize
    public var nodes: [Node]
    public var paths: [Path]
    public var texts: [Text]

    public init(size: CGSize, nodes: [Node], paths: [Path], texts: [Text]) {
        self.size = size
        self.nodes = nodes
        self.paths = paths
        self.texts = texts
    }
}

/// Deterministic layouts. Validated data is the contract; defensive caps keep bad fixtures on canvas.
public enum OmniMapLayouts {
    private static let width: CGFloat = 604

    public static func layout(_ document: OmniMapDocument) -> OmniMapScene {
        switch document.data {
        case .tree(let data): tree(data)
        case .radial(let data): radial(data)
        case .bridge(let data): bridge(data)
        case .matrix(let data): matrix(data)
        case .spectrum(let data): spectrum(data)
        case .loop(let data): loop(data)
        case .flow(let data): flow(data)
        }
    }

    public static func tree(_ data: OmniMapTree) -> OmniMapScene {
        var nodes = [OmniMapScene.Node(frame: CGRect(x: 242, y: 8, width: 120, height: 30),
                                           label: data.rootLabel)]
        var paths: [OmniMapScene.Path] = []
        let entries = Array(data.nodes.prefix(11))
        let ids = Set(entries.map(\.id))
        let levelOne = entries.filter { $0.parent == nil || !ids.contains($0.parent ?? "") }
        let levelOneIDs = Set(levelOne.map(\.id))
        let parentOrder = Dictionary(uniqueKeysWithValues: levelOne.enumerated().map { ($0.element.id, $0.offset) })
        let levelTwo = entries.enumerated()
            .filter { !levelOneIDs.contains($0.element.id) }
            .sorted { left, right in
                let leftParent = parentOrder[left.element.parent ?? ""] ?? Int.max
                let rightParent = parentOrder[right.element.parent ?? ""] ?? Int.max
                return leftParent == rightParent ? left.offset < right.offset : leftParent < rightParent
            }
            .map(\.element)
        let firstFrames = tierFrames(count: levelOne.count, y: 100)
        let secondFrames = tierFrames(count: levelTwo.count, y: 205)
        var framesByID: [String: CGRect] = [:]
        for (entry, frame) in zip(levelOne, firstFrames) {
            framesByID[entry.id] = frame
            nodes.append(.init(frame: frame, label: entry.label))
        }
        for (entry, frame) in zip(levelTwo, secondFrames) {
            framesByID[entry.id] = frame
            nodes.append(.init(frame: frame, label: entry.label))
        }
        for entry in entries {
            guard let child = framesByID[entry.id] else { continue }
            let parent = entry.parent.flatMap { framesByID[$0] } ?? nodes[0].frame
            paths.append(.init(segments: [.move(CGPoint(x: parent.midX, y: parent.maxY)),
                                           .line(CGPoint(x: child.midX, y: child.minY))],
                               dashed: entry.edge == .dashed))
        }
        return .init(size: CGSize(width: width, height: 250), nodes: nodes, paths: paths,
                     texts: [])
    }

    public static func radial(_ data: OmniMapRadial) -> OmniMapScene {
        let hub = CGRect(x: 250, y: 122, width: 104, height: 32)
        var nodes: [OmniMapScene.Node] = [.init(frame: hub, label: data.hub, filled: true)]
        var paths: [OmniMapScene.Path] = []
        var texts: [OmniMapScene.Text] = []
        for (index, spoke) in data.spokes.prefix(8).enumerated() {
            let left = index < 4
            let row = index % 4
            let y = CGFloat(19 + row * 66)
            let frame = CGRect(x: left ? 112 : 374, y: y, width: 118, height: 28)
            nodes.append(.init(frame: frame, label: spoke.label, dimmed: spoke.offered))
            let from = CGPoint(x: left ? hub.minX : hub.maxX, y: hub.midY)
            let to = CGPoint(x: left ? frame.maxX : frame.minX, y: frame.midY)
            paths.append(.init(segments: [.move(from), .line(to)], dimmed: spoke.offered))
            if let label = spoke.edgeLabel {
                texts.append(.init(frame: CGRect(x: frame.minX + 8, y: frame.minY - 18,
                                                 width: 102, height: 14), label: label, role: .caption,
                                   dimmed: spoke.offered))
            }
            for (childIndex, child) in spoke.children.prefix(2).enumerated() {
                let childX: CGFloat = left ? 6 : 503
                let childFrame = CGRect(x: childX, y: y + CGFloat(childIndex * 24), width: 95, height: 20)
                nodes.append(.init(frame: childFrame, label: child, dimmed: spoke.offered))
                let start = left ? CGPoint(x: childFrame.maxX, y: childFrame.midY) : CGPoint(x: frame.maxX, y: frame.midY)
                let end = left ? CGPoint(x: frame.minX, y: frame.midY) : CGPoint(x: childFrame.minX, y: childFrame.midY)
                paths.append(.init(segments: [.move(start), .line(end)], dimmed: spoke.offered))
            }
        }
        return .init(size: CGSize(width: width, height: 292), nodes: nodes, paths: paths, texts: texts)
    }

    public static func bridge(_ data: OmniMapBridge) -> OmniMapScene {
        let pairs = Array(data.pairs.prefix(5))
        var nodes: [OmniMapScene.Node] = []
        var paths: [OmniMapScene.Path] = []
        for (index, pair) in pairs.enumerated() {
            let y = CGFloat(26 + index * 36)
            nodes.append(.init(frame: CGRect(x: 40, y: y, width: 180, height: 26), label: pair.new))
            nodes.append(.init(frame: CGRect(x: 384, y: y, width: 180, height: 26), label: pair.familiar))
            paths.append(.init(segments: [.move(CGPoint(x: 222, y: y + 13)),
                                           .line(CGPoint(x: 382, y: y + 13))], arrow: true))
        }
        let height = CGFloat(34 + pairs.count * 36)
        let texts: [OmniMapScene.Text] = [
            .init(frame: CGRect(x: 40, y: 1, width: 180, height: 17), label: "NEW · \(data.newSide)", role: .heading),
            .init(frame: CGRect(x: 384, y: 1, width: 180, height: 17), label: "FAMILIAR · \(data.familiarSide)", role: .heading),
            .init(frame: CGRect(x: 162, y: height - 18, width: 280, height: 16),
                  label: "correspondence, not equivalence", role: .caption)
        ]
        return .init(size: CGSize(width: width, height: height), nodes: nodes, paths: paths, texts: texts)
    }

    public static func matrix(_ data: OmniMapMatrix) -> OmniMapScene {
        let rows = Array(data.rows.prefix(5))
        let criteria = Array(data.criteria.prefix(4))
        let colWidth = CGFloat(494) / CGFloat(max(criteria.count, 1))
        let height = CGFloat(32 + rows.count * 32)
        var paths: [OmniMapScene.Path] = []
        var texts: [OmniMapScene.Text] = []
        for (column, criterion) in criteria.enumerated() {
            let x = 110 + CGFloat(column) * colWidth
            texts.append(.init(frame: CGRect(x: x, y: 2, width: colWidth, height: 20),
                               label: criterion.uppercased(), role: .heading))
            paths.append(.init(segments: [.move(CGPoint(x: x, y: 28)),
                                           .line(CGPoint(x: x, y: height - 4))]))
        }
        for row in 0...rows.count {
            let y = CGFloat(28 + row * 32)
            paths.append(.init(segments: [.move(CGPoint(x: 110, y: y)),
                                           .line(CGPoint(x: 604, y: y))]))
        }
        for (row, label) in rows.enumerated() {
            let dimmed = data.offered.contains(row)
            let y = CGFloat(33 + row * 32)
            texts.append(.init(frame: CGRect(x: 4, y: y, width: 100, height: 23),
                               label: label, role: .body, dimmed: dimmed, alignment: .trailing))
            for column in criteria.indices {
                let value = data.cells.indices.contains(row) && data.cells[row].indices.contains(column)
                    ? data.cells[row][column] : "—"
                texts.append(.init(frame: CGRect(x: 110 + CGFloat(column) * colWidth, y: y,
                                                 width: colWidth, height: 23), label: value,
                                   dimmed: dimmed || value == "—"))
            }
        }
        return .init(size: CGSize(width: width, height: height), nodes: [], paths: paths, texts: texts)
    }

    public static func spectrum(_ data: OmniMapSpectrum) -> OmniMapScene {
        let hasSecondAxis = data.axis2 != nil
        let centerY: CGFloat = 136
        var paths: [OmniMapScene.Path] = [
            .init(segments: [.move(CGPoint(x: 74, y: centerY)), .line(CGPoint(x: 530, y: centerY))], arrow: true)
        ]
        if hasSecondAxis {
            paths.append(.init(segments: [.move(CGPoint(x: 302, y: 32)),
                                           .line(CGPoint(x: 302, y: 240))], arrow: true))
        }
        var texts: [OmniMapScene.Text] = [
            .init(frame: CGRect(x: 8, y: 126, width: 62, height: 20), label: data.axis.low, role: .caption),
            .init(frame: CGRect(x: 534, y: 126, width: 62, height: 20), label: data.axis.high, role: .caption)
        ]
        if let axis2 = data.axis2 {
            texts.append(.init(frame: CGRect(x: 247, y: 5, width: 110, height: 18), label: axis2.low, role: .caption))
            texts.append(.init(frame: CGRect(x: 247, y: 253, width: 110, height: 18), label: axis2.high, role: .caption))
        }
        var nodes: [OmniMapScene.Node] = []
        var labels: [CGRect] = []
        for (index, point) in data.points.prefix(7).enumerated() {
            let x = 74 + CGFloat(min(max(point.x, 0), 1)) * 456
            let y = hasSecondAxis ? 32 + CGFloat(min(max(point.y ?? 0.5, 0), 1)) * 208 : centerY
            nodes.append(.init(frame: CGRect(x: x - 5, y: y - 5, width: 10, height: 10),
                               label: point.label, shape: .circle))
            let candidates = [CGRect(x: x - 52, y: y - 28, width: 104, height: 18),
                              CGRect(x: x - 52, y: y + 10, width: 104, height: 18),
                              CGRect(x: x - 52, y: y - 46, width: 104, height: 18),
                              CGRect(x: x - 52, y: y + 28, width: 104, height: 18),
                              CGRect(x: x + 12, y: y - 28, width: 104, height: 18),
                              CGRect(x: x - 116, y: y - 28, width: 104, height: 18)]
            let preferred = hasSecondAxis ? candidates :
                (index.isMultiple(of: 2) ? candidates : [candidates[1], candidates[0], candidates[3], candidates[2]])
            var occupied = labels + texts.map(\.frame)
            occupied.append(CGRect(x: 68, y: centerY - 3, width: 468, height: 6))
            if hasSecondAxis { occupied.append(CGRect(x: 299, y: 26, width: 6, height: 220)) }
            let fallbackRows: [CGFloat] = [44, 64, 84, 104, 156, 176, 196, 216]
            let fallbackColumns: [CGFloat] = [8, 124, 240, 356, 472]
            let fallbacks = fallbackRows.flatMap { y in fallbackColumns.map { x in CGRect(x: x, y: y, width: 104, height: 18) } }
            let frame = (preferred + fallbacks).first { candidate in
                candidate.minX >= 1 && candidate.maxX <= width && candidate.minY >= 0 &&
                    candidate.maxY <= 280 && !occupied.contains(where: { $0.intersects(candidate) })
            } ?? CGRect(x: min(max(x - 52, 1), 499), y: index.isMultiple(of: 2) ? 78 : 166,
                        width: 104, height: 18)
            labels.append(frame)
            texts.append(.init(frame: frame, label: point.label, role: .caption))
        }
        return .init(size: CGSize(width: width, height: 280), nodes: nodes, paths: paths, texts: texts)
    }

    public static func loop(_ data: OmniMapLoop) -> OmniMapScene {
        let labels = Array(data.variables.prefix(6))
        let count = labels.count
        var nodes: [OmniMapScene.Node] = []
        var paths: [OmniMapScene.Path] = []
        var texts: [OmniMapScene.Text] = []
        guard count > 0 else { return .init(size: CGSize(width: width, height: 280), nodes: [], paths: [], texts: []) }
        // Model arrays need not already be in causal order. Place the validated
        // cycle around the ring, retaining original indices for link endpoints.
        var cycle = [0]
        var cursor = 0
        while cycle.count < count, let next = data.links.first(where: { $0.from == cursor })?.to,
              labels.indices.contains(next), !cycle.contains(next) {
            cycle.append(next)
            cursor = next
        }
        if cycle.count != count { cycle = Array(labels.indices) }
        let slots = Dictionary(uniqueKeysWithValues: cycle.enumerated().map { ($0.element, $0.offset) })
        let frames: [CGRect] = labels.indices.map { index in
            let angle = -Double.pi / 2 + Double(slots[index] ?? index) * 2 * Double.pi / Double(count)
            let x = 302 + 220 * cos(angle)
            let y = 139 + 105 * sin(angle)
            return CGRect(x: min(max(x - 65, 5), 469), y: min(max(y - 14, 4), 251),
                          width: 130, height: 28)
        }
        for (label, frame) in zip(labels, frames) { nodes.append(.init(frame: frame, label: label)) }
        for link in data.links {
            guard frames.indices.contains(link.from), frames.indices.contains(link.to) else { continue }
            let from = frames[link.from]
            let to = frames[link.to]
            let (start, end) = endpoints(from: from, to: to)
            let midpoint: CGPoint
            if count == 2 {
                // The two directed edges need separate sides of the ring.
                let side: CGFloat = link.from == 0 ? 1 : -1
                let control = CGPoint(x: 302 + side * 116, y: 139)
                paths.append(.init(segments: [.move(start),
                                               .curve(to: end, control1: control, control2: control)],
                                   arrow: true))
                midpoint = CGPoint(x: 302 + side * 64, y: 139)
            } else {
                paths.append(.init(segments: [.move(start), .line(end)], arrow: true))
                midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            }
            let signX = min(max(midpoint.x - 9, 2), 584)
            let signY = min(max(midpoint.y - 22, 2), 268)
            texts.append(.init(frame: CGRect(x: signX, y: signY, width: 18, height: 16),
                               label: link.sign.rawValue, role: .caption))
        }
        nodes.append(.init(frame: CGRect(x: 284, y: 121, width: 36, height: 36),
                           label: data.polarity.rawValue, filled: true, shape: .circle))
        texts.append(.init(frame: CGRect(x: 245, y: 162, width: 114, height: 18),
                           label: data.polarity == .reinforcing ? "reinforcing" : "balancing",
                           role: .caption))
        return .init(size: CGSize(width: width, height: 284), nodes: nodes, paths: paths, texts: texts)
    }

    public static func flow(_ data: OmniMapFlow) -> OmniMapScene {
        let steps = Array(data.steps.prefix(7))
        let count = steps.count
        let gap: CGFloat = count > 6 ? 12 : 16
        let stepWidth: CGFloat = min(88, (width - 12 - CGFloat(max(0, count - 1)) * gap) / CGFloat(max(1, count)))
        let total = CGFloat(count) * stepWidth + CGFloat(max(count - 1, 0)) * gap
        let origin = (width - total) / 2
        var nodes: [OmniMapScene.Node] = []
        var paths: [OmniMapScene.Path] = []
        var texts: [OmniMapScene.Text] = []
        for (index, label) in steps.enumerated() {
            let x = origin + CGFloat(index) * (stepWidth + gap)
            nodes.append(.init(frame: CGRect(x: x, y: 42, width: stepWidth, height: 34), label: label))
            if index > 0 {
                paths.append(.init(segments: [.move(CGPoint(x: x - gap, y: 59)),
                                               .line(CGPoint(x: x - 2, y: 59))], arrow: true))
            }
        }
        if let branch = data.branch, steps.indices.contains(branch.at) {
            let fork = nodes[branch.at].frame
            let branchLabels = Array(branch.steps.prefix(max(0, 7 - steps.count)))
            let branchCount = branchLabels.count
            let bGap: CGFloat = 14
            let bWidth: CGFloat = min(100, (width - 12 - CGFloat(max(0, branchCount - 1)) * bGap) / CGFloat(max(1, branchCount)))
            let branchTotal = CGFloat(branchCount) * bWidth + CGFloat(max(0, branchCount - 1)) * bGap
            let preferred = fork.midX + 14
            let branchOrigin = min(max(preferred, 6), max(6, width - branchTotal - 6))
            if branchCount > 0 {
                let firstX = branchOrigin
                paths.append(.init(segments: [.move(CGPoint(x: fork.midX, y: fork.maxY)),
                                               .line(CGPoint(x: fork.midX, y: 139)),
                                               .line(CGPoint(x: firstX + bWidth / 2, y: 139)),
                                               .line(CGPoint(x: firstX + bWidth / 2, y: 152))], arrow: true))
                for (index, label) in branchLabels.enumerated() {
                    let x = branchOrigin + CGFloat(index) * (bWidth + bGap)
                    nodes.append(.init(frame: CGRect(x: x, y: 154, width: bWidth, height: 32), label: label))
                    if index > 0 {
                        paths.append(.init(segments: [.move(CGPoint(x: x - bGap, y: 170)),
                                                       .line(CGPoint(x: x - 2, y: 170))], arrow: true))
                    }
                }
                let captionX = fork.midX + 108 <= width - 6 ? fork.midX + 8 : fork.midX - 108
                texts.append(.init(frame: CGRect(x: min(max(captionX, 6), 498), y: 111,
                                                 width: 100, height: 18), label: branch.label,
                                   role: .caption))
            }
        }
        return .init(size: CGSize(width: width, height: data.branch == nil ? 112 : 206),
                     nodes: nodes, paths: paths, texts: texts)
    }

    private static func tierFrames(count: Int, y: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let gap: CGFloat = 6
        let slot = (width - 16) / CGFloat(count)
        let nodeWidth = min(124, slot - gap)
        return (0..<count).map { index in
            CGRect(x: 8 + CGFloat(index) * slot + (slot - nodeWidth) / 2,
                   y: y, width: nodeWidth, height: 30)
        }
    }

    private static func endpoints(from: CGRect, to: CGRect) -> (CGPoint, CGPoint) {
        let dx = to.midX - from.midX
        let dy = to.midY - from.midY
        if abs(dx) >= abs(dy) {
            return (CGPoint(x: dx >= 0 ? from.maxX : from.minX, y: from.midY),
                    CGPoint(x: dx >= 0 ? to.minX : to.maxX, y: to.midY))
        }
        return (CGPoint(x: from.midX, y: dy >= 0 ? from.maxY : from.minY),
                CGPoint(x: to.midX, y: dy >= 0 ? to.minY : to.maxY))
    }
}

/// Representative, valid documents for the empty-state chooser and layout previews.
public enum OmniMapSamples {
    public static func document(for form: OmniMapForm) -> OmniMapDocument {
        switch form {
        case .tree:
            return .init(form: .tree, title: "Why a useful library lasts",
                         lineMeaning: "solid: supports · dashed: objects to",
                         honesty: .init(kind: .leavesOut, text: "Funding and local context vary."),
                         data: .tree(.init(rootLabel: "Useful library", edgeMeaning: .supports,
                                           nodes: [
                                            .init(id: "access", label: "Open access"),
                                            .init(id: "trust", label: "Public trust"),
                                            .init(id: "care", label: "Collection care"),
                                            .init(id: "hours", label: "Long hours", parent: "access"),
                                            .init(id: "catalogue", label: "Clear catalogue", parent: "access"),
                                            .init(id: "staff", label: "Skilled staff", parent: "trust"),
                                            .init(id: "privacy", label: "Reader privacy", parent: "trust"),
                                            .init(id: "budget", label: "Budget pressure", parent: "care", edge: .dashed)
                                           ])))
        case .radial:
            return .init(form: .radial, title: "Around a library",
                         lineMeaning: "spokes: association",
                         honesty: .init(kind: .leavesOut, text: "Informal relationships change."),
                         data: .radial(.init(hub: "Library", spokes: [
                            .init(label: "Readers", children: ["Borrow", "Learn"]),
                            .init(label: "Staff", children: ["Guide", "Care"]),
                            .init(label: "Schools", children: ["Visit", "Study"]),
                            .init(label: "Authors", children: ["Write", "Speak"]),
                            .init(label: "Archives", children: ["Preserve", "Share"]),
                            .init(label: "Council", children: ["Fund", "Plan"]),
                            .init(label: "Volunteers", children: ["Host", "Help"]),
                            .init(label: "Community", children: ["Meet", "Create"])
                         ])))
        case .bridge:
            return .init(form: .bridge, title: "Git for a librarian",
                         lineMeaning: "arrows: plays the role of",
                         honesty: .init(kind: .breaksAt,
                                        text: "A library copy never diverges on its own; a branch does."),
                         data: .bridge(.init(newSide: "Git", familiarSide: "Library", pairs: [
                            .init(new: "Commit", familiar: "Dated accession record"),
                            .init(new: "Branch", familiar: "Parallel edition"),
                            .init(new: "Merge", familiar: "Collated edition"),
                            .init(new: "Tag", familiar: "Catalogue number")
                         ])))
        case .matrix:
            return .init(form: .matrix, title: "Book, document, work",
                         lineMeaning: "cells: short facts · — means none",
                         honesty: .init(kind: .leavesOut,
                                        text: "Digital works and legal exceptions are omitted."),
                         data: .matrix(.init(rows: ["Book", "Document", "Work", "Edition"],
                                             criteria: ["Physical form", "Single unit", "Legal object", "Identified by"],
                                             cells: [
                                                ["bound pages", "yes", "embodiment", "ISBN"],
                                                ["any", "yes", "—", "file or title"],
                                                ["none", "no, abstract", "copyright", "title + author"],
                                                ["a printing", "yes", "—", "ISBN"]
                                             ], offered: [3])))
        case .spectrum:
            return .init(form: .spectrum, title: "Publishing choices",
                         lineMeaning: "position on two axes",
                         honesty: .init(kind: .leavesOut, text: "Positions depend on audience and context."),
                         data: .spectrum(.init(axis: .init(low: "Private", high: "Public"),
                                               axis2: .init(low: "Informal", high: "Formal"),
                                               points: [
                                                .init(label: "Note", x: 0.12, y: 0.15),
                                                .init(label: "Draft", x: 0.24, y: 0.48),
                                                .init(label: "Memo", x: 0.42, y: 0.62),
                                                .init(label: "Blog", x: 0.72, y: 0.30),
                                                .init(label: "Paper", x: 0.84, y: 0.87)
                                               ])))
        case .loop:
            return .init(form: .loop, title: "Scrum as a reinforcing loop",
                         lineMeaning: "arrows: increases · R = reinforcing",
                         honesty: .init(kind: .leavesOut,
                                        text: "Delays between sprints, team churn, and external deadlines."),
                         data: .loop(.init(variables: ["Sprint commitment", "Delivered increment",
                                                      "Stakeholder trust", "Backlog clarity", "Team focus"],
                                           links: [
                                            .init(from: 0, to: 1, sign: .positive),
                                            .init(from: 1, to: 2, sign: .positive),
                                            .init(from: 2, to: 3, sign: .positive),
                                            .init(from: 3, to: 4, sign: .positive),
                                            .init(from: 4, to: 0, sign: .positive)
                                           ], polarity: .reinforcing)))
        case .flow:
            return .init(form: .flow, title: "From idea to release",
                         lineMeaning: "arrows: then",
                         honesty: .init(kind: .leavesOut, text: "Feedback can restart earlier steps."),
                         data: .flow(.init(steps: ["Idea", "Sketch", "Build", "Review", "Release"],
                                           branch: .init(at: 2, label: "needs revision",
                                                         steps: ["Rework", "Review again"]))))
        }
    }
}
