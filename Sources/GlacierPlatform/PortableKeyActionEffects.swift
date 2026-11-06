import AppKit
import Foundation
import GlacierConfiguration
import HyperOverlayRuntime

/// Reuses the proven selection/Finder/clipboard adapters, but replaces every
/// personal helper path and the fixed Sublime/Ghostty assumptions.
@MainActor
public final class PortableKeyActionEffects: KeyActionEffects {
    public typealias FileFinder = @Sendable (String) async -> [URL]

    private let safeEffects: KeyActionSystemEffects
    private var terminal: TerminalAdapter
    private var rootDirectory: URL?
    private var editorBundleID: String
    private let fileFinder: FileFinder?

    public init(collect: CollectSystemEffects,
                settings: GlacierSettings,
                editorBundleID: String? = nil,
                fileFinder: FileFinder? = nil,
                pasteboard: NSPasteboard = .general,
                onFailure: @escaping @MainActor (String) -> Void,
                onNotice: @escaping @MainActor (String) -> Void) {
        safeEffects = KeyActionSystemEffects(collect: collect, pasteboard: pasteboard,
                                             onFailure: onFailure, onNotice: onNotice)
        terminal = TerminalAdapter(preference: settings.terminal)
        rootDirectory = settings.roots.jumpToRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.editorBundleID = editorBundleID ?? settings.editorBundleID
        self.fileFinder = fileFinder
    }

    public func applySettings(_ settings: GlacierSettings) {
        editorBundleID = settings.editorBundleID
        terminal = TerminalAdapter(preference: settings.terminal)
        rootDirectory = settings.roots.jumpToRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func trusted() -> Bool { safeEffects.trusted() }
    public func waitForHyperRelease() async -> Bool { await safeEffects.waitForHyperRelease() }
    public func copySelection(from target: PasteTarget, wait: Duration,
                              isCurrent: @escaping @MainActor () -> Bool) async -> CollectCopy {
        await safeEffects.copySelection(from: target, wait: wait, isCurrent: isCurrent)
    }
    public func clipboardText() -> String? { safeEffects.clipboardText() }
    public func clipboardRevision() -> Int { safeEffects.clipboardRevision() }
    public func finderSelection() async -> FinderSelection { await safeEffects.finderSelection() }

    public func helper(_ helper: KeyActionHelper, input: String) async -> HelperAnswer {
        switch helper {
        case .extractPath:
            return Self.existingPath(in: input).map(HelperAnswer.value) ?? .none
        case .extractURL:
            return Self.webURL(in: input).map(HelperAnswer.value) ?? .none
        case .jumpRoot:
            guard let rootDirectory, directoryExists(rootDirectory.path) else { return .none }
            return .value(rootDirectory.path)
        case .fence:
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
            return .value(Self.markdownFence(input))
        case .gather:
            let destinations = MarkdownLocalLink.destinations(in: input)
            if !destinations.isEmpty {
                var paths = destinations.compactMap { Self.existingDestination($0, decodePercent: true) }
                let remainder = MarkdownLocalLink.remainingText(in: input).trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty, let fileFinder {
                    paths += await fileFinder(remainder).filter(\.isFileURL).map(\.path)
                }
                var seen: Set<String> = []
                paths = paths.filter { path in
                    var isDirectory: ObjCBool = false
                    return !path.contains("\n") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                        && !isDirectory.boolValue && seen.insert(path).inserted
                }
                return paths.isEmpty ? .none : .value(paths.joined(separator: "\n"))
            }
            guard let fileFinder else { return .failed }
            let files = await fileFinder(input).filter { $0.isFileURL && !$0.path.contains("\n") }
            return files.isEmpty ? .none : .value(files.map(\.path).joined(separator: "\n"))
        }
    }

    public func directoryExists(_ path: String) -> Bool { safeEffects.directoryExists(path) }

    public func open(_ urls: [URL], with app: KeyActionApp?) async -> Bool {
        switch app {
        case nil: return await safeEffects.open(urls, with: nil)
        case .sublime:
            guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editorBundleID) else { return false }
            do {
                _ = try await NSWorkspace.shared.open(urls, withApplicationAt: editor,
                                                      configuration: NSWorkspace.OpenConfiguration())
                return true
            } catch { return false }
        case .ghostty:
            guard urls.count == 1, let folder = urls.first else { return false }
            do { try await terminal.open(folder: folder); return true }
            catch { return false }
        }
    }

    public func reveal(_ urls: [URL]) -> Bool { safeEffects.reveal(urls) }
    public func writeClipboard(text: String, ifRevision revision: Int) -> ClipboardWrite {
        safeEffects.writeClipboard(text: text, ifRevision: revision)
    }
    public func writeClipboard(files: [URL], ifRevision revision: Int) -> ClipboardWrite {
        safeEffects.writeClipboard(files: files, ifRevision: revision)
    }
    public func showFailure(_ text: String) { safeEffects.showFailure(text) }
    public func showNotice(_ text: String) { safeEffects.showNotice(text) }

    /// Uses only an explicit path in selected input; never scans Home or an
    /// unrelated folder to guess what the user meant.
    public static func existingPath(in text: String) -> String? {
        let destinations = MarkdownLocalLink.destinations(in: text)
        if !destinations.isEmpty { return destinations.compactMap { existingDestination($0, decodePercent: true) }.first }
        for raw in text.split(whereSeparator: \.isNewline) {
            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = existingDestination(candidate, decodePercent: false) { return path }
        }
        return nil
    }

    private static func existingDestination(_ candidate: String, decodePercent: Bool) -> String? {
        let path: String
        if candidate.hasPrefix("file://"), let url = URL(string: candidate), url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            path = url.path
        } else if candidate.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(candidate.dropFirst(2))).path
        } else if candidate.hasPrefix("/") {
            path = candidate
        } else { return nil }
        // Decode Markdown URL syntax once; plain raw paths retain percent bytes.
        // Literal numeric suffixes still win over source-line annotations.
        let candidates = decodePercent && !candidate.hasPrefix("file://")
            ? [path.removingPercentEncoding ?? path] : [path]
        for current in candidates {
            if FileManager.default.fileExists(atPath: current) { return current }
            for suffix in [#"#[^/#]+"#, #":[0-9]+(?::[0-9]+)?"#] {
                if let range = current.range(of: suffix + "$", options: .regularExpression) {
                    let withoutLine = String(current[..<range.lowerBound])
                    if FileManager.default.fileExists(atPath: withoutLine) { return withoutLine }
                }
            }
        }
        return nil
    }

    public static func webURL(in text: String) -> String? {
        for word in text.split(whereSeparator: \.isWhitespace) {
            var candidate = String(word)
            while let last = candidate.last, ").,;:!?]}'\"".contains(last) { candidate.removeLast() }
            guard let url = URL(string: candidate),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { continue }
            return url.absoluteString
        }
        return nil
    }

    public static func markdownFence(_ text: String) -> String {
        var run = 0, longest = 0
        for character in text {
            if character == "`" { run += 1; longest = max(longest, run) }
            else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
    }
}
