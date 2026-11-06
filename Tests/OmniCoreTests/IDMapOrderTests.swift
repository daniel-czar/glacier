import Foundation
import OmniCore
import Testing

// M1 review fixes and the steering-approved filename key (D1): precedence,
// copies, the row cap, folded README ids.

private let id = "569d5a7cf925cbd7"

private func doc(_ path: String, id: String?, modified: TimeInterval = 0) -> LauncherCandidate {
    LauncherCandidate(title: (path as NSString).lastPathComponent, path: path, kind: "spec", source: .docsIndex, modified: Date(timeIntervalSince1970: modified), documentID: id)
}

private func file(_ path: String, modified: TimeInterval = 0) -> LauncherCandidate {
    LauncherCandidate(title: (path as NSString).lastPathComponent, path: path, kind: "md", source: .files, modified: Date(timeIntervalSince1970: modified))
}

@Test func filenameIDsAreAnchoredSuffixesBeforeAnExtension() {
    #expect(OmniIDAddress.filenameID("omni-find-id-lane-decision-surface_\(id).md") == id)
    #expect(OmniIDAddress.filenameID("report_\(id).pdf") == id)
    #expect(OmniIDAddress.filenameID("report_\(id)") == nil, "an extension is required")
    #expect(OmniIDAddress.filenameID("_\(id).md") == nil, "a title before the id")
    #expect(OmniIDAddress.filenameID("report_\(id.uppercased()).md") == nil)
    #expect(OmniIDAddress.filenameID("report_\(id)x.md") == nil)
    #expect(OmniIDAddress.filenameID("\(id)_report.md") == nil, "a prefix is not a suffix")
}

@Test func aFreshFilenameIDResolvesUntilTheIndexClaimsThePath() throws {
    let fresh = file("/Users/fixture/Base/surface_\(id).md", modified: 100)
    let before = LauncherIDMap(curated: [], everywhere: [fresh])
    let hits = before.hits(for: try #require(OmniIDAddress(id)))
    #expect(hits.map(\.candidate.path) == [fresh.path])
    #expect(hits.first?.key == .filename && hits.first?.namespace == .doc && hits.first?.lane == .everywhere)
    // The index catches up: the docs-index row takes precedence, no duplicate.
    let indexed = doc(fresh.path, id: id, modified: 100)
    let after = LauncherIDMap(curated: [indexed], everywhere: [fresh])
    #expect(after.hits(for: try #require(OmniIDAddress(id))).map(\.key) == [.documentIndex])
}

@Test func whenTheIndexAndTheFilenameDisagreeTheIndexWins() throws {
    let path = "/Users/fixture/Base/renamed_\(id).md"
    let other = "0123456789abcdef"
    let map = LauncherIDMap(curated: [doc(path, id: other)], everywhere: [file(path)])
    #expect(map.hits(for: try #require(OmniIDAddress(other))).map(\.candidate.path) == [path])
    #expect(map.hits(for: try #require(OmniIDAddress(id))).isEmpty, "no filename key for a claimed path")
    // A docs-index row without an id still claims its path.
    let unclaimed = LauncherIDMap(curated: [doc(path, id: nil)], everywhere: [file(path)])
    #expect(unclaimed.hits(for: try #require(OmniIDAddress(id))).isEmpty)
}

@Test func copiesOfOneIDOrderMostRecentFirstAndDocsIndexBeforeRunsAndFilenames() throws {
    let older = doc("/Users/fixture/Tooling/agent-output/aaaa000011112222_a/s_\(id).md", id: id, modified: 10)
    let newer = doc("/Users/fixture/Tooling/agent-output/bbbb000011112222_b/s_\(id).md", id: id, modified: 20)
    let run = LauncherCandidate(title: "\(id)_run", path: "/Users/fixture/Tooling/agent-output/\(id)_run", kind: "run-folder", source: .roots, modified: Date(timeIntervalSince1970: 99))
    let named = file("/Users/fixture/Base/other_\(id).pdf", modified: 500)
    let map = LauncherIDMap(curated: [named], everywhere: [older, run, newer])
    let hits = map.hits(for: try #require(OmniIDAddress(id)))
    #expect(hits.map(\.candidate.path) == [newer.path, older.path, run.path, named.path])
    #expect(map.results(for: try #require(OmniIDAddress(id)), query: id, lane: .curated).rows.first?.candidate.path == newer.path, "Enter's row is the most recent copy")
}

@Test func anIDWithManyCopiesShowsAtMostFifteenRows() throws {
    let copies = (0..<24).map { doc("/Users/fixture/Tooling/agent-output/\(String(format: "%016x", $0))_r/x_\(id).md", id: id, modified: TimeInterval($0)) }
    let map = LauncherIDMap(curated: [], everywhere: copies)
    let hits = map.hits(for: try #require(OmniIDAddress(id)))
    #expect(hits.count == 15)
    #expect(hits.first?.candidate.modified == Date(timeIntervalSince1970: 23))
}

@Test func aFoldedProjectReadmeKeepsItsIDAsAnAddress() throws {
    let home = "/Users/fixture"
    let root = LauncherCandidate(title: "ambervale", path: "\(home)/Lab/ambervale", kind: "folder", source: .roots)
    let readme = LauncherDocsRow(path: "\(home)/Lab/ambervale/README.md", title: "Ambervale", kind: "readme", documentID: "fc5ae9afc0eac361")
    let assembled = LauncherIndexAssembler.assembleWithAddresses(LauncherSourceBatch(apps: [], roots: [root], docs: [readme], files: []), home: home)
    #expect(!assembled.candidates.contains { $0.path == readme.path }, "still folded into its folder row (C51)")
    #expect(assembled.addressOnly.map(\.path) == [readme.path])
    let map = LauncherIDMap(curated: assembled.candidates, everywhere: [], addressOnly: assembled.addressOnly)
    let readmeAddress = try #require(OmniIDAddress("fc5ae9afc0eac361"))
    let hit = try #require(map.hits(for: readmeAddress).first)
    #expect(hit.candidate.path == readme.path && hit.lane == .curated)
    // The snapshot carries them, decoded if present.
    let snapshot = LauncherSnapshot(builtAt: Date(), docsGeneration: nil, buildMilliseconds: nil, stats: LauncherIndexStats(), candidates: assembled.candidates, addressOnly: assembled.addressOnly)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    #expect(try decoder.decode(LauncherSnapshot.self, from: encoder.encode(snapshot)).addressOnly?.map(\.path) == [readme.path])
}

@Test func idLaunchesAreMarkedInTheLaunchLog() throws {
    let entry = LaunchLogEntry(timestamp: Date(timeIntervalSince1970: 0), event: .launch, query: id, ready: true, top1Chosen: true, fellThrough: false, addressed: true)
    let line = try entry.jsonLine()
    #expect(line.contains("\"addressed\":true"))
    let decoded = try LaunchLogEntry.decode(line: line)
    #expect(decoded.addressed == true)
    // Lines without the key (every older line) read as nil.
    let plain = LaunchLogEntry(timestamp: Date(timeIntervalSince1970: 0), event: .launch, query: "ghostty", ready: true, top1Chosen: true, fellThrough: false)
    #expect(!(try plain.jsonLine()).contains("addressed"))
}

@Test func manyCopiesNeverCrowdOutTheRunFolder() throws {
    let copies = (0..<20).map { doc("/Users/fixture/Tooling/agent-output/\(String(format: "%016x", $0))_r/x_\(id).md", id: id, modified: TimeInterval($0)) }
    let run = LauncherCandidate(title: "\(id)_run", path: "/Users/fixture/Tooling/agent-output/\(id)_run", kind: "run-folder", source: .roots)
    let hits = LauncherIDMap(curated: [], everywhere: copies + [run]).hits(for: try #require(OmniIDAddress(id)))
    #expect(hits.count == 15)
    #expect(hits.last?.candidate.path == run.path, "documents first, then the run folder, which always appears")
}

@Test func onlyLoadedFilesGainAFilenameKey() throws {
    let folder = LauncherCandidate(title: "x", path: "/Users/fixture/Lab/x_\(id).d", kind: "folder", source: .roots)
    let app = LauncherCandidate(title: "y", path: "/Applications/y_\(id).app", kind: "app", source: .apps)
    #expect(LauncherIDMap(curated: [folder, app], everywhere: []).count == 0)
}

@Test func anIDLaunchCountsButTeachesNoPrefix() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let addressed = LaunchLogEntry(timestamp: now, event: .launch, query: "ca12345678901234", candidateID: "/doc.md", ready: true, top1Chosen: true, fellThrough: false, addressed: true)
    let typed = LaunchLogEntry(timestamp: now, event: .launch, query: "ca12345678901234", candidateID: "/doc.md", ready: true, top1Chosen: true, fellThrough: false)
    let fromID = LauncherFrecency(entries: [addressed])
    let fromTyping = LauncherFrecency(entries: [typed])
    #expect(fromID.decayedCount(candidateID: "/doc.md", now: now) == fromTyping.decayedCount(candidateID: "/doc.md", now: now))
    #expect(fromID.score(candidateID: "/doc.md", foldedQuery: "ca", now: now) < fromTyping.score(candidateID: "/doc.md", foldedQuery: "ca", now: now), "typing ca gets no boost from an id that starts with it")
}
