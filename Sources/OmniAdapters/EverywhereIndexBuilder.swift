import Darwin
import Foundation
import OmniCore

/// W2's metadata-only full walk and narrow event-driven subtree scans.
public struct EverywhereIndexBuilder: EverywhereIndexBuilding {
    public let configuration: EverywhereSourceConfiguration
    private let clock: @Sendable () -> Date
    private let fullWalkPacing: EverywhereWalkPacing?

    public init(configuration: EverywhereSourceConfiguration, clock: @escaping @Sendable () -> Date = Date.init,
                fullWalkPacing: EverywhereWalkPacing? = nil) {
        self.configuration = configuration
        self.clock = clock
        self.fullWalkPacing = fullWalkPacing
    }

    public func currentDocsGeneration() -> String? {
        guard let jsonl = configuration.docsIndex, FileManager.default.fileExists(atPath: jsonl.path) else { return nil }
        return LauncherDocsIndexReader(jsonl: jsonl, meta: configuration.docsIndexMeta).generation()
    }

    public func build() throws -> EverywhereSnapshot {
        // Bind the generation to the start of the walk. If it changes during
        // 25 seconds of crawling, the service schedules one more walk rather
        // than declaring the mixed result current.
        let generation = currentDocsGeneration()
        let result = EverywhereCrawler(configuration: configuration).walk(pacing: fullWalkPacing)
        return EverywhereSnapshot(
            builtAt: clock(), docsGeneration: generation, lastEventID: nil,
            stats: result.stats, candidates: result.candidates
        )
    }

    public func patch(root: String) throws -> EverywhereIndexPatch {
        if root == configuration.home.path, homeHasOptOutMarker {
            return EverywhereIndexPatch(root: root, result: EverywhereWalkResult(candidates: [], stats: EverywhereWalkStats()), replaceDescendants: true)
        }
        let touchesDocsIndex = root == agentOutputRoot || root == configuration.home.appendingPathComponent("Tooling").path
        let generation = touchesDocsIndex ? currentDocsGeneration() : nil
        let result: EverywhereWalkResult
        if root == agentOutputRoot {
            result = EverywhereCrawler(configuration: configuration).agentOutputRows()
        } else if root == mobileDocumentsRoot {
            // The parent and Library can opt out every allowed container.
            // Scan the four explicit roots, never Library as a general tree.
            result = EverywhereCrawler(configuration: configuration).walk(roots: configuration.iCloudRoots)
        } else if root == configuration.home.appendingPathComponent("Tooling").path {
            let crawler = EverywhereCrawler(configuration: configuration)
            let ordinary = crawler.walk(roots: [URL(fileURLWithPath: root, isDirectory: true)])
            let agentOutput = crawler.agentOutputRows()
            var stats = ordinary.stats
            stats.visited += agentOutput.stats.visited
            for (key, count) in agentOutput.stats.rowsByArea { stats.rowsByArea[key, default: 0] += count }
            for (key, count) in agentOutput.stats.rowsBySource { stats.rowsBySource[key, default: 0] += count }
            stats.docsIndexRaw += agentOutput.stats.docsIndexRaw
            stats.docsIndexMissing += agentOutput.stats.docsIndexMissing
            result = EverywhereWalkResult(candidates: ordinary.candidates + agentOutput.candidates, stats: stats)
        } else {
            result = EverywhereCrawler(configuration: configuration).walk(roots: [URL(fileURLWithPath: root, isDirectory: true)])
        }
        return EverywhereIndexPatch(root: root, result: result, updatesDocsGeneration: touchesDocsIndex, docsGeneration: generation)
    }

    /// Resolve an event to the smallest directory whose replacement captures
    /// adds, removals, renames and opt-out markers. Source/build noise is
    /// ignored before it can make the service crawl a project unnecessarily.
    public func affectedRoot(for eventPath: String) -> String? {
        affectedRoot(for: eventPath, isDirectory: false)
    }

    public func affectedRoot(for eventPath: String, isDirectory directoryEvent: Bool) -> String? {
        let path = URL(fileURLWithPath: eventPath).standardizedFileURL.path
        let home = configuration.home.path
        let library = home + "/Library"
        if path == library || path == mobileDocumentsRoot ||
           [library + "/.nolaunch", library + "/.git", mobileDocumentsRoot + "/.nolaunch", mobileDocumentsRoot + "/.git"].contains(path) {
            return mobileDocumentsRoot
        }
        if path == agentOutputRoot { return agentOutputRoot }
        if path.hasPrefix(agentOutputRoot + "/") {
            let relative = path.dropFirst(agentOutputRoot.count + 1).split(separator: "/")
            guard relative.count == 1 || path.hasSuffix("/.nolaunch") || path.hasSuffix("/.git") else { return nil }
            return agentOutputRoot
        }

        let allowedICloud = configuration.iCloudRoots.map(\.path)
        let inICloud = allowedICloud.first { path == $0 || path.hasPrefix($0 + "/") }
        guard inICloud != nil || path == home || path.hasPrefix(home + "/") else { return nil }
        if inICloud == nil, path.hasPrefix(home + "/Library/") { return nil }

        // The leaf markers affect the containing directory; every other
        // hidden, source or excluded path cannot contribute a row.
        let leaf = (path as NSString).lastPathComponent
        let marker = leaf == ".nolaunch" || leaf == ".git"
        let anchor = inICloud ?? home
        let relative = path == anchor ? "" : String(path.dropFirst(anchor.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        if parts.dropLast().contains(where: { EverywhereScope.prunesDirectory($0) }) { return nil }
        if !marker, !parts.isEmpty, EverywhereScope.prunesDirectory(leaf) { return nil }
        if !marker, !parts.isEmpty {
            var info = stat()
            let exists = lstat(path, &info) == 0
            let isDirectory = exists && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            if !(directoryEvent || isDirectory) {
                // A missing extensionless path may be a deleted directory;
                // a regular extensionless file cannot have been a crawler row.
                if exists && (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG) { return nil }
                if exists || !EverywhereScope.extensionOf(leaf).isEmpty {
                    let area: EverywhereScope.Area
                    if inICloud != nil { area = .iCloud }
                    else if parts.count == 1 { area = .homeRoot }
                    else { area = .topLevel(parts[0]) }
                    guard EverywhereScope.fileClass(
                        name: leaf, area: area,
                        downloadsMediaEnabled: configuration.downloadsMediaEnabled
                    ) != nil else { return nil }
                }
            }
        }

        // Check physical ancestors closest first. The containing directory
        // of a marker must be scanned even when that very marker excludes it.
        // A deep path beyond the cap is left relevant, so uncertainty causes
        // an extra scan rather than a missed update.
        if path != home {
            let crawler = EverywhereCrawler(configuration: configuration)
            var ancestor = URL(fileURLWithPath: path).deletingLastPathComponent()
            if marker { ancestor.deleteLastPathComponent() }
            var checked = 0
            while ancestor.path == home || ancestor.path.hasPrefix(home + "/") {
                if checked == 32 { break }
                if crawler.excludesDirectory(ancestor) { return nil }
                if ancestor.path == home { break }
                ancestor.deleteLastPathComponent()
                checked += 1
            }
        }

        if let inICloud { return inICloud }
        if path == home { return home }
        guard let first = parts.first else { return home }
        if marker, parts.count == 1 { return home }
        if marker, parts.count == 2, ["Projects", "Lab", "Tooling"].contains(first) {
            return home + "/" + first
        }
        if parts.count == 1 {
            // A top-level directory is its own partition; a loose file is
            // handled by home's selected loose-files-only walk.
            var isDirectory = ObjCBool(false)
            if directoryEvent || (FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue) { return path }
            return (leaf as NSString).pathExtension.isEmpty ? path : home
        }
        if ["Projects", "Lab", "Tooling"].contains(first), parts.count >= 2 {
            return home + "/" + first + "/" + parts[1]
        }
        return home + "/" + first
    }

    private var agentOutputRoot: String { configuration.home.appendingPathComponent("Tooling/agent-output").path }
    private var mobileDocumentsRoot: String { configuration.home.appendingPathComponent("Library/Mobile Documents").path }

    private var homeHasOptOutMarker: Bool {
        let home = configuration.home
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".nolaunch").path) { return true }
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(".git").path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
