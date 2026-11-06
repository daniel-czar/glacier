import Foundation
import OmniCore
import OmniRun

/// Editable composer state is UI state, separate from immutable run versions.
/// Range coordinates always belong to the text in the same record.
struct StoredFollowUpDraft: Codable, Sendable, Equatable {
    let runID: String
    let sourceVersion: Int
    let text: String
    let annotations: [OmniTextAnnotation]
}

struct FollowUpDraftDocument: Codable, Sendable {
    var version = 1
    var drafts: [StoredFollowUpDraft] = []
    var discardedRequestIDs: [String] = []
}

struct FollowUpDraftStore: Sendable {
    let configuration: GlacierWorkspaceConfiguration

    func load() throws -> FollowUpDraftDocument {
        let url = try documentURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return FollowUpDraftDocument() }
        let document = try JSONDecoder().decode(FollowUpDraftDocument.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return document
    }

    func save(_ document: FollowUpDraftDocument) throws {
        let url = try documentURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: documentURL(), options: .atomic)
    }

    private func documentURL() throws -> URL {
        let root = try OmniDevelopmentRoot(
            validating: configuration.developmentRoot,
            allowedRoot: configuration.allowedRoot,
            forbiddenRoots: configuration.forbiddenRoots
        )
        return try root.containedURL(relativePath: "ui/follow-up-drafts.json")
    }
}
