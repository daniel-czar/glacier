import Foundation

// The local executor behind `/find` tiers 2 and 3 (D2, decision surface
// 569d5a7cf925cbd7). It answers from the retrieval docs index in process and
// keeps `retrieve docs <filters>` semantics exactly
// (`~/Tooling/retrieval/frontmatter.py` `parse_filter_args`, `matches`,
// `document_matches_filters`): every filter is a case-insensitive substring
// test against the row's frontmatter value (any item of a list), filters are
// ANDed, a missing or empty field never matches, `in:X` means
// `projects:project_X` (the prefix is added unless X already starts with
// `project_`, case-sensitively), only `md` rows count, rows keep the index's
// file order, and at most 100 are returned. Free words are this executor's
// own addition: each must appear in the title or the summary (a plural also
// as its singular). Tier 3 and local terms rank instead of failing empty:
// see `rank`.

/// One docs-index row as `/find` reads it.
public struct FindDocument: Sendable, Equatable {
    public let path: String
    public let title: String
    /// Frontmatter `kind` (empty when absent): the row label.
    public let kind: String
    public let documentID: String?
    public let summary: String
    /// String forms of the frontmatter fields the facets filter on, as
    /// `retrieve` sees them (`str(item)` of each list item, `str(value)` of a
    /// scalar); nil when the field is absent or null.
    public let kindValues: [String]?
    public let projectValues: [String]?
    public let tagValues: [String]?
    public let modified: Date?
    /// Frontmatter `visibility: private`. Such rows are found like any other
    /// (`retrieve docs` keeps them), but their facet values are never shown
    /// to a model.
    public let isPrivate: Bool

    public init(
        path: String,
        title: String,
        kind: String = "",
        documentID: String? = nil,
        summary: String = "",
        kindValues: [String]? = nil,
        projectValues: [String]? = nil,
        tagValues: [String]? = nil,
        modified: Date? = nil,
        isPrivate: Bool = false
    ) {
        self.path = path
        self.title = title
        self.kind = kind
        self.documentID = documentID
        self.summary = summary
        self.kindValues = kindValues ?? (kind.isEmpty ? nil : [kind])
        self.projectValues = projectValues
        self.tagValues = tagValues
        self.modified = modified
        self.isPrivate = isPrivate
    }

    func values(for facet: FindFacet) -> [String]? {
        switch facet {
        case .kind: kindValues
        case .project: projectValues
        case .tags: tagValues
        }
    }
}

/// One value a facet offers in the completion menu, with how many rows the
/// filter `facet:value` returns.
public struct FindFacetValue: Sendable, Equatable {
    public let value: String
    public let count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

/// The facet vocabulary: completion values in the pad and, for tier 3, the
/// only index-derived text the model is shown (D2). Never result rows.
public struct FindFacets: Sendable, Equatable {
    public let kinds: [FindFacetValue]
    public let projects: [FindFacetValue]
    public let tags: [FindFacetValue]

    public init(kinds: [FindFacetValue], projects: [FindFacetValue], tags: [FindFacetValue]) {
        self.kinds = kinds
        self.projects = projects
        self.tags = tags
    }

    public static let empty = FindFacets(kinds: [], projects: [], tags: [])

    public func values(for facet: FindFacet) -> [FindFacetValue] {
        switch facet {
        case .kind: kinds
        case .project: projects
        case .tags: tags
        }
    }

    /// Whether `facet:value` names a value the index knows: the rule for
    /// drawing a pill (D2, rendering only).
    public func knows(_ filter: FindFilter) -> Bool {
        values(for: filter.facet).contains { $0.value == filter.value }
    }

    /// A model-written filter on a facet that holds its value (D2, tier 3):
    /// as written when its own facet knows the value (case folded), else on
    /// the first facet (kind, in, tags) that does (`tags:runbook` becomes
    /// `kind:runbook` when only kinds hold it), else nil: a value no facet
    /// lists is dropped rather than guessed at.
    public func placed(_ filter: FindFilter) -> FindFilter? {
        if knows(filter) { return filter }
        // `kind:Review` is `kind:review`; `in:project_helios` is `in:helios`.
        var value = filter.value
        if filter.facet == .project, value.lowercased().hasPrefix("project_") { value = String(value.dropFirst("project_".count)) }
        func known(_ facet: FindFacet) -> FindFilter? {
            values(for: facet).first { $0.value.caseInsensitiveCompare(value) == .orderedSame }.map { FindFilter(facet: facet, value: $0.value) }
        }
        return known(filter.facet) ?? FindFacet.allCases.lazy.compactMap(known).first
    }
}

public struct FindIndex: Sendable {
    /// `retrieve docs`' default `--limit`.
    public static let defaultLimit = 100

    public let documents: [FindDocument]
    /// Every row's values: completion, pills and placing a model's filter.
    public let facets: FindFacets
    /// Values from rows not marked private: the only index-derived text a
    /// model is shown (tier 3).
    public let promptFacets: FindFacets
    /// The docs index generation the rows came from, when known.
    public let generation: String?

    public static let empty = FindIndex(documents: [], generation: nil)

    public init(documents: [FindDocument], generation: String? = nil) {
        self.documents = documents
        self.generation = generation
        facets = Self.facets(of: documents)
        promptFacets = documents.contains(where: \.isPrivate) ? Self.facets(of: documents.filter { !$0.isPrivate }) : facets
    }

    /// `retrieve docs` parity for filters, plus free-word matching on title
    /// and summary. Returns the matching rows in index order, capped, and the
    /// uncapped count.
    public func query(filters: [FindFilter], terms: [String], limit: Int = defaultLimit) -> (rows: [FindDocument], total: Int) {
        let forms = terms.map(Self.termForms)
        var rows: [FindDocument] = []
        var total = 0
        for document in documents where Self.matches(document, filters: filters) {
            guard Self.termScore(document, forms: forms) == forms.count else { continue }
            total += 1
            if limit <= 0 || rows.count < limit { rows.append(document) }
        }
        return (rows, total)
    }

    /// Tier 3 and local terms (D2). The typed filters are `hard`: every row
    /// satisfies all of them. The model's filters and the terms are soft.
    /// Rows that satisfy everything are the answer, exactly as `query`
    /// returns them. When none does, the closest rows are those that satisfy
    /// the most of the soft part (at least one of it); among them, rows whose
    /// satisfied parts are rarer under the hard filters come first (a rare
    /// `brochure` outranks a common `draft`), then index order. The query
    /// itself is never rewritten, so the route line still shows what ran.
    /// `exact` counts the rows that satisfied all of it.
    public func rank(hard: [FindFilter], soft: [FindFilter], terms: [String], limit: Int = defaultLimit) -> (rows: [FindDocument], total: Int, exact: Int) {
        let strict = query(filters: hard + soft, terms: terms, limit: limit)
        if strict.total > 0 || soft.isEmpty && terms.isEmpty { return (strict.rows, strict.total, strict.total) }
        let forms = terms.map(Self.termForms)
        // Which soft parts each row under the hard filters satisfies, and how
        // many rows satisfy each part.
        var pool: [(document: FindDocument, hits: [Bool])] = []
        var frequency = Array(repeating: 0, count: soft.count + forms.count)
        for document in documents where Self.matches(document, filters: hard) {
            let hits = soft.map { Self.matches(document, filters: [$0]) } + forms.map { Self.termMatches(document, forms: $0) }
            guard hits.contains(true) else { continue }
            for (part, hit) in hits.enumerated() where hit { frequency[part] += 1 }
            pool.append((document, hits))
        }
        let satisfied: ([Bool]) -> Int = { hits in hits.count(where: { $0 }) }
        let best = pool.map { satisfied($0.hits) }.max() ?? 0
        let size = Double(pool.count + 1)
        let weights: [Double] = frequency.map { log(size / (Double($0) + 0.5)) }
        var tier: [(order: Int, weight: Double, document: FindDocument)] = []
        for (order, entry) in pool.enumerated() where satisfied(entry.hits) == best {
            var weight = 0.0
            for (part, hit) in entry.hits.enumerated() where hit { weight += weights[part] }
            tier.append((order, weight, entry.document))
        }
        tier.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.order < $1.order }
        let rows = limit > 0 ? tier.prefix(limit) : tier[...]
        return (rows.map { $0.document }, tier.count, 0)
    }

    /// How many of the terms appear in the title or the summary.
    static func termScore(_ document: FindDocument, forms: [[String]]) -> Int {
        forms.count { termMatches(document, forms: $0) }
    }

    /// Whether one term (any of its forms) appears in the title or the summary.
    static func termMatches(_ document: FindDocument, forms: [String]) -> Bool {
        let title = document.title.lowercased()
        let summary = document.summary.lowercased()
        return forms.contains { title.contains($0) || summary.contains($0) }
    }

    /// A term, folded, and for a plural its singular (`receipts` finds
    /// `receipt`, `queries` finds `query`, `searches` finds `search`). Terms
    /// only: filter values keep `retrieve`'s plain substring test.
    static func termForms(_ term: String) -> [String] {
        let folded = term.lowercased()
        var forms = [folded]
        // Not `ss`, `us`, `is` (class, status, this): those are not plurals.
        guard folded.count > 3, folded.hasSuffix("s"), !["ss", "us", "is"].contains(where: folded.hasSuffix) else { return forms }
        if folded.hasSuffix("ies") {
            forms.append(String(folded.dropLast(3)) + "y")
        } else if ["ches", "shes", "xes", "sses"].contains(where: folded.hasSuffix) {
            forms.append(String(folded.dropLast(2)))
        }
        forms.append(String(folded.dropLast()))
        return forms
    }

    public func document(id: String) -> [FindDocument] {
        documents.filter { $0.documentID == id }
    }

    /// `frontmatter.matches`: the value, lowercased, is a substring of the
    /// field, lowercased, or of any item of a list field.
    public static func matches(_ document: FindDocument, filters: [FindFilter]) -> Bool {
        filters.allSatisfy { filter in
            guard let values = document.values(for: filter.facet), !values.isEmpty else { return false }
            let needle = retrieveValue(filter).lowercased()
            return values.contains { $0.lowercased().contains(needle) }
        }
    }

    /// `parse_filter_args`: `in:X` becomes `projects:project_X` unless X
    /// already starts with `project_` (case-sensitive, as in `retrieve`).
    public static func retrieveValue(_ filter: FindFilter) -> String {
        guard filter.facet == .project, !filter.value.hasPrefix("project_") else { return filter.value }
        return "project_" + filter.value
    }

    /// Kinds and tags with how many rows carry them; `in:` values only for
    /// `project_`-prefixed project items (the only ones `in:` can reach), with
    /// counts from running the filter, so every offered value finds a row.
    static func facets(of documents: [FindDocument]) -> FindFacets {
        var kinds: [String: Int] = [:]
        var tags: [String: Int] = [:]
        var projectNames: Set<String> = []
        var foldedProjects: [[String]] = []
        for document in documents {
            for kind in Set(document.kindValues ?? []) where !kind.isEmpty { kinds[kind, default: 0] += 1 }
            for tag in Set(document.tagValues ?? []) where !tag.isEmpty { tags[tag, default: 0] += 1 }
            guard let projects = document.projectValues, !projects.isEmpty else { continue }
            let folded = projects.map { $0.lowercased() }
            foldedProjects.append(folded)
            for project in folded where project.hasPrefix("project_") {
                let name = String(project.dropFirst("project_".count))
                if !name.isEmpty, !name.contains(where: \.isWhitespace) { projectNames.insert(name) }
            }
        }
        // The count is what `in:<name>` returns: a substring test, so
        // `in:helios` also counts `project_helios_archive`.
        let projects = projectNames.map { name in
            let needle = "project_" + name
            return FindFacetValue(value: name, count: foldedProjects.reduce(0) { $0 + ($1.contains { $0.contains(needle) } ? 1 : 0) })
        }
        func ranked(_ values: [FindFacetValue]) -> [FindFacetValue] {
            values.filter { $0.count > 0 && !$0.value.contains(where: \.isWhitespace) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
        }
        return FindFacets(
            kinds: ranked(kinds.map { FindFacetValue(value: $0.key, count: $0.value) }),
            projects: ranked(projects),
            tags: ranked(tags.map { FindFacetValue(value: $0.key, count: $0.value) })
        )
    }
}

/// Where `/find` gets its rows and facets. Implementations load the docs
/// index lazily and may reload it when its generation changes.
public protocol FindIndexProviding: Sendable {
    /// The current index, loading or reloading it when needed (may block).
    func currentIndex() throws -> FindIndex
    /// The last loaded index without blocking; nil before the first load.
    /// The pad's completion menu reads this on the main thread.
    func cachedIndex() -> FindIndex?
}

public struct StaticFindIndex: FindIndexProviding {
    public let index: FindIndex
    public init(_ index: FindIndex) { self.index = index }
    public func currentIndex() throws -> FindIndex { index }
    public func cachedIndex() -> FindIndex? { index }
}

// MARK: - The stored picker result

/// One row of a `/find` result as the receipt stores it. The picker's open,
/// reveal and copy-path act on these stored paths, never on editor text.
public struct OmniFindRow: Codable, Sendable, Equatable {
    public enum Namespace: String, Codable, Sendable {
        case doc
        case run
    }

    public let path: String
    public let title: String
    public let kind: String
    public let namespace: Namespace
    public let id: String?
    public let modified: Date?

    public init(path: String, title: String, kind: String, namespace: Namespace = .doc, id: String? = nil, modified: Date? = nil) {
        self.path = path
        self.title = title
        self.kind = kind
        self.namespace = namespace
        self.id = id
        self.modified = modified
    }
}

/// What a `/find` run asked, how it was answered, and the rows (D2). Stored
/// additively in the run context; older binaries ignore it and show the
/// path list in `fullText`.
public struct OmniFindResult: Codable, Sendable, Equatable {
    public enum Tier: String, Codable, Sendable {
        /// An exact id, resolved locally.
        case id
        /// Filters only, run locally.
        case filters
        /// Free words the model translated into a query (tier 3).
        case words
        /// Free words matched as plain title and summary terms, with no
        /// model: under `/offline`, or where no model tier is composed.
        case localTerms = "local-terms"
    }

    public let tier: Tier
    /// What the person typed after `/find`.
    public let typed: String
    /// The query the local executor ran, in the filter grammar.
    public let query: String
    /// Tier 3 only: the model's output exactly as received (a query, never rows).
    public let modelOutput: String?
    public let rows: [OmniFindRow]
    /// Matches before the cap.
    public let total: Int
    /// Tier 3 and local terms: how many rows satisfied all of `query`. Zero
    /// with rows means they are the closest ones (`FindIndex.rank`); nil for
    /// the strict tiers, where every row satisfies the query.
    public let exact: Int?

    public init(tier: Tier, typed: String, query: String, modelOutput: String? = nil, rows: [OmniFindRow], total: Int, exact: Int? = nil) {
        self.tier = tier
        self.typed = typed
        self.query = query
        self.modelOutput = modelOutput
        self.rows = rows
        self.total = total
        self.exact = exact
    }

    /// No row satisfied all of the query; the rows satisfy the most of it.
    public var isClosest: Bool { exact == 0 && total > 0 }

    /// `12 found`, `1 found`, `No match`, or `No exact match · 4 closest`.
    public var countLabel: String {
        if total == 0 { return "No match" }
        if isClosest { return "No exact match · \(total) closest" }
        return total == 1 ? "1 found" : "\(total) found"
    }

    /// Whether a model ran: only tier 3 asks one.
    public var ranModel: Bool { tier == .words }

    /// `retrieve docs`' plain output: one absolute path per line. This is
    /// `fullText`, what Copy and older binaries see.
    public var pathList: String { rows.map(\.path).joined(separator: "\n") }

    /// `12 found · kind:review in:helios`, or `No match · …`.
    public var summary: String {
        query.isEmpty ? countLabel : "\(countLabel) · \(query)"
    }
}
