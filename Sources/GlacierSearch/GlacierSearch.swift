import CryptoKit
import Foundation
import GlacierConfiguration
import OmniApplication
import OmniAdapters
import OmniCore

/// Shared authority for indexed rows, including old /find results. Explicit Finder actions use a different authority.
public struct SourcePolicy: Sendable {
    /// Enabled roots watched by FSEvents. A disabled nested root still masks its parent.
    public let roots: [GlacierSourceRoot]
    public let protectedRoots: [URL]
    private let configuredRoots: [GlacierSourceRoot]
    public init(roots: [GlacierSourceRoot], protectedRoots: [URL]) {
        self.configuredRoots = roots
        self.roots = roots.filter(\.enabled)
        self.protectedRoots = protectedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }
    public func permits(_ path: String) -> Bool { permits(path, forTraversal: false) }
    /// App-only roots still allow directory traversal to reach nested bundles.
    public func permitsTraversal(_ path: String) -> Bool { permits(path, forTraversal: true) }
    private func permits(_ path: String, forTraversal: Bool) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path, url.path == url.resolvingSymlinksInPath().path,
              !protectedRoots.contains(where: { Self.contains($0.path, url.path) }),
              !Self.isKnownPrivateState(url.path),
              !Self.isSensitivePath(url) else { return false }
        // The most specific configured root wins. Ties deny, including opposite flags.
        let matching = configuredRoots.filter { Self.contains($0.path, url.path) }
        guard let maximumLength = matching.map(\.path.count).max() else { return false }
        let mostSpecific = matching.filter { $0.path.count == maximumLength }
        guard mostSpecific.count == 1, let root = mostSpecific.first,
              root.enabled, root.path != "/",
              root.path == URL(fileURLWithPath: root.path).standardizedFileURL.resolvingSymlinksInPath().path else {
            return false
        }
        let relative = String(url.path.dropFirst(root.path.count)).split(separator: "/").map(String.init)
        if !root.recursive && relative.count > 1 { return false }
        if relative.contains(where: { component in
            (!root.includeHidden && component.hasPrefix(".")) ||
            Self.excludedDirectories.contains(component) || root.excludedNames.contains(component)
        }) { return false }
        if !root.includeSourceFiles && Self.sourceExtensions.contains(url.pathExtension.lowercased()) { return false }
        if root.applicationDiscoveryOnly {
            // A direct bundle root (Finder) grants the app, not its contents or helpers.
            if root.path.lowercased().hasSuffix(".app") && !relative.isEmpty { return false }
            // Never expose another bundle nested inside an application package.
            if relative.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) { return false }
            // A directory may lead to an app, but is not itself an indexed result.
            if !forTraversal && url.pathExtension.lowercased() != "app" { return false }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
        }
        var ancestor = url.deletingLastPathComponent()
        while Self.contains(root.path, ancestor.path) {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".nolaunch").path) { return false }
            if ancestor.path == root.path { break }
            ancestor.deleteLastPathComponent()
        }
        return true
    }
    /// A file event inside a bundle must rescan its outermost app's parent,
    /// matching the full scan's package-descendant skip for the effective root.
    func rescanPath(for changed: String) -> String {
        let matching = configuredRoots.filter { Self.contains($0.path, changed) }
        guard let maximumLength = matching.map(\.path.count).max() else { return changed }
        let mostSpecific = matching.filter { $0.path.count == maximumLength }
        guard mostSpecific.count == 1, let root = mostSpecific.first,
              root.enabled else { return changed }
        if root.applicationDiscoveryOnly && root.path.lowercased().hasSuffix(".app") { return root.path }
        var ancestor = root.path
        for component in String(changed.dropFirst(root.path.count)).split(separator: "/") {
            ancestor += "/" + component
            if component.lowercased().hasSuffix(".app") { return ancestor }
        }
        return changed
    }
    public static func contains(_ root: String, _ path: String) -> Bool {
        root == "/" ? path.hasPrefix("/") : path == root || path.hasPrefix(root + "/")
    }
    public static let excludedDirectories: Set<String> = [
        "node_modules", "target", "DerivedData", "site-packages", "__pycache__", "Library", ".git", ".build", ".venv", ".nolaunch",
    ]
    public static let sourceExtensions: Set<String> = [
        "swift", "py", "rs", "ts", "tsx", "js", "jsx", "json", "go", "c", "h", "m", "mm", "cpp", "hpp", "java", "kt", "rb", "sh",
    ]
    private static let sensitiveDirectoryNames: Set<String> = [
        ".ssh", ".aws", ".gnupg", ".config", ".kube", ".azure", ".docker",
    ]
    private static let sensitiveFileNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials", "credentials.json",
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
    ]
    private static func isSensitivePath(_ url: URL) -> Bool {
        let components = url.pathComponents.map { $0.lowercased() }
        if components.contains(where: sensitiveDirectoryNames.contains) { return true }
        return components.contains { name in
            name == ".env" || name.hasPrefix(".env.") || name == ".envrc" ||
            sensitiveFileNames.contains(name) ||
            ["pem", "key", "p12", "pfx", "keystore"].contains(URL(fileURLWithPath: name).pathExtension)
        }
    }
    private static func isKnownPrivateState(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        if parts.contains(where: { ["omniintent", "omniintentstandalone", "danieltooling", "hyperoverlay", "hyperoverlayhost"].contains($0) }) {
            return true
        }
        for (index, part) in parts.enumerated() where part == "glacier" {
            if index > 0 && ["applicationsupport", "caches", "logs"].contains(parts[index - 1]) { return true }
        }
        for (index, part) in parts.enumerated() where part == "omni" {
            if index > 0 && parts[index - 1] == "applicationsupport" { return true }
        }
        return false
    }
    public var fingerprint: String {
        let bytes = (try? JSONEncoder().encode(configuredRoots)) ?? Data()
        let discovery = Data(configuredRoots.map { $0.applicationDiscoveryOnly ? "1" : "0" }.joined().utf8)
        return SHA256.hash(data: bytes + discovery + Data(protectedRoots.map(\.path).joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One generation-aware metadata store; all work is off the UI actor. No file contents or facets leave this service.
public final class GlacierSearchService: LauncherIndexBuilding, LauncherSnapshotStoring, FindIndexProviding, @unchecked Sendable {
    private struct Persisted: Codable {
        let schemaVersion: Int
        let fingerprint: String
        let eventID: UInt64?
        let snapshot: LauncherSnapshot
    }
    private let lock = NSLock()
    private let scanLock = NSLock()
    private let publicationLock = NSRecursiveLock()
    private let publishQueue = DispatchQueue(label: "glacier.search.publish", qos: .utility)
    private var policy: SourcePolicy
    private var generation = 0
    private var generationID: String
    private var snapshot: LauncherSnapshot
    private var findIndex: FindIndex = .empty
    private var eventID: UInt64?
    private var watcher: FSEverywhereWatcher?
    private var publish: (@Sendable (LauncherSnapshot) -> Void)?
    private let url: URL
    public init(directory: URL, policy: SourcePolicy) throws {
        self.policy = policy
        self.generationID = policy.fingerprint + ":" + UUID().uuidString
        self.url = directory.appendingPathComponent("metadata-index.json")
        snapshot = Self.empty()
        try GlacierFilePermissions.ensurePrivateDirectory(at: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try GlacierFilePermissions.ensurePrivateFile(at: url)
        }
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Persisted.self, from: data),
           saved.schemaVersion == 2, saved.fingerprint == policy.fingerprint {
            snapshot = Self.filtered(saved.snapshot, policy: policy, generationID: generationID)
            eventID = saved.eventID
        }
        findIndex = Self.makeFindIndex(snapshot, generationID: generationID)
    }
    private static func empty() -> LauncherSnapshot {
        LauncherSnapshot(builtAt: .distantPast, docsGeneration: nil, buildMilliseconds: nil, stats: .init(), candidates: [])
    }
    private static func filtered(_ value: LauncherSnapshot, policy: SourcePolicy, generationID: String) -> LauncherSnapshot {
        LauncherSnapshot(builtAt: value.builtAt, docsGeneration: generationID, buildMilliseconds: value.buildMilliseconds,
                         stats: value.stats, candidates: value.candidates.filter { policy.permits($0.path) })
    }
    public func currentDocsGeneration() -> String? { lock.withLock { generationID } }
    public func load() throws -> LauncherSnapshot? { lock.withLock { snapshot } }
    public func save(_ candidate: LauncherSnapshot) throws {
        try lock.withLock {
            guard candidate.docsGeneration == generationID,
                  candidate.builtAt >= snapshot.builtAt else { return }
            let safe = Self.filtered(candidate, policy: policy, generationID: generationID)
            let indexed = Self.makeFindIndex(safe, generationID: generationID)
            try persist(safe, event: eventID)
            snapshot = safe
            findIndex = indexed
        }
    }
    private func persist(_ candidate: LauncherSnapshot, event: UInt64?) throws {
        let data = try JSONEncoder().encode(Persisted(schemaVersion: 2, fingerprint: policy.fingerprint,
                                                     eventID: event, snapshot: candidate))
        try data.write(to: url, options: .atomic)
        try GlacierFilePermissions.ensurePrivateFile(at: url)
    }
    public func permits(_ path: String) -> Bool { lock.withLock { policy.permits(path) } }
    public func currentIndex() throws -> FindIndex {
        lock.withLock { findIndex }
    }
    public func cachedIndex() -> FindIndex? { try? currentIndex() }
    private static func makeFindIndex(_ snapshot: LauncherSnapshot, generationID: String) -> FindIndex {
        FindIndex(documents: snapshot.candidates.map {
            FindDocument(path: $0.path, title: $0.title, kind: $0.kind,
                         documentID: $0.documentID, modified: $0.modified, isPrivate: true)
        }, generation: generationID)
    }
    public func build() async throws -> LauncherSnapshot {
        // Capture the replay cursor before walking. Events during the walk replay on watch start.
        let baseline = FSEverywhereWatcher(paths: []).currentEventID()
        return try await Task.detached(priority: .utility) {
            try self.reconcile(paths: nil, event: baseline)
        }.value
    }
    /// Revocation is synchronous and clears old rows before any worker can publish.
    public func replacePolicy(_ replacement: SourcePolicy) throws {
        publicationLock.lock(); defer { publicationLock.unlock() }
        stopWatching()
        var writeFailure: Error?
        let (cleared, epoch): (LauncherSnapshot, Int) = lock.withLock {
            generation &+= 1
            policy = replacement
            generationID = replacement.fingerprint + ":" + UUID().uuidString
            eventID = nil
            let empty = Self.filtered(Self.empty(), policy: replacement, generationID: generationID)
            snapshot = empty
            findIndex = Self.makeFindIndex(empty, generationID: generationID)
            // A persisted tombstone makes a later A-B-A policy cycle restart-safe.
            do { try persist(empty, event: nil) } catch { writeFailure = error }
            return (empty, generation)
        }
        publishEvent(cleared, epoch: epoch)
        if let writeFailure { throw writeFailure }
    }
    public func startWatching(publish: @escaping @Sendable (LauncherSnapshot) -> Void) throws {
        stopWatching()
        let state = lock.withLock { () -> ([String], UInt64?) in
            self.publish = publish
            let watched = policy.roots.map { root -> String in
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                   isDirectory.boolValue { return root.path }
                return URL(fileURLWithPath: root.path).deletingLastPathComponent().path
            }
            return (Array(Set(watched)).sorted(), eventID)
        }
        guard !state.0.isEmpty else { return }
        let watcher = FSEverywhereWatcher(paths: state.0)
        try watcher.start(after: state.1) { [weak self] changes in
            guard let self else { return }
            let paths = changes.requiresFullScan ? nil : changes.paths
            _ = try? self.reconcile(paths: paths, event: changes.eventID)
        }
        lock.withLock { self.watcher = watcher }
    }
    public func stopWatching() { let old = lock.withLock { let old = watcher; watcher = nil; return old }; old?.stop() }
    func reconcile(paths: [String]?, event: UInt64?) throws -> LauncherSnapshot {
        scanLock.lock(); defer { scanLock.unlock() }
        let (policy, epoch, token, previous) = lock.withLock { (self.policy, generation, generationID, snapshot) }
        let started = Date()
        let fullScan = paths == nil || paths!.contains { changed in
            policy.roots.contains { root in SourcePolicy.contains(changed, root.path) }
        }
        var candidates = fullScan ? [] : previous.candidates
        let scanRoots: [URL]
        if fullScan {
            scanRoots = policy.roots.map { URL(fileURLWithPath: $0.path) }
        } else if let paths {
            let parents = Set(paths.map { changed -> String in
                let path = policy.rescanPath(for: changed)
                // A direct app root is its own scan unit, including changes inside the bundle.
                if policy.roots.contains(where: { $0.path == path && $0.applicationDiscoveryOnly }) { return path }
                return URL(fileURLWithPath: path).deletingLastPathComponent().path
            })
            scanRoots = parents.filter { policy.permitsTraversal($0) }.map { URL(fileURLWithPath: $0) }
            candidates.removeAll { candidate in
                paths.contains { SourcePolicy.contains($0, candidate.path) } ||
                scanRoots.contains { SourcePolicy.contains($0.path, candidate.path) } ||
                !policy.permits(candidate.path)
            }
        } else {
            scanRoots = []
        }
        var stats = fullScan ? LauncherIndexStats() : previous.stats
        var unreadable = Set(stats.unreadableRoots ?? [])
        for root in scanRoots {
            guard policy.permitsTraversal(root.path) else {
                if policy.roots.contains(where: { $0.path == root.path }) { unreadable.insert(root.path) }
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  FileManager.default.isReadableFile(atPath: root.path) else {
                unreadable.insert(root.path)
                continue
            }
            if Self.isCloudPlaceholder(root) { unreadable.insert(root.path); continue }
            unreadable.remove(root.path)
            if let entry = Self.entry(root, policy: policy) { candidates.append(entry) }
            guard isDirectory.boolValue else { continue }
            let showHidden = policy.roots.first { $0.path == root.path }?.includeHidden == true ||
                policy.roots.contains { $0.includeHidden && SourcePolicy.contains($0.path, root.path) }
            let options: FileManager.DirectoryEnumerationOptions = showHidden
                ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                             .contentModificationDateKey, .isUbiquitousItemKey,
                                             .ubiquitousItemDownloadingStatusKey],
                options: options,
                errorHandler: { _, _ in unreadable.insert(root.path); return true }
            ) else {
                unreadable.insert(root.path)
                continue
            }
            let physicalRoot = (try? GlacierPaths.canonicalFileURL(root))?.path ?? root.path
            for case let file as URL in enumerator {
                if Self.isCloudPlaceholder(file) { enumerator.skipDescendants(); continue }
                guard SourcePolicy.contains(physicalRoot, file.path) else { enumerator.skipDescendants(); continue }
                // FileManager may canonicalize a root's ancestor (e.g. /var -> /private/var)
                // even when the configured URL retains that spelling. Keep indexed paths in
                // the configured namespace; resource reads still resolve to the same file.
                let relative = String(file.path.dropFirst(physicalRoot.count))
                let configuredFile = URL(fileURLWithPath: root.path + relative)
                guard policy.permitsTraversal(configuredFile.path),
                      (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                    enumerator.skipDescendants(); continue
                }
                if FileManager.default.fileExists(atPath: configuredFile.appendingPathComponent(".nolaunch").path) {
                    enumerator.skipDescendants(); continue
                }
                if let entry = Self.entry(configuredFile, policy: policy) { candidates.append(entry) }
            }
        }
        candidates = Dictionary(candidates.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.path < $1.path }
        stats.unreadableRoots = unreadable.isEmpty ? nil : unreadable.sorted()
        stats.folders = candidates.filter { $0.kind == "folder" }.count
        stats.files = candidates.count - stats.folders
        let result = LauncherSnapshot(builtAt: Date(), docsGeneration: token,
            buildMilliseconds: Int(Date().timeIntervalSince(started) * 1_000), stats: stats, candidates: candidates)
        let indexed = Self.makeFindIndex(result, generationID: token)
        let accepted = try lock.withLock { () -> Bool in
            guard epoch == generation, token == generationID else { return false }
            let nextEvent = event.map { max($0, eventID ?? 0) } ?? eventID
            try persist(result, event: nextEvent)
            snapshot = result
            findIndex = indexed
            eventID = nextEvent
            return true
        }
        if accepted { publishEvent(result, epoch: epoch) }
        return lock.withLock { snapshot }
    }
    private func publishEvent(_ value: LauncherSnapshot, epoch: Int) {
        publishQueue.async { [weak self] in
            guard let self else { return }
            self.publicationLock.lock(); defer { self.publicationLock.unlock() }
            let callback = self.lock.withLock { epoch == self.generation ? self.publish : nil }
            callback?(value)
        }
    }
    private static func entry(_ url: URL, policy: SourcePolicy) -> LauncherCandidate? {
        guard policy.permits(url.path),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                              .isPackageKey, .contentModificationDateKey,
                                                              .isUbiquitousItemKey,
                                                              .ubiquitousItemDownloadingStatusKey]),
              values.isSymbolicLink != true else { return nil }
        let ext = url.pathExtension.lowercased()
        guard !["download", "crdownload", "part"].contains(ext) else { return nil }
        // Metadata-only indexing must not hydrate a cloud placeholder.
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current {
            return nil
        }
        let appBundle = values.isDirectory == true && ext == "app"
        let kind = values.isDirectory == true ? (appBundle ? "app" : "folder") : (ext.isEmpty ? "file" : ext)
        let frontmatter = ext == "md" && values.isDirectory != true ? Self.frontmatter(at: url) : nil
        return LauncherCandidate(title: frontmatter?.title ?? url.lastPathComponent,
                                 path: url.path, kind: frontmatter?.kind ?? kind,
                                 source: appBundle ? .apps : .files, modified: values.contentModificationDate,
                                 documentID: frontmatter?.id)
    }
    private static func isCloudPlaceholder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                               .ubiquitousItemDownloadingStatusKey]) else { return false }
        return values.isUbiquitousItem == true &&
            values.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current
    }
    private struct Frontmatter {
        let id: String?
        let title: String?
        let kind: String?
    }
    /// Parses only three scalar fields from a bounded frontmatter header. No body is indexed.
    private static func frontmatter(at url: URL) -> Frontmatter? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8_192),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
              }) else { return nil }
        var id: String?
        var title: String?
        var kind: String?
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":"), !line[..<colon].contains(" ") else { continue }
            let key = String(line[..<colon])
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2 && ((value.first == "\"" && value.last == "\"") ||
                                    (value.first == "'" && value.last == "'")) {
                value.removeFirst(); value.removeLast()
            }
            switch key {
            case "id" where value.count == 16 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }):
                id = value
            case "title" where !value.isEmpty && value.count <= 256: title = value
            case "kind" where !value.isEmpty && value.count <= 64: kind = value
            default: break
            }
        }
        return Frontmatter(id: id, title: title, kind: kind)
    }
    deinit { watcher?.stop() }
}

public struct GlacierSearchOpener: LauncherTargetOpening {
    private let search: GlacierSearchService
    private let effect: @Sendable (URL, LauncherOpenAction) async throws -> Void
    public init(search: GlacierSearchService, effect: @escaping @Sendable (URL, LauncherOpenAction) async throws -> Void) { self.search = search; self.effect = effect }
    public func open(_ candidate: LauncherCandidate, action: LauncherOpenAction) async throws -> String {
        guard search.permits(candidate.path) else { throw LauncherError.excludedTarget(candidate.path) }
        guard FileManager.default.fileExists(atPath: candidate.path) else { throw LauncherError.missingTarget(candidate.path) }
        try await effect(URL(fileURLWithPath: candidate.path), action.effective(for: candidate, lane: .everywhere))
        return "Opened selected source item"
    }
}
