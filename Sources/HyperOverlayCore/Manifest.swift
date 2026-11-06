import Foundation

public enum OverlayID {
    public static let reference = "hyper-reference"
    public static let referenceSheet = "hyper-reference-sheet"
    public static let help = "hyper-help"
    public static let space = "hyper-space"
    public static let webSearch = "hyper-web-search"
    public static let zoxide = "hyper-z"
    public static let translate = "hyper-translate"
    public static let quickQuestion = "hyper-quick-question"
    public static let semanticTools = "hyper-semantic-tools"
    public static let normalizeNote = "hyper-normalize-note"
    public static let capture = "hyper-capture"
    public static let pronounce = "hyper-pronounce"
    public static let express = "hyper-express"
    public static let clipboard = "hyper-clipboard"
    /// The stash stack (`st`, C92): Hyper+Y, yank; Clipboard moved to Hyper+'.
    public static let stash = "hyper-stash"

    /// Collect (H19, C104–C110): direct actions. They hold manifest chords
    /// but open nothing: never foreground overlays, never socket `show`
    /// targets. "Buffer" is the code's word; the UI says Collect.
    public static let collectAdd = "hyper-clip-buffer-add"
    public static let collectNext = "hyper-clip-buffer-next"
    public static let collectAll = "hyper-clip-buffer-batch"
    public static let collectClear = "hyper-clip-buffer-clear"
    public static let equalize = "hyper-clipboard-equalize"

    /// The former Keyboard Maestro utilities (plan f71f8baac8f0149e): direct
    /// actions on the selection, the clipboard or the Finder selection.
    public static let reveal = "hyper-reveal"
    public static let openNaturally = "hyper-open"
    public static let jumpToRoot = "hyper-jump-root"
    public static let editInSublime = "hyper-edit-sublime"
    public static let terminalHere = "hyper-terminal-here"
    public static let copyPath = "hyper-copy-path"
    public static let fence = "hyper-fence"
    public static let gatherFiles = "hyper-gather"

    public static let collectActions: Set<String> = [collectAdd, collectNext, collectAll, collectClear, equalize]
    public static let keyActions: Set<String> = [
        reveal, openNaturally, jumpToRoot, editInSublime, terminalHere, copyPath, fence, gatherFiles,
    ]
    public static let directActions: Set<String> = collectActions.union(keyActions)

    /// Every id the hotkey manifest must hold: the overlays plus the direct
    /// actions. Lifecycle and socket `show` accept only `implemented`.
    public static var hotkeyIDs: Set<String> { implemented.union(directActions) }

    public static let implemented: Set<String> = [
        reference,
        referenceSheet,
        help,
        space,
        webSearch,
        zoxide,
        translate,
        quickQuestion,
        semanticTools,
        normalizeNote,
        capture,
        pronounce,
        express,
        clipboard,
        stash
    ]

    public static let manifest: Set<String> = [
        reference,
        referenceSheet,
        translate,
        quickQuestion,
        semanticTools,
        normalizeNote,
        capture,
        pronounce,
        express,
        clipboard,
        stash,
        webSearch,
        space,
        zoxide,
        help
    ]
}

public struct CommandReferenceEntry: Codable, Equatable, Sendable {
    public var category: String
    public var title: String
    public var command: String
    public var note: String?

    public init(category: String, title: String, command: String, note: String?) {
        self.category = category
        self.title = title
        self.command = command
        self.note = note
    }
}

public enum OverlayPaths {
    /// The owner control plane, anchored on the home directory recorded in the
    /// directory service (the passwd entry, not `$HOME` and not
    /// `CFFIXED_USER_HOME`). `HyperOverlayCore` has no dependencies, so this
    /// mirrors `OmniLayout.toolingRoot` rather than importing it; a test in
    /// `OmniAdaptersTests` asserts the two agree.
    public static let homeDirectory = directoryServiceHomeDirectory()
    public static let toolingRoot = homeDirectory
        .appendingPathComponent("Tooling", isDirectory: true)
    public static let keyboardMaestroRoot = toolingRoot.appendingPathComponent("keyboard-maestro", isDirectory: true)
    public static let commandReferenceJSON = keyboardMaestroRoot.appendingPathComponent("command-reference.json")

    public static var runtimeDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/DanielTooling/hyper-overlay", isDirectory: true)
    }

    public static var socketURL: URL {
        runtimeDirectory.appendingPathComponent("hyper-overlay.sock")
    }

    public static var lockURL: URL {
        runtimeDirectory.appendingPathComponent("hyper-overlay.lock")
    }
}

/// Resolves the effective user's home directory from the passwd entry, which
/// the process environment cannot redirect (Foundation's home directory honours
/// `CFFIXED_USER_HOME`). Identical to the copy in `OmniCore.OmniLayout`; kept
/// separate because this module has no dependencies. Failure is fatal because
/// every owner path below is untrustworthy without an anchor.
private func directoryServiceHomeDirectory() -> URL {
    var entry = passwd()
    var result: UnsafeMutablePointer<passwd>? = nil
    let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
    var capacity = suggested > 0 ? Int(suggested) : 4096
    var status: Int32 = ERANGE
    while status == ERANGE, capacity <= 1 << 20 {
        var buffer = [CChar](repeating: 0, count: capacity)
        status = getpwuid_r(getuid(), &entry, &buffer, buffer.count, &result)
        if status == 0, result != nil, let directory = entry.pw_dir, directory.pointee != 0 {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        capacity *= 4
    }
    fatalError("OverlayPaths: the current user's home directory could not be resolved from the directory service (getpwuid_r status \(status))")
}
