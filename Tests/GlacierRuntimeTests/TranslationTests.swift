import Foundation
import OmniCore
import OmniModels
import Testing
@testable import GlacierWorkspace

@Test func translationDefaultsToDetectedSourceAndEnglish() throws {
    let options = TranslationOptions.defaultToEnglish
    #expect(options.sourceLanguageCode == nil)
    #expect(options.targetLanguageCode == "en")
    #expect(TranslationOptions(sourceLanguageCode: "auto").sourceLanguageCode == nil)
    let input = ModuleInput(canonicalText: "/translate Hallo", rawText: "Hallo", payloadText: "Hallo")
    let prompt = try LanguagePromptBuilder().prompt(for: .translation, input: input)
    #expect(prompt.contains("Detect the predominant source language"))
    #expect(prompt.contains("Translate into English (en)"))
    #expect(prompt.contains("Preserve code identifiers, names, numbers"))
    #expect(!prompt.contains("German input becomes English"))
}

@Test func translationExplicitTargetAndEphemeralOptions() throws {
    let input = ModuleInput(canonicalText: "/translate:de Hello", rawText: "Hello", payloadText: "Hello",
                            tokenValues: ["/translate": .langcode("de")])
    let prompt = try LanguagePromptBuilder().prompt(for: .translation, input: input)
    #expect(prompt.contains("Translate into German (de)"))
    let configured = try LanguagePromptBuilder(translationOptions: .init(sourceLanguageCode: "fr", targetLanguageCode: "en"))
        .prompt(for: .translation, input: ModuleInput(canonicalText: "/translate Bonjour", rawText: "Bonjour", payloadText: "Bonjour"))
    #expect(configured.contains("The source language is French (fr)"))
    #expect(configured.contains("Translate into English (en)"))
    let provided = try LanguagePromptBuilder(
        translationOptions: .init(targetLanguageCode: "en"),
        translationOptionsProvider: { .init(sourceLanguageCode: "auto", targetLanguageCode: "de") }
    ).prompt(for: .translation, input: ModuleInput(canonicalText: "/translate Hello", rawText: "Hello", payloadText: "Hello"))
    #expect(provided.contains("Translate into German (de)"))
    let request = try OmniEphemeralTools.request(for: .translation, text: "Bonjour print(x) 42",
                                                  profileOverride: "custom-translation",
                                                  translationOptions: .init(targetLanguageCode: "en"))
    #expect(request.commandID == "translate")
    #expect(request.prompt.contains("Translate into English (en)"))
    #expect(request.dispatch?.selection?.profileID == "custom-translation")
}

@Test func expressValidatesMeaningAnchorAndBothGroups() throws {
    let good = """
    {"meaning":"I do not know","force":"statement of uncertainty","fixed":"","ambiguity":""}
    {"group":"close","phrase":"I don't know.","cue":""}
    {"group":"broader","phrase":"I can't answer that.","cue":"focuses on ability to answer"}
    """
    let result = try OmniExpressModelProducer.finalResult(from: good)
    #expect(result.contains("I don't know."))
    let missingAnchor = good.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
    #expect(throws: ExpressResultError.self) {
        _ = try OmniExpressModelProducer.finalResult(from: missingAnchor)
    }
    let request = OmniExpressModelProducer.request(text: "Hello", profileID: "express-profile")
    #expect(request.commandID == "express.alternatives")
    #expect(request.dispatch?.selection?.profileID == "express-profile")
    #expect(request.prompt.contains("Always write every alternative phrase in English (en)"))
    #expect(request.prompt.contains("including when the user's text is already in English"))
    #expect(request.prompt.contains("Write the meaning anchor and every option cue in the same output language"))
    #expect(!request.prompt.contains("plain English meaning"))
}

@Test func expressPromptFollowsSelectedPairAndModeWithoutChangingTranslate() throws {
    let pair = OmniLanguagePair(primary: "fr", secondary: "it")
    let primary = OmniExpressModelProducer.request(text: "Bonjour", languages: pair)
    #expect(primary.prompt.contains("Always write every alternative phrase in French (fr)"))
    #expect(primary.prompt.contains("Rephrase primary-language input naturally."))
    let oneLanguage = OmniExpressModelProducer.request(text: "Hello", languages: .init(primary: "en", secondary: "en"))
    #expect(!oneLanguage.prompt.contains("do not translate it into English"))
    let paired = OmniExpressModelProducer.request(text: "Bonjour", languages: pair, outputMode: .paired)
    #expect(paired.prompt.contains("If it is French (fr), write every alternative phrase in Italian (it)"))
    #expect(paired.prompt.contains("otherwise write every alternative phrase in French (fr)"))
    let defaultTranslation = try LanguagePromptBuilder().prompt(for: .translation,
        input: ModuleInput(canonicalText: "/translate Hallo", rawText: "Hallo", payloadText: "Hallo"))
    #expect(defaultTranslation.contains("Translate into English (en)"))
}
