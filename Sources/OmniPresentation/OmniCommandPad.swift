import AppKit
import CoreText
import OmniCore
import SwiftUI

// MARK: - Vocabulary

/// The route line speaks in outcomes (C21): what will exist, in which style,
/// through which provider. Tokens the manifest may add later fall back to
/// their own name.
public enum OmniPadVocabulary {
    public static func outcome(for token: String) -> String {
        switch token {
        case "/email": "Email draft"
        case "/msg": "Message draft"
        case "/qq": "Answer"
        case "/translate": "Translation"
        case "/slug": "URL slug"
        case "/stance": "Positions"
        case "/structure": "Structure"
        case "/expand": "Expansion"
        case "/meaning": "Meaning"
        case "/g": "Google search"
        case "/open": "Open"
        case "/rv": "Reveal in Finder"
        case "/todo": "Todo · optional adapter"
        case "/remind": "Reminder · optional adapter"
        case "/fav": "Favourite"
        case "/stash": "Stash"
        case "/weather": "Weather"
        case "/capture": "Capture"
        case "/find": "Find"
        case "/span": "Time span"
        case "/settings": "Settings"
        case "/model": "Model settings"
        case "/workspace": "Workspace"
        case "/shorter": "Shorter"
        default: String(token.dropFirst()).capitalized
        }
    }

    /// One line per command in the completion menu (C25, C78).
    public static func description(for token: String) -> String {
        switch token {
        case "/email": "Draft an email reply"
        case "/msg": "Draft a message"
        case "/qq": "Ask a quick question"
        case "/translate": "Translate the supplied text"
        case "/slug": "Name a URL slug"
        case "/stance": "Decide how to respond or approach"
        case "/structure": "Structure a thought"
        case "/expand": "Expand through a lens"
        case "/meaning": "Pin down what a term means"
        case "/g": "Search Google"
        case "/open": "Open a target"
        case "/rv": "Reveal a target in Finder"
        case "/todo": "Add a task"
        case "/remind": "Add a reminder"
        case "/fav": "Capture a link through a configured adapter"
        case "/stash": "Push onto the stash, or import an entry"
        case "/weather": "Show weather for here or a place"
        case "/capture": "Save a note"
        case "/find": "Find documents by id, by picked filters, or in words"
        case "/span": "Time between dates, time since a date, or a date offset"
        case "/retrieve": "Same as /find"
        case "/settings": "Open settings"
        case "/model": "Per-command models"
        case "/workspace": "Open the workspace"
        case "/offline": "Local models for this run"
        case "/style": "Style modifier"
        case "/formal": "Formal style"
        case "/shorter": "Shorten the result"
        default: ""
        }
    }

    /// The help column's paragraph for one command (C78). Facts only: what
    /// runs, where the result goes, what is never done. Argument shapes come
    /// from the manifest through `usage(for:valueTypes:)`, not from here.
    public static func help(for token: String) -> String {
        switch token {
        case "/email": "Drafts an email reply from the text in the pad. Nothing is sent: the draft comes back to copy or edit."
        case "/msg": "Drafts a short message. Nothing is sent."
        case "/qq": "Answers a quick question directly and says when it is unsure."
        case "/translate": "Detects the source and translates into English unless a target is given. Keeps code, names and numbers."
        case "/slug": "Turns the text into a short lowercase hyphenated URL slug."
        case "/stance": "Reads the material and offers three or four positions you could take, plus things it noticed. Picking a position can start the draft."
        case "/structure": "Orders rambling thoughts into structured prose and names what they circle."
        case "/expand": "Expands one idea through a lens, a paragraph or two. Bare /expand lists the five lenses first; nothing runs until you pick."
        case "/meaning": "Pins down what a term means at its core, then lists nearby terms and how each differs."
        case "/g": "Opens a Google search for the text in your default browser. The pad closes when the browser opens."
        case "/open": "Opens an enabled document or run in its default app by id or @reference."
        case "/rv": "Reveals an enabled document or run in Finder by id or @reference."
        case "/todo": "Adds a task through a configured adapter; unavailable by default."
        case "/remind": "Adds a reminder through a configured adapter; unavailable by default. It schedules nothing."
        case "/fav": "Saves a link through a configured adapter; unavailable by default."
        case "/stash": "Pushes the text onto the stash, five deep (⌘Y does it too); the oldest drops. Alone it imports the top entry, /stash:2 to :5 the others."
        case "/weather": "Shows four weather facts for the entered place, or here when empty. Only the last reading is cached."
        case "/capture": "Saves a Markdown note in your chosen folder or Glacier storage."
        case "/find": "An id lists its document and run; picked filters such as kind:review run on this Mac; words become a filter query a model writes, never seeing the results."
        case "/span": "Time between dates, time since one date, or an offset such as 5 months after 19 oct 2026. Use before to subtract; excl excludes a range's last day. Enter shows the result; Enter again copies it."
        case "/settings": "Opens Glacier Settings."
        case "/model": "Opens settings at the per-command model assignments."
        case "/workspace": "Opens the existing Glacier workspace window."
        case "/offline": "Keeps this run on local models. A command with no local path stops instead of reaching the network."
        case "/style": "Shapes a draft's register. Only formal exists for now; /formal is its short form."
        case "/shorter": "Shortens a workspace result into a new version of that run. Bare means a third to a half shorter; 25% keeps a quarter of the length."
        default: ""
        }
    }

    /// The help column's kind line: what the command reaches for.
    public static func kind(for command: ManifestCommand) -> String {
        switch command.role {
        case .settings: "Settings"
        case .mode: "Mode · this run only"
        case .modifier: "Modifier"
        case .alias: "Alias"
        case .primary:
            switch command.execution {
            case .modelBacked where command.capabilities.contains(.readIndex):
                // `/find` (D2): ids and filters stay on this Mac; only words ask a model.
                "Command · local, words may ask a model"
            case .modelBacked:
                command.acceptedModes.contains("/offline") ? "Command · runs a model, or local with /offline" : "Command · runs a model"
            case .deterministicLocal:
                // /g reaches the network for the browser, so it is not "local".
                command.capabilities.contains(.openURL) ? "Command · opens your browser" : "Command · runs locally"
            case .settings: "Settings"
            case .policy: "Command · follow-up"
            }
        }
    }

    /// Argument shapes from the manifest, one line each, so the help column
    /// stays true when the manifest changes.
    public static func usage(for command: ManifestCommand, valueTypes: ManifestValueTypes) -> [String] {
        var lines: [String] = []
        if let value = command.value {
            // The shape once, then the members without the token so the
            // column wraps at the separators and never inside a token.
            let placeholder: String
            let members: [String]
            switch value.type {
            case .langcode:
                placeholder = "lang"
                members = valueTypes.langcode?.codes ?? []
            case .enumRegistry:
                let registry = value.registry ?? "value"
                placeholder = registry == OmniDecisionStep.expandLensRegistry ? "lens" : registry == "stash" ? "n" : registry
                members = valueTypes.enums[registry] ?? []
            case .length:
                placeholder = "length"
                members = (valueTypes.length?.units ?? []).map { unit in
                    switch unit {
                    case "%": "25%"
                    case "w": "120w"
                    case "s": "3s"
                    default: "<n>\(unit)"
                    }
                }
            case .int:
                placeholder = "n"
                members = []
            case .time:
                placeholder = "time"
                members = []
            }
            lines.append("\(command.token):<\(placeholder)>" + (value.required ? "" : " (optional)"))
            if !members.isEmpty { lines.append(members.joined(separator: " · ")) }
        }
        // Modes live on the kind line (every model-backed command takes
        // /offline, and a line per command would push the column past the
        // room a laptop leaves above the pad); modifiers are the news here.
        if !command.acceptedModifiers.isEmpty { lines.append("With " + command.acceptedModifiers.joined(separator: " · ")) }
        return lines
    }

    /// Modifiers in words: `/style:formal` → "formal", `/shorter:25%` → "shorter 25%".
    public static func modifierWords(_ intent: ParsedIntent) -> [String] {
        intent.modifiers.map { modifier in
            if let colon = modifier.firstIndex(of: ":") {
                let name = String(modifier[modifier.index(after: modifier.startIndex)..<colon])
                let value = String(modifier[modifier.index(after: colon)...])
                return name == "style" ? value : "\(name) \(value)"
            }
            return String(modifier.dropFirst())
        }
    }
}

/// A compiled contributor route projected into the pad without importing a
/// module package or teaching the pad any module-specific dispatch rules.
public struct OmniContributedSlashRoute: Sendable, Equatable {
    public let token: String
    public let toolID: String
    public let title: String
    public let detail: String

    public init(token: String, toolID: String, title: String, detail: String) {
        self.token = token
        self.toolID = toolID
        self.title = title
        self.detail = detail
    }
}

// MARK: - Renderer-neutral pad state

/// The effective model route for the typed command, resolved by the host.
public struct OmniPadRoute: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case policyDefault
        case savedOptIn
        case thisRunOnly
    }

    /// "Cerebras", "Local", "Sample replies" — nil for deterministic commands.
    public let providerName: String?
    /// Resolved provider and tier for the model chevron's read-only tooltip.
    public let displayName: String?
    public let scope: Scope
    /// The attention line when nothing can dispatch (C30).
    public let unavailable: String?
    public let recoveryHint: String?
    public let offersSettings: Bool

    public init(providerName: String?, scope: Scope = .policyDefault, displayName: String? = nil, unavailable: String? = nil, recoveryHint: String? = nil, offersSettings: Bool = false) {
        self.providerName = providerName
        self.displayName = displayName
        self.scope = scope
        self.unavailable = unavailable
        self.recoveryHint = recoveryHint
        self.offersSettings = offersSettings
    }
}

public enum OmniPadRouteLine: Equatable, Sendable {
    case hint(String)
    case outcome(String)
    /// Transient; the next keystroke clears it (C27, C29).
    case notice(String)
    /// An unknown or combined command: Enter asks for a proposal (C26).
    case propose(String)
    /// Not ready (C67): a human reason, with a recovery hint when available.
    case attention(String)
    /// A proposal is being asked for (H2).
    case waiting(String)

    public var text: String {
        switch self {
        case .hint(let text), .outcome(let text), .notice(let text), .propose(let text), .attention(let text), .waiting(let text): text
        }
    }
}

public struct OmniPadKeyHint: Equatable, Sendable {
    public let key: String
    public let label: String
    /// A key whose meaning the current text has changed, drawn in the mode tint.
    public let emphasized: Bool
    public init(_ key: String, _ label: String, emphasized: Bool = false) {
        self.key = key
        self.label = label
        self.emphasized = emphasized
    }

    /// Tab names the tool it opens (quick-launch §1), in place of the lane's own Tab hint.
    public static func quickLaunch(_ tool: OmniQuickLaunch, over hints: [OmniPadKeyHint]) -> [OmniPadKeyHint] {
        [.init("⇥", tool.title, emphasized: true)] + hints.filter { $0.key != "⇥" }
    }

    public static let run: [OmniPadKeyHint] = [.init("↩", "Run"), .init("⌘↩", "Open in workspace"), .init("esc", "")]
    public static let propose: [OmniPadKeyHint] = [.init("↩", "Propose"), .init("esc", "")]
    public static let completion: [OmniPadKeyHint] = [.init("⇥", "Complete"), .init("↩", "Run"), .init("esc", "Close menu")]
    /// The palette over a field that submits nothing, such as a bare `/` (C78).
    public static let completionBrowse: [OmniPadKeyHint] = [.init("⇥", "Complete"), .init("↑↓", "Browse"), .init("esc", "Close menu")]
    public static let pronunciation: [OmniPadKeyHint] = [.init("↩", "Open panel"), .init("esc", "")]
    public static let clipboard: [OmniPadKeyHint] = [.init("↩", "Open history"), .init("esc", "")]
    public static let calculator: [OmniPadKeyHint] = [.init("↩", "Copy and close"), .init("esc", "")]
    public static let dismissOnly: [OmniPadKeyHint] = [.init("esc", "")]
    public static let chooser: [OmniPadKeyHint] = [.init("↩", "Run selected"), .init("1–3", ""), .init("esc", "Dismiss")]
    public static let working: [OmniPadKeyHint] = [.init("esc", "Continue in background")]
    public static let textResult: [OmniPadKeyHint] = [.init("↩", "Copy and close"), .init("⌘↩", "Open in workspace"), .init("esc", "Close")]
    public static let confirmationResult: [OmniPadKeyHint] = [.init("↩", "Close"), .init("⌘↩", "Open in workspace"), .init("esc", "Close")]
    public static let failureResult: [OmniPadKeyHint] = [.init("⌘↩", "Open in workspace"), .init("esc", "Close")]
    public static let proposalResult: [OmniPadKeyHint] = [.init("↩", "Run selected"), .init("1–3", ""), .init("⌘↩", "Open in workspace"), .init("esc", "Close")]
    /// A launcher row is the Enter target (H10).
    public static let launch: [OmniPadKeyHint] = [.init("↩", "Open"), .init("⌘↩", "Reveal"), .init("esc", "")]
    /// A `/find` picker (D2): the launcher's chords on result rows.
    public static let picker: [OmniPadKeyHint] = [.init("↩", "Open"), .init("⌘↩", "Reveal"), .init("⌥⌘C", "Copy path"), .init("esc", "Close")]
    public static let pickerEmpty: [OmniPadKeyHint] = [.init("↩", "Close"), .init("esc", "Close")]
    /// An exact-id hit (D1): Finder's chords, ⌥⌘C being Copy as Pathname.
    public static let idLane: [OmniPadKeyHint] = [.init("↩", "Open"), .init("⌘↩", "Reveal"), .init("⌥⌘C", "Copy path"), .init("esc", "")]
    /// Launcher rows are visible but none is the Enter target (H10).
    public static let launcherPropose: [OmniPadKeyHint] = [.init("↩", "Propose"), .init("↓", "Pick"), .init("esc", "")]
}

/// The provenance strip (C19): where the imported text came from.
public struct OmniPadProvenance: Equatable, Sendable {
    /// The source app's name; it also picks the offer row's wording (C77).
    public let source: String
    /// The window title at capture time.
    public let detail: String?
    public let wordCount: Int
    /// The source app's bundle identifier, for its icon (D3).
    public let bundleIdentifier: String?
    /// A stash import's chip (C96) draws this symbol instead of an app icon
    /// and reads `Stash 2 · Recall` instead of `From …`.
    public let symbolName: String?
    /// Replaces the word count (`1 line` for a stash entry).
    public let meta: String?

    public init(source: String, detail: String? = nil, wordCount: Int, bundleIdentifier: String? = nil, symbolName: String? = nil, meta: String? = nil) {
        self.source = source
        self.detail = detail
        self.wordCount = wordCount
        self.bundleIdentifier = bundleIdentifier
        self.symbolName = symbolName
        self.meta = meta
    }

    /// The same line the workspace header draws (one formatter, D3).
    public var line: OmniProvenanceLine? {
        OmniProvenanceLine(appName: source, windowTitle: detail, bundleIdentifier: bundleIdentifier)
    }

    /// `From Mail “Mira Chen”`; the title is dropped when it repeats the app.
    public var label: String {
        if symbolName != nil { return [source, detail].compactMap { $0 }.joined(separator: " · ") }
        return line?.text ?? source
    }
}

/// An entry `/stash` or `/stash:N` imports as source (C43, C96). The host
/// resolves the position; the pad keeps the atom that named it.
public struct OmniPadStashImport: Equatable, Sendable {
    public let position: Int
    public let literal: String
    public let text: String
    public let source: String
    public let lineCount: Int

    public init(position: Int, literal: String = "", text: String, source: String, lineCount: Int) {
        self.position = position
        self.literal = literal
        self.text = text
        self.source = source
        self.lineCount = lineCount
    }

    public func with(literal: String) -> OmniPadStashImport {
        OmniPadStashImport(position: position, literal: literal, text: text, source: source, lineCount: lineCount)
    }

    /// `Stash 2 · Recall`; a bare `/stash` reads `Stash · Recall`.
    public var chipLabel: String { "\(literal == OmniStashCommand.token ? "Stash" : "Stash \(position)") · \(source)" }

    public var chip: OmniPadProvenance {
        OmniPadProvenance(
            source: literal == OmniStashCommand.token ? "Stash" : "Stash \(position)", detail: source,
            wordCount: text.split(whereSeparator: \.isWhitespace).count, symbolName: "archivebox",
            meta: "\(lineCount) line\(lineCount == 1 ? "" : "s")"
        )
    }
}

/// One typed alternative of a proposal (C26), drawn with its real tokens.
public struct OmniPadAlternative: Equatable, Sendable {
    public let id: String
    public let planHash: String
    public let title: String
    /// Canonical command texts, in order.
    public let steps: [String]

    public init(id: String, planHash: String, title: String, steps: [String]) {
        self.id = id
        self.planHash = planHash
        self.title = title
        self.steps = steps
    }
}

/// The pad's four states (H11). A proposal is one result kind, not a parallel
/// state machine. The run ID binds keyboard actions to the visible run.
public enum OmniPadMode: Equatable, Sendable {
    case composing
    case suggesting
    case working(runID: String)
    case result(runID: String)
}

public enum OmniPadResultKind: Equatable, Sendable {
    case text
    case confirmation
    case failure(retryAllowed: Bool)
    case proposal
    /// Positions or lenses (amendment 1.4.0): Enter or a digit picks, esc
    /// closes, ⌘↩ opens the workspace. Never copies (C55 amended).
    case options
    /// A `/find` result (amendment 1.5.0, D2): file rows. ↩ opens the
    /// highlighted row, ⌘↩ reveals it, ⌥⌘C copies its path, esc closes.
    case picker
}

/// A complete display value. `body` stays intact even when the body scrolls;
/// Enter delegates the full-copy operation to the host.
public struct OmniPadResult: Equatable, Sendable {
    public let kind: OmniPadResultKind
    public let body: String
    public let summary: String

    public init(kind: OmniPadResultKind, body: String, summary: String) {
        self.kind = kind
        self.body = body
        self.summary = summary
    }
}

/// What the footer shows for a given parse (pure, testable).
public struct OmniPadFooterState: Equatable, Sendable {
    public let routeLine: OmniPadRouteLine
    public let keyHints: [OmniPadKeyHint]
    public let runEnabled: Bool
    /// Whether Enter submits anything at all.
    public let submits: Bool
}

// MARK: - Controller

@MainActor public final class OmniCommandPadViewController: NSViewController, NSTextViewDelegate {
    public static let preferredWidth: CGFloat = 640
    public static let emptyHint = "Type / for commands, or paste text first"
    public static let addCommandHint = "Add a command to this text"
    public static let typingHint = "Type a command"
    public static let waitingLine = "Asking for a proposal…"
    public static let choosingLine = "Proposal · nothing has run yet"

    public let editor = OmniCommandTextView()
    /// The route line (C21), under its historical name for hosts and tests.
    public let statusLabel = NSTextField(wrappingLabelWithString: "")
    public let notesButton = OmniPadInlineButton(title: "0 notes")
    /// Honesty about fixture data lives in the route line's provider word;
    /// this label stays readable for hosts but is not shown.
    public let developmentLabel: NSTextField
    /// The one-invocation model override: routing data for the next submit only.
    /// Pull-down title stays a chevron; the chosen ID is held separately.
    public let modelPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    public let modelOverrideLabel = NSTextField(labelWithString: "")
    public let clearModelButton = OmniPadInlineButton(title: "×")
    public let runButton = OmniPadRunButton()
    public let settingsButton = OmniPadInlineButton(title: "Open settings")
    public let keyHintsView = OmniKeyHintsView()
    public let provenanceChip = OmniProvenanceChip()
    public let wordCountLabel = NSTextField(labelWithString: "")

    public var onSubmit: ((String, OmniSubmitGesture) -> Void)?
    /// `/pron` opens the native disposable panel; the term is never submitted
    /// through the durable Omni command path.
    public var onPronunciationRequested: ((String) -> Void)?
    public var onExpressRequested: ((String) -> Void)?
    public var onRecallRequested: ((String) -> Void)?
    public var onRatioRequested: ((String) -> Void)?
    public var onCharactersRequested: ((String) -> Void)?
    public var onMapRequested: ((String) -> Void)?
    public var onWeatherRequested: ((String) -> Void)?
    public var onQRRequested: ((String) -> Void)?
    public var onRegexRequested: ((String) -> Void)?
    /// The abbreviation registry (quick-launch §1). Empty, or without a handler, Tab and
    /// the hints keep their ordinary meaning.
    public var quickLaunchTools: [OmniQuickLaunch] = [] { didSet { if isViewLoaded { renderVisibleText() } } }
    /// The effective app catalogue projects only usable actions into active help.
    public var isActionAvailable: @MainActor (String) -> Bool = { _ in true } {
        didSet { if isViewLoaded { dismissCompletion(); renderFooter() } }
    }
    /// Tab on an exact abbreviation: the host replaces the pad with the tool.
    public var onQuickLaunch: ((OmniQuickLaunch) -> Void)?
    public var contributedSlashRoutes: [OmniContributedSlashRoute] = [] {
        didSet { if isViewLoaded { dismissCompletion(); renderFooter() } }
    }
    /// `nil` leaves an unknown slash token to the ordinary parser.
    public var onContributedSlashRequested: ((String) -> Bool?)?
    /// Local routes are consumed by the host; neither submits an Omni run.
    public var onClipboardRequested: ((String) -> Void)?
    public var onCalculatorCopy: ((String) -> Void)?
    public var onAnnotationsChanged: (([OmniTextAnnotation]) -> Void)?
    public var annotations: [OmniTextAnnotation] { editor.annotations }
    public var onEscape: (() -> Void)?
    public var onOpenSettings: ((Bool) -> Void)?
    public var onOpenWorkspace: (() -> Void)?
    public var onRequestReferenceChoices: ((String) -> [OmniReferenceChoice])?
    /// Legacy string route, used by the tiles host; prefer `onResolveRoute`.
    public var onResolveModelRoute: ((String, String?) -> String?)?
    /// The typed route for the parsed command and one-invocation profile.
    public var onResolveRoute: ((ParsedIntent, String?) -> OmniPadRoute?)?
    /// The chip's × : the host drops the imported text and its provenance.
    public var onClearProvenance: (() -> Void)?
    /// Enter (or the ↑ button) on a chosen alternative: run it (C26).
    public var onConfirmProposal: ((String, String) -> Void)?
    /// esc in the chooser: the proposal is dismissed, nothing has run.
    public var onDismissProposal: ((String) -> Void)?
    public var onCopyResult: ((String) -> Void)?
    public var onCloseResult: ((String) -> Void)?
    public var onOpenResult: ((String) -> Void)?
    public var onRetryResult: ((String) -> Void)?

    // MARK: Launcher (H10, C50–C52)

    /// Set by a host that composes the file-finder fast lane. Off: bare text
    /// behaves exactly as before (*Add a command to this text*).
    public var launcherEnabled = false { didSet { if isViewLoaded { refreshLauncherMode(textChanged: false) } } }
    /// Home directory for `~/…` row subtitles, from the launcher configuration.
    public var launcherHome = ""
    /// Per keystroke: the host queries asynchronously and calls `showLauncherResults`.
    public var onLauncherQuery: ((String) -> Void)?
    /// Synchronous query, used at Enter when the shown rows are for older text.
    public var onResolveLauncher: ((String) -> LauncherResults?)?
    /// Enter (or Cmd+Enter) on a row: candidate id, open or reveal, evidence.
    public var onLaunch: ((String, LauncherOpenAction, LaunchContext) -> Void)?
    /// Whether an id miss may only mean the index is still loading (D1).
    public var onIDLookupPending: (() -> Bool)?
    /// ⌥⌘C on a file row: the host writes the path to the pasteboard.
    public var onCopyPath: ((String) -> Void)?
    /// Enter with no ready or selected row, just before the Tier 2 submit.
    public var onLauncherFallthrough: ((LaunchContext) -> Void)?
    /// Why the launcher cannot answer (index loading or unavailable); nil when healthy.
    public var onLauncherHealth: (() -> String?)?
    public internal(set) var launcherState: OmniLauncherPadState?
    public internal(set) var launcherLane: LauncherLane = .curated
    public let launcherScopeChip = OmniLauncherScopeChip()
    var launcherQueryStartedAt: Date?
    var launcherView: NSView?
    var launcherRowViews: [OmniLauncherRowView] = []

    public private(set) var provenance: OmniPadProvenance?
    public private(set) var submittedProvenance: OmniPadProvenance?
    /// Resolves a stash position (1 = top) to its entry; nil when empty.
    public var onResolveStashImport: ((Int) -> OmniPadStashImport?)?
    /// The entry the field's `/stash` or `/stash:N` imports, when it resolves.
    public private(set) var stashImport: OmniPadStashImport?
    /// An import atom that names no entry: painted unresolved (C96).
    public private(set) var unresolvedStashAtom: String?
    public internal(set) var mode: OmniPadMode = .composing
    public internal(set) var result: OmniPadResult?
    public private(set) var submittedRequestText = ""
    private var workingSummary = "Working…"
    public let submittedRequestView = OmniPadReadOnlyTextView()
    public let resultTextView = OmniPadReadOnlyTextView()
    public private(set) var resultScrollView: NSScrollView?
    public private(set) var alternatives: [OmniPadAlternative] = []
    public private(set) var chosenIndex = 0
    private var chooserView: NSView?
    private var chooserRows: [OmniProposalRow] = []
    // Options results and the offer row (decision step, OmniOptionsPad.swift).
    public internal(set) var options: OmniPadOptions?
    public internal(set) var optionIndex = 0
    /// A `/find` picker's rows and highlight (D2).
    public internal(set) var pickerRows: [OmniFindRow] = []
    public internal(set) var pickerIndex = 0
    var pickerView: NSView?
    var pickerRowViews: [OmniLauncherRowView] = []
    /// A picker row action: run ID, the row's index in the receipt, action.
    public var onPickerAction: ((String, Int, OmniPickerAction) -> Void)?
    public internal(set) var tickedNoticed: Set<Int> = []
    var optionsView: NSView?
    var optionRows: [OmniOptionRow] = []
    var noticedRows: [OmniNoticedRow] = []
    var offerRowView: OmniOfferRow?
    /// A local options result (bare `/expand`) answers its own pick.
    var localOptionsPick: ((Int, OmniPadPickGesture) -> Void)?
    /// Enter or a digit on an option: run ID, option index, ticked noticed
    /// indices, and whether the person asked to edit first (D6).
    public var onPickOption: ((String, Int, [Int], OmniPadPickGesture) -> Void)?
    private var resultFade: NSView?
    private var workingView: NSView?
    private var submittedRequestScrollView: NSScrollView?
    private let retryButton = OmniPadInlineButton(title: "Retry")
    public private(set) var footerState = OmniPadFooterState(routeLine: .hint(emptyHint), keyHints: OmniPadKeyHint.run, runEnabled: false, submits: false)
    public var routeLine: OmniPadRouteLine { footerState.routeLine }
    /// The palette's rows (C78): each choice with its role tint and help.
    public internal(set) var completionItems: [OmniCompletionItem] = []
    /// `/find`'s facet vocabulary for the completion menu (D2), from the
    /// loaded docs index; nil until it has loaded (facets then list no values).
    public var onRequestFindFacets: (() -> FindFacets?)?
    /// The top of the usable screen for the palette; tests pin it, the host
    /// reads the pad's screen.
    var completionScreenTop: CGFloat?
    public var completionChoices: [OmniReferenceChoice] { completionItems.map(\.choice) }
    public internal(set) var completionIndex = 0
    public private(set) var completionMenu: OmniCompletionMenu?
    public private(set) var editorScrollView: NSScrollView?
    public var isCompletionVisible: Bool { !completionItems.isEmpty }
    public private(set) var selectedModelProfileID: String?

    let parser: OmniParser
    private var modelChoices: [OmniModelChoice] = []
    private var applyingRewrite = false
    /// The abbreviation the field was last tinted for; a caret move re-tints.
    private var renderedQuickLaunch: OmniQuickLaunch?
    private var localToolRequestSubmitted = false
    private var updatingTextPresentation = false
    private lazy var annotationUI = OmniAnnotationUI(editor: editor)
    private var referencePicker: OmniReferencePicker?
    var transientMessage: String?
    private let footerSeparator = NSBox()
    private var editorHeight: CGFloat = 52
    private var footerHeight: CGFloat = 44
    private var resultContentHeight: CGFloat = 0
    var bodyHeight: CGFloat = 0

    public init(parser: OmniParser, developmentIndicator: String = "DEVELOPMENT · PURE FAKE · NO LIVE DATA") {
        self.parser = parser
        developmentLabel = NSTextField(labelWithString: developmentIndicator)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: View

    public override func loadView() {
        let root = OmniMaterialView(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: 108))
        root.setAccessibilityIdentifier("omni.command-pad-content")
        developmentLabel.isHidden = true
        developmentLabel.setAccessibilityIdentifier("omni.development-indicator")

        provenanceChip.setAccessibilityIdentifier("omni.pad.provenance")
        provenanceChip.onClear = { [weak self] in
            guard let self else { return }
            // × on a stash chip drops the import, never the entry (C96).
            if self.stashImport != nil { self.removeStashImportAtom() } else { self.onClearProvenance?() }
        }
        provenanceChip.isHidden = true
        launcherScopeChip.isHidden = true
        launcherScopeChip.setAccessibilityIdentifier("omni.pad.everywhere")
        wordCountLabel.font = .systemFont(ofSize: 11)
        wordCountLabel.textColor = OmniFrostedStyle.secondaryInk
        wordCountLabel.alignment = .right
        wordCountLabel.isHidden = true
        wordCountLabel.setAccessibilityIdentifier("omni.pad.word-count")

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        editor.frame = scroll.bounds
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 40)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 2, height: 7)
        editor.textContainer?.lineFragmentPadding = 0
        editor.drawsBackground = false
        editor.isRichText = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = OmniFrostedStyle.commandFont
        editor.textColor = OmniFrostedStyle.ink
        editor.insertionPointColor = .controlAccentColor
        editor.delegate = self
        editor.installAnnotationTracking()
        // No ghost text: the pad opens empty, like Spotlight.
        editor.setAccessibilityIdentifier("omni.command-editor")
        editor.setAccessibilityLabel("Glacier command text. Visible text determines routing and authority.")
        editor.onSubmit = { [weak self] gesture in self?.submit(gesture) }
        editor.onStashChord = { [weak self] in self?.stashChord() ?? false }
        editor.onEscape = { [weak self] in self?.annotationUI.closeAll(); self?.onEscape?() }
        editor.onEscapeMenu = { [weak self] in
            guard let self else { return false }
            guard self.isCompletionVisible else { return false }
            self.dismissCompletion()
            return true
        }
        editor.onTab = { [weak self] in
            guard let self else { return false }
            if self.acceptCompletion() { return true }
            // After `/find `, Tab asks for the filter facets (D2).
            if self.openFindFacets() { return true }
            if let tool = self.matchedQuickLaunch {
                self.onQuickLaunch?(tool)
                return true
            }
            return self.toggleLauncherLane()
        }
        editor.onArrow = { [weak self] delta in
            guard let self else { return false }
            if self.result?.kind == .proposal { return self.moveChoice(by: delta) }
            if self.result?.kind == .options { return self.moveOption(by: delta) }
            if case .suggesting = self.mode { return self.moveLauncherSelection(by: delta) }
            return self.moveCompletion(by: delta)
        }
        editor.onDigit = { [weak self] digit in
            guard let self else { return false }
            return self.choose(number: digit) || self.chooseOption(number: digit, gesture: .run)
        }
        editor.onCopyPath = { [weak self] in self?.copyHighlightedLauncherPath() ?? false }
        editor.onAnnotationsChanged = { [weak self] notes in
            guard let self else { return }
            if self.updatingTextPresentation || self.editor.isProcessingCharacterEdit {
                self.onAnnotationsChanged?(notes)
                return
            }
            self.annotationUI.changed()
            self.onAnnotationsChanged?(notes)
            self.refreshLauncherMode(textChanged: false)
            self.renderFooter()
        }
        scroll.documentView = editor
        editorScrollView = scroll

        let requestScroll = NSScrollView(frame: .zero)
        requestScroll.hasVerticalScroller = false
        requestScroll.hasHorizontalScroller = false
        requestScroll.drawsBackground = false
        requestScroll.borderType = .noBorder
        requestScroll.isHidden = true
        configureReadOnlyText(submittedRequestView, font: .systemFont(ofSize: 15))
        submittedRequestView.textColor = OmniFrostedStyle.secondaryInk
        submittedRequestView.setAccessibilityIdentifier("omni.pad.submitted-request")
        submittedRequestView.onSubmit = { [weak self] gesture in self?.submit(gesture) }
        submittedRequestView.onEscape = { [weak self] in
            guard let self else { return }
            if self.dismissLocalOptions() { return }
            self.onEscape?()
        }
        submittedRequestView.onArrow = { [weak self] delta in
            guard let self else { return false }
            return self.moveChoice(by: delta) || self.moveOption(by: delta) || self.movePicker(by: delta)
        }
        submittedRequestView.onCopyPath = { [weak self] in self?.performPickerAction(.copyPath) ?? false }
        submittedRequestView.onDigit = { [weak self] digit in
            guard let self else { return false }
            return self.choose(number: digit) || self.chooseOption(number: digit, gesture: .run)
        }
        submittedRequestView.onAlternateDigit = { [weak self] digit in self?.chooseOption(number: digit, gesture: .editFirst) ?? false }
        submittedRequestView.onAlternateSubmit = { [weak self] in self?.confirmOption(.editFirst) ?? false }
        submittedRequestView.onLetter = { [weak self] letter in self?.toggleNoticed(letter: letter) ?? false }
        requestScroll.documentView = submittedRequestView
        submittedRequestScrollView = requestScroll

        let resultScroll = NSScrollView(frame: .zero)
        resultScroll.hasVerticalScroller = true
        resultScroll.autohidesScrollers = true
        resultScroll.drawsBackground = false
        resultScroll.borderType = .noBorder
        resultScroll.isHidden = true
        configureReadOnlyText(resultTextView, font: OmniFrostedStyle.bodyFont)
        resultTextView.setAccessibilityIdentifier("omni.pad.result-text")
        resultTextView.onSubmit = { [weak self] gesture in self?.submit(gesture) }
        resultTextView.onEscape = { [weak self] in self?.onEscape?() }
        resultScroll.documentView = resultTextView
        resultScrollView = resultScroll

        footerSeparator.boxType = .custom
        footerSeparator.fillColor = OmniFrostedStyle.line
        footerSeparator.setAccessibilityElement(false)

        statusLabel.font = OmniFrostedStyle.diagnosticFont
        statusLabel.textColor = OmniFrostedStyle.secondaryInk
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.setAccessibilityIdentifier("omni.command-diagnostics")
        notesButton.setAccessibilityIdentifier("omni.pad.notes")
        notesButton.isHidden = true
        notesButton.onPress = { [weak self] in
            guard let self else { return }
            self.annotationUI.openOverview(anchor: self.notesButton)
        }
        annotationUI.onNotice = { [weak self] message in self?.showTransientNotice(message) }

        settingsButton.setAccessibilityIdentifier("omni.pad.open-settings")
        settingsButton.isHidden = true
        settingsButton.onPress = { [weak self] in self?.onOpenSettings?(false) }

        modelPopUp.cell = OmniModelChevronCell(textCell: "", pullsDown: true)
        modelPopUp.font = OmniFrostedStyle.diagnosticFont
        modelPopUp.isBordered = false
        (modelPopUp.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        modelPopUp.imagePosition = .imageOnly
        modelPopUp.controlSize = .small
        modelPopUp.isHidden = true
        modelPopUp.target = self
        modelPopUp.action = #selector(modelChoiceChanged(_:))
        modelPopUp.setAccessibilityIdentifier("omni.model-selection")
        modelPopUp.setAccessibilityLabel("Choose model for this run")
        modelOverrideLabel.font = OmniFrostedStyle.diagnosticFont
        modelOverrideLabel.textColor = OmniFrostedStyle.secondaryInk
        modelOverrideLabel.lineBreakMode = .byTruncatingTail
        modelOverrideLabel.isHidden = true
        modelOverrideLabel.setAccessibilityIdentifier("omni.model-override")
        clearModelButton.isHidden = true
        clearModelButton.setAccessibilityIdentifier("omni.model-clear")
        clearModelButton.setAccessibilityLabel("Clear model override")
        clearModelButton.onPress = { [weak self] in self?.clearModelSelection() }

        keyHintsView.hints = OmniPadKeyHint.run
        runButton.setAccessibilityIdentifier("omni.pad.run")
        runButton.setAccessibilityLabel("Run")
        runButton.onPress = { [weak self] in self?.submit(.enterShowHere) }
        runButton.isEnabled = false

        retryButton.setAccessibilityIdentifier("omni.pad.retry")
        retryButton.onPress = { [weak self] in
            guard let self, case .result(let runID) = self.mode,
                  let result = self.result,
                  case .failure(retryAllowed: true) = result.kind else { return }
            self.onRetryResult?(runID)
        }
        retryButton.isHidden = true

        for subview in [developmentLabel, provenanceChip, launcherScopeChip, wordCountLabel, scroll, requestScroll, resultScroll, footerSeparator, statusLabel, notesButton, settingsButton, modelOverrideLabel, modelPopUp, clearModelButton, retryButton, keyHintsView, runButton] as [NSView] {
            root.addSubview(subview)
        }
        view = root
        layoutPad(width: root.bounds.width)
        renderFooter()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutPad(width: view.bounds.width)
    }

    // MARK: Provenance

    public func setProvenance(_ provenance: OmniPadProvenance?) {
        self.provenance = provenance
        if case .composing = mode { displayProvenance(composingChip) }
        if case .suggesting = mode { displayProvenance(composingChip) }
        // An imported selection is text to act on, not a launcher query.
        if isViewLoaded { refreshLauncherMode(textChanged: false) }
        // The offer row's wording follows the source; a cleared chip can
        // also end the material state.
        if isViewLoaded, mode == .composing { renderFooter() }
        updateEditorHeight()
    }

    private func displayProvenance(_ value: OmniPadProvenance?) {
        provenanceChip.provenance = value
        provenanceChip.isHidden = value == nil
        wordCountLabel.isHidden = value == nil
        if let value { wordCountLabel.stringValue = value.meta ?? "\(value.wordCount) word\(value.wordCount == 1 ? "" : "s")" }
    }

    /// The chip while composing: a resolved stash import, else the capture.
    private var composingChip: OmniPadProvenance? { stashImport?.chip ?? provenance }

    /// What the pad parses for routes and submit: the field without the
    /// stash import atom, which names material rather than a command.
    var textForParsing: String {
        stashImport.map { OmniStashCommand.removingImport($0.literal, from: editor.string) } ?? editor.string
    }

    /// Re-reads `/stash` and `/stash:N` in the field (C43, C96).
    func refreshStashImport() {
        let previous = (stashImport, unresolvedStashAtom)
        stashImport = nil
        unresolvedStashAtom = nil
        if (mode == .composing || mode == .suggesting), let resolver = onResolveStashImport {
            let text = editor.string
            if case .import(let position, let literal) = OmniStashCommand.reading(of: text, otherPrimaryTokens: otherPrimaryTokens(in: text)) {
                if (1...OmniStashStack.capacity).contains(position), let found = resolver(position) {
                    stashImport = found.with(literal: literal)
                } else {
                    unresolvedStashAtom = literal
                }
            }
        }
        guard previous.0 != stashImport || previous.1 != unresolvedStashAtom else { return }
        if mode == .composing || mode == .suggesting { displayProvenance(composingChip) }
        updateEditorHeight()
    }

    private func otherPrimaryTokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { word in
            let atom = String(word)
            guard let slash = SlashAtom.parse(atom), slash.token != OmniStashCommand.token,
                  let command = parser.manifest.command(matchingAtom: atom) ?? parser.manifest.command(for: slash.token)
            else { return nil }
            let role = command.role == .alias ? command.canonical.flatMap { parser.manifest.command(matchingAtom: $0)?.role } : command.role
            return role == .primary ? slash.token : nil
        }
    }

    /// × on the stash chip: the atom leaves the field (undoable); the rest stays.
    func removeStashImportAtom() {
        guard let literal = stashImport?.literal, let found = OmniStashCommand.range(of: literal, in: editor.string) else { return }
        let source = editor.string as NSString
        var range = found
        if NSMaxRange(range) < source.length, source.substring(with: NSRange(location: NSMaxRange(range), length: 1)) == " " { range.length += 1 }
        if editor.shouldChangeText(in: range, replacementString: "") {
            editor.textStorage?.replaceCharacters(in: range, with: "")
            editor.didChangeText()
        }
    }

    public static let stashChordEmptyLine = "Nothing to stash · type or paste text first"
    public static let stashChordCommandLine = "⌘Y stashes plain text · this line has a command"
    public static let stashChordNotesLine = "⌘Y stashes plain text · this text has notes"

    /// ⌘Y, the stash chord (D3): what the field holds joins the stash through
    /// the ordinary `/stash` path. Plain material gets `/stash` visibly on a
    /// line of its own, as the offer row adds `/stance`; a line holding the
    /// token is rejoined with single spaces, so material lines never hold it.
    /// A field that already pushes just submits. The gesture closes the pad
    /// once the run is admitted (D4). Never a result row, and nothing that
    /// would lose a command, a marker or a note.
    func stashChord() -> Bool {
        guard mode == .composing || mode == .suggesting,
              parser.manifest.command(for: OmniStashCommand.token) != nil else { return false }
        if isCompletionVisible { dismissCompletion() }
        let text = editor.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showTransientNotice(Self.stashChordEmptyLine)
            return true
        }
        guard annotations.isEmpty else {
            showTransientNotice(Self.stashChordNotesLine)
            return true
        }
        if OmniStashCommand.reading(of: text, otherPrimaryTokens: otherPrimaryTokens(in: text)) == .push {
            // The push would store the field without every other slash word.
            guard OmniStashText.droppedWords(in: text) == [OmniStashCommand.token] else {
                showTransientNotice(Self.stashChordCommandLine)
                return true
            }
            // A launch must never stand in for the stash.
            if mode == .composing { submit(.commandYClose) }
            return true
        }
        guard isMaterialText(parser.parse(text)), OmniStashText.droppedWords(in: text).isEmpty else {
            showTransientNotice(Self.stashChordCommandLine)
            return true
        }
        let insertion = (text.last?.isNewline == true ? "" : "\n") + OmniStashCommand.token
        replace(NSRange(location: (text as NSString).length, length: 0), with: insertion)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        // The token ends launcher mode; a launch must never stand in for it.
        guard mode == .composing else { return true }
        submit(.commandYClose)
        return true
    }

    static func unresolvedStashLine(_ literal: String) -> String {
        guard let value = SlashAtom.parse(literal)?.value else { return "The stash is empty · /stash with text keeps something" }
        if let position = Int(value), (1...OmniStashStack.capacity).contains(position) { return "Nothing at \(literal) yet" }
        return "The stash holds five · /stash:1 to /stash:5"
    }

    /// The footer while the field imports from the stash: unresolved, or an
    /// import still waiting for a command.
    private func stashFooterState(_ parsed: ParsedIntent) -> OmniPadFooterState? {
        guard mode == .composing else { return nil }
        if let literal = unresolvedStashAtom {
            return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .attention(Self.unresolvedStashLine(literal)),
                keyHints: OmniPadKeyHint.dismissOnly, runEnabled: false, submits: false)
        }
        guard let stashImport, parsed.dispatchToken == nil else { return nil }
        return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .hint("Add a command to use \(stashImport.chipLabel)"),
            keyHints: OmniPadKeyHint.dismissOnly, runEnabled: false, submits: false)
    }

    // MARK: Model override

    public func setModelChoices(_ choices: [OmniModelChoice]) {
        modelChoices = choices
        modelPopUp.removeAllItems()
        modelPopUp.addItem(withTitle: "⌄")
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)) {
            chevron.isTemplate = true
            modelPopUp.item(at: 0)?.image = chevron
        }
        modelPopUp.addItem(withTitle: "Default routing")
        modelPopUp.menu?.autoenablesItems = false
        for choice in choices {
            modelPopUp.addItem(withTitle: choice.menuTitle)
            modelPopUp.lastItem?.isEnabled = choice.isEnabled
            modelPopUp.lastItem?.toolTip = choice.unavailabilityReason
            let title = NSMutableAttributedString(
                string: choice.label,
                attributes: [.font: NSFont.menuFont(ofSize: 13)]
            )
            if let reason = choice.unavailabilityReason {
                title.append(NSAttributedString(
                    string: " — \(reason)",
                    attributes: [.font: NSFont.menuFont(ofSize: 11)]
                ))
            }
            modelPopUp.lastItem?.attributedTitle = title
        }
        if let id = selectedModelProfileID, !choices.contains(where: { $0.id == id }) {
            selectedModelProfileID = nil
        }
        modelPopUp.selectItem(at: 0)
        renderFooter()
    }

    public func clearModelSelection() {
        selectedModelProfileID = nil
        modelPopUp.selectItem(at: 0)
        renderVisibleText()
    }

    public func selectModelProfile(id: String?) {
        selectedModelProfileID = id.flatMap { wanted in modelChoices.first(where: { $0.id == wanted })?.id }
        modelPopUp.selectItem(at: 0)
        renderVisibleText()
    }

    @objc private func modelChoiceChanged(_ sender: Any?) {
        let index = modelPopUp.indexOfSelectedItem
        if index >= 2, modelChoices.indices.contains(index - 2) {
            guard modelChoices[index - 2].isEnabled else {
                modelPopUp.selectItem(at: 0)
                return
            }
            selectedModelProfileID = modelChoices[index - 2].id
        } else {
            selectedModelProfileID = nil
        }
        modelPopUp.selectItem(at: 0)
        renderVisibleText()
    }

    // MARK: Messages

    /// A transient route-line notice; the next keystroke clears it.
    public func showTransientNotice(_ text: String) {
        transientMessage = text
        renderFooter()
    }

    /// Re-renders the route line after an async resolution without treating
    /// it as a keystroke: notices and the completion menu are left alone.
    public func refreshRoute() {
        guard case .composing = mode else { return }
        renderFooter()
    }

    public func showActionFeedback(_ text: String) {
        showTransientNotice(text)
    }

    // MARK: Text

    public func textDidChange(_ notification: Notification) {
        guard !applyingRewrite else { return }
        localToolRequestSubmitted = false
        updatingTextPresentation = true
        editor.reconcileAnnotations()
        transientMessage = nil
        applyCompletedRewrites()
        refreshLauncherMode(textChanged: true)
        renderVisibleText(refreshFooter: false)
        updateEditorHeight(relayout: false)
        // Decide the palette first (the footer's hints depend on it), settle
        // the footer and pad geometry, then place the palette against the
        // pad's final edges (C78).
        refreshCompletionItems()
        renderFooter()
        if isCompletionVisible { showCompletionMenu() }
        updatingTextPresentation = false
        annotationUI.changed()
    }

    public func setAnnotations(_ notes: [OmniTextAnnotation]) {
        editor.setAnnotations(notes)
        if isViewLoaded { renderVisibleText() }
    }

    public func clearAnnotations() { setAnnotations([]) }
    public func closeAnnotationPanels() { annotationUI.closeAll() }

    public func openAnnotationForSelection() { annotationUI.openForSelection() }
    public func showAnnotationHover(_ id: UUID?) { annotationUI.showHover(id) }
    public var annotationCardPanel: NSPanel? { annotationUI.card }
    public var annotationHoverPanel: NSPanel? { annotationUI.hover }
    public var annotationOverviewPanel: NSPanel? { annotationUI.overview }

    public func insertVisibleText(_ value: String) {
        editor.insertText(value, replacementRange: editor.selectedRange())
        renderVisibleText()
    }

    public func applyVisibleRewrite(_ rewrite: VisibleRewrite) {
        let ns = editor.string as NSString
        var search = NSRange(location: 0, length: ns.length)
        for atom in editor.string.split(whereSeparator: \.isWhitespace).map(String.init) {
            let range = ns.range(of: atom, options: [], range: search)
            guard range.location != NSNotFound else { continue }
            search = NSRange(location: range.upperBound, length: max(0, ns.length - range.upperBound))
            if atom == rewrite.from {
                replace(range, with: rewrite.to)
                return
            }
        }
    }

    public func presentReferencePicker(choices: [OmniReferenceChoice], replacing atom: String? = nil) {
        guard !choices.isEmpty else { return }
        referencePicker?.orderOut(nil)
        let picker = OmniReferencePicker(choices: choices, anchor: view.window?.frame ?? view.frame)
        picker.onChoose = { [weak self] choice in self?.replaceActiveAtom(matching: atom, with: choice.canonicalText) }
        referencePicker = picker
        picker.orderFrontRegardless()
    }

    /// Replaces the last matching atom before the caret, not the first document
    /// occurrence, so a later `/st` cannot mutate an earlier `/style:formal`.
    public func replaceActiveAtom(matching source: String? = nil, with value: String) {
        let ns = editor.string as NSString
        let caret = min(editor.selectedRange().location, ns.length)
        let needle: String
        if let source {
            needle = source
        } else {
            let before = ns.substring(to: caret)
            guard let atom = before.split(whereSeparator: \.isWhitespace).last else { return }
            needle = String(atom)
        }
        let range = ns.range(of: needle, options: .backwards, range: NSRange(location: 0, length: caret))
        guard range.location != NSNotFound else { return }
        replace(range, with: value)
    }

    func replace(_ range: NSRange, with value: String) {
        guard editor.shouldChangeText(in: range, replacementString: value) else { return }
        editor.textStorage?.replaceCharacters(in: range, with: value)
        editor.didChangeText()
        renderVisibleText()
    }

    /// Applies slash rewrites to atoms the user has finished. A valued atom
    /// still under the caret is left alone wherever it sits; submit applies
    /// every rewrite.
    private func applyCompletedRewrites() {
        guard OmniPronunciationRoute.term(in: editor.string) == nil,
              OmniClipboardRoute.query(in: editor.string) == nil,
              OmniExpressRoute.text(in: editor.string) == nil,
              OmniRecallRoute.intent(in: editor.string) == nil,
              OmniRatioRoute.query(in: editor.string) == nil,
              OmniMapRoute.query(in: editor.string) == nil,
              OmniWeatherRoute.query(in: editor.string) == nil,
              OmniQRRoute.payload(in: editor.string) == nil,
              OmniRegexRoute.input(in: editor.string) == nil else { return }
        applyingRewrite = true
        defer { applyingRewrite = false }
        for _ in 0..<16 {
            let parsed = parser.parse(editor.string)
            let rewrites = Dictionary(parsed.visibleRewrites.filter { $0.from.hasPrefix("/") }.map { ($0.from, $0.to) }, uniquingKeysWith: { first, _ in first })
            guard !rewrites.isEmpty else { return }
            let ns = editor.string as NSString
            let caret = min(editor.selectedRange().location, ns.length)
            var search = NSRange(location: 0, length: ns.length)
            var target: (range: NSRange, to: String)?
            for atom in editor.string.split(whereSeparator: \.isWhitespace).map(String.init) {
                let range = ns.range(of: atom, options: [], range: search)
                guard range.location != NSNotFound else { continue }
                search = NSRange(location: range.upperBound, length: max(0, ns.length - range.upperBound))
                guard let to = rewrites[atom] else { continue }
                let underCaret = range.location < caret && caret <= range.upperBound
                if underCaret && atom.contains(":") { continue }
                target = (range, to)
                break
            }
            guard let target else { return }
            let before = editor.string
            replace(target.range, with: target.to)
            if editor.string == before { return }
        }
    }

    // MARK: Submit

    func submit(_ gesture: OmniSubmitGesture) {
        switch mode {
        case .working(let runID):
            if gesture == .commandEnterAttach { onOpenResult?(runID) }
            return
        case .result(let runID):
            // A picker row: ↩ opens, ⌘↩ reveals (the launcher's chords, D2).
            if result?.kind == .picker {
                if pickerRows.isEmpty { onCloseResult?(runID) } else { performPickerAction(gesture == .commandEnterAttach ? .reveal : .open) }
                return
            }
            if gesture == .commandEnterAttach {
                onOpenResult?(runID)
                return
            }
            switch result?.kind {
            case .text: onCopyResult?(runID)
            case .confirmation: onCloseResult?(runID)
            case .proposal: confirmChoice()
            case .options: _ = confirmOption(.run)
            case .picker, .failure, .none: break
            }
            return
        case .suggesting:
            if submitLocalInput() { return }
            submitLauncher(gesture)
            return
        case .composing:
            break
        }
        if isCompletionVisible { dismissCompletion() }
        if submitLocalInput() { return }
        if let intent = OmniRecallRoute.intent(in: editor.string) {
            guard isActionAvailable("tool.recall") else { showTransientNotice("Recall is disabled in Settings."); return }
            guard !localToolRequestSubmitted else { return }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onRecallRequested?(intent)
            return
        }
        if let query = OmniRatioRoute.query(in: editor.string) {
            guard isActionAvailable("tool.ratio") else { showTransientNotice("Ratio is disabled in Settings."); return }
            guard !localToolRequestSubmitted else { return }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onRatioRequested?(query)
            return
        }
        if let term = OmniPronunciationRoute.term(in: editor.string) {
            guard isActionAvailable("tool.pronunciation") else { showTransientNotice("Pronunciation is disabled in Settings."); return }
            guard !localToolRequestSubmitted else { return }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onPronunciationRequested?(term)
            return
        }
        if let text = OmniExpressRoute.text(in: editor.string) {
            guard isActionAvailable("tool.express") else { showTransientNotice("Express is disabled in Settings."); return }
            guard !localToolRequestSubmitted else { return }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onExpressRequested?(text)
            return
        }
        refreshStashImport()
        if unresolvedStashAtom != nil || (stashImport != nil && parser.parse(textForParsing).dispatchToken == nil) {
            renderFooter()
            return
        }
        let parsed = parser.parse(textForParsing)
        for rewrite in parsed.visibleRewrites { applyVisibleRewrite(rewrite) }
        let normalized = parser.parse(textForParsing)
        // Bare `/expand` offers its five lenses here, with no run and no
        // model call; a pick runs `/expand:<lens>`.
        if isBareExpand(normalized) {
            presentExpandLenses()
            return
        }
        // D3: Enter on captured or multi-line material with no token runs
        // `/stance`, inserting it visibly first. Its route is the one that
        // matters here, never the bare text's Tier 2 route.
        if isOfferMaterial(normalized) {
            acceptOffer(gesture)
            return
        }
        let route = resolvedRoute(normalized)
        guard route?.unavailable == nil else {
            renderFooter()
            return
        }
        if isAnnotatedBareText(normalized) {
            // An id with a note stays put (D1); the footer says why.
            guard OmniIDAddress(editor.string) == nil else {
                renderFooter()
                return
            }
            annotationUI.closeAll()
            onSubmit?(normalized.canonicalText, gesture)
            return
        }
        let state = Self.footerState(for: normalized, route: route, completionVisible: false, transientMessage: nil)
        guard state.submits else {
            renderFooter()
            return
        }
        if let ambiguous = normalized.references.first(where: { if case .ambiguous = $0 { return true }; return false }),
           case let .ambiguous(key) = ambiguous,
           let choices = onRequestReferenceChoices?("@\(key)"), !choices.isEmpty {
            presentReferencePicker(choices: choices, replacing: "@\(key)")
            return
        }
        let canonical = normalized.canonicalText
        if canonical == "/settings" {
            guard isActionAvailable("settings.open") else { showTransientNotice("Settings is unavailable."); return }
            onOpenSettings?(false); return
        }
        if canonical == "/model" {
            guard isActionAvailable("settings.model") else { showTransientNotice("Model settings is unavailable."); return }
            onOpenSettings?(true); return
        }
        if normalized.dispatchToken == "/workspace" {
            guard canonical == "/workspace" else { showTransientNotice("/workspace takes no input."); return }
            onOpenWorkspace?(); return
        }
        annotationUI.closeAll()
        onSubmit?(canonical, gesture)
    }

    /// Local actions take the same current text that the footer previews.
    /// Incomplete or invalid arithmetic is consumed here, never proposed.
    func submitLocalInput() -> Bool {
        if let payload = OmniQRRoute.payload(in: editor.string) {
            guard isActionAvailable("tool.qr") else { showTransientNotice("QR is disabled in Settings."); return true }
            guard !localToolRequestSubmitted else { return true }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onQRRequested?(payload)
            return true
        }
        if let input = OmniRegexRoute.input(in: editor.string) {
            guard isActionAvailable("tool.regex") else { showTransientNotice("Regex is disabled in Settings."); return true }
            guard !localToolRequestSubmitted else { return true }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onRegexRequested?(input)
            return true
        }
        if let query = OmniCharactersRoute.query(in: editor.string) {
            guard isActionAvailable("tool.characters") else { showTransientNotice("Characters is disabled in Settings."); return true }
            guard !localToolRequestSubmitted else { return true }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onCharactersRequested?(query)
            return true
        }
        if let query = OmniWeatherRoute.query(in: editor.string) {
            guard isActionAvailable("tool.weather") else { showTransientNotice("Weather is disabled in Settings."); return true }
            guard !localToolRequestSubmitted else { return true }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onWeatherRequested?(query)
            return true
        }
        if let query = OmniMapRoute.query(in: editor.string) {
            guard isActionAvailable("tool.map") else { showTransientNotice("Map is disabled in Settings."); return true }
            guard !localToolRequestSubmitted else { return true }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onMapRequested?(query)
            return true
        }
        if let query = OmniClipboardRoute.query(in: editor.string) {
            guard isActionAvailable("clipboard.history") else { showTransientNotice("Clipboard history is disabled in Settings."); return true }
            guard !localToolRequestSubmitted else { return true }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onClipboardRequested?(query)
            return true
        }
        if submitContributedSlash() { return true }
        switch localCalculatorState() {
        case .ordinary:
            return false
        case .incomplete, .failure:
            renderFooter()
            return true
        case .result(let answer):
            guard !localToolRequestSubmitted else { return true }
            localToolRequestSubmitted = true
            annotationUI.closeAll()
            onCalculatorCopy?(answer)
            return true
        }
    }

    private func submitContributedSlash() -> Bool {
        let raw = editor.string
        guard let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).first.map(String.init), token.hasPrefix("/") else { return false }
        if let route = contributedSlashRoutes.first(where: { $0.token == token }) {
            guard isActionAvailable("tool.\(route.toolID)") else {
                showTransientNotice("This tool is disabled in Settings.")
                return true
            }
        } else if parser.manifest.command(matchingAtom: token) != nil {
            return false
        }
        guard let onContributedSlashRequested else { return false }
        guard annotations.isEmpty else {
            showTransientNotice("Contributed tools cannot carry annotations.")
            return true
        }
        guard !localToolRequestSubmitted else { return true }
        guard let opened = onContributedSlashRequested(raw) else { return false }
        if opened {
            localToolRequestSubmitted = true
            annotationUI.closeAll()
        } else {
            showTransientNotice("This tool is unavailable in Settings.")
        }
        return true
    }

    private func localCalculatorState() -> BasicCalculationState {
        let input = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = input == "/calc" || (input.hasPrefix("/calc") && input.dropFirst(5).first?.isWhitespace == true)
        guard explicit || (provenance == nil && annotations.isEmpty) else { return .ordinary }
        return BasicCalculator.classify(editor.string)
    }

    // MARK: Completion (C25, C78): a floating palette above the pad, accepted with Tab

    /// Decides the items; `showCompletionMenu` places them once the pad has
    /// its settled geometry.
    private func refreshCompletionItems() {
        let source = editor.string as NSString
        let caret = min(editor.selectedRange().location, source.length)
        let before = source.substring(to: caret)
        // Every word after the leading local tool token is literal material.
        if OmniRecallRoute.intent(in: editor.string) != nil,
           before.drop(while: \.isWhitespace).count > OmniRecallRoute.token.count {
            dismissCompletion()
            return
        }
        if OmniRatioRoute.query(in: editor.string) != nil,
           before.drop(while: \.isWhitespace).count > OmniRatioRoute.token.count {
            dismissCompletion()
            return
        }
        if OmniMapRoute.query(in: editor.string) != nil,
           before.drop(while: \.isWhitespace).count > OmniMapRoute.token.count {
            dismissCompletion()
            return
        }
        if OmniWeatherRoute.query(in: editor.string) != nil,
           before.drop(while: \.isWhitespace).count > OmniWeatherRoute.token.count {
            dismissCompletion()
            return
        }
        if OmniQRRoute.payload(in: editor.string) != nil,
           before.drop(while: \.isWhitespace).count > OmniQRRoute.token.count {
            dismissCompletion()
            return
        }
        if OmniRegexRoute.input(in: editor.string) != nil,
           before.drop(while: \.isWhitespace).count > OmniRegexRoute.token.count {
            dismissCompletion()
            return
        }
        if OmniPronunciationRoute.term(in: editor.string) != nil,
           before.drop(while: \.isWhitespace).count > OmniPronunciationRoute.token.count {
            dismissCompletion()
            return
        }
        if OmniExpressRoute.text(in: editor.string) != nil,
           before.drop(while: \.isWhitespace).count > OmniExpressRoute.token.count {
            dismissCompletion()
            return
        }
        if OmniClipboardRoute.query(in: editor.string) != nil,
           before.drop(while: \.isWhitespace).count > 3 {
            dismissCompletion()
            return
        }
        if BasicCalculator.classify(editor.string) != .ordinary,
           before.drop(while: \.isWhitespace).count > 5,
           before.drop(while: \.isWhitespace).hasPrefix("/calc") {
            dismissCompletion()
            return
        }
        // The atom being typed, at the caret: a slash left behind a space is
        // material again (C77), and the offer row must be free to show.
        guard before.last?.isWhitespace == false,
              let atom = before.split(whereSeparator: \.isWhitespace).last else {
            dismissCompletion()
            return
        }
        // A word in `/find`'s payload completes from the filter facets (D2).
        if !atom.hasPrefix("/"), let items = findCompletionItems(for: String(atom)), !items.isEmpty {
            if items != completionItems { completionIndex = 0 }
            completionItems = items
            completionIndex = min(completionIndex, items.count - 1)
            return
        }
        guard atom.hasPrefix("/") else {
            dismissCompletion()
            return
        }
        var items = Self.paletteItems(for: String(atom), manifest: parser.manifest,
                                      isActionAvailable: isActionAvailable)
        let contributed: [OmniCompletionItem] = contributedSlashRoutes.compactMap { route -> OmniCompletionItem? in
            guard route.token.hasPrefix(String(atom)), route.token != String(atom),
                  isActionAvailable("tool.\(route.toolID)") else { return nil }
            return OmniCompletionItem(
                choice: OmniReferenceChoice(id: route.token, canonicalText: route.token, label: route.title),
                role: .primary,
                help: OmniCommandHelp(token: route.token, kind: "Tool · opens native panel",
                                      body: route.detail, usage: ["\(route.token) <text>"])
            )
        }.sorted { $0.choice.canonicalText < $1.choice.canonicalText }
        items += contributed
        guard !items.isEmpty else {
            dismissCompletion()
            return
        }
        if items != completionItems { completionIndex = 0 }
        completionItems = items
        completionIndex = min(completionIndex, items.count - 1)
    }

    /// A bare `/` lists every command but the aliases (they rewrite to their
    /// canonical token on insert, so listing them would teach the wrong
    /// spelling); a longer atom narrows by prefix; a valued token lists its
    /// registry members (C78). `CommandManifest.commands` order: sorted by token.
    static func paletteItems(for prefix: String, manifest: CommandManifest,
                             isActionAvailable: @MainActor (String) -> Bool = { _ in true }) -> [OmniCompletionItem] {
        var items: [OmniCompletionItem] = manifest.commands
            .filter { $0.role != .alias && $0.token.hasPrefix(prefix) && $0.token != prefix
                && ($0.token == "/workspace" || isActionAvailable(actionID(for: $0.token))) }
            .map { command in
                OmniCompletionItem(
                    choice: OmniReferenceChoice(id: command.token, canonicalText: command.token, label: OmniPadVocabulary.description(for: command.token)),
                    role: command.role,
                    help: OmniCommandHelp(
                        token: command.token,
                        kind: OmniPadVocabulary.kind(for: command),
                        body: OmniPadVocabulary.help(for: command.token),
                        usage: OmniPadVocabulary.usage(for: command, valueTypes: manifest.valueTypes)
                    )
                )
            }
        if OmniRecallRoute.token.hasPrefix(prefix), OmniRecallRoute.token != prefix,
           isActionAvailable("tool.recall") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: OmniRecallRoute.token, canonicalText: OmniRecallRoute.token,
                                            label: "Recall a git or shell command"),
                role: .primary,
                help: OmniCommandHelp(token: OmniRecallRoute.token, kind: "Tool · opens native panel",
                    body: "Searches your sheet first; AI can add suggestions. ⌘Return requests one. Copy only; never executes.",
                    usage: ["/recall <intent>", "/recall (opens the whole sheet)"])
            ))
            items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        }
        if OmniRatioRoute.token.hasPrefix(prefix), OmniRatioRoute.token != prefix,
           isActionAvailable("tool.ratio") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: OmniRatioRoute.token, canonicalText: OmniRatioRoute.token,
                                            label: "Aspect ratios and sizes, drawn"),
                role: .primary,
                help: OmniCommandHelp(token: OmniRatioRoute.token, kind: "Tool · opens native panel",
                    body: "A ratio, a size, a ratio at a width or height, or a preset name. No model.",
                    usage: ["/ratio 16:9 at 1200 wide", "/ratio (opens the common ratios)"])
            ))
            items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        }
        if OmniCharactersRoute.token.hasPrefix(prefix), OmniCharactersRoute.token != prefix,
           isActionAvailable("tool.characters") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: OmniCharactersRoute.token, canonicalText: OmniCharactersRoute.token,
                                            label: "Find or identify a Unicode character"),
                role: .primary,
                help: OmniCommandHelp(token: OmniCharactersRoute.token, kind: "Tool · opens native panel",
                    body: "Searches Unicode names, aliases and blocks offline. A glyph or code point shows its representations.",
                    usage: ["/char <name, glyph or code point>", "/char (frequent characters)"])
            ))
            items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        }
        if OmniWeatherRoute.token.hasPrefix(prefix), OmniWeatherRoute.token != prefix,
           isActionAvailable("tool.weather") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: OmniWeatherRoute.token, canonicalText: OmniWeatherRoute.token,
                                            label: "Weather for here or a place"),
                role: .primary,
                help: OmniCommandHelp(token: OmniWeatherRoute.token, kind: "Tool · opens native panel",
                    body: "Shows four weather facts for here or a literal place. Only the last reading is cached.",
                    usage: ["/weather", "/weather Copenhagen"])
            ))
            items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        }
        if OmniQRRoute.token.hasPrefix(prefix), OmniQRRoute.token != prefix,
           isActionAvailable("tool.qr") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: OmniQRRoute.token, canonicalText: OmniQRRoute.token,
                                            label: "Make a scannable QR code"),
                role: .primary,
                help: OmniCommandHelp(token: OmniQRRoute.token, kind: "Tool · opens native panel",
                    body: "Draws a QR code locally from literal text, a link or wifi:NAME,password.",
                    usage: ["/qr https://example.com", "/qr (opens empty)"])
            ))
            items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        }
        if OmniRegexRoute.token.hasPrefix(prefix), OmniRegexRoute.token != prefix,
           isActionAvailable("tool.regex") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: OmniRegexRoute.token, canonicalText: OmniRegexRoute.token,
                                            label: "Read or write an ICU regex"),
                role: .primary,
                help: OmniCommandHelp(token: OmniRegexRoute.token, kind: "Tool · opens native panel",
                    body: "Reads ICU patterns or writes one from a description. Checks examples locally.",
                    usage: ["/regex UK postcode", "/regex (opens the sheet)"])
            ))
            items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        }
        if OmniMapRoute.token.hasPrefix(prefix), OmniMapRoute.token != prefix,
           isActionAvailable("tool.map") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: OmniMapRoute.token, canonicalText: OmniMapRoute.token,
                                            label: "Draw an answer as a map"),
                role: .primary,
                help: OmniCommandHelp(token: OmniMapRoute.token, kind: "Tool · opens native panel",
                    body: "Draws a question or phrase as one of seven native map forms. Nothing is stored.",
                    usage: ["/map what keeps a library useful?", "/map (choose a form)"])
            ))
            items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        }
        if OmniPronunciationRoute.token.hasPrefix(prefix), OmniPronunciationRoute.token != prefix,
           isActionAvailable("tool.pronunciation") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(
                    id: OmniPronunciationRoute.token,
                    canonicalText: OmniPronunciationRoute.token,
                    label: "Pronounce a word or phrase"
                ),
                role: .primary,
                help: OmniCommandHelp(
                    token: OmniPronunciationRoute.token,
                    kind: "Tool · opens native panel",
                    body: "Opens the pronunciation panel on this Mac. Type a term after /pron, or open it empty. No durable command run is created.",
                    usage: ["/pron <word or phrase>", "/pron (opens empty)"]
                )
            ))
            items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        }
        if OmniExpressRoute.token.hasPrefix(prefix), OmniExpressRoute.token != prefix,
           isActionAvailable("tool.express") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: OmniExpressRoute.token,
                    canonicalText: OmniExpressRoute.token,
                    label: "Find conversational English alternatives"),
                role: .primary,
                help: OmniCommandHelp(token: OmniExpressRoute.token, kind: "Tool · opens native panel",
                    body: "Offers close and broader English phrasing for the supplied text. Copy a choice; no durable command run is created.",
                    usage: ["/express <text>", "/express (opens empty)"])
            ))
            items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        }
        for token in OmniClipboardRoute.tokens where token.hasPrefix(prefix) && token != prefix
            && isActionAvailable("clipboard.history") {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: token, canonicalText: token, label: "Open clipboard history"),
                role: .primary,
                help: OmniCommandHelp(token: token, kind: "Tool · opens native picker",
                    body: "Opens local clipboard history. Type a search after the command to start there; copied items stay inside the history picker.",
                    usage: ["\(token) <search>", "\(token) (opens all history)"])
            ))
        }
        if "/calc".hasPrefix(prefix), "/calc" != prefix {
            items.append(OmniCompletionItem(
                choice: OmniReferenceChoice(id: "/calc", canonicalText: "/calc", label: "Calculate an expression"),
                role: .primary,
                help: OmniCommandHelp(token: "/calc", kind: "Tool · local arithmetic",
                    body: "Shows the answer while you type. Enter copies the displayed number and closes. Supports +, −, ×, ÷, decimals and parentheses.",
                    usage: ["/calc <expression>"])
            ))
        }
        items.sort { $0.choice.canonicalText < $1.choice.canonicalText }
        if let command = manifest.command(matchingAtom: prefix) ?? manifest.command(for: prefix),
           command.value?.type == .enumRegistry,
           let registry = command.value?.registry,
           let members = manifest.valueTypes.enums[registry] {
            for member in members {
                let canonical = "\(command.token):\(member)"
                guard canonical.hasPrefix(prefix), canonical != prefix,
                      isActionAvailable(actionID(for: command.token)) else { continue }
                let detail = Self.registryMemberDetail(registry: registry, member: member) ?? OmniPadVocabulary.description(for: command.token)
                items.append(OmniCompletionItem(
                    choice: OmniReferenceChoice(id: canonical, canonicalText: canonical, label: detail),
                    role: command.role,
                    help: OmniCommandHelp(token: canonical, kind: OmniPadVocabulary.kind(for: command), body: detail, usage: [])
                ))
            }
        }
        return items
    }

    static func actionID(for token: String) -> String {
        switch token {
        case "/settings": "settings.open"
        case "/model": "settings.model"
        default: "command.\(token.hasPrefix("/") ? String(token.dropFirst()) : token)"
        }
    }

    /// What a registry member means, where the product already says so.
    static func registryMemberDetail(registry: String, member: String) -> String? {
        if registry == OmniDecisionStep.expandLensRegistry {
            return OmniDecisionStep.expandLenses.first { $0.id == member }?.detail
        }
        if registry == "style", member == "formal" { return "Formal register for the draft" }
        return nil
    }

    func showCompletionMenu() {
        completionMenu?.orderOut(nil)
        guard let window = view.window else {
            dismissCompletion()
            return
        }
        let caret = editor.firstRect(forCharacterRange: NSRange(location: editor.selectedRange().location, length: 0), actualRange: nil)
        let anchorX = caret.width > 0 || caret.origin.x > 0 ? caret.minX : window.frame.minX + 16
        // The pad sits in the upper third, so the room above it is finite on
        // a laptop display: the list shows what fits there. Only when not
        // even the help column fits does the palette go below the pad, with
        // the full list, since 0.8 of the screen is free there (C78).
        let screenTop = completionScreenTop ?? (window.screen ?? NSScreen.main)?.visibleFrame.maxY ?? .infinity
        let roomAbove = screenTop - window.frame.maxY - OmniCompletionMenu.gap
        let fitsAbove = roomAbove >= OmniCompletionMenu.minimumHeight(for: completionItems)
        let menu = OmniCompletionMenu(items: completionItems, highlighted: completionIndex, room: fitsAbove ? roomAbove : .infinity)
        menu.onChoose = { [weak self] index in
            self?.completionIndex = index
            _ = self?.acceptCompletion()
        }
        menu.onHover = { [weak self] index in self?.hoverCompletion(index) }
        menu.present(above: window.frame, caretX: anchorX, screenTop: screenTop)
        completionMenu = menu
    }

    public func dismissCompletion() {
        completionMenu?.orderOut(nil)
        completionMenu = nil
        guard !completionItems.isEmpty else { return }
        completionItems = []
        completionIndex = 0
        renderFooter()
    }

    @discardableResult
    public func acceptCompletion() -> Bool {
        guard completionItems.indices.contains(completionIndex) else { return false }
        let choice = completionItems[completionIndex].choice
        if !choice.canonicalText.hasPrefix("/"), isInFindPayload() {
            acceptFindCompletion(choice.canonicalText)
            return true
        }
        replaceActiveAtom(with: choice.canonicalText)
        dismissCompletion()
        return true
    }

    @discardableResult
    public func moveCompletion(by delta: Int) -> Bool {
        guard isCompletionVisible else { return false }
        completionIndex = (completionIndex + delta + completionItems.count) % completionItems.count
        completionMenu?.highlight(completionIndex, scrollingIntoView: true)
        return true
    }

    /// The pointer moved over a row: it becomes the Tab target, and the list
    /// never scrolls under a resting pointer (C78).
    public func hoverCompletion(_ index: Int) {
        guard completionItems.indices.contains(index), index != completionIndex else { return }
        completionIndex = index
        completionMenu?.highlight(index, scrollingIntoView: false)
    }

    // MARK: Working and results (H11, C53–C58)

    /// The request is captured before the host clears its next-draft editor.
    /// Its visible, read-only copy retains token and annotation tints.
    public func beginWorking(
        runID: String,
        requestText: String,
        annotations: [OmniTextAnnotation] = [],
        summary: String = "Working…",
        provenance: OmniPadProvenance? = nil
    ) {
        dismissCompletion()
        clearLauncher()
        transientMessage = nil
        mode = .working(runID: runID)
        result = nil
        alternatives = []
        localOptionsPick = nil
        submittedRequestText = requestText
        workingSummary = summary
        submittedProvenance = provenance ?? self.provenance
        displayProvenance(submittedProvenance)
        provenanceChip.isEnabled = false
        editor.isEditable = false
        editorScrollView?.isHidden = true
        submittedRequestScrollView?.isHidden = false
        configureSubmittedRequest(text: requestText, annotations: annotations)
        clearResultBody()
        let indicator = OmniPadWorkingIndicator(frame: NSRect(x: 18, y: 15, width: 24, height: 22))
        let label = NSTextField(labelWithString: "Working…")
        label.font = .systemFont(ofSize: 15)
        label.textColor = OmniFrostedStyle.secondaryInk
        label.frame = NSRect(x: 48, y: 16, width: view.bounds.width - 64, height: 20)
        label.autoresizingMask = [.width]
        let container = NSView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: 52))
        container.setAccessibilityIdentifier("omni.pad.working")
        container.addSubview(indicator)
        container.addSubview(label)
        view.addSubview(container)
        workingView = container
        bodyHeight = 52
        renderFooter()
        view.window?.makeFirstResponder(submittedRequestView)
    }

    public func showResult(runID: String, result: OmniPadResult) {
        switch mode {
        case .working(let boundID), .result(let boundID):
            guard boundID == runID else { return }
        case .composing, .suggesting:
            return
        }
        if mode == .result(runID: runID), self.result == result { return }
        mode = .result(runID: runID)
        self.result = result
        clearResultBody()
        switch result.kind {
        case .proposal, .options, .picker:
            // Typed alternatives, options and picker rows arrive through their own calls.
            bodyHeight = 0
        case .text, .confirmation, .failure:
            configureResultBody(result)
        }
        renderFooter()
        if result.kind != .proposal, result.kind != .options, result.kind != .picker { view.window?.makeFirstResponder(resultTextView) }
    }

    /// The returned alternatives, drawn in the body with their real tokens.
    /// Enter runs the selected one; 1–3 jump; esc closes the result.
    public func showProposalChooser(runID: String, alternatives: [OmniPadAlternative]) {
        dismissCompletion()
        clearLauncher()
        transientMessage = nil
        switch mode {
        case .working(let boundID), .result(let boundID):
            guard boundID == runID else { return }
        case .composing, .suggesting:
            beginWorking(runID: runID, requestText: editor.string, annotations: annotations, summary: Self.waitingLine)
        }
        mode = .result(runID: runID)
        result = OmniPadResult(kind: .proposal, body: "", summary: Self.choosingLine)
        self.alternatives = Array(alternatives.prefix(3))
        chosenIndex = 0
        clearResultBody()
        rebuildChooser()
        renderFooter()
        view.window?.makeFirstResponder(submittedRequestView)
    }

    /// Back to the editable field, text intact.
    public func returnToComposing() {
        mode = .composing
        result = nil
        submittedRequestText = ""
        submittedProvenance = nil
        workingSummary = "Working…"
        alternatives = []
        chosenIndex = 0
        options = nil
        optionIndex = 0
        tickedNoticed = []
        localOptionsPick = nil
        pickerRows = []
        pickerIndex = 0
        clearResultBody()
        editorScrollView?.isHidden = false
        submittedRequestScrollView?.isHidden = true
        provenanceChip.isEnabled = true
        displayProvenance(provenance)
        editor.isEditable = true
        editor.alphaValue = 1
        refreshLauncherMode(textChanged: false)
        renderFooter()
        updateEditorHeight()
    }

    @discardableResult
    public func moveChoice(by delta: Int) -> Bool {
        guard case .result = mode, result?.kind == .proposal, !alternatives.isEmpty else { return false }
        chosenIndex = (chosenIndex + delta + alternatives.count) % alternatives.count
        highlightChoice()
        return true
    }

    @discardableResult
    public func choose(number: Int) -> Bool {
        guard case .result = mode, result?.kind == .proposal, alternatives.indices.contains(number - 1) else { return false }
        chosenIndex = number - 1
        highlightChoice()
        return true
    }

    public func confirmChoice() {
        guard case .result(let runID) = mode, result?.kind == .proposal,
              alternatives.indices.contains(chosenIndex) else { return }
        onConfirmProposal?(runID, alternatives[chosenIndex].planHash)
    }

    private func highlightChoice() {
        for (index, row) in chooserRows.enumerated() { row.isChosen = index == chosenIndex }
    }

    private func rebuildChooser() {
        chooserView?.removeFromSuperview()
        chooserRows = []
        let rowHeight: CGFloat = 30
        let headingHeight: CGFloat = 22
        let height = headingHeight + rowHeight * CGFloat(alternatives.count) + 6
        let container = NSView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: height))
        container.setAccessibilityIdentifier("omni.pad.proposal")
        let heading = NSTextField(labelWithString: "PROPOSED · PICK ONE")
        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        heading.textColor = OmniFrostedStyle.secondaryInk
        heading.frame = NSRect(x: 16, y: height - headingHeight + 2, width: 200, height: 14)
        container.addSubview(heading)
        for (index, alternative) in alternatives.enumerated() {
            let row = OmniProposalRow(number: index + 1, alternative: alternative, parser: parser) { [weak self] in
                self?.chosenIndex = index
                self?.highlightChoice()
                self?.confirmChoice()
            }
            row.frame = NSRect(x: 12, y: height - headingHeight - rowHeight * CGFloat(index + 1), width: view.bounds.width - 24, height: rowHeight)
            row.autoresizingMask = [.width]
            row.setAccessibilityIdentifier("omni.pad.proposal.\(alternative.id)")
            row.isChosen = index == chosenIndex
            container.addSubview(row)
            chooserRows.append(row)
        }
        container.autoresizingMask = [.width]
        view.addSubview(container)
        chooserView = container
        bodyHeight = height
        layoutPad(width: view.bounds.width)
    }

    private func configureReadOnlyText(_ textView: OmniPadReadOnlyTextView, font: NSFont) {
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = font
        textView.textColor = OmniFrostedStyle.ink
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 40)
        textView.autoresizingMask = [.width]
    }

    func configureSubmittedRequest(text: String, annotations: [OmniTextAnnotation]) {
        let collapsed = Self.collapsedRequest(text, width: max(1, view.bounds.width - 48))
        submittedRequestView.textStorage?.setAttributedString(
            OmniTokenRenderer.attributedText(collapsed, parser: parser, fontSize: 15)
        )
        submittedRequestView.alphaValue = 0.74
        submittedRequestView.setAccessibilityLabel("Submitted request: \(text)")
        let originalLength = (collapsed as NSString).length - (collapsed.hasSuffix("…") ? 1 : 0)
        submittedRequestView.annotations = annotations.compactMap { note in
            // A request note has no span to clip; it stays with the request.
            if note.isRequestScoped { return note }
            let clipped = NSIntersectionRange(note.range, NSRange(location: 0, length: max(0, originalLength)))
            return clipped.length > 0 ? note.with(range: clipped) : nil
        }
        editorHeight = 52
        layoutPad(width: view.bounds.width)
    }

    /// Keeps just the first visible line. If it wraps at the fixed pad width,
    /// shorten by measured glyph width and add an explicit ellipsis.
    static func collapsedRequest(_ text: String, width: CGFloat) -> String {
        let first = String(text.prefix { $0 != "\n" && $0 != "\r" })
        var visible = String(first.prefix(300))
        var clipped = visible.count < first.count || first.count < text.count
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        while !visible.isEmpty,
              ((visible + (clipped ? "…" : "")) as NSString).size(withAttributes: attributes).width > width {
            visible.removeLast()
            clipped = true
        }
        return visible + (clipped ? "…" : "")
    }

    func clearResultBody() {
        for indicator in workingView?.subviews.compactMap({ $0 as? OmniPadWorkingIndicator }) ?? [] {
            indicator.stop()
        }
        workingView?.removeFromSuperview()
        workingView = nil
        chooserView?.removeFromSuperview()
        chooserView = nil
        chooserRows = []
        optionsView?.removeFromSuperview()
        optionsView = nil
        optionRows = []
        noticedRows = []
        pickerView?.removeFromSuperview()
        pickerView = nil
        pickerRowViews = []
        resultFade?.removeFromSuperview()
        resultFade = nil
        resultScrollView?.isHidden = true
        resultTextView.string = ""
        resultContentHeight = 0
        retryButton.isHidden = true
        bodyHeight = 0
    }

    private func configureResultBody(_ value: OmniPadResult) {
        let text = value.body
        let width = max(1, view.bounds.width - 40)
        let oneLine = !text.contains("\n") &&
            (text as NSString).size(withAttributes: [.font: OmniFrostedStyle.commandFont]).width <= width - 8
        let font = oneLine ? OmniFrostedStyle.commandFont : NSFont.systemFont(ofSize: 15)
        resultTextView.font = font
        resultTextView.textColor = {
            if case .failure = value.kind { return OmniFrostedStyle.warning }
            return OmniFrostedStyle.ink
        }()
        resultTextView.string = text
        resultTextView.setAccessibilityLabel(text)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let naturalHeight = ceil(attributed.boundingRect(
            with: NSSize(width: width - 8, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 20
        let visibleHeight = min(240, max(46, naturalHeight))
        resultContentHeight = naturalHeight
        resultScrollView?.isHidden = false
        retryButton.isHidden = {
            if case .failure(retryAllowed: true) = value.kind { return false }
            return true
        }()
        bodyHeight = visibleHeight + (retryButton.isHidden ? 16 : 52)
        if naturalHeight > visibleHeight {
            let fade = OmniPadResultFade(frame: .zero)
            fade.setAccessibilityIdentifier("omni.pad.result-fade")
            view.addSubview(fade)
            resultFade = fade
        }
        layoutPad(width: view.bounds.width)
    }

    // MARK: Rendering

    func resolvedRoute(_ intent: ParsedIntent) -> OmniPadRoute? {
        let typed = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if OmniRecallRoute.intent(in: typed) != nil
            || (typed.hasPrefix("/rec") && OmniRecallRoute.token.hasPrefix(typed))
            || OmniRatioRoute.query(in: typed) != nil
            || (typed.hasPrefix("/ra") && OmniRatioRoute.token.hasPrefix(typed))
            || OmniMapRoute.query(in: typed) != nil
            || (typed.hasPrefix("/ma") && OmniMapRoute.token.hasPrefix(typed))
            || OmniWeatherRoute.query(in: typed) != nil
            || (typed.hasPrefix("/we") && OmniWeatherRoute.token.hasPrefix(typed))
            || OmniQRRoute.payload(in: typed) != nil
            || (typed.hasPrefix("/q") && OmniQRRoute.token.hasPrefix(typed))
            || OmniRegexRoute.input(in: editor.string) != nil
            || (typed.hasPrefix("/re") && OmniRegexRoute.token.hasPrefix(typed))
            || OmniPronunciationRoute.term(in: typed) != nil
            || (typed.hasPrefix("/pr") && OmniPronunciationRoute.token.hasPrefix(typed))
            || OmniExpressRoute.text(in: typed) != nil
            || (typed.hasPrefix("/ex") && OmniExpressRoute.token.hasPrefix(typed)) {
            return nil
        }
        if let onResolveRoute { return onResolveRoute(intent, selectedModelProfileID) }
        if let legacy = onResolveModelRoute?(intent.canonicalText, selectedModelProfileID) {
            return OmniPadRoute(providerName: legacy)
        }
        return nil
    }

    private func renderVisibleText(refreshFooter: Bool = true) {
        editor.reconcileAnnotations()
        refreshStashImport()
        let selection = editor.selectedRange()
        // Read before the rewrite: replacing the storage moves the caret.
        let quickLaunch = matchedQuickLaunch
        let fontSize = editor.string.contains(where: \.isNewline)
            ? OmniFrostedStyle.sourceTextFontSize
            : OmniFrostedStyle.commandFont.pointSize
        applyingRewrite = true
        if OmniPronunciationRoute.term(in: editor.string) != nil
            || OmniExpressRoute.text(in: editor.string) != nil
            || OmniRecallRoute.intent(in: editor.string) != nil
            || OmniRatioRoute.query(in: editor.string) != nil
            || OmniMapRoute.query(in: editor.string) != nil
            || OmniWeatherRoute.query(in: editor.string) != nil
            || OmniQRRoute.payload(in: editor.string) != nil
            || OmniRegexRoute.input(in: editor.string) != nil {
            // Do not paint slash-looking term words as commands or unknowns.
            let text = editor.string
            let styled = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: OmniFrostedStyle.ink,
            ])
            let token = OmniRecallRoute.intent(in: text) != nil ? OmniRecallRoute.token
                : OmniRatioRoute.query(in: text) != nil ? OmniRatioRoute.token
                : OmniMapRoute.query(in: text) != nil ? OmniMapRoute.token
                : OmniWeatherRoute.query(in: text) != nil ? OmniWeatherRoute.token
                : OmniQRRoute.payload(in: text) != nil ? OmniQRRoute.token
                : OmniRegexRoute.input(in: text) != nil ? OmniRegexRoute.token
                : OmniExpressRoute.text(in: text) != nil ? OmniExpressRoute.token : OmniPronunciationRoute.token
            let tokenRange = (text as NSString).range(of: token)
            styled.addAttributes([
                .foregroundColor: OmniFrostedStyle.command,
                .backgroundColor: OmniFrostedStyle.commandTokenFill,
                .font: fontSize == 22 ? OmniFrostedStyle.commandFont : NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            ], range: tokenRange)
            editor.textStorage?.setAttributedString(styled)
        } else if quickLaunch != nil {
            // An abbreviation is a mode switch, so it reads as one (quick-launch §1).
            editor.textStorage?.setAttributedString(NSAttributedString(string: editor.string, attributes: [
                .foregroundColor: OmniFrostedStyle.mode,
                .backgroundColor: OmniFrostedStyle.modeTokenFill,
                .font: fontSize == 22 ? OmniFrostedStyle.commandFont : NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            ]))
        } else {
            editor.textStorage?.setAttributedString(OmniTokenRenderer.attributedText(editor.string, parser: parser, fontSize: fontSize, findFacets: onRequestFindFacets?(),
                unresolvedAtoms: unresolvedStashAtom.map { [$0] } ?? []))
        }
        renderedQuickLaunch = quickLaunch
        editor.setSelectedRange(selection)
        editor.typingAttributes[.font] = NSFont.systemFont(ofSize: fontSize)
        applyingRewrite = false
        if refreshFooter { renderFooter() }
        if !updatingTextPresentation { annotationUI.changed() }
    }

    func renderFooter() {
        let parsed = parser.parse(textForParsing)
        var visibleRoute: OmniPadRoute?
        refreshOfferRow(parsed)
        let localFooter: OmniPadFooterState? = {
            guard mode == .composing || mode == .suggesting else { return nil }
            if let token = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace).first.map(String.init),
               let route = contributedSlashRoutes.first(where: { $0.token == token }) {
                if !isActionAvailable("tool.\(route.toolID)") {
                    return OmniPadFooterState(routeLine: .attention("This tool is disabled in Settings."),
                        keyHints: OmniPadKeyHint.dismissOnly, runEnabled: false, submits: false)
                }
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) }
                    ?? .outcome("\(route.title) · opens native panel"),
                    keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true)
            }
            if OmniCharactersRoute.query(in: editor.string) != nil, isActionAvailable("tool.characters") {
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .outcome("Characters · opens native panel"),
                    keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true)
            }
            if OmniWeatherRoute.query(in: editor.string) != nil, isActionAvailable("tool.weather") {
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .outcome("Weather · opens native panel"),
                    keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true)
            }
            if OmniQRRoute.payload(in: editor.string) != nil, isActionAvailable("tool.qr") {
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .outcome("QR · opens native panel"),
                    keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true)
            }
            if OmniRegexRoute.input(in: editor.string) != nil, isActionAvailable("tool.regex") {
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .outcome("Regex · opens native panel"),
                    keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true)
            }
            if OmniMapRoute.query(in: editor.string) != nil, isActionAvailable("tool.map") {
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .outcome("Map · opens native panel"),
                    keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true)
            }
            if OmniClipboardRoute.query(in: editor.string) != nil, isActionAvailable("clipboard.history") {
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .outcome("Clipboard history · opens picker"),
                    keyHints: OmniPadKeyHint.clipboard, runEnabled: true, submits: true)
            }
            switch localCalculatorState() {
            case .ordinary: return nil
            case .incomplete:
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .hint("Continue the calculation"),
                    keyHints: OmniPadKeyHint.dismissOnly, runEnabled: false, submits: false)
            case .failure(let message):
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .attention(message),
                    keyHints: OmniPadKeyHint.dismissOnly, runEnabled: false, submits: false)
            case .result(let answer):
                return OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .outcome("= \(answer)"),
                    keyHints: OmniPadKeyHint.calculator, runEnabled: true, submits: true)
            }
        }()
        switch mode {
        case .composing:
            // Material resolves only the `/stance` route: resolving the bare
            // text too would alternate two command routes on every render.
            let localToolVisible = (OmniPronunciationRoute.term(in: editor.string) != nil && isActionAvailable("tool.pronunciation"))
                || (OmniExpressRoute.text(in: editor.string) != nil && isActionAvailable("tool.express"))
                || (OmniRecallRoute.intent(in: editor.string) != nil && isActionAvailable("tool.recall"))
                || (OmniRatioRoute.query(in: editor.string) != nil && isActionAvailable("tool.ratio"))
                || (OmniMapRoute.query(in: editor.string) != nil && isActionAvailable("tool.map"))
                || (OmniWeatherRoute.query(in: editor.string) != nil && isActionAvailable("tool.weather"))
                || (OmniQRRoute.payload(in: editor.string) != nil && isActionAvailable("tool.qr"))
                || (OmniRegexRoute.input(in: editor.string) != nil && isActionAvailable("tool.regex"))
                || (OmniCharactersRoute.query(in: editor.string) != nil && isActionAvailable("tool.characters"))
                || completionItems.contains(where: { $0.choice.canonicalText == OmniRecallRoute.token })
                || completionItems.contains(where: { $0.choice.canonicalText == OmniRatioRoute.token })
                || completionItems.contains(where: { $0.choice.canonicalText == OmniMapRoute.token })
                || completionItems.contains(where: { $0.choice.canonicalText == OmniWeatherRoute.token })
                || completionItems.contains(where: { $0.choice.canonicalText == OmniQRRoute.token })
                || completionItems.contains(where: { $0.choice.canonicalText == OmniRegexRoute.token })
                || completionItems.contains(where: { $0.choice.canonicalText == OmniCharactersRoute.token })
                || completionItems.contains(where: { $0.choice.canonicalText == OmniPronunciationRoute.token })
                || completionItems.contains(where: { $0.choice.canonicalText == OmniExpressRoute.token })
            visibleRoute = localToolVisible || localFooter != nil ? nil : (offerRowView != nil ? offerRoute(parsed) : resolvedRoute(parsed))
            if let localFooter {
                footerState = localFooter
            } else if let stashFooter = stashFooterState(parsed) {
                footerState = stashFooter
            } else if offerRowView != nil {
                footerState = Self.offerFooterState(route: visibleRoute, transientMessage: transientMessage)
            } else if isAnnotatedBareText(parsed), OmniIDAddress(editor.string) != nil {
                // A note makes an id a request, and an id never asks for a
                // proposal (D1): say so before Enter rather than after.
                footerState = OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .hint(Self.annotatedIDLine), keyHints: OmniPadKeyHint.dismissOnly, runEnabled: false, submits: false)
            } else if isAnnotatedBareText(parsed), visibleRoute?.unavailable == nil {
                // D2: a chosen position shows its title here too.
                let title = annotations.first(where: { $0.isRequestScoped && $0.label != nil })?.label.map { " · \($0)" } ?? ""
                footerState = OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .propose(Self.annotatedProposalLine + title), keyHints: OmniPadKeyHint.propose, runEnabled: true, submits: true)
            } else {
                footerState = Self.footerState(for: parsed, route: visibleRoute, completionVisible: isCompletionVisible, transientMessage: transientMessage, positionTitle: annotations.first(where: { $0.isRequestScoped && $0.label != nil })?.label)
            }
        case .suggesting:
            footerState = localFooter ?? Self.launcherFooterState(launcherState ?? OmniLauncherPadState(results: .empty(LauncherQuery(editor.string).text, lane: launcherLane)), transientMessage: transientMessage, unavailable: onLauncherHealth?(), idsPending: onIDLookupPending?() ?? false)
            if localFooter != nil { break }
            if OmniIDAddress(editor.string) != nil, launcherState?.results.query != LauncherQuery(editor.string).text {
                // Before the id's rows arrive: Enter still decides on the
                // current text (it resolves synchronously), never a proposal.
                footerState = OmniPadFooterState(routeLine: transientMessage.map { .notice($0) } ?? .hint(Self.idLookingUpLine), keyHints: OmniPadKeyHint.idLane, runEnabled: true, submits: true)
            } else if launcherLane == .curated, case .propose = launcherState?.enter ?? .propose(afterUndo: false) {
                visibleRoute = resolvedRoute(parsed)
                if let reason = visibleRoute?.unavailable {
                    let widen = Self.everywhereOffer(launcherState?.results)
                    footerState = OmniPadFooterState(routeLine: .attention(widen.map { reason + " · " + $0 } ?? reason), keyHints: OmniPadKeyHint.dismissOnly, runEnabled: false, submits: false)
                }
            }
        case .working:
            footerState = OmniPadFooterState(routeLine: .waiting(workingSummary), keyHints: OmniPadKeyHint.working, runEnabled: false, submits: false)
        case .result:
            let value = result ?? OmniPadResult(kind: .failure(retryAllowed: false), body: "", summary: "Result")
            switch value.kind {
            case .text:
                footerState = OmniPadFooterState(routeLine: .outcome(value.summary), keyHints: OmniPadKeyHint.textResult, runEnabled: true, submits: true)
            case .confirmation:
                footerState = OmniPadFooterState(routeLine: .outcome(value.summary), keyHints: OmniPadKeyHint.confirmationResult, runEnabled: false, submits: true)
            case .failure:
                footerState = OmniPadFooterState(routeLine: .attention(value.summary), keyHints: OmniPadKeyHint.failureResult, runEnabled: false, submits: false)
            case .proposal:
                footerState = OmniPadFooterState(routeLine: .outcome(value.summary), keyHints: OmniPadKeyHint.proposalResult, runEnabled: !alternatives.isEmpty, submits: true)
            case .options:
                footerState = OmniPadFooterState(routeLine: .outcome(value.summary), keyHints: optionsKeyHints, runEnabled: !(options?.options.isEmpty ?? true), submits: true)
            case .picker:
                footerState = pickerFooterState()
            }
        }
        if let tool = matchedQuickLaunch {
            // Hints follow state (quick-launch §1.1): Tab's new meaning shows before the key.
            footerState = OmniPadFooterState(routeLine: footerState.routeLine,
                keyHints: OmniPadKeyHint.quickLaunch(tool, over: footerState.keyHints),
                runEnabled: footerState.runEnabled, submits: footerState.submits)
        }
        keyHintsView.hints = editor.selectedRange().length > 0 && mode == .composing
            ? [.init("⇧⌘K", "Annotate"), .init("esc", "")]
            : footerState.keyHints
        runButton.isEnabled = footerState.runEnabled
        runButton.isHidden = {
            if case .working = mode { return true }
            if case .result = mode { return result?.kind != .text && result?.kind != .proposal && result?.kind != .options && !(result?.kind == .picker && !pickerRows.isEmpty) }
            return false
        }()
        runButton.symbolName = result?.kind == .text ? "doc.on.doc" : "arrow.up"
        runButton.setAccessibilityLabel(
            OmniClipboardRoute.query(in: editor.string) != nil ? "Open clipboard history"
                : OmniCharactersRoute.query(in: editor.string) != nil ? "Open Characters"
                : OmniMapRoute.query(in: editor.string) != nil ? "Open Map"
                : OmniWeatherRoute.query(in: editor.string) != nil ? "Open Weather"
                : OmniQRRoute.payload(in: editor.string) != nil ? "Open QR"
                : OmniRegexRoute.input(in: editor.string) != nil ? "Open Regex"
                : localFooter != nil ? "Copy calculation and close"
                : OmniRecallRoute.intent(in: editor.string) != nil ? "Open Recall"
                : OmniRatioRoute.query(in: editor.string) != nil ? "Open Ratio" : OmniPronunciationRoute.term(in: editor.string) != nil
                ? "Open pronunciation panel" : OmniMapRoute.query(in: editor.string) != nil ? "Open Map" : OmniExpressRoute.text(in: editor.string) != nil
                ? "Open Express panel" : (result?.kind == .text ? "Copy and close" : "Run")
        )
        let noteCount = (mode == .composing || mode == .suggesting) ? annotations.count : submittedRequestView.annotations.count
        notesButton.isHidden = noteCount == 0 || !(mode == .composing || mode == .suggesting)
        notesButton.title = "\(noteCount) note\(noteCount == 1 ? "" : "s")"
        notesButton.setAccessibilityLabel("Show \(notesButton.title) in text order")
        settingsButton.isHidden = {
            if case .attention = footerState.routeLine, mode == .composing, visibleRoute?.offersSettings == true { return false }
            return true
        }()
        // C116: the footer's model chevron is retired. Model choice lives in
        // Settings → Models and `/model`; the route line's tooltip names the model.
        modelPopUp.isHidden = true
        let override = modelChoices.first(where: { $0.id == selectedModelProfileID })
        modelOverrideLabel.stringValue = override?.label ?? ""
        modelOverrideLabel.isHidden = modelPopUp.isHidden || override == nil
        clearModelButton.isHidden = modelOverrideLabel.isHidden
        let routeName = visibleRoute?.displayName ?? visibleRoute?.providerName ?? override?.label
        let routeScope = selectedModelProfileID != nil || visibleRoute?.scope == .thisRunOnly ? "this run" : "default"
        modelPopUp.toolTip = nil
        statusLabel.toolTip = [routeName.map { "\($0) (\(routeScope))" }, visibleRoute?.recoveryHint]
            .compactMap { $0 }.joined(separator: "\n").nilIfEmpty
        statusLabel.attributedStringValue = Self.attributedRouteLine(footerState.routeLine)
        statusLabel.setAccessibilityLabel(footerState.routeLine.text)
        annotationUI.updateMark()
        layoutPad(width: view.bounds.width)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        annotationUI.updateMark()
        // The match needs the caret at the end, so moving it can change the tint.
        if isViewLoaded, !applyingRewrite, matchedQuickLaunch != renderedQuickLaunch {
            renderVisibleText(refreshFooter: false)
        }
        if isViewLoaded { renderFooter() }
    }

    /// The registered abbreviation the whole field spells, caret at the end,
    /// while Tab would otherwise edit or widen bare text (quick-launch §1).
    public var matchedQuickLaunch: OmniQuickLaunch? {
        guard onQuickLaunch != nil, !quickLaunchTools.isEmpty, mode == .composing || mode == .suggesting,
              editor.isEditable, !editor.hasMarkedText(), annotations.isEmpty else { return nil }
        let text = editor.string
        let selection = editor.selectedRange()
        guard selection.length == 0, selection.location == (text as NSString).length else { return nil }
        return quickLaunchTools.first { $0.letters == text }
    }

    /// The pad's whole footer, derived from one parse (C19–C31).
    public static func footerState(
        for intent: ParsedIntent,
        route: OmniPadRoute?,
        completionVisible: Bool,
        transientMessage: String?,
        positionTitle: String? = nil
    ) -> OmniPadFooterState {
        if OmniRecallRoute.intent(in: intent.rawText) != nil {
            return OmniPadFooterState(
                routeLine: transientMessage.map { .notice($0) } ?? .outcome("Recall · opens native panel"),
                keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true
            )
        }
        if OmniRatioRoute.query(in: intent.rawText) != nil {
            return OmniPadFooterState(
                routeLine: transientMessage.map { .notice($0) } ?? .outcome("Ratio · opens native panel"),
                keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true
            )
        }
        if OmniCharactersRoute.query(in: intent.rawText) != nil {
            return OmniPadFooterState(
                routeLine: transientMessage.map { .notice($0) } ?? .outcome("Characters · opens native panel"),
                keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true
            )
        }
        if OmniWeatherRoute.query(in: intent.rawText) != nil {
            return OmniPadFooterState(
                routeLine: transientMessage.map { .notice($0) } ?? .outcome("Weather · opens native panel"),
                keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true
            )
        }
        if OmniQRRoute.payload(in: intent.rawText) != nil {
            return OmniPadFooterState(
                routeLine: transientMessage.map { .notice($0) } ?? .outcome("QR · opens native panel"),
                keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true
            )
        }
        if OmniRegexRoute.input(in: intent.rawText) != nil {
            return OmniPadFooterState(
                routeLine: transientMessage.map { .notice($0) } ?? .outcome("Regex · opens native panel"),
                keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true
            )
        }
        if OmniMapRoute.query(in: intent.rawText) != nil {
            return OmniPadFooterState(
                routeLine: transientMessage.map { .notice($0) } ?? .outcome("Map · opens native panel"),
                keyHints: OmniPadKeyHint.pronunciation, runEnabled: true, submits: true
            )
        }
        if OmniPronunciationRoute.term(in: intent.rawText) != nil {
            return OmniPadFooterState(
                routeLine: transientMessage.map { .notice($0) } ?? .outcome("Pronunciation · opens native panel"),
                keyHints: OmniPadKeyHint.pronunciation,
                runEnabled: true,
                submits: true
            )
        }
        if OmniExpressRoute.text(in: intent.rawText) != nil {
            return OmniPadFooterState(
                routeLine: transientMessage.map { .notice($0) } ?? .outcome("Express · opens native panel"),
                keyHints: OmniPadKeyHint.pronunciation,
                runEnabled: true,
                submits: true
            )
        }
        var line: OmniPadRouteLine
        var hints = OmniPadKeyHint.run
        var runEnabled = true
        var submits = true
        switch SubmissionClassifier().classify(intent) {
        case .disabled:
            line = .hint(emptyHint)
            runEnabled = false
            submits = false
        case .referenceChoice:
            line = .hint("Choose which @reference you mean · ↩")
        case .tier2:
            if let unavailable = route?.unavailable {
                line = .attention(unavailable)
                hints = OmniPadKeyHint.dismissOnly
                runEnabled = false
                submits = false
            } else if let diagnostic = intent.diagnostics.first {
                let reason: String = if case .unknownSlash(let token) = diagnostic { "\(token) isn't a command" } else { diagnostic.statusLabel }
                line = .propose("\(reason) · ↩ asks for a proposal instead")
                hints = OmniPadKeyHint.propose
            } else if intent.primaryTokens.count + intent.settingsTokens.count >= 2 {
                line = .propose("Two commands · ↩ asks for a proposal instead")
                hints = OmniPadKeyHint.propose
            } else {
                line = .hint(addCommandHint)
                runEnabled = false
                submits = false
            }
        case .tier1(let token):
            if let unavailable = route?.unavailable {
                line = .attention(unavailable)
                hints = OmniPadKeyHint.dismissOnly
                runEnabled = false
                submits = false
            } else {
                // D2: a chosen position shows its title in the route line.
                line = .outcome(outcomeLine(token: token, intent: intent, route: route) + (positionTitle.map { " · \($0)" } ?? ""))
            }
        }
        if completionVisible, route?.unavailable == nil {
            // The menu is cheap: it never changes what Enter does (C25), so the
            // ↑ button stays what it is (C22); the hints add Tab and esc. Over a
            // bare `/` nothing submits, so the hints promise no run (C78).
            line = .hint(typingHint)
            hints = submits ? OmniPadKeyHint.completion : OmniPadKeyHint.completionBrowse
        }
        if route?.unavailable != nil {
            // Completion is a hint, never permission to submit an unavailable model.
            runEnabled = false
            submits = false
        }
        if let transientMessage { line = .notice(transientMessage) }
        return OmniPadFooterState(routeLine: line, keyHints: hints, runEnabled: runEnabled, submits: submits)
    }

    static func outcomeLine(token: String, intent: ParsedIntent, route: OmniPadRoute?) -> String {
        // `/span` (C82) confirms its parse while typing: the endpoints as
        // read and the headline. Until the payload parses, the static outcome.
        if token == "/span", let span = SpanCalculator.result(payload: SpanCalculator.payload(fromCommandText: intent.rawText)) {
            return span.headline
        }
        var parts = [OmniPadVocabulary.outcome(for: token)]
        if let value = intent.tokenValues[token]?.canonical, !value.isEmpty { parts.append(value) }
        parts.append(contentsOf: OmniPadVocabulary.modifierWords(intent))
        if route?.scope == .thisRunOnly, route?.providerName == "Local" {
            parts.append("Local, this run only")
        }
        return parts.joined(separator: " · ")
    }

    static func attributedRouteLine(_ line: OmniPadRouteLine) -> NSAttributedString {
        let secondary: [NSAttributedString.Key: Any] = [.font: OmniFrostedStyle.diagnosticFont, .foregroundColor: OmniFrostedStyle.secondaryInk]
        let emphasis: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: OmniFrostedStyle.ink]
        switch line {
        case .outcome(let text):
            let result = NSMutableAttributedString(string: text, attributes: secondary)
            let head = (text as NSString).range(of: " · ")
            result.addAttributes(emphasis, range: NSRange(location: 0, length: head.location == NSNotFound ? (text as NSString).length : head.location))
            return result
        case .attention(let text):
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: OmniFrostedStyle.warning])
        case .propose(let text):
            let result = NSMutableAttributedString(string: text, attributes: secondary)
            if text.hasPrefix("/"), let space = text.firstIndex(of: " ") {
                result.addAttributes(emphasis, range: NSRange(location: 0, length: text.distance(from: text.startIndex, to: space)))
            }
            return result
        case .hint(let text), .notice(let text), .waiting(let text):
            return NSAttributedString(string: text, attributes: secondary)
        }
    }

    // MARK: Layout

    func updateEditorHeight(relayout: Bool = true) {
        guard mode == .composing || mode == .suggesting else { return }
        guard let scroll = editorScrollView, let container = editor.textContainer, let layout = editor.layoutManager else { return }
        container.containerSize = NSSize(width: max(1, scroll.contentSize.width - editor.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        editorHeight = min(210, max(52, ceil(layout.usedRect(for: container).height + editor.textContainerInset.height * 2 + 2)))
        if relayout { layoutPad(width: view.bounds.width) }
    }

    private var padHeight: CGFloat {
        let visibleProvenance = mode == .composing || mode == .suggesting ? composingChip : submittedProvenance
        return 12 + (visibleProvenance == nil && launcherScopeChip.isHidden ? 0 : 34) + editorHeight + bodyHeight + footerHeight
    }

    func layoutPad(width: CGFloat) {
        guard view.subviews.contains(runButton) else { return }
        let contentWidth = max(1, width - 32)
        runButton.frame = NSRect(x: width - 16 - 28, y: 8, width: 28, height: 28)
        let hintsWidth = min(keyHintsView.fittingWidth, max(1, runButton.frame.minX - 12 - 16))
        let hintsHeight = keyHintsView.fittingHeight(forWidth: hintsWidth)
        keyHintsView.frame = NSRect(x: runButton.frame.minX - 12 - hintsWidth, y: 12, width: hintsWidth, height: hintsHeight)
        let actionRowHeight = max(44, hintsHeight + 24)
        let modelVisible = !modelPopUp.isHidden
        let desiredOverrideWidth: CGFloat = modelOverrideLabel.isHidden ? 0 : min(240, ceil(modelOverrideLabel.fittingSize.width) + 2)
        let fixedModelWidth: CGFloat = modelVisible ? 24 + (modelOverrideLabel.isHidden ? 0 : 4) + (clearModelButton.isHidden ? 0 : 4 + 22) : 0
        let optionalWidth = (notesButton.isHidden ? 0 : notesButton.fittingWidth + 8)
            + (settingsButton.isHidden ? 0 : settingsButton.fittingWidth + 8)
        // At constrained display widths, keep the same controls in a separate
        // footer row rather than painting model/notes controls over key hints.
        let hasSecondaryControls = modelVisible || optionalWidth > 0
        let separateControls = hasSecondaryControls
            && keyHintsView.frame.minX - 12 - optionalWidth - 16 < fixedModelWidth + desiredOverrideWidth
        let controlCenterY: CGFloat = separateControls ? actionRowHeight + 12 : 22
        var leftLimit = separateControls ? width - 16 : keyHintsView.frame.minX - 12
        if !notesButton.isHidden {
            let buttonWidth = notesButton.fittingWidth
            notesButton.frame = NSRect(x: leftLimit - buttonWidth, y: controlCenterY - 11, width: buttonWidth, height: 22)
            leftLimit = notesButton.frame.minX - 8
        }
        if !settingsButton.isHidden {
            let buttonWidth = settingsButton.fittingWidth
            settingsButton.frame = NSRect(x: leftLimit - buttonWidth, y: controlCenterY - 11, width: buttonWidth, height: 22)
            leftLimit = settingsButton.frame.minX - 8
        }

        let route = statusLabel.attributedStringValue
        let overrideWidth = min(desiredOverrideWidth, max(0, leftLimit - 16 - fixedModelWidth))
        let modelWidth = fixedModelWidth + overrideWidth
        let modelGap: CGFloat = modelVisible ? 4 : 0
        let inlineWidth = max(1, leftLimit - 16 - modelWidth - modelGap)
        let fittingWidth = ceil(route.size().width) + 4
        let modelX: CGFloat
        if !separateControls && hintsHeight <= 20 && fittingWidth <= inlineWidth {
            footerHeight = 44
            statusLabel.preferredMaxLayoutWidth = inlineWidth
            statusLabel.frame = NSRect(x: 16, y: 13, width: fittingWidth, height: 18)
            modelX = statusLabel.frame.maxX + modelGap
        } else {
            // Long routes get a full-width row; the model control starts the
            // lower row, before notes and hints, without clipping either.
            statusLabel.preferredMaxLayoutWidth = contentWidth
            let routeHeight = max(18, ceil(route.boundingRect(
                with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height) + 4)
            let routeY = actionRowHeight + (separateControls ? 32 : 0)
            statusLabel.frame = NSRect(x: 16, y: routeY, width: contentWidth, height: routeHeight)
            footerHeight = routeY + routeHeight + 8
            modelX = 16
        }
        if modelVisible {
            var nextX = modelX
            if !modelOverrideLabel.isHidden {
                modelOverrideLabel.frame = NSRect(x: nextX, y: controlCenterY - 9, width: overrideWidth, height: 18)
                modelOverrideLabel.toolTip = modelOverrideLabel.stringValue
                nextX += overrideWidth + 4
            }
            modelPopUp.frame = NSRect(x: nextX, y: controlCenterY - 13, width: 24, height: 26)
            nextX += 28
            if !clearModelButton.isHidden {
                clearModelButton.frame = NSRect(x: nextX, y: controlCenterY - 12, width: 22, height: 24)
            }
        }

        let total = padHeight
        if view.frame.size.height != total {
            view.frame.size.height = total
            if let window = view.window {
                var frame = window.frame
                let top = frame.maxY
                frame.size.height = min(window.screen?.visibleFrame.height ?? total, total)
                frame.origin.y = top - frame.size.height
                window.setFrame(frame, display: true)
            }
        }
        let footer = footerHeight
        if !provenanceChip.isHidden {
            let chipWidth = min(contentWidth - 100, provenanceChip.fittingWidth)
            provenanceChip.frame = NSRect(x: 16, y: total - 12 - 26, width: chipWidth, height: 26)
            wordCountLabel.frame = NSRect(x: width - 16 - 120, y: total - 12 - 22, width: 120, height: 18)
        }
        if !launcherScopeChip.isHidden {
            launcherScopeChip.frame = NSRect(x: 16, y: total - 12 - 26, width: launcherScopeChip.fittingWidth, height: 26)
        }
        editorScrollView?.frame = NSRect(x: 16, y: footer + bodyHeight, width: contentWidth, height: editorHeight)
        submittedRequestScrollView?.frame = NSRect(x: 16, y: footer + bodyHeight, width: contentWidth, height: editorHeight)
        submittedRequestView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: editorHeight)
        chooserView?.frame = NSRect(x: 0, y: footer, width: width, height: bodyHeight)
        optionsView?.frame = NSRect(x: 0, y: footer, width: width, height: bodyHeight)
        pickerView?.frame = NSRect(x: 0, y: footer, width: width, height: bodyHeight)
        offerRowView?.frame = NSRect(x: 12, y: footer + 4, width: width - 24, height: OmniOfferRow.rowHeight)
        workingView?.frame = NSRect(x: 0, y: footer, width: width, height: bodyHeight)
        launcherView?.frame = NSRect(x: 0, y: footer, width: width, height: bodyHeight)
        if let resultScrollView, !resultScrollView.isHidden {
            let retryOffset: CGFloat = retryButton.isHidden ? 0 : 36
            let scrollHeight = bodyHeight - retryOffset - 16
            resultScrollView.frame = NSRect(x: 16, y: footer + retryOffset + 8, width: contentWidth, height: scrollHeight)
            resultTextView.frame.size = NSSize(width: contentWidth, height: max(scrollHeight, resultContentHeight))
            resultFade?.frame = NSRect(x: 16, y: resultScrollView.frame.minY, width: contentWidth, height: 22)
            retryButton.frame = NSRect(x: 16, y: footer + 10, width: 68, height: 24)
        }
        let documentWidth = editorScrollView?.contentSize.width ?? contentWidth
        editor.frame.size.width = documentWidth
        if let container = editor.textContainer, let layout = editor.layoutManager {
            container.containerSize = NSSize(width: max(1, documentWidth - editor.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            editor.frame.size.height = max(editorHeight, ceil(layout.usedRect(for: container).height + editor.textContainerInset.height * 2))
        }
        if let scroll = editorScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
        footerSeparator.frame = NSRect(x: 16, y: footer - 1, width: contentWidth, height: OmniFrostedStyle.hairlineWidth)

    }

    /// Brings the field forward (after a proposal or a settings panel) and
    /// re-lays the pad out.
    public func showCommandEditor() {
        referencePicker?.orderOut(nil)
        modelPopUp.isHidden = true
        let visibleProvenance = mode == .composing || mode == .suggesting ? composingChip : submittedProvenance
        displayProvenance(visibleProvenance)
        view.frame.size.height = padHeight
        renderFooter()
        updateEditorHeight()
        editor.window?.makeFirstResponder(editor)
    }
}

// MARK: - Views

/// One palette row (C78): the choice Tab inserts, its role for the tint, and
/// what the help column says while it is highlighted.
public struct OmniCompletionItem: Equatable, Sendable {
    public let choice: OmniReferenceChoice
    public let role: TokenRole
    public let help: OmniCommandHelp

    public init(choice: OmniReferenceChoice, role: TokenRole, help: OmniCommandHelp) {
        self.choice = choice
        self.role = role
        self.help = help
    }
}

/// The help column's content for one command: its token, what it reaches for,
/// a factual paragraph, and argument shapes from the manifest.
public struct OmniCommandHelp: Equatable, Sendable {
    public let token: String
    public let kind: String
    public let body: String
    public let usage: [String]

    public init(token: String, kind: String, body: String, usage: [String]) {
        self.token = token
        self.kind = kind
        self.body = body
        self.usage = usage
    }
}

/// The completion palette (C25, C78): cheap, floating above the pad at the
/// caret, accepted with Tab. It never takes key focus. A bare `/` lists every
/// command; past eight rows, or fewer when the screen above the pad is short,
/// the list scrolls, with the keyboard and with the trackpad under the
/// pointer; the help column describes the highlighted row.
@MainActor public final class OmniCompletionMenu: NSPanel {
    public static let rowHeight: CGFloat = 30
    public static let visibleRows = 8
    public static let listWidth: CGFloat = 300
    public static let helpWidth: CGFloat = 300
    /// Between the pad and the palette.
    public static let gap: CGFloat = 8
    static let inset: CGFloat = 6

    public var onChoose: ((Int) -> Void)?
    /// The pointer moved onto a row that is not the highlighted one.
    public var onHover: ((Int) -> Void)?
    public let items: [OmniCompletionItem]
    public private(set) var highlighted: Int
    public let listScrollView: NSScrollView
    public let helpView: OmniCompletionHelpView
    /// Rows in view at once: up to eight, fewer when the room above is short.
    public let visibleRowCount: Int
    /// Set when even the fitted panel could not sit above the pad.
    public private(set) var isBelowPad = false
    private let listView: OmniCompletionListView
    private var rows: [OmniCompletionRow] = []

    /// The panel can never be shorter than the tallest help among `items`.
    public static func minimumHeight(for items: [OmniCompletionItem]) -> CGFloat {
        items.map { OmniCompletionHelpView.fittingHeight(for: $0, width: helpWidth) }.max() ?? 0
    }

    /// `room` is the vertical space the palette may take; `.infinity` (or
    /// anything huge) means the full eight rows.
    public init(items: [OmniCompletionItem], highlighted: Int, room: CGFloat = .infinity) {
        self.items = items
        self.highlighted = highlighted
        // Clamped as a CGFloat on both sides before the conversion: a huge,
        // infinite or NaN room means eight rows, a negative one means one row.
        let rowsInRoom = max(1, min(CGFloat(Self.visibleRows), ((room - Self.inset * 2) / Self.rowHeight).rounded(.down)))
        let visibleRowCount = min(items.count, Int(rowsInRoom))
        self.visibleRowCount = visibleRowCount
        let visibleHeight = CGFloat(visibleRowCount) * Self.rowHeight
        let listHeight = visibleHeight + Self.inset * 2
        let height = max(listHeight, Self.minimumHeight(for: items))
        let width = Self.listWidth + Self.helpWidth
        let listView = OmniCompletionListView(frame: NSRect(x: 0, y: 0, width: Self.listWidth - Self.inset * 2, height: CGFloat(items.count) * Self.rowHeight))
        self.listView = listView
        let scroll = NSScrollView(frame: NSRect(x: Self.inset, y: height - Self.inset - visibleHeight, width: Self.listWidth - Self.inset * 2, height: visibleHeight))
        self.listScrollView = scroll
        self.helpView = OmniCompletionHelpView(frame: NSRect(x: Self.listWidth, y: 0, width: Self.helpWidth, height: height))
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        let root = OmniMaterialView(frame: NSRect(x: 0, y: 0, width: width, height: height), cornerRadius: 12)
        root.setAccessibilityIdentifier("omni.completion-menu")

        for (index, item) in items.enumerated() {
            let row = OmniCompletionRow(item: item) { [weak self] in self?.onChoose?(index) }
            row.frame = NSRect(x: 0, y: Self.rowHeight * CGFloat(index), width: listView.bounds.width, height: Self.rowHeight)
            row.setAccessibilityIdentifier("omni.completion.\(item.choice.id)")
            listView.addSubview(row)
            rows.append(row)
        }
        listView.onHover = { [weak self] index in
            guard let self, index != self.highlighted else { return }
            self.onHover?(index)
        }
        scroll.documentView = listView
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.setAccessibilityIdentifier("omni.completion-list")
        root.addSubview(scroll)
        helpView.setAccessibilityIdentifier("omni.completion-help")
        root.addSubview(helpView)
        contentView = root
        highlight(highlighted, scrollingIntoView: true)
    }

    public override var canBecomeKey: Bool { false }

    /// Token tint by role (C20, C41); settings share the command tint.
    public static func tint(for role: TokenRole) -> NSColor {
        switch role {
        case .modifier: OmniFrostedStyle.modifier
        case .mode: OmniFrostedStyle.mode
        case .primary, .settings, .alias: OmniFrostedStyle.command
        }
    }

    /// Arrow keys scroll the highlight into view; a hover never scrolls.
    public func highlight(_ index: Int, scrollingIntoView: Bool = true) {
        guard items.indices.contains(index) else { return }
        highlighted = index
        for (offset, row) in rows.enumerated() { row.isHighlightedRow = offset == index }
        if scrollingIntoView {
            listView.scrollToVisible(NSRect(x: 0, y: Self.rowHeight * CGFloat(index), width: listView.bounds.width, height: Self.rowHeight))
            listScrollView.reflectScrolledClipView(listScrollView.contentView)
        }
        helpView.item = items[index]
    }

    /// Above the pad, left edge at the caret (clamped to the pad); below the
    /// pad only when even the fitted panel cannot sit above it on this screen.
    public func present(above padFrame: NSRect, caretX: CGFloat, screenTop: CGFloat = .infinity) {
        let x = min(max(caretX - 12, padFrame.minX), padFrame.maxX - frame.width)
        let above = padFrame.maxY + Self.gap
        isBelowPad = above + frame.height > screenTop
        setFrameOrigin(NSPoint(x: x, y: isBelowPad ? padFrame.minY - Self.gap - frame.height : above))
        orderFrontRegardless()
        // Say that there is more: the overlay scroller is otherwise invisible
        // until the first scroll, and the last row ends exactly at the edge.
        // The menu is rebuilt per keystroke, so this repeats while filtering.
        if items.count > visibleRowCount { listScrollView.flashScrollers() }
    }
}

/// The scrolling list's document: rows stack from the top. Only the pointer's
/// own movement names a row: content scrolling under a resting pointer, and
/// the jitter of fingers landing on a trackpad, never steal the keyboard's
/// highlight, because an event from the same screen spot is ignored.
@MainActor final class OmniCompletionListView: NSView {
    /// The row under the moving pointer; the menu ignores the highlighted one.
    var onHover: ((Int) -> Void)?
    /// Where the pointer was last seen, in screen points.
    var lastPointer = NSEvent.mouseLocation
    static let movementThreshold: CGFloat = 2

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        guard hypot(screenPoint.x - lastPointer.x, screenPoint.y - lastPointer.y) >= Self.movementThreshold else { return }
        lastPointer = screenPoint
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onHover?(Int(point.y / OmniCompletionMenu.rowHeight))
    }
}

/// The help column (C78): token, kind, a factual paragraph, argument shapes.
@MainActor public final class OmniCompletionHelpView: NSView {
    static let padding: CGFloat = 12
    static let tokenFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let kindFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let bodyFont = NSFont.systemFont(ofSize: 12)
    static let usageFont = NSFont.systemFont(ofSize: 11)

    public var item: OmniCompletionItem? {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(item.map { "\($0.help.token). \($0.help.body)" } ?? "")
        }
    }

    public override var isFlipped: Bool { true }
    public override var allowsVibrancy: Bool { false }

    public static func fittingHeight(for item: OmniCompletionItem, width: CGFloat) -> CGFloat {
        var y = padding
        y += tokenFont.pointSize + 6
        y += kindFont.pointSize + 6
        let textWidth = width - padding * 2
        y += textHeight(item.help.body, font: bodyFont, width: textWidth)
        for line in item.help.usage { y += 4 + textHeight(line, font: usageFont, width: textWidth) }
        return ceil(y + padding)
    }

    static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// Measured the way `draw(with:options:)` lays it out, plus a point of slack.
    static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let bounds = attributed(text, font: font, color: .black).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: drawingOptions)
        return ceil(bounds.height) + 1
    }

    public override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.line.setFill()
        NSRect(x: 0, y: 10, width: OmniFrostedStyle.hairlineWidth, height: bounds.height - 20).fill()
        guard let item else { return }
        let padding = Self.padding
        let textWidth = bounds.width - padding * 2
        var y = padding
        (item.help.token as NSString).draw(at: NSPoint(x: padding, y: y), withAttributes: [.font: Self.tokenFont, .foregroundColor: OmniCompletionMenu.tint(for: item.role)])
        y += Self.tokenFont.pointSize + 6
        (item.help.kind as NSString).draw(at: NSPoint(x: padding, y: y), withAttributes: [.font: Self.kindFont, .foregroundColor: OmniFrostedStyle.secondaryInk])
        y += Self.kindFont.pointSize + 6
        let bodyHeight = Self.textHeight(item.help.body, font: Self.bodyFont, width: textWidth)
        Self.attributed(item.help.body, font: Self.bodyFont, color: OmniFrostedStyle.ink)
            .draw(with: NSRect(x: padding, y: y, width: textWidth, height: bodyHeight), options: Self.drawingOptions)
        y += bodyHeight
        for line in item.help.usage {
            y += 4
            let height = Self.textHeight(line, font: Self.usageFont, width: textWidth)
            Self.attributed(line, font: Self.usageFont, color: OmniFrostedStyle.secondaryInk)
                .draw(with: NSRect(x: padding, y: y, width: textWidth, height: height), options: Self.drawingOptions)
            y += height
        }
    }
}

@MainActor final class OmniCompletionRow: NSButton {
    let item: OmniCompletionItem
    private let handler: () -> Void
    var isHighlightedRow = false { didSet { needsDisplay = true } }

    init(item: OmniCompletionItem, handler: @escaping () -> Void) {
        self.item = item
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        setAccessibilityLabel("\(item.choice.canonicalText) \(item.choice.label)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var allowsVibrancy: Bool { false }
    @objc private func invoke() { handler() }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlightedRow {
            OmniFrostedStyle.selectedFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let token = item.choice.canonicalText as NSString
        let tokenAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: OmniCompletionMenu.tint(for: item.role)]
        let tokenSize = token.size(withAttributes: tokenAttributes)
        let y = (bounds.height - tokenSize.height) / 2
        token.draw(at: NSPoint(x: 10, y: y), withAttributes: tokenAttributes)
        let description = item.choice.label as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        description.draw(
            in: NSRect(x: 10 + tokenSize.width + 10, y: y, width: max(0, bounds.width - tokenSize.width - 30), height: tokenSize.height),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: OmniFrostedStyle.secondaryInk, .paragraphStyle: paragraph]
        )
    }
}

/// Keeps a native pull-down menu and its original hit target, while placing the
/// quiet symbol close to the route text instead of at a font's low baseline.
@MainActor private final class OmniModelChevronCell: NSPopUpButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 2, y: rect.midY - 3, width: 9, height: 6)
    }
}

/// The round ↑ button: it does what Enter does (C22).
@MainActor public final class OmniPadRunButton: NSButton {
    public var onPress: (() -> Void)?
    public var symbolName = "arrow.up" { didSet { needsDisplay = true } }
    public var symbolPointSize: CGFloat = 13 { didSet { needsDisplay = true } }
    public var isSymbolAnimating = false {
        didSet {
            guard oldValue != isSymbolAnimating else { return }
            animatedSymbol?.removeFromSuperview()
            animatedSymbol = nil
            if isSymbolAnimating {
                let symbol = OmniPlaybackSymbolHost(rootView: OmniPlaybackSymbol())
                symbol.frame = bounds
                symbol.autoresizingMask = [.width, .height]
                addSubview(symbol)
                animatedSymbol = symbol
            }
            needsDisplay = true
        }
    }
    private var animatedSymbol: OmniPlaybackSymbolHost?

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        title = ""
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var allowsVibrancy: Bool { false }
    @objc private func invoke() { onPress?() }

    public override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        // The system accent fills the control; token tints stay text colours (C41).
        (isEnabled ? NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.8 : 1) : OmniFrostedStyle.controlFill).setFill()
        circle.fill()
        guard !isSymbolAnimating else { return }
        let tint: NSColor = isEnabled ? .white : OmniFrostedStyle.secondaryInk.withAlphaComponent(0.6)
        if let arrow = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [tint]))) {
            // SF Symbols carry aspect and alignment metadata. Centre that ink
            // instead of stretching every symbol into the same square.
            let alignment = arrow.alignmentRect
            let scale = min((symbolPointSize + 1) / max(1, alignment.width), (symbolPointSize + 1) / max(1, alignment.height))
            arrow.draw(in: NSRect(
                x: bounds.midX - alignment.midX * scale,
                y: bounds.midY - alignment.midY * scale,
                width: arrow.size.width * scale,
                height: arrow.size.height * scale
            ))
        }
    }
}

private struct OmniPlaybackSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: "speaker.wave.2")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

@MainActor private final class OmniPlaybackSymbolHost: NSHostingView<OmniPlaybackSymbol> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Selectable, read-only result text that retains the pad's Enter, ⌘↩ and
/// esc actions even after the user clicks into the result to select a span.
@MainActor public final class OmniPadReadOnlyTextView: NSTextView {
    public var annotations: [OmniTextAnnotation] = [] { didSet { needsDisplay = true } }
    /// Copy and drag carry plain text: the view is rich only for its tints.
    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter(OmniPlainPasteboard.isPlainText)
    }
    public var onSubmit: ((OmniSubmitGesture) -> Void)?
    public var onEscape: (() -> Void)?
    public var onArrow: ((Int) -> Bool)?
    public var onDigit: ((Int) -> Bool)?
    /// ⌥-digit and ⌥↩: pick, but edit first (D6).
    public var onAlternateDigit: ((Int) -> Bool)?
    public var onAlternateSubmit: (() -> Bool)?
    /// A plain letter: ticks a noticed item; never a digit, so never a pick.
    public var onLetter: ((Character) -> Bool)?
    /// ⌥⌘C on a picker row copies its path (Finder's Copy as Pathname).
    public var onCopyPath: (() -> Bool)?

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        OmniAnnotationHighlight.draw(annotations, activeID: nil, in: self, dirtyRect: dirtyRect)
    }

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "c", onCopyPath?() == true { return }
        if performStandardEditingKey(event) { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 53:
            onEscape?()
        case 36, 76:
            if modifiers == [.option], onAlternateSubmit?() == true { return }
            onSubmit?(modifiers.contains(.command) ? .commandEnterAttach : .enterShowHere)
        case 126:
            if onArrow?(-1) != true { super.keyDown(with: event) }
        case 125:
            if onArrow?(1) != true { super.keyDown(with: event) }
        default:
            if let digit = OmniDigitKeys.digit(forKeyCode: event.keyCode) {
                // ⌘-, ⌃- and ⇧-digits stay free (C73); ⌥-digit edits first.
                let handled: Bool? = switch modifiers {
                case []: onDigit?(digit)
                case [.option]: onAlternateDigit?(digit)
                default: false
                }
                if handled != true { super.keyDown(with: event) }
                return
            }
            if modifiers.isEmpty, let letter = event.charactersIgnoringModifiers?.lowercased().first,
               letter.isLetter, onLetter?(letter) == true { return }
            super.keyDown(with: event)
        }
    }
}

/// The number row by key code: the codes for 4–9 are not contiguous, so a
/// `keyCode − 17` offset only ever reached 1–3.
public enum OmniDigitKeys {
    static let table: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    public static func digit(forKeyCode code: UInt16) -> Int? { table[code] }
}

@MainActor final class OmniPadResultFade: NSView {
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSColor.windowBackgroundColor
        NSGradient(starting: base.withAlphaComponent(0), ending: base.withAlphaComponent(0.68))?
            .draw(in: bounds, angle: 270)
    }
}

/// Matches the workspace's four-position running dot. The timer lives only
/// while the working body is mounted and runs through menu tracking/resizing.
@MainActor final class OmniPadWorkingIndicator: NSView {
    private var step = 0
    private var timer: Timer?

    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.step = (self.step + 1) % 4
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        OmniFrostedStyle.secondaryInk.withAlphaComponent(0.86).setFill()
        let travel = CGFloat(step) * 4
        NSBezierPath(ovalIn: NSRect(x: 2 + travel, y: (bounds.height - 5) / 2, width: 5, height: 5)).fill()
    }
}

/// Key hints as keycaps with labels: `↩ Run · ⌘↩ Run and show · esc`.
@MainActor public final class OmniKeyHintsView: NSView {
    public var hints: [OmniPadKeyHint] = [] { didSet { needsDisplay = true } }
    private let keyFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private let labelFont = NSFont.systemFont(ofSize: 11)

    public override var allowsVibrancy: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public var fittingWidth: CGFloat {
        var width: CGFloat = 0
        for (index, hint) in hints.enumerated() {
            width += keycapWidth(hint.key)
            if !hint.label.isEmpty { width += 5 + ceil((hint.label as NSString).size(withAttributes: [.font: labelFont]).width) }
            if index < hints.count - 1 { width += 12 }
        }
        return ceil(width)
    }

    private func keycapWidth(_ key: String) -> CGFloat {
        ceil((key as NSString).size(withAttributes: [.font: keyFont]).width) + 10
    }

    private func hintWidth(_ hint: OmniPadKeyHint) -> CGFloat {
        keycapWidth(hint.key) + (hint.label.isEmpty ? 0 : 5 + ceil((hint.label as NSString).size(withAttributes: [.font: labelFont]).width))
    }

    private func rows(forWidth width: CGFloat) -> [[OmniPadKeyHint]] {
        var rows: [[OmniPadKeyHint]] = []
        var row: [OmniPadKeyHint] = []
        var used: CGFloat = 0
        for hint in hints {
            let next = hintWidth(hint) + (row.isEmpty ? 0 : 12)
            if !row.isEmpty && used + next > max(1, width) {
                rows.append(row)
                row = []
                used = 0
            }
            used += hintWidth(hint) + (row.isEmpty ? 0 : 12)
            row.append(hint)
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let count = max(1, rows(forWidth: width).count)
        return CGFloat(count * 20 + (count - 1) * 4)
    }

    private func drawKey(_ key: String, in cap: NSRect, color: NSColor = OmniFrostedStyle.ink) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): keyFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.textPosition = .zero
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: key, attributes: attributes) as CFAttributedString)
        let ink = CTLineGetImageBounds(line, context)
        context.textPosition = NSPoint(x: cap.midX - ink.midX, y: cap.midY - ink.midY)
        CTLineDraw(line, context)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let capHeight: CGFloat = 18
        let rows = rows(forWidth: bounds.width)
        let height = fittingHeight(forWidth: bounds.width)
        for (rowIndex, row) in rows.enumerated() {
            let rowWidth = row.reduce(CGFloat(0)) { $0 + hintWidth($1) } + CGFloat(max(0, row.count - 1)) * 12
            var x = max(0, bounds.width - rowWidth)
            let centerY = (bounds.height - height) / 2 + height - 10 - CGFloat(rowIndex) * 24
            for hint in row {
                let width = keycapWidth(hint.key)
                let cap = NSRect(x: x, y: centerY - capHeight / 2, width: width, height: capHeight)
                let path = NSBezierPath(roundedRect: cap, xRadius: 4, yRadius: 4)
                (hint.emphasized ? OmniFrostedStyle.modeTokenFill : OmniFrostedStyle.controlFill).setFill()
                path.fill()
                (hint.emphasized ? OmniFrostedStyle.mode.withAlphaComponent(0.35) : OmniFrostedStyle.controlLine).setStroke()
                path.lineWidth = 1
                path.stroke()
                drawKey(hint.key, in: cap, color: hint.emphasized ? OmniFrostedStyle.mode : OmniFrostedStyle.ink)
                x += width
                if !hint.label.isEmpty {
                    let labelSize = (hint.label as NSString).size(withAttributes: [.font: labelFont])
                    (hint.label as NSString).draw(at: NSPoint(x: x + 5, y: centerY - labelSize.height / 2), withAttributes: [.font: labelFont, .foregroundColor: hint.emphasized ? OmniFrostedStyle.ink : OmniFrostedStyle.secondaryInk])
                    x += 5 + ceil(labelSize.width)
                }
                x += 12
            }
        }
    }
}

/// `From <icon> Mail “Mira Chen” ×`: where the imported text came from
/// (C19), drawn by the provenance formatter the workspace header uses (D3).
@MainActor public final class OmniProvenanceChip: NSButton {
    public var provenance: OmniPadProvenance? { didSet { updateLabel() } }
    public var usesCompactLabel = false { didSet { updateLabel() } }
    public var onClear: (() -> Void)?
    private let chipFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let leading: CGFloat = 10
    private static let trailing: CGFloat = 28
    private static let iconSize: CGFloat = 14

    public init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var allowsVibrancy: Bool { false }
    @objc private func invoke() { onClear?() }

    private func updateLabel() {
        needsDisplay = true
        let label = provenance.map { value in
            usesCompactLabel || value.symbolName != nil ? [value.source, value.detail].compactMap { $0 }.joined(separator: " · ") : value.label
        }
        setAccessibilityLabel(label.map { "\($0). Remove imported text" } ?? "")
    }

    /// The chip's text: the formatter's attributed line in the chip's ink.
    public var attributedLabel: NSAttributedString? {
        guard let provenance else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: chipFont, .foregroundColor: OmniFrostedStyle.ink, .paragraphStyle: paragraph]
        if let symbolName = provenance.symbolName {
            let result = NSMutableAttributedString()
            if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [OmniFrostedStyle.ink]))) {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                attachment.bounds = NSRect(x: 0, y: (chipFont.capHeight - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
                let icon = NSMutableAttributedString(attachment: attachment)
                icon.addAttribute(.kern, value: Self.iconSize * 0.3, range: NSRange(location: 0, length: icon.length))
                result.append(icon)
            }
            result.append(NSAttributedString(string: provenance.label, attributes: attributes))
            return result
        }
        guard let line = provenance.line else { return NSAttributedString(string: provenance.source, attributes: attributes) }
        return line.attributed(attributes: attributes, iconSize: Self.iconSize, compact: usesCompactLabel)
    }

    public var fittingWidth: CGFloat {
        guard let label = attributedLabel else { return 0 }
        return Self.leading + ceil(label.size().width) + Self.trailing
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let label = attributedLabel else { return }
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isHighlighted ? OmniFrostedStyle.hoverFill : OmniFrostedStyle.controlFill).setFill()
        pill.fill()
        OmniFrostedStyle.controlLine.setStroke()
        pill.lineWidth = 1
        pill.stroke()
        let size = label.size()
        label.draw(with: NSRect(x: Self.leading, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - Self.leading - Self.trailing), height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let close = "×" as NSString
        let closeSize = close.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
        close.draw(at: NSPoint(x: bounds.maxX - 10 - closeSize.width, y: (bounds.height - closeSize.height) / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk])
    }
}

/// A small inline action in the route line (`Open settings`, C30).
@MainActor public final class OmniPadInlineButton: NSButton {
    public var onPress: (() -> Void)?
    private let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    public init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        setButtonType(.momentaryChange)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var allowsVibrancy: Bool { false }
    @objc private func invoke() { onPress?() }

    public var fittingWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: labelFont]).width) + 18 }

    public override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (isHighlighted ? OmniFrostedStyle.hoverFill : OmniFrostedStyle.controlFill).setFill()
        path.fill()
        let size = (title as NSString).size(withAttributes: [.font: labelFont])
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: [.font: labelFont, .foregroundColor: OmniFrostedStyle.ink])
    }
}

/// One alternative in the chooser: `1  /qq summarise the thread`.
@MainActor final class OmniProposalRow: NSButton {
    let alternative: OmniPadAlternative
    private let number: Int
    private let parser: OmniParser
    private let handler: () -> Void
    var isChosen = false { didSet { needsDisplay = true } }

    init(number: Int, alternative: OmniPadAlternative, parser: OmniParser, handler: @escaping () -> Void) {
        self.number = number
        self.alternative = alternative
        self.parser = parser
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        setAccessibilityLabel("\(number). \(alternative.title): \(alternative.steps.joined(separator: ", then "))")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var allowsVibrancy: Bool { false }
    @objc private func invoke() { handler() }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen {
            OmniFrostedStyle.selectedFill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        let numberText = "\(number)" as NSString
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: OmniFrostedStyle.secondaryInk]
        let numberSize = numberText.size(withAttributes: numberAttributes)
        numberText.draw(at: NSPoint(x: 8, y: (bounds.height - numberSize.height) / 2), withAttributes: numberAttributes)
        let text = alternative.steps.count == 1 ? alternative.steps[0] : alternative.title
        let attributed = NSMutableAttributedString(attributedString: OmniTokenRenderer.attributedText(text, parser: parser, fontSize: 13))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
        let size = attributed.size()
        attributed.draw(in: NSRect(x: 24, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 32), height: size.height))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
