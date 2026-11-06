import CryptoKit
import Foundation
import Testing
import OmniCore
@testable import OmniModels

// Golden prompt bytes recorded at main `05368c9`, before the decision step.
// The identity guide, `/stance` and request-scoped notes must leave every
// prompt below byte-identical: mechanical commands, `/qq`, and drafting
// requests that bind no identity guide or carry only span notes.

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private let goldenEmailGuide = PinnedLanguageGuide(identifier: "golden-email", version: "v1", status: "synthetic-test", text: "Say what matters, then stop.")
private let goldenSharedGuide = PinnedLanguageGuide(identifier: "golden-shared", version: "v1", status: "synthetic-test", text: "Plain words. One idea per sentence.")
private let goldenNoteID = UUID(uuidString: "6F1C2A10-2B5E-4C0B-9C71-0D3E5A8B7C21")!

private func input(_ raw: String, values: [String: TokenValue] = [:], modifiers: Set<String> = [], markers: [String] = []) -> ModuleInput {
    ModuleInput(
        canonicalText: raw,
        rawText: raw,
        payloadText: SlashTokenSyntax.payloadText(from: raw),
        modifiers: modifiers,
        markers: markers,
        tokenValues: values
    )
}

/// A synthetic identity guide in the registered shape: only the fenced block
/// under "Model-Facing Block" may reach a prompt.
let goldenIdentityGuideText = """
# Identity Guide (synthetic)

## Binding in Omni

Bound to language commands.

## Model-Facing Block

```text
IDENTITY — who is asking. Never use it to invent circumstances.

Conduct
- Takes a position without hedging.
```

## Facts — Daniel Writes This Section

- not injected
"""

func goldenIdentity() throws -> PinnedIdentityGuide {
    try PinnedIdentityGuide(PinnedLanguageGuide(identifier: "golden-identity", version: "v0", status: "synthetic-test", text: goldenIdentityGuideText))
}

@Test(arguments: [false, true])
func goldenMechanicalAndQuickPromptsKeepTheirBaseBytes(identityConfigured: Bool) throws {
    // /translate's direction is intentionally configurable; its semantics
    // stay stable while /slug and /qq retain their byte goldens.
    let builder = LanguagePromptBuilder(emailGuide: goldenEmailGuide, sharedGuide: goldenSharedGuide, identityGuide: identityConfigured ? try goldenIdentity() : nil)
    let translate = try builder.prompt(for: .translation, input: input("/translate Guten Morgen, der Termin steht."))
    let translateDE = try builder.prompt(for: .translation, input: input("/translate:de Good morning, the meeting is confirmed.", values: ["/translate": .langcode("de")]))
    let slug = try builder.prompt(for: .slug, input: input("/slug The European languages are members of the same family."))
    let quick = try builder.prompt(for: .quickQuestion, input: input("/qq What is a comet?"))
    #expect(translate.contains("Detect the predominant source language"))
    #expect(translate.contains("Translate into English (en)."))
    #expect(translate.contains("Preserve code identifiers, names, numbers"))
    #expect(translateDE.contains("Translate into German (de)."))
    #expect(!translate.contains("German input becomes English"))
    #expect(sha256(slug) == "122fc5c088023cbfbb52dcacfe786f54c06ea74e0fe04de7f966565828a6306a")
    #expect(sha256(quick) == "0802b4afe2eb3974c1096a11883b2ba377c9a41773d8d82a017f100a15dddfe8")
}

private func draftingEnvelope(_ prompt: String) throws -> [String: Any] {
    let lastLine = try #require(prompt.split(separator: "\n", omittingEmptySubsequences: false).last)
    return try #require(JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any])
}

@Test func draftingPromptsSeparateUserRequestsAndKeepSpanGuidance() throws {
    let builder = LanguagePromptBuilder(emailGuide: goldenEmailGuide, sharedGuide: goldenSharedGuide)
    let email = try builder.prompt(for: .email, input: input("/email ✓ Thursday at 15:30 works for coffee with Mira", markers: ["✓"]))
    let message = try builder.prompt(for: .message, input: input("/msg /style:formal running ten minutes late", modifiers: ["/style:formal"]))
    let raw = "/email decline the Thursday meeting but keep the Bessel thread warm"
    let span = (raw as NSString).range(of: "keep the Bessel thread warm")
    let note = OmniTextAnnotation(id: goldenNoteID, range: span, guidance: "Mention the draft sequencing; never quote this note.")
    let structured = try builder.prompt(for: .email, input: input(raw), annotations: [note], annotationFormat: .structured)
    let delimited = try builder.prompt(for: .email, input: input(raw), annotations: [note], annotationFormat: .delimited)
    let emailData = try draftingEnvelope(email)
    #expect(emailData["supplied_material"] as? String == "")
    #expect(emailData["user_request"] as? String == "Thursday at 15:30 works for coffee with Mira")
    let messageData = try draftingEnvelope(message)
    #expect(messageData["user_request"] as? String == "running ten minutes late")
    for prompt in [structured, delimited] {
        let envelope = try draftingEnvelope(prompt)
        #expect(envelope["user_request"] as? String == "decline the Thursday meeting but keep the Bessel thread warm")
        let rows = try #require(envelope["annotations"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["field"] as? String == "user_request")
        #expect(rows[0]["guidance"] as? String == "Mention the draft sequencing; never quote this note.")
    }
}
