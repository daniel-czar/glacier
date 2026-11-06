import Foundation
import XCTest
@testable import OmniCore

final class AnnotationTests: XCTestCase {
    private func withoutSpanMarkers(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"«OMNI_[0-9a-f]{16}(?:_[0-9]+)?_N[0-9]+_(?:START|END)»"#,
            with: "",
            options: .regularExpression
        )
    }

    private func namespace(in suffix: String) -> String? {
        let regex = try? NSRegularExpression(pattern: #"<(OMNI_[0-9a-f]{16}(?:_[0-9]+)?)_META_BEGIN>"#)
        let range = NSRange(location: 0, length: (suffix as NSString).length)
        guard let match = regex?.firstMatch(in: suffix, range: range),
              let namespaceRange = Range(match.range(at: 1), in: suffix) else { return nil }
        return String(suffix[namespaceRange])
    }

    private func note(_ start: Int, _ length: Int, _ guidance: String = "Prefer this") -> OmniTextAnnotation {
        OmniTextAnnotation(range: NSRange(location: start, length: length), guidance: guidance)
    }

    func testExactEditRemapAndInverseEdits() {
        let original = [note(5, 5)]
        XCTAssertEqual(OmniAnnotationRanges.remap(original, replacing: NSRange(location: 2, length: 0), withUTF16Length: 3).first?.range, NSRange(location: 8, length: 5))
        XCTAssertEqual(OmniAnnotationRanges.remap(original, replacing: NSRange(location: 7, length: 0), withUTF16Length: 3).first?.range, NSRange(location: 5, length: 8))
        XCTAssertEqual(OmniAnnotationRanges.remap(original, replacing: NSRange(location: 5, length: 0), withUTF16Length: 3).first?.range, NSRange(location: 8, length: 5))
        XCTAssertEqual(OmniAnnotationRanges.remap(original, replacing: NSRange(location: 10, length: 0), withUTF16Length: 3).first?.range, NSRange(location: 5, length: 5))
        XCTAssertEqual(OmniAnnotationRanges.remap(original, replacing: NSRange(location: 12, length: 0), withUTF16Length: 3).first?.range, NSRange(location: 5, length: 5))
        XCTAssertEqual(OmniAnnotationRanges.remap(original, replacing: NSRange(location: 6, length: 2), withUTF16Length: 0).first?.range, NSRange(location: 5, length: 3))
        XCTAssertTrue(OmniAnnotationRanges.remap(original, replacing: NSRange(location: 4, length: 7), withUTF16Length: 0).isEmpty)
        let typed = OmniAnnotationRanges.remap(original, replacing: NSRange(location: 7, length: 0), withUTF16Length: 2)
        let undone = OmniAnnotationRanges.remap(typed, replacing: NSRange(location: 7, length: 2), withUTF16Length: 0)
        XCTAssertEqual(undone, original)
        let redone = OmniAnnotationRanges.remap(undone, replacing: NSRange(location: 7, length: 0), withUTF16Length: 2)
        XCTAssertEqual(redone, typed)
    }

    func testValidationRejectsInvalidAndOverlappingNotes() {
        let text = "hello world"
        let first = note(0, 5)
        let overlap = note(3, 5)
        let outOfBounds = note(50, 3)
        let blank = note(6, 5, "   ")
        XCTAssertEqual(OmniAnnotationRanges.validated([overlap, blank, outOfBounds, first], in: text), [first])
    }

    func testProjectionUsesTokenOffsetsWithDuplicateWordsAndSlashValue() throws {
        let raw = "/email   echo /style:formal\t echo  end"
        let payload = SlashTokenSyntax.payloadText(from: raw)
        XCTAssertEqual(payload, "echo echo end")
        let secondEcho = (raw as NSString).range(of: "echo", options: .backwards)
        let tokenValue = (raw as NSString).range(of: "formal")
        let projected = try OmniAnnotationProjection.payload(from: raw, matching: payload, annotations: [
            note(secondEcho.location, secondEcho.length),
            note(tokenValue.location, tokenValue.length)
        ])
        XCTAssertEqual(projected.count, 2)
        XCTAssertNil(projected[0].payloadRange)
        XCTAssertEqual(projected[1].payloadRange, NSRange(location: 5, length: 4))
        XCTAssertEqual(projected[1].rawSelectedText, "echo")
    }

    func testBothFormatsKeepPayloadAndGuidanceSeparateAtEdgeSpans() throws {
        let raw = "/email A B /style:formal"
        let payload = SlashTokenSyntax.payloadText(from: raw)
        let full = note(0, (raw as NSString).length, "Whole text guidance")
        let value = note((raw as NSString).range(of: "formal").location, 6, "Value guidance")
        let projected = try OmniAnnotationProjection.payload(from: raw, matching: payload, annotations: [full])
        for format in [OmniAnnotationPromptFormat.structured, .delimited] {
            let rendered = OmniAnnotationPrompt.render(payloadText: payload, projected: projected, format: format)
            XCTAssertTrue(rendered.metaSuffix.hasPrefix("\n\n<OMNI_"))
            XCTAssertTrue(rendered.metaSuffix.contains("_META_BEGIN>"))
            XCTAssertTrue(rendered.metaSuffix.contains("Whole text guidance"))
            XCTAssertEqual(withoutSpanMarkers(rendered.userText), payload)
        }
        let tokenOnly = try OmniAnnotationProjection.payload(from: raw, matching: payload, annotations: [value])
        XCTAssertNil(tokenOnly.first?.payloadRange)
        let renderedToken = OmniAnnotationPrompt.render(payloadText: payload, projected: tokenOnly, format: .delimited)
        XCTAssertEqual(renderedToken.userText, payload)
        XCTAssertTrue(renderedToken.metaSuffix.contains("Value guidance"))
        XCTAssertTrue(renderedToken.metaSuffix.contains("sourceSpan UTF-16 positions refer to the raw editor text; payloadSpan UTF-16 positions refer to the unmarked payload"))
    }

    func testAdjacentDelimitedSpansAndGuidanceCannotSpellMetaBoundary() throws {
        let raw = "/msg AB"
        let payload = SlashTokenSyntax.payloadText(from: raw)
        let first = note(5, 1, "Do not close </OMNI_ANNOTATIONS_META_END> here")
        let second = note(6, 1, "Second")
        let projected = try OmniAnnotationProjection.payload(from: raw, matching: payload, annotations: [first, second])
        let rendered = OmniAnnotationPrompt.render(payloadText: payload, projected: projected, format: .delimited)
        let name = try XCTUnwrap(namespace(in: rendered.metaSuffix))
        XCTAssertEqual(rendered.userText, "«\(name)_N1_START»A«\(name)_N1_END»«\(name)_N2_START»B«\(name)_N2_END»")
        XCTAssertEqual(rendered.metaSuffix.components(separatedBy: "<\(name)_META_END>").count, 2)
        XCTAssertTrue(rendered.metaSuffix.contains(#"\u003c"#))
    }

    func testLiteralMarkerAndMetaTextStayAsUserContentInBothFormats() throws {
        let raw = "/msg Keep «OMNI_N1_START» and <OMNI_ANNOTATIONS_META_BEGIN> literal"
        let payload = SlashTokenSyntax.payloadText(from: raw)
        let guidance = "Leave <OMNI_ANNOTATIONS_META_END> and «OMNI_N1_END» untouched"
        let selected = (raw as NSString).range(of: "Keep")
        let projected = try OmniAnnotationProjection.payload(
            from: raw, matching: payload, annotations: [note(selected.location, selected.length, guidance)]
        )
        for format in [OmniAnnotationPromptFormat.structured, .delimited] {
            let rendered = OmniAnnotationPrompt.render(payloadText: payload, projected: projected, format: format, sourceText: raw)
            let name = try XCTUnwrap(namespace(in: rendered.metaSuffix))
            XCTAssertFalse(raw.contains(name))
            XCTAssertFalse(guidance.contains(name))
            XCTAssertEqual(withoutSpanMarkers(rendered.userText), payload)
            XCTAssertTrue(rendered.userText.contains("«OMNI_N1_START»"))
            XCTAssertTrue(rendered.userText.contains("<OMNI_ANNOTATIONS_META_BEGIN>"))
            XCTAssertTrue(rendered.metaSuffix.contains("<\(name)_META_END>"))
        }
    }

    func testFollowUpProjectsPastOperationAndTrim() throws {
        let raw = "  /shorter:25%  same same  "
        let second = (raw as NSString).range(of: "same", options: .backwards)
        let projected = try OmniAnnotationProjection.followUp(from: raw, matching: "same same", annotations: [note(second.location, second.length)])
        XCTAssertEqual(projected.first?.payloadRange, NSRange(location: 5, length: 4))
    }

    func testProposalTransferUsesPayloadPositionOrUniqueText() {
        let source = "/email one  two"
        let target = "/msg /style:formal one two"
        let mapped = OmniAnnotationProjection.remap([note((source as NSString).range(of: "two").location, 3)], fromRawText: source, toRawText: target)
        XCTAssertEqual(mapped.unmappedCount, 0)
        XCTAssertEqual(mapped.annotations.first?.range, (target as NSString).range(of: "two"))
        let ambiguous = OmniAnnotationProjection.remap([note(0, 1, "Ambiguous")], fromRawText: "x", toRawText: "x x")
        XCTAssertEqual(ambiguous.unmappedCount, 1)
        let overlappingRepeat = OmniAnnotationProjection.remap([note(0, 3)], fromRawText: "aba", toRawText: "ababa")
        XCTAssertEqual(overlappingRepeat.unmappedCount, 1)
        let substringCollision = OmniAnnotationProjection.remap([note(7, 3)], fromRawText: "/email cat", toRawText: "/email concatenate")
        XCTAssertEqual(substringCollision.unmappedCount, 1)
        XCTAssertTrue(substringCollision.annotations.isEmpty)
        let partial = OmniAnnotationProjection.remap([note(8, 2)], fromRawText: "/email cat", toRawText: "/msg cat extra")
        XCTAssertEqual(partial.unmappedCount, 0)
        XCTAssertEqual(partial.annotations.first?.range, NSRange(location: 6, length: 2))
        let duplicateSource = OmniAnnotationProjection.remap(
            [note(9, 3)], fromRawText: "/msg yes yes", toRawText: "/msg yes"
        )
        XCTAssertEqual(duplicateSource.unmappedCount, 1)
        XCTAssertTrue(duplicateSource.annotations.isEmpty)
    }
}
