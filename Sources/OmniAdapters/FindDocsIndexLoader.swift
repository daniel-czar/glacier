import Foundation
import OmniCore

/// Reads the retrieval docs index (`~/Tooling/retrieval/.index/docs.jsonl`)
/// into `/find`'s in-process executor (D2). Read-only; it never refreshes the
/// index (index refresh stays `retrieve`'s, the only staleness story). The
/// parsed index is cached and re-read only when `docs.meta.json`'s
/// `generation_id` (or, without it, the file's size and date) changes.
public final class FindDocsIndexLoader: FindIndexProviding, @unchecked Sendable {
    public let docsIndex: URL
    public let meta: URL?
    private let lock = NSLock()
    private var cached: (key: String, index: FindIndex)?

    public init(docsIndex: URL, meta: URL? = nil) {
        self.docsIndex = docsIndex
        self.meta = meta
    }

    /// The docs index next to a `retrieve` checkout: the same reach the
    /// registered resolver already has (the runbook's `--no-registered-resolver`
    /// turns both off).
    public convenience init(retrievalRoot: URL) {
        let index = retrievalRoot.appendingPathComponent(".index", isDirectory: true)
        self.init(docsIndex: index.appendingPathComponent("docs.jsonl"), meta: index.appendingPathComponent("docs.meta.json"))
    }

    public func currentIndex() throws -> FindIndex {
        let key = try generationKey()
        if let cached = lock.withLock({ cached }), cached.key == key { return cached.index }
        let index = try load(generation: key)
        lock.withLock { cached = (key, index) }
        return index
    }

    public func cachedIndex() -> FindIndex? {
        lock.withLock { cached?.index }
    }

    private func generationKey() throws -> String {
        if let meta, let data = try? Data(contentsOf: meta),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let generation = object["generation_id"] as? String {
            return "generation:" + generation
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: docsIndex.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "file:\(size):\(date)"
    }

    private func load(generation: String) throws -> FindIndex {
        let data = try Data(contentsOf: docsIndex)
        var documents: [FindDocument] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            guard end > start else { continue }
            autoreleasepool {
                guard let row = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any],
                      let document = Self.document(row)
                else { return }
                documents.append(document)
            }
        }
        return FindIndex(documents: documents, generation: generation)
    }

    /// One row, or nil for rows `retrieve docs` would not consider (not
    /// Markdown, no path).
    static func document(_ row: [String: Any]) -> FindDocument? {
        guard let path = row["absolute_path"] as? String, !path.isEmpty else { return nil }
        // `filter_index_documents` keeps the default `--ext md` only,
        // comparing the lowercased extension (a row without one is out).
        guard (row["extension"] as? String)?.lowercased() == "md" else { return nil }
        // `document_matches_filters` reads the nested frontmatter, falling
        // back to the row itself when there is none.
        let frontmatter = row["frontmatter"] as? [String: Any] ?? row
        let title = (frontmatter["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let kindValues = pythonValues(frontmatter["kind"])
        return FindDocument(
            path: path,
            title: title,
            kind: (frontmatter["kind"] as? String) ?? "",
            documentID: (frontmatter["id"] as? String).flatMap { OmniIDAddress.isExactID($0) ? $0 : nil },
            summary: (frontmatter["summary"] as? String) ?? (row["summary"] as? String) ?? "",
            kindValues: kindValues,
            projectValues: pythonValues(frontmatter["projects"]),
            tagValues: pythonValues(frontmatter["tags"]),
            modified: LauncherDocsIndexReader.date(row["updated"]) ?? LauncherDocsIndexReader.date(row["created"]),
            // `is_private`: `str(visibility).lower() == "private"`.
            isPrivate: frontmatter["visibility"].flatMap(pythonString)?.lowercased() == "private"
        )
    }

    /// The strings `retrieve`'s `matches` compares against: `str(item)` for
    /// each list item, `str(value)` for a scalar, nothing for a missing or
    /// null field (which never matches).
    static func pythonValues(_ value: Any?) -> [String]? {
        guard let value, !(value is NSNull) else { return nil }
        if let list = value as? [Any] { return list.compactMap(pythonString) }
        return pythonString(value).map { [$0] }
    }

    static func pythonString(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case is NSNull:
            return "None"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "True" : "False" }
            if CFNumberIsFloatType(number) { return "\(number.doubleValue)" }
            return "\(number.int64Value)"
        default:
            return nil
        }
    }
}

extension OmniFindResult {
    /// Tier 1 (D2): the registered resolver's exact-id matches as picker rows.
    /// `retrieve` names a document by its file and a run by its folder.
    static func exactID(typed: String, entries: [ReplicaIndexEntry]) -> OmniFindResult {
        let rows = entries.map { entry in
            OmniFindRow(
                path: entry.path,
                title: entry.title,
                kind: entry.namespace == "run" ? "run-folder" : "doc",
                namespace: entry.namespace == "run" ? .run : .doc,
                id: entry.id
            )
        }
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return OmniFindResult(tier: .id, typed: query, query: query, rows: rows, total: rows.count)
    }
}
