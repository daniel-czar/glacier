import CoreGraphics
import OmniCore
import OmniPresentation
import Testing

@Suite struct RegexRailroadTests {
    @Test func referencePatternIsDeterministicAndBounded() throws {
        let ast = try #require(RegexAnalysis(pattern: #"^(\d{4})-(\d{2})-(\d{2})$"#).ast)
        let scene = OmniRegexRailroad.layout(ast)
        #expect(scene == OmniRegexRailroad.layout(ast))
        #expect(scene.size.width == 604)
        #expect(scene.nodes.contains { $0.raw == #"\d{4}"# && $0.label == "4×" })
        for node in scene.nodes {
            #expect(node.frame.minX >= 0 && node.frame.maxX <= scene.size.width)
            #expect(node.frame.minY >= 0 && node.frame.maxY <= scene.size.height)
        }
        for segment in scene.segments {
            for point in [segment.from, segment.to] {
                #expect(point.x >= 0 && point.x <= scene.size.width)
                #expect(point.y >= 0 && point.y <= scene.size.height)
            }
        }
    }

    @Test func nestedWideAlternativesAndGroupsWrapWithinCanvas() throws {
        let branch = String(repeating: "(?:ab|cd)\\d{2,4}?", count: 4)
        let pattern = "(?<outer>\(branch)|\(branch))"
        let ast = try #require(RegexAnalysis(pattern: pattern).ast)
        let scene = OmniRegexRailroad.layout(ast)
        #expect(scene.size.width == 604)
        #expect(scene.size.height > 100)
        #expect(scene.nodes.contains { $0.label == "group outer" })
        #expect(scene.nodes.contains { $0.label == "2–4× · lazy" })
        #expect(scene.nodes.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 604 })
        #expect(scene.segments.allSatisfy {
            $0.from.x >= 0 && $0.from.x <= 604 && $0.to.x >= 0 && $0.to.x <= 604
        })
    }

    @Test func zeroMinimumDrawsBypassAndZeroOnlySkipsChild() throws {
        let star = OmniRegexRailroad.layout(try #require(RegexAnalysis(pattern: "a*").ast))
        #expect(star.nodes.contains { $0.label == "a" })
        #expect(star.nodes.contains { $0.label == "optional" })
        #expect(star.segments.contains { $0.from.y == $0.to.y && $0.from.x < $0.to.x
            && $0.from.y > (star.nodes.first { $0.label == "a" }?.frame.maxY ?? 0) })
        let counted = OmniRegexRailroad.layout(try #require(RegexAnalysis(pattern: "a{0,1}").ast))
        #expect(counted.nodes.contains { $0.label == "a" })
        #expect(counted.nodes.contains { $0.label == "0–1×" })
        let zero = OmniRegexRailroad.layout(try #require(RegexAnalysis(pattern: "a{0}").ast))
        #expect(!zero.nodes.contains { $0.label == "a" })
        #expect(zero.nodes.contains { $0.label == "0×" })
    }

    @Test func deepNestingFailsDiagramGracefullyAndSafeNestingFits() throws {
        let pattern = String(repeating: "(", count: 50) + "a" + String(repeating: ")", count: 50)
        let deep = RegexAnalysis(pattern: pattern)
        #expect(deep.compileFailure == nil)
        #expect(deep.ast == nil)
        #expect(deep.diagramStatus == .unparsable)
        #expect(deep.parseFailure == "Nesting is too deep to diagram")
        let safePattern = String(repeating: "(", count: 12) + "a" + String(repeating: ")", count: 12)
        let ast = try #require(RegexAnalysis(pattern: safePattern).ast)
        let scene = OmniRegexRailroad.layout(ast)
        #expect(scene.nodes.filter { $0.style == .frame }.count == 12)
        #expect(scene.nodes.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 604 })
        #expect(scene.segments.allSatisfy {
            $0.from.x >= 0 && $0.from.x <= 604 && $0.to.x >= 0 && $0.to.x <= 604
        })
    }

    @Test func wrappedRailUsesGutterOutsideNextRowNodes() throws {
        let ast = try #require(RegexAnalysis(pattern: String(repeating: "abcdef", count: 20)).ast)
        let scene = OmniRegexRailroad.layout(ast)
        let crossRowSegments = scene.segments.filter { $0.from.y == $0.to.y
            && abs($0.from.x - $0.to.x) > 400 }
        #expect(!crossRowSegments.isEmpty)
        for segment in crossRowSegments {
            #expect(!scene.nodes.contains { node in
                node.style != .endpoint && node.frame.minY < segment.from.y
                    && segment.from.y < node.frame.maxY
                    && max(segment.from.x, segment.to.x) > node.frame.minX
                    && min(segment.from.x, segment.to.x) < node.frame.maxX
            })
        }
    }

    @Test func mixedWidthWrapReservesSpaceForEndDot() throws {
        let ast = try #require(RegexAnalysis(pattern: #"aaaaaaaaaa\dbc"#).ast)
        let scene = OmniRegexRailroad.layout(ast)
        #expect(scene.nodes.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 604 })
        #expect(scene.segments.allSatisfy { $0.from.x <= 604 && $0.to.x <= 604 })
    }
    @Test func wrappedPatternConnectsItsFinalTokenToEndDot() throws {
        let ast = try #require(RegexAnalysis(pattern: #"^[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}$"#).ast)
        let scene = OmniRegexRailroad.layout(ast)
        let anchor = try #require(scene.nodes.last { $0.raw == "$" && $0.style == .anchor })
        let endpoint = try #require(scene.nodes.last { $0.style == .endpoint })
        let intervals = scene.segments.filter { $0.from.y == anchor.frame.midY && $0.to.y == anchor.frame.midY }
            .map { (min($0.from.x, $0.to.x), max($0.from.x, $0.to.x)) }.sorted { $0.0 < $1.0 }
        var reached = anchor.frame.maxX
        for (start, end) in intervals where start <= reached { reached = max(reached, end) }
        #expect(reached >= endpoint.frame.minX)
    }
}
