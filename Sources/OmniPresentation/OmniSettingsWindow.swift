import AppKit
import OmniCore
import SwiftUI

// Settings (H20): a preference window with five toolbar tabs, each an inset
// grouped form. One row per choice, label left and control right; the only
// explanation is a group footer (C112). Nothing waits for a Save (C113).

/// `/a, /b and /c`.
func omniSettingsList(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
}

/// The in-place failure value (C113): never a dialog.
struct OmniNotSavedButton: View {
    let retry: () -> Void

    var body: some View {
        Button("Not saved · retry", action: retry)
            .buttonStyle(.link)
            .foregroundStyle(.red)
            .accessibilityIdentifier("omni.settings.not-saved")
    }
}

/// A menu popup in a labelled row, with the failure value beside it.
struct OmniSettingsPicker<Value: Hashable>: View {
    let title: String
    let selection: Binding<Value>
    let options: [(Value, String)]
    var failed = false
    var retry: () -> Void = {}

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if failed { OmniNotSavedButton(retry: retry) }
                Picker(title, selection: selection) {
                    ForEach(options, id: \.0) { value, label in Text(label).tag(value) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }
}

struct OmniGeneralPane: View {
    @Bindable var model: OmniGeneralSettings

    var body: some View {
        Form {
            Section("Startup") {
                LabeledContent("Open at login", value: model.openAtLogin)
            }
            Section("Notifications") {
                LabeledContent("Notifications") {
                    HStack(spacing: 8) {
                        Text(model.notifications)
                        if model.notificationsOff {
                            Button("Open System Settings…") { model.openNotificationSettings() }.buttonStyle(.link)
                        }
                    }
                }
            }
            Section("Appearance") {
                OmniSettingsPicker(
                    title: "Appearance",
                    selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) }),
                    options: [(.system, "Follow system"), (.light, "Light"), (.dark, "Dark")],
                    failed: model.appearanceWrite == .failed, retry: { model.setAppearance(model.appearance) }
                )
            }
        }
        .formStyle(.grouped)
    }
}

struct OmniModelRowView: View {
    let row: OmniModelRow
    let model: OmniModelSettings
    @State private var pending: OmniSettingsChoice?

    static let modelWidth: CGFloat = 196
    static let fallbackWidth: CGFloat = 150
    /// The menu popup's chevron, so values line up with popup titles.
    static let indicatorWidth: CGFloat = 26

    var body: some View {
        HStack(spacing: 10) {
            Text(row.token).fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Default: \(row.defaultDetail)")
            if row.write == .failed { OmniNotSavedButton { model.retry(row.token) } }
            Picker(row.token, selection: Binding(get: { row.model ?? "" }, set: { choose($0) })) {
                Text("Default").tag("")
                ForEach(row.models) { Text($0.label).tag($0.id) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .frame(width: Self.modelWidth, alignment: .trailing)
            .accessibilityIdentifier("omni.settings.model.\(row.token)")
            if row.model == nil {
                // A saved fallback needs a saved main: here it is a fact.
                Text("Default").foregroundStyle(.secondary)
                    .padding(.trailing, Self.indicatorWidth)
                    .frame(width: Self.fallbackWidth, alignment: .trailing)
            } else {
                Picker("\(row.token) if unavailable", selection: Binding(get: { row.fallback ?? "" }, set: { model.setFallback($0.isEmpty ? nil : $0, for: row.token) })) {
                    Text("None").tag("")
                    ForEach(row.fallbacks) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .frame(width: Self.fallbackWidth, alignment: .trailing)
                .accessibilityIdentifier("omni.settings.fallback.\(row.token)")
            }
        }
        .confirmationDialog(pending?.confirmation ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Use \(pending?.label ?? "")") {
                if let pending { model.setModel(pending.value, for: row.token) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }

    /// A billed route asks first (C113: a risky change confirms in place).
    private func choose(_ id: String) {
        let choice = row.models.first { $0.id == id }
        if let choice, choice.confirmation != nil {
            pending = choice
        } else {
            model.setModel(id.isEmpty ? nil : id, for: row.token)
        }
    }
}

struct OmniModelsPane: View {
    @Bindable var model: OmniModelSettings

    var body: some View {
        Form {
            if let notice = model.notice {
                Section {
                    LabeledContent("Models", value: notice)
                }
            } else {
                Section {
                    LabeledContent("Model", value: model.defaultModel)
                    LabeledContent("If unavailable", value: model.defaultFallback)
                } header: {
                    Text("Default")
                } footer: {
                    Text("Used by every model-backed command unless overridden below." + (model.defaultExceptions.map { " \($0)" } ?? ""))
                }
                Section {
                    HStack(spacing: 10) {
                        Spacer()
                        Text("Model").padding(.trailing, OmniModelRowView.indicatorWidth)
                            .frame(width: OmniModelRowView.modelWidth, alignment: .trailing)
                        Text("If unavailable").padding(.trailing, OmniModelRowView.indicatorWidth)
                            .frame(width: OmniModelRowView.fallbackWidth, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(model.rows) { OmniModelRowView(row: $0, model: model) }
                } header: {
                    Text("Per command")
                } footer: {
                    if !model.deterministicTokens.isEmpty {
                        Text("\(omniSettingsList(model.deterministicTokens)) are deterministic and use no model.")
                    }
                }
                Section {
                    OmniSettingsPicker(
                        title: "Quick answer, Translate, Recall and Emoji",
                        selection: Binding(get: { model.ephemeralModel ?? "" }, set: { model.setEphemeralModel($0.isEmpty ? nil : $0) }),
                        options: [("", "Default")] + model.ephemeralChoices.map { ($0.id, $0.label) },
                        failed: model.ephemeralWrite == .failed, retry: { model.setEphemeralModel(model.ephemeralModel) }
                    )
                } header: {
                    Text("Ephemeral tools")
                } footer: {
                    Text("Connected language tools use their selected provider. Clipboard, Stash and Collect work locally. What you copy stays on this Mac.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct OmniClipboardPane: View {
    @Bindable var model: OmniClipboardSettings
    @State private var confirmHistory = false
    @State private var confirmCollected = false

    var body: some View {
        Form {
            Section {
                if let notice = model.historyNotice {
                    LabeledContent("Clipboard history", value: notice)
                } else {
                    LabeledContent("Capture copied items") {
                        HStack(spacing: 8) {
                            if model.failed.contains(.capture) { OmniNotSavedButton { model.setCapture(model.capture) } }
                            Toggle("Capture copied items", isOn: Binding(get: { model.capture }, set: { model.setCapture($0) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    OmniSettingsPicker(
                        title: "Keep for",
                        selection: Binding(get: { model.keepForHours }, set: { model.setKeepFor($0) }),
                        options: model.keepChoices.map { ($0, OmniClipboardSettings.keepLabel($0)) },
                        failed: model.failed.contains(.keepFor), retry: { model.setKeepFor(model.keepForHours) }
                    )
                    LabeledContent("Items kept") {
                        HStack(spacing: 8) {
                            if model.failed.contains(.clearHistory) { OmniNotSavedButton { model.clearHistory() } }
                            Text(model.itemsKept).accessibilityIdentifier("omni.settings.items-kept")
                            Button("Clear history…", role: .destructive) { confirmHistory = true }
                                .foregroundStyle(.red)
                                .disabled(model.itemCount == 0)
                        }
                    }
                    .confirmationDialog("Clear clipboard history?", isPresented: $confirmHistory) {
                        Button("Clear History", role: .destructive) { model.clearHistory() }
                    } message: {
                        Text("Every saved item is removed from this Mac. This cannot be undone.")
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("History is kept on this Mac only and never sent anywhere. Items from password managers and other concealed sources are never captured.")
            }
            Section {
                LabeledContent("Stash depth", value: "\(model.stashDepth)")
                LabeledContent("Collected items") {
                    HStack(spacing: 8) {
                        if model.failed.contains(.clearCollected) { OmniNotSavedButton { model.clearCollected() } }
                        Text(model.collectedCount.map(String.init) ?? "Collect runs in the installed host")
                        if let count = model.collectedCount {
                            Button("Clear", role: .destructive) { confirmCollected = true }
                                .foregroundStyle(.red)
                                .disabled(count == 0)
                        }
                    }
                }
                .confirmationDialog("Clear collected items?", isPresented: $confirmCollected) {
                    Button("Clear", role: .destructive) { model.clearCollected() }
                } message: {
                    Text("Items waiting for Hyper V are removed. This cannot be undone.")
                }
            } header: {
                Text("Stash and Collect")
            } footer: {
                Text("Stash keeps \(model.stashDepth) entries; the next one pushes the oldest out. Collected items persist until pasted or cleared.")
            }
            Section {
                OmniSettingsPicker(
                    title: "Paste from history and Stash",
                    selection: Binding(get: { model.pasteMode }, set: { model.setPasteMode($0) }),
                    options: [(.asCopied, "As copied"), (.plainText, "Plain text")],
                    failed: model.failed.contains(.pasteMode), retry: { model.setPasteMode(model.pasteMode) }
                )
                OmniSettingsPicker(
                    title: "Batch separator",
                    selection: Binding(get: { model.batchSeparator }, set: { model.setBatchSeparator($0) }),
                    options: [(.newLine, "New line"), (.blankLine, "Blank line")],
                    failed: model.failed.contains(.batchSeparator), retry: { model.setBatchSeparator(model.batchSeparator) }
                )
            } header: {
                Text("Paste")
            } footer: {
                Text("⇧↩ pastes plain text regardless of this setting.")
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }
}

struct OmniToolsPane: View {
    @Bindable var model: OmniToolSettings

    var body: some View {
        Form {
            Section("Emoji") {
                OmniSettingsPicker(
                    title: "Skin tone",
                    selection: Binding(get: { model.skinTone }, set: { model.setSkinTone($0) }),
                    options: OmniSkinTone.allCases.map { tone in
                        (tone, tone.apply(to: "\u{270B}") + "  " + Self.label(tone))
                    },
                    failed: model.skinToneWrite == .failed, retry: { model.setSkinTone(model.skinTone) }
                )
            }
            Section("Recall") {
                LabeledContent("Command sheet") {
                    HStack(spacing: 8) {
                        if model.recallWrite == .failed { OmniNotSavedButton { model.chooseRecallSheet() } }
                        Text(Self.abbreviated(model.recallSheetPath))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: Self.pathWidth, alignment: .trailing)
                            .help(model.recallSheetPath)
                        Button("Choose…") { model.chooseRecallSheet() }
                    }
                }
            }
            Section {
                OmniSettingsPicker(
                    title: "Units",
                    selection: Binding(get: { model.weatherUnits }, set: { model.setWeatherUnits($0) }),
                    options: [(.followSystem, "Follow system"), (.metric, "Metric"), (.imperial, "Imperial")],
                    failed: model.weatherUnitsWrite == .failed, retry: { model.setWeatherUnits(model.weatherUnits) }
                )
            } header: {
                Text("Weather")
            } footer: {
                Text("Location is used only while Weather is open. Coordinates are not stored; the last reading is cached by place name.")
            }
            Section {
                LabeledContent("Forvo key", value: model.forvoKey)
                LabeledContent("Merriam-Webster key", value: model.merriamWebsterKey)
                LabeledContent("Config file") {
                    HStack(spacing: 8) {
                        Text(Self.abbreviated(model.pronConfigPath)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: Self.pathWidth, alignment: .trailing)
                            .help(model.pronConfigPath)
                        Button("Open…") { model.openPronConfig() }
                    }
                }
            } header: {
                Text("Pronounce")
            } footer: {
                Text("Pronunciation source keys are configured separately. Glacier shows only whether each one is set.")
            }
        }
        .formStyle(.grouped)
    }

    /// Long paths truncate in the middle rather than wrap the row.
    static let pathWidth: CGFloat = 320

    static func label(_ tone: OmniSkinTone) -> String {
        switch tone {
        case .none: "Default"
        case .light: "Light"
        case .mediumLight: "Medium light"
        case .medium: "Medium"
        case .mediumDark: "Medium dark"
        case .dark: "Dark"
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The overlay's own AppKit view, drawn at its natural size and scaled to fit.
struct OmniOverlayPicture: NSViewRepresentable {
    let make: () -> NSView
    let width: CGFloat

    /// The scaled size for a view of `natural` size.
    static func size(natural: NSSize, width: CGFloat) -> NSSize {
        let scale = natural.width > 0 ? min(1, width / natural.width) : 1
        return NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    func makeNSView(context: Context) -> NSView {
        let overlay = make()
        let natural = overlay.frame.size
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size(natural: natural, width: width)))
        container.addSubview(overlay)
        container.setBoundsSize(natural)
        overlay.frame = NSRect(origin: .zero, size: natural)
        container.setAccessibilityIdentifier("omni.settings.overlay")
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { nsView.frame.size }
}

struct OmniShortcutsPane: View {
    @Bindable var model: OmniShortcutSettings

    var body: some View {
        Form {
            if let make = model.makeOverlayView {
                let size = OmniOverlayPicture.size(natural: model.overlaySize, width: OmniSettingsWindow.width - 80)
                Section {
                    OmniOverlayPicture(make: make, width: OmniSettingsWindow.width - 80)
                        .frame(width: size.width, height: size.height)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                }
            }
            Section {
                LabeledContent("Manifest") {
                    HStack(spacing: 8) {
                        Text(model.manifestPath.map(OmniToolsPane.abbreviated) ?? "Not available in this build")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: OmniToolsPane.pathWidth, alignment: .trailing)
                        if model.manifestPath != nil { Button("Edit…") { model.edit() } }
                    }
                }
            } footer: {
                Text("Open keyboard help from Glacier Settings to see active shortcuts.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Selection reports, so the window can remember the last pane.
@MainActor final class OmniSettingsTabs: NSTabViewController {
    var onSelect: ((Int) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?(selectedTabViewItemIndex)
    }
}

/// Fixed at 640 pt wide; each pane's form sets the height. The title follows
/// the pane. Standard window material, following the appearance.
@MainActor
public final class OmniSettingsWindow: NSWindow {
    public static let width: CGFloat = 640
    public let model: OmniSettingsModel
    public var onPaneChange: ((OmniSettingsPane) -> Void)?
    private let tabs = OmniSettingsTabs()

    /// `maximumPaneHeight` caps a pane taller than the screen allows; that
    /// pane scrolls, the others keep their own height.
    public init(model: OmniSettingsModel, pane: OmniSettingsPane, maximumPaneHeight: CGFloat = .greatestFiniteMagnitude) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        toolbarStyle = .preference
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for pane in OmniSettingsPane.allCases {
            let item = NSTabViewItem(viewController: Self.controller(for: pane, model: model, maximumHeight: maximumPaneHeight))
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
            item.identifier = pane.rawValue
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = OmniSettingsPane.allCases.firstIndex(of: pane) ?? 0
        contentViewController = tabs
        title = pane.title
        tabs.onSelect = { [weak self] index in
            guard let self, OmniSettingsPane.allCases.indices.contains(index) else { return }
            let selected = OmniSettingsPane.allCases[index]
            self.title = selected.title
            self.onPaneChange?(selected)
        }
        setAccessibilityIdentifier("omni.settings")
    }

    public var pane: OmniSettingsPane {
        let index = tabs.selectedTabViewItemIndex
        return OmniSettingsPane.allCases.indices.contains(index) ? OmniSettingsPane.allCases[index] : .general
    }

    public func select(_ pane: OmniSettingsPane) {
        guard let index = OmniSettingsPane.allCases.firstIndex(of: pane) else { return }
        tabs.selectedTabViewItemIndex = index
        title = pane.title
    }

    /// A pane's hosting controller, for layout checks.
    public func paneController(_ pane: OmniSettingsPane) -> NSViewController? {
        tabs.tabViewItems.first { $0.identifier as? String == pane.rawValue }?.viewController
    }

    private static func controller(for pane: OmniSettingsPane, model: OmniSettingsModel, maximumHeight: CGFloat) -> NSViewController {
        let root: AnyView = switch pane {
        case .general: AnyView(OmniGeneralPane(model: model.general))
        case .models: AnyView(OmniModelsPane(model: model.models))
        case .clipboard: AnyView(OmniClipboardPane(model: model.clipboard))
        case .tools: AnyView(OmniToolsPane(model: model.tools))
        case .shortcuts: AnyView(OmniShortcutsPane(model: model.shortcuts))
        }
        let fitted = NSHostingController(rootView: AnyView(root.scrollDisabled(true).frame(width: width).fixedSize(horizontal: false, vertical: true)))
        fitted.sizingOptions = [.preferredContentSize]
        fitted.title = pane.title
        guard fitted.view.fittingSize.height > maximumHeight else { return fitted }
        let capped = NSHostingController(rootView: AnyView(root.frame(width: width, height: maximumHeight)))
        capped.sizingOptions = [.preferredContentSize]
        capped.title = pane.title
        return capped
    }
}
