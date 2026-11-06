import AppKit
import OmniCore

// `/find`'s picker result (D2, decision surface 569d5a7cf925cbd7): the rows a
// tier found, in the launcher's row idiom (kind · folder · age). It reuses
// the launcher's row view and keys, not the options model (C76), which picks
// by digit and never opens files. ↩ opens, ⌘↩ reveals, ⌥⌘C copies the path,
// esc closes. The host acts on the receipt's stored rows by index; the pad
// never hands it a path typed anywhere.

/// What a picker row is asked to do.
public enum OmniPickerAction: String, Equatable, Sendable {
    case open
    case reveal
    case copyPath
}

extension OmniCommandPadViewController {
    /// Rows drawn in the pad body; the workspace lists every row.
    static let pickerVisibleRows = 10

    /// `Find · 12 found · kind:review in:helios`; the query is the translated
    /// one for a sentence (D2: the route line shows what ran).
    static func pickerSummary(_ find: OmniFindResult) -> String {
        var parts = ["Find", find.countLabel]
        if !find.query.isEmpty { parts.append(find.query) }
        if find.rows.count > pickerVisibleRows {
            // Rows are capped (retrieve's 100); the count is not.
            parts.append(find.total > find.rows.count ? "first \(pickerVisibleRows) here, \(find.rows.count) in the workspace" : "first \(pickerVisibleRows) here, all in the workspace")
        }
        return parts.joined(separator: " · ")
    }

    /// Shows a `/find` result as rows. Bound to the run like every result.
    public func showPicker(runID: String, find: OmniFindResult) {
        switch mode {
        case .working(let boundID), .result(let boundID):
            guard boundID == runID else { return }
        case .composing, .suggesting:
            return
        }
        let value = OmniPadResult(kind: .picker, body: find.pathList, summary: Self.pickerSummary(find))
        if mode == .result(runID: runID), result == value, pickerRows == find.rows { return }
        dismissCompletion()
        clearLauncher()
        transientMessage = nil
        mode = .result(runID: runID)
        result = value
        pickerRows = find.rows
        pickerIndex = 0
        clearResultBody()
        if find.rows.isEmpty {
            configurePickerEmpty()
        } else {
            rebuildPicker()
        }
        renderFooter()
        view.window?.makeFirstResponder(submittedRequestView)
    }

    private func configurePickerEmpty() {
        let label = NSTextField(labelWithString: "Nothing in the docs index matches")
        label.font = .systemFont(ofSize: 15)
        label.textColor = OmniFrostedStyle.secondaryInk
        label.frame = NSRect(x: 18, y: 14, width: view.bounds.width - 36, height: 20)
        label.autoresizingMask = [.width]
        let container = NSView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: 48))
        container.setAccessibilityIdentifier("omni.pad.picker")
        container.addSubview(label)
        container.autoresizingMask = [.width]
        view.addSubview(container)
        pickerView = container
        bodyHeight = 48
        layoutPad(width: view.bounds.width)
    }

    func rebuildPicker() {
        pickerView?.removeFromSuperview()
        pickerRowViews = []
        let rows = Array(pickerRows.prefix(Self.pickerVisibleRows))
        let rowHeight = OmniLauncherRowView.rowHeight
        let height = rowHeight * CGFloat(rows.count) + 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: height))
        container.setAccessibilityIdentifier("omni.pad.picker")
        container.autoresizingMask = [.width]
        let now = Date()
        for (index, row) in rows.enumerated() {
            let view = OmniLauncherRowView(
                item: .row(.exact(Self.candidate(for: row))),
                home: launcherHome,
                now: now,
                showsReady: false,
                marked: false
            ) { [weak self] gesture in
                self?.pickerIndex = index
                self?.highlightPicker()
                _ = self?.performPickerAction(gesture == .commandEnterAttach ? .reveal : .open)
            }
            view.frame = NSRect(x: 12, y: height - 4 - rowHeight * CGFloat(index + 1), width: self.view.bounds.width - 24, height: rowHeight)
            view.autoresizingMask = [.width]
            view.setAccessibilityIdentifier("omni.pad.picker.\(index)")
            view.isHighlightedRow = index == pickerIndex
            container.addSubview(view)
            pickerRowViews.append(view)
        }
        view.addSubview(container)
        pickerView = container
        bodyHeight = height
        layoutPad(width: view.bounds.width)
    }

    /// The launcher's row model for a stored row: run folders draw as folders.
    static func candidate(for row: OmniFindRow) -> LauncherCandidate {
        LauncherCandidate(
            title: row.title,
            path: row.path,
            kind: row.namespace == .run ? "run-folder" : row.kind,
            source: row.namespace == .run ? .roots : .docsIndex,
            modified: row.modified,
            documentID: row.namespace == .doc ? row.id : nil
        )
    }

    @discardableResult
    func movePicker(by delta: Int) -> Bool {
        guard case .result = mode, result?.kind == .picker, !pickerRowViews.isEmpty else { return false }
        pickerIndex = max(0, min(pickerRowViews.count - 1, pickerIndex + delta))
        highlightPicker()
        renderFooter()
        return true
    }

    func highlightPicker() {
        for (index, row) in pickerRowViews.enumerated() { row.isHighlightedRow = index == pickerIndex }
    }

    /// Hands the highlighted row's index to the host. Returns false when the
    /// pad is not showing picker rows.
    @discardableResult
    func performPickerAction(_ action: OmniPickerAction) -> Bool {
        guard case .result(let runID) = mode, result?.kind == .picker, pickerRows.indices.contains(pickerIndex) else { return false }
        onPickerAction?(runID, pickerIndex, action)
        if action == .copyPath { showTransientNotice("Copied the path of \(pickerRows[pickerIndex].title)") }
        return true
    }

    /// The footer while a picker shows (rule 1: an in-body list is a commitment).
    func pickerFooterState() -> OmniPadFooterState {
        let summary = result?.summary ?? "Find"
        let line: OmniPadRouteLine = transientMessage.map { .notice($0) } ?? .outcome(summary)
        guard !pickerRows.isEmpty else {
            return OmniPadFooterState(routeLine: line, keyHints: OmniPadKeyHint.pickerEmpty, runEnabled: false, submits: true)
        }
        return OmniPadFooterState(routeLine: line, keyHints: OmniPadKeyHint.picker, runEnabled: true, submits: true)
    }
}
