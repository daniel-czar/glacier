import Darwin
import Foundation
import OmniCore

// Filesystem side of the file-finder fast lane (H10, C51): the crawl, the
// docs-index reader, the snapshot and launch-log stores, and the opener.
// Nothing here uses the network; Spotlight is not a dependency.

/// The one canonical-path function every comparison goes through: docs rows,
/// crawled files and the open-time check. Resolving symlinks (which also
/// folds `/private/var` onto `/var`) on both sides keeps "no absolute path
/// twice" true on the real index and on fixtures alike.
public enum LauncherPaths {
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The roots and bounds of one build (handoff §3).
public struct LauncherSourceConfiguration: Sendable, Equatable {
    public let home: URL
    public let appDirectories: [URL]
    /// Their immediate subdirectories are the launchable roots; their trees
    /// are crawled for plain document files.
    public let projectParents: [URL]
    /// Crawled whole for documents and Markdown.
    public let wholeTrees: [URL]
    public let docsIndex: URL?
    public let docsIndexMeta: URL?
    /// Depth cap under Projects, Lab and Tooling (agent-owned, seed 6).
    public let projectDepthCap: Int
    /// A safety bound for the whole trees.
    public let wholeTreeDepthCap: Int

    public init(
        home: URL,
        appDirectories: [URL],
        projectParents: [URL],
        wholeTrees: [URL],
        docsIndex: URL?,
        docsIndexMeta: URL?,
        projectDepthCap: Int = 6,
        wholeTreeDepthCap: Int = 16
    ) {
        self.home = home
        self.appDirectories = appDirectories
        self.projectParents = projectParents
        self.wholeTrees = wholeTrees
        self.docsIndex = docsIndex
        self.docsIndexMeta = docsIndexMeta
        self.projectDepthCap = projectDepthCap
        self.wholeTreeDepthCap = wholeTreeDepthCap
    }

    /// The launcher's single home-directory seam. Every root, the docs
    /// index, the opener's exclusion check and the row subtitles derive from
    /// the `home` of one configuration built once at startup; nothing else in
    /// the launcher asks the system for a home directory. When `OmniLayout`
    /// exposes a directory-service home lookup, this is the one line to point
    /// at it. Tests inject fixture homes through `standard(home:)` instead.
    public static func production() -> LauncherSourceConfiguration {
        standard(home: OmniLayout.homeDirectory)
    }

    /// Daniel's layout under `home`: apps, `~/Projects`, `~/Lab`, `~/Tooling`,
    /// whole `~/Base`, `~/Documents`, `~/Desktop`, `~/Tooling/office`, the
    /// four iCloud Drive containers, and the retrieval docs index.
    /// `~/Downloads` and `agent-output` are deliberately absent (C51).
    public static func standard(home: URL) -> LauncherSourceConfiguration {
        let index = home.appendingPathComponent("Tooling/retrieval/.index", isDirectory: true)
        let mobile = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let iCloud = ["com~apple~CloudDocs", "com~apple~Pages", "com~apple~Numbers", "com~apple~Keynote"]
            .map { mobile.appendingPathComponent($0, isDirectory: true) }
        return LauncherSourceConfiguration(
            home: home,
            appDirectories: ["/Applications", "/System/Applications", "/System/Applications/Utilities"].map { URL(fileURLWithPath: $0, isDirectory: true) },
            projectParents: ["Projects", "Lab", "Tooling"].map { home.appendingPathComponent($0, isDirectory: true) },
            wholeTrees: ["Base", "Documents", "Desktop", "Tooling/office"].map { home.appendingPathComponent($0, isDirectory: true) } + iCloud,
            docsIndex: index.appendingPathComponent("docs.jsonl"),
            docsIndexMeta: index.appendingPathComponent("docs.meta.json")
        )
    }

    public var homePath: String { LauncherPaths.canonical(home) }
}

/// Crawls apps, launchable roots and document trees. Pruning, the depth cap
/// and `.nolaunch` bound the walk (spike finding 4); every entry runs in an
/// `autoreleasepool` (spike finding 5: without it a multi-million-entry walk
/// retained hundreds of megabytes).
public struct LauncherCrawler: Sendable {
    /// PDF, Typst, Sketch, Keynote, Pages, Numbers, Office.
    public static let documentExtensions: Set<String> = ["pdf", "typ", "sketch", "key", "pages", "numbers", "docx", "xlsx", "pptx", "doc", "xls", "ppt"]

    public let configuration: LauncherSourceConfiguration

    public init(configuration: LauncherSourceConfiguration) {
        self.configuration = configuration
    }

    /// Bundles directly in each app directory, and one level into vendor
    /// folders (`/Applications/World of Warcraft/…app`).
    public func apps() -> [LauncherCandidate] {
        var result: [LauncherCandidate] = []
        let manager = FileManager.default
        let configured = Set(configuration.appDirectories.map { LauncherPaths.canonical($0) })
        var directories = configuration.appDirectories
        for directory in configuration.appDirectories {
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for url in entries where url.pathExtension.lowercased() != "app" {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDirectory, !configured.contains(LauncherPaths.canonical(url)) { directories.append(url) }
            }
        }
        for directory in directories {
            guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for url in entries where url.pathExtension.lowercased() == "app" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                result.append(LauncherCandidate(
                    title: url.deletingPathExtension().lastPathComponent,
                    path: LauncherPaths.canonical(url),
                    kind: "app",
                    source: .apps,
                    modified: values?.contentModificationDate
                ))
            }
        }
        return result
    }

    public func roots() -> [LauncherCandidate] {
        var result: [LauncherCandidate] = []
        let manager = FileManager.default
        for parent in configuration.projectParents {
            guard let entries = try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for url in entries {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values?.isDirectory == true, !LauncherPathRules.prunesDirectory(named: url.lastPathComponent) else { continue }
                result.append(LauncherCandidate(
                    title: url.lastPathComponent,
                    path: LauncherPaths.canonical(url),
                    kind: "folder",
                    source: .roots,
                    modified: values?.contentModificationDate
                ))
            }
        }
        return result
    }

    /// Plain document files under the project parents; documents and
    /// Markdown in the whole trees.
    public func files() -> [LauncherCandidate] {
        var unreadable: [String] = []
        return files(unreadable: &unreadable)
    }

    /// As `files()`, recording every configured root that exists but could
    /// not be read (a privacy denial must not look like an empty folder).
    public func files(unreadable: inout [String]) -> [LauncherCandidate] {
        var result: [LauncherCandidate] = []
        for tree in configuration.wholeTrees {
            walk(tree, depthCap: configuration.wholeTreeDepthCap, includeMarkdown: true, into: &result, unreadable: &unreadable)
        }
        for tree in configuration.projectParents {
            walk(tree, depthCap: configuration.projectDepthCap, includeMarkdown: false, into: &result, unreadable: &unreadable)
        }
        return result
    }

    private final class RootErrors: @unchecked Sendable {
        var rootFailed = false
    }

    private func walk(_ root: URL, depthCap: Int, includeMarkdown: Bool, into result: inout [LauncherCandidate], unreadable: inout [String]) {
        let manager = FileManager.default
        if iCloudAncestorsOptOut(root) { return }
        guard manager.fileExists(atPath: root.path) else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .addedToDirectoryDateKey]
        let rootPath = LauncherPaths.canonical(root)
        let errors = RootErrors()
        defer { if errors.rootFailed { unreadable.append(rootPath) } }
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in
            if LauncherPaths.canonical(url) == rootPath { errors.rootFailed = true }
            return true
        }) else {
            errors.rootFailed = true
            return
        }
        var visited = 0
        while let item = enumerator.nextObject() {
            visited += 1
            if visited % 2_048 == 0, Task.isCancelled { return }
            autoreleasepool {
                guard let url = item as? URL else { return }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                if values?.isDirectory == true {
                    // Keynote/Pages/Numbers documents may be packages.
                    if Self.documentExtensions.contains(ext) {
                        result.append(candidate(url, ext: ext, values: values, markdownTitle: nil))
                        enumerator.skipDescendants()
                    } else if LauncherPathRules.prunesDirectory(named: name)
                        || enumerator.level >= depthCap
                        || manager.fileExists(atPath: url.appendingPathComponent(LauncherPathRules.noLaunchMarker).path) {
                        enumerator.skipDescendants()
                    }
                    return
                }
                if Self.documentExtensions.contains(ext) {
                    result.append(candidate(url, ext: ext, values: values, markdownTitle: nil))
                } else if includeMarkdown, ext == "md" {
                    result.append(candidate(url, ext: ext, values: values, markdownTitle: Self.frontmatterTitle(url)))
                }
            }
        }
    }

    /// New C51 iCloud roots inherit `.nolaunch` and linked-worktree/package
    /// opt-outs from their physical ancestors. Legacy curated roots keep
    /// their existing scope and ranking behaviour.
    private func iCloudAncestorsOptOut(_ root: URL) -> Bool {
        let library = configuration.home.appendingPathComponent("Library", isDirectory: true)
        let mobile = library.appendingPathComponent("Mobile Documents", isDirectory: true)
        guard root.path.hasPrefix(mobile.path + "/") else { return false }
        for ancestor in [configuration.home, library, mobile, root] {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(LauncherPathRules.noLaunchMarker).path) { return true }
            var info = stat()
            if lstat(ancestor.appendingPathComponent(".git").path, &info) == 0,
               (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) { return true }
            if (try? ancestor.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
        }
        return false
    }

    private func candidate(_ url: URL, ext: String, values: URLResourceValues?, markdownTitle: String?) -> LauncherCandidate {
        LauncherCandidate(
            title: markdownTitle ?? url.deletingPathExtension().lastPathComponent,
            path: LauncherPaths.canonical(url),
            kind: ext,
            source: .files,
            modified: values?.contentModificationDate,
            added: values?.addedToDirectoryDate
        )
    }

    /// `title:` from a leading YAML frontmatter block, read from the first 8 KB.
    static func frontmatterTitle(_ url: URL) -> String? {
        // Accessing a dataless iCloud placeholder can trigger a download.
        // Metadata and filename remain indexable even when content is absent.
        if url.path.contains("/Library/Mobile Documents/") {
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            guard status == .current || status == .downloaded else { return nil }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8_192), let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst().prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard line.hasPrefix("title:") else { continue }
            var value = String(line.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last, (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Reads the retrieval docs index (`docs.jsonl`, schema fields
/// `absolute_path`, `title`, `kind`, `tags`, `created`, `updated`). Read-only;
/// the index itself is maintained by the daily Codex automation.
public struct LauncherDocsIndexReader: Sendable {
    public let jsonl: URL
    public let meta: URL?

    public init(jsonl: URL, meta: URL?) {
        self.jsonl = jsonl
        self.meta = meta
    }

    public func generation() -> String? {
        guard let meta,
              let data = try? Data(contentsOf: meta),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["generation_id"] as? String
    }

    /// Rows outside `agent-output` whose files still exist, canonicalised.
    public func rows() throws -> (rows: [LauncherDocsRow], raw: Int, missing: Int) {
        let data = try Data(contentsOf: jsonl)
        var rows: [LauncherDocsRow] = []
        var raw = 0
        var missing = 0
        let manager = FileManager.default
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            guard end > start else { continue }
            raw += 1
            autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any],
                      let absolute = object["absolute_path"] as? String,
                      !absolute.contains("/agent-output/")
                else { return }
                let path = LauncherPaths.canonical(absolute)
                guard manager.fileExists(atPath: path) else {
                    missing += 1
                    return
                }
                rows.append(LauncherDocsRow(
                    path: path,
                    title: object["title"] as? String,
                    kind: object["kind"] as? String,
                    tags: (object["tags"] as? [Any])?.compactMap { $0 as? String } ?? [],
                    created: Self.date(object["created"]),
                    updated: Self.date(object["updated"]),
                    documentID: Self.documentID(object)
                ))
            }
        }
        return (rows, raw, missing)
    }

    /// `frontmatter.id` when it is an exact 16-hex id (the exact-id lane, D1).
    public static func documentID(_ row: [String: Any]) -> String? {
        guard let id = (row["frontmatter"] as? [String: Any])?["id"] as? String, OmniIDAddress.isExactID(id) else { return nil }
        return id
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if text.count == 10 { return dayFormatter.date(from: text) }
        return timestampFormatter.date(from: text) ?? plainTimestampFormatter.date(from: text) ?? dayFormatter.date(from: String(text.prefix(10)))
    }

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// One build: crawl + docs index + the C51 rules.
public struct FileLauncherIndexBuilder: LauncherIndexBuilding {
    public let configuration: LauncherSourceConfiguration
    private let clock: @Sendable () -> Date

    public init(configuration: LauncherSourceConfiguration, clock: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration
        self.clock = clock
    }

    public func currentDocsGeneration() -> String? {
        guard let jsonl = configuration.docsIndex, FileManager.default.fileExists(atPath: jsonl.path) else { return nil }
        return LauncherDocsIndexReader(jsonl: jsonl, meta: configuration.docsIndexMeta).generation()
    }

    public func build() async throws -> LauncherSnapshot {
        let started = ContinuousClock.now
        let crawler = LauncherCrawler(configuration: configuration)
        let apps = crawler.apps()
        let roots = crawler.roots()
        try Task.checkCancellation()
        var docs: [LauncherDocsRow] = []
        var docsRaw = 0
        var docsMissing = 0
        var generation: String?
        if let jsonl = configuration.docsIndex, FileManager.default.fileExists(atPath: jsonl.path) {
            let reader = LauncherDocsIndexReader(jsonl: jsonl, meta: configuration.docsIndexMeta)
            generation = reader.generation()
            (docs, docsRaw, docsMissing) = try reader.rows()
        }
        try Task.checkCancellation()
        var unreadable: [String] = []
        let files = crawler.files(unreadable: &unreadable)
        try Task.checkCancellation()
        var (candidates, addressOnly, stats) = LauncherIndexAssembler.assembleWithAddresses(
            LauncherSourceBatch(apps: apps, roots: roots, docs: docs, files: files),
            home: configuration.homePath
        )
        stats.docsRaw = docsRaw
        stats.docsMissing = docsMissing
        stats.unreadableRoots = unreadable.isEmpty ? nil : unreadable
        candidates.sort { $0.path < $1.path }
        let elapsed = ContinuousClock.now - started
        let milliseconds = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return LauncherSnapshot(builtAt: clock(), docsGeneration: generation, buildMilliseconds: milliseconds, stats: stats, candidates: candidates, addressOnly: addressOnly.isEmpty ? nil : addressOnly)
    }
}

/// `<support>/launcher/index-snapshot.json`, replaced atomically.
public struct FileLauncherSnapshotStore: LauncherSnapshotStoring {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("index-snapshot.json")
    }

    public func load() throws -> LauncherSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(LauncherSnapshot.self, from: Data(contentsOf: url))
        return snapshot.schemaVersion == LauncherSnapshot.schemaVersion ? snapshot : nil
    }

    public func save(_ snapshot: LauncherSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(snapshot).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// `<support>/launcher/launch-log.jsonl`: one JSON line per launch,
/// fallthrough or undo. Local only; never leaves the machine.
public final class FileLaunchLog: LaunchLogging, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(directory: URL) {
        url = directory.appendingPathComponent("launch-log.jsonl")
    }

    public func append(_ entry: LaunchLogEntry) throws {
        let line = Data((try entry.jsonLine() + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // A torn last line (crash mid-write) must not swallow this entry too.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    /// Malformed lines are skipped: a torn write must not cost the history.
    public func readAll() throws -> [LaunchLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        return text.split(separator: "\n").compactMap { try? LaunchLogEntry.decode(line: String($0)) }
    }
}

/// Opens or reveals a candidate the published index produced (handoff §6).
///
/// A launch is a deterministic open (C4) and is not a run: the launcher is
/// not a command, so it creates no run, no receipt and no notification.
/// It is still safe by construction:
/// - the caller resolves the target by candidate id against the published
///   index only; a path typed in the pad never reaches this type;
/// - the path is re-canonicalised, the exclusions re-applied and existence
///   re-checked at open time;
/// - when a capability environment exists, its installed policy must grant
///   `openResolvedTarget` / `revealResolvedTarget`, the same operation
///   identities `/open` and `/rv` use;
/// - only non-network platform actions are used.
///
/// Files open in whatever application macOS assigns to their type; the
/// launcher keeps no per-type application table of its own.
public struct PlatformLauncherOpener: LauncherTargetOpening {
    private let platform: any PlatformActionPerforming
    private let allowedOperations: Set<OwnerOperation>?
    private let home: String
    private let lane: LauncherLane
    private let everywhereConfiguration: EverywhereSourceConfiguration

    public init(platform: any PlatformActionPerforming, allowedOperations: Set<OwnerOperation>?, home: URL, lane: LauncherLane = .curated, everywhereConfiguration: EverywhereSourceConfiguration? = nil) {
        self.platform = platform
        self.allowedOperations = allowedOperations
        self.home = LauncherPaths.canonical(home)
        self.lane = lane
        self.everywhereConfiguration = everywhereConfiguration ?? .standard(home: home)
    }

    public func open(_ candidate: LauncherCandidate, action: LauncherOpenAction) async throws -> String {
        if let allowedOperations, !allowedOperations.contains(action.operation) {
            throw LauncherError.operationNotAllowed(action.operation)
        }
        let path = LauncherPaths.canonical(candidate.path)
        guard path == candidate.path else { throw LauncherError.targetMoved(candidate.path) }
        if lane == .everywhere,
           !EverywhereTargetValidator(configuration: everywhereConfiguration).admits(candidate) {
            throw LauncherError.excludedTarget(path)
        }
        if lane == .curated, candidate.source == .docsIndex || candidate.source == .files,
           LauncherPathRules.excludesDocument(atPath: path, home: home) {
            throw LauncherError.excludedTarget(path)
        }
        guard FileManager.default.fileExists(atPath: path) else { throw LauncherError.missingTarget(path) }
        let url = URL(fileURLWithPath: path)
        let platformAction: PlatformAction
        switch action {
        case .reveal:
            platformAction = .revealFile(url)
        case .open:
            platformAction = .openFile(url)
        }
        return try await platform.perform(platformAction).identifier
    }
}
