import Foundation

/// C72's file-type and lexical scope rules. Filesystem checks (packages,
/// worktree markers and .nolaunch) belong to the adapter.
public enum EverywhereScope {
    public static let documentExtensions: Set<String> = [
        "pdf", "md", "markdown", "docx", "doc", "pages", "numbers", "key",
        "pptx", "ppt", "xlsx", "xls", "typ", "tex", "epub", "rtf", "rtfd",
        "odt", "ods", "odp", "sketch", "fig", "psd",
    ]
    public static let plainTextExtensions: Set<String> = ["txt", "csv", "html", "htm"]
    public static let mediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff", "tif", "bmp",
        "mp4", "mov", "m4v", "mkv", "avi", "webm",
    ]
    public static let revealExtensions: Set<String> = ["pkg", "dmg", "zip", "tar", "gz", "tgz", "7z", "rar"]
    public static let packageDocumentExtensions: Set<String> = ["pages", "numbers", "key", "rtfd", "sketch"]
    public static let massThreshold = 500

    public enum Area: Sendable, Equatable {
        case homeRoot
        case downloads
        case documents
        case desktop
        case iCloud
        case other(String)

        public var label: String {
            switch self {
            case .homeRoot: "~ root"
            case .downloads: "Downloads"
            case .documents: "Documents"
            case .desktop: "Desktop"
            case .iCloud: "iCloud Drive"
            case .other(let name): name
            }
        }

        public var admitsPlainText: Bool {
            switch self {
            case .homeRoot, .downloads, .documents, .desktop, .iCloud: true
            case .other: false
            }
        }

        public func admitsMedia(downloadsMediaEnabled: Bool) -> Bool {
            switch self {
            case .homeRoot, .documents, .desktop, .iCloud: true
            case .downloads: downloadsMediaEnabled
            case .other: false
            }
        }

        public var admitsRevealFile: Bool { true }

        public static func topLevel(_ name: String) -> Area {
            switch name {
            case "Downloads": .downloads
            case "Documents": .documents
            case "Desktop": .desktop
            default: .other(name)
            }
        }
    }

    public enum FileClass: String, Sendable {
        case document
        case plainText
        case media
        case reveal
    }

    public static func fileClass(name: String, area: Area, downloadsMediaEnabled: Bool) -> FileClass? {
        let ext = extensionOf(name)
        if documentExtensions.contains(ext) { return .document }
        if plainTextExtensions.contains(ext), area.admitsPlainText { return .plainText }
        if mediaExtensions.contains(ext), area.admitsMedia(downloadsMediaEnabled: downloadsMediaEnabled), !isScreenshotName(name) { return .media }
        if revealExtensions.contains(ext), area.admitsRevealFile { return .reveal }
        return nil
    }

    public static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    public static func isScreenshotName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["screenshot", "screen shot", "cleanshot", "bildschirmfoto"].contains { lower.hasPrefix($0) }
    }

    public static func prunesDirectory(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.lowercased().contains("screenshot") { return true }
        if name.lowercased().hasSuffix(".app") || name.lowercased().hasSuffix(".photoslibrary") || name.lowercased().hasSuffix(".library") { return true }
        return LauncherPathRules.prunesDirectory(named: name)
    }

    public static func isRunFolder(_ name: String) -> Bool {
        guard let underscore = name.firstIndex(of: "_"), underscore != name.startIndex else { return false }
        let id = name[..<underscore]
        guard id.count == 16, name.index(after: underscore) < name.endIndex else { return false }
        return id.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

public struct EverywhereWalkStats: Codable, Sendable, Equatable {
    public var visited = 0
    public var rowsByArea: [String: Int] = [:]
    public var rowsBySource: [String: Int] = [:]
    public var documentRowsOutsideAgentOutput = 0
    public var collapsedFolders = 0
    public var collapsedDirectoryPaths: [String] = []
    public var unreadableRoots: [String] = []
    public var docsIndexRaw = 0
    public var docsIndexMissing = 0
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case visited
        case rowsByArea = "rows_by_area"
        case rowsBySource = "rows_by_source"
        case documentRowsOutsideAgentOutput = "document_rows_outside_agent_output"
        case collapsedFolders = "collapsed_folders"
        case collapsedDirectoryPaths = "collapsed_directory_paths"
        case unreadableRoots = "unreadable_roots"
        case docsIndexRaw = "docs_index_raw"
        case docsIndexMissing = "docs_index_missing"
    }
}

public struct EverywhereWalkResult: Codable, Sendable, Equatable {
    public let candidates: [LauncherCandidate]
    public let stats: EverywhereWalkStats

    public init(candidates: [LauncherCandidate], stats: EverywhereWalkStats) {
        self.candidates = candidates
        self.stats = stats
    }
}
