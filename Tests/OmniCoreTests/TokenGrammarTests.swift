import Foundation
import XCTest
@testable import OmniCore

final class TokenGrammarTests: XCTestCase {
    func testLengthNormalisationMatchesTheAcceptedGrammar() {
        XCTAssertEqual(LengthValue.parse("25%")?.canonical, "25%")
        XCTAssertEqual(LengthValue.parse("25")?.canonical, "25%")
        XCTAssertEqual(LengthValue.parse("0.25")?.canonical, "25%")
        XCTAssertEqual(LengthValue.parse("1")?.canonical, "1%")
        XCTAssertEqual(LengthValue.parse("1.0")?.canonical, "100%")
        XCTAssertEqual(LengthValue.parse("120w")?.canonical, "120w")
        XCTAssertEqual(LengthValue.parse("3s")?.canonical, "3s")
        XCTAssertNil(LengthValue.parse("2.5"))
        XCTAssertNil(LengthValue.parse("nope"))
        XCTAssertNil(LengthValue.parse(""))
    }

    func testLengthLiteralsAreStrictDigitGrammarNotDecimalPrefixes() {
        // `Decimal(string:)` parses a numeric prefix and drops the rest; the
        // grammar must reject anything that is not `[0-9]+` or `[0-9]+.[0-9]+`.
        for garbage in ["0.5abc", "0.2.5", ".5", "5.", "1.5.w", "+1.5w", "+1w", "-1", "0.1e1", "1e2", "1,5", "25 ", "٢٥", "1.5%%", "%", "w"] {
            XCTAssertNil(LengthValue.parse(garbage), garbage)
        }
        XCTAssertEqual(LengthValue.parse("1.5w")?.canonical, "1.5w")
        XCTAssertEqual(LengthValue.parse("0.5")?.canonical, "50%")
        XCTAssertEqual(LengthValue.parse("007")?.canonical, "7%")
    }

    func testSlashAtomsKeepInnerColonsAndRejectPaths() {
        XCTAssertEqual(SlashAtom.parse("/remind:15:00")?.value, "15:00")
        XCTAssertEqual(SlashAtom.parse("/shorter:25%")?.name, "shorter")
        XCTAssertNil(SlashAtom.parse("/usr/bin"))
        XCTAssertNil(SlashAtom.parse("https://example.com"))
        XCTAssertNil(SlashAtom.parse("$foo"))
        XCTAssertNotNil(SlashAtom.parse("/style:formal"))
    }

    func testPayloadStrippingRemovesValuedTokensAndKeepsPaths() {
        XCTAssertEqual(
            SlashTokenSyntax.payloadText(from: "/email /style:formal @zoe meet up for coffee at 3?"),
            "@zoe meet up for coffee at 3?"
        )
        XCTAssertEqual(
            SlashTokenSyntax.payloadText(from: "Keep this /shorter:25%"),
            "Keep this"
        )
        XCTAssertEqual(
            SlashTokenSyntax.payloadText(from: "Read /usr/bin docs"),
            "Read /usr/bin docs"
        )
    }

    func testFollowUpPromptStatesRequestedLength() {
        let shortened = FollowUpGenerationRequest(
            runID: "run",
            modelCommandID: "draft.email",
            sourceVersion: 1,
            sourceText: "A long draft",
            visibleText: "A long draft /shorter:0.25",
            operation: .shorter,
            length: LengthValue.parse("0.25"),
            offline: false
        )
        XCTAssertTrue(shortened.prompt.contains("25% of the source"))
        XCTAssertFalse(shortened.prompt.contains("a third to a half"))
        let defaulted = FollowUpGenerationRequest(
            runID: "run",
            modelCommandID: "draft.email",
            sourceVersion: 1,
            sourceText: "A long draft",
            visibleText: "A long draft /shorter",
            operation: .shorter,
            offline: false
        )
        XCTAssertTrue(defaulted.prompt.contains("a third to a half"))
    }
}
