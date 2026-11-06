import AppKit
import OmniCore

// MARK: - Renderer-neutral launcher state (H10, C50)

/// One item in the launcher body: a candidate row, or the synthetic
/// *Ask for a proposal instead* row that leads after ⌘Z of a launch.
public enum OmniLauncherItem: Equatable, Sendable {
    case askForProposal
    case row(LauncherScoredRow)

    var candidateID: String? {
        if case .row(let row) = self { return row.id }
        return nil
    }
}

/// What the pad shows while `suggesting`, and what Enter will do. Pure.
public struct OmniLauncherPadState: Equatable, Sendable {
    public var results: LauncherResults
    /// A display index chosen with ↑/↓ or a click; nil when untouched.
    public var manualSelection: Int?
    /// Set after ⌘Z of a launch, or after a launch that failed: that row is
    /// marked and *Ask for a proposal instead* comes first.
    public var undoneCandidateID: String?
    /// The mark is a failed open, not an undo.
    public var markedAfterFailure: Bool

    public init(results: LauncherResults, manualSelection: Int? = nil, undoneCandidateID: String? = nil, markedAfterFailure: Bool = false) {
        self.results = results
        self.manualSelection = manualSelection
        self.undoneCandidateID = undoneCandidateID
        self.markedAfterFailure = markedAfterFailure
    }

    public var items: [OmniLauncherItem] {
        // An id never asks for a proposal (D1), not even after ⌘Z or a
        // failed open: the address is the whole request.
        let ask = undoneCandidateID != nil && results.lane == .curated && results.idLookup == nil
        return (ask ? [.askForProposal] : []) + results.rows.map(OmniLauncherItem.row)
    }

    /// The item Enter acts on: a manual selection; else the ask row after an
    /// undo; else the top row when it is ready; else nothing (propose).
    public var highlighted: Int? {
        let items = items
        if let manualSelection, items.indices.contains(manualSelection) { return manualSelection }
        if results.idLookup != nil || results.lane == .everywhere { return results.rows.isEmpty ? nil : 0 }
        if undoneCandidateID != nil { return 0 }
        if results.ready, !results.rows.isEmpty { return 0 }
        return nil
    }

    /// The ↵ badge marks the row Enter opens without looking: the ready top
    /// row, and only while it is the Enter target (not after ⌘Z, not while
    /// another row is picked).
    public var readyBadgeIndex: Int? {
        (results.lane == .curated || results.idLookup != nil) && undoneCandidateID == nil && results.ready && !results.rows.isEmpty && highlighted == 0 ? 0 : nil
    }

    public enum Enter: Equatable, Sendable {
        /// Open (or, with Cmd, reveal) this row. `rank` is 1-based among the rows.
        case launch(LauncherScoredRow, rank: Int, selection: LaunchLogEntry.Selection)
        /// The Tier 2 proposal request the application makes for bare text.
        case propose(afterUndo: Bool)
        case nothing
    }

    public var enter: Enter {
        let items = items
        guard let highlighted, items.indices.contains(highlighted) else {
            // An id miss is dead, like an empty everywhere lane (D1, C71).
            return results.lane == .everywhere || results.idLookup != nil ? .nothing : .propose(afterUndo: false)
        }
        switch items[highlighted] {
        case .askForProposal:
            return .propose(afterUndo: !markedAfterFailure)
        case .row(let row):
            let rank = (results.rows.firstIndex { $0.id == row.id } ?? 0) + 1
            // The selection is the judgment: a manual pick launches regardless of ready.
            let manual = manualSelection != nil || (results.lane == .everywhere && results.idLookup == nil)
            return .launch(row, rank: rank, selection: manual ? .manual : .ready)
        }
    }

    /// ↓ moves to the next item (from nothing to the first unhighlighted
    /// one); ↑ moves back, and above the first item clears the selection.
    @discardableResult
    public mutating func move(by delta: Int) -> Bool {
        let count = items.count
        guard count > 0 else { return false }
        let current = highlighted
        if delta > 0 {
            manualSelection = min(count - 1, (current ?? -1) + 1)
        } else if let current, current > 0 {
            manualSelection = current - 1
        } else {
            manualSelection = nil
        }
        return true
    }
}

public extension OmniCommandPadViewController {
    static let nothingMatchesLine = "Nothing matches"
    static let pickOrProposeLine = "Pick a match or propose"
    static let proposeInsteadLine = "Ask for a proposal"
    static let annotatedProposalLine = "Ask for a proposal"
    static let askForProposalTitle = "Ask for a proposal instead"
    static let backToProposalLine = "⇥ back to ask for a proposal"
    static let everywhereQueryHint = "Type at least 3 characters to search everywhere"
    /// The exact-id lane's miss (D1). Enter does nothing.
    static let idMissLine = "No document with this id"
    static let runIDMissLine = "No run folder with this id"
    /// An id miss while the index loads or gains its ids (first start after
    /// an upgrade): not yet a miss.
    static let idPendingLine = "Ids are still loading · try again in a moment"
    /// Before the first rows for an id arrive.
    static let idLookingUpLine = "Looking up the id"
    /// An id with a note: a request, which an id never becomes (D1).
    static let annotatedIDLine = "An id opens from the launcher · remove the note to open it"
    /// An id submitted where no launcher answers it.
    static let idOpensFromLauncherLine = "An id opens from the launcher, never as a request"
    /// Longer bare text is still launcher-first (it falls through to a
    /// proposal) but is not scored: it is a sentence, not a name.
    static let launcherQueryLimit = 120

    static func everywhereOffer(_ results: LauncherResults?) -> String? {
        guard let results, results.lane == .curated, !results.ready,
              LauncherQuery(results.query).characterCount >= 3 else { return nil }
        guard let count = results.everywhereMatchCount else { return "⇥ search everywhere" }
        return "⇥ search everywhere · \(count >= 100 ? "99+" : String(count)) matches"
    }

    /// Bare text is launcher-first (C50): no slash token, no @reference, no
    /// marker, a single line, and not an imported selection (text to act
    /// on). Pasted multi-line text keeps the paste-first route line
    /// (*Add a command to this text*). Everything else keeps today's routing.
    static func isLauncherQuery(_ intent: ParsedIntent, rawText: String, hasProvenance: Bool, hasAnnotations: Bool) -> Bool {
        if BasicCalculator.classify(rawText) != .ordinary, !hasProvenance, !hasAnnotations { return false }
        // An id is an address whatever surrounds it (D1): a pasted line's
        // newline or an imported selection never makes it material, so it
        // never reaches the offer row or a model. A note still makes it a
        // request (which the service refuses for an id).
        if !hasAnnotations, OmniIDAddress(rawText) != nil { return true }
        guard !hasProvenance, !hasAnnotations, !intent.isEmpty, !rawText.contains(where: \.isNewline) else { return false }
        guard intent.primaryTokens.isEmpty, intent.settingsTokens.isEmpty, intent.modifiers.isEmpty, intent.modes.isEmpty,
              intent.references.isEmpty, intent.markers.isEmpty, intent.diagnostics.isEmpty
        else { return false }
        return !rawText.split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix("/") || $0.hasPrefix("@") }
    }

    /// Notes turn plain text into a request, including imported selections
    /// and multiple lines. Explicit command and reference syntax still uses
    /// its normal route.
    func isAnnotatedBareText(_ intent: ParsedIntent) -> Bool {
        guard !annotations.isEmpty, !intent.isEmpty else { return false }
        // Material back from a pick (D6) carries its position note: paths and
        // `@MainActor` in it are material, as for the offer row, so Enter
        // still asks for a proposal instead of going dead.
        if annotations.contains(where: \.isRequestScoped) { return isMaterialText(intent) }
        guard intent.primaryTokens.isEmpty, intent.settingsTokens.isEmpty, intent.modifiers.isEmpty, intent.modes.isEmpty,
              intent.references.isEmpty, intent.markers.isEmpty, intent.diagnostics.isEmpty
        else { return false }
        return !editor.string.split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix("/") || $0.hasPrefix("@") }
    }

    /// The footer while `suggesting` (handoff §2 lines). `unavailable` names
    /// an index that cannot answer yet, so no rows never reads as "Nothing matches".
    static func launcherFooterState(_ state: OmniLauncherPadState, transientMessage: String?, unavailable: String? = nil, idsPending: Bool = false) -> OmniPadFooterState {
        var line: OmniPadRouteLine
        var hints: [OmniPadKeyHint]
        if let lookup = state.results.idLookup {
            // The exact-id lane (D1): open the row, or a plain miss. No
            // everywhere offer and no proposal: an id is looked up in both
            // lanes already, and it never leaves the machine.
            if case .launch(let row, _, _) = state.enter {
                let lane = lookup.lane(for: row.id) ?? state.results.lane
                let verb = LauncherOpenAction.open.effective(for: row.candidate, lane: lane) == .reveal ? "Reveal" : "Open"
                line = .outcome("\(verb) \(row.candidate.title) · \(LauncherRowText.kindLabel(row.candidate))")
                hints = OmniPadKeyHint.idLane
            } else {
                let address = OmniIDAddress(state.results.query)
                line = .hint(idsPending ? idPendingLine : address?.namespace == .run ? runIDMissLine : idMissLine)
                hints = OmniPadKeyHint.dismissOnly
            }
            if let transientMessage { line = .notice(transientMessage) }
            let enabled = state.enter != .nothing
            return OmniPadFooterState(routeLine: line, keyHints: hints, runEnabled: enabled, submits: enabled)
        }
        switch state.enter {
        case .launch(let row, _, _):
            let action = LauncherOpenAction.open.effective(for: row.candidate, lane: state.results.lane)
            let verb = action == .reveal ? "Reveal" : "Open"
            let offer = everywhereOffer(state.results).map { " · " + $0 } ?? ""
            line = .outcome("\(verb) \(row.candidate.title) · \(LauncherRowText.kindLabel(row.candidate))\(offer)")
            hints = OmniPadKeyHint.launch
        case .propose(let afterUndo):
            if afterUndo {
                line = .propose(proposeInsteadLine)
                hints = OmniPadKeyHint.launcherPropose
            } else if state.results.rows.isEmpty {
                line = .propose(unavailable ?? nothingMatchesLine)
                hints = OmniPadKeyHint.propose
            } else {
                line = .propose(pickOrProposeLine)
                hints = OmniPadKeyHint.launcherPropose
            }
            if let offer = everywhereOffer(state.results) {
                line = .propose(unavailable.map { $0 + " · " + offer } ?? offer)
            }
        case .nothing:
            let short = LauncherQuery(state.results.query).characterCount < 3
            line = .hint(short ? everywhereQueryHint : (unavailable.map { $0 + " · " } ?? "") + backToProposalLine)
            hints = [.init("⇥", "Back"), .init("esc", "")]
        }
        if let transientMessage { line = .notice(transientMessage) }
        // Enter always does something here: open a row or ask for a proposal.
        let enabled = state.enter != .nothing
        return OmniPadFooterState(routeLine: line, keyHints: hints, runEnabled: enabled, submits: enabled)
    }
}

// MARK: - Pad behaviour

extension OmniCommandPadViewController {
    /// Completion has already had first refusal. Empty widening shows a hint;
    /// command syntax, imported text and annotations keep their own routes.
    @discardableResult
    func toggleLauncherLane() -> Bool {
        // A captured id is an address (D1): Tab never types a tab into it.
        // Its chip holds the header, so the lane stays; the lookup covers
        // both lanes anyway.
        if launcherEnabled, provenance != nil, annotations.isEmpty, OmniIDAddress(editor.string) != nil { return true }
        guard launcherEnabled, editor.isEditable, !editor.hasMarkedText(), annotations.isEmpty, provenance == nil else { return false }
        let text = editor.string
        let bare = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || Self.isLauncherQuery(parser.parse(text), rawText: text, hasProvenance: false, hasAnnotations: false)
        guard bare, mode == .composing || mode == .suggesting else { return false }
        setLauncherLane(launcherLane == .curated ? .everywhere : .curated)
        return true
    }

    /// Also used to restore the lane captured by a launch undo after closing.
    public func setLauncherLane(_ lane: LauncherLane) {
        guard launcherLane != lane else { return }
        launcherLane = lane
        launcherScopeChip.isHidden = lane != .everywhere
        clearLauncher()
        refreshLauncherMode(textChanged: true)
        renderFooter()
    }

    /// Enters or leaves `suggesting` from the current text; a keystroke asks
    /// the host for fresh rows and drops any manual selection or undo mark.
    func refreshLauncherMode(textChanged: Bool) {
        switch mode {
        case .working, .result: return
        case .composing, .suggesting: break
        }
        let text = editor.string
        let emptyWiden = launcherLane == .everywhere && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && provenance == nil && annotations.isEmpty
        let eligible = launcherEnabled && (emptyWiden || Self.isLauncherQuery(parser.parse(text), rawText: text, hasProvenance: provenance != nil, hasAnnotations: !annotations.isEmpty))
        guard eligible else {
            launcherLane = .curated
            launcherScopeChip.isHidden = true
            launcherQueryStartedAt = nil
            if case .suggesting = mode {
                mode = .composing
                clearLauncher()
                if !textChanged { renderFooter() }
            }
            return
        }
        if mode != .suggesting { mode = .suggesting }
        // The first keystroke of a query starts its clock (also after a
        // decision reset it, e.g. typing on after a failed open).
        if textChanged, launcherQueryStartedAt == nil { launcherQueryStartedAt = Date() }
        if textChanged, var state = launcherState {
            let hadMark = state.undoneCandidateID != nil
            state.manualSelection = nil
            state.undoneCandidateID = nil
            state.markedAfterFailure = false
            launcherState = state
            // The ask row goes away with the mark: repaint the items, not just the highlight.
            if hadMark { rebuildLauncherRows() } else { highlightLauncherRows() }
        }
        if textChanged || launcherState == nil { requestLauncherResults(for: text) }
        if !textChanged { renderFooter() }
    }

    /// Asks the host for rows, or answers "no rows" for a sentence too long
    /// to be a name (it still falls through to a proposal).
    func requestLauncherResults(for text: String) {
        guard annotations.isEmpty else { return }
        if text.count > Self.launcherQueryLimit {
            showLauncherResults(.empty(LauncherQuery(text).text, lane: launcherLane))
        } else {
            onLauncherQuery?(text)
        }
    }

    /// Re-queries the current text (the index may have been rebuilt since
    /// the rows were shown, e.g. when the pad reopens).
    public func refreshLauncherResults() {
        guard case .suggesting = mode, annotations.isEmpty else { return }
        // A reopened pad with a bare-text draft starts a new session clock.
        if launcherQueryStartedAt == nil { launcherQueryStartedAt = Date() }
        requestLauncherResults(for: editor.string)
    }

    /// The pad closed or a decision was taken: the next query starts a new
    /// first-keystroke clock.
    public func endLauncherSession() {
        launcherQueryStartedAt = nil
        if launcherLane != .curated {
            launcherLane = .curated
            launcherScopeChip.isHidden = true
            clearLauncher()
            if mode == .suggesting { mode = .composing }
            renderFooter()
        }
    }

    /// Applies one keystroke's rows. Rows for older text are dropped, so a
    /// late batch never replaces what the field now says.
    public func showLauncherResults(_ results: LauncherResults) {
        guard launcherEnabled, case .suggesting = mode, annotations.isEmpty,
              results.lane == launcherLane, results.query == LauncherQuery(editor.string).text else { return }
        var state = launcherState ?? OmniLauncherPadState(results: results)
        let selectedID = state.manualSelection.flatMap { index in state.items.indices.contains(index) ? state.items[index].candidateID : nil }
        state.results = results
        state.manualSelection = selectedID.flatMap { id in state.items.firstIndex { $0.candidateID == id } }
        launcherState = state
        rebuildLauncherRows()
        renderFooter()
    }

    /// After ⌘Z of a launch the host restores the query; this marks the
    /// launched row and puts *Ask for a proposal instead* first. Returns
    /// whether the mark was applied (the pad must be suggesting).
    @discardableResult
    public func markLaunchUndo(candidateID: String) -> Bool {
        markLaunch(candidateID: candidateID, failed: false)
    }

    /// A launch that could not open: fresh rows, the row marked, and Enter
    /// on *Ask for a proposal instead* first, so Enter is never dead.
    @discardableResult
    public func markLaunchFailed(candidateID: String) -> Bool {
        markLaunch(candidateID: candidateID, failed: true)
    }

    private func markLaunch(candidateID: String, failed: Bool) -> Bool {
        guard case .suggesting = mode, annotations.isEmpty else { return false }
        let text = editor.string
        let query = LauncherQuery(text).text
        let fresh = failed || launcherState?.results.query != query || launcherState?.results.rows.isEmpty != false
        var state = launcherState ?? OmniLauncherPadState(results: .empty(query, lane: launcherLane))
        if fresh { state.results = onResolveLauncher?(text) ?? .empty(query, lane: launcherLane) }
        state.undoneCandidateID = candidateID
        state.markedAfterFailure = failed
        state.manualSelection = nil
        launcherState = state
        rebuildLauncherRows()
        renderFooter()
        return true
    }

    @discardableResult
    func moveLauncherSelection(by delta: Int) -> Bool {
        guard var state = launcherState, state.move(by: delta) else { return false }
        launcherState = state
        highlightLauncherRows()
        renderFooter()
        return true
    }

    /// Enter while suggesting. Decides on the current text: when the shown
    /// rows answer older text, the host resolves synchronously first.
    func submitLauncher(_ gesture: OmniSubmitGesture) {
        if submitLocalInput() { return }
        let text = editor.string
        let query = LauncherQuery(text).text
        if !annotations.isEmpty {
            guard onResolveRoute?(parser.parse(text), selectedModelProfileID)?.unavailable == nil else {
                renderFooter()
                return
            }
            closeAnnotationPanels()
            onSubmit?(parser.parse(text).canonicalText, gesture)
            return
        }
        if launcherState?.results.query != query || launcherState?.results.lane != launcherLane {
            let fresh = text.count > Self.launcherQueryLimit ? .empty(query, lane: launcherLane) : (onResolveLauncher?(text) ?? .empty(query, lane: launcherLane))
            // A pick made on the not-yet-refreshed rows follows its candidate.
            let picked = launcherState.flatMap { state in state.manualSelection.flatMap { state.items.indices.contains($0) ? state.items[$0].candidateID : nil } }
            var state = OmniLauncherPadState(results: fresh)
            state.manualSelection = picked.flatMap { id in state.items.firstIndex { $0.candidateID == id } }
            launcherState = state
            rebuildLauncherRows()
        }
        let state = launcherState ?? OmniLauncherPadState(results: .empty(query, lane: launcherLane))
        let rows = state.results.rows
        let elapsed = launcherQueryStartedAt.map { Int((Date().timeIntervalSince($0) * 1_000).rounded()) }
        launcherQueryStartedAt = nil
        switch state.enter {
        case .launch(let row, let rank, let selection):
            // An id hit opens through the lane that holds it (D1).
            let lane = state.results.idLookup?.lane(for: row.id) ?? launcherLane
            let context = LaunchContext(query: query, rank: rank, top1ID: rows.first?.id, ready: state.results.ready, selection: selection, candidateCount: rows.count, elapsedMilliseconds: elapsed, lane: lane)
            let action = (gesture == .commandEnterAttach ? LauncherOpenAction.reveal : .open).effective(for: row.candidate, lane: lane)
            onLaunch?(row.id, action, context)
        case .propose(let afterUndo):
            guard launcherLane == .curated else { return }
            // An id is an address, never a proposal (D1); the service holds
            // the same line for every other surface.
            guard OmniIDAddress(text) == nil else { return }
            guard onResolveRoute?(parser.parse(text), selectedModelProfileID)?.unavailable == nil else {
                renderFooter()
                return
            }
            let context = LaunchContext(query: query, rank: nil, top1ID: rows.first?.id, ready: state.results.ready, selection: nil, candidateCount: rows.count, elapsedMilliseconds: elapsed, afterUndo: afterUndo)
            onLauncherFallthrough?(context)
            // The Tier 2 request the application makes for bare text: the host
            // submits the visible text through its ordinary submit path.
            onSubmit?(parser.parse(text).canonicalText, gesture)
        case .nothing:
            return
        }
    }

    /// ⌥⌘C, Finder's Copy as Pathname, on the exact-id lane (D1): copies the
    /// highlighted row's path. Returns false (the key goes on) elsewhere.
    func copyHighlightedLauncherPath() -> Bool {
        guard case .suggesting = mode, let state = launcherState, state.results.idLookup != nil,
              let highlighted = state.highlighted, state.items.indices.contains(highlighted),
              case .row(let row) = state.items[highlighted]
        else { return false }
        onCopyPath?(row.candidate.path)
        showTransientNotice("Copied the path of \(row.candidate.title)")
        return true
    }

    /// A click on a row: the selection is the judgment.
    func chooseLauncherItem(at index: Int, gesture: OmniSubmitGesture) {
        guard annotations.isEmpty, var state = launcherState, state.items.indices.contains(index) else { return }
        state.manualSelection = index
        launcherState = state
        highlightLauncherRows()
        renderFooter()
        submitLauncher(gesture)
    }

    func clearLauncher() {
        guard launcherState != nil || launcherView != nil else { return }
        launcherState = nil
        launcherView?.removeFromSuperview()
        launcherView = nil
        launcherRowViews = []
        bodyHeight = 0
        layoutPad(width: view.bounds.width)
    }

    func rebuildLauncherRows() {
        launcherView?.removeFromSuperview()
        launcherView = nil
        launcherRowViews = []
        guard case .suggesting = mode, annotations.isEmpty, let state = launcherState, !state.items.isEmpty else {
            if bodyHeight != 0 {
                bodyHeight = 0
                layoutPad(width: view.bounds.width)
            }
            return
        }
        let rowHeight = OmniLauncherRowView.rowHeight
        let items = state.items
        let height = rowHeight * CGFloat(items.count) + 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: height))
        container.setAccessibilityIdentifier("omni.pad.launcher")
        container.autoresizingMask = [.width]
        let highlighted = state.highlighted
        let now = Date()
        for (index, item) in items.enumerated() {
            let row = OmniLauncherRowView(
                item: item,
                home: launcherHome,
                now: now,
                showsReady: index == state.readyBadgeIndex,
                marked: item.candidateID != nil && item.candidateID == state.undoneCandidateID,
                markNote: state.markedAfterFailure ? "couldn't open" : "just opened"
            ) { [weak self] gesture in
                self?.chooseLauncherItem(at: index, gesture: gesture)
            }
            row.frame = NSRect(x: 12, y: height - 4 - rowHeight * CGFloat(index + 1), width: view.bounds.width - 24, height: rowHeight)
            row.autoresizingMask = [.width]
            row.setAccessibilityIdentifier("omni.pad.launcher.\(index)")
            row.isHighlightedRow = index == highlighted
            container.addSubview(row)
            launcherRowViews.append(row)
        }
        view.addSubview(container)
        launcherView = container
        bodyHeight = height
        layoutPad(width: view.bounds.width)
    }

    func highlightLauncherRows() {
        let highlighted = launcherState?.highlighted
        let badge = launcherState?.readyBadgeIndex
        for (index, row) in launcherRowViews.enumerated() {
            row.isHighlightedRow = index == highlighted
            row.showsReady = index == badge
        }
    }
}

// MARK: - Row view

/// One candidate row (handoff §6): kind glyph · title · subtitle (kind ·
/// folder · age) · confidence bar · the green ↵ badge on the ready top row.
@MainActor public final class OmniLauncherRowView: NSButton {
    public static let rowHeight: CGFloat = 30
    public let item: OmniLauncherItem
    private let subtitle: String
    var showsReady: Bool { didSet { if oldValue != showsReady { needsDisplay = true } } }
    private let marked: Bool
    private let markNote: String
    private let handler: (OmniSubmitGesture) -> Void
    var isHighlightedRow = false { didSet { if oldValue != isHighlightedRow { needsDisplay = true } } }

    init(item: OmniLauncherItem, home: String, now: Date, showsReady: Bool, marked: Bool, markNote: String = "just opened", handler: @escaping (OmniSubmitGesture) -> Void) {
        self.item = item
        self.showsReady = showsReady
        self.marked = marked
        self.markNote = markNote
        self.handler = handler
        switch item {
        case .askForProposal:
            subtitle = "Tier 2 · nothing runs until you choose"
        case .row(let row):
            subtitle = LauncherRowText.subtitle(row.candidate, home: home, now: now)
        }
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        switch item {
        case .askForProposal:
            setAccessibilityLabel(OmniCommandPadViewController.askForProposalTitle)
        case .row(let row):
            setAccessibilityLabel("\(row.candidate.title), \(subtitle)\(showsReady ? ", ready" : "")\(marked ? ", \(markNote)" : "")")
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var allowsVibrancy: Bool { false }

    /// App rows show the real app icon (recognition beats a generic glyph);
    /// cached per path so a keystroke never repeats the lookup.
    private static var iconCache: [String: NSImage] = [:]
    static func applicationIcon(atPath path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    @objc private func invoke() {
        let command = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        handler(command ? .commandEnterAttach : .enterShowHere)
    }

    private var symbolName: String {
        guard case .row(let row) = item else { return "text.bubble" }
        switch row.candidate.source {
        case .apps: return "app"
        case .roots: return "folder"
        case .docsIndex: return "doc.text"
        case .files:
            switch row.candidate.kind {
            case "pdf": return "doc.richtext"
            case "key", "pptx", "ppt": return "play.rectangle"
            case "numbers", "xlsx", "xls": return "tablecells"
            case "sketch": return "pencil.and.ruler"
            case let kind where EverywhereScope.mediaExtensions.contains(kind): return "photo"
            case let kind where EverywhereScope.revealExtensions.contains(kind): return "shippingbox"
            default: return "doc"
            }
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        if isHighlightedRow {
            OmniFrostedStyle.selectedFill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        if case .row(let row) = item, row.candidate.source == .apps {
            Self.applicationIcon(atPath: row.candidate.path).draw(in: NSRect(x: 6, y: (bounds.height - 20) / 2, width: 20, height: 20))
        } else if let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [OmniFrostedStyle.secondaryInk]))) {
            icon.draw(in: NSRect(x: 8, y: (bounds.height - 15) / 2, width: 16, height: 15))
        }
        // Right side: ↵ badge, confidence bar, or the undo mark.
        var right = bounds.width - 8
        if showsReady {
            let badge = NSRect(x: right - 22, y: (bounds.height - 16) / 2, width: 22, height: 16)
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            let glyph = "↵" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
            right = badge.minX - 8
        }
        if case .row(let row) = item {
            if marked {
                let note = markNote as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: OmniFrostedStyle.secondaryInk]
                let size = note.size(withAttributes: attributes)
                note.draw(at: NSPoint(x: right - size.width, y: (bounds.height - size.height) / 2), withAttributes: attributes)
                right -= size.width + 8
            } else if row.fuzzy > 0 {
                let track = NSRect(x: right - 32, y: bounds.midY - 1.5, width: 32, height: 3)
                OmniFrostedStyle.secondaryInk.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                var fill = track
                fill.size.width = max(2, track.width * CGFloat(min(1, max(0, row.fuzzy))))
                OmniFrostedStyle.secondaryInk.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
                right = track.minX - 10
            }
        }
        let titleText: String = switch item {
        case .askForProposal: OmniCommandPadViewController.askForProposalTitle
        case .row(let row): row.candidate.title
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: OmniFrostedStyle.ink, .paragraphStyle: paragraph]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: OmniFrostedStyle.secondaryInk, .paragraphStyle: paragraph]
        let left: CGFloat = 32
        let available = max(0, right - left)
        let titleSize = (titleText as NSString).size(withAttributes: titleAttributes)
        let titleWidth = min(ceil(titleSize.width), available * 0.62)
        (titleText as NSString).draw(in: NSRect(x: left, y: (bounds.height - titleSize.height) / 2, width: titleWidth, height: titleSize.height), withAttributes: titleAttributes)
        let subtitleX = left + titleWidth + 8
        let subtitleSize = (subtitle as NSString).size(withAttributes: subtitleAttributes)
        if right - subtitleX > 24 {
            (subtitle as NSString).draw(in: NSRect(x: subtitleX, y: (bounds.height - subtitleSize.height) / 2, width: right - subtitleX, height: subtitleSize.height), withAttributes: subtitleAttributes)
        }
    }
}

/// The scope marker occupies the same header strip as imported provenance.
/// It is a label; Tab is the single toggle interaction.
@MainActor public final class OmniLauncherScopeChip: NSView {
    private let chipFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    public var fittingWidth: CGFloat { ceil(("Everywhere" as NSString).size(withAttributes: [.font: chipFont]).width) + 24 }
    public override var allowsVibrancy: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        OmniFrostedStyle.controlFill.setFill()
        pill.fill()
        OmniFrostedStyle.controlLine.setStroke()
        pill.lineWidth = OmniFrostedStyle.hairlineWidth
        pill.stroke()
        let text = "Everywhere" as NSString
        let size = text.size(withAttributes: [.font: chipFont])
        text.draw(at: NSPoint(x: 12, y: (bounds.height - size.height) / 2), withAttributes: [.font: chipFont, .foregroundColor: OmniFrostedStyle.ink])
    }
    public override func accessibilityLabel() -> String? { "Everywhere search" }
}
