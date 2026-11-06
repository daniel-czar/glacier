import Foundation
import XCTest
@testable import OmniCore

/// Provenance is an additive, optional envelope on `RuntimeRunContext`. Old
/// JSONL events that predate this field must keep decoding as if it were
/// absent, and a populated envelope must round-trip exactly.
final class RunProvenanceTests: XCTestCase {
    func testRuntimeContextRoundTripsProvenance() throws {
        let provenance = OmniRunProvenance(appName: "Mail", windowTitle: "Re: Quarterly plan", wordCount: 40)
        var context = RuntimeRunContext(input: nil, provenance: provenance)
        context.fullText = "carry-through of unrelated fields"

        let encoded = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(RuntimeRunContext.self, from: encoded)

        XCTAssertEqual(decoded.provenance, provenance)
        XCTAssertEqual(decoded.provenance?.appName, "Mail")
        XCTAssertEqual(decoded.provenance?.windowTitle, "Re: Quarterly plan")
        XCTAssertEqual(decoded.provenance?.wordCount, 40)
        XCTAssertEqual(decoded.fullText, "carry-through of unrelated fields")
    }

    func testRuntimeContextDecodesLegacyEventWithoutProvenanceKey() throws {
        let legacy = Data("{\"version\":1,\"fullText\":\"typed directly, no capture\"}".utf8)

        let decoded = try JSONDecoder().decode(RuntimeRunContext.self, from: legacy)

        XCTAssertNil(decoded.provenance)
        XCTAssertEqual(decoded.fullText, "typed directly, no capture")
    }

    func testRuntimeContextWithNilProvenanceOmitsTheKeyOnEncode() throws {
        let context = RuntimeRunContext()

        let encoded = try JSONEncoder().encode(context)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNil(object["provenance"])
    }
}
