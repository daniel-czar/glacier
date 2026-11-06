import Darwin
import Foundation

/// Only Glacier-owned state paths. An override is intended for synthetic test roots.
public struct GlacierPaths: Sendable {
    public let support: URL
    public let cache: URL
    public let logs: URL
    public let settings: URL

    public init(home: URL, supportOverride: URL? = nil) throws {
        let canonicalHome = try Self.canonical(home)
        guard canonicalHome.path != "/" else { throw GlacierConfigurationError.invalidPath(home.path) }
        let requestedSupport = supportOverride ?? canonicalHome
            .appendingPathComponent("Library/Application Support/Glacier", isDirectory: true)
        try Self.rejectFinalSymlink(requestedSupport)
        let support = try Self.canonical(requestedSupport)
        let requestedCache = supportOverride == nil
            ? canonicalHome.appendingPathComponent("Library/Caches/Glacier", isDirectory: true)
            : support.appendingPathComponent("Cache", isDirectory: true)
        let requestedLogs = supportOverride == nil
            ? canonicalHome.appendingPathComponent("Library/Logs/Glacier", isDirectory: true)
            : support.appendingPathComponent("Logs", isDirectory: true)
        try Self.rejectFinalSymlink(requestedCache)
        try Self.rejectFinalSymlink(requestedLogs)
        let cache = try Self.canonical(requestedCache)
        let logs = try Self.canonical(requestedLogs)
        guard Self.isSafeStateRoot(support, home: canonicalHome),
              support.lastPathComponent == "Glacier",
              Self.isSafeStateRoot(cache, home: canonicalHome),
              Self.isSafeStateRoot(logs, home: canonicalHome) else {
            throw GlacierConfigurationError.invalidPath(support.path)
        }
        self.support = support
        self.cache = cache
        self.logs = logs
        self.settings = support.appendingPathComponent("settings.json")
    }

    /// Validates a user-selected output folder without treating it as an app state root.
    /// The caller still decides whether a particular operation may write there.
    public static func validateUserDirectory(_ url: URL) throws -> URL {
        let candidate = try canonical(url)
        guard isSafeStateRoot(candidate, home: URL(fileURLWithPath: "/")) else {
            throw GlacierConfigurationError.invalidPath(candidate.path)
        }
        return candidate
    }

    /// Resolves the nearest existing ancestor, then appends not-yet-created descendants.
    /// Foundation's `resolvingSymlinksInPath` can leave an alias unresolved when the leaf
    /// does not exist, so state protection must use `realpath` on an existing prefix.
    public static func canonicalFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw GlacierConfigurationError.invalidPath(url.absoluteString)
        }
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while true {
            var state = stat()
            if lstat(ancestor.path, &state) == 0 {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                guard let resolved = realpath(ancestor.path, &buffer) else {
                    // Includes a dangling symlink. Never return the unverified lexical path.
                    throw GlacierConfigurationError.invalidPath(ancestor.path)
                }
                var result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                for component in missing.reversed() { result.appendPathComponent(component) }
                // `standardizedFileURL` rewrites /private/var back to /var on
                // macOS, undoing realpath and mismatching FileManager's crawl URLs.
                return result
            }
            guard errno == ENOENT, ancestor.path != "/" else {
                throw GlacierConfigurationError.invalidPath(ancestor.path)
            }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }

    private static func canonical(_ url: URL) throws -> URL { try canonicalFileURL(url) }

    private static func rejectFinalSymlink(_ url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw GlacierConfigurationError.invalidPath(url.path)
        }
    }

    private static func isSafeStateRoot(_ url: URL, home: URL) -> Bool {
        let path = url.path
        if path == "/" || path == home.path { return false }
        // Reject both the live app state and the two source checkouts, even through symlinks.
        let bannedComponents: Set<String> = [
            "omni", "omniintent", "omniintentstandalone", "hyperoverlay", "hyperoverlayhost",
            "danieltooling",
        ]
        let components = url.pathComponents.map {
            $0.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        if components.contains(where: bannedComponents.contains) { return false }
        // Never use the Glacier source checkout itself as an Application Support root.
        return !zip(components, components.dropFirst()).contains { pair in
            pair.0 == "apps" && pair.1 == "glacier"
        }
    }
}
