import AppKit
import ApplicationServices
import Foundation
import HyperOverlayCore

/// The key actions' real platform effects (plan f71f8baac8f0149e). The copy
/// and modifier waits are Collect's; Finder is asked through `osascript`, so
/// a first-use Automation prompt never blocks the host's main thread; the
/// helpers run bounded under the host's minimal environment plus `HOME`.
@MainActor
public final class KeyActionSystemEffects: KeyActionEffects {
    public static let helperTimeout: TimeInterval = 8
    /// Gather asks Spotlight once per name and root: a few seconds for a long
    /// list of names.
    public static let gatherTimeout: TimeInterval = 30
    /// Long enough to answer a first-use Automation prompt.
    public static let finderTimeout: TimeInterval = 30

    private let collect: CollectSystemEffects
    private let pasteboard: NSPasteboard
    private let onFailure: @MainActor (String) -> Void
    private let onNotice: @MainActor (String) -> Void

    public init(collect: CollectSystemEffects, pasteboard: NSPasteboard = .general,
                onFailure: @escaping @MainActor (String) -> Void,
                onNotice: @escaping @MainActor (String) -> Void) {
        self.collect = collect
        self.pasteboard = pasteboard
        self.onFailure = onFailure
        self.onNotice = onNotice
    }

    public func trusted() -> Bool { AXIsProcessTrusted() }
    public func waitForHyperRelease() async -> Bool { await collect.waitForHyperRelease() }

    public func copySelection(from target: PasteTarget, wait: Duration,
                              isCurrent: @escaping @MainActor () -> Bool) async -> CollectCopy {
        await collect.copySelection(from: target, wait: wait, isCurrent: isCurrent)
    }

    /// The clipboard as text: Finder copies as their paths, as Collect reads
    /// them; concealed and transient copies never.
    public func clipboardText() -> String? { CollectSystemEffects.read(pasteboard) }

    public func clipboardRevision() -> Int { pasteboard.changeCount }

    public static func isFinder(_ application: NSRunningApplication?) -> Bool {
        application?.bundleIdentifier == "com.apple.finder"
    }

    /// File URLs, not POSIX paths: percent-encoded, so a name with a line
    /// break cannot split into two entries. With nothing selected, the
    /// insertion location: the front window's folder, or the desktop when
    /// the desktop is focused.
    static let finderScript = """
    tell application "Finder"
        set theSelection to selection
        if theSelection is not {} then
            set out to "S"
            repeat with theItem in theSelection
                set out to out & linefeed & (URL of theItem)
            end repeat
            return out
        end if
        try
            set insertionFolder to insertion location
            return "W" & linefeed & (URL of insertionFolder)
        end try
        return "N"
    end tell
    """

    public func finderSelection() async -> FinderSelection {
        let result = await HelperProcess.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-"],
                                             stdin: Self.finderScript, environment: HelperProcess.baseEnvironment,
                                             timeout: Self.finderTimeout)
        return Self.parseFinder(result)
    }

    nonisolated static func parseFinder(_ result: HelperProcess.Result?) -> FinderSelection {
        guard let result else { return .unavailable("Finder didn't answer") }
        guard result.status == 0 else {
            // -1743: the person declined, or has not yet allowed, Automation.
            return .unavailable(result.stderr.contains("-1743") ? "Finder access needed" : "Finder didn't answer")
        }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let paths = lines.dropFirst().compactMap { line -> String? in
            guard let url = URL(string: line), url.isFileURL, !url.path.isEmpty else { return nil }
            return url.path
        }
        switch lines.first {
        case "S" where !paths.isEmpty: return .items(paths)
        case "W" where !paths.isEmpty: return .window(paths[0])
        default: return .nothing
        }
    }

    public nonisolated static func helperInvocation(_ helper: KeyActionHelper) -> (executable: URL, arguments: [String]) {
        let home = OverlayPaths.homeDirectory
        let toolkit = OverlayPaths.toolingRoot.appendingPathComponent("shell-toolkit/bin")
        switch helper {
        case .extractPath: return (home.appendingPathComponent(".local/bin/km-extract-path"), [])
        case .extractURL: return (home.appendingPathComponent(".local/bin/km-extract-url"), [])
        case .jumpRoot: return (toolkit.appendingPathComponent("km-jump-root.sh"), [])
        case .fence: return (toolkit.appendingPathComponent("km-wrap-markdown-fence.sh"), ["--stdin"])
        case .gather: return (toolkit.appendingPathComponent("gather_files.sh"), ["--print"])
        }
    }

    public nonisolated static var helperEnvironment: [String: String] {
        HelperProcess.baseEnvironment.merging(["HOME": OverlayPaths.homeDirectory.path]) { _, new in new }
    }

    public func helper(_ helper: KeyActionHelper, input: String) async -> HelperAnswer {
        let invocation = Self.helperInvocation(helper)
        let result = await HelperProcess.run(invocation.executable, arguments: invocation.arguments, stdin: input,
                                             environment: Self.helperEnvironment,
                                             timeout: helper == .gather ? Self.gatherTimeout : Self.helperTimeout)
        return Self.answer(helper, result)
    }

    /// Exit 0 with output is a value. Exit 0 with nothing, exit 1 (the
    /// extractors' "nothing found") and exit 64 (the fence's empty input) are
    /// a miss. A timeout, a signal, a start failure or any other status is a
    /// failure.
    nonisolated static func answer(_ helper: KeyActionHelper, _ result: HelperProcess.Result?) -> HelperAnswer {
        guard let result else { return .failed }
        switch result.status {
        case 0:
            // The fence keeps its exact bytes; the rest are one value per line.
            let value = helper == .fence ? result.stdout : result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .none : .value(value)
        case 1, 64: return .none
        default: return .failed
        }
    }

    public func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func open(_ urls: [URL], with app: KeyActionApp?) async -> Bool {
        guard let app else {
            for url in urls {
                do { _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) } catch { return false }
            }
            return true
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) else { return false }
        do {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            return false
        }
    }

    public func reveal(_ urls: [URL]) -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        return true
    }

    /// An ordinary copy, without Collect's history marker: the result is
    /// something the person asked for and belongs in Clipboard history.
    public func writeClipboard(text: String, ifRevision revision: Int) -> ClipboardWrite {
        guard pasteboard.changeCount == revision else { return .stale }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string) ? .written : .failed
    }

    public func writeClipboard(files: [URL], ifRevision revision: Int) -> ClipboardWrite {
        guard pasteboard.changeCount == revision else { return .stale }
        pasteboard.clearContents()
        return pasteboard.writeObjects(files as [NSURL]) ? .written : .failed
    }

    public func showFailure(_ text: String) { onFailure(text) }
    public func showNotice(_ text: String) { onNotice(text) }
}
