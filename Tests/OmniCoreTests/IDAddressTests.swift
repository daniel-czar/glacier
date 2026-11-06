import Foundation
import OmniCore
import Testing

// The exact-id lane's grammar and map (D1, decision surface 569d5a7cf925cbd7).

private let id = "569d5a7cf925cbd7"

@Test func aBareSixteenHexIDIsAnAddressWithOrWithoutANamespace() throws {
    #expect(OmniIDAddress(id) == OmniIDAddress(id))
    #expect(try #require(OmniIDAddress(id)).namespace == nil)
    #expect(try #require(OmniIDAddress("doc:\(id)")).namespace == .doc)
    #expect(try #require(OmniIDAddress("run:\(id)")).namespace == .run)
    #expect(try #require(OmniIDAddress("run:\(id)")).id == id)
    // A pasted id often carries whitespace or a newline.
    #expect(try #require(OmniIDAddress("  \(id)\n")).id == id)
    #expect(try #require(OmniIDAddress("\tdoc:\(id) ")).namespace == .doc)
}

@Test func anyCaseAndZeroWidthWrappedIDsAreTheSameAddress() throws {
    // One normaliser for the launcher, /find and the service (steering,
    // 2026-10-10): case folds, zero-width characters and a BOM are trimmed,
    // the stored id is lowercase.
    #expect(OmniIDAddress(id.uppercased()) == OmniIDAddress(id))
    #expect(try #require(OmniIDAddress("569D5A7cf925cbd7")).id == id)
    #expect(try #require(OmniIDAddress("DOC:\(id.uppercased())")).namespace == .doc)
    #expect(OmniIDAddress("\u{200B}\(id)\u{FEFF}") == OmniIDAddress(id))
    #expect(OmniIDAddress("\u{FEFF}run:\(id)\u{200D}\n")?.namespace == .run)
    // Quoted, backticked, bracketed or followed by punctuation, and wrapped
    // in direction marks or a soft hyphen: still the one address.
    for wrapped in ["`\(id)`", "\"\(id)\"", "“\(id)”", "(\(id))", "\(id).", "\(id),", "\u{200E}\(id)\u{200F}", "\u{00AD}\(id)", "(doc:\(id))"] {
        #expect(OmniIDAddress(wrapped)?.id == id, "\(wrapped.debugDescription)")
    }
}

@Test func wrongLengthsAndOtherTextAreOrdinaryText() {
    #expect(OmniIDAddress(String(id.dropLast())) == nil, "15 characters")
    #expect(OmniIDAddress(id + "0") == nil, "17 characters")
    #expect(OmniIDAddress("569d5a7cf925cbdg") == nil, "not hex")
    #expect(OmniIDAddress("note:\(id)") == nil)
    #expect(OmniIDAddress("doc: \(id)") == nil)
    #expect(OmniIDAddress("open \(id)") == nil)
    #expect(OmniIDAddress("") == nil)
    #expect(OmniIDAddress("doc:") == nil)
}

@Test func runFolderIDsAreLowercaseNamePrefixes() {
    #expect(OmniIDAddress.runFolderID("\(id)_omni_find_id_lane") == id)
    #expect(OmniIDAddress.runFolderID("\(id.uppercased())_x") == nil)
    #expect(OmniIDAddress.runFolderID("\(id)_") == nil)
    #expect(OmniIDAddress.runFolderID(id) == nil)
    #expect(OmniIDAddress.runFolderID("notes_\(id)") == nil)
}

private func doc(_ path: String, id: String?, title: String = "A document") -> LauncherCandidate {
    LauncherCandidate(title: title, path: path, kind: "spec", source: .docsIndex, documentID: id)
}

private func runFolder(_ name: String) -> LauncherCandidate {
    LauncherCandidate(title: name, path: "/Users/fixture/Tooling/agent-output/\(name)", kind: "run-folder", source: .roots)
}

@Test func theMapHoldsDocsRowsFromBothLanesAndRunFoldersDocumentFirst() throws {
    let curatedDoc = doc("/Users/fixture/Base/surface_\(id).md", id: id, title: "Decision surface")
    let agentDoc = doc("/Users/fixture/Tooling/agent-output/aaaa000011112222_x/review.md", id: "1111222233334444", title: "Review")
    let run = runFolder("\(id)_omni_find_id_lane")
    let noID = doc("/Users/fixture/Base/plain.md", id: nil)
    let map = LauncherIDMap(curated: [curatedDoc, noID], everywhere: [run, agentDoc])

    let both = map.hits(for: try #require(OmniIDAddress(id)))
    #expect(both.map(\.candidate.path) == [curatedDoc.path, run.path], "document first, then the run folder")
    #expect(both.map(\.lane) == [.curated, .everywhere])
    #expect(map.hits(for: try #require(OmniIDAddress("doc:\(id)"))).map(\.namespace) == [.doc])
    #expect(map.hits(for: try #require(OmniIDAddress("run:\(id)"))).map(\.namespace) == [.run])
    // An agent-output document only the everywhere lane holds.
    #expect(map.hits(for: try #require(OmniIDAddress("1111222233334444"))).map(\.lane) == [.everywhere])
    // A row without an id is not in the map; an unknown id is a miss.
    #expect(map.count == 2)
    #expect(map.hits(for: try #require(OmniIDAddress("ffffffffffffffff"))).isEmpty)
}

@Test func whereBothLanesHoldAPathTheCuratedRowWins() throws {
    let shared = doc("/Users/fixture/Base/surface_\(id).md", id: id)
    let map = LauncherIDMap(curated: [shared], everywhere: [shared])
    let hits = map.hits(for: try #require(OmniIDAddress(id)))
    #expect(hits.count == 1)
    #expect(hits.first?.lane == .curated)
}

@Test func idResultsAreReadyHitsOrAMissWithNoRows() throws {
    let curatedDoc = doc("/Users/fixture/Base/surface_\(id).md", id: id)
    let map = LauncherIDMap(curated: [curatedDoc], everywhere: [runFolder("\(id)_lane")])
    let hit = map.results(for: try #require(OmniIDAddress(id)), query: id, lane: .curated)
    #expect(hit.ready)
    #expect(hit.rows.count == 2)
    #expect(hit.rows.allSatisfy { $0.fuzzy == 0 }, "an address is not a score")
    #expect(hit.idLookup?.lane(for: curatedDoc.id) == .curated)
    #expect(hit.idLookup?.lane(for: "/Users/fixture/Tooling/agent-output/\(id)_lane") == .everywhere)
    let miss = map.results(for: try #require(OmniIDAddress("0000000000000000")), query: "0000000000000000", lane: .everywhere)
    #expect(miss.idLookup == .miss)
    #expect(miss.rows.isEmpty && !miss.ready && miss.lane == .everywhere)
}

@Test func candidatesWrittenBeforeDocumentIDsDecodeAndInvalidIDsAreDropped() throws {
    // A snapshot row as the installed 2026.10.15 binary persists it.
    let old = #"{"id":"/Users/fixture/Base/a.md","title":"A","path":"/Users/fixture/Base/a.md","kind":"note","source":"docs-index","tags":[]}"#
    let decoded = try JSONDecoder().decode(LauncherCandidate.self, from: Data(old.utf8))
    #expect(decoded.documentID == nil)
    let roundTrip = try JSONDecoder().decode(LauncherCandidate.self, from: JSONEncoder().encode(doc("/a.md", id: id)))
    #expect(roundTrip.documentID == id)
    #expect(doc("/b.md", id: "NOT-AN-ID").documentID == nil)
    #expect(doc("/b.md", id: id).withSummary("README").documentID == id)
    // The widened union keeps the id.
    let union = LauncherIndexAssembler.union(curated: [doc("/a.md", id: id)], everywhere: [doc("/a.md", id: nil)])
    #expect(union.first?.documentID == id)
}
