import Foundation
@testable import OmniCore
import Testing

private func characters() throws -> CharacterCorpus { try CharacterCorpus.shared.get() }

@Test func bundledCharactersCoverAssignedUnicode17WithoutEmojiPresentation() throws {
    let corpus = try characters()
    #expect(corpus.entries.count == 158_412)
    #expect(corpus.entry(for: 0x2191)?.name == "Upwards arrow")
    #expect(corpus.entry(for: 0x4E00)?.name == "CJK unified ideograph-4E00")
    #expect(corpus.entry(for: 0xAC00)?.name == "Hangul syllable ga")
    #expect(corpus.entry(for: 0x323B0)?.since == "17.0")
    #expect(corpus.entry(for: 0x323B0)?.name == "CJK unified ideograph-323B0")
    #expect(corpus.entry(for: 0x0301)?.displayGlyph == "◌\u{0301}")
    #expect(corpus.entry(named: "caps lock")?.scalar == 0x21EA)
    #expect(corpus.entry(named: "squiggly equals")?.scalar == 0x2248)
    #expect(corpus.entry(named: "up arrow")?.scalar == 0x2191)
    #expect(corpus.entry(named: "degree")?.scalar == 0x00B0)
    for excluded in [UInt32(0), 0x200D, 0xD800, 0xE000, 0x0378, 0x1F600] {
        #expect(corpus.entry(for: excluded) == nil)
    }
    #expect(corpus.entries.allSatisfy { !$0.name.isEmpty && !$0.block.isEmpty && !$0.since.isEmpty })
}

@Test func identificationDistinguishesCharactersEmojiAndUnavailableCodePoints() throws {
    let corpus = try characters()
    #expect(corpus.identify("↑") == .character(try #require(corpus.entry(for: 0x2191))))
    #expect(corpus.identify("U+2191") == corpus.identify("0x2191"))
    #expect(corpus.identify("2191") == corpus.identify("↑"))
    #expect(corpus.identify("❤️") == .emoji)
    #expect(corpus.identify("😀") == .emoji)
    #expect(corpus.identify("U+0378") == .unavailable)
    #expect(corpus.identify("text") == nil)
}

@Test func representationsAreOrderedAndHaveInsertionText() throws {
    let corpus = try characters()
    let arrow = try #require(corpus.entry(for: 0x2191))
    #expect(arrow.representations.map(\.label) == ["Glyph", "Code point", "HTML", "Escape", "UTF-8", "Looks like"])
    #expect(arrow.representations[0].insertionText == "↑")
    #expect(arrow.representations[1].insertionText == "U+2191")
    #expect(arrow.representations[2].insertionText == "&uarr;")
    #expect(arrow.representations[2].displayText == "&uarr; · &#8593;")
    #expect(arrow.representations[3].insertionText == "\\u2191")
    #expect(arrow.representations[3].displayText == "\\u2191 · \\u{2191}")
    #expect(arrow.representations[4].insertionText == "E2 86 91")
    let boldA = try #require(corpus.entry(for: 0x1D400))
    #expect(boldA.representations[3].insertionText == "\\uD835\\uDC00")
    #expect(boldA.representations[3].displayText == "\\uD835\\uDC00 · \\u{1D400}")
    let cjk = try #require(corpus.entry(for: 0x4E00))
    #expect(cjk.representations[2].insertionText == "&#19968;")
}

@Test func searchFindsSymbolsScriptsAndBlocksLocally() throws {
    let corpus = try characters()
    #expect(CharacterMatcher.search("upward arrow", in: corpus).strong.first?.scalar == 0x2191)
    #expect(CharacterMatcher.search("heart", in: corpus).strong.contains { $0.scalar == 0x2665 })
    #expect(CharacterMatcher.search("greek small alpha", in: corpus).strong.first?.scalar == 0x03B1)
    #expect(CharacterMatcher.search("box drawing", in: corpus).strong.contains { $0.block == "Box Drawing" })
    #expect(CharacterMatcher.search("caps lock", in: corpus).strong.first?.scalar == 0x21EA)
    #expect(CharacterMatcher.search("squiggly equals", in: corpus).strong.first?.scalar == 0x2248)
    #expect(CharacterMatcher.search("α", in: corpus).strong.first?.scalar == 0x03B1)
    #expect(CharacterMatcher.search("0378", in: corpus).isThin)
    #expect(!CharacterMatcher.search(" ", in: corpus).hasQuery)
}

@Test func confusablesFollowOfficialSingleScalarMap() throws {
    let corpus = try characters()
    let alpha = try #require(corpus.entry(for: 0x03B1))
    #expect(alpha.confusables.contains(0x0061))
    #expect(alpha.representations.last?.label == "Looks like")
    #expect(alpha.representations.last?.insertionText == "a")
}

@Test func confusableCombiningMarksAlsoUseDottedCircleWithoutChangingInsertion() throws {
    let mark = try #require(try characters().entry(for: 0x0301))
    let looks = try #require(mark.representations.first { $0.label == "Looks like" })
    #expect(looks.displayText.unicodeScalars.contains { $0.value == 0x25CC })
    #expect(looks.insertionText.unicodeScalars.count == 1)
    #expect(!looks.insertionText.unicodeScalars.contains { $0.value == 0x25CC })
}
