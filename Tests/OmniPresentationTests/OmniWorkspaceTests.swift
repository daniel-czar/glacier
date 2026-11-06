import AppKit
import OmniPresentation
import Testing

@MainActor
private func workspaceButton(in view: NSView, identifier: String) -> NSButton? {
    if view.accessibilityIdentifier() == identifier { return view as? NSButton }
    for child in view.subviews {
        if let result = workspaceButton(in: child, identifier: identifier) { return result }
    }
    return nil
}

@MainActor
private func workspaceView(in view: NSView, identifier: String) -> NSView? {
    if view.accessibilityIdentifier() == identifier { return view }
    for child in view.subviews {
        if let result = workspaceView(in: child, identifier: identifier) { return result }
    }
    return nil
}

@Test @MainActor func workspaceKeepsItsStandardWindowAfterLauncherRetirement() throws {
    _ = NSApplication.shared
    let visible = NSRect(x: 100, y: 80, width: 1200, height: 800)
    let workspace = OmniWorkspace(visibleFrame: visible)
    #expect(workspace.workspacePanel.canBecomeKey)
    #expect(workspace.workspacePanel.styleMask.contains(.titled))
    #expect(workspace.workspacePanel.styleMask.contains(.resizable))
    #expect(!workspace.workspacePanel.styleMask.contains(.utilityWindow))
    #expect(workspace.workspacePanel.title == "Glacier")
    #expect(workspaceView(in: try #require(workspace.workspacePanel.contentView), identifier: "omni.workspace.sidebar") is NSVisualEffectView)
    #expect(workspace.workspacePanel.accessibilityIdentifier() == "omni.workspace.panel")
    #expect(workspace.workspacePanel.collectionBehavior.contains(.moveToActiveSpace))
    #expect(workspace.workspacePanel.frame.minY >= visible.minY)
    #expect(workspace.workspacePanel.frame.maxY <= visible.maxY)
    var opened = 0
    workspace.onOpenWorkspace = { opened += 1 }
    workspace.openWorkspace()
    #expect(opened == 1)
}

@Test func rowTimeAndDayLabelsFollowTheCalendar() {
    let calendar = Calendar.autoupdatingCurrent
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 15, minute: 5))!
    let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 14, minute: 42))!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let lastWednesday = calendar.date(byAdding: .day, value: -2, to: today)!
    let lastMonth = calendar.date(byAdding: .day, value: -30, to: today)!
    #expect(OmniWorkspace.dayLabel(for: today, now: now) == "Today")
    #expect(OmniWorkspace.dayLabel(for: yesterday, now: now) == "Yesterday")
    #expect(OmniWorkspace.dayLabel(for: lastWednesday, now: now).count > 3)
    #expect(OmniWorkspace.dayLabel(for: lastMonth, now: now).contains("2026"))
    #expect(OmniWorkspace.dayLabel(for: nil, now: now) == "Earlier")
    #expect(OmniWorkspace.timeLabel(for: today, now: now).contains("42"))
    #expect(!OmniWorkspace.timeLabel(for: yesterday, now: now).contains(":"))
    #expect(OmniWorkspace.timeLabel(for: nil, now: now) == "")
}

@Test @MainActor func calendarDayNotificationFromBackgroundDoesNotCrashWorkspace() async {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    workspace.displayRuns([OmniWorkspaceRunRow(id: "run-1", title: "Run", status: "done", summary: "Result")], selectedID: nil)

    let postedOnMainThread = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let onMainThread = Thread.isMainThread
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            continuation.resume(returning: onMainThread)
        }
    }
    #expect(!postedOnMainThread)
    #expect(workspace.displayedRuns.count == 1)
}

@Test @MainActor func rowsVersionsAndActionsCarryStableIdentifiersAndCallbacks() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    let run = OmniWorkspaceRunRow(id: "run-1", title: "Draft note", status: "ready", summary: "A concise result")
    let older = OmniWorkspaceVersion(number: 1, inputText: "/email first", resultText: "First output", operation: "initial")
    let newer = OmniWorkspaceVersion(number: 2, inputText: "/shorter", resultText: "Second output", operation: "continue", sourceVersion: 1)
    workspace.displayRuns([run], selectedID: run.id)
    workspace.displayResult(runID: run.id, title: run.title, status: run.status, versions: [older, newer], selectedVersion: 2)
    workspace.workspacePanel.contentView?.layoutSubtreeIfNeeded()

    var selectedRun: String?
    var selectedVersion: Int?
    var continued: (String, Int)?
    var copied: (String, Int)?
    workspace.onSelectRun = { selectedRun = $0 }
    workspace.onSelectVersion = { selectedVersion = $0 }
    workspace.onContinue = { continued = ($0, $1) }
    workspace.onCopy = { copied = ($0, $1) }

    let content = try #require(workspace.workspacePanel.contentView)
    // The result text keeps ⌘A/⌘C in the resident host, which has no Edit menu.
    #expect(workspaceView(in: content, identifier: "omni.workspace.version-result") is OmniSelectableTextView)
    try #require(workspaceButton(in: content, identifier: "omni.workspace.run.run-1")).performClick(nil)
    #expect(selectedRun == run.id)
    // The version strip (C35): pills naming each operation, latest selected.
    let latestPill = try #require(workspaceButton(in: content, identifier: "omni.workspace.version.2") as? OmniVersionPill)
    let olderPill = try #require(workspaceButton(in: content, identifier: "omni.workspace.version.1") as? OmniVersionPill)
    #expect(latestPill.isSelected)
    #expect(!olderPill.isSelected)
    #expect(latestPill.title == "v2 continue")
    #expect(olderPill.title == "v1 initial")
    olderPill.performClick(nil)
    #expect(selectedVersion == older.number)
    try #require(workspaceButton(in: content, identifier: "omni.workspace.continue")).performClick(nil)
    workspace.copySelectedResult()
    #expect(continued?.0 == run.id)
    #expect(continued?.1 == older.number)
    #expect(copied?.0 == run.id)
    #expect(copied?.1 == older.number)
    // The toolbar carries Copy and New (C33).
    let toolbarItems = workspace.workspacePanel.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
    #expect(toolbarItems.contains("omni.workspace.toolbar.copy"))
    #expect(toolbarItems.contains("omni.workspace.toolbar.new"))
    // The input sits behind a disclosure once there is a result.
    #expect(workspaceView(in: content, identifier: "omni.workspace.version-input") == nil)
    try #require(workspaceButton(in: content, identifier: "omni.workspace.input-disclosure")).performClick(nil)
    let disclosedInput = try #require(workspaceView(in: content, identifier: "omni.workspace.version-input") as? NSTextView)
    #expect(disclosedInput.string == older.inputText)

    var cancelled: String?
    workspace.onCancel = { cancelled = $0 }
    workspace.displayResult(runID: run.id, title: run.title, status: "running", versions: [], selectedVersion: 0, pendingText: "/shorter please")
    #expect(workspaceButton(in: content, identifier: "omni.workspace.version.2") == nil)
    let pendingContinue = try #require(workspaceButton(in: content, identifier: "omni.workspace.continue"))
    let pendingInput = try #require(workspaceView(in: content, identifier: "omni.workspace.version-input") as? NSTextView)
    #expect(!pendingContinue.isEnabled)
    #expect(pendingInput.string == "/shorter please")
    try #require(workspaceButton(in: content, identifier: "omni.workspace.cancel-pending")).performClick(nil)
    #expect(cancelled == run.id)

    workspace.displayResult(runID: run.id, title: run.title, status: "running", versions: [], selectedVersion: 0, submittedInput: "/email awaiting result", canCancel: true)
    let initialCancel = try #require(workspaceButton(in: content, identifier: "omni.workspace.cancel-pending"))
    #expect(!initialCancel.isHidden)
    let initialInput = try #require(workspaceView(in: content, identifier: "omni.workspace.version-input") as? NSTextView)
    #expect(initialInput.string == "/email awaiting result")
}

@Test @MainActor func composerPreservesCaretAcrossListRefreshAndExplicitResultExitsComposer() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    workspace.showComposer(text: "Please make this direct", runID: "run-1", sourceVersion: 2)
    workspace.editor.setSelectedRange(NSRange(location: 7, length: 0))
    workspace.displayRuns([OmniWorkspaceRunRow(id: "run-1", title: "Draft", status: "running", summary: "Waiting")], selectedID: "run-1")
    #expect(workspace.editor.string == "Please make this direct")
    #expect(workspace.editor.selectedRange() == NSRange(location: 7, length: 0))
    workspace.displayResult(
        runID: "run-1",
        title: "Draft",
        status: "running",
        versions: [OmniWorkspaceVersion(number: 2, inputText: "old", resultText: "old result", operation: "initial")],
        selectedVersion: 2
    )
    let resultContent = try #require(workspace.workspacePanel.contentView)
    #expect(workspaceView(in: resultContent, identifier: "omni.workspace.editor") == nil)

    workspace.showComposer(text: "Please make this direct", runID: "run-1", sourceVersion: 2)
    workspace.editor.setSelectedRange(NSRange(location: 7, length: 0))
    workspace.insertShorterHelper()
    #expect(workspace.editor.string == "Please /shorter make this direct")
    #expect(workspace.editor.accessibilityIdentifier() == "omni.workspace.editor")

    var submission: (String, OmniSubmitGesture)?
    var discarded: (String, Int)?
    workspace.onSubmit = { submission = ($0, $1) }
    workspace.onDiscardDraft = { discarded = ($0, $1) }
    let content = try #require(workspace.workspacePanel.contentView)
    try #require(workspaceButton(in: content, identifier: "omni.workspace.apply")).performClick(nil)
    try #require(workspaceButton(in: content, identifier: "omni.workspace.discard-draft")).performClick(nil)
    #expect(submission?.0 == workspace.editor.string)
    #expect(submission?.1 == .commandEnterAttach)
    #expect(discarded?.0 == "run-1")
    #expect(discarded?.1 == 2)

    var closes = 0
    workspace.onClose = { closes += 1 }
    workspace.editor.onEscape?()
    #expect(closes == 1)
}

@Test @MainActor func workspaceSidebarKeepsAllRunsAfterLauncherRetirement() throws {
    _ = NSApplication.shared
    let workspace = OmniWorkspace(visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    var rows: [OmniWorkspaceRunRow] = []
    for index in 1...7 {
        let activity: OmniWorkspaceRowActivity = index == 2 ? .running : (index == 3 ? .failed : .done)
        let status = index == 2 ? "running" : "done"
        let submitted = Date(timeIntervalSinceNow: -Double(index) * 60)
        rows.append(OmniWorkspaceRunRow(id: "run-\(index)", title: "Run \(index)", status: status, summary: "Result \(index)", token: "/qq", submittedAt: submitted, activity: activity))
    }
    workspace.displayRuns(rows, selectedID: nil)
    var workspaceOpens = 0
    workspace.onOpenWorkspace = { workspaceOpens += 1 }

    workspace.openWorkspace()
    #expect(workspaceOpens == 1)

    // The sidebar shows every run, grouped by day, with the same row identifiers.
    let content = try #require(workspace.workspacePanel.contentView)
    #expect(workspaceButton(in: content, identifier: "omni.workspace.run.run-7") != nil)
    #expect(workspaceView(in: content, identifier: "omni.workspace.run-group") != nil)
}
