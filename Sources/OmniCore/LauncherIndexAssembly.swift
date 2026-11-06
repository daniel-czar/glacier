import Foundation

/// One row of the retrieval docs index as the launcher reads it (schema
/// fields `absolute_path`, `title`, `kind`, `tags`, `created`, `updated`).
/// `path` must already be canonical.
public struct LauncherDocsRow: Sendable, Equatable {
    public let path: String
    public let title: String?
    public let kind: String?
    public let tags: [String]
    public let created: Date?
    public let updated: Date?
    /// `frontmatter.id`, when it is an exact 16-hex id (D1).
    public let documentID: String?

    public init(path: String, title: String?, kind: String?, tags: [String] = [], created: Date? = nil, updated: Date? = nil, documentID: String? = nil) {
        self.path = path
        self.title = title
        self.kind = kind
        self.tags = tags
        self.created = created
        self.updated = updated
        self.documentID = documentID
    }
}

/// Everything the sources produced for one build, before the rules run.
public struct LauncherSourceBatch: Sendable {
    public let apps: [LauncherCandidate]
    /// Immediate subdirectories of `~/Projects`, `~/Lab`, `~/Tooling`.
    public let roots: [LauncherCandidate]
    public let docs: [LauncherDocsRow]
    /// Crawled document files (whole `~/Base`, `~/Documents`, `~/Desktop`;
    /// plain document types under Projects, Lab, Tooling).
    public let files: [LauncherCandidate]

    public init(apps: [LauncherCandidate], roots: [LauncherCandidate], docs: [LauncherDocsRow], files: [LauncherCandidate]) {
        self.apps = apps
        self.roots = roots
        self.docs = docs
        self.files = files
    }
}

/// Counts for the receipt and the snapshot header.
public struct LauncherIndexStats: Codable, Sendable, Equatable {
    public var apps = 0
    public var folders = 0
    public var docs = 0
    public var files = 0
    public var docsRaw = 0
    /// Docs-index rows whose file no longer exists (the index is refreshed daily).
    public var docsMissing = 0
    public var docsExcluded = 0
    public var docsWorktreeDropped = 0
    public var filesExcluded = 0
    public var filesCoveredByDocs = 0
    public var filesWorktreeDropped = 0
    public var readmesAbsorbed = 0
    public var duplicatePathsDropped = 0
    /// Configured roots the crawl could not read (a privacy denial on
    /// `~/Documents` or `~/Desktop` would show here, not silently).
    public var unreadableRoots: [String]?

    public init() {}

    public var total: Int { apps + folders + docs + files }

    enum CodingKeys: String, CodingKey {
        case apps, folders, docs, files
        case docsRaw = "docs_raw"
        case docsMissing = "docs_missing"
        case docsExcluded = "docs_excluded"
        case docsWorktreeDropped = "docs_worktree_dropped"
        case filesExcluded = "files_excluded"
        case filesCoveredByDocs = "files_covered_by_docs"
        case filesWorktreeDropped = "files_worktree_dropped"
        case readmesAbsorbed = "readmes_absorbed"
        case duplicatePathsDropped = "duplicate_paths_dropped"
        case unreadableRoots = "unreadable_roots"
    }
}

/// The C51 rules as one pure function (handoff §3, spike findings 1–3):
///
/// - Exclusions apply to docs-index rows as well as crawled files
///   (`~/Downloads`, `agent-output`, build trees, tests/fixtures/examples/archive).
/// - Copies of one docs row collapse by (title, basename): worktree copies
///   (same path inside checkouts of one family, `Project_Cassandra` and
///   `Project_Cassandra_spl_*`), or anywhere when the filename carries a
///   16-hex id (the same document copied). Distinct files that merely share
///   a generic name (`SKILL.md`) stay distinct. The surviving copy is the
///   curated one: Projects/Lab/Tooling, then Base, then Documents, then
///   Desktop; within a family the shortest checkout name; then the most
///   recently updated; then the shortest path. Crawled files collapse only
///   within a worktree family, by (basename, path inside the checkout).
/// - The docs index wins by absolute path: the crawl contributes only files
///   the docs index does not know (including its dropped copies), so one
///   file is one row.
/// - A README directly inside a launchable root is not a candidate; its
///   title becomes the folder row's summary line.
public enum LauncherIndexAssembler {
    /// Widened lane candidate union. A duplicate path keeps the curated
    /// title, kind, tags and source; the walk's filesystem date-added drives
    /// C72 recency when available. Curated input candidates are never changed.
    public static func union(curated: [LauncherCandidate], everywhere: [LauncherCandidate]) -> [LauncherCandidate] {
        var result = curated
        var positionByPath: [String: Int] = [:]
        for (position, candidate) in curated.enumerated() where positionByPath[candidate.path] == nil {
            positionByPath[candidate.path] = position
        }
        for candidate in everywhere {
            if let position = positionByPath[candidate.path] {
                let preferred = result[position]
                result[position] = LauncherCandidate(
                    title: preferred.title,
                    path: preferred.path,
                    kind: preferred.kind,
                    source: preferred.source,
                    modified: preferred.modified,
                    added: candidate.added ?? preferred.added,
                    tags: preferred.tags,
                    summary: preferred.summary,
                    documentID: preferred.documentID ?? candidate.documentID
                )
            } else {
                positionByPath[candidate.path] = result.count
                result.append(candidate)
            }
        }
        return result
    }

    public static func assemble(_ batch: LauncherSourceBatch, home: String) -> (candidates: [LauncherCandidate], stats: LauncherIndexStats) {
        let assembled = assembleWithAddresses(batch, home: home)
        return (assembled.candidates, assembled.stats)
    }

    /// `assemble`, plus the docs rows absorbed into their folder rows (project
    /// READMEs). They are never scored or listed, but their ids stay
    /// addresses (D1): the exact-id lane opens the README itself.
    public static func assembleWithAddresses(_ batch: LauncherSourceBatch, home: String) -> (candidates: [LauncherCandidate], addressOnly: [LauncherCandidate], stats: LauncherIndexStats) {
        var stats = LauncherIndexStats()
        stats.docsRaw = batch.docs.count

        // Docs index rows: exclusions, then worktree dedup.
        var keptDocs: [LauncherDocsRow] = []
        for row in batch.docs {
            if LauncherPathRules.excludesDocument(atPath: row.path, home: home) {
                stats.docsExcluded += 1
            } else {
                keptDocs.append(row)
            }
        }
        struct DocKey: Hashable { let title: String; let basename: String }
        var docGroups: [DocKey: [LauncherDocsRow]] = [:]
        var docOrder: [DocKey] = []
        for row in keptDocs {
            let basename = (row.path as NSString).lastPathComponent
            let key = DocKey(title: docTitle(row), basename: basename)
            if docGroups[key] == nil { docOrder.append(key) }
            docGroups[key, default: []].append(row)
        }
        var docCandidates: [LauncherCandidate] = []
        let mergeSets = docOrder.flatMap { key in copySets(docGroups[key] ?? [], path: \.path, home: home, mergeAnywhere: hasHexIdentifier(key.basename)) }
        for group in mergeSets {
            let chosen = canonicalCopy(group, path: \.path, date: { $0.updated ?? $0.created }, home: home)
            stats.docsWorktreeDropped += group.count - 1
            docCandidates.append(LauncherCandidate(
                title: docTitle(chosen),
                path: chosen.path,
                kind: (chosen.kind?.isEmpty == false ? chosen.kind : nil) ?? "doc",
                source: .docsIndex,
                modified: chosen.updated ?? chosen.created,
                added: chosen.created,
                tags: chosen.tags,
                documentID: chosen.documentID
            ))
        }
        // Every docs row the rules kept, dedup losers included: a copy the
        // docs index dropped must not come back through the crawl.
        let docPaths = Set(keptDocs.map(\.path))

        // Crawled files: exclusions, docs precedence, then worktree dedup.
        struct FileKey: Hashable { let parent: String; let basename: String; let remainder: String }
        var fileGroups: [FileKey: [LauncherCandidate]] = [:]
        var fileOrder: [FileKey] = []
        for file in batch.files {
            if LauncherPathRules.excludesDocument(atPath: file.path, home: home) {
                stats.filesExcluded += 1
                continue
            }
            if docPaths.contains(file.path) {
                stats.filesCoveredByDocs += 1
                continue
            }
            let key = FileKey(parent: parentRoot(of: file.path, home: home), basename: file.basename, remainder: LauncherPathRules.topLevelDirectory(of: file.path, home: home).remainder)
            if fileGroups[key] == nil { fileOrder.append(key) }
            fileGroups[key, default: []].append(file)
        }
        var fileCandidates: [LauncherCandidate] = []
        for key in fileOrder {
            let group = fileGroups[key] ?? []
            // Only worktree copies collapse: checkouts of one family under
            // Projects, Lab or Tooling. Folders elsewhere (`Invoices` and
            // `Invoices 2025` in ~/Documents) are different files.
            let checkouts = Set(group.map { LauncherPathRules.topLevelDirectory(of: $0.path, home: home).name })
            if group.count > 1, ["Projects", "Lab", "Tooling"].contains(key.parent), checkouts.count == group.count, isWorktreeFamily(checkouts) {
                fileCandidates.append(canonicalCopy(group, path: \.path, date: { $0.modified }, home: home))
                stats.filesWorktreeDropped += group.count - 1
            } else {
                fileCandidates.append(contentsOf: group)
            }
        }

        // README absorption for launchable roots.
        var readmeTitles: [String: String] = [:]
        var absorbed: Set<String> = []
        let rootPaths = Set(batch.roots.map(\.path))
        for candidate in docCandidates + fileCandidates where candidate.basename.lowercased() == "readme.md" {
            let parent = (candidate.path as NSString).deletingLastPathComponent
            guard rootPaths.contains(parent) else { continue }
            absorbed.insert(candidate.path)
            if readmeTitles[parent] == nil, candidate.title.lowercased() != "readme" { readmeTitles[parent] = candidate.title }
        }
        stats.readmesAbsorbed = absorbed.count
        let roots = batch.roots.map { root in root.withSummary(readmeTitles[root.path]) }

        // Final: one row per absolute path, precedence apps > roots > docs > files.
        var seen: Set<String> = []
        var result: [LauncherCandidate] = []
        func admit(_ candidate: LauncherCandidate) -> Bool {
            guard !absorbed.contains(candidate.path) else { return false }
            guard seen.insert(candidate.path).inserted else {
                stats.duplicatePathsDropped += 1
                return false
            }
            result.append(candidate)
            return true
        }
        for app in batch.apps where admit(app) { stats.apps += 1 }
        for root in roots where admit(root) { stats.folders += 1 }
        for doc in docCandidates where admit(doc) { stats.docs += 1 }
        for file in fileCandidates where admit(file) { stats.files += 1 }
        let addressOnly = docCandidates.filter { absorbed.contains($0.path) && $0.documentID != nil }
        return (result, addressOnly, stats)
    }

    static func docTitle(_ row: LauncherDocsRow) -> String {
        if let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return ((row.path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Checkout names like `Project_Cassandra` and `Project_Cassandra_spl_x`:
    /// every name extends the shortest one.
    static func isWorktreeFamily(_ names: Set<String>) -> Bool {
        guard let shortest = names.min(by: { $0.count < $1.count }) else { return false }
        return names.allSatisfy { $0.hasPrefix(shortest) }
    }

    /// A 16-hex id in the filename (`title_8bc815e208fb0def.md`) names one
    /// document wherever it was copied.
    static func hasHexIdentifier(_ basename: String) -> Bool {
        let stem = (basename as NSString).deletingPathExtension
        var run = 0
        for scalar in stem.unicodeScalars {
            if ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) {
                run += 1
                if run >= 16 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// Splits one (title, basename) group into sets that may merge: the whole
    /// group when the name carries an id, else copies at the same path inside
    /// checkouts of one worktree family.
    static func copySets<Row>(_ rows: [Row], path: KeyPath<Row, String>, home: String, mergeAnywhere: Bool) -> [[Row]] {
        guard rows.count > 1, !mergeAnywhere else { return rows.isEmpty ? [] : [rows] }
        var sets: [(parent: String, checkout: String, remainder: String, rows: [Row])] = []
        // Shortest checkout name first, so each family's canonical name opens its set.
        let ordered = rows.sorted {
            LauncherPathRules.topLevelDirectory(of: $0[keyPath: path], home: home).name.count
                < LauncherPathRules.topLevelDirectory(of: $1[keyPath: path], home: home).name.count
        }
        for row in ordered {
            let (checkout, remainder) = LauncherPathRules.topLevelDirectory(of: row[keyPath: path], home: home)
            let parent = parentRoot(of: row[keyPath: path], home: home)
            if let index = sets.firstIndex(where: { $0.parent == parent && $0.remainder == remainder && checkout.hasPrefix($0.checkout) }) {
                sets[index].rows.append(row)
            } else {
                sets.append((parent, checkout, remainder, [row]))
            }
        }
        return sets.map(\.rows)
    }

    /// `Projects`, `Lab`, `Base`, … : the first component below home.
    static func parentRoot(of path: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return "" }
        return String(path.dropFirst(prefix.count).split(separator: "/").first ?? "")
    }

    /// Curated homes first, scratch last.
    static func rootRank(_ path: String, home: String) -> Int {
        switch parentRoot(of: path, home: home) {
        case "Projects", "Lab", "Tooling": 0
        case "Base": 1
        case "Documents": 2
        case "Desktop": 3
        default: 4
        }
    }

    /// The surviving copy: curated root, then (within one worktree family)
    /// the shortest checkout name, then the most recent, then the shortest
    /// path, then lexical order.
    static func canonicalCopy<Row>(_ rows: [Row], path: KeyPath<Row, String>, date: (Row) -> Date?, home: String) -> Row {
        let names = Set(rows.map { LauncherPathRules.topLevelDirectory(of: $0[keyPath: path], home: home).name })
        let family = isWorktreeFamily(names)
        return rows.min { lhs, rhs in
            let leftPath = lhs[keyPath: path], rightPath = rhs[keyPath: path]
            let leftRank = rootRank(leftPath, home: home), rightRank = rootRank(rightPath, home: home)
            if leftRank != rightRank { return leftRank < rightRank }
            if family {
                let left = LauncherPathRules.topLevelDirectory(of: leftPath, home: home).name
                let right = LauncherPathRules.topLevelDirectory(of: rightPath, home: home).name
                if left.count != right.count { return left.count < right.count }
            }
            let leftDate = date(lhs) ?? .distantPast, rightDate = date(rhs) ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            if leftPath.count != rightPath.count { return leftPath.count < rightPath.count }
            return leftPath < rightPath
        }!
    }
}
