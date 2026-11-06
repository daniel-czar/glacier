import Foundation

// The file-finder fast lane (H10; decisions C50–C52; handoff
// `docs/intent-extension/omni-intent-file-finder_2ba3b06ed1db135d.md`).
// Everything in this file is pure: no filesystem, no network, no clock.

/// Where a launcher candidate came from (handoff §3). The two index sources
/// are the retrieval docs index (keyed by frontmatter title, kind, tags) and
/// the filesystem crawl (apps, launchable roots, document trees).
public enum LauncherSource: String, Codable, Sendable, Equatable, CaseIterable {
    case apps
    case roots
    case docsIndex = "docs-index"
    case files
}

/// One thing Daniel opens by name. `id` is the canonical absolute path, so a
/// file is one row no matter which source found it (the precedence rule).
public struct LauncherCandidate: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Canonical absolute path (see `LauncherPaths` in the adapters).
    public let path: String
    /// `app`, `folder`, a frontmatter kind (`spec`, `note`, …) or a file
    /// extension (`pdf`, `md`, …).
    public let kind: String
    public let source: LauncherSource
    public let modified: Date?
    public let added: Date?
    public let tags: [String]
    /// A folder row's summary line: the title of the README it absorbed.
    public let summary: String?
    /// The docs index row's `frontmatter.id` (16 lowercase hex), the key of
    /// the exact-id lane (D1). Optional and decoded if present, so snapshots
    /// written before it existed still load (they are rebuilt once).
    public let documentID: String?

    public init(
        title: String,
        path: String,
        kind: String,
        source: LauncherSource,
        modified: Date? = nil,
        added: Date? = nil,
        tags: [String] = [],
        summary: String? = nil,
        documentID: String? = nil
    ) {
        id = path
        self.title = title
        self.path = path
        self.kind = kind
        self.source = source
        self.modified = modified
        self.added = added
        self.tags = tags
        self.summary = summary
        self.documentID = documentID.flatMap { OmniIDAddress.isExactID($0) ? $0 : nil }
    }

    public func withSummary(_ summary: String?) -> LauncherCandidate {
        LauncherCandidate(title: title, path: path, kind: kind, source: source, modified: modified, added: added, tags: tags, summary: summary, documentID: documentID)
    }

    public var basename: String { (path as NSString).lastPathComponent }
}

/// Kind priority (handoff §4): app, folder, knowledge kinds, reports, plain
/// files. The spread is deliberately modest (0.4…1.0 at weight 0.10) so kind
/// can order near-ties but cannot manufacture a ready margin on its own.
public enum LauncherKindClass: Int, Sendable, Equatable, CaseIterable {
    case app
    case folder
    case knowledge
    case other
    case report
    case file

    public static let knowledgeKinds: Set<String> = [
        "adr", "note", "spec", "readme", "reference", "index", "architecture", "knowledge", "kb",
        "runbook", "policy", "protocol", "essay", "primer", "guide", "meta", "design-doc", "rfc",
        "style_guide", "blueprint", "instructions", "template", "checklist", "proposal", "concept",
        "architecture_note", "design", "design-brief", "design-kit", "tracker", "strategy-memo", "research-note",
    ]
    public static let reportKinds: Set<String> = [
        "report", "analysis", "review", "retro", "plan", "handoff", "handover", "working-memory", "log",
        "changelog", "decision-packet", "goal-prompt", "impl", "research-report", "conversation",
        "ledger-entry", "review-disposition", "reviewer-note", "finding", "receipt", "audit", "prompt",
    ]
    public static let fileKinds: Set<String> = [
        "pdf", "typ", "sketch", "key", "pages", "numbers", "docx", "xlsx", "pptx", "doc", "xls", "ppt", "md",
    ]

    public static func of(_ candidate: LauncherCandidate) -> LauncherKindClass {
        switch candidate.source {
        case .apps: return .app
        case .roots: return .folder
        case .files: return .file
        case .docsIndex:
            let kind = candidate.kind.lowercased()
            if knowledgeKinds.contains(kind) { return .knowledge }
            if reportKinds.contains(kind) { return .report }
            return .other
        }
    }

    /// 0…1 component for the blend.
    public var priority: Double {
        switch self {
        case .app: 1.0
        case .folder: 0.9
        case .knowledge: 0.7
        case .other: 0.6
        case .report: 0.5
        case .file: 0.4
        }
    }
}

/// Lexical path rules shared by the index assembler and the open-time check
/// (handoff §3). Paths must already be canonical; nothing here touches disk.
public enum LauncherPathRules {
    /// Build, dependency and VCS trees the crawl prunes and docs rows may not
    /// come from.
    public static let prunedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".venv", "venv", "target", ".build", "DerivedData", "site-packages", "agent-output",
    ]
    /// Test and archive trees (the spike found a fixture out-ranking real
    /// targets); matched case-insensitively on directory components.
    public static let excludedDirectoryNames: Set<String> = ["tests", "fixtures", "examples", "archive"]
    /// The marker file that stops the crawl descending into a directory.
    public static let noLaunchMarker = ".nolaunch"

    /// Whether a directory with this name is pruned from the crawl.
    public static func prunesDirectory(named name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        if name.lowercased().hasSuffix(".app") { return true }
        if prunedDirectoryNames.contains(name) { return true }
        return excludedDirectoryNames.contains(name.lowercased())
    }

    /// Whether a document or file row at `path` is excluded (handoff §3):
    /// anything in `~/Downloads`, under `agent-output`, a pruned tree, a
    /// hidden directory, an app bundle, or a tests/fixtures/examples/archive
    /// directory. The file's own name is not a directory component.
    public static func excludesDocument(atPath path: String, home: String) -> Bool {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home + "/Downloads" || path.hasPrefix(home + "/Downloads/") { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count > 1 else { return false }
        for directory in components.dropLast() where prunesDirectory(named: directory) {
            return true
        }
        return false
    }

    /// The top-level project directory used by the worktree rule: the second
    /// component below home (`Projects/Project_Cassandra/…` → `Project_Cassandra`).
    public static func topLevelDirectory(of path: String, home: String) -> (name: String, remainder: String) {
        var relative = path
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if relative.hasPrefix(prefix) { relative = String(relative.dropFirst(prefix.count)) }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.count >= 3 {
            return (components[1], components[2...].joined(separator: "/"))
        }
        return (components.first ?? relative, components.dropFirst().joined(separator: "/"))
    }

    /// `~/…` for display.
    public static func relativeToHome(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}

/// The row's words (handoff §6): subtitle = kind · path relative to home · age.
public enum LauncherRowText {
    public static func kindLabel(_ candidate: LauncherCandidate) -> String {
        switch candidate.source {
        case .apps: "app"
        case .roots: "folder"
        case .docsIndex, .files: candidate.kind.isEmpty ? "doc" : candidate.kind
        }
    }

    public static func subtitle(_ candidate: LauncherCandidate, home: String, now: Date) -> String {
        var parts = [kindLabel(candidate)]
        let parent = (candidate.path as NSString).deletingLastPathComponent
        parts.append(LauncherPathRules.relativeToHome(parent, home: home))
        if let summary = candidate.summary, !summary.isEmpty,
           summary.lowercased() != candidate.title.lowercased() {
            parts.append(summary)
        }
        if candidate.source != .apps, let date = candidate.modified ?? candidate.added {
            parts.append(age(from: date, now: now))
        }
        return parts.joined(separator: " · ")
    }

    public static func age(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let days = seconds / 86_400
        if days < 1 { return "today" }
        if days < 14 { return "\(Int(days))d" }
        if days < 60 { return "\(Int(days / 7))w" }
        if days < 730 { return "\(Int(days / 30))mo" }
        return "\(Int(days / 365))y"
    }
}
