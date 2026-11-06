import CoreGraphics
import Foundation
import OmniCore
@testable import OmniPresentation
import Testing

private func points(in path: OmniMapScene.Path) -> [CGPoint] {
    path.segments.flatMap { segment in
        switch segment {
        case .move(let point), .line(let point): [point]
        case .curve(let to, let control1, let control2): [to, control1, control2]
        }
    }
}

private func isInside(_ frame: CGRect, _ size: CGSize) -> Bool {
    frame.minX >= 0 && frame.minY >= 0 && frame.maxX <= size.width && frame.maxY <= size.height
}

@Suite struct MapLayoutTests {
    @Test func allSamplesAreDeterministicAndBounded() {
        for form in OmniMapForm.allCases {
            let document = OmniMapSamples.document(for: form)
            #expect(document.form == form)
            #expect(document.data.form == form)
            #expect(!document.honesty.text.isEmpty)
            let scene = OmniMapLayouts.layout(document)
            #expect(scene == OmniMapLayouts.layout(document))
            #expect(scene.size.width == 604)
            #expect(scene.size.height > 0 && scene.size.height <= 292)
            for node in scene.nodes { #expect(isInside(node.frame, scene.size)) }
            for text in scene.texts { #expect(isInside(text.frame, scene.size)) }
            for path in scene.paths {
                for point in points(in: path) {
                    #expect(point.x >= 0 && point.x <= scene.size.width)
                    #expect(point.y >= 0 && point.y <= scene.size.height)
                }
            }
        }
    }

    @Test func maximumTreeHasTwelveNonoverlappingNodesAndDashedObjection() {
        let descendants = (0..<11).map { index in
            OmniMapTree.Node(id: "n\(index)", label: "Kind \(index)",
                             parent: index < 6 ? nil : "n\(index - 6)",
                             edge: index == 10 ? .dashed : nil)
        }
        let scene = OmniMapLayouts.tree(.init(rootLabel: "Subject", edgeMeaning: .kindOf,
                                               nodes: descendants))
        #expect(scene.nodes.count == 12)
        #expect(scene.paths.count == 11)
        #expect(scene.paths.filter(\.dashed).count == 1)
        for (index, first) in scene.nodes.enumerated() {
            for second in scene.nodes.dropFirst(index + 1) {
                #expect(!first.frame.intersects(second.frame))
            }
        }
    }

    @Test func treePlacesChildrenInParentOrderWhenInputReversesThem() throws {
        let scene = OmniMapLayouts.tree(.init(rootLabel: "Root", edgeMeaning: .partOf, nodes: [
            .init(id: "a", label: "Parent A"),
            .init(id: "b", label: "Parent B"),
            .init(id: "bc", label: "Child B", parent: "b"),
            .init(id: "ac", label: "Child A", parent: "a")
        ]))
        let parentA = try #require(scene.nodes.first { $0.label == "Parent A" })
        let parentB = try #require(scene.nodes.first { $0.label == "Parent B" })
        let childA = try #require(scene.nodes.first { $0.label == "Child A" })
        let childB = try #require(scene.nodes.first { $0.label == "Child B" })
        #expect(parentA.frame.midX < parentB.frame.midX)
        #expect(childA.frame.midX < childB.frame.midX)
    }

    @Test func maximumRadialFitsAndDimsOfferedSpoke() {
        let spokes = (0..<8).map { index in
            OmniMapRadial.Spoke(label: "Spoke \(index)", edgeLabel: "helps",
                                children: ["Child A", "Child B"], offered: index == 7)
        }
        let scene = OmniMapLayouts.radial(.init(hub: "Centre", spokes: spokes))
        #expect(scene.nodes.count == 25)
        #expect(scene.nodes.filter(\.filled).count == 1)
        #expect(scene.nodes.filter(\.dimmed).count == 3)
        #expect(scene.paths.filter(\.dimmed).count == 3)
        for (index, first) in scene.nodes.enumerated() {
            for second in scene.nodes.dropFirst(index + 1) {
                #expect(!first.frame.intersects(second.frame))
            }
        }
        #expect(scene.texts.count == 8)
        for text in scene.texts {
            #expect(isInside(text.frame, scene.size))
            for node in scene.nodes { #expect(!text.frame.intersects(node.frame)) }
        }
    }

    @Test func bridgeMatrixSpectrumLoopAndFlowRetainTheirMeanings() {
        let bridge = OmniMapLayouts.layout(OmniMapSamples.document(for: .bridge))
        #expect(bridge.paths.count == 4 && bridge.paths.allSatisfy(\.arrow))
        #expect(bridge.texts.contains { $0.label == "correspondence, not equivalence" })
        let matrix = OmniMapLayouts.layout(OmniMapSamples.document(for: .matrix))
        #expect(matrix.nodes.isEmpty)
        #expect(matrix.texts.contains { $0.label == "Edition" && $0.dimmed })
        #expect(matrix.texts.contains { $0.label == "—" && $0.dimmed })
        let spectrum = OmniMapLayouts.layout(OmniMapSamples.document(for: .spectrum))
        #expect(spectrum.paths.count == 2)
        #expect(spectrum.nodes.count == 5)
        let loop = OmniMapLayouts.layout(OmniMapSamples.document(for: .loop))
        #expect(loop.nodes.count == 6)
        #expect(loop.nodes.filter(\.filled).count == 1)
        #expect(loop.paths.count == 5 && loop.paths.allSatisfy(\.arrow))
        #expect(loop.texts.filter { $0.label == "+" }.count == 5)
        let flow = OmniMapLayouts.layout(OmniMapSamples.document(for: .flow))
        #expect(flow.nodes.count == 7)
        #expect(flow.paths.count == 6 && flow.paths.allSatisfy(\.arrow))
        #expect(flow.texts.contains { $0.label == "needs revision" })
        #expect(flow.paths.filter(\.arrow).count == flow.paths.count)
    }

    @Test func maximumBridgeMatrixSpectrumLoopAndFlowStayOnCanvas() {
        let scenes: [OmniMapScene] = [
            OmniMapLayouts.bridge(.init(newSide: "New", familiarSide: "Familiar", pairs: (0..<5).map {
                .init(new: "New \($0)", familiar: "Familiar \($0)")
            })),
            OmniMapLayouts.matrix(.init(rows: (0..<5).map { "Row \($0)" },
                                        criteria: (0..<4).map { "Criterion \($0)" },
                                        cells: (0..<5).map { row in (0..<4).map { column in "\(row) \(column)" } })),
            OmniMapLayouts.spectrum(.init(axis: .init(low: "Low", high: "High"),
                                          axis2: .init(low: "Bottom", high: "Top"),
                                          points: (0..<7).map { .init(label: "Point \($0)", x: Double($0) / 6,
                                                                     y: Double($0) / 6) })),
            OmniMapLayouts.loop(.init(variables: (0..<6).map { "Variable \($0)" },
                                      links: (0..<6).map { .init(from: $0, to: ($0 + 1) % 6,
                                                                  sign: .positive) },
                                      polarity: .reinforcing)),
            OmniMapLayouts.flow(.init(steps: (0..<7).map { "Step \($0)" }))
        ]
        for scene in scenes {
            #expect(scene.size.width == 604 && scene.size.height <= 292)
            for node in scene.nodes { #expect(isInside(node.frame, scene.size)) }
            for text in scene.texts { #expect(isInside(text.frame, scene.size)) }
            for path in scene.paths {
                for point in points(in: path) {
                    #expect(point.x >= 0 && point.x <= scene.size.width)
                    #expect(point.y >= 0 && point.y <= scene.size.height)
                }
            }
        }
    }

    @Test func twoVariableLoopSeparatesOppositeArrows() {
        let scene = OmniMapLayouts.loop(.init(variables: ["Demand", "Supply"],
                                               links: [.init(from: 0, to: 1, sign: .positive),
                                                       .init(from: 1, to: 0, sign: .negative)],
                                               polarity: .balancing))
        #expect(scene.paths.count == 2)
        #expect(scene.paths.allSatisfy { path in
            path.segments.contains { segment in
                if case .curve = segment { return true }
                return false
            }
        })
        #expect(scene.texts.contains { $0.label == "−" })
        #expect(scene.nodes.last?.label == "B")
    }

    @Test func everyFlowLengthFitsAndSpectrumPointsAvoidAxisCaptions() {
        for count in 1...7 {
            let scene = OmniMapLayouts.flow(.init(steps: (0..<count).map { "Step \($0)" }))
            for node in scene.nodes { #expect(isInside(node.frame, scene.size)) }
        }
        let scene = OmniMapLayouts.spectrum(.init(axis: .init(low: "Less", high: "More"),
            axis2: .init(low: "Low", high: "High"), points: [.init(label: "At endpoint", x: 0.5, y: 0)]))
        let point = scene.texts.first { $0.label == "At endpoint" }!
        for axis in scene.texts where axis.label != "At endpoint" { #expect(!axis.frame.intersects(point.frame)) }
    }

    @Test func radialChildrenConnectToNodesAndSpectrumCaptionsAvoidAxes() {
        let radial = OmniMapLayouts.layout(OmniMapSamples.document(for: .radial))
        for path in radial.paths {
            guard let first = path.segments.first, let last = path.segments.last,
                  case .move(let start) = first, case .line(let end) = last else { continue }
            #expect(radial.nodes.contains { $0.frame.insetBy(dx: -0.1, dy: -0.1).contains(start) })
            #expect(radial.nodes.contains { $0.frame.insetBy(dx: -0.1, dy: -0.1).contains(end) })
        }
        let spectrum = OmniMapLayouts.layout(OmniMapSamples.document(for: .spectrum))
        let axes = [CGRect(x: 68, y: 133, width: 468, height: 6), CGRect(x: 299, y: 26, width: 6, height: 220)]
        for text in spectrum.texts where ["Note", "Draft", "Memo", "Blog", "Paper"].contains(text.label) {
            #expect(!axes.contains { $0.intersects(text.frame) })
        }
    }

    @Test func loopPlacesVariablesInCausalOrderRatherThanArrayOrder() {
        let data = OmniMapLoop(variables: ["A", "B", "C", "D"],
            links: [.init(from: 0, to: 2, sign: .positive), .init(from: 2, to: 1, sign: .positive),
                    .init(from: 1, to: 3, sign: .positive), .init(from: 3, to: 0, sign: .positive)], polarity: .reinforcing)
        let scene = OmniMapLayouts.loop(data)
        let nodes = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.label, $0.frame) })
        #expect(nodes["C"]!.midX > 302)
        #expect(nodes["B"]!.midY > 139)
        #expect(nodes["D"]!.midX < 302)
        let hub = nodes["R"]!
        for path in scene.paths {
            let values = points(in: path)
            guard values.count == 2 else { continue }
            for i in 0...20 {
                let t = CGFloat(i) / 20
                let point = CGPoint(x: values[0].x + (values[1].x - values[0].x) * t,
                                    y: values[0].y + (values[1].y - values[0].y) * t)
                #expect(!hub.contains(point))
            }
        }
    }

    @Test func longFlowBranchFitsAndRightmostForkCaptionAvoidsItsLine() {
        let long = OmniMapLayouts.flow(.init(steps: ["Start"], branch: .init(at: 0, label: "continue", steps: (0..<6).map { "Step \($0)" })))
        for node in long.nodes { #expect(isInside(node.frame, long.size)) }
        let right = OmniMapLayouts.flow(.init(steps: (0..<6).map { "Step \($0)" }, branch: .init(at: 5, label: "continue", steps: ["Last"])))
        let fork = right.nodes[5].frame
        let caption = right.texts.first { $0.label == "continue" }!.frame
        #expect(!caption.contains(CGPoint(x: fork.midX, y: caption.midY)))
    }
}
