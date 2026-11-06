import Foundation
@testable import OmniCore
import Testing

private func corpus() throws -> EmojiCorpus { try EmojiCorpus.shared.get() }

@Test func bundledCorpusHasBaseEmojiNamesKeywordsAndGroups() throws {
    let corpus = try corpus()
    #expect(corpus.entries.count == 1_906)
    #expect(corpus.entries.allSatisfy { !$0.name.isEmpty && !$0.keywords.isEmpty && !$0.group.isEmpty })
    let tones = (0x1F3FB...0x1F3FF).compactMap(Unicode.Scalar.init).map(Character.init)
    #expect(!corpus.entries.contains { entry in tones.contains { entry.emoji.contains($0) } })
    #expect(!corpus.entries.contains { $0.group == "Component" })
    #expect(corpus.entry(named: "flag: Germany")?.emoji == "🇩🇪")
    #expect(corpus.entry(named: "face exhaling")?.emoji == "😮‍💨")
    #expect(corpus.entry(named: "Smirking Face")?.emoji == "😏")
    #expect(corpus.entry(named: "smirky face") == nil)
    // Every exact name resolves to one emoji; symbols are part of the name.
    #expect(Set(corpus.entries.map { EmojiText.nameKey($0.name) }).count == corpus.entries.count)
    #expect(corpus.entry(named: "keycap: *")?.emoji == "*️⃣")
    #expect(corpus.entry(named: "keycap: #")?.emoji == "#️⃣")
    #expect(corpus.entry(named: "flag: côte d’ivoire") != nil)
    #expect(corpus.entry(named: "flag: côte d’ivoire") == corpus.entry(named: "Flag: Cote d'Ivoire"))
    // A punctuation-blind name resolves only when it names one emoji.
    #expect(corpus.entry(named: "flag Germany")?.emoji == "🇩🇪")
    #expect(corpus.entry(named: "Japanese \"here\" button") != nil)
    #expect(corpus.entry(named: "keycap") == nil)
    // Variation selectors and tones resolve to the base entry.
    #expect(corpus.entry(for: "❤")?.name == "red heart")
    #expect(corpus.entry(for: "👋🏽")?.emoji == "👋")
    #expect(corpus.entry(named: "waving hand")?.displayName == "Waving hand")
    #expect(corpus.entry(named: "OK hand")?.displayName == "OK hand")
}

@Test func handIsACategoryWithWavingHandFirstAndNoModel() throws {
    let match = EmojiMatcher.search("hand", in: try corpus())
    #expect(match.strong.first?.emoji == "👋", "\(match.strong.prefix(8).map { "\($0.emoji) \($0.name) \($0.keywords)" })")
    #expect(match.strong.count >= 30)
    #expect(!match.isThin)
    #expect(match.weak.isEmpty)
    let shown = Set(match.strong.map(\.emoji))
    for emoji in ["🤚", "✋", "👌", "✌️", "👍", "👏", "🙏", "🤝"] { #expect(shown.contains(emoji)) }
}

@Test func groupNamesAreSearchTermsAndTyposStillFind() throws {
    let corpus = try corpus()
    let food = EmojiMatcher.search("food", in: corpus).strong
    #expect(food.count >= 50)
    #expect(food.contains { $0.emoji == "🍕" })
    #expect(EmojiMatcher.search("flag", in: corpus).strong.contains { $0.emoji == "🇩🇪" })
    #expect(EmojiMatcher.search("hnad", in: corpus).strong.contains { $0.emoji == "👋" })
    #expect(EmojiMatcher.search("red heart", in: corpus).strong.first?.emoji == "❤️")
    #expect(EmojiMatcher.search("thumbs up", in: corpus).strong.first?.emoji == "👍")
    // A first letter searches even when it is a stop word on its own.
    #expect(!EmojiMatcher.search("a", in: corpus).strong.isEmpty)
    #expect(EmojiMatcher.search("a", in: corpus).strong.count <= EmojiMatcher.resultLimit)
    #expect(!EmojiMatcher.search("   ", in: corpus).hasQuery)
}

@Test func descriptionWithoutFullMatchesIsThinAndKeepsCappedWeakMatches() throws {
    let match = EmojiMatcher.search("smug but tired", in: try corpus())
    #expect(match.isThin)
    #expect(match.strong.count < EmojiMatcher.thinThreshold)
    #expect(match.weak.contains { $0.emoji == "😏" })
    #expect(match.weak.count <= EmojiMatcher.weakLimit)
    #expect(match.rows == match.strong + match.weak)
    #expect(EmojiMatcher.search("zzqx", in: try corpus()).isThin)
}

@Test func frequentSetCountsPicksDecaysSlowlyAndCaps() throws {
    let corpus = try corpus()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var table = EmojiFrequency()
    #expect(table.frequentSet(in: corpus, at: start).isEmpty)
    table.record("😄", at: start)
    table.record("😄", at: start)
    for _ in 0..<3 { table.record("👍🏽", at: start.addingTimeInterval(60)) }
    #expect(table.ranked(at: start.addingTimeInterval(120)).first == "👍")
    #expect(table.frequentSet(in: corpus, at: start).map(\.emoji).prefix(2) == ["👍", "😄"])

    let later = start.addingTimeInterval(EmojiFrequency.halfLife)
    let decayed = try #require(table.entries["😄"]).score * 0.5
    #expect(abs(EmojiFrequency.decayed(try #require(table.entries["😄"]), at: later) - decayed) < 0.000_1)

    for (index, entry) in corpus.entries.prefix(260).enumerated() {
        table.record(entry.emoji, at: start.addingTimeInterval(Double(index)))
    }
    #expect(table.entries.count <= 200)
    #expect(table.frequentSet(in: corpus, at: start).count == EmojiFrequency.setSize)
}
