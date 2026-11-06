import Foundation
@testable import OmniCore
import Testing

private let fixtureNow = Date(timeIntervalSince1970: 1_790_000_000)
private let fixtureOld = fixtureNow.addingTimeInterval(-400 * 86_400)

private func goldenFixture() -> LauncherIndex {
    LauncherIndex(candidates: [
        LauncherCandidate(title: "Ghostty", path: "/Applications/Ghostty.app", kind: "app", source: .apps),
        LauncherCandidate(title: "Sublime Text", path: "/Applications/Sublime Text.app", kind: "app", source: .apps),
        LauncherCandidate(title: "omni-intent", path: "/Users/fixture/Lab/omni-intent", kind: "folder", source: .roots, modified: fixtureOld),
        LauncherCandidate(title: "Omni Intent: Early Riff", path: "/Users/fixture/Tooling/riff.md", kind: "note", source: .docsIndex, modified: fixtureOld),
        LauncherCandidate(title: "Omni Intent Token Grammar", path: "/Users/fixture/Tooling/grammar.md", kind: "spec", source: .docsIndex, modified: fixtureOld),
    ])
}

@Test func curatedGoldenScoresAndReadyFlagsRemainUnchanged() {
    let index = goldenFixture()
    let expected: [(String, Bool, Double, [Double])] = [
        ("sublime", true, 0.6351123595505619, [0.6351123595505619]),
        ("omni intent", false, 0.002270435528856307, [0.5361463010420778, 0.5338758655132215, 0.5322474595917455]),
        ("omni", false, 0.031186440677965943, [0.5402639260152596, 0.5090774853372937, 0.5072130785576328]),
        ("gho", true, 0.5832653061224491, [0.5832653061224491]),
    ]
    for (query, ready, margin, scores) in expected {
        let result = index.query(query, now: fixtureNow)
        #expect(result.lane == .curated)
        #expect(result.ready == ready)
        #expect(abs((result.margin ?? 0) - margin) < 1e-12)
        #expect(result.rows.count == scores.count)
        for (row, score) in zip(result.rows, scores) { #expect(abs(row.score - score) < 1e-12) }
    }
}

private func candidate(_ name: String, parent: String, kind: String = "pdf", added: Date? = nil, source: LauncherSource = .files) -> LauncherCandidate {
    LauncherCandidate(title: name, path: "/Users/fixture/\(parent)/\(name).\(kind)", kind: kind, source: source, added: added)
}

@Test func everywhereRequiresThreeCharactersAndNeverMarksReady() {
    let index = LauncherIndex(candidates: [candidate("Biography", parent: "Documents")], lane: .everywhere)
    #expect(index.query("bi", now: fixtureNow).rows.isEmpty)
    #expect(index.query("bi", now: fixtureNow).lane == .everywhere)
    let result = index.query("bio", now: fixtureNow)
    #expect(result.rows.count == 1)
    #expect(!result.ready)
    #expect(index.matchCount("bi") == 0)
    #expect(index.matchCount("bio") == 1)
}

@Test func parentFolderDisambiguatesDuplicateNamesOnlyInEverywhere() {
    let helios = candidate("README", parent: "Projects/Helios", kind: "md")
    let other = candidate("README", parent: "Projects/Cassandra", kind: "md")
    let index = LauncherIndex(candidates: [helios, other], lane: .everywhere)
    #expect(index.query("helios readme", now: fixtureNow).rows.map(\.candidate.path) == [helios.path])
    #expect(index.matchCount("helios readme") == 1)
    #expect(LauncherIndex(candidates: [helios, other]).query("helios readme", now: fixtureNow).rows.isEmpty)
}

@Test func newlyAddedComparableFileOutranksOlderFile() {
    let recent = candidate("Report", parent: "Documents/New", added: fixtureNow)
    let old = candidate("Report", parent: "Documents/Old", added: fixtureNow.addingTimeInterval(-60 * 86_400))
    let result = LauncherIndex(candidates: [old, recent], lane: .everywhere).query("report", now: fixtureNow)
    #expect(result.rows.map(\.candidate.path) == [recent.path, old.path])
    #expect(result.rows[0].recency == 1)
    #expect(result.rows[1].recency == 0)
    #expect(result.rows[0].score - result.rows[1].score >= 0.19)
}

@Test func mediaCapIsAppliedWhileRankingSoDocumentsFillFifteenRows() {
    let recent = fixtureNow
    let media = (0..<20).map { candidate("bio", parent: "Desktop/Media-\($0)", kind: "jpg", added: recent) }
    let docs = (0..<20).map { candidate("biography-\($0)", parent: "Documents", added: fixtureOld) }
    let result = LauncherIndex(candidates: media + docs, lane: .everywhere).query("bio", now: fixtureNow)
    #expect(result.rows.count == LauncherIndex.candidateCap)
    #expect(result.rows.filter { $0.candidate.kind == "jpg" }.count == 3)
    #expect(result.rows.filter { $0.candidate.kind == "pdf" }.count == 12)
}

@Test func agentOutputAndMediaHaveLowerKindPriority() throws {
    let ordinary = candidate("Receipt", parent: "Documents", added: fixtureNow)
    let run = candidate("Receipt", parent: "Tooling/agent-output/abc_run", kind: "pdf", added: fixtureNow)
    let media = candidate("Receipt", parent: "Desktop", kind: "jpg", added: fixtureNow)
    let result = LauncherIndex(candidates: [media, run, ordinary], lane: .everywhere).query("receipt", now: fixtureNow)
    #expect(result.rows.map(\.candidate.path) == [ordinary.path, run.path, media.path])
}

@Test func cappedCountMatchesEverywhereSemanticMatcher() {
    let rows = (0..<130).map { candidate("Biography-\($0)", parent: "Documents") }
    let index = LauncherIndex(candidates: rows, lane: .everywhere)
    #expect(index.matchCount("bio", cap: 100) == 100)
    #expect(index.matchCount("bio", cap: 150) == index.query("bio", now: fixtureNow, limit: 150).rows.count)
    #expect(index.matchCount("no match", cap: 100) == 0)
}

@Test func widenedUnionPrefersCuratedTextAndEverywhereAddedDate() throws {
    let path = "/Users/fixture/Documents/notes.md"
    let curated = LauncherCandidate(title: "Curated Notes", path: path, kind: "note", source: .docsIndex, added: fixtureOld, tags: ["personal"])
    let everywhere = LauncherCandidate(title: "notes", path: path, kind: "md", source: .files, added: fixtureNow)
    let extra = candidate("Elsewhere", parent: "Downloads")
    let union = LauncherIndexAssembler.union(curated: [curated], everywhere: [everywhere, extra])
    #expect(union.count == 2)
    let merged = try #require(union.first)
    #expect(merged.title == "Curated Notes")
    #expect(merged.kind == "note" && merged.tags == ["personal"] && merged.source == .docsIndex)
    #expect(merged.added == fixtureNow)
    #expect(union[1] == extra)
    #expect(curated.added == fixtureOld)
}

@Test func archivesAndInstallersRevealOnlyForEverywhereOpen() {
    for ext in ["pkg", "dmg", "zip", "tar", "gz", "tgz", "7z", "rar"] {
        let row = candidate("download", parent: "Downloads", kind: ext)
        #expect(LauncherOpenAction.open.effective(for: row, lane: .everywhere) == .reveal)
        #expect(LauncherOpenAction.open.effective(for: row, lane: .curated) == .open)
        #expect(LauncherOpenAction.reveal.effective(for: row, lane: .everywhere) == .reveal)
    }
    #expect(LauncherOpenAction.open.effective(for: candidate("paper", parent: "Downloads"), lane: .everywhere) == .open)
}

@Test func launchLogV2AndV1LaneDecodingPreserveFrecency() throws {
    let path = "/Users/fixture/Documents/Report.pdf"
    let entry = LaunchLogEntry(timestamp: fixtureNow, event: .launch, query: "report", candidateID: path, ready: false, top1Chosen: true, fellThrough: false, lane: .everywhere)
    let line = try entry.jsonLine()
    #expect(line.contains("\"schema_version\":2"))
    #expect(line.contains("\"lane\":\"everywhere\""))
    #expect(try LaunchLogEntry.decode(line: line).lane == .everywhere)
    var v1 = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    v1.removeValue(forKey: "lane")
    v1["schema_version"] = 1
    let v1Data = try JSONSerialization.data(withJSONObject: v1)
    let decoded = try LaunchLogEntry.decode(line: String(decoding: v1Data, as: UTF8.self))
    #expect(decoded.lane == .curated)
    let frecency = LauncherFrecency(entries: [entry, decoded])
    #expect(frecency.decayedCount(candidateID: path, now: fixtureNow) == 2)
}
