import Darwin
import Foundation
#if canImport(OmniCore)
import OmniCore
#endif

public struct EverywhereFileDates: Sendable {
    public let modified: Date?
    public let added: Date?
    public let created: Date?

    public init(modified: Date?, added: Date?, created: Date?) {
        self.modified = modified
        self.added = added
        self.created = created
    }
}

/// Injectable metadata seam for package, placeholder and date-added fixtures.
public protocol EverywhereMetadataReading: Sendable {
    func isPackage(_ url: URL) -> Bool?
    func dates(_ url: URL) -> EverywhereFileDates
    func isFullyDownloaded(_ url: URL) -> Bool?
}

public struct FoundationEverywhereMetadataReader: EverywhereMetadataReading {
    public init() {}

    public func isPackage(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage
    }

    public func dates(_ url: URL) -> EverywhereFileDates {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
        return EverywhereFileDates(modified: values?.contentModificationDate, added: values?.addedToDirectoryDate, created: values?.creationDate)
    }

    public func isFullyDownloaded(_ url: URL) -> Bool? {
        guard let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus else { return nil }
        return status == .current || status == .downloaded
    }
}

public struct EverywhereSourceConfiguration: Sendable {
    public let home: URL
    public let iCloudRoots: [URL]
    public let docsIndex: URL?
    public let docsIndexMeta: URL?
    public let downloadsMediaEnabled: Bool
    public let massThreshold: Int

    public init(home: URL, iCloudRoots: [URL], docsIndex: URL?, docsIndexMeta: URL?, downloadsMediaEnabled: Bool = false, massThreshold: Int = EverywhereScope.massThreshold) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.iCloudRoots = iCloudRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.docsIndex = docsIndex
        self.docsIndexMeta = docsIndexMeta
        self.downloadsMediaEnabled = downloadsMediaEnabled
        self.massThreshold = massThreshold
    }

    public static func standard(home: URL) -> EverywhereSourceConfiguration {
        let mobile = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let index = home.appendingPathComponent("Tooling/retrieval/.index", isDirectory: true)
        return EverywhereSourceConfiguration(
            home: home,
            iCloudRoots: ["com~apple~CloudDocs", "com~apple~Pages", "com~apple~Numbers", "com~apple~Keynote"].map { mobile.appendingPathComponent($0, isDirectory: true) },
            docsIndex: index.appendingPathComponent("docs.jsonl"),
            docsIndexMeta: index.appendingPathComponent("docs.meta.json")
        )
    }

    /// These roots can be refreshed independently after an FSEvents signal.
    /// `home` means loose files only when passed to `walk(roots:)`.
    public var hotRoots: [URL] {
        [home.appendingPathComponent("Downloads", isDirectory: true),
         home.appendingPathComponent("Desktop", isDirectory: true), home] + iCloudRoots
    }
}

/// Metadata-only C72 traversal. POSIX directory streaming avoids allocating
/// URL arrays for large generated folders; metadata is fetched only for rows
/// or directory package checks. No symlink is followed.
public struct EverywhereCrawler: Sendable {
    public let configuration: EverywhereSourceConfiguration
    private let metadata: any EverywhereMetadataReading

    public init(configuration: EverywhereSourceConfiguration, metadata: any EverywhereMetadataReading = FoundationEverywhereMetadataReader()) {
        self.configuration = configuration
        self.metadata = metadata
    }

    private struct Directory {
        let url: URL
        let area: EverywhereScope.Area
        let isProtected: Bool
        let looseOnly: Bool
        let isHome: Bool
    }

    public func walk(roots: [URL]? = nil, pacing: EverywhereWalkPacing? = nil) -> EverywhereWalkResult {
        let pacer = pacing.map { EverywhereWalkPacer(policy: $0) }
        let home = configuration.home.path
        let selected = roots.map { Set($0.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }) }
        var stack: [Directory] = []
        let homeSelected = selected == nil || selected!.contains(home)
        if homeSelected {
            stack.append(Directory(url: configuration.home, area: .homeRoot, isProtected: true, looseOnly: selected != nil, isHome: true))
        }
        for root in configuration.iCloudRoots where (selected == nil || selected!.contains(root.path)) && iCloudRootIsEligible(root) {
            stack.append(Directory(url: root, area: .iCloud, isProtected: true, looseOnly: false, isHome: false))
        }
        if let selected {
            for name in ["Downloads", "Desktop", "Documents"] {
                let root = configuration.home.appendingPathComponent(name, isDirectory: true)
                if selected.contains(root.path), selectedRootIsEligible(root.path, anchor: home) {
                    stack.append(Directory(url: root, area: .topLevel(name), isProtected: true, looseOnly: false, isHome: false))
                }
            }
            let known = Set(stack.map { $0.url.path })
            let iCloudPaths = configuration.iCloudRoots.map(\.path)
            for path in selected where !known.contains(path) && path != home {
                let area: EverywhereScope.Area
                if let root = iCloudPaths.first(where: { path.hasPrefix($0 + "/") }) {
                    guard iCloudRootIsEligible(URL(fileURLWithPath: root, isDirectory: true)),
                          selectedRootIsEligible(path, anchor: root) else { continue }
                    area = .iCloud
                } else if path.hasPrefix(home + "/") {
                    let relative = String(path.dropFirst(home.count + 1))
                    let parts = relative.split(separator: "/").map(String.init)
                    guard let first = parts.first, first != "Library", first != "Tooling" || parts.dropFirst().first != "agent-output",
                          selectedRootIsEligible(path, anchor: home) else { continue }
                    if ["Projects", "Lab", "Tooling"].contains(first), parts.count >= 2 {
                        area = .other(first + "/" + parts[1])
                    } else {
                        area = .topLevel(first)
                    }
                } else { continue }
                stack.append(Directory(url: URL(fileURLWithPath: path, isDirectory: true), area: area, isProtected: false, looseOnly: false, isHome: false))
            }
        }

        var result: [LauncherCandidate] = []
        var stats = EverywhereWalkStats()
        let protected = Set([home, home + "/Downloads", home + "/Desktop", home + "/Documents", home + "/Base", home + "/Tooling/office"] + configuration.iCloudRoots.map(\.path))
        while let directory = stack.popLast() {
            if Task.isCancelled || pacer?.checkpoint(force: true) == true { break }
            autoreleasepool {
                let path = directory.url.path
                if hasNoLaunchMarker(directory.url) || hasLinkedWorktreeMarker(directory.url) || (!directory.isHome && isExcludedPackage(directory.url, allowDocumentPackage: false)) { return }
                guard let handle = opendir(path) else {
                    let failure = errno
                    if failure != ENOENT, failure != ENOTDIR { stats.unreadableRoots.append(path) }
                    return
                }
                var extensionCounts: [String: Int] = [:]
                var children: [Directory] = []
                var packageRows: [(url: URL, area: EverywhereScope.Area, category: String, ext: String)] = []
                while let entry = readdir(handle) {
                    if pacer?.checkpoint() == true { break }
                    let name = withUnsafePointer(to: entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    if name == "." || name == ".." { continue }
                    stats.visited += 1
                    if stats.visited % 2_048 == 0, Task.isCancelled { break }
                    let type = entry.pointee.d_type
                    if type == UInt8(DT_REG) {
                        if EverywhereScope.fileClass(name: name, area: directory.area, downloadsMediaEnabled: configuration.downloadsMediaEnabled) != nil {
                            extensionCounts[EverywhereScope.extensionOf(name), default: 0] += 1
                        }
                        continue
                    }
                    if type == UInt8(DT_LNK) { continue }
                    autoreleasepool {
                        let item = directory.url.appendingPathComponent(name)
                        let isDirectory: Bool
                        if type == UInt8(DT_DIR) { isDirectory = true }
                        else {
                            var info = stat()
                            guard lstat(item.path, &info) == 0 else { return }
                            if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) { return }
                            isDirectory = (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                        }
                        if isDirectory {
                            if directory.looseOnly || EverywhereScope.prunesDirectory(name) { return }
                            if directory.isHome && name == "Library" { return }
                            let childArea: EverywhereScope.Area
                            if directory.isHome {
                                childArea = .topLevel(name)
                            } else if [home + "/Projects", home + "/Lab", home + "/Tooling"].contains(path) {
                                childArea = .other(directory.url.lastPathComponent + "/" + name)
                            } else {
                                childArea = directory.area
                            }
                            let ext = item.pathExtension.lowercased()
                            if EverywhereScope.documentExtensions.contains(ext) {
                                if !hasNoLaunchMarker(item), !hasLinkedWorktreeMarker(item), !isExcludedPackage(item, allowDocumentPackage: true) {
                                    extensionCounts[ext, default: 0] += 1
                                    packageRows.append((item, childArea, "document", ext))
                                }
                                return
                            }
                            if EverywhereScope.revealExtensions.contains(ext) {
                                if !hasNoLaunchMarker(item), !hasLinkedWorktreeMarker(item) {
                                    extensionCounts[ext, default: 0] += 1
                                    packageRows.append((item, childArea, "reveal", ext))
                                }
                                return
                            }
                            if isExcludedPackage(item, allowDocumentPackage: false) || hasNoLaunchMarker(item) || hasLinkedWorktreeMarker(item) { return }
                            if item.path == home + "/Tooling/agent-output" { return }
                            children.append(Directory(url: item, area: childArea, isProtected: protected.contains(item.path), looseOnly: false, isHome: false))
                        } else if EverywhereScope.fileClass(name: name, area: directory.area, downloadsMediaEnabled: configuration.downloadsMediaEnabled) != nil {
                            // Counts are by direct *indexable* type; Downloads'
                            // disabled images cannot become a mass folder.
                            let ext = EverywhereScope.extensionOf(name)
                            extensionCounts[ext, default: 0] += 1
                        }
                    }
                }
                closedir(handle)
                if Task.isCancelled { return }
                let mass = !directory.isProtected && !protected.contains(path) ? extensionCounts.max(by: { $0.value < $1.value }) : nil
                if let mass, mass.value > configuration.massThreshold {
                    stats.collapsedFolders += 1
                    stats.collapsedDirectoryPaths.append(path)
                    let title = "\(directory.url.lastPathComponent) · \(mass.value.formatted()) \(mass.key)"
                    emit(candidate(directory.url, title: title, kind: "mass-folder", source: .roots), area: directory.area, category: "mass-folder", into: &result, stats: &stats)
                    return
                }
                for row in packageRows {
                    autoreleasepool {
                        emit(candidate(row.url, kind: row.ext, source: .files), area: row.area, category: row.category, into: &result, stats: &stats)
                    }
                }
                stack.append(contentsOf: children.reversed())
                guard let filesHandle = opendir(path) else { return }
                var fileEntries = 0
                while let entry = readdir(filesHandle) {
                    fileEntries += 1
                    if pacer?.checkpoint() == true || (fileEntries % 2_048 == 0 && Task.isCancelled) { break }
                    let name = withUnsafePointer(to: entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    guard name != ".", name != "..", entry.pointee.d_type != UInt8(DT_DIR), entry.pointee.d_type != UInt8(DT_LNK) else { continue }
                    guard let fileClass = EverywhereScope.fileClass(name: name, area: directory.area, downloadsMediaEnabled: configuration.downloadsMediaEnabled) else { continue }
                    autoreleasepool {
                        let item = directory.url.appendingPathComponent(name)
                        // Unknown d_type may be a symlink or package directory.
                        if entry.pointee.d_type != UInt8(DT_REG) {
                            var info = stat()
                            guard lstat(item.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return }
                        }
                        let category: String
                        switch fileClass {
                        case .document: category = "document"
                        case .plainText: category = "plain-text"
                        case .media: category = "media"
                        case .reveal: category = "reveal"
                        }
                        emit(candidate(item, kind: item.pathExtension.lowercased(), source: .files), area: directory.area, category: category, into: &result, stats: &stats)
                    }
                }
                closedir(filesHandle)
            }
        }
        if selected == nil, !Task.isCancelled {
            appendAgentOutput(into: &result, stats: &stats, pacer: pacer)
        }
        return EverywhereWalkResult(candidates: result, stats: stats)
    }

    /// Refreshes only the shallow run-folder census plus its docs-index rows.
    /// No file below agent-output is enumerated.
    public func agentOutputRows() -> EverywhereWalkResult {
        var result: [LauncherCandidate] = []
        var stats = EverywhereWalkStats()
        appendAgentOutput(into: &result, stats: &stats)
        return EverywhereWalkResult(candidates: result, stats: stats)
    }

    private func selectedRootIsEligible(_ path: String, anchor: String) -> Bool {
        guard path.hasPrefix(anchor + "/") else { return false }
        let anchorURL = URL(fileURLWithPath: anchor, isDirectory: true)
        guard !hasNoLaunchMarker(anchorURL), !hasLinkedWorktreeMarker(anchorURL),
              !isExcludedPackage(anchorURL, allowDocumentPackage: false) else { return false }
        let relative = String(path.dropFirst(anchor.count + 1))
        var cursor = anchorURL
        for name in relative.split(separator: "/").map(String.init) {
            if EverywhereScope.prunesDirectory(name) { return false }
            cursor.appendPathComponent(name, isDirectory: true)
            if hasNoLaunchMarker(cursor) || hasLinkedWorktreeMarker(cursor) || isExcludedPackage(cursor, allowDocumentPackage: false) { return false }
        }
        return true
    }

    /// The explicit Library exception still inherits physical ancestor opt-outs.
    /// This is four metadata checks per iCloud root, never per crawled entry.
    private func iCloudRootIsEligible(_ root: URL) -> Bool {
        let library = configuration.home.appendingPathComponent("Library", isDirectory: true)
        let mobile = library.appendingPathComponent("Mobile Documents", isDirectory: true)
        for ancestor in [configuration.home, library, mobile, root] {
            if hasNoLaunchMarker(ancestor) || hasLinkedWorktreeMarker(ancestor) || isExcludedPackage(ancestor, allowDocumentPackage: false) { return false }
        }
        return true
    }

    private func emit(_ row: LauncherCandidate, area: EverywhereScope.Area, category: String, into result: inout [LauncherCandidate], stats: inout EverywhereWalkStats) {
        result.append(row)
        stats.rowsByArea[area.label, default: 0] += 1
        stats.rowsBySource[category, default: 0] += 1
        if category == "document" || category == "plain-text" { stats.documentRowsOutsideAgentOutput += 1 }
    }

    private func candidate(_ url: URL, title: String? = nil, kind: String, source: LauncherSource, tags: [String] = [], documentID: String? = nil) -> LauncherCandidate {
        let dates = metadata.dates(url)
        let resolvedTitle: String
        if let title { resolvedTitle = title }
        else if kind == "md" || kind == "markdown" { resolvedTitle = safeMarkdownTitle(url) ?? url.deletingPathExtension().lastPathComponent }
        else { resolvedTitle = url.deletingPathExtension().lastPathComponent }
        return LauncherCandidate(
            title: resolvedTitle,
            path: url.standardizedFileURL.resolvingSymlinksInPath().path,
            kind: kind,
            source: source,
            modified: dates.modified,
            added: dates.added ?? dates.created,
            tags: tags,
            documentID: documentID
        )
    }

    private func safeMarkdownTitle(_ url: URL) -> String? {
        if url.path.contains("/Library/Mobile Documents/") {
            guard metadata.isFullyDownloaded(url) == true else { return nil }
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
            let value = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    private func isExcludedPackage(_ url: URL, allowDocumentPackage: Bool) -> Bool {
        if metadata.isPackage(url) == true { return !allowDocumentPackage }
        // Extension fallback covers filesystems that do not supply isPackage.
        let ext = url.pathExtension.lowercased()
        if ["app", "photoslibrary", "library", "xcodeproj", "xcworkspace", "framework", "bundle", "xcassets", "lproj"].contains(ext) { return true }
        return false
    }

    /// Keep event filtering in step with the directories the walk skips.
    /// This is deliberately uncached: a marker can appear or disappear between
    /// adjacent FSEvents callbacks.
    func excludesDirectory(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        // Document and reveal directories produce one package row. The walk
        // never descends into them, even when Foundation does not tag them as
        // packages on the current filesystem.
        return EverywhereScope.documentExtensions.contains(ext) || EverywhereScope.revealExtensions.contains(ext) ||
            hasNoLaunchMarker(url) || hasLinkedWorktreeMarker(url) || isExcludedPackage(url, allowDocumentPackage: false)
    }

    private func hasNoLaunchMarker(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(LauncherPathRules.noLaunchMarker).path)
    }

    private func hasLinkedWorktreeMarker(_ url: URL) -> Bool {
        var info = stat()
        let marker = url.appendingPathComponent(".git").path
        return lstat(marker, &info) == 0 && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private func appendAgentOutput(into result: inout [LauncherCandidate], stats: inout EverywhereWalkStats,
                                   pacer: EverywhereWalkPacer? = nil) {
        let root = configuration.home.appendingPathComponent("Tooling/agent-output", isDirectory: true)
        let tooling = configuration.home.appendingPathComponent("Tooling", isDirectory: true)
        for ancestor in [configuration.home, tooling, root] {
            if hasNoLaunchMarker(ancestor) || hasLinkedWorktreeMarker(ancestor) || isExcludedPackage(ancestor, allowDocumentPackage: false) { return }
        }
        guard let handle = opendir(root.path) else {
            let failure = errno
            if failure != ENOENT, failure != ENOTDIR { stats.unreadableRoots.append(root.path) }
            return
        }
        var validRuns: Set<String> = []
        while let entry = readdir(handle) {
            if pacer?.checkpoint() == true || (stats.visited % 2_048 == 0 && Task.isCancelled) { break }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            stats.visited += 1
            guard EverywhereScope.isRunFolder(name) else { continue }
            let url = root.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), !hasNoLaunchMarker(url), !hasLinkedWorktreeMarker(url) else { continue }
            validRuns.insert(name)
            emit(candidate(url, title: name, kind: "run-folder", source: .roots), area: .other("agent-output"), category: "run-folder", into: &result, stats: &stats)
        }
        closedir(handle)
        if Task.isCancelled { return }
        guard let index = configuration.docsIndex, let data = try? Data(contentsOf: index) else { return }
        let prefix = root.path + "/"
        var start = data.startIndex
        var ancestryCache: [String: Bool] = [:]
        while start < data.endIndex {
            if pacer?.checkpoint() == true || (stats.docsIndexRaw % 2_048 == 0 && Task.isCancelled) { break }
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            guard end > start else { continue }
            stats.docsIndexRaw += 1
            autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any],
                      let absolute = object["absolute_path"] as? String,
                      absolute.hasPrefix(prefix)
                else { return }
                let relative = String(absolute.dropFirst(prefix.count))
                let components = relative.split(separator: "/").map(String.init)
                guard components.count >= 2, validRuns.contains(components[0]),
                      components.dropFirst().dropLast().allSatisfy({ !EverywhereScope.prunesDirectory($0) }) else { return }
                let url = URL(fileURLWithPath: absolute)
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard canonical.hasPrefix(prefix), FileManager.default.fileExists(atPath: canonical) else {
                    stats.docsIndexMissing += 1
                    return
                }
                let parent = url.deletingLastPathComponent().path
                if ancestryCache[parent] == nil {
                    var clean = true
                    var cursor = url.deletingLastPathComponent()
                    while cursor.path != root.path && cursor.path.hasPrefix(prefix) {
                        if hasNoLaunchMarker(cursor) || hasLinkedWorktreeMarker(cursor) || isExcludedPackage(cursor, allowDocumentPackage: false) { clean = false; break }
                        cursor.deleteLastPathComponent()
                    }
                    ancestryCache[parent] = clean
                }
                guard ancestryCache[parent] == true else { return }
                let kind = (object["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "doc"
                let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
                let tags = (object["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
                emit(candidate(url, title: title, kind: kind, source: .docsIndex, tags: tags, documentID: LauncherDocsIndexReader.documentID(object)), area: .other("agent-output"), category: "docs-index", into: &result, stats: &stats)
            }
        }
    }
}
