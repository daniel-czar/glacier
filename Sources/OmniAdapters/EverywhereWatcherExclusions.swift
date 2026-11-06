import Darwin
import Foundation
#if canImport(OmniCore)
import OmniCore
#endif

enum EverywhereWatcherPath {
    /// Foundation's resolvingSymlinksInPath can retain /var on current macOS
    /// even though FSEvents reports /private/var. Resolve existing watch roots
    /// once with POSIX realpath; never do this in the native callback.
    static func physicalRoot(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolved = standardized.withCString({ realpath($0, nil) }) else { return standardized }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Conservative, filesystem-backed evidence for FSEvents exclusions. A path
/// learned from an event or cache is never trusted without checking it again.
struct EverywhereWatcherExclusionPolicy: Sendable {
    enum Reason: Int, Sendable, Equatable {
        case unscopedLibrary = 0, lexical = 1, noLaunch = 2, linkedWorktree = 3
    }

    let home: String
    let watchedRoots: [String]
    static let maximumNativePaths = 8
    static let maximumAncestorChecks = 24

    init(paths: [String]) {
        watchedRoots = Array(Set(paths.map(EverywhereWatcherPath.physicalRoot))).sorted()
        home = watchedRoots.min(by: { $0.count < $1.count }) ?? ""
    }

    /// The shallowest proven excluded ancestor suppresses the most traffic.
    /// Inspection starts from the event's parent, so marker create/delete
    /// events can reveal the owning directory without guessing file types.
    func discover(from eventPath: String) -> String? {
        // FSEvents supplies physical spelling. Foundation turns /private/var
        // back into /var, breaking containment against realpath watch roots.
        let event = eventPath
        guard event.hasPrefix("/") else { return nil }
        guard isInsideWatchedRoot(event) else { return nil }
        var cursor = event
        var result: String?
        for _ in 0..<Self.maximumAncestorChecks {
            if reason(for: cursor) != nil { result = cursor }
            guard cursor != home, cursor != "/" else { break }
            let parent = (cursor as NSString).deletingLastPathComponent
            guard parent != cursor, isInsideWatchedRoot(parent) else { break }
            cursor = parent
        }
        return result
    }

    func reason(for path: String) -> Reason? {
        let path = EverywhereWatcherPath.physicalRoot(path)
        guard isInsideWatchedRoot(path), !isProtected(path), isDirectory(path) else { return nil }
        var marker = stat()
        if lstat(path + "/.git", &marker) == 0,
           (marker.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) { return .linkedWorktree }
        if lstat(path + "/.nolaunch", &marker) == 0,
           (marker.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) { return .noLaunch }
        if LauncherPathRules.prunesDirectory(named: (path as NSString).lastPathComponent) { return .lexical }
        let library = home + "/Library/"
        if path.hasPrefix(library) {
            let tail = path.dropFirst(library.count)
            if !tail.contains("/"), tail != "Mobile Documents" { return .unscopedLibrary }
        }
        return nil
    }

    func ranked(_ paths: Set<String>) -> [String] {
        paths.compactMap { path -> (String, Reason)? in
            guard let reason = reason(for: path) else { return nil }
            return (path, reason)
        }.sorted {
            if $0.1.rawValue != $1.1.rawValue { return $0.1.rawValue > $1.1.rawValue }
            if $0.0.count != $1.0.count { return $0.0.count < $1.0.count }
            return $0.0 < $1.0
        }.prefix(Self.maximumNativePaths).map(\.0)
    }

    private func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private func isInsideWatchedRoot(_ path: String) -> Bool {
        watchedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func isProtected(_ path: String) -> Bool {
        // An excluded ancestor would mask events from the separately crawled
        // iCloud root. The agent-output root has its own shallow run census;
        // the docs index is an independent metadata source, even when its
        // containing Tooling directory carries an opt-out marker.
        if path == home || path == home + "/Tooling/agent-output" { return true }
        if watchedRoots.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { return true }
        let docsIndex = home + "/Tooling/retrieval/.index"
        if path == docsIndex || docsIndex.hasPrefix(path + "/") { return true }
        if path == home + "/Library" { return true }
        return false
    }
}
