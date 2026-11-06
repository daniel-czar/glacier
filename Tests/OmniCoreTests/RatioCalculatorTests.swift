import Foundation
import OmniCore
import Testing

private func tables() throws -> RatioTables { try RatioTables.shared.get() }

@Suite struct RatioCalculatorTests {
    @Test func ratioParserReadsEveryFormInTheGrammar() {
        #expect(RatioParser.parse("") == .reference)
        #expect(RatioParser.parse("   ") == .reference)
        for text in ["16:9", "16/9", "16x9", "16 : 9", "16×9"] {
            #expect(RatioParser.parse(text) == .ratio(RatioShape(width: 16, height: 9)), "\(text)")
        }
        #expect(RatioParser.parse("1.91:1") == .ratio(RatioShape(width: 1.91, height: 1)))
        #expect(RatioParser.parse("2.39") == .ratio(RatioShape(width: 2.39, height: 1)))
        for text in ["1200x628", "1200×628", "1200 628", "1200 x 628", "1200X628"] {
            #expect(RatioParser.parse(text) == .size(width: 1200, height: 628), "\(text)")
        }
        // `AxB` is a size when either side reaches 100.
        #expect(RatioParser.parse("100x50") == .size(width: 100, height: 50))
        #expect(RatioParser.parse("99x50") == .ratio(RatioShape(width: 99, height: 50)))
        let wide = RatioQuery.ratioAt(RatioShape(width: 16, height: 9), side: .wide, length: 1200)
        for text in ["16:9 at 1200 wide", "16:9 1200w", "16:9 w1200", "16:9 at 1200", "16:9 1200 wide"] {
            #expect(RatioParser.parse(text) == wide, "\(text)")
        }
        let high = RatioQuery.ratioAt(RatioShape(width: 16, height: 9), side: .high, length: 600)
        for text in ["16:9 at 600 high", "16:9 h600", "16:9 600h", "16:9 at 600 tall"] {
            #expect(RatioParser.parse(text) == high, "\(text)")
        }
        for text in ["instagram", "og", "youtube thumbnail", "a4", "cinema", "hello", "1/0", "-16:9", "1e3x2", "16:9 1200"] {
            #expect(RatioParser.parse(text) == .name(text), "\(text)")
        }
    }

    @Test func emptyFieldIsTheReferenceAtACommonHeightWithSquareSelected() throws {
        let tables = try tables()
        let result = RatioCalculator.evaluate("", tables: tables)
        #expect(result.grid.map(\.label) == ["9:16", "3:4", "4:5", "1:1", "5:4", "4:3", "3:2", "16:10", "16:9", "1.91:1", "2:1", "21:9", "2.39:1"])
        #expect(result.grid.map(\.gridNote) == ["0.56", "0.75", "0.80", "1.00", "1.25", "1.33", "1.50", "1.60", "1.78", "OG", "2.00", "2.33", "cinema"])
        #expect(result.rows.isEmpty && result.drawing == nil && result.miss == nil)
        let square = try #require(result.initialSelection)
        #expect(result.copyText(at: square) == "1:1")
        #expect(result.summary(at: square) == "1:1 · square · 1080 × 1080")
        #expect(result.summary(at: square)?.contains(result.copyText(at: square) ?? "-") == true)
    }

    @Test func aSizeReadsAsItsDecimalNearestCommonAndPresets() throws {
        let result = RatioCalculator.evaluate("1200x628", tables: try tables())
        let drawing = try #require(result.drawing)
        #expect(drawing.widthLabel == "1200" && drawing.heightLabel == "628")
        #expect(drawing.ratioLabel == "1.91 : 1")
        #expect(drawing.shape == RatioShape(width: 1200, height: 628))
        let first = try #require(result.rows.first)
        #expect(first.text == "1.91:1" && first.qualifier == "decimal" && first.note == "300:157 reduced")
        #expect(result.initialSelection == 0)
        #expect(result.copyText(at: 0) == "1.91:1")
        #expect(result.summary(at: 0) == "1200 × 628 · 1.91:1")
        // The nearest common ratio skips the 1.91:1 the first row already names.
        #expect(result.rows[1].text == "≈ 2:1" && result.rows[1].qualifier == "nearest common" && result.rows[1].note == "4.5 % wider")
        #expect(result.rows[1].copyText == "2:1")
        let og = try #require(result.rows.first { $0.text == "Open Graph image" })
        #expect(og.qualifier == "Web · 1200 × 630" && og.note == "preset" && og.copyText == "1200 × 630")
        for index in result.rows.indices {
            #expect(result.summary(at: index)?.contains(result.copyText(at: index) ?? "-") == true)
        }
    }

    @Test func aWholeCommonSizeReducesToItsLabel() throws {
        let tables = try tables()
        let hd = RatioCalculator.evaluate("1920 × 1080", tables: tables)
        #expect(hd.drawing?.ratioLabel == "16 : 9")
        #expect(hd.rows.first?.text == "1.78:1" && hd.rows.first?.note == "16:9 reduced")
        #expect(hd.rows[1].text == "16:9" && hd.rows[1].qualifier == "common" && hd.rows[1].note == "exact")
        // 8:5 is 16:10, said the way people say it.
        #expect(RatioCalculator.evaluate("1920x1200", tables: tables).drawing?.ratioLabel == "16 : 10")
        // A near miss is never rounded into a common label.
        let laptop = RatioCalculator.evaluate("1366x768", tables: tables)
        #expect(laptop.drawing?.ratioLabel == "1.78 : 1")
        #expect(laptop.rows[1].text == "≈ 16:9" && laptop.rows[1].note == "< 0.1 % narrower")
    }

    @Test func aRatioAtADimensionAnswersFirstThenCommonSizes() throws {
        let tables = try tables()
        let result = RatioCalculator.evaluate("16:9 at 1200 wide", tables: tables)
        #expect(result.drawing == RatioDrawing(shape: RatioShape(width: 1200, height: 675), widthLabel: "1200", heightLabel: "675", ratioLabel: "16 : 9"))
        #expect(result.rows.map(\.text) == ["1200 × 675", "1280 × 720", "1920 × 1080", "2560 × 1440", "3840 × 2160"])
        #expect(result.rows.map(\.qualifier) == [nil, "HD", "Full HD", "QHD", "4K"])
        #expect(result.rows.map(\.note) == ["at 1200 wide", "common", "common", "common", "common"])
        #expect(result.initialSelection == 0)
        #expect(result.copyText(at: 0) == "1200 × 675")
        #expect(result.summary(at: 0) == "16:9 at 1200 wide · 1200 × 675")
        #expect(result.summary(at: 1) == "16:9 · HD · 1280 × 720")
        let high = RatioCalculator.evaluate("16:9 h600", tables: tables)
        #expect(high.rows.first?.text == "1067 × 600")
        #expect(high.rows.first?.qualifier == "rounded from 1066.67")
        #expect(high.rows.first?.note == "at 600 high")
        // An uncommon ratio has the answer alone.
        #expect(RatioCalculator.evaluate("7:5 at 700 wide", tables: tables).rows.map(\.text) == ["700 × 500"])
    }

    @Test func aBareRatioListsItsCommonSizesOrItsNeighbours() throws {
        let tables = try tables()
        let common = RatioCalculator.evaluate("16:9", tables: tables)
        #expect(common.drawing?.ratioLabel == "16 : 9")
        #expect(common.drawing?.widthLabel == "16" && common.drawing?.heightLabel == "9")
        #expect(common.rows.first?.text == "1280 × 720")
        #expect(common.summary(at: 0) == "16:9 · HD · 1280 × 720")
        // 7:3 is 21:9.
        #expect(RatioCalculator.evaluate("7:3", tables: tables).drawing?.ratioLabel == "21 : 9")
        let cinema = RatioCalculator.evaluate("2.35", tables: tables)
        #expect(cinema.rows.first?.text == "2.35:1")
        #expect(cinema.rows[1].text == "≈ 21:9")
        #expect(cinema.rows.contains { $0.text == "Scope, classic" && $0.copyText == "1920 × 817" })
    }

    @Test func aNameListsPresetsFuzzyOverNameAndPlatform() throws {
        let tables = try tables()
        let instagram = RatioCalculator.evaluate("instagram", tables: tables)
        #expect(instagram.drawing == nil)
        #expect(instagram.rows.map(\.text) == ["Post", "Portrait", "Story, Reel", "Landscape"])
        #expect(instagram.rows.map(\.qualifier) == ["1:1 · 1080 × 1080", "4:5 · 1080 × 1350", "9:16 · 1080 × 1920", "1.91:1 · 1080 × 566"])
        #expect(Set(instagram.rows.compactMap(\.note)) == ["Instagram"])
        #expect(instagram.copyText(at: 0) == "1080 × 1080")
        #expect(instagram.summary(at: 0) == "Post · 1:1 · 1080 × 1080")
        #expect(RatioCalculator.evaluate("og", tables: tables).rows.first?.text == "Open Graph image")
        #expect(RatioCalculator.evaluate("youtube thumbnail", tables: tables).rows.first?.copyText == "1280 × 720")
        #expect(RatioCalculator.evaluate("a4", tables: tables).rows.map(\.copyText) == ["210 × 297 mm"])
        #expect(RatioCalculator.evaluate("cinema", tables: tables).rows.map(\.text) == ["Scope", "Scope, classic"])
        #expect(RatioCalculator.evaluate("story", tables: tables).rows.first?.text == "Story, Reel")
    }

    @Test func unparsableInputSaysSoAndHasNoResult() throws {
        let tables = try tables()
        for text in ["hello", "1/0", "::", "zzzz"] {
            let result = RatioCalculator.evaluate(text, tables: tables)
            #expect(result.rows.isEmpty && result.grid.isEmpty && result.drawing == nil, "\(text)")
            #expect(result.miss == "no ratio in \u{201C}\(text)\u{201D}")
            #expect(result.summary(at: nil) == result.miss)
            #expect(result.initialSelection == nil)
        }
        let long = String(repeating: "a", count: 300)
        #expect(RatioCalculator.evaluate(long, tables: tables).miss == "no ratio in \u{201C}\(String(repeating: "a", count: 40))…\u{201D}")
    }

    @Test func absurdTermsAndAnswersAreMissesNeverATrap() throws {
        let tables = try tables()
        // Once, 1e19 for a side trapped the host converting it to Int.
        for text in ["1:0.00000000000001 h100000", "0.00000000000001:1 w100000", "1:0.01 h100000",
                     "16:9 at 100000 high", "0.000001", "1x0.001"] {
            let result = RatioCalculator.evaluate(text, tables: tables)
            #expect(result.miss != nil && result.rows.isEmpty, "\(text)")
        }
        #expect(RatioCalculator.evaluate("16:9 at 100000 wide", tables: tables).rows.first?.text == "100000 × 56250")
    }

    @Test func aPresetAddedToTheTableAppearsWithoutCodeChanges() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: RatioTables.bundledData()) as? [String: Any])
        var presets = try #require(json["presets"] as? [[String: Any]])
        presets.append(["platform": "Mastodon", "name": "Header", "ratio": "3:1", "w": 1500, "h": 500])
        json["presets"] = presets
        let edited = try RatioTables(data: JSONSerialization.data(withJSONObject: json))
        let result = RatioCalculator.evaluate("mastodon", tables: edited)
        #expect(result.rows.map(\.summary) == ["Header · 3:1 · 1500 × 500"])
        #expect(RatioCalculator.evaluate("mastodon", tables: try tables()).miss != nil)
    }

    @Test func tablesRejectMalformedRows() {
        let bad = #"{"version":1,"common":[{"ratio":"1:1","width":0,"height":1,"typical":{"w":1,"h":1},"sizes":[]}],"presets":[]}"#
        #expect(throws: RatioTablesError.self) { try RatioTables(data: Data(bad.utf8)) }
        let version = #"{"version":2,"common":[],"presets":[]}"#
        #expect(throws: RatioTablesError.self) { try RatioTables(data: Data(version.utf8)) }
    }
}
