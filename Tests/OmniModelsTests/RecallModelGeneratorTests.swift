import OmniCore
import OmniModels
import Testing

@Test func recallRequestPinsCerebrasAndNamesMacEnvironment() {
    let environment = RecallEnvironment(macOSVersion: "15.7.1", availableTools: ["git", "fd"])
    let request = RecallModelGenerator.request(intent: "list file names", sheet: [], environment: environment, runID: "test")
    #expect(request.commandID == "recall.command")
    #expect(request.dispatch?.selection?.profileID == ProviderRuntimeCatalog.cerebrasFastProfileID)
    #expect(request.outputConstraint.shape == .jsonObject)
    #expect(request.prompt.contains("BSD variants"))
    #expect(request.prompt.contains("macOS 15.7.1"))
    #expect(request.prompt.contains("git, fd"))
}

@Test func recallParserRejectsProseAndInvalidCandidates() {
    let valid = #"{"candidates":[{"command":"git reset --soft HEAD~1","label":"undo commit","note":"keeps changes","category":"git","destructive":false}]}"#
    #expect(RecallModelGenerator.parse(valid)?.first?.command == "git reset --soft HEAD~1")
    #expect(RecallModelGenerator.parse("Here you go: " + valid) == nil)
    #expect(RecallModelGenerator.parse(#"{"candidates":[{"command":"rm -rf out","label":"remove","note":"","category":"shell","destructive":"false"}]}"#) == nil)
    #expect(RecallModelGenerator.parse(#"{"candidates":[{"command":"rm -rf out","label":"remove","note":"","category":"shell","destructive":1}]}"#) == nil)
    let flagged = #"{"candidates":[{"command":"rm -rf out","label":"remove","note":"","category":"shell","destructive":false}]}"#
    #expect(RecallModelGenerator.parse(flagged)?.first?.destructive == true)
    let existing = [RecallCommand(category: "git", command: "git reset --soft HEAD~1", label: "undo commit")]
    #expect(RecallModelGenerator.parse(valid, excluding: existing) == nil)
}
