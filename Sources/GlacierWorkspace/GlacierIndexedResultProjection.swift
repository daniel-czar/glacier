import OmniCore

/// Projects persisted `/find` rows through current source authority before
/// showing a picker or any path-derived copy text. Placeholders preserve row
/// indices, so an in-flight click cannot act on a different stored row.
public enum GlacierIndexedResultProjection {
    @MainActor
    public static func project(_ find: OmniFindResult, permits: @MainActor (String) -> Bool) -> OmniFindResult {
        let rows = find.rows.map { row in
            permits(row.path) ? row : OmniFindRow(path: "", title: "Source removed from this app",
                                                 kind: "unavailable", namespace: row.namespace)
        }
        return OmniFindResult(tier: find.tier, typed: find.typed, query: find.query,
                              modelOutput: find.modelOutput, rows: rows,
                              total: rows.count, exact: find.exact == 0 ? 0 : nil)
    }

    public static func safeText(_ find: OmniFindResult) -> String {
        find.rows.map { $0.path.isEmpty ? "Source removed from this app" : $0.path }
            .joined(separator: "\n")
    }
}
