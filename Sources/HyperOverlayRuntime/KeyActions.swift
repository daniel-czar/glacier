import Foundation
import HyperOverlayCore

/// The former Keyboard Maestro utilities as direct actions (plan
/// f71f8baac8f0149e): Hyper R, O, J, S, T, P, W and G. One-to-one with the
/// KM macros except where the plan says otherwise.
public enum HyperKeyAction: String, Sendable, CaseIterable {
    case reveal
    case openNaturally
    case jumpToRoot
    case editInSublime
    case terminalHere
    case copyPath
    case fence
    case gatherFiles

    public init?(overlayID: String) {
        guard let action = Self.allCases.first(where: { $0.overlayID == overlayID }) else { return nil }
        self = action
    }

    public var overlayID: String {
        switch self {
        case .reveal: OverlayID.reveal
        case .openNaturally: OverlayID.openNaturally
        case .jumpToRoot: OverlayID.jumpToRoot
        case .editInSublime: OverlayID.editInSublime
        case .terminalHere: OverlayID.terminalHere
        case .copyPath: OverlayID.copyPath
        case .fence: OverlayID.fence
        case .gatherFiles: OverlayID.gatherFiles
        }
    }

    /// Where the text comes from when Finder is not in front.
    enum Input: Equatable {
        /// A fresh ⌘C, or the clipboard as it is when nothing new arrives
        /// (KM's behaviour: ⌘C on an empty selection leaves it alone).
        case selectionOrClipboard
        /// A fresh ⌘C only; a stale clipboard is refused.
        case selection
        /// The clipboard as it is; no ⌘C.
        case clipboard
    }

    var input: Input {
        switch self {
        case .copyPath: .clipboard
        case .fence: .selection
        default: .selectionOrClipboard
        }
    }

    /// S, T and P read the Finder selection when Finder is in front.
    public var readsFinder: Bool { self == .editInSublime || self == .terminalHere || self == .copyPath }
}

/// What an action ended in. `telemetry` is content-free: it names the
/// outcome, never a path or the copied text.
public enum KeyActionOutcome: Sendable, Equatable {
    case done(String, notice: String? = nil)
    case miss(String)
    case refused(String)
    case failed(String)
    case cancelled

    public var telemetry: String {
        switch self {
        case .done(let what, _): what
        case .miss(let why): "miss:\(why)"
        case .refused(let why): "refused:\(why)"
        case .failed(let why): "failed:\(why)"
        case .cancelled: "cancelled"
        }
    }
}

/// The Finder selection, read without ⌘C so the clipboard is left alone.
public enum FinderSelection: Sendable, Equatable {
    /// The selected items' POSIX paths.
    case items([String])
    /// Nothing selected; the folder Finder would insert into (the front
    /// window's, or the desktop's when the desktop is focused).
    case window(String)
    case nothing
    /// Automation was refused, or Finder did not answer in time.
    case unavailable(String)
}

/// The helpers stay the source of truth for extraction (plan §4).
public enum KeyActionHelper: Sendable, CaseIterable {
    case extractPath
    case extractURL
    case jumpRoot
    case fence
    case gather
}

/// A helper's answer. A miss (it found nothing) is not a failure (it timed
/// out, died or could not start): O must not guess a URL because a path
/// lookup was slow.
public enum HelperAnswer: Sendable, Equatable {
    case value(String)
    case none
    case failed
}

public enum ClipboardWrite: Sendable, Equatable {
    case written
    /// A newer copy arrived while the action worked; it wins, untouched.
    case stale
    case failed
}

public enum KeyActionApp: String, Sendable {
    case sublime = "com.sublimetext.4"
    case ghostty = "com.mitchellh.ghostty"

    public var displayName: String {
        switch self {
        case .sublime: "Sublime Text"
        case .ghostty: "Ghostty"
        }
    }
}

/// The platform side, injected so the actions are testable without keys,
/// Finder, helpers or other apps.
@MainActor
public protocol KeyActionEffects: AnyObject {
    func trusted() -> Bool
    func waitForHyperRelease() async -> Bool
    func copySelection(from target: PasteTarget, wait: Duration, isCurrent: @escaping @MainActor () -> Bool) async -> CollectCopy
    func clipboardText() -> String?
    /// The pasteboard's revision, read with the input so a write can tell
    /// whether a newer copy arrived meanwhile.
    func clipboardRevision() -> Int
    func finderSelection() async -> FinderSelection
    func helper(_ helper: KeyActionHelper, input: String) async -> HelperAnswer
    func directoryExists(_ path: String) -> Bool
    func open(_ urls: [URL], with app: KeyActionApp?) async -> Bool
    func reveal(_ urls: [URL]) -> Bool
    func writeClipboard(text: String, ifRevision revision: Int) -> ClipboardWrite
    func writeClipboard(files: [URL], ifRevision revision: Int) -> ClipboardWrite
    func showFailure(_ text: String)
    func showNotice(_ text: String)
}

/// One action at a time. Another Hyper chord, a newer foreground intent or
/// an app switch cancels the pending one, helper included. A second direct
/// action while one is pending answers `Busy`.
@MainActor
public final class KeyActionController {
    /// KM waited 0.2 s before falling back to the clipboard; Collect's 1 s
    /// would make "copy a path, then press R" feel slow.
    public static let fallbackWait: Duration = .milliseconds(300)
    public static let selectionWait: Duration = .milliseconds(1_000)

    private let effects: any KeyActionEffects
    public private(set) var busy = false
    private var generation = 0
    private var current: Task<KeyActionOutcome, Never>?
    /// False for P working from the clipboard: it needs no app, so an app
    /// switch does not cancel it; the revision guard protects a newer copy,
    /// as for Equalize.
    private var followsDestination = true

    public init(effects: any KeyActionEffects) {
        self.effects = effects
    }

    public func invalidate() {
        generation &+= 1
        if followsDestination { current?.cancel() }
    }

    /// Reserves the lane synchronously at the key press, so a second chord
    /// dispatched before the task runs still sees `busy`, and an app switch
    /// after the press cancels this action.
    /// - `target` is the app in front, nil when a host surface owns the
    ///   foreground.
    /// - `frontIsFinder` says whether Finder is the frontmost app, whoever
    ///   owns the foreground.
    @discardableResult
    public func start(_ action: HyperKeyAction, target: PasteTarget?, frontIsFinder: Bool) -> Task<KeyActionOutcome, Never> {
        guard !busy else {
            let outcome = report(.refused("Busy"))
            return Task { outcome }
        }
        busy = true
        followsDestination = true
        generation &+= 1
        let mine = generation
        let isCurrent: @MainActor () -> Bool = { [weak self] in self?.generation == mine && !Task.isCancelled }
        let task = Task { @MainActor [weak self] () -> KeyActionOutcome in
            guard let self else { return .cancelled }
            let outcome = await self.run(action, target: target, frontIsFinder: frontIsFinder, isCurrent: isCurrent)
            self.busy = false
            self.current = nil
            self.followsDestination = true
            return self.report(outcome)
        }
        current = task
        return task
    }

    @discardableResult
    public func perform(_ action: HyperKeyAction, target: PasteTarget?, frontIsFinder: Bool = false) async -> KeyActionOutcome {
        await start(action, target: target, frontIsFinder: frontIsFinder).value
    }

    private func report(_ outcome: KeyActionOutcome) -> KeyActionOutcome {
        switch outcome {
        case .done(_, let notice): if let notice { effects.showNotice(notice) }
        case .miss(let text), .refused(let text), .failed(let text): effects.showFailure(text)
        case .cancelled: effects.showFailure("Destination changed")
        }
        return outcome
    }

    static let noPath = "No path found"
    static let lookupFailed = "Lookup failed"

    /// The bezel when there is no text to work on at all.
    static func nothingFound(for action: HyperKeyAction) -> String {
        switch action {
        case .openNaturally: "No path or URL found"
        case .jumpToRoot: "No path root found"
        case .fence: "No selected text"
        case .gatherFiles: "No files found"
        case .reveal, .editInSublime, .terminalHere, .copyPath: noPath
        }
    }

    private func run(_ action: HyperKeyAction, target: PasteTarget?, frontIsFinder: Bool,
                     isCurrent: @escaping @MainActor () -> Bool) async -> KeyActionOutcome {
        if action.readsFinder, frontIsFinder {
            // Finder is in front but a host surface owns the foreground:
            // refuse rather than read a selection behind it.
            guard target != nil else { return .refused("No app to act on") }
            return await finderBranch(action, isCurrent: isCurrent)
        }
        let text: String
        let revision: Int
        var isCurrent = isCurrent
        switch action.input {
        case .clipboard:
            followsDestination = false
            isCurrent = { !Task.isCancelled }
            revision = effects.clipboardRevision()
            guard let current = effects.clipboardText() else { return .miss(Self.noPath) }
            text = current
        case .selection, .selectionOrClipboard:
            guard let target else { return .refused("No app to act on") }
            guard effects.trusted() else { return .refused("Accessibility access needed") }
            guard await effects.waitForHyperRelease() else { return isCurrent() ? .failed("Copy failed") : .cancelled }
            guard isCurrent() else { return .cancelled }
            let wait = action.input == .selection ? Self.selectionWait : Self.fallbackWait
            switch await effects.copySelection(from: target, wait: wait, isCurrent: isCurrent) {
            case .text(let copied):
                revision = effects.clipboardRevision()
                text = copied
            case .changed:
                return .cancelled
            case .failed:
                guard isCurrent() else { return .cancelled }
                revision = effects.clipboardRevision()
                guard action.input == .selectionOrClipboard, let current = effects.clipboardText() else {
                    return .miss(Self.nothingFound(for: action))
                }
                text = current
            }
        }
        guard isCurrent() else { return .cancelled }
        return await act(action, on: text, revision: revision, isCurrent: isCurrent)
    }

    /// A helper's value, or the outcome that ends the action: cancelled
    /// first (a cancel kills the helper, so its answer means nothing), then
    /// a failure, then the action's own miss.
    private func ask(_ helper: KeyActionHelper, _ text: String, miss: String,
                     isCurrent: @escaping @MainActor () -> Bool) async -> Result<String, Stop> {
        let answer = await effects.helper(helper, input: text)
        guard isCurrent() else { return .failure(Stop(.cancelled)) }
        switch answer {
        case .value(let value): return .success(value)
        case .none: return .failure(Stop(.miss(miss)))
        case .failed: return .failure(Stop(.failed(Self.lookupFailed)))
        }
    }

    struct Stop: Error {
        let outcome: KeyActionOutcome
        init(_ outcome: KeyActionOutcome) { self.outcome = outcome }
    }

    private func act(_ action: HyperKeyAction, on text: String, revision: Int,
                     isCurrent: @escaping @MainActor () -> Bool) async -> KeyActionOutcome {
        do {
            switch action {
            case .reveal:
                let path = try await ask(.extractPath, text, miss: Self.noPath, isCurrent: isCurrent).get()
                return effects.reveal([URL(fileURLWithPath: path)]) ? .done("revealed") : .failed("Couldn't reveal")
            case .openNaturally:
                return try await openNaturally(text, isCurrent: isCurrent)
            case .jumpToRoot:
                let root = try await ask(.jumpRoot, text, miss: "No path root found", isCurrent: isCurrent).get()
                return effects.reveal([URL(fileURLWithPath: root)]) ? .done("revealed-root") : .failed("Couldn't reveal")
            case .editInSublime:
                let path = try await ask(.extractPath, text, miss: Self.noPath, isCurrent: isCurrent).get()
                return await open([path], with: .sublime, isCurrent: isCurrent)
            case .terminalHere:
                let path = try await ask(.extractPath, text, miss: Self.noPath, isCurrent: isCurrent).get()
                return await open([folder(of: path)], with: .ghostty, isCurrent: isCurrent)
            case .copyPath:
                let path = try await ask(.extractPath, text, miss: Self.noPath, isCurrent: isCurrent).get()
                return written(effects.writeClipboard(text: path, ifRevision: revision), notice: "Path copied")
            case .fence:
                let fenced = try await ask(.fence, text, miss: "No selected text", isCurrent: isCurrent).get()
                return written(effects.writeClipboard(text: fenced, ifRevision: revision), notice: "Fenced")
            case .gatherFiles:
                let listing = try await ask(.gather, text, miss: "No files found", isCurrent: isCurrent).get()
                let paths = listing.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                guard !paths.isEmpty else { return .miss("No files found") }
                let notice = paths.count == 1 ? "1 file ready" : "\(paths.count) files ready"
                return written(effects.writeClipboard(files: paths.map { URL(fileURLWithPath: $0) }, ifRevision: revision),
                               notice: notice, done: "copied-files")
            }
        } catch let stop as Stop {
            return stop.outcome
        } catch {
            return .failed(Self.lookupFailed)
        }
    }

    private func written(_ write: ClipboardWrite, notice: String, done: String = "copied") -> KeyActionOutcome {
        switch write {
        case .written: .done(done, notice: notice)
        case .stale: .failed("Clipboard changed")
        case .failed: .failed("Copy failed")
        }
    }

    /// The order:
    /// - An explicit http(s) URL goes through `km-extract-url`, which trims
    ///   prose punctuation.
    /// - Any other explicit scheme (`file:`, `obsidian:`, `vscode:`) opens as
    ///   written, and `file:` opens as its path.
    /// - Text that reads as a web address (`example.com`,
    ///   `github.com/a/b`, `www.…`) tries the URL first, as KM did: a path
    ///   lookup can resolve `github.com/a/b` to a local folder.
    /// - Otherwise an existing path wins over a URL guess, so `notes.md` is
    ///   not opened as `https://notes.md` (plan §1, a deliberate change from
    ///   KM), and a failed path lookup never falls through to a guess.
    private func openNaturally(_ text: String, isCurrent: @escaping @MainActor () -> Bool) async throws -> KeyActionOutcome {
        let miss = "No path or URL found"
        if !MarkdownLocalLink.destinations(in: text).isEmpty {
            // A Markdown label is display text. Resolve its local destination
            // before URL and web-address guesses can act on the label.
            let path = try await ask(.extractPath, text, miss: miss, isCurrent: isCurrent).get()
            return await open(URL(fileURLWithPath: path), isCurrent: isCurrent)
        }
        if let range = text.range(of: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s<>"']+"#, options: .regularExpression) {
            let token = Self.trimmingProsePunctuation(String(text[range]))
            if let explicit = URL(string: token), let scheme = explicit.scheme?.lowercased() {
                if scheme == "http" || scheme == "https" {
                    let found = try await ask(.extractURL, text, miss: miss, isCurrent: isCurrent).get()
                    guard let url = URL(string: found) else { return .miss(miss) }
                    return await open(url, isCurrent: isCurrent)
                }
                return await open(explicit.isFileURL ? URL(fileURLWithPath: explicit.path) : explicit, isCurrent: isCurrent)
            }
        }
        if Self.looksLikeWebAddress(text) {
            switch await effects.helper(.extractURL, input: text) {
            case .value(let found):
                guard isCurrent() else { return .cancelled }
                if let url = URL(string: found) { return await open(url, isCurrent: isCurrent) }
            case .failed:
                return isCurrent() ? .failed(Self.lookupFailed) : .cancelled
            case .none:
                guard isCurrent() else { return .cancelled }
            }
        }
        switch await effects.helper(.extractPath, input: text) {
        case .value(let path):
            return await open(URL(fileURLWithPath: path), isCurrent: isCurrent)
        case .failed:
            return isCurrent() ? .failed(Self.lookupFailed) : .cancelled
        case .none:
            guard isCurrent() else { return .cancelled }
        }
        let found = try await ask(.extractURL, text, miss: miss, isCurrent: isCurrent).get()
        guard let url = URL(string: found) else { return .miss(miss) }
        return await open(url, isCurrent: isCurrent)
    }

    /// The domains people copy as bare addresses. `.md`, `.sh`, `.py` and
    /// `.rs` are country domains too, so the list is the common web ones,
    /// never "any TLD".
    static let webTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "ai", "app", "co", "edu", "gov", "info", "me", "so", "gg", "xyz",
        "tech", "uk", "de", "fr", "eu", "nl", "ch", "at", "se", "no", "dk", "es", "it", "us", "ca", "au", "jp",
    ]

    /// A whitespace-separated token whose host part (before any `/`) is a
    /// dotted name ending in a common web domain, or that starts with `www.`.
    /// Paths like `~/site.com/x` or `Projects/foo.io/a.md` do not count:
    /// their first segment has no dot.
    static func looksLikeWebAddress(_ text: String) -> Bool {
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let token = trimmingProsePunctuation(String(raw)).trimmingCharacters(in: CharacterSet(charactersIn: "(<[\"'"))
            if token.lowercased().hasPrefix("www.") { return true }
            guard let host = token.split(separator: "/", omittingEmptySubsequences: false).first,
                  host.contains("."), !host.hasPrefix("."), !host.hasPrefix("~")
            else { continue }
            let labels = host.split(separator: ".")
            if labels.count >= 2, let tld = labels.last?.lowercased(), webTLDs.contains(tld),
               labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) {
                return true
            }
        }
        return false
    }

    /// Prose punctuation after a URL is not part of it: `(see x://a).`.
    static func trimmingProsePunctuation(_ token: String) -> String {
        var token = token
        while let last = token.last, ").,;:!?]'\"".contains(last) { token.removeLast() }
        return token
    }

    private func open(_ url: URL, isCurrent: @escaping @MainActor () -> Bool) async -> KeyActionOutcome {
        guard isCurrent() else { return .cancelled }
        return await effects.open([url], with: nil) ? .done("opened") : .failed("Couldn't open")
    }

    private func open(_ paths: [String], with app: KeyActionApp, isCurrent: @escaping @MainActor () -> Bool) async -> KeyActionOutcome {
        guard isCurrent() else { return .cancelled }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        return await effects.open(urls, with: app) ? .done("opened") : .failed("Couldn't open \(app.displayName)")
    }

    private func folder(of path: String) -> String {
        effects.directoryExists(path) ? path : (path as NSString).deletingLastPathComponent
    }

    /// Finder in front (S, T, P): its selection, read without ⌘C.
    private func finderBranch(_ action: HyperKeyAction, isCurrent: @escaping @MainActor () -> Bool) async -> KeyActionOutcome {
        let revision = effects.clipboardRevision()
        // Not cancelled with the action: the first query raises the
        // Automation prompt, and killing osascript under it could withdraw
        // the prompt. It runs to its bound; a stale answer is discarded below.
        let effects = self.effects
        let selection = await Task { @MainActor in await effects.finderSelection() }.value
        guard isCurrent() else { return .cancelled }
        switch (action, selection) {
        case (_, .unavailable(let why)):
            return .failed(why)
        case (.editInSublime, .items(let paths)):
            return await open(paths, with: .sublime, isCurrent: isCurrent)
        case (.editInSublime, _):
            return .miss("No file selected")
        case (.terminalHere, .items(let paths)):
            return await open([folder(of: paths[0])], with: .ghostty, isCurrent: isCurrent)
        case (.terminalHere, .window(let folder)):
            return await open([folder], with: .ghostty, isCurrent: isCurrent)
        case (.terminalHere, .nothing):
            return await open([OverlayPaths.homeDirectory.path], with: .ghostty, isCurrent: isCurrent)
        case (.copyPath, .items(let paths)):
            let notice = paths.count == 1 ? "Path copied" : "\(paths.count) paths copied"
            return written(effects.writeClipboard(text: paths.joined(separator: "\n"), ifRevision: revision), notice: notice)
        case (.copyPath, .window(let folder)):
            return written(effects.writeClipboard(text: folder, ifRevision: revision), notice: "Path copied")
        default:
            return .miss("Nothing selected")
        }
    }
}

/// Content-free fire records for every direct action, in `hyper-overlay
/// status` as `direct_actions`: did the chord arrive, and how did it end.
@MainActor
public final class DirectActionTelemetry {
    private struct Entry {
        var count = 0
        var last: Date?
        var outcome: String?
        var openToken: Int?
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var nextToken = 0
    private let formatter = ISO8601DateFormatter()

    public init() {}

    /// Counts the press and opens a record for it, unless a press of the
    /// same chord is still open: that one keeps the record, so a second press
    /// refused while it runs can neither take nor drop its outcome.
    @discardableResult
    public func fired(_ id: String, at date: Date = Date()) -> Int {
        nextToken += 1
        var entry = entries[id] ?? Entry()
        entry.count += 1
        entry.last = date
        if entry.openToken == nil {
            entry.outcome = "pending"
            entry.openToken = nextToken
        }
        entries[id] = entry
        order.removeAll { $0 == id }
        order.append(id)
        return nextToken
    }

    /// Closes the record if this press still owns it.
    public func finished(_ id: String, token: Int, outcome: String) {
        guard var entry = entries[id], entry.openToken == token else { return }
        entry.outcome = outcome
        entry.openToken = nil
        entries[id] = entry
    }

    /// A failure reported without its id: it belongs to the most recently
    /// fired open record among `ids`.
    public func failLatestOpen(among ids: Set<String>, outcome: String) {
        guard let id = order.last(where: { ids.contains($0) && entries[$0]?.openToken != nil }),
              let token = entries[id]?.openToken
        else { return }
        finished(id, token: token, outcome: outcome)
    }

    public var facts: [String: String] {
        entries.mapValues { entry in
            let last = entry.last.map { formatter.string(from: $0) } ?? "-"
            return "count=\(entry.count) last=\(last) outcome=\(entry.outcome ?? "-")"
        }
    }
}
