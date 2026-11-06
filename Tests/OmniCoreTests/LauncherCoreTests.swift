import Foundation
@testable import OmniCore
import Testing

// Handoff §10 unit tests for the file-finder fast lane (H10, C50–C52).

private let home = "/Users/fixture"
private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func app(_ name: String) -> LauncherCandidate {
    LauncherCandidate(title: name, path: "/Applications/\(name).app", kind: "app", source: .apps)
}

private func folder(_ relative: String, modified: Date? = nil) -> LauncherCandidate {
    let path = "\(home)/\(relative)"
    return LauncherCandidate(title: (path as NSString).lastPathComponent, path: path, kind: "folder", source: .roots, modified: modified)
}

private func doc(_ relative: String, title: String?, kind: String = "note", updated: Date? = nil) -> LauncherDocsRow {
    LauncherDocsRow(path: "\(home)/\(relative)", title: title, kind: kind, updated: updated)
}

private func file(_ relative: String, title: String? = nil) -> LauncherCandidate {
    let path = "\(home)/\(relative)"
    let ext = (path as NSString).pathExtension
    return LauncherCandidate(title: title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension, path: path, kind: ext, source: .files)
}

private func score(_ query: String, _ title: String) -> Double? {
    var scratch = LauncherFuzzy.Scratch()
    return LauncherFuzzy.score(word: LauncherQuery(query).words[0], field: LauncherSearchField(title), scratch: &scratch)
}

// MARK: - Scorer

@Test func scorerNormalisesExactToOneAndOrdersPrefixBoundaryAndScatteredMatches() throws {
    #expect(score("ghostty", "Ghostty") == 1.0)
    let prefix = try #require(score("ghost", "Ghostty"))
    let boundary = try #require(score("ghost", "Tmux Ghost Reference"))
    let scattered = try #require(score("ghost", "go high on sat"))
    #expect(prefix < 1.0)
    #expect(prefix > boundary)
    #expect(boundary > scattered)
    for value in [prefix, boundary, scattered] { #expect((0...1).contains(value)) }
    #expect(score("zz", "Ghostty") == nil)
    #expect(score("ghosttyx", "Ghostty") == nil)
}

@Test func scorerRewardsWordBoundariesIncludingSeparatorsAndCamelCase() throws {
    // Same letters, same gaps: only the boundary position differs.
    let afterDash = try #require(score("ws", "warm-sun"))
    let midWord = try #require(score("ws", "warmxsun"))
    #expect(afterDash > midWord)
    let afterUnderscore = try #require(score("ws", "warm_sun"))
    let afterDot = try #require(score("ws", "warm.sun"))
    let afterSlash = try #require(score("ws", "warm/sun"))
    #expect(afterUnderscore == afterDash && afterDot == afterDash && afterSlash == afterDash)
    let camel = try #require(score("ws", "warmSun"))
    let flat = try #require(score("ws", "warmsun"))
    #expect(camel > flat)
    #expect(afterDash > camel)
}

@Test func scorerFoldsCaseAndDiacritics() throws {
    #expect(score("garten", "Gärten") == 1.0)
    #expect(score("CAFE", "café") == 1.0)
}

@Test func multiWordQueriesMatchEachWordIndependentlyWithAnInOrderBonus() throws {
    let index = LauncherIndex(candidates: [
        LauncherCandidate(title: "Warm Minimal Palette", path: "\(home)/Base/warm.md", kind: "note", source: .docsIndex),
        LauncherCandidate(title: "Warm Palette", path: "\(home)/Base/palette.md", kind: "note", source: .docsIndex),
        LauncherCandidate(title: "Minimal Warmth", path: "\(home)/Base/minimal.md", kind: "note", source: .docsIndex),
    ])
    let results = index.query("warm min", now: now)
    // Every word must match: "Warm Palette" has no "min".
    #expect(Set(results.rows.map(\.candidate.title)) == ["Warm Minimal Palette", "Minimal Warmth"])
    #expect(results.rows.first?.candidate.title == "Warm Minimal Palette")
    // The same two words reversed lose the in-order bonus on that title.
    let reversed = index.query("min warm", now: now)
    let forward = try #require(results.rows.first { $0.candidate.title == "Warm Minimal Palette" })
    let backward = try #require(reversed.rows.first { $0.candidate.title == "Warm Minimal Palette" })
    #expect(forward.fuzzy > backward.fuzzy)
}

@Test func queriesCollapseWhitespaceAndMatchTheBasenameAsASecondField() throws {
    let index = LauncherIndex(candidates: [
        LauncherCandidate(title: "Tagging Guidance", path: "\(home)/Tooling/docs/tagging-guidance_a1fb874d8e7db656.md", kind: "policy", source: .docsIndex),
    ])
    #expect(index.query("  tagging   guid ", now: now).query == "tagging guid")
    // A hex-ID filename is still reachable through the basename field.
    #expect(index.query("a1fb874d", now: now).rows.count == 1)
}

@Test func kindAndTagsAreTheDocsIndexSecondKeyButATitleMatchStillWins() throws {
    // `orbit spec`: the Orbit doc's title has no "spec"; its kind does.
    let index = LauncherIndex(candidates: [
        LauncherCandidate(title: "Orbit: workspace guide", path: "\(home)/Tooling/apps/orbit/orbit-guide.md", kind: "spec", source: .docsIndex, tags: ["orbit", "hyper-overlay"]),
        LauncherCandidate(title: "SPEC-017 - Instrument X-Ray Projection Materialization", path: "\(home)/Projects/Project_Cassandra/specs/spec-017.md", kind: "spec", source: .docsIndex),
        LauncherCandidate(title: "Orbit", path: "\(home)/Tooling/apps/orbit/README.md", kind: "readme", source: .docsIndex, tags: ["orbit"]),
    ])
    let results = index.query("orbit spec", now: now)
    #expect(results.top?.candidate.path == "\(home)/Tooling/apps/orbit/orbit-guide.md")
    // A tag word alone finds the tagged rows; the kind-word match is discounted.
    #expect(Set(index.query("hyper-overlay", now: now).rows.map(\.candidate.title)) == ["Orbit: workspace guide"])
    let viaKind = try #require(index.query("spec", now: now).rows.first { $0.candidate.title.hasPrefix("Orbit:") })
    let viaTitle = try #require(index.query("spec", now: now).rows.first { $0.candidate.title.hasPrefix("SPEC-017") })
    #expect(viaTitle.fuzzy > viaKind.fuzzy)
}

@Test func aContiguousPhraseBeatsTheSameLettersScattered() throws {
    // Real index, 2026-09-28: `warm min` put `warmińsko-mazurskie` above the
    // Warm Minimal documents.
    let index = LauncherIndex(candidates: [
        LauncherCandidate(title: "warmińsko-mazurskie", path: "\(home)/Base/warmi-sko-mazurskie_dc2fc459d5e16ea7.md", kind: "note", source: .docsIndex),
        LauncherCandidate(title: "Font Reference Card — Warm Minimal Ecosystem", path: "\(home)/Base/font-reference-card_d2e127d64add0940.md", kind: "reference", source: .docsIndex),
    ])
    #expect(index.query("warm min", now: now).top?.candidate.title == "Font Reference Card — Warm Minimal Ecosystem")
}

// MARK: - Assembly rules

@Test func worktreeCopiesCollapseOntoTheCanonicalCheckout() {
    let batch = LauncherSourceBatch(apps: [], roots: [], docs: [
        doc("Projects/Project_Cassandra_spl_factory_batch_refresh/specs/spec-008.md", title: "SPEC-008 Calibration Lab", kind: "spec"),
        doc("Projects/Project_Cassandra/specs/spec-008.md", title: "SPEC-008 Calibration Lab", kind: "spec"),
        doc("Projects/Project_Cassandra_spl_factory_integration/specs/spec-008.md", title: "SPEC-008 Calibration Lab", kind: "spec"),
        doc("Projects/Project_Cassandra/specs/spec-009.md", title: "SPEC-009 Something Else", kind: "spec"),
    ], files: [
        file("Projects/Project_Helios/docs/deck.pdf"),
        file("Projects/Project_Helios_feat_bridge/docs/deck.pdf"),
        // Same filename in unrelated projects is not a worktree copy.
        file("Lab/lethe/paper.pdf"),
        file("Lab/mesapotamia/paper.pdf"),
    ])
    let (candidates, stats) = LauncherIndexAssembler.assemble(batch, home: home)
    let paths = Set(candidates.map(\.path))
    #expect(paths.contains("\(home)/Projects/Project_Cassandra/specs/spec-008.md"))
    #expect(!paths.contains("\(home)/Projects/Project_Cassandra_spl_factory_batch_refresh/specs/spec-008.md"))
    #expect(stats.docsWorktreeDropped == 2)
    #expect(paths.contains("\(home)/Projects/Project_Helios/docs/deck.pdf"))
    #expect(!paths.contains("\(home)/Projects/Project_Helios_feat_bridge/docs/deck.pdf"))
    #expect(paths.contains("\(home)/Lab/lethe/paper.pdf") && paths.contains("\(home)/Lab/mesapotamia/paper.pdf"))
    #expect(stats.filesWorktreeDropped == 1)
}

@Test func docsIndexWinsByAbsolutePathSoNoPathAppearsTwice() {
    // Spike finding 1: the docs index and the crawl both produced every .md in
    // ~/Base, so the same file appeared twice with different kinds.
    let batch = LauncherSourceBatch(
        apps: [app("Ghostty"), app("Ghostty")],
        roots: [folder("Lab/elevator-escape")],
        docs: [
            doc("Base/font-reference-card_d2e127d64add0940.md", title: "Font Reference Card — Warm Minimal Ecosystem", kind: "reference"),
            doc("Base/font-reference-card_d2e127d64add0940.md", title: "Font Reference Card — Warm Minimal Ecosystem", kind: "reference"),
        ],
        files: [
            file("Base/font-reference-card_d2e127d64add0940.md", title: "Font Reference Card — Warm Minimal Ecosystem"),
            file("Base/loose-note.md"),
        ]
    )
    let (candidates, stats) = LauncherIndexAssembler.assemble(batch, home: home)
    #expect(Set(candidates.map(\.path)).count == candidates.count)
    let card = candidates.filter { $0.title.hasPrefix("Font Reference Card") }
    #expect(card.count == 1)
    #expect(card.first?.source == .docsIndex && card.first?.kind == "reference")
    #expect(stats.filesCoveredByDocs == 1)
    #expect(stats.duplicatePathsDropped == 1)
    #expect(candidates.contains { $0.path.hasSuffix("loose-note.md") && $0.source == .files })
    // With the precedence rule the tie the spike measured is gone.
    let results = LauncherIndex(candidates: candidates).query("warm minimal", now: now)
    #expect(results.rows.count == 1)
}

@Test func aReadmeAtALaunchableRootFeedsItsFolderRowInsteadOfTyingWithIt() {
    // Spike finding 2: `elevator-escape` and its README tied exactly.
    let batch = LauncherSourceBatch(
        apps: [],
        roots: [folder("Lab/elevator-escape"), folder("Lab/mesapotamia")],
        docs: [
            doc("Lab/elevator-escape/README.md", title: "Elevator Escape", kind: "readme"),
            doc("Lab/elevator-escape/docs/README.md", title: "Elevator Escape Docs", kind: "readme"),
            doc("Lab/elevator-escape/elevator-escape-tracking_586883aae8388b14.md", title: "Elevator Escape Tracking", kind: "tracker"),
        ],
        files: [file("Lab/mesapotamia/readme.md", title: "readme")]
    )
    let (candidates, stats) = LauncherIndexAssembler.assemble(batch, home: home)
    #expect(!candidates.contains { $0.path == "\(home)/Lab/elevator-escape/README.md" })
    #expect(!candidates.contains { $0.path == "\(home)/Lab/mesapotamia/readme.md" })
    // A README deeper in the tree is an ordinary candidate.
    #expect(candidates.contains { $0.path == "\(home)/Lab/elevator-escape/docs/README.md" })
    #expect(stats.readmesAbsorbed == 2)
    let escape = candidates.first { $0.path == "\(home)/Lab/elevator-escape" }
    #expect(escape?.summary == "Elevator Escape")
    // A README with no real title leaves no summary.
    #expect(candidates.first { $0.path == "\(home)/Lab/mesapotamia" }?.summary == nil)
    let results = LauncherIndex(candidates: candidates).query("elevator", now: now)
    #expect(results.top?.candidate.path == "\(home)/Lab/elevator-escape")
    #expect((results.margin ?? 0) > 0)
    #expect(LauncherRowText.subtitle(escape!, home: home, now: now) == "folder · ~/Lab · Elevator Escape")
}

@Test func exclusionsApplyToDocsIndexRowsAsWellAsCrawledFiles() {
    // Spike finding 3: a fixture out-ranked real targets and the docs index
    // carries rows under ~/Downloads.
    let batch = LauncherSourceBatch(apps: [], roots: [], docs: [
        doc("Tooling/retrieval/tests/fixtures/docs_index/source/helios/helios-body.md", title: "Fixture Body Match"),
        doc("Downloads/2025-23-01_downloads/Project_Helios/dev/kb.md", title: "Token Age Detection"),
        doc("Tooling/agent-output/abc_run/working-memory.md", title: "Working Memory"),
        doc("Lab/thing/Archive/old.md", title: "Old Thing"),
        doc("Lab/thing/node_modules/pkg/README.md", title: "Package"),
        doc("Projects/helios-oss/docs/knowledge/README.md", title: "Helios Knowledge Base", kind: "index"),
    ], files: [
        file("Lab/thing/examples/demo.pdf"),
        file("Lab/thing/.hidden/secret.pdf"),
        file("Lab/thing/Thing.app/Contents/Resources/help.pdf"),
        file("Lab/thing/docs/examples.pdf"),
    ])
    let (candidates, stats) = LauncherIndexAssembler.assemble(batch, home: home)
    #expect(candidates.map(\.title).sorted() == ["Helios Knowledge Base", "examples"])
    #expect(stats.docsExcluded == 5)
    #expect(stats.filesExcluded == 3)
}

// MARK: - Review round 1 regressions

@Test func aCopyTheDocsIndexDroppedDoesNotComeBackThroughTheCrawl() {
    // C1: 16 real cases re-created the spike's ties this way.
    let batch = LauncherSourceBatch(apps: [], roots: [], docs: [
        doc("Documents/Codex/a/liquid-continuum_1234567890abcdef.md", title: "Liquid Continuum Reference"),
        doc("Documents/Codex/b/liquid-continuum_1234567890abcdef.md", title: "Liquid Continuum Reference"),
    ], files: [
        file("Documents/Codex/a/liquid-continuum_1234567890abcdef.md", title: "Liquid Continuum Reference"),
        file("Documents/Codex/b/liquid-continuum_1234567890abcdef.md", title: "Liquid Continuum Reference"),
    ])
    let (candidates, stats) = LauncherIndexAssembler.assemble(batch, home: home)
    #expect(candidates.count == 1)
    #expect(stats.filesCoveredByDocs == 2)
}

@Test func theKindAndTagFieldTreatsTaggedAndUntaggedDocsAlikeAndNeverBeatsATitleMatch() throws {
    // C2: the joined field gave untagged docs an exact-match bonus.
    let index = LauncherIndex(candidates: [
        LauncherCandidate(title: "Quarterly Numbers", path: "\(home)/Base/q.md", kind: "analysis", source: .docsIndex),
        LauncherCandidate(title: "Yearly Numbers", path: "\(home)/Base/y.md", kind: "analysis", source: .docsIndex, tags: ["finance"]),
        LauncherCandidate(title: "Liquidity Analysis", path: "\(home)/Base/l.md", kind: "note", source: .docsIndex, tags: ["finance"]),
    ])
    let rows = index.query("analysis", now: now).rows
    let untagged = try #require(rows.first { $0.candidate.title == "Quarterly Numbers" })
    let tagged = try #require(rows.first { $0.candidate.title == "Yearly Numbers" })
    // Only the trailing-gap penalty of the longer field separates them now
    // (it was an exact-match bonus of about 0.27 before).
    #expect(abs(untagged.fuzzy - tagged.fuzzy) < 0.01)
    #expect(rows.first?.candidate.title == "Liquidity Analysis")
}

@Test func onlyWorktreeOrIdentifiedCopiesMergeAndTheCuratedCopySurvives() {
    // C3: generic names in unrelated folders are different files; an
    // id-bearing copy in a scratch folder loses to the curated home.
    let batch = LauncherSourceBatch(apps: [], roots: [], docs: [
        doc("Documents/SKILL.md", title: "Skill"),
        doc("Projects/Project_Parhelion/SKILL.md", title: "Skill"),
        doc("Documents/Codex/tracker_4d2f8a1b3c5e6d7f.md", title: "Static-99 Tracker"),
        doc("Lab/static99-epistemic-limits/tracker_4d2f8a1b3c5e6d7f.md", title: "Static-99 Tracker"),
        doc("Desktop/triage/cached/insights_0a1b2c3d4e5f6a7b.md", title: "Reddit Customer Insights"),
        doc("Projects/Project_Cassandra/research/insights_0a1b2c3d4e5f6a7b.md", title: "Reddit Customer Insights"),
    ], files: [])
    let (candidates, stats) = LauncherIndexAssembler.assemble(batch, home: home)
    let paths = Set(candidates.map(\.path))
    #expect(paths.contains("\(home)/Documents/SKILL.md") && paths.contains("\(home)/Projects/Project_Parhelion/SKILL.md"))
    #expect(paths.contains("\(home)/Lab/static99-epistemic-limits/tracker_4d2f8a1b3c5e6d7f.md"))
    #expect(!paths.contains("\(home)/Documents/Codex/tracker_4d2f8a1b3c5e6d7f.md"))
    #expect(paths.contains("\(home)/Projects/Project_Cassandra/research/insights_0a1b2c3d4e5f6a7b.md"))
    #expect(stats.docsWorktreeDropped == 2)
}

@Test func sameNamedFilesInOrdinaryFoldersAreDifferentFiles() {
    // Re-review: the file rule merged `Invoices` and `Invoices 2025` as if a worktree family.
    let batch = LauncherSourceBatch(apps: [], roots: [], docs: [], files: [
        file("Documents/Invoices/march.pdf"),
        file("Documents/Invoices 2025/march.pdf"),
        file("Desktop/Taxes/a.pdf"),
        file("Documents/Taxes-old/a.pdf"),
        file("Projects/Project_Helios/docs/deck.pdf"),
        file("Projects/Project_Helios_feat_x/docs/deck.pdf"),
    ])
    let (candidates, stats) = LauncherIndexAssembler.assemble(batch, home: home)
    #expect(candidates.count == 5)
    #expect(stats.filesWorktreeDropped == 1)
}

@Test func aStaleLaunchDoesNotMakeANearTieReady() {
    // C4: decay never reaches zero; a year-old launch must not count.
    let index = readyFixture()
    let strict = LauncherReadyRule(minimumFuzzy: LauncherReadyRule.seed.minimumFuzzy, minimumMargin: 0.99)
    let old = LauncherFrecency(entries: [
        LaunchLogEntry(timestamp: now.addingTimeInterval(-365 * 86_400), event: .launch, query: "om", candidateID: "\(home)/Lab/omni-intent", ready: false, top1Chosen: false, fellThrough: false),
    ])
    #expect(!index.query("omni", frecency: old, now: now, rule: strict).ready)
}

// MARK: - Ready rule

private func readyFixture() -> LauncherIndex {
    let old = now.addingTimeInterval(-400 * 86_400)
    return LauncherIndex(candidates: [
        app("Ghostty"),
        app("Sublime Text"),
        LauncherCandidate(title: "HQ Sidebar Tmux Ghostty Reference", path: "\(home)/Tooling/docs/hq-sidebar-tmux-ghostty-reference.md", kind: "reference", source: .docsIndex, modified: old),
        LauncherCandidate(title: "omni-intent", path: "\(home)/Lab/omni-intent", kind: "folder", source: .roots, modified: old),
        LauncherCandidate(title: "Omni Intent: Early Riff", path: "\(home)/Tooling/apps/omni-intent/docs/riff.md", kind: "note", source: .docsIndex, modified: old),
        LauncherCandidate(title: "Omni Intent Token Grammar", path: "\(home)/Tooling/apps/omni-intent/docs/grammar.md", kind: "spec", source: .docsIndex, modified: old),
    ])
}

@Test func readyRuleLightsForAClearSingleTargetAtTheSeededThresholds() throws {
    let results = readyFixture().query("sublime", now: now)
    let top = try #require(results.top)
    #expect(top.candidate.title == "Sublime Text")
    #expect(top.fuzzy >= LauncherReadyRule.seed.minimumFuzzy)
    #expect((results.margin ?? 0) >= LauncherReadyRule.seed.minimumMargin)
    #expect(results.ready)
}

@Test func readyRuleStaysDarkForAnAmbiguousQuery() throws {
    let results = readyFixture().query("omni intent", now: now)
    #expect(results.rows.count == 3)
    #expect(results.top?.fuzzy ?? 0 >= LauncherReadyRule.seed.minimumFuzzy)
    #expect((results.margin ?? 1) < LauncherReadyRule.seed.minimumMargin)
    #expect(!results.ready)
}

@Test func readyRuleBoundariesAreInclusiveAndTheMarginMatters() throws {
    let index = readyFixture()
    let baseline = index.query("omni intent", now: now)
    let margin = try #require(baseline.margin)
    let fuzzy = try #require(baseline.top?.fuzzy)
    #expect(index.query("omni intent", now: now, rule: LauncherReadyRule(minimumFuzzy: fuzzy, minimumMargin: margin)).ready)
    #expect(!index.query("omni intent", now: now, rule: LauncherReadyRule(minimumFuzzy: fuzzy + 0.001, minimumMargin: margin)).ready)
    #expect(!index.query("omni intent", now: now, rule: LauncherReadyRule(minimumFuzzy: fuzzy, minimumMargin: margin + 0.001)).ready)
}

@Test func anExactOrPrefixTitleMatchWithFrecencyIsReadyEvenWithoutMargin() throws {
    let index = readyFixture()
    // "omni" is a prefix of three titles: no margin, not ready on its own.
    let cold = index.query("omni", now: now)
    #expect(cold.rows.count == 3)
    #expect(!cold.ready)
    // One logged launch of the folder makes its prefix match ready.
    let frecency = LauncherFrecency(entries: [
        LaunchLogEntry(timestamp: now.addingTimeInterval(-3_600), event: .launch, query: "om", candidateID: "\(home)/Lab/omni-intent", ready: false, top1Chosen: false, fellThrough: false),
    ])
    // A margin threshold nothing can reach isolates the second clause.
    let strict = LauncherReadyRule(minimumFuzzy: LauncherReadyRule.seed.minimumFuzzy, minimumMargin: 0.99)
    let warm = index.query("omni", frecency: frecency, now: now, rule: strict)
    #expect(warm.top?.candidate.path == "\(home)/Lab/omni-intent")
    #expect(warm.ready)
    // Frecency without a title prefix match does not qualify.
    let inner = index.query("intent", frecency: frecency, now: now, rule: strict)
    #expect(inner.top?.candidate.path == "\(home)/Lab/omni-intent")
    #expect(!inner.ready)
}

@Test func oneCharacterQueriesAreFrecencyOrderedWordStartsAndNeverReady() {
    let index = readyFixture()
    let frecency = LauncherFrecency(entries: [
        LaunchLogEntry(timestamp: now, event: .launch, query: "sub", candidateID: "/Applications/Sublime Text.app", ready: true, top1Chosen: true, fellThrough: false),
    ])
    let results = index.query("s", frecency: frecency, now: now)
    #expect(results.rows.first?.candidate.title == "Sublime Text")
    #expect(results.rows.allSatisfy { $0.fuzzy == 0 })
    #expect(!results.ready)
    // "Sidebar" starts a word with s; "Ghostty" has an s mid-word only.
    #expect(results.rows.contains { $0.candidate.title.hasPrefix("HQ Sidebar") })
    #expect(!results.rows.contains { $0.candidate.title == "Ghostty" })
}

@Test func resultsAreCappedAtFifteenDistinctRows() {
    let candidates = (0..<40).map { LauncherCandidate(title: "report \($0)", path: "\(home)/Base/report-\($0).md", kind: "report", source: .docsIndex) }
    let results = LauncherIndex(candidates: candidates).query("report", now: now)
    #expect(results.rows.count == 15)
    #expect(Set(results.rows.map(\.id)).count == 15)
}

// MARK: - Launch log and frecency

@Test func launchLogEntriesRoundTripThroughTheirJSONLineWithSnakeCaseKeys() throws {
    let entry = LaunchLogEntry(
        timestamp: Date(timeIntervalSince1970: 1_790_000_000.123),
        event: .launch,
        query: "elev",
        candidateID: "\(home)/Lab/elevator-escape",
        path: "\(home)/Lab/elevator-escape",
        rank: 1,
        top1ID: "\(home)/Lab/elevator-escape",
        ready: true,
        top1Chosen: true,
        fellThrough: false,
        elapsedMilliseconds: 820,
        gesture: .open,
        selection: .ready,
        candidateCount: 7
    )
    let line = try entry.jsonLine()
    #expect(!line.contains("\n"))
    for key in ["\"schema_version\":2", "\"lane\":\"curated\"", "\"ts\":\"2026-", "\"event\":\"launch\"", "\"query\":\"elev\"", "\"candidate_id\":", "\"path\":", "\"rank\":1", "\"top1_id\":", "\"ready\":true", "\"top1_chosen\":true", "\"fell_through\":false", "\"elapsed_ms\":820", "\"gesture\":\"open\""] {
        #expect(line.contains(key), "missing \(key) in \(line)")
    }
    let decoded = try LaunchLogEntry.decode(line: line)
    #expect(decoded == entry)
    let fellThrough = LaunchLogEntry(timestamp: entry.timestamp, event: .fellThrough, query: "summarise the thread", top1ID: nil, ready: false, top1Chosen: false, fellThrough: true)
    #expect(try LaunchLogEntry.decode(line: try fellThrough.jsonLine()) == fellThrough)
    #expect(try fellThrough.jsonLine().contains("\"event\":\"fallthrough\""))
}

@Test func frecencyDecaysLearnsPrefixesAndForgetsUndoneLaunches() {
    let target = "\(home)/Lab/elevator-escape"
    let launch = { (age: TimeInterval, query: String) in
        LaunchLogEntry(timestamp: now.addingTimeInterval(-age), event: .launch, query: query, candidateID: target, ready: false, top1Chosen: false, fellThrough: false)
    }
    let fresh = LauncherFrecency(entries: [launch(0, "elev")])
    let stale = LauncherFrecency(entries: [launch(28 * 86_400, "elev")])
    #expect(abs(fresh.decayedCount(candidateID: target, now: now) - 1) < 1e-9)
    #expect(abs(stale.decayedCount(candidateID: target, now: now) - 0.25) < 1e-9)
    // The per-prefix association: `elev` learned this row; `lethe` did not.
    #expect(fresh.score(candidateID: target, foldedQuery: "eleva", now: now) > fresh.score(candidateID: target, foldedQuery: "lethe", now: now))
    #expect(fresh.score(candidateID: target, foldedQuery: "el", now: now) > fresh.score(candidateID: target, foldedQuery: "e", now: now))
    // A launch undone with ⌘Z teaches nothing.
    let undone = LauncherFrecency(entries: [
        launch(60, "elev"),
        LaunchLogEntry(timestamp: now.addingTimeInterval(-30), event: .undo, query: "elev", candidateID: target, ready: false, top1Chosen: false, fellThrough: false),
    ])
    #expect(undone.score(candidateID: target, foldedQuery: "elev", now: now) == 0)
    #expect(undone.isEmpty)
}

// MARK: - Latency

/// ~4k rows shaped like the spike's real index (155 apps, 177 folders,
/// ~2.5k docs rows, ~1.2k plain files).
func launcherLatencyFixture() -> [LauncherCandidate] {
    var generator = SplitMix64(seed: 0x5EED_4C41_554E_4348)
    let words = ["omni", "intent", "orbit", "spec", "helios", "cassandra", "lethe", "prereg", "elevator", "escape", "warm", "minimal",
                 "palette", "ghost", "states", "review", "report", "working", "memory", "handoff", "goal", "prompt", "study", "tracker",
                 "reality", "anchors", "mesapotamia", "paper", "draft", "benchmark", "camouflage", "retrieval", "index", "tagging",
                 "guidance", "filename", "conventions", "adr", "calibration", "lab", "neumann", "bessel", "market", "orientation", "primer",
                 "hutter", "prize", "rosetta", "compression", "latency", "simulation", "readiness", "boundary", "scheduler", "loop"]
    func pick() -> String { words[Int(generator.next() % UInt64(words.count))] }
    func title(_ count: Int) -> String { (0..<count).map { _ in pick().capitalized }.joined(separator: " ") }
    var candidates: [LauncherCandidate] = []
    for index in 0..<155 {
        candidates.append(LauncherCandidate(title: "\(title(1))\(index % 3 == 0 ? " \(title(1))" : "")", path: "/Applications/app-\(index).app", kind: "app", source: .apps))
    }
    for index in 0..<177 {
        candidates.append(LauncherCandidate(title: "\(pick())-\(pick())-\(index)", path: "\(home)/Lab/root-\(index)", kind: "folder", source: .roots))
    }
    let kinds = ["spec", "note", "adr", "report", "analysis", "review", "reference", "working-memory"]
    for index in 0..<2_506 {
        let text = title(3 + Int(generator.next() % 6))
        let slug = text.lowercased().replacingOccurrences(of: " ", with: "-")
        let path = "\(home)/Projects/p\(index % 40)/docs/\(slug)_\(String(format: "%016llx", generator.next())).md"
        let modified = now.addingTimeInterval(-Double(generator.next() % 400) * 86_400)
        candidates.append(LauncherCandidate(title: text, path: path, kind: kinds[index % kinds.count], source: .docsIndex, modified: modified))
    }
    for index in 0..<1_179 {
        let text = title(2 + Int(generator.next() % 3))
        let slug = text.lowercased().replacingOccurrences(of: " ", with: "_")
        candidates.append(LauncherCandidate(title: text, path: "\(home)/Lab/l\(index % 30)/out/\(slug)-\(index).pdf", kind: "pdf", source: .files))
    }
    return candidates
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

@Test(.timeLimit(.minutes(1)))
func perKeystrokeLatencyOnAFourThousandRowIndexStaysWithinBudget() {
    let candidates = launcherLatencyFixture()
    let buildStart = ContinuousClock.now
    let index = LauncherIndex(candidates: candidates)
    let buildMilliseconds = milliseconds(ContinuousClock.now - buildStart)
    let queries = ["elev", "orbit spec", "ghostty", "warm min", "omni intent", "lethe prereg", "tagging", "filename adr", "helios", "mesapotamia", "sublime", "email style"]
    var all: [Double] = []
    var short: [Double] = []
    var long: [Double] = []
    for query in queries {
        for length in 1...query.count {
            let prefix = String(query.prefix(length))
            let start = ContinuousClock.now
            _ = index.query(prefix, now: now)
            let elapsed = milliseconds(ContinuousClock.now - start)
            all.append(elapsed)
            if prefix.count <= 2 { short.append(elapsed) } else { long.append(elapsed) }
        }
    }
    func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
    }
    let report = String(
        format: "launcher latency (%d rows, index build %.1f ms): all p50 %.2f p95 %.2f max %.2f ms (n=%d) · ≤2 chars p50 %.2f p95 %.2f · ≥3 chars p50 %.2f p95 %.2f",
        candidates.count, buildMilliseconds, percentile(all, 0.5), percentile(all, 0.95), all.max() ?? 0, all.count,
        percentile(short, 0.5), percentile(short, 0.95), percentile(long, 0.5), percentile(long, 0.95)
    )
    print(report)
    #expect(candidates.count >= 4_000)
    #expect(percentile(all, 0.5) <= 25, "\(report)")
    #expect(percentile(long, 0.5) <= 25, "\(report)")
}
