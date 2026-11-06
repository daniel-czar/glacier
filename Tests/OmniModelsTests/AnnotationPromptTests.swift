import Foundation
import Testing
import OmniCore
@testable import OmniModels

@Test func unannotatedLanguagePromptKeepsExactLegacyBytes() throws {
    let input = ModuleInput(canonicalText: "/qq What is a comet?", rawText: "/qq What is a comet?", payloadText: "What is a comet?")
    let actual = try LanguagePromptBuilder().prompt(for: .quickQuestion, input: input)
    let expected = """
    Answer the question directly and concisely. State uncertainty when it matters. Do not claim actions were taken, do not invent sources, and return only the answer.

    No pinned references.

    No acceptance or decline marker was supplied.

    Grounding: the user text below is the question. Answer it from general knowledge. Do not invent facts about the user's context, calendar, contacts or files, and do not claim to have taken any action.

    \(ModelOutputDiscipline.instruction)

    User text:
    What is a comet?
    """
    #expect(actual == expected)
    #expect(try LanguagePromptBuilder().prompt(for: .quickQuestion, input: input, annotations: [], annotationFormat: .delimited) == expected)
}

@Test func annotatedDraftKeepsGuidanceInTheRequestEnvelope() throws {
    let raw = "/msg ask Mira for coffee; decline Thursday before 16:00"
    let payload = SlashTokenSyntax.payloadText(from: raw)
    let target = (raw as NSString).range(of: "decline Thursday")
    let note = OmniTextAnnotation(range: target, guidance: "Say this politely, never quote this guidance.")
    let input = ModuleInput(canonicalText: raw, rawText: raw, payloadText: payload)
    for format in [OmniAnnotationPromptFormat.structured, .delimited] {
        let prompt = try LanguagePromptBuilder().prompt(for: .message, input: input, annotations: [note], annotationFormat: format)
        let json = try #require(prompt.split(separator: "\n", omittingEmptySubsequences: false).last)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(envelope["supplied_material"] as? String == "")
        #expect(envelope["user_request"] as? String == payload)
        let rows = try #require(envelope["annotations"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["guidance"] as? String == "Say this politely, never quote this guidance.")
        #expect(rows[0]["field"] as? String == "user_request")
        #expect(rows[0]["selected_text"] as? String == "decline Thursday")
        #expect(!json.contains("<OMNI_"))
    }
}

@Test func unannotatedFollowUpPromptKeepsExactLegacyBytes() {
    let request = FollowUpGenerationRequest(
        runID: "r", modelCommandID: "draft.message", sourceVersion: 1,
        sourceText: "Please help", visibleText: "/formal Please help",
        operation: .formal, offline: false
    )
    let expected = """
    Rewrite the edited draft.
    Operation: formal
    Produce one version in a formally courteous, direct register that keeps the draft's purpose, facts and structure. Do not add obligations, deadlines or pleasantries the draft does not contain.

    \(ModelOutputDiscipline.instruction)

    Edited draft:
    Please help
    """
    #expect(request.prompt == expected)
    #expect(request.prompt(annotationFormat: .delimited) == expected)
}

@Test func annotatedFollowUpProjectsAfterOperationRemoval() {
    let raw = "/formal Please help"
    let note = OmniTextAnnotation(range: (raw as NSString).range(of: "help"), guidance: "Keep the urgency")
    let request = FollowUpGenerationRequest(
        runID: "r", modelCommandID: "draft.message", sourceVersion: 1,
        sourceText: "Please help", visibleText: raw,
        operation: .formal, offline: false, annotations: [note]
    )
    let prompt = request.prompt(annotationFormat: .delimited)
    #expect(prompt.range(of: #"Please «OMNI_[0-9a-f]{16}(?:_[0-9]+)?_N1_START»help«OMNI_[0-9a-f]{16}(?:_[0-9]+)?_N1_END»"#, options: .regularExpression) != nil)
    #expect(prompt.contains("Keep the urgency"))
    #expect(prompt.range(of: #"<OMNI_[0-9a-f]{16}(?:_[0-9]+)?_META_BEGIN>"#, options: .regularExpression) != nil)
}
