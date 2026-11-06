import Foundation
@testable import OmniCore
import Testing

// `/find`'s grammar and its local executor (D2, decision surface
// 569d5a7cf925cbd7). The executor keeps `retrieve docs` filter semantics
// (`~/Tooling/retrieval/frontmatter.py`); each expectation below names the
// rule it pins.

@Test func keyValueWordsParseAsFiltersAndTheRestAsTerms() {
    let query = FindQuery(payload: "kind:review in:helios adversarial  ML run tags:ml")
    #expect(query.filters == [FindFilter(facet: .kind, value: "review"), FindFilter(facet: .project, value: "helios"), FindFilter(facet: .tags, value: "ml")])
    #expect(query.terms == ["adversarial", "ML", "run"])
    #expect(query.tier == .words)
    #expect(query.text == "kind:review in:helios tags:ml adversarial ML run")
    #expect(FindQuery(payload: "kind:review in:helios").tier == .filters)
    // An id alone is tier 1, in either case; beside other words it is
    // refused, never a term.
    #expect(FindQuery(payload: " doc:569d5a7cf925cbd7 ").tier == .id)
    #expect(FindQuery(payload: " doc:569d5a7cf925cbd7 ").text == "doc:569d5a7cf925cbd7")
    #expect(FindQuery(payload: "5C3059324FCBF75B").address?.id == "5c3059324fcbf75b", "an uppercase id is the same id")
    #expect(FindQuery(payload: "RUN:5C3059324FCBF75B").tier == .id)
    #expect(FindQuery(payload: "569d5a7cf925cbd7 kind:spec").refusal != nil)
    // An id pasted in backticks or quotes is still tier 1; an id as a filter
    // value, wrapped beside words, or behind punctuation is refused.
    #expect(FindQuery(payload: "`569d5a7cf925cbd7`").tier == .id)
    #expect(FindQuery(payload: "“doc:569d5a7cf925cbd7”.").address?.namespace == .doc)
    for payload in ["kind:569d5a7cf925cbd7 notes", "`569d5a7cf925cbd7` notes", "see (569D5A7CF925CBD7), please", "notes about report_569d5a7cf925cbd7.md"] {
        let query = FindQuery(payload: payload)
        #expect(query.refusal != nil && !query.asksModel, "\(payload)")
    }
    // A 17-hex word or an id inside a longer word is not an id.
    #expect(FindQuery(payload: "notes 0123456789abcdef0").refusal == nil)
    #expect(FindQuery(payload: "notes x0123456789abcdef").refusal == nil)
    #expect(FindQuery(payload: "569D5A7CF925CBD7 reviews").refusal != nil && !FindQuery(payload: "569D5A7CF925CBD7 reviews").asksModel)
    // Unknown keys, empty values and other case are words (`retrieve`'s keys
    // are case-sensitive; a bare `kind:` is not a filter here).
    #expect(FindQuery(payload: "Kind:review status:open kind: http://x").filters.isEmpty)
    #expect(FindQuery(payload: "").isEmpty)
    // Values may contain colons, as `retrieve` splits on the first one.
    #expect(FindFilter(word: "tags:a:b") == FindFilter(facet: .tags, value: "a:b"))
}

@Test func typedFiltersAreHardConstraintsOverATranslation() {
    let typed = FindQuery(payload: "kind:review adversarial reviews from helios")
    let translated = FindQuery(payload: "kind:report in:helios tags:adversarial ML")
    let merged = FindQuery.constrained(typed: typed, translated: translated)
    // The typed kind stays; the model's other kind is dropped, not ANDed.
    #expect(merged.filters == [FindFilter(facet: .kind, value: "review"), FindFilter(facet: .project, value: "helios"), FindFilter(facet: .tags, value: "adversarial")])
    #expect(merged.terms == ["ML"])
}

private func doc(_ name: String, kind: Any? = nil, projects: Any? = nil, tags: Any? = nil, title: String? = nil, summary: String = "") -> FindDocument {
    func strings(_ value: Any?) -> [String]? {
        switch value {
        case nil: nil
        case let list as [String]: list
        case let scalar as String: [scalar]
        default: nil
        }
    }
    return FindDocument(path: "/Users/fixture/\(name).md", title: title ?? name, kind: (kind as? String) ?? "", summary: summary, kindValues: strings(kind), projectValues: strings(projects), tagValues: strings(tags))
}

private let fixture = FindIndex(documents: [
    doc("a-review", kind: "review", projects: ["project_helios"], tags: ["ml", "adversarial-review"], summary: "Adversarial review of an ML run"),
    doc("b-report", kind: "report", projects: ["Project_Helios"], tags: ["ml"]),
    doc("c-notebook", kind: "notebook", projects: ["helios"], tags: ["data"]),
    doc("d-note", kind: "note", projects: ["project_cassandra"], tags: []),
    doc("e-nokind", projects: ["project_helios"], tags: ["review"]),
    doc("f-review", kind: "review", projects: [], tags: ["ML"], title: "Second review"),
])

private func paths(_ filters: String, terms: [String] = []) -> [String] {
    fixture.query(filters: FindQuery(payload: filters).filters, terms: terms).rows.map { ($0.path as NSString).lastPathComponent }
}

@Test func filtersMatchLikeRetrieveDocs() {
    // matches(): case-insensitive substring on the value.
    #expect(paths("kind:REVIEW") == ["a-review.md", "f-review.md"])
    #expect(paths("kind:note") == ["c-notebook.md", "d-note.md"], "substring: note matches notebook")
    // A list field matches when any item contains the value.
    #expect(paths("tags:ml") == ["a-review.md", "b-report.md", "f-review.md"])
    #expect(paths("tags:review") == ["a-review.md", "e-nokind.md"], "adversarial-review contains review")
    // Filters AND; a repeated key is two filters, not an OR.
    #expect(paths("kind:review tags:ml") == ["a-review.md", "f-review.md"])
    #expect(paths("tags:ml tags:adversarial") == ["a-review.md"])
    // A missing field or an empty list never matches.
    #expect(paths("kind:e") == ["a-review.md", "b-report.md", "c-notebook.md", "d-note.md", "f-review.md"], "e-nokind has no kind")
    #expect(!paths("tags:a").contains("d-note.md"))
}

@Test func inIsProjectsProjectPrefixLikeRetrieve() {
    // parse_filter_args: in:X → projects:project_X, case-insensitive match.
    #expect(paths("in:helios") == ["a-review.md", "b-report.md", "e-nokind.md"], "Project_Helios matches; bare helios does not")
    // An explicit project_ prefix is kept; the prefix test itself is case-sensitive.
    #expect(paths("in:project_cassandra") == ["d-note.md"])
    #expect(paths("in:Project_cassandra").isEmpty, "becomes project_Project_cassandra, as in retrieve")
    #expect(FindIndex.retrieveValue(FindFilter(facet: .project, value: "helios")) == "project_helios")
}

@Test func freeWordsMatchTitleAndSummaryAndRowsKeepIndexOrder() {
    #expect(paths("", terms: ["adversarial"]) == ["a-review.md"], "from the summary")
    #expect(paths("kind:review", terms: ["second"]) == ["f-review.md"], "from the title, ANDed with filters")
    #expect(paths("", terms: ["ml", "run"]) == ["a-review.md"], "every word must appear")
    let limited = fixture.query(filters: [FindFilter(facet: .tags, value: "ml")], terms: [], limit: 2)
    #expect(limited.rows.count == 2 && limited.total == 3)
    #expect(FindIndex.defaultLimit == 100, "retrieve docs --limit default")
}

@Test func aPluralTermAlsoFindsItsSingular() {
    #expect(paths("", terms: ["reviews"]) == ["a-review.md", "f-review.md"])
    #expect(FindIndex.termForms("Receipts") == ["receipts", "receipt"])
    #expect(FindIndex.termForms("queries") == ["queries", "query", "querie"])
    #expect(FindIndex.termForms("searches") == ["searches", "search", "searche"])
    #expect(FindIndex.termForms("class") == ["class"], "a double s is not a plural")
    #expect(FindIndex.termForms("status") == ["status"] && FindIndex.termForms("this") == ["this"])
    #expect(FindIndex.termForms("ids") == ["ids"], "too short to strip")
    // Filter values keep retrieve's plain substring test.
    #expect(paths("kind:reviews").isEmpty)
}

@Test func rankingKeepsHardFiltersAndReturnsTheClosestTierWhenNothingIsExact() {
    let review = FindFilter(facet: .kind, value: "review")
    // Exact rows are the strict answer, unchanged.
    let exact = fixture.rank(hard: [review], soft: [FindFilter(facet: .tags, value: "ml")], terms: [])
    #expect(exact.rows.map(\.path) == fixture.query(filters: [review, FindFilter(facet: .tags, value: "ml")], terms: []).rows.map(\.path))
    #expect(exact.exact == exact.total && exact.total == 2)
    // No reviewed row is tagged data and titled second: f-review has one of
    // the two; c-notebook has the tag but fails the hard kind:review.
    let closest = fixture.rank(hard: [review], soft: [FindFilter(facet: .tags, value: "data")], terms: ["second"])
    #expect(closest.rows.map { ($0.path as NSString).lastPathComponent } == ["f-review.md"])
    #expect(closest.exact == 0 && closest.total == 1)
    // Only the best-scoring tier comes back.
    let tier = fixture.rank(hard: [], soft: [FindFilter(facet: .tags, value: "ml"), FindFilter(facet: .project, value: "helios")], terms: ["adversarial", "second"])
    #expect(tier.rows.map { ($0.path as NSString).lastPathComponent } == ["a-review.md"])
    // Within the tier, a rarer satisfied part ranks first: tags:data (one
    // row) before in:helios (three), ahead of index order.
    let rare = fixture.rank(hard: [], soft: [FindFilter(facet: .project, value: "helios"), FindFilter(facet: .tags, value: "data")], terms: [])
    #expect(rare.rows.map { ($0.path as NSString).lastPathComponent } == ["c-notebook.md", "a-review.md", "b-report.md", "e-nokind.md"])
    #expect(rare.total == 4 && rare.exact == 0)
    // A row must satisfy at least one soft part; hard filters alone never
    // list rows as "closest".
    #expect(fixture.rank(hard: [review], soft: [], terms: ["zzz"]).total == 0)
}

@Test func aModelFilterIsPlacedOnTheFacetThatHoldsItsValue() {
    let facets = fixture.facets
    #expect(facets.placed(FindFilter(facet: .kind, value: "review")) == FindFilter(facet: .kind, value: "review"))
    #expect(facets.placed(FindFilter(facet: .kind, value: "ml")) == FindFilter(facet: .tags, value: "ml"))
    #expect(facets.placed(FindFilter(facet: .tags, value: "helios")) == FindFilter(facet: .project, value: "helios"))
    #expect(facets.placed(FindFilter(facet: .kind, value: "zzz")) == nil)
    // Case folds to the listed spelling; `in:project_x` is `in:x`.
    #expect(facets.placed(FindFilter(facet: .kind, value: "Review")) == FindFilter(facet: .kind, value: "review"))
    #expect(facets.placed(FindFilter(facet: .project, value: "project_helios")) == FindFilter(facet: .project, value: "helios"))
    #expect(facets.placed(FindFilter(facet: .tags, value: "Helios")) == FindFilter(facet: .project, value: "helios"))
}

@Test func pillsAreCompleteIndexKnownFiltersAfterTheFindToken() {
    let facets = fixture.facets
    let text = "kind:review /find kind:review in:helios kind:rev kind: status:open tags:ml words"
    let spans = FindFilterSpan.spans(in: text, facets: facets)
    #expect(spans.map(\.filter.text) == ["kind:review", "in:helios", "tags:ml"], "not before the token, not half-typed, not unknown")
    let source = text as NSString
    #expect(spans.map { source.substring(with: $0.range) } == ["kind:review", "in:helios", "tags:ml"])
    #expect(spans.map(\.keyLength) == [5, 3, 5])
    #expect(FindFilterSpan.spans(in: "/retrieve kind:note ", facets: facets).count == 1)
    #expect(FindFilterSpan.spans(in: "/email kind:review", facets: facets).isEmpty)
    #expect(FindFilterSpan.spans(in: "/find  é kind:review", facets: facets).first?.range == NSRange(location: 9, length: 11), "UTF-16 ranges")
    // A last word still being typed whose value begins a longer known value
    // waits for its space: kind:note on the way to kind:notebook.
    #expect(FindFilterSpan.spans(in: "/find kind:note", facets: facets).isEmpty)
    #expect(FindFilterSpan.spans(in: "/find kind:note ", facets: facets).count == 1)
    #expect(FindFilterSpan.spans(in: "/find kind:notebook", facets: facets).count == 1)
    #expect(FindFilterSpan.spans(in: "kind:review only", facets: facets).isEmpty, "no /find at all")
}

@Test func facetsOfferOnlyValuesThatFindRows() {
    let facets = fixture.facets
    #expect(facets.kinds.map(\.value) == ["review", "note", "notebook", "report"].sorted { lhs, rhs in
        let counts = ["review": 2, "note": 1, "notebook": 1, "report": 1]
        return counts[lhs]! != counts[rhs]! ? counts[lhs]! > counts[rhs]! : lhs < rhs
    })
    #expect(facets.kinds.first == FindFacetValue(value: "review", count: 2))
    // in: values only from project_-prefixed items, folded; counts are what
    // the filter returns (Project_Helios counts towards helios).
    #expect(facets.projects == [FindFacetValue(value: "helios", count: 3), FindFacetValue(value: "cassandra", count: 1)])
    for value in facets.projects { #expect(!paths("in:\(value.value)").isEmpty) }
    #expect(facets.tags.contains(FindFacetValue(value: "ml", count: 2)))
    #expect(facets.knows(FindFilter(facet: .kind, value: "review")))
    #expect(!facets.knows(FindFilter(facet: .kind, value: "revi")))
}

@Test func aFindResultReadsAsAPathListAndASummary() {
    let rows = [OmniFindRow(path: "/a.md", title: "A", kind: "review"), OmniFindRow(path: "/b", title: "B", kind: "run-folder", namespace: .run, id: "0123456789abcdef")]
    let result = OmniFindResult(tier: .filters, typed: "kind:review", query: "kind:review", rows: rows, total: 2)
    #expect(result.pathList == "/a.md\n/b")
    #expect(result.summary == "2 found · kind:review")
    #expect(!result.ranModel)
    #expect(OmniFindResult(tier: .words, typed: "x", query: "", modelOutput: "{}", rows: [], total: 0).summary == "No match")
    #expect(OmniFindResult(tier: .words, typed: "x", query: "kind:spec lane", rows: rows, total: 2, exact: 0).summary == "No exact match · 2 closest · kind:spec lane")
    #expect(OmniFindResult(tier: .words, typed: "x", query: "kind:spec lane", rows: [], total: 0, exact: 0).summary == "No match · kind:spec lane")
    #expect(OmniFindResult(tier: .words, typed: "x", query: "", rows: [], total: 0).ranModel)
}
