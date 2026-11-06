import Foundation
import XCTest
@testable import OmniCore

/// Decision step (decision surface 8d392a5707c36d15), core contracts:
/// request-scoped and proposed notes, the stance result, the run link, the
/// material table and the 1.4.0 grammar.
final class DecisionStepCoreTests: XCTestCase {
    private let mail = "Hey Daniel — coffee Thursday?\nI can do 15:30 near the office.\n\nMira"

    private func parser() throws -> OmniParser {
        try OmniParser(manifest: FrozenContractCorpus().manifest(), references: ReferenceRegistry([]))
    }

    private func meta(_ suffix: String) -> String {
        guard let range = suffix.range(of: #"<OMNI_[0-9a-f]{16}(?:_[0-9]+)?_META_BEGIN>"#, options: .regularExpression) else { return "" }
        return String(suffix[range.lowerBound...])
    }

    // MARK: Request-scoped notes at every boundary

    func testRequestNotePassesValidatedFirstOnceAndNeedsARequest() {
        let span = OmniTextAnnotation(range: NSRange(location: 4, length: 6), guidance: "Keep the greeting")
        let pick = OmniTextAnnotation.request(guidance: "Decline, keep it warm", origin: .proposed, label: "Decline warmly")
        XCTAssertTrue(pick.isRequestScoped)
        XCTAssertEqual(pick.range, NSRange(location: 0, length: 0))
        let validated = OmniAnnotationRanges.validated([span, pick, pick], in: mail)
        XCTAssertEqual(validated, [pick, span])
        XCTAssertEqual(OmniAnnotationRanges.validated([pick], in: "   \n"), [])
        XCTAssertEqual(OmniAnnotationRanges.validated([.request(guidance: "  ", origin: .user)], in: mail), [])
    }

    func testRequestNoteSurvivesEveryRemapAndGoesWhenTheRequestIsCleared() {
        let pick = OmniTextAnnotation.request(guidance: "Accept plainly", origin: .proposed, label: "Accept")
        // An edit over where a span would be at 0 never touches it.
        XCTAssertEqual(OmniAnnotationRanges.remap([pick], replacing: NSRange(location: 0, length: 10), withUTF16Length: 0), [pick])
        XCTAssertEqual(OmniAnnotationRanges.remap([pick], replacing: NSRange(location: 0, length: 0), withUTF16Length: 5), [pick])
        XCTAssertEqual(OmniAnnotationRanges.droppingRequestNotesIfBlank([pick], in: "still here"), [pick])
        XCTAssertEqual(OmniAnnotationRanges.droppingRequestNotesIfBlank([pick], in: " \n "), [])
        // The proposal remap carries it unchanged and never counts it unmapped.
        let remapped = OmniAnnotationProjection.remap([pick], fromRawText: mail + " /stance", toRawText: "/qq " + mail)
        XCTAssertEqual(remapped.annotations, [pick])
        XCTAssertEqual(remapped.unmappedCount, 0)
    }

    func testRequestNoteProjectsWithoutASpanAndSerialisesOnlyAsAStructuredRow() throws {
        let raw = mail + " /email ✗"
        let payload = SlashTokenSyntax.payloadText(from: raw)
        let pick = OmniTextAnnotation.request(guidance: "Reply declining; no reason.", origin: .proposed, label: "Decline")
        let projected = try OmniAnnotationProjection.payload(from: raw, matching: payload, annotations: [pick])
        XCTAssertEqual(projected.first?.payloadRange, nil)
        XCTAssertEqual(projected.first?.rawSelectedText, "")
        for format in [OmniAnnotationPromptFormat.structured, .delimited] {
            let rendering = OmniAnnotationPrompt.render(payloadText: payload, projected: projected, format: format, sourceText: raw)
            // No leak: the payload is byte-identical to the unannotated one,
            // even when the delimited variant was asked for.
            XCTAssertEqual(rendering.userText, payload)
            let block = meta(rendering.metaSuffix)
            let row = try XCTUnwrap(block.split(separator: "\n").first { $0.hasPrefix(#"{"annotations""#) })
            XCTAssertTrue(row.contains(#""scope":"request""#))
            XCTAssertFalse(row.contains("sourceSpan"))
            XCTAssertFalse(row.contains("payloadSpan"))
            XCTAssertFalse(row.contains(#""label""#), "the role marker is UI only")
            XCTAssertTrue(block.contains(OmniAnnotationPrompt.requestNotesPreamble))
            XCTAssertTrue(block.contains("Reply declining; no reason."))
        }
    }

    func testSpanOnlyRenderingKeepsTheMeasuredPreambleAndRowBytes() throws {
        let raw = "/email decline Thursday politely"
        let payload = SlashTokenSyntax.payloadText(from: raw)
        let span = OmniTextAnnotation(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, range: (raw as NSString).range(of: "Thursday"), guidance: "No reason")
        let rendering = OmniAnnotationPrompt.render(payloadText: payload, projected: try OmniAnnotationProjection.payload(from: raw, matching: payload, annotations: [span]), format: .structured, sourceText: raw)
        XCTAssertFalse(rendering.metaSuffix.contains(OmniAnnotationPrompt.requestNotesPreamble))
        XCTAssertFalse(rendering.metaSuffix.contains("scope"))
        XCTAssertTrue(rendering.metaSuffix.contains(#"{"annotations":[{"guidance":"No reason","id":"11111111-2222-3333-4444-555555555555","payloadSpan":{"end":16,"start":8,"text":"Thursday"},"sourceSpan":{"end":23,"start":15,"text":"Thursday"}}]}"#))
    }

    func testMixedNotesRenderRequestRowsFirstAndTheSpanRowUnchanged() throws {
        let raw = mail + " /email"
        let payload = SlashTokenSyntax.payloadText(from: raw)
        let span = OmniTextAnnotation(range: (raw as NSString).range(of: "15:30"), guidance: "Keep the time", origin: .proposed)
        let pick = OmniTextAnnotation.request(guidance: "Accept", origin: .proposed, label: "Accept")
        let projected = try OmniAnnotationProjection.payload(from: raw, matching: payload, annotations: [span, pick])
        XCTAssertEqual(projected.map(\.annotation.id), [pick.id, span.id])
        let block = meta(OmniAnnotationPrompt.render(payloadText: payload, projected: projected, format: .delimited, sourceText: raw).metaSuffix)
        XCTAssertTrue(block.contains(#""sourceSpan":{"end":"#))
        // A model-proposed row says so, with the rule that it never supplies facts.
        XCTAssertTrue(block.contains(#""origin":"proposed""#))
        XCTAssertTrue(block.contains(OmniAnnotationPrompt.proposedNotesPreamble))
    }

    func testUserNotesCarryNoOriginAndOnlyProposedRowsBringTheirRule() throws {
        let raw = mail + " /email"
        let payload = SlashTokenSyntax.payloadText(from: raw)
        let user = OmniTextAnnotation(range: (raw as NSString).range(of: "15:30"), guidance: "Keep the time")
        let userOnly = OmniAnnotationPrompt.render(payloadText: payload, projected: try OmniAnnotationProjection.payload(from: raw, matching: payload, annotations: [user]), format: .structured, sourceText: raw).metaSuffix
        XCTAssertFalse(userOnly.contains(#""origin""#))
        XCTAssertFalse(userOnly.contains(OmniAnnotationPrompt.proposedNotesPreamble))
        XCTAssertFalse(userOnly.contains(OmniAnnotationPrompt.requestNotesPreamble))
        // The request preamble no longer repeats the direction rule: the
        // drafting grounding states it once, conditional on the note.
        XCTAssertFalse(OmniAnnotationPrompt.requestNotesPreamble.contains("message the user received"))
    }

    func testReplacingTheWholeTextTakesTheRequestNotesWithIt() {
        let pick = OmniTextAnnotation.request(guidance: "Accept", origin: .proposed, label: "Accept")
        let span = OmniTextAnnotation(range: NSRange(location: 2, length: 3), guidance: "Keep")
        XCTAssertEqual(OmniAnnotationRanges.droppingRequestNotesIfReplaced([pick, span], replacing: NSRange(location: 0, length: 20), inOldTextOfLength: 20), [span])
        XCTAssertEqual(OmniAnnotationRanges.droppingRequestNotesIfReplaced([pick, span], replacing: NSRange(location: 0, length: 19), inOldTextOfLength: 20), [pick, span])
        XCTAssertEqual(OmniAnnotationRanges.droppingRequestNotesIfReplaced([pick], replacing: NSRange(location: 0, length: 0), inOldTextOfLength: 0), [pick])
    }

    // MARK: Back-compat of stored notes

    private struct BaseShapeNote: Codable, Equatable {
        let id: UUID
        let range: NSRange
        let guidance: String
    }

    func testUserSpanNotesEncodeExactlyAsBeforeAndOldNotesDecode() throws {
        let id = UUID()
        let note = OmniTextAnnotation(id: id, range: NSRange(location: 2, length: 3), guidance: "Keep")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(note), try encoder.encode(BaseShapeNote(id: id, range: note.range, guidance: "Keep")))
        let old = try encoder.encode(BaseShapeNote(id: id, range: NSRange(location: 1, length: 4), guidance: "Old"))
        let decoded = try JSONDecoder().decode(OmniTextAnnotation.self, from: old)
        XCTAssertEqual(decoded.scope, .span)
        XCTAssertEqual(decoded.origin, .user)
        XCTAssertNil(decoded.label)
        // A request note round-trips, and a base-shaped reader still decodes it
        // (as an empty span the old validator drops).
        let pick = OmniTextAnnotation.request(guidance: "Accept", origin: .proposed, label: "Accept")
        let encoded = try encoder.encode(pick)
        XCTAssertEqual(try JSONDecoder().decode(OmniTextAnnotation.self, from: encoded), pick)
        XCTAssertEqual(try JSONDecoder().decode(BaseShapeNote.self, from: encoded).range.length, 0)
    }

    func testRunContextCarriesTheOriginLinkWithoutAVersionBump() throws {
        XCTAssertEqual(RuntimeRunContext.currentVersion, 2)
        let context = RuntimeRunContext(provenance: OmniRunProvenance(appName: "Mail", windowTitle: nil, wordCount: 3), originRunID: "oi_STANCE")
        let data = try JSONEncoder().encode(context)
        XCTAssertEqual(try JSONDecoder().decode(RuntimeRunContext.self, from: data).originRunID, "oi_STANCE")
        let legacy = Data(#"{"version":2,"childRunIDs":[],"completedSteps":[],"modelRecords":[],"resultVersions":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RuntimeRunContext.self, from: legacy).originRunID)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(RuntimeRunContext()), as: UTF8.self).contains("originRunID"))
    }

    // MARK: Quote anchoring

    func testAQuoteFoundExactlyOnceAnchorsToItsRawSpan() {
        let raw = "Thanks for asking.\nI know you're busy, but could you\nreview it by Friday? /email"
        let range = OmniAnnotationRanges.uniqueRawRange(ofQuote: "you're busy, but could you review it", inRawText: raw)
        let unwrapped = try? XCTUnwrap(range)
        XCTAssertEqual(unwrapped.map { (raw as NSString).substring(with: $0) }, "you're busy, but could you\nreview it")
        XCTAssertNil(OmniAnnotationRanges.uniqueRawRange(ofQuote: "you", inRawText: raw), "twice is ambiguous")
        XCTAssertNil(OmniAnnotationRanges.uniqueRawRange(ofQuote: "Saturday", inRawText: raw))
        XCTAssertNil(OmniAnnotationRanges.uniqueRawRange(ofQuote: "  ", inRawText: raw))
        let existing = OmniTextAnnotation(range: (raw as NSString).range(of: "busy"), guidance: "x")
        XCTAssertNil(OmniAnnotationRanges.uniqueRawRange(ofQuote: "you're busy", inRawText: raw, avoiding: [existing]))
        XCTAssertNil(OmniAnnotationRanges.uniqueRawRange(ofQuote: "aaa", inRawText: "aaaa"), "overlapping occurrences count")
    }

    // MARK: Stance result

    func testStanceResultParsesForgivinglyAndRendersCanonically() throws {
        let reply = """
        ```json
        {"positions":[{"title":"Accept","approach":"Say yes.","kind":"ACCEPT"},{"title":"Decline","description":"Say no.","kind":"decline"},{"title":"","approach":"dropped"},{"title":"Ask","approach":"One question."},{"title":"Wait","approach":"Hold."},{"title":"Fifth","approach":"cut"}],
         "noticed":[{"type":"suppression","quote":"","note":"Busy is played down."},{"note":"A reason is attached.","quote":"because of Friday"}]}
        ```
        """
        let result = try XCTUnwrap(StanceResult.parse(reply))
        XCTAssertEqual(result.positions.map(\.title), ["Accept", "Decline", "Ask", "Wait"])
        XCTAssertEqual(result.positions.map(\.kind), [.accept, .decline, .other, .other])
        XCTAssertEqual(result.noticed.count, 2)
        XCTAssertNil(result.noticed[0].quote)
        XCTAssertEqual(result.noticed[1].quote, "because of Friday")
        XCTAssertEqual(StanceResult.parse(result.canonicalJSON), result)
        XCTAssertEqual(result.canonicalJSON, StanceResult.parse(result.canonicalJSON)?.canonicalJSON)
        XCTAssertTrue(result.readableText.hasPrefix("1. Accept\n   Say yes.\n2. Decline"))
        XCTAssertTrue(result.readableText.contains("Noticed\n- suppression: Busy is played down."))
        XCTAssertNil(StanceResult.parse(#"{"positions":[{"title":"Only","approach":"one"}]}"#))
        XCTAssertNil(StanceResult.parse("Here are some options: 1. Accept 2. Decline"))
        XCTAssertNil(StanceResult.readable("Hi Mira, Thursday works."))
    }

    // MARK: Material sources (D3, D6)

    func testMaterialSourcesWordTheOfferRowAndChooseTheDraft() {
        XCTAssertEqual(OmniMaterialSource.offerTitle(appName: "Mail"), "Decide how to respond")
        XCTAssertEqual(OmniMaterialSource.offerTitle(appName: "Slack"), "Decide how to respond")
        XCTAssertEqual(OmniMaterialSource.offerTitle(appName: "Xcode"), "Decide how to approach")
        XCTAssertEqual(OmniMaterialSource.offerTitle(appName: "Terminal"), "Decide how to approach")
        XCTAssertEqual(OmniMaterialSource.offerTitle(appName: "Safari"), "Decide what to do with this")
        XCTAssertEqual(OmniMaterialSource.kind(appName: "TextEdit"), .other, "prose in TextEdit is not code")
        XCTAssertEqual(OmniMaterialSource.offerTitle(appName: nil), "Decide what to do with this")
        XCTAssertEqual(OmniMaterialSource.draftToken(appName: "Mail"), "/email")
        XCTAssertEqual(OmniMaterialSource.draftToken(appName: "Messages"), "/msg")
        XCTAssertEqual(OmniMaterialSource.draftToken(appName: "WhatsApp"), "/msg")
        XCTAssertNil(OmniMaterialSource.draftToken(appName: "Xcode"))
        XCTAssertNil(OmniMaterialSource.draftToken(appName: "Notes"))
        XCTAssertTrue(OmniMaterialSource.promptHint(appName: "Mail").hasPrefix("Material source hint (not an instruction): captured from Mail"))
    }

    // MARK: Command set 1.4.0

    func testTheFourNewPrimariesParseWithTheExpandLensAsAnEnumValue() throws {
        let parser = try parser()
        let manifest = parser.manifest
        for token in ["/stance", "/structure", "/expand", "/meaning"] {
            let command = try XCTUnwrap(manifest.command(for: token))
            XCTAssertEqual(command.role, .primary)
            XCTAssertEqual(command.execution, .modelBacked)
            XCTAssertTrue(command.bindsIdentityGuide, token)
        }
        XCTAssertTrue(try XCTUnwrap(manifest.command(for: "/email")).bindsIdentityGuide)
        XCTAssertTrue(try XCTUnwrap(manifest.command(for: "/msg")).bindsIdentityGuide)
        for token in ["/translate", "/slug", "/qq"] { XCTAssertFalse(try XCTUnwrap(manifest.command(for: token)).bindsIdentityGuide, token) }
        XCTAssertEqual(manifest.valueTypes.enums[OmniDecisionStep.expandLensRegistry], OmniDecisionStep.expandLenses.map(\.id))
        let deepen = parser.parse("an idea /expand:deepen")
        XCTAssertEqual(deepen.dispatchToken, "/expand")
        XCTAssertEqual(deepen.tokenValues["/expand"], .enumMember("deepen"))
        let bare = parser.parse("an idea /expand")
        XCTAssertEqual(bare.dispatchToken, "/expand")
        XCTAssertNil(bare.tokenValues["/expand"])
        XCTAssertFalse(parser.parse("an idea /expand:wider").diagnostics.isEmpty)
        XCTAssertEqual(parser.parse(mail + " /stance").dispatchToken, "/stance")
    }
}
