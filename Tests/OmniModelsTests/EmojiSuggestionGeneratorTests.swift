import OmniCore
import OmniModels
import Testing

@Test func emojiRequestPinsCerebrasAndCarriesCorpusVocabulary() throws {
    let corpus = try EmojiCorpus.shared.get()
    let request = EmojiSuggestionGenerator.request(description: "smug but tired", corpus: corpus, runID: "test")
    #expect(request.commandID == "emoji.suggest")
    #expect(request.dispatch?.selection?.profileID == ProviderRuntimeCatalog.cerebrasFastProfileID)
    #expect(request.outputConstraint.shape == .jsonObject)
    #expect(request.prompt.hasSuffix("Description: smug but tired"))
    #expect(request.prompt.contains("\nsmirking face\n"))
    #expect(request.prompt.contains("\nflag: Germany\n"))
    #expect(ModelProviderPolicy.v6.commandIDs.contains("emoji.suggest"))
    #expect(ProviderRuntimeCatalog.routineCommandIDs.contains("emoji.suggest"))
}

@Test func emojiParserKeepsOnlyCorpusNamesInOrder() throws {
    let corpus = try EmojiCorpus.shared.get()
    let reply = #"{"names":["smirking face","Face Exhaling","smug cat","smirking face","face with rolling eyes","unamused face","melting face","sleeping face"]}"#
    let picks = try #require(EmojiSuggestionGenerator.parse(reply, corpus: corpus))
    #expect(picks.map(\.emoji) == ["😏", "😮‍💨", "🙄", "😒", "🫠"])
    #expect(EmojiSuggestionGenerator.parse(#"{"names":["nothing real"]}"#, corpus: corpus) == [])
    #expect(EmojiSuggestionGenerator.parse("Here: " + reply, corpus: corpus) == nil)
    #expect(EmojiSuggestionGenerator.parse(#"{"names":[]}"#, corpus: corpus) == nil)
    #expect(EmojiSuggestionGenerator.parse(#"{"names":["smirking face"],"why":"smug"}"#, corpus: corpus) == nil)
    #expect(EmojiSuggestionGenerator.parse(#"{"emoji":["😏"]}"#, corpus: corpus) == nil)
}
