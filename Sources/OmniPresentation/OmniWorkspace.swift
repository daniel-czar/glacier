import AppKit
import OmniCore

/// How a run row marks itself (C34): done rows are unmarked, running rows
/// carry the stepping dot, failed rows a red dot.
public enum OmniWorkspaceRowActivity: Sendable, Equatable {
    case done
    case running
    case failed
}

/// A renderer-neutral summary of a durable run: `token · derived title · time`
/// on one line and the result excerpt below (C34). The same rows feed the
/// workspace sidebar and the menu's Recent section (C60).
public struct OmniWorkspaceRunRow: Sendable, Equatable, Identifiable {
    public let id: String
    /// The command token (`/email`); empty for runs without one.
    public let token: String
    /// `Reply · <subject>` with Mail provenance, else the first words of the request.
    public let title: String
    /// Textual state, kept for accessibility and tooltips.
    public let status: String
    /// Result excerpt.
    public let summary: String
    public let submittedAt: Date?
    public let activity: OmniWorkspaceRowActivity

    public init(
        id: String,
        title: String,
        status: String,
        summary: String,
        token: String = "",
        submittedAt: Date? = nil,
        activity: OmniWorkspaceRowActivity = .done
    ) {
        self.id = id
        self.token = token
        self.title = title
        self.status = status
        self.summary = summary
        self.submittedAt = submittedAt
        self.activity = activity
    }
}

/// The detail pane's subtitle ingredients (C35, D3, C81):
/// `/email · From <icon> Mail “Re: invoice” · Cerebras`, with `Today, 14:42`
/// right-aligned on the same row.
public struct OmniWorkspaceRunHeader: Sendable, Equatable {
    public static let localRoute = "On this Mac"

    public let token: String
    /// Where the material came from; drawn by the shared formatter.
    public let provenance: OmniProvenanceLine?
    public let submittedAt: Date?
    /// The run this one came from, e.g. `from /stance · Decline, keep warm`.
    public let origin: String?
    /// What ran it: the provider's name for a model run, `On this Mac` when
    /// no model tier ran, nil while that is not yet known.
    public let route: String?

    public init(token: String, provenance: OmniProvenanceLine? = nil, submittedAt: Date? = nil, origin: String? = nil, route: String? = nil) {
        self.token = token
        self.provenance = provenance
        self.submittedAt = submittedAt
        self.origin = origin
        self.route = route
    }
}

/// One immutable result revision. The application owns persistence and maps it
/// into this presentation value; this module does not depend on run storage.
public struct OmniWorkspaceVersion: Sendable, Equatable, Identifiable {
    public let number: Int
    public let inputText: String
    public let resultText: String
    public let operation: String
    public let sourceVersion: Int?
    public let annotations: [OmniTextAnnotation]

    public var id: Int { number }

    public init(
        number: Int,
        inputText: String,
        resultText: String,
        operation: String,
        sourceVersion: Int? = nil,
        annotations: [OmniTextAnnotation] = []
    ) {
        self.number = number
        self.inputText = inputText
        self.resultText = resultText
        self.operation = operation
        self.sourceVersion = sourceVersion
        self.annotations = annotations
    }
}

@MainActor
public final class OmniWorkspace: NSObject, NSWindowDelegate, NSTextViewDelegate, NSToolbarDelegate {
    /// Called by workspace affordances before this module makes the
    /// workspace key. Hosts use it to capture foreground ownership first.
    public var onOpenWorkspace: (() -> Void)?
    public var onSelectRun: ((String) -> Void)?
    public var onSelectVersion: ((Int) -> Void)?
    public var onContinue: ((String, Int) -> Void)?
    /// A `/find` row action (D2): run ID, row index in the receipt, action.
    public var onPickerAction: ((String, Int, OmniPickerAction) -> Void)?
    /// The selected run's `/find` rows; empty for every other result.
    public private(set) var pickerRows: [OmniFindRow] = []
    public var onSubmit: ((String, OmniSubmitGesture) -> Void)?
    public var onAnnotationsChanged: (([OmniTextAnnotation]) -> Void)?
    public var onComposerTextChanged: ((String) -> Void)?
    public var onClose: (() -> Void)?
    public var onCopy: ((String, Int) -> Void)?
    public var onCancel: ((String) -> Void)?
    public var onDiscardDraft: ((String, Int) -> Void)?
    public var onNewRequest: (() -> Void)?
    /// A run opened from history: the host
    /// shows the workspace at that run (and withdraws its notification).
    public var onOpenRun: ((String) -> Void)?
    /// The pinned Stash row was chosen (C42): the host stops following a run.
    public var onSelectStash: (() -> Void)?
    public var onStashEdited: ((String, String) -> Void)?
    public var onStashCopy: ((String) -> Void)?
    public var onStashDrop: ((String) -> Void)?
    public var onStashClear: (() -> Void)?
    /// The stack, top first; empty hides the pinned row.
    public private(set) var stashEntries: [OmniWorkspaceStashEntry] = []
    public let stashView = OmniWorkspaceStashView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
    private var stashNotice: String?
    private weak var stashRowButton: OmniWorkspaceButton?
    public var isShowingStash: Bool {
        if case .stash = detailMode { return true }
        return false
    }

    /// Inspection points deliberately remain public for native UI tests and
    /// for application-level accessibility automation.
    /// A standard macOS window (C33): system sidebar material plus detail, no frost.
    public let workspacePanel: NSWindow
    public let editor = OmniCommandTextView()
    public var annotations: [OmniTextAnnotation] { editor.annotations }
    private lazy var annotationUI = OmniAnnotationUI(editor: editor)
    public private(set) var selectedRunID: String?
    public private(set) var selectedVersion: Int?
    public var displayedRuns: [OmniWorkspaceRunRow] { runRows }
    public var displayedVersions: [OmniWorkspaceVersion] { versions }
    public var pendingText: String? { pendingResultText }
    public var isShowingComposer: Bool {
        if case .composer = detailMode { return true }
        return false
    }

    private let parser: OmniParser?
    private let developmentIndicator: String
    private var stylingEditor = false
    private weak var composerNotesButton: OmniPadInlineButton?
    private weak var composerRouteLabel: NSTextField?
    private var visibleFrame: NSRect
    private var runRows: [OmniWorkspaceRunRow] = []
    private var versions: [OmniWorkspaceVersion] = []
    private var resultTitle = ""
    private var resultStatus = ""
    private var resultAnnotationNotice: String?
    private var pendingResultText: String?
    private var pendingAnnotations: [OmniTextAnnotation] = []
    private var submittedInput: String?
    private var submittedAnnotations: [OmniTextAnnotation] = []
    private var resumeAvailable = false
    private var continueAvailable = true
    /// Whether the shown result offers Continue (never for a `/find` list).
    public var offersContinue: Bool { continueAvailable }
    private var canCancelResult = false
    private var resultHeader: OmniWorkspaceRunHeader?
    private var composerRoute: String?
    private var inputDisclosed = false
    private var composerRunButton: OmniPadRunButton?
    private var rowButtons: [OmniWorkspaceButton] = []
    private var rowStep = 0
    private var rowTicker: Timer?
    private var detailContainer = OmniWorkspaceDetailView()
    private var layingOutComposerFooter = false
    private var runListStack = NSStackView()
    private var runListWidthConstraints: [NSLayoutConstraint] = []
    private var detailMode: DetailMode = .empty

    private enum DetailMode {
        case empty
        case result
        case composer(runID: String?, sourceVersion: Int?, sourceLabel: String?)
        case stash
    }

    public init(visibleFrame: NSRect, parser: OmniParser? = nil, developmentIndicator: String = "Glacier workspace") {
        self.visibleFrame = visibleFrame
        self.parser = parser
        self.developmentIndicator = developmentIndicator

        workspacePanel = OmniWorkspaceWindow(
            contentRect: Self.workspaceFrame(visibleFrame: visibleFrame),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        editor.installAnnotationTracking()
        editor.onAnnotationsChanged = { [weak self] notes in
            guard let self else { return }
            self.annotationUI.changed()
            self.updateComposerNotesButton()
            self.onAnnotationsChanged?(notes)
        }
        annotationUI.onNotice = { [weak self] message in self?.showComposerNotice(message) }
        stashView.onEdited = { [weak self] id, text in self?.onStashEdited?(id, text) }
        stashView.onCopy = { [weak self] id in self?.onStashCopy?(id) }
        stashView.onDrop = { [weak self] id in self?.onStashDrop?(id) }
        stashView.onClear = { [weak self] in self?.onStashClear?() }
        stashView.autoresizingMask = [.width, .height]
        configurePanels()
        // Day groups and clock times roll over at midnight (C34). The
        // selector observer unregisters itself when this object goes away.
        NotificationCenter.default.addObserver(self, selector: #selector(calendarDayChanged(_:)), name: .NSCalendarDayChanged, object: nil)
    }

    // NotificationCenter invokes selectors on the posting queue, including its midnight worker.
    @objc nonisolated private func calendarDayChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.rebuildRunList() }
    }

    public func showWorkspace() {
        workspacePanel.makeKeyAndOrderFront(nil)
        updateRowTicker()
    }

    public func hideWorkspace(notify: Bool = false) {
        annotationUI.closeAll()
        workspacePanel.orderOut(nil)
        updateRowTicker()
        if notify { onClose?() }
    }

    /// Escape hides an editable request without treating it as run cancellation.
    public func dismissComposer() {
        hideWorkspace(notify: true)
    }

    /// Invokes the host focus/capture boundary before opening the panel.
    public func openWorkspace() {
        if let onOpenWorkspace { onOpenWorkspace() }
        else { showWorkspace() }
    }

    public func updateVisibleFrame(_ frame: NSRect) {
        visibleFrame = frame
        workspacePanel.setFrame(Self.workspaceFrame(visibleFrame: frame), display: true)
    }

    /// Host code maps durable run records into these compact presentation rows.
    /// Refreshes deliberately leave composer text and selection untouched.
    public func displayRuns(_ rows: [OmniWorkspaceRunRow], selectedID: String?) {
        runRows = rows
        selectedRunID = selectedID
        rebuildRunList()
    }

    /// Group label for the sidebar (C34): Today, Yesterday, a weekday within
    /// the week, else the date.
    nonisolated public static func dayLabel(for date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Earlier" }
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        }
        return formatter.string(from: date)
    }

    /// Row time (C34): clock time today, weekday within the week, else the date.
    nonisolated public static func timeLabel(for date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let calendar = Calendar.autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
        }
        return formatter.string(from: date)
    }

    /// Displays an explicit result selection. Polling should use `displayRuns`
    /// alone while text is edited; this method intentionally exits composer mode.
    public func displayResult(
        runID: String,
        title: String,
        status: String,
        versions: [OmniWorkspaceVersion],
        selectedVersion: Int,
        pendingText: String? = nil,
        submittedInput: String? = nil,
        resumeAvailable: Bool = false,
        canCancel: Bool = false,
        header: OmniWorkspaceRunHeader? = nil,
        composerRoute: String? = nil,
        annotationNotice: String? = nil,
        pendingAnnotations: [OmniTextAnnotation] = [],
        submittedAnnotations: [OmniTextAnnotation] = [],
        continueAvailable: Bool = true,
        pickerRows: [OmniFindRow] = []
    ) {
        annotationUI.closeAll()
        if selectedRunID != runID { inputDisclosed = false }
        self.continueAvailable = continueAvailable && pickerRows.isEmpty
        self.pickerRows = pickerRows
        selectedRunID = runID
        resultTitle = title
        resultStatus = status
        resultAnnotationNotice = annotationNotice
        resultHeader = header
        self.composerRoute = composerRoute
        self.versions = versions.sorted { $0.number > $1.number }
        self.selectedVersion = selectedVersion
        pendingResultText = pendingText
        self.pendingAnnotations = pendingAnnotations
        self.submittedInput = submittedInput
        self.submittedAnnotations = submittedAnnotations
        self.resumeAvailable = resumeAvailable
        canCancelResult = canCancel
        detailMode = .result
        rebuildRunList()
        rebuildDetail()
    }

    public func showComposer(
        text: String,
        runID: String? = nil,
        sourceVersion: Int? = nil,
        sourceLabel: String? = nil,
        annotations: [OmniTextAnnotation] = []
    ) {
        annotationUI.closeAll()
        selectedRunID = runID
        selectedVersion = sourceVersion
        detailMode = .composer(runID: runID, sourceVersion: sourceVersion, sourceLabel: sourceLabel)
        replaceEditorTextPreservingSelection(text, preserveWhenEqual: true)
        editor.setAnnotations(annotations)
        rebuildRunList()
        rebuildDetail()
        workspacePanel.makeFirstResponder(editor)
    }

    /// The stack behind the pinned row. An open stash detail updates in
    /// place; the row appears and disappears with the stack (C42).
    public func displayStash(_ entries: [OmniWorkspaceStashEntry], notice: String? = nil) {
        let rowChanged = entries.isEmpty != stashEntries.isEmpty || entries.count != stashEntries.count
        stashEntries = entries
        stashNotice = notice
        if rowChanged || stashRowButton == nil && !entries.isEmpty {
            rebuildRunList()
        } else if let top = entries.first, let button = stashRowButton {
            // Typing in the top entry refreshes its excerpt, not the list.
            button.detailText = Self.excerpt(top.text.isEmpty ? "Image" : top.text)
        }
        if isShowingStash { stashView.update(entries: entries, notice: notice) }
    }

    /// Shows the stash detail, with one entry's editor focused (⌘↩ Edit from
    /// the stack view, C94).
    public func showStash(focusing entryID: String? = nil) {
        annotationUI.closeAll()
        selectedRunID = nil
        detailMode = .stash
        rebuildRunList()
        rebuildDetail()
        stashView.focus(entryID: entryID)
    }

    public func selectStash() {
        showStash()
        onSelectStash?()
    }

    public func setAnnotations(_ notes: [OmniTextAnnotation]) { editor.setAnnotations(notes) }
    public func showComposerNotice(_ message: String) {
        composerRoute = message
        composerRouteLabel?.stringValue = message
        composerRouteLabel?.setAccessibilityLabel(message)
        composerRouteLabel?.toolTip = message
    }
    /// A one-line notice under the displayed result's header (a refused
    /// Continue, for example); the next `displayResult` replaces it.
    public func showResultNotice(_ message: String) {
        guard case .result = detailMode else { return }
        resultAnnotationNotice = message
        rebuildDetail()
    }
    public func openAnnotationForSelection() { annotationUI.openForSelection() }
    public var annotationCardPanel: NSPanel? { annotationUI.card }
    public var annotationHoverPanel: NSPanel? { annotationUI.hover }
    public var annotationOverviewPanel: NSPanel? { annotationUI.overview }

    /// Exposed for test harnesses and host key bindings. The text view remains
    /// the sole editable authority for helper insertion.
    public func insertShorterHelper() {
        editor.insertText("/shorter ", replacementRange: editor.selectedRange())
        editor.didChangeText()
    }

    public func selectRun(_ id: String) {
        selectedRunID = id
        rebuildRunList()
        onSelectRun?(id)
    }

    public func selectVersion(_ number: Int) {
        selectedVersion = number
        rebuildDetail()
        onSelectVersion?(number)
    }

    public func submitEditor(gesture: OmniSubmitGesture = .commandEnterAttach) {
        onSubmit?(editor.string, gesture)
    }

    public func cancelPending() {
        guard let runID = selectedRunID else { return }
        onCancel?(runID)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === workspacePanel else { return true }
        hideWorkspace(notify: true)
        return false
    }

    private func configurePanels() {
        workspacePanel.title = "Glacier"
        workspacePanel.minSize = NSSize(width: 760, height: 520)
        workspacePanel.isReleasedWhenClosed = false
        workspacePanel.collectionBehavior = [.moveToActiveSpace]
        workspacePanel.tabbingMode = .disallowed
        workspacePanel.delegate = self
        workspacePanel.setAccessibilityIdentifier("omni.workspace.panel")
        workspacePanel.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("omni.workspace.toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        workspacePanel.toolbar = toolbar
        workspacePanel.contentViewController = workspaceSplitController()
    }

    static let copyToolbarItem = NSToolbarItem.Identifier("omni.workspace.toolbar.copy")
    static let newToolbarItem = NSToolbarItem.Identifier("omni.workspace.toolbar.new")

    /// Sidebar (system material) + detail, like Notes or Mail (C33).
    private func workspaceSplitController() -> NSSplitViewController {
        let split = NSSplitViewController()
        let sidebarController = NSViewController()
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 264, height: 600))
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.setAccessibilityIdentifier("omni.workspace.sidebar")
        let listScroll = OmniWorkspaceRunListScrollView(frame: NSRect(x: 12, y: 12, width: 240, height: 576))
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.automaticallyAdjustsContentInsets = true
        listScroll.autoresizingMask = [.width, .height]
        listScroll.setAccessibilityIdentifier("omni.workspace.run-scroll")
        runListStack = OmniWorkspaceRunStack()
        runListStack.orientation = .vertical
        runListStack.alignment = .leading
        runListStack.spacing = 5
        runListStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        runListStack.frame = NSRect(x: 0, y: 0, width: listScroll.contentSize.width, height: 1)
        listScroll.documentView = runListStack
        listScroll.onViewportWidthChange = { [weak self] width in self?.resizeRunList(to: width) }
        sidebar.addSubview(listScroll)
        sidebarController.view = sidebar
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 264
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true

        let detailController = NSViewController()
        detailContainer = OmniWorkspaceDetailView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        detailContainer.onLayout = { [weak self] in self?.layoutComposerFooter() }
        detailContainer.setAccessibilityIdentifier("omni.workspace.detail")
        detailController.view = detailContainer
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailController))
        split.splitView.dividerStyle = .thin
        split.view.setAccessibilityIdentifier("omni.workspace.content")
        return split
    }

    // MARK: NSToolbarDelegate (Copy · New, C33)

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, Self.copyToolbarItem, Self.newToolbarItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.copyToolbarItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Copy"
            item.paletteLabel = "Copy result"
            item.toolTip = "Copy the shown result"
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy result")
            item.target = self
            item.action = #selector(copyToolbarAction(_:))
            item.isBordered = true
            return item
        case Self.newToolbarItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "New"
            item.paletteLabel = "New request"
            item.toolTip = "New request (opens the pad)"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New request")
            item.target = self
            item.action = #selector(newToolbarAction(_:))
            item.isBordered = true
            return item
        default:
            return nil
        }
    }

    @objc private func copyToolbarAction(_ sender: Any?) { copySelectedResult() }
    @objc private func newToolbarAction(_ sender: Any?) { onNewRequest?() }

    /// The toolbar's Copy: the shown version's full result.
    public func copySelectedResult() {
        if isShowingStash {
            if let id = stashView.focusedEntryID ?? stashEntries.first?.id { onStashCopy?(id) }
            return
        }
        guard let runID = selectedRunID, let number = selectedVersion ?? versions.first?.number else { return }
        onCopy?(runID, number)
    }

    private func rebuildRunList() {
        guard runListStack.superview != nil else { return }
        runListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        runListWidthConstraints.removeAll()
        rowButtons.removeAll()
        let width = max(1, (runListStack.superview as? NSClipView)?.bounds.width ?? runListStack.frame.width)
        let rowHeight: CGFloat = 56
        var height: CGFloat = 0
        var lastGroup: String?
        let now = Date()
        func addGroupHeader(_ group: String) {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
            let header = NSTextField(labelWithString: group.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = OmniFrostedStyle.secondaryInk
            header.frame = NSRect(x: 12, y: 2, width: width - 24, height: 14)
            header.autoresizingMask = [.width]
            header.setAccessibilityIdentifier("omni.workspace.run-group")
            container.addSubview(header)
            runListStack.addArrangedSubview(container)
            let widthConstraint = container.widthAnchor.constraint(equalToConstant: width)
            widthConstraint.isActive = true
            runListWidthConstraints.append(widthConstraint)
            container.heightAnchor.constraint(equalToConstant: 22).isActive = true
            height += 22 + runListStack.spacing
        }
        // Pinned above Today (C42), one row for the whole stack (C92).
        if let top = stashEntries.first {
            addGroupHeader("Pinned")
            let button = actionButton(title: "Stash", identifier: "omni.workspace.stash-row") { [weak self] in self?.selectStash() }
            button.treatment = .row
            button.alignment = .left
            button.leadingSymbolName = "archivebox"
            stashRowButton = button
            button.timeText = "\(stashEntries.count) of \(OmniStashStack.capacity)"
            button.detailText = Self.excerpt(top.text.isEmpty ? "Image" : top.text)
            button.setButtonType(.toggle)
            button.state = isShowingStash ? .on : .off
            button.setAccessibilityLabel("Stash, \(button.timeText), \(button.detailText)")
            runListStack.addArrangedSubview(button)
            let widthConstraint = button.widthAnchor.constraint(equalToConstant: width)
            widthConstraint.isActive = true
            runListWidthConstraints.append(widthConstraint)
            button.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            height += rowHeight + runListStack.spacing
        }
        for row in runRows {
            let group = Self.dayLabel(for: row.submittedAt, now: now)
            if group != lastGroup {
                addGroupHeader(group)
                lastGroup = group
            }
            let button = rowButton(row, identifier: "omni.workspace.run.\(row.id)", now: now) { [weak self] in self?.selectRun(row.id) }
            button.setButtonType(.toggle)
            button.state = row.id == selectedRunID && !isShowingStash ? .on : .off
            runListStack.addArrangedSubview(button)
            let widthConstraint = button.widthAnchor.constraint(equalToConstant: width)
            widthConstraint.isActive = true
            runListWidthConstraints.append(widthConstraint)
            button.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            rowButtons.append(button)
            height += rowHeight + runListStack.spacing
        }
        runListStack.setFrameSize(NSSize(width: width, height: max(1, height)))
        updateRowTicker()
    }

    /// The scroll view reports its usable clip width after AppKit has accounted
    /// for either overlay or legacy scrollers. Existing rows and detail survive
    /// a split-view drag; only the sidebar's width constraints change.
    private func resizeRunList(to width: CGFloat) {
        let width = max(1, width)
        guard runListStack.frame.width != width || runListWidthConstraints.contains(where: { $0.constant != width }) else { return }
        for constraint in runListWidthConstraints { constraint.constant = width }
        runListStack.setFrameSize(NSSize(width: width, height: runListStack.frame.height))
    }

    private func rowButton(_ row: OmniWorkspaceRunRow, identifier: String, now: Date, action: @escaping () -> Void) -> OmniWorkspaceButton {
        let title = row.title.isEmpty ? (row.token.isEmpty ? row.id : "") : row.title
        let button = actionButton(title: title, identifier: identifier, action: action)
        button.treatment = .row
        button.alignment = .left
        button.tokenText = row.token
        button.timeText = Self.timeLabel(for: row.submittedAt, now: now)
        button.detailText = Self.excerpt(row.summary)
        button.activity = row.activity
        button.rowStep = rowStep
        button.toolTip = "\(row.token) \(title) · \(row.status)".trimmingCharacters(in: .whitespaces)
        button.setAccessibilityLabel([row.token, title, row.status, button.detailText].filter { !$0.isEmpty }.joined(separator: ", "))
        return button
    }

    static func excerpt(_ summary: String) -> String {
        String(summary.replacingOccurrences(of: "[Synthetic fixture output]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(120))
    }

    /// The stepping dot on running rows (C34) advances once a second while
    /// any row is running; nothing ticks otherwise.
    private func updateRowTicker() {
        let visible = workspacePanel.isVisible
        let running = visible && (runRows.contains { $0.activity == .running })
        if running {
            guard rowTicker == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.stepRunningRows() }
            }
            RunLoop.main.add(timer, forMode: .common)
            rowTicker = timer
        } else {
            rowTicker?.invalidate()
            rowTicker = nil
        }
    }

    private func stepRunningRows() {
        rowStep = (rowStep + 1) % 4
        for button in rowButtons where button.activity == .running {
            button.rowStep = rowStep
        }
    }

    private func rebuildDetail() {
        guard detailContainer.superview != nil else { return }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        switch detailMode {
        case .empty:
            let label = NSTextField(wrappingLabelWithString: "Select a run, or start a new request from the pad.")
            label.textColor = .secondaryLabelColor
            label.frame = detailContainer.bounds.insetBy(dx: 28, dy: 28)
            label.autoresizingMask = [.width, .height]
            detailContainer.addSubview(label)
        case .result:
            buildResultDetail()
        case .composer(let runID, let sourceVersion, let sourceLabel):
            buildComposerDetail(runID: runID, sourceVersion: sourceVersion, sourceLabel: sourceLabel)
        case .stash:
            stashView.frame = detailContainer.bounds
            detailContainer.addSubview(stashView)
            stashView.update(entries: stashEntries, notice: stashNotice)
        }
    }

    private var detailTop: CGFloat {
        detailContainer.bounds.height - detailContainer.safeAreaInsets.top - 18
    }

    /// The header chain (D3, C81): `token · From <icon> App “Title” · route`.
    /// The time is its own right-aligned label. When the chain does not fit
    /// `width`, the window title shortens with an ellipsis first, then the
    /// origin (`from /stance · …`), so the route stays; the time is never cut.
    /// Refitted whenever the label's width changes.
    func subtitleText(fitting width: CGFloat? = nil) -> NSAttributedString {
        let origin = resultHeader?.origin
        let provenance = resultHeader?.provenance
        let full = subtitleChain(origin: origin, provenance: provenance)
        guard let width, full.size().width > width else { return full }
        var line = provenance
        if let current = provenance, let title = current.windowTitle {
            let titled: (String?) -> OmniProvenanceLine? = { kept in
                OmniProvenanceLine(appName: current.appName, windowTitle: kept, bundleIdentifier: current.bundleIdentifier)
            }
            let fit = Self.shortened(title, width: width) { kept in self.subtitleChain(origin: origin, provenance: titled(kept)) }
            if fit.fits { return fit.chain }
            line = titled(nil)
        }
        if let origin, !origin.isEmpty {
            let fit = Self.shortened(origin, width: width) { kept in self.subtitleChain(origin: kept, provenance: line) }
            if fit.fits { return fit.chain }
            return subtitleChain(origin: nil, provenance: line)
        }
        return subtitleChain(origin: origin, provenance: line)
    }

    /// The longest prefix of `text` (with an ellipsis; nil drops it) whose
    /// chain fits `width`, by binary search: titles are uncapped.
    static func shortened(_ text: String, width: CGFloat, chain: (String?) -> NSAttributedString) -> (fits: Bool, chain: NSAttributedString) {
        let characters = Array(text)
        func candidate(_ keep: Int) -> NSAttributedString {
            chain(keep == 0 ? nil : String(characters.prefix(keep)).trimmingCharacters(in: .whitespaces) + "…")
        }
        var best = candidate(0)
        guard best.size().width <= width else { return (false, best) }
        var low = 1
        var high = characters.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let attempt = candidate(middle)
            if attempt.size().width <= width {
                best = attempt
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return (true, best)
    }

    static func timeLabelWidth(_ label: NSTextField) -> CGFloat {
        ceil(max(label.intrinsicContentSize.width, label.attributedStringValue.size().width)) + 6
    }

    /// `Today, 14:42`, `Yesterday, 18:02` or `Oct 1 09:12`, right-aligned on
    /// the header row (Apple's idiom; C81).
    func subtitleTime() -> String? {
        guard let date = resultHeader?.submittedAt else { return nil }
        let day = Self.dayLabel(for: date)
        let time = Self.timeLabel(for: date, now: date)
        return day == "Today" || day == "Yesterday" ? "\(day), \(time)" : "\(day) \(time)"
    }

    private func subtitleChain(origin: String?, provenance: OmniProvenanceLine?) -> NSAttributedString {
        let secondary: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let result = NSMutableAttributedString()
        if let header = resultHeader {
            if !header.token.isEmpty {
                result.append(NSAttributedString(string: header.token, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: OmniFrostedStyle.command,
                    .backgroundColor: OmniFrostedStyle.commandTokenFill,
                ]))
            }
            var parts: [NSAttributedString] = []
            if let origin, !origin.isEmpty { parts.append(NSAttributedString(string: origin, attributes: secondary)) }
            if let provenance { parts.append(provenance.attributed(attributes: secondary, iconSize: 14)) }
            if let route = header.route, !route.isEmpty { parts.append(NSAttributedString(string: route, attributes: secondary)) }
            for part in parts {
                if result.length > 0 { result.append(NSAttributedString(string: " · ", attributes: secondary)) }
                result.append(part)
            }
        }
        if result.length == 0 { result.append(NSAttributedString(string: resultStatus, attributes: secondary)) }
        return result
    }

    /// `v1 /email · v2 /shorter`, latest selected; branches read `v3 · on v1` (C35).
    func versionPillLabel(_ version: OmniWorkspaceVersion) -> String {
        let operation: String = switch version.operation.lowercased() {
        case "initial": resultHeader?.token ?? version.operation
        case "shorter": "/shorter"
        case "more formal", "formal": "/formal"
        default: version.operation
        }
        if let source = version.sourceVersion, source != version.number - 1 {
            return "v\(version.number) \(operation) · on v\(source)"
        }
        return "v\(version.number) \(operation)"
    }

    @discardableResult
    static func fitVersionStrip(_ strip: NSScrollView, top: CGFloat, width: CGFloat) -> CGFloat {
        strip.layoutSubtreeIfNeeded()
        let scrollerHeight = max(0, strip.frame.height - strip.contentSize.height)
        strip.frame = NSRect(x: strip.frame.minX, y: top - 24 - scrollerHeight, width: width, height: 24 + scrollerHeight)
        strip.layoutSubtreeIfNeeded()
        return scrollerHeight
    }

    private func buildResultDetail() {
        let bounds = detailContainer.bounds
        let top = detailTop
        let left: CGFloat = 28
        let contentWidth = max(1, bounds.width - left - 28)
        var y = top

        let title = NSTextField(labelWithString: resultTitle.isEmpty ? (selectedRunID ?? "Run") : resultTitle)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: left, y: y - 26, width: contentWidth, height: 26)
        title.autoresizingMask = [.width, .minYMargin]
        title.setAccessibilityIdentifier("omni.workspace.result-title")
        detailContainer.addSubview(title)
        y -= 30

        var chainWidth = contentWidth
        if let timeText = subtitleTime() {
            let time = NSTextField(labelWithString: timeText)
            time.font = .systemFont(ofSize: 12)
            time.textColor = .secondaryLabelColor
            time.alignment = .right
            // A few points of slack: the label's cell insets would otherwise
            // clip the last digit at the trailing edge.
            let timeWidth = Self.timeLabelWidth(time)
            time.frame = NSRect(x: left + contentWidth - timeWidth, y: y - 18, width: timeWidth, height: 18)
            time.autoresizingMask = [.minXMargin, .minYMargin]
            time.setAccessibilityIdentifier("omni.workspace.result-time")
            detailContainer.addSubview(time)
            chainWidth = max(1, contentWidth - timeWidth - 16)
        }
        let subtitle = OmniFittingLabel(labelWithString: "")
        subtitle.fit = { [weak self] width in self?.subtitleText(fitting: width) ?? NSAttributedString() }
        subtitle.attributedStringValue = subtitleText(fitting: chainWidth)
        // VoiceOver reads the whole chain and the time, never the shortened form.
        subtitle.setAccessibilityLabel([subtitleText().string, subtitleTime()].compactMap { $0 }.joined(separator: " · "))
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: left, y: y - 18, width: chainWidth, height: 18)
        subtitle.autoresizingMask = [.width, .minYMargin]
        subtitle.setAccessibilityIdentifier("omni.workspace.result-subtitle")
        detailContainer.addSubview(subtitle)
        y -= 26

        if let notice = resultAnnotationNotice, !notice.isEmpty {
            let routeNotice = NSTextField(labelWithString: notice)
            routeNotice.font = .systemFont(ofSize: 12, weight: .medium)
            routeNotice.textColor = .systemOrange
            routeNotice.lineBreakMode = .byTruncatingTail
            routeNotice.frame = NSRect(x: left, y: y - 18, width: contentWidth, height: 18)
            routeNotice.autoresizingMask = [.width, .minYMargin]
            routeNotice.setAccessibilityIdentifier("omni.workspace.annotation-notice")
            detailContainer.addSubview(routeNotice)
            y -= 24
        }

        let version = versions.first { $0.number == selectedVersion } ?? versions.first
        if versions.count > 1 {
            let strip = NSScrollView(frame: NSRect(x: left, y: y - 40, width: contentWidth, height: 40))
            strip.borderType = .noBorder
            strip.drawsBackground = false
            strip.hasHorizontalScroller = true
            strip.autohidesScrollers = true
            strip.autoresizingMask = [.width, .minYMargin]
            strip.setAccessibilityIdentifier("omni.workspace.version-strip")
            let row = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 24))
            var x = left
            var selectedX: CGFloat = 0
            for entry in versions.sorted(by: { $0.number < $1.number }) {
                let pill = OmniVersionPill(label: versionPillLabel(entry)) { [weak self] in self?.selectVersion(entry.number) }
                pill.isSelected = entry.number == selectedVersion
                pill.isEnabled = pendingResultText == nil
                pill.setAccessibilityIdentifier("omni.workspace.version.\(entry.number)")
                pill.frame = NSRect(x: x - left, y: 0, width: pill.fittingWidth, height: 24)
                if pill.isSelected { selectedX = pill.frame.minX }
                row.addSubview(pill)
                x += pill.fittingWidth + 6
            }
            row.setFrameSize(NSSize(width: max(contentWidth, x - left - 6), height: 24))
            strip.documentView = row
            // Regular system scrollbars take vertical room; overlay scrollbars do not.
            let scrollerHeight = Self.fitVersionStrip(strip, top: y, width: contentWidth)
            if row.frame.width > contentWidth {
                let offset = min(selectedX, row.frame.width - contentWidth)
                strip.contentView.scroll(to: NSPoint(x: offset, y: 0))
                strip.reflectScrolledClipView(strip.contentView)
            }
            detailContainer.addSubview(strip)
            y -= 34 + scrollerHeight
        }

        // Bottom row: Continue/Resume · Cancel when pending.
        let continueButton = actionButton(title: resumeAvailable ? "Resume" : "Continue", identifier: "omni.workspace.continue") { [weak self] in
            guard let self, let runID = self.selectedRunID, let number = self.selectedVersion else { return }
            self.onContinue?(runID, number)
        }
        continueButton.treatment = .primary
        continueButton.image = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)
        continueButton.frame = NSRect(x: left, y: 14, width: 126, height: 32)
        continueButton.autoresizingMask = [.maxYMargin]
        continueButton.isEnabled = version != nil && pendingResultText == nil
        // Positions are picked in the pad, never continued as prose (D6).
        continueButton.isHidden = !continueAvailable
        detailContainer.addSubview(continueButton)

        let cancel = actionButton(title: "Cancel", identifier: "omni.workspace.cancel-pending") { [weak self] in self?.cancelPending() }
        cancel.frame = NSRect(x: left + 136, y: 14, width: 82, height: 32)
        cancel.autoresizingMask = [.maxYMargin]
        cancel.isHidden = (pendingResultText == nil && !canCancelResult) || selectedRunID == nil
        detailContainer.addSubview(cancel)
        var bottom: CGFloat = 60

        // Input: behind a disclosure once there is a result; shown while pending or before any result.
        let inputText = pendingResultText ?? version?.inputText ?? submittedInput ?? ""
        let inputAnnotations = pendingResultText != nil ? pendingAnnotations : (version?.annotations ?? submittedAnnotations)
        let showInput = pendingResultText != nil || version == nil || inputDisclosed
        let disclosureTitle: String = {
            if pendingResultText != nil { return "Pending request" }
            guard let version else { return "Request" }
            let operation = versionPillLabel(version).split(separator: " ").dropFirst().joined(separator: " ")
            let base = "Input for v\(version.number)"
            return version.sourceVersion.map { "\(base) · \(operation) on v\($0)" } ?? base
        }()
        let disclosure = actionButton(title: (showInput ? "▾ " : "▸ ") + disclosureTitle, identifier: "omni.workspace.input-disclosure") { [weak self] in
            guard let self else { return }
            self.inputDisclosed.toggle()
            self.rebuildDetail()
        }
        disclosure.treatment = .plain
        disclosure.alignment = .left
        disclosure.frame = NSRect(x: left - 8, y: bottom, width: min(contentWidth, 420), height: 24)
        disclosure.autoresizingMask = [.maxYMargin]
        disclosure.isEnabled = version != nil && pendingResultText == nil
        detailContainer.addSubview(disclosure)
        bottom += 30
        if showInput {
            // Whole-request notes have no span to tint: they read beneath the
            // input, as the notes overview names them (D2).
            let requestNotes = inputAnnotations.filter(\.isRequestScoped)
            if !requestNotes.isEmpty {
                let line = NSTextField(labelWithString: requestNotes.map { OmniAnnotationUI.overviewSnippet($0, source: "" as NSString) }.joined(separator: "   |   "))
                line.font = .systemFont(ofSize: 11.5, weight: .medium)
                line.textColor = OmniFrostedStyle.annotationRule
                line.lineBreakMode = .byTruncatingTail
                line.frame = NSRect(x: left, y: bottom, width: contentWidth, height: 16)
                line.autoresizingMask = [.width, .maxYMargin]
                line.setAccessibilityIdentifier("omni.workspace.request-notes")
                detailContainer.addSubview(line)
                bottom += 22
            }
            let input = resultTextView(text: inputText, identifier: "omni.workspace.version-input")
            let height: CGFloat = version == nil ? max(80, y - bottom - 12) : 96
            input.frame = NSRect(x: left, y: bottom, width: contentWidth, height: height)
            input.autoresizingMask = version == nil ? [.width, .height] : [.width, .maxYMargin]
            if let text = input.documentView as? OmniSelectableTextView {
                if let parser {
                    text.textStorage?.setAttributedString(OmniTokenRenderer.attributedText(inputText, parser: parser, fontSize: 14, followUp: version?.sourceVersion != nil))
                }
                text.annotations = inputAnnotations
            }
            detailContainer.addSubview(input)
            bottom += height + 10
        }

        if !pickerRows.isEmpty {
            // A `/find` result lists its rows, every one, with the pad's
            // actions (D2); the path list stays in the receipt for Copy.
            let list = pickerList(width: contentWidth)
            list.frame = NSRect(x: left, y: bottom, width: contentWidth, height: max(60, y - bottom - 8))
            list.autoresizingMask = [.width, .height]
            detailContainer.addSubview(list)
        } else if version != nil {
            let result = resultTextView(text: version?.resultText ?? "", identifier: "omni.workspace.version-result")
            result.frame = NSRect(x: left, y: bottom, width: contentWidth, height: max(60, y - bottom - 8))
            result.autoresizingMask = [.width, .height]
            detailContainer.addSubview(result)
        } else if pendingResultText == nil, let status = Optional(resultStatus), !status.isEmpty {
            let working = NSTextField(labelWithString: status == "running" || status == "queued" ? "Working…" : status)
            working.font = .systemFont(ofSize: 13)
            working.textColor = .secondaryLabelColor
            working.frame = NSRect(x: left, y: y - 24, width: contentWidth, height: 18)
            working.autoresizingMask = [.width, .minYMargin]
            detailContainer.addSubview(working)
        }
    }

    /// The continue composer (C37): the editable body · route line · ↩ Apply.
    private func buildComposerDetail(runID: String?, sourceVersion: Int?, sourceLabel: String?) {
        let bounds = detailContainer.bounds
        let top = detailTop
        let left: CGFloat = 28
        let contentWidth = max(1, bounds.width - left - 28)

        let title = NSTextField(labelWithString: resultTitle.isEmpty ? "Follow-up" : resultTitle)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: left, y: top - 26, width: contentWidth, height: 26)
        title.autoresizingMask = [.width, .minYMargin]
        detailContainer.addSubview(title)

        let source = sourceLabel ?? sourceVersion.map { "Continue from v\($0) · edit the text and add /formal or /shorter" } ?? "Write the request that should be applied."
        let subtitle = NSTextField(labelWithString: source)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: left, y: top - 48, width: contentWidth, height: 18)
        subtitle.autoresizingMask = [.width, .minYMargin]
        detailContainer.addSubview(subtitle)

        let footerHeight: CGFloat = 52
        let scroll = NSScrollView(frame: NSRect(x: left, y: footerHeight, width: contentWidth, height: max(80, top - 60 - footerHeight)))
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        editor.frame = scroll.bounds
        editor.minSize = NSSize(width: 0, height: 60)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 4, height: 10)
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.insertionPointColor = OmniFrostedStyle.accent
        editor.delegate = self
        editor.isRichText = true
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.placeholder = "Continue from v\(sourceVersion ?? 1) — /formal or /shorter"
        editor.setAccessibilityIdentifier("omni.workspace.editor")
        editor.setAccessibilityLabel("Glacier follow-up request")
        editor.onSubmit = { [weak self] gesture in self?.submitEditor(gesture: gesture) }
        editor.onEscape = { [weak self] in self?.dismissComposer() }
        scroll.documentView = editor
        scroll.setAccessibilityIdentifier("omni.workspace.composer-scroll")
        detailContainer.addSubview(scroll)
        styleComposerText()

        let rule = OmniWorkspaceRule(frame: NSRect(x: left, y: footerHeight - 2, width: contentWidth, height: 1))
        rule.autoresizingMask = [.width, .maxYMargin]
        rule.setAccessibilityIdentifier("omni.workspace.composer-rule")
        detailContainer.addSubview(rule)

        let route = NSTextField(labelWithString: composerRoute ?? "Follow-up · new version in this run")
        route.font = .systemFont(ofSize: 12)
        route.textColor = .secondaryLabelColor
        route.lineBreakMode = .byTruncatingTail
        route.frame = NSRect(x: left, y: 16, width: max(0, contentWidth - 280), height: 18)
        route.autoresizingMask = [.width, .maxYMargin]
        route.setAccessibilityIdentifier("omni.workspace.composer-route")
        route.setAccessibilityLabel(route.stringValue)
        route.toolTip = route.stringValue
        detailContainer.addSubview(route)
        composerRouteLabel = route
        let notesButton = OmniPadInlineButton(title: "0 notes")
        notesButton.setAccessibilityIdentifier("omni.workspace.notes")
        notesButton.onPress = { [weak self, weak notesButton] in
            self?.annotationUI.openOverview(anchor: notesButton)
        }
        notesButton.frame = NSRect(x: left, y: 12, width: 78, height: 24)
        notesButton.autoresizingMask = [.minXMargin, .maxYMargin]
        detailContainer.addSubview(notesButton)
        composerNotesButton = notesButton

        let apply = OmniPadRunButton()
        apply.setAccessibilityIdentifier("omni.workspace.apply")
        apply.setAccessibilityLabel("Apply")
        apply.onPress = { [weak self] in self?.submitEditor() }
        apply.frame = NSRect(x: bounds.width - 28 - 28, y: 12, width: 28, height: 28)
        apply.autoresizingMask = [.minXMargin, .maxYMargin]
        detailContainer.addSubview(apply)
        composerRunButton = apply

        let hints = OmniKeyHintsView()
        hints.setAccessibilityIdentifier("omni.workspace.composer-hints")
        hints.hints = [OmniPadKeyHint("↩", "Apply"), OmniPadKeyHint("esc", "")]
        let hintsWidth = hints.fittingWidth
        hints.frame = NSRect(x: apply.frame.minX - 12 - hintsWidth, y: 16, width: hintsWidth, height: 20)
        hints.autoresizingMask = [.minXMargin, .maxYMargin]
        detailContainer.addSubview(hints)

        let discard = actionButton(title: "Discard", identifier: "omni.workspace.discard-draft") { [weak self] in
            guard let runID, let sourceVersion else { return }
            self?.onDiscardDraft?(runID, sourceVersion)
        }
        discard.treatment = .plain
        discard.frame = NSRect(x: hints.frame.minX - 12 - 76, y: 12, width: 76, height: 28)
        discard.autoresizingMask = [.minXMargin, .maxYMargin]
        discard.isEnabled = runID != nil
        detailContainer.addSubview(discard)
        notesButton.frame.origin.x = discard.frame.minX - 8 - notesButton.frame.width
        updateComposerNotesButton()
    }

    private func layoutComposerFooter() {
        guard case .composer = detailMode, !layingOutComposerFooter,
              let route = composerRouteLabel, let notes = composerNotesButton,
              let scroll = detailContainer.subviews.first(where: { $0.accessibilityIdentifier() == "omni.workspace.composer-scroll" }),
              let rule = detailContainer.subviews.first(where: { $0.accessibilityIdentifier() == "omni.workspace.composer-rule" }),
              let hints = detailContainer.subviews.first(where: { $0.accessibilityIdentifier() == "omni.workspace.composer-hints" }),
              let discard = detailContainer.subviews.first(where: { $0.accessibilityIdentifier() == "omni.workspace.discard-draft" }),
              let apply = detailContainer.subviews.first(where: { $0.accessibilityIdentifier() == "omni.workspace.apply" }) else { return }
        layingOutComposerFooter = true
        defer { layingOutComposerFooter = false }

        let left: CGFloat = 28
        let contentWidth = max(1, detailContainer.bounds.width - left - 28)
        apply.frame.origin.x = detailContainer.bounds.width - 56
        hints.frame.origin.x = apply.frame.minX - 12 - hints.frame.width
        discard.frame.origin.x = hints.frame.minX - 12 - discard.frame.width
        notes.frame.origin.x = discard.frame.minX - 8 - notes.frame.width
        let nextControlX = notes.isHidden ? discard.frame.minX : notes.frame.minX
        let singleRowRouteWidth = max(0, nextControlX - left - 8)
        let twoRows = singleRowRouteWidth < 96
        let footerHeight: CGFloat = twoRows ? 76 : 52

        route.frame = NSRect(x: left, y: twoRows ? 50 : 16,
                             width: twoRows ? contentWidth : singleRowRouteWidth, height: 18)
        rule.frame = NSRect(x: left, y: footerHeight - 2, width: contentWidth, height: 1)
        scroll.frame = NSRect(x: left, y: footerHeight, width: contentWidth,
                              height: max(80, detailTop - 60 - footerHeight))
    }

    public func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === editor else { return }
        editor.reconcileAnnotations()
        styleComposerText()
        onComposerTextChanged?(editor.string)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        annotationUI.updateMark()
    }

    private func updateComposerNotesButton() {
        guard let button = composerNotesButton else { return }
        let count = annotations.count
        button.title = "\(count) note\(count == 1 ? "" : "s")"
        button.setAccessibilityLabel("Show \(button.title) in text order")
        button.isHidden = count == 0
        button.needsDisplay = true
        layoutComposerFooter()
    }

    private func styleComposerText() {
        guard !stylingEditor, let parser, let storage = editor.textStorage else { return }
        editor.reconcileAnnotations()
        stylingEditor = true
        defer { stylingEditor = false }
        let selected = editor.selectedRange()
        let followUp: Bool
        if case .composer(let runID, _, _) = detailMode { followUp = runID != nil }
        else { followUp = false }
        let attributed = OmniTokenRenderer.attributedText(editor.string, parser: parser, fontSize: 18, followUp: followUp)
        storage.setAttributedString(attributed)
        editor.setSelectedRange(selected)
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: OmniFrostedStyle.ink]
        annotationUI.updateMark()
    }

    private func resultTextView(text: String, identifier: String) -> NSScrollView {
        let scroll = OmniWorkspaceTextScrollView()
        if identifier == "omni.workspace.version-result" { scroll.readingMeasure = 620 }
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = OmniSelectableTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // The measured result view owns its width in OmniWorkspaceTextScrollView.layout().
        // AppKit can otherwise stretch it back to the clip width after that layout pass.
        textView.autoresizingMask = identifier == "omni.workspace.version-result" ? [] : [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: identifier.contains("input") ? 13 : 17)
        textView.textColor = OmniFrostedStyle.ink
        textView.textContainerInset = NSSize(width: 2, height: 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = identifier.contains("input") ? 3 : 5
        textView.defaultParagraphStyle = paragraph
        textView.string = text
        if text.hasPrefix("[Synthetic fixture output]") {
            textView.textStorage?.addAttributes([.font: NSFont.systemFont(ofSize: 11), .foregroundColor: OmniFrostedStyle.secondaryInk], range: NSRange(location: 0, length: "[Synthetic fixture output]".utf16.count))
        }
        textView.setAccessibilityIdentifier(identifier)
        scroll.documentView = textView
        return scroll
    }

    /// The `/find` rows as a scrolling list: title, kind · folder, and Open,
    /// Reveal and Copy path on each row.
    private func pickerList(width: CGFloat) -> NSScrollView {
        let rowHeight: CGFloat = 44
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setAccessibilityIdentifier("omni.workspace.picker")
        let document = OmniFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight * CGFloat(pickerRows.count)))
        document.autoresizingMask = [.width]
        let home = OmniLayout.homeDirectory.path
        for (index, row) in pickerRows.enumerated() {
            let y = rowHeight * CGFloat(index)
            let open = actionButton(title: row.title, identifier: "omni.workspace.picker.\(index).open") { [weak self] in
                guard let self, let runID = self.selectedRunID else { return }
                self.onPickerAction?(runID, index, .open)
            }
            open.treatment = .plain
            open.alignment = .left
            open.font = .systemFont(ofSize: 13, weight: .semibold)
            open.frame = NSRect(x: -8, y: y + 2, width: max(1, width - 190), height: 22)
            open.autoresizingMask = [.width]
            open.toolTip = row.path
            document.addSubview(open)
            let folder = (row.path as NSString).deletingLastPathComponent
            let shown = folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
            let detail = NSTextField(labelWithString: "\(row.namespace == .run ? "run folder" : row.kind) · \(shown)")
            detail.font = .systemFont(ofSize: 11.5)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            detail.frame = NSRect(x: 0, y: y + 24, width: max(1, width - 190), height: 16)
            detail.autoresizingMask = [.width]
            document.addSubview(detail)
            for (offset, action) in [(OmniPickerAction.reveal, "Reveal"), (.copyPath, "Copy path")].enumerated() {
                let button = actionButton(title: action.1, identifier: "omni.workspace.picker.\(index).\(action.0.rawValue)") { [weak self] in
                    guard let self, let runID = self.selectedRunID else { return }
                    self.onPickerAction?(runID, index, action.0)
                }
                button.frame = NSRect(x: width - 180 + CGFloat(offset) * 90, y: y + 8, width: 84, height: 26)
                button.autoresizingMask = [.minXMargin]
                document.addSubview(button)
            }
        }
        scroll.documentView = document
        return scroll
    }

    private func actionButton(title: String, identifier: String, action: @escaping () -> Void) -> OmniWorkspaceButton {
        let button = OmniWorkspaceButton(title: title, action: action)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        return button
    }

    private func materialRoot(size: NSSize) -> NSVisualEffectView {
        OmniFrostedSurface(frame: NSRect(origin: .zero, size: size), cornerRadius: 16)
    }

    private func replaceEditorTextPreservingSelection(_ text: String, preserveWhenEqual: Bool = false) {
        let oldText = editor.string
        guard oldText != text || !preserveWhenEqual else { return }
        let oldRange = editor.selectedRange()
        editor.string = text
        let location = min(oldRange.location, (text as NSString).length)
        let length = min(oldRange.length, max(0, (text as NSString).length - location))
        editor.setSelectedRange(NSRange(location: location, length: length))
    }

    private static func workspaceFrame(visibleFrame: NSRect) -> NSRect {
        let size = NSSize(width: min(1040, max(760, visibleFrame.width * 0.76)), height: min(740, max(520, visibleFrame.height * 0.8)))
        return NSRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func findView(in root: NSView, identifier: String) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let match = findView(in: child, identifier: identifier) { return match }
        }
        return nil
    }
}

@MainActor
private final class OmniWorkspaceButton: NSButton {
    enum Treatment { case plain, secondary, primary, row, icon }
    var treatment: Treatment = .secondary { didSet { needsDisplay = true } }
    var detailText = "" { didSet { needsDisplay = true } }
    var metadataText = "" { didSet { needsDisplay = true } }
    var tokenText = "" { didSet { needsDisplay = true } }
    var timeText = "" { didSet { needsDisplay = true } }
    var activity: OmniWorkspaceRowActivity = .done { didSet { needsDisplay = true } }
    var rowStep = 0 { didSet { needsDisplay = true } }
    /// A small secondary symbol after the icon (the recent-runs chevron).
    var trailingSymbolName: String? { didSet { needsDisplay = true } }
    /// A row's leading glyph (the pinned Stash row's archive box).
    var leadingSymbolName: String? { didSet { needsDisplay = true } }
    private let handler: () -> Void
    private var hovering = false
    private var hoverTracking: NSTrackingArea?

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        font = .systemFont(ofSize: 13, weight: .medium)
        isBordered = false
        target = self
        self.action = #selector(invoke)
        focusRingType = .none
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityDisplayOptionsChanged(_:)), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) { needsDisplay = true }

    override var allowsVibrancy: Bool { false }
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let selected = treatment == .row && state == .on
        let focused = window?.firstResponder === self
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: treatment == .row ? 11 : 8, yRadius: treatment == .row ? 11 : 8)
        if selected || isHighlighted {
            (highContrast ? NSColor.selectedControlColor : OmniFrostedStyle.selectedFill).setFill(); path.fill()
        } else if hovering && isEnabled {
            (highContrast ? NSColor.controlBackgroundColor : OmniFrostedStyle.hoverFill).setFill(); path.fill()
        } else if treatment == .primary || treatment == .secondary {
            (highContrast ? NSColor.controlBackgroundColor : OmniFrostedStyle.controlFill).setFill(); path.fill()
        }
        if selected || treatment == .primary || treatment == .secondary || focused {
            (highContrast ? NSColor.labelColor : focused ? OmniFrostedStyle.accent : treatment == .primary ? OmniFrostedStyle.accent.withAlphaComponent(0.45) : OmniFrostedStyle.line).setStroke()
            path.lineWidth = focused || highContrast ? 2 : 1
            path.stroke()
        }
        let systemSelection = highContrast && (selected || isHighlighted)
        let ink = (systemSelection ? NSColor.selectedControlTextColor : treatment == .primary ? OmniFrostedStyle.accent : OmniFrostedStyle.ink).withAlphaComponent(isEnabled ? 1 : 0.4)
        let secondaryInk = systemSelection ? NSColor.selectedControlTextColor : OmniFrostedStyle.secondaryInk
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        if treatment == .row {
            // NSButton draws flipped: `fromTop` measures down from the top edge.
            func rect(fromTop: CGFloat, x: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
                NSRect(x: x, y: isFlipped ? fromTop : bounds.height - fromTop - height, width: width, height: height)
            }
            var x: CGFloat = 12
            switch activity {
            case .done:
                break
            case .running:
                ink.withAlphaComponent(0.8).setFill()
                let travel = CGFloat(rowStep % 4) * 2.5
                NSBezierPath(ovalIn: rect(fromTop: 17, x: x + travel, width: 4, height: 4)).fill()
                x += 16
            case .failed:
                NSColor(srgbRed: 1, green: 0x45 / 255, blue: 0x3a / 255, alpha: 1).setFill()
                NSBezierPath(ovalIn: rect(fromTop: 16.5, x: x, width: 5, height: 5)).fill()
                x += 14
            }
            if let leadingSymbolName,
               let symbol = NSImage(systemSymbolName: leadingSymbolName, accessibilityDescription: nil)?
                   .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [secondaryInk]))) {
                symbol.draw(in: rect(fromTop: 10, x: x, width: 15, height: 15))
                x += 21
            }
            let timeFont = NSFont.systemFont(ofSize: 11)
            let timeWidth = timeText.isEmpty ? 0 : ceil((timeText as NSString).size(withAttributes: [.font: timeFont]).width)
            if timeWidth > 0 {
                drawText(timeText, rect: rect(fromTop: 11, x: bounds.width - 12 - timeWidth, width: timeWidth, height: 16), font: timeFont, color: secondaryInk, paragraph: paragraph)
            }
            if !tokenText.isEmpty {
                let tokenFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
                let size = (tokenText as NSString).size(withAttributes: [.font: tokenFont])
                let chip = rect(fromTop: 9, x: x, width: ceil(size.width) + 10, height: 19)
                (systemSelection ? NSColor.selectedControlColor : OmniFrostedStyle.accentTokenFill).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
                drawText(tokenText, rect: rect(fromTop: 10.5, x: chip.minX + 5, width: ceil(size.width) + 2, height: 16), font: tokenFont, color: systemSelection ? NSColor.selectedControlTextColor : OmniFrostedStyle.accent, paragraph: paragraph)
                x = chip.maxX + 7
            }
            let titleWidth = max(0, bounds.width - 12 - x - (timeWidth > 0 ? timeWidth + 8 : 0))
            drawText(title, rect: rect(fromTop: 9.5, x: x, width: titleWidth, height: 18), font: .systemFont(ofSize: 13, weight: .medium), color: ink, paragraph: paragraph)
            drawText(detailText, rect: rect(fromTop: 31, x: 12, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 11), color: secondaryInk, paragraph: paragraph)
        } else if treatment == .icon {
            let iconSize: CGFloat = 16
            let trailingWidth: CGFloat = trailingSymbolName == nil ? 0 : 12
            var x = (bounds.width - iconSize - trailingWidth) / 2
            if let image {
                let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
                (image.withSymbolConfiguration(configuration) ?? image).draw(in: NSRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize))
            }
            x += iconSize + 2
            if let trailingSymbolName,
               let symbol = NSImage(systemSymbolName: trailingSymbolName, accessibilityDescription: nil)?
                   .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [secondaryInk]))) {
                symbol.draw(in: NSRect(x: x, y: (bounds.height - 10) / 2, width: 10, height: 10))
            }
        } else {
            let labelFont = font ?? .systemFont(ofSize: 13)
            let titleSize = (title as NSString).size(withAttributes: [.font: labelFont])
            let iconWidth: CGFloat = image == nil ? 0 : 21
            let start = alignment == .left ? 8 : max(7, (bounds.width - min(titleSize.width, bounds.width - iconWidth - 14) - iconWidth) / 2)
            if let image {
                let tinted = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [ink])) ?? image
                tinted.draw(in: NSRect(x: start, y: (bounds.height - 15) / 2, width: 15, height: 15))
            }
            drawText(title, rect: NSRect(x: start + iconWidth, y: (bounds.height - titleSize.height) / 2, width: bounds.width - start - iconWidth - 7, height: titleSize.height), font: labelFont, color: ink, paragraph: paragraph)
        }
    }

    private func drawText(_ text: String, rect: NSRect, font: NSFont, color: NSColor, paragraph: NSParagraphStyle) {
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    @objc private func invoke() { handler() }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class OmniWorkspaceDetailView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
private final class OmniWorkspaceRule: NSView {
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) { OmniFrostedStyle.line.setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
private final class OmniWorkspaceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// ⌘Z after a stash Drop or Clear when no editor has focus (a button
    /// was the last thing clicked); editors handle their own first.
    override func keyDown(with event: NSEvent) {
        if OmniWorkspaceUndoKey.perform(event, undoManager: undoManager) { return }
        super.keyDown(with: event)
    }
}

/// `v2 /shorter` in the version strip (C35).
@MainActor public final class OmniVersionPill: NSButton {
    private let handler: () -> Void
    private let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    public var isSelected = false { didSet { needsDisplay = true } }

    public init(label: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        title = label
        isBordered = false
        target = self
        action = #selector(invoke)
        focusRingType = .none
        setButtonType(.momentaryChange)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var allowsVibrancy: Bool { false }
    @objc private func invoke() { handler() }

    public var fittingWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: labelFont]).width) + 20 }

    public override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isSelected ? OmniFrostedStyle.commandTokenFill : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)).setFill()
        path.fill()
        let size = (title as NSString).size(withAttributes: [.font: labelFont])
        let colour: NSColor = isEnabled ? (isSelected ? OmniFrostedStyle.command : .secondaryLabelColor) : .tertiaryLabelColor
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: [.font: labelFont, .foregroundColor: colour])
    }
}

@MainActor
private final class OmniWorkspaceTextScrollView: NSScrollView {
    var readingMeasure: CGFloat?

    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, let container = text.textContainer else { return }
        let width = max(1, min(contentSize.width, readingMeasure ?? .greatestFiniteMagnitude))
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        text.layoutManager?.ensureLayout(for: container)
        let used = text.layoutManager?.usedRect(for: container).height ?? 0
        let size = NSSize(width: width, height: max(contentSize.height, used + text.textContainerInset.height * 2 + 4))
        if text.frame.size != size { text.setFrameSize(size) }
    }
}

@MainActor
private final class OmniWorkspaceRunListScrollView: NSScrollView {
    var onViewportWidthChange: ((CGFloat) -> Void)?

    override func layout() {
        super.layout()
        onViewportWidthChange?(contentView.bounds.width)
    }
}

@MainActor
private final class OmniWorkspaceRunStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// A top-down document view for the workspace's scrolling lists.
@MainActor final class OmniFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A label that recomputes its text when its width changes: the header chain
/// shortens its window title or origin to fit, so a resize never cuts the
/// route (C81).
@MainActor final class OmniFittingLabel: NSTextField {
    var fit: ((CGFloat) -> NSAttributedString)?
    private var fittedWidth: CGFloat = -1

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let fit, abs(newSize.width - fittedWidth) > 0.5 else { return }
        fittedWidth = newSize.width
        attributedStringValue = fit(newSize.width)
    }
}
