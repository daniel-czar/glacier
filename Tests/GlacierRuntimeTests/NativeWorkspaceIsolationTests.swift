import OmniCore
import Testing
import GlacierWorkspace

@MainActor
@Test func revokedFindRowsLosePathsWithoutChangingPickerIndices() {
    let find = OmniFindResult(
        tier: .filters, typed: "kind:note", query: "kind:note",
        rows: [
            OmniFindRow(path: "/allowed/one.md", title: "One", kind: "note"),
            OmniFindRow(path: "/revoked/private.md", title: "Private", kind: "note"),
            OmniFindRow(path: "/allowed/two.md", title: "Two", kind: "note")
        ], total: 3
    )
    let projected = GlacierIndexedResultProjection.project(find) { $0.hasPrefix("/allowed/") }
    #expect(projected.rows.count == 3)
    #expect(projected.rows[1].path.isEmpty)
    #expect(projected.rows[1].title == "Source removed from this app")
    #expect(projected.rows[2].path == "/allowed/two.md")
    let text = GlacierIndexedResultProjection.safeText(projected)
    #expect(!text.contains("/revoked/private.md"))
    #expect(text.contains("Source removed from this app"))
}
