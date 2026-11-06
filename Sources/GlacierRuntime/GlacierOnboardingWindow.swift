import AppKit
import GlacierConfiguration
import GlacierConnections
import GlacierPlatform
import SwiftUI

/// A normal app window. The model owns setup state and all effects; this controller only presents it.
@MainActor
public final class GlacierOnboardingWindowController: NSWindowController, NSWindowDelegate {
    public let model: GlacierOnboardingModel
    public var onFinish: (() -> Void)?

    public init(model: GlacierOnboardingModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glacier — Getting started"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        window.contentMinSize = NSSize(width: 760, height: 680)
        window.contentMaxSize = NSSize(width: 760, height: 680)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: GlacierOnboardingView(model: model) { [weak self] in
            self?.window?.close()
            self?.onFinish?()
        })
    }

    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.open() }
    }

    public func windowWillClose(_ notification: Notification) { model.close() }
}

private struct GlacierOnboardingColors {
    let background: Color
    let raised: Color
    let deep: Color
    let line: Color
    let ink: Color
    let muted: Color
    let faint: Color
    let accent: Color
    let accentInk: Color
    let soft: Color
    let success: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            background = Color(red: 0.087, green: 0.109, blue: 0.126)
            raised = Color(red: 0.135, green: 0.163, blue: 0.185)
            deep = Color(red: 0.071, green: 0.090, blue: 0.106)
            line = Color(red: 0.210, green: 0.251, blue: 0.280)
            ink = Color(red: 0.93, green: 0.95, blue: 0.96)
            muted = Color(red: 0.65, green: 0.71, blue: 0.75)
            faint = Color(red: 0.54, green: 0.61, blue: 0.66)
            accent = Color(red: 0.75, green: 0.85, blue: 0.91)
            accentInk = Color(red: 0.08, green: 0.15, blue: 0.20)
            soft = Color(red: 0.145, green: 0.23, blue: 0.29)
            success = Color(red: 0.65, green: 0.81, blue: 0.72)
        } else {
            background = Color(red: 0.969, green: 0.973, blue: 0.973)
            raised = .white
            deep = Color(red: 0.933, green: 0.945, blue: 0.949)
            line = Color(red: 0.86, green: 0.88, blue: 0.89)
            ink = Color(red: 0.09, green: 0.15, blue: 0.18)
            muted = Color(red: 0.34, green: 0.39, blue: 0.43)
            faint = Color(red: 0.42, green: 0.47, blue: 0.51)
            accent = Color(red: 0.15, green: 0.36, blue: 0.47)
            accentInk = .white
            soft = Color(red: 0.886, green: 0.929, blue: 0.949)
            success = Color(red: 0.17, green: 0.42, blue: 0.33)
        }
    }
}

/// The same Glacier artwork used by the public site, packaged with this runtime target.
private struct GlacierOnboardingBrandIcon: View {
    let size: CGFloat

    private static let image: NSImage = {
        guard let url = Bundle.module.url(forResource: "GlacierThemeIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            fatalError("The bundled Glacier onboarding icon is missing")
        }
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            // The approved asset carries its own centered tile and clean alpha.
            .accessibilityHidden(true)
    }
}

/// The view is also usable in an isolated hosting view for native previews and capture tests.
@MainActor
public struct GlacierOnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var focusedControl: FocusControl?
    @State private var selectedDemo: GlacierOnboardingDemo = .date
    @State private var displayedDemo: GlacierOnboardingDemo?
    @State private var showsAccessibilityHelp = false
    public let model: GlacierOnboardingModel
    public let onFinish: (() -> Void)?

    private enum FocusControl: Hashable { case apiKey, example }
    private var colors: GlacierOnboardingColors { .init(colorScheme) }
    private var stepIndex: Int { GlacierOnboardingStep.allCases.firstIndex(of: model.step) ?? 0 }
    private var skipLabel: String? {
        switch model.step {
        case .welcome: "Try Glacier first"
        case .shortcut: model.snapshot.shortcut == nil ? "Use menu bar" : "Keep existing shortcut"
        case .selectedText: "Not now"
        case .intelligence: "Set up later"
        case .yourMac, .ready: nil
        }
    }

    public init(model: GlacierOnboardingModel, onFinish: (() -> Void)? = nil) {
        self.model = model
        self.onFinish = onFinish
    }

    /// Called only by the Ready primary action. Loading an already completed state must not launch Glacier.
    func finishAndOpen() async {
        guard model.isOpen, model.step == .ready else { return }
        await model.finish()
        if model.completed && model.errorMessage == nil && model.isOpen { onFinish?() }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GlacierOnboardingBrandIcon(size: 18)
                Text("Glacier")
                    .foregroundStyle(colors.ink)
                    .fontWeight(.semibold)
                Text("/")
                    .foregroundStyle(colors.faint)
                Text("Getting started")
                    .foregroundStyle(colors.muted)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .overlay(alignment: .bottom) { colors.line.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        switch model.step {
                        case .welcome: welcome
                        case .shortcut: shortcut
                        case .selectedText: selectedText
                        case .intelligence: intelligence
                        case .yourMac: yourMac
                        case .ready: ready
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 676)
                .frame(maxWidth: .infinity, minHeight: 523, alignment: .center)
                .padding(.horizontal, 42)
                .padding(.vertical, 24)
            }
            .scrollIndicators(.hidden)
            .frame(height: 571)
            .id(model.step)

            footer
        }
        .frame(width: 760, height: 680)
        .background(colors.background)
        .onChange(of: model.step) { _, _ in
            showsAccessibilityHelp = false
            headingFocused = false
            Task { @MainActor in headingFocused = true }
        }
        .sheet(isPresented: $showsAccessibilityHelp) { accessibilitySheet }
        .accessibilityIdentifier("glacier.onboarding.window")
    }

    private func heading(_ eyebrow: String, _ title: String, _ lede: String, centered: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            Text(eyebrow)
                .font(.system(size: 10, weight: .bold))
                .tracking(2.1)
                .foregroundStyle(colors.accent)
            Text(title)
                .font(.system(size: centered && model.step == .welcome ? 42 : 34, weight: .semibold))
                .tracking(-1.1)
                .lineSpacing(-2)
                .foregroundStyle(colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(lede)
                .font(.system(size: 14))
                .lineSpacing(5)
                .foregroundStyle(colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .multilineTextAlignment(centered ? .center : .leading)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            GlacierOnboardingBrandIcon(size: 66)
                .padding(.bottom, 20)
                .accessibilityHidden(true)
            heading("A LITTLE LESS FRICTION", "Glacier", "Open apps. Work with text.\nGet the little things done, without breaking your flow.", centered: true)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(colors.muted)
                    (Text("/span").foregroundColor(colors.accent).bold() + Text(" 3 weeks after 2 November 2026"))
                        .foregroundStyle(colors.ink)
                    Spacer()
                }
                .padding(18)
                HStack(spacing: 12) {
                    iconTile("calendar")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("23 November 2026").font(.system(size: 16, weight: .semibold)).foregroundStyle(colors.ink)
                        Text("Monday · 21 days later").font(.system(size: 11)).foregroundStyle(colors.muted)
                    }
                    Spacer()
                    Text("On this Mac  ✓").font(.system(size: 10)).foregroundStyle(colors.faint)
                }
                .padding(17)
                .frame(maxWidth: .infinity)
                .background(colors.soft.opacity(0.35))
            }
            .background(colors.raised, in: RoundedRectangle(cornerRadius: 15))
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(colors.line))
            .frame(maxWidth: 520)
            .padding(.top, 31)
            HStack(spacing: 24) {
                benefit("command", "A shortcut away")
                benefit("laptopcomputer", "Useful without AI")
                benefit("chevron.left.forwardslash.chevron.right", "Free & open source")
            }
            .padding(.top, 26)
            Text("A few choices to make it yours. Everything can change later.")
                .font(.system(size: 11))
                .foregroundStyle(colors.faint)
                .padding(.top, 23)
        }
        .frame(maxWidth: .infinity)
    }

    private var shortcut: some View {
        VStack(spacing: 0) {
            heading("YOUR WAY IN", "One shortcut.\nWherever you are.", "Choose the keys that bring Glacier to the front.", centered: true)
            HStack(spacing: 9) {
                if case .menuBarOnly = model.shortcutChoice {
                    keycap("Using the menu bar", width: 250)
                } else {
                    keycap(shortcutModifierLabel, width: 80)
                    keycap(shortcutKeyLabel, width: 168)
                }
            }
            .frame(height: 80)
            .padding(.top, 27)
            HStack(spacing: 8) {
                secondaryButton("Option + Space", selected: isOptionSpace) {
                    model.shortcutChoice = .optionSpace
                }
                .disabled(model.snapshot.isPreview)
                GlacierOnboardingShortcutRecorder(chord: model.shortcutChoice.chord) { chord in
                    model.shortcutChoice = .custom(chord)
                }
                .frame(width: 155, height: 36)
                .disabled(model.snapshot.isPreview)
                Button("I use Hyper") {
                    if let chord = try? GlacierShortcutChord(keyCode: 49, modifiers: [.control, .option, .shift, .command]) {
                        model.shortcutChoice = .hyper(chord)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(colors.muted)
                .accessibilityHint("Choose Control, Option, Shift, Command and Space")
                .disabled(model.snapshot.isPreview)
            }
            .padding(.top, 9)
            Text("Pick something comfortable. The shortcut is checked for conflicts before it is turned on.")
                .font(.system(size: 12))
                .foregroundStyle(colors.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 410)
                .padding(.top, 23)
            Text(model.snapshot.isPreview ? "Preview mode uses the menu bar; global shortcuts stay off." : shortcutStatus)
                .font(.system(size: 11))
                .foregroundStyle(colors.faint)
                .padding(.top, 18)
                .accessibilityIdentifier("glacier.onboarding.shortcut.status")
        }
        .frame(maxWidth: .infinity)
    }

    private var isOptionSpace: Bool {
        if case .optionSpace = model.shortcutChoice { return true }
        return false
    }

    private var shortcutModifierLabel: String {
        switch model.shortcutChoice {
        case .menuBarOnly: ""
        case .optionSpace: "⌥"
        case .hyper: "⌃ ⌥ ⇧ ⌘"
        case .custom(let chord): chord.modifiers.map { modifier in
            switch modifier { case .command: "⌘"; case .option: "⌥"; case .control: "⌃"; case .shift: "⇧" }
        }.joined(separator: " ")
        }
    }

    private var shortcutKeyLabel: String {
        switch model.shortcutChoice {
        case .menuBarOnly: ""
        case .optionSpace, .hyper: "Space"
        case .custom(let chord): chord.keyCode == 49 ? "Space" : CurrentKeyboardShortcutLabels().keyLabel(for: chord.keyCode)
        }
    }

    private var shortcutStatus: String {
        if case .menuBarOnly = model.shortcutChoice { return "You can open Glacier from the menu bar." }
        return "You can also open Glacier from the menu bar."
    }

    private var selectedText: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("TEXT, IN CONTEXT", "Start with the text\nyou already selected.", "Let Glacier pick up a selection and insert the result back into your app.")
            HStack(alignment: .center, spacing: 17) {
                VStack(alignment: .leading, spacing: 13) {
                    smallLabel("IN YOUR DOCUMENT")
                    (Text("Let’s meet ") + Text("3 weeks after 2 November").foregroundColor(colors.accent) + Text("."))
                        .font(.system(size: 13)).foregroundStyle(colors.muted)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(colors.muted)
                Spacer()
                VStack(alignment: .leading, spacing: 13) {
                    smallLabel("WITH GLACIER")
                    (Text("Let’s meet ") + Text("23 November").foregroundColor(colors.accent) + Text("."))
                        .font(.system(size: 13)).foregroundStyle(colors.muted)
                }
            }
            .padding(.vertical, 23)
            .overlay(alignment: .top) { colors.line.frame(height: 1) }
            .overlay(alignment: .bottom) { colors.line.frame(height: 1) }
            .padding(.top, 30)

            HStack(spacing: 14) {
                iconTile("cursorarrow")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility").font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.ink)
                    Text("Read selected text and insert results.").font(.system(size: 11)).foregroundStyle(colors.muted)
                }
                Spacer()
                if model.snapshot.accessibilityTrusted {
                    Label("Enabled", systemImage: "checkmark").foregroundStyle(colors.success).font(.system(size: 11))
                } else {
                    secondaryButton("Enable access ↗") { showsAccessibilityHelp = true }
                        .disabled(model.snapshot.isPreview)
                }
            }
            .padding(.vertical, 20)
            .overlay(alignment: .bottom) { colors.line.frame(height: 1) }
            note("info.circle", "This macOS permission allows an app to read and control other apps. It is optional: you can type or paste into Glacier instead.")
                .padding(.top, 20)
        }
    }

    private var accessibilitySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            iconTile("cursorarrow")
            Text("Enable selected-text access")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(colors.ink)
            Text("macOS keeps this permission in System Settings.")
                .font(.system(size: 12)).foregroundStyle(colors.muted)
            Text("1. Open Privacy & Security → Accessibility.\n2. Turn on Glacier.\n3. Return here and choose Check access.")
                .font(.system(size: 12)).lineSpacing(8).foregroundStyle(colors.muted)
            HStack {
                Spacer()
                secondaryButton("Not now") { showsAccessibilityHelp = false }
                secondaryButton("Open System Settings") { model.openAccessibilitySettings() }
                primaryButton("Check access") {
                    Task {
                        await model.checkAccessibility()
                        if model.snapshot.accessibilityTrusted { showsAccessibilityHelp = false }
                    }
                }
            }
        }
        .padding(26)
        .frame(width: 445)
        .background(colors.raised)
    }

    private var intelligence: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("OPTIONAL INTELLIGENCE", "Connect an AI provider.", "For writing, translation and questions. You can also set this up later.")
            Picker("AI connection type", selection: Binding(
                get: { model.connectionProvider == .ollama },
                set: { model.connectionProvider = $0 ? .ollama : .cerebras }
            )) {
                Text("Cloud provider").tag(false)
                Text("Local with Ollama").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 390)
            .padding(.top, 29)

            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 7) {
                    if model.connectionProvider == .ollama {
                        fieldLabel("Ollama address")
                        Text(model.snapshot.connectionEndpoints[.ollama]?.absoluteString ?? "Endpoint unavailable")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.muted)
                            .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                            .padding(.horizontal, 8)
                            .background(colors.deep, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Ollama address")
                    } else {
                        fieldLabel("Provider")
                        Picker("Provider", selection: Binding(
                            get: { model.connectionProvider }, set: { model.connectionProvider = $0 }
                        )) {
                            ForEach(ConnectionProvider.allCases.filter { $0 != .ollama }, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("glacier.onboarding.provider")
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("Model to use")
                    Picker("Model to use", selection: Binding(
                        get: { model.modelProfileID }, set: { model.modelProfileID = $0 }
                    )) {
                        ForEach(model.snapshot.modelChoices.filter { $0.provider == model.connectionProvider }, id: \.id) { choice in
                            Text(choice.label).tag(choice.id as String?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("glacier.onboarding.model")
                }
            }
            .padding(.top, 24)
            if model.connectionProvider != .ollama {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("Connection endpoint")
                    Text(model.snapshot.connectionEndpoints[model.connectionProvider]?.absoluteString ?? "Endpoint unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("glacier.onboarding.endpoint")
                }
                .padding(.top, 14)
            }
            if model.connectionProvider.requiresCredential {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("API key")
                    SecureField("Paste your provider key", text: Binding(
                        get: { model.apiKey }, set: { model.apiKey = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedControl, equals: .apiKey)
                    .accessibilityIdentifier("glacier.onboarding.apiKey")
                    .disabled(model.snapshot.isPreview)
                }
                .padding(.top, 17)
            }
            HStack(spacing: 11) {
                secondaryButton("Save and use this model") { Task { await model.saveConnection() } }
                    .disabled(model.snapshot.isPreview || model.snapshot.connectionEndpoints[model.connectionProvider] == nil)
                if model.snapshot.connectionSavedProviders.contains(model.connectionProvider) {
                    Button("Test connection") { Task { await model.testConnection() } }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(colors.accent)
                        .accessibilityIdentifier("glacier.onboarding.testConnection")
                        .disabled(model.snapshot.isPreview)
                }
                Text(model.snapshot.isPreview ? "Preview mode: connect later in Settings." : model.connectionTestResult ?? (model.snapshot.connectionSavedProviders.contains(model.connectionProvider) ? "Saved · not checked" : "You can set this up later."))
                    .font(.system(size: 11)).foregroundStyle(colors.muted)
                    .accessibilityIdentifier("glacier.onboarding.connectionStatus")
            }
            .padding(.top, 16)
            note(model.connectionProvider == .ollama ? "laptopcomputer" : "key", model.connectionProvider == .ollama
                 ? "Requests go to the Ollama address you choose. Saving does not send a request."
                 : "Your key is stored in macOS Keychain. Your provider bills its API usage. Saving does not send a request. Automatic requests stay off.")
                .padding(.top, 19)
            if model.connectionProvider.requiresCredential {
                Text("Online tools send their input and selected text to that provider.")
                    .font(.system(size: 11)).foregroundStyle(colors.muted).padding(.top, 7)
            }
        }
    }

    private var yourMac: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("A LITTLE MORE PERSONAL", "Your Mac.\nYour starting point.", "Apps are ready to find. Choose what else you want Glacier to remember.")
            VStack(spacing: 0) {
                dataRow("apps.iphone", "Your applications", "Find and open the apps on your Mac.") {
                    Text("Ready").font(.system(size: 11)).foregroundStyle(colors.success)
                }
                dataRow("folder", model.selectedRoots.isEmpty ? "File search" : "File search · \(model.selectedRoots.count) folder\(model.selectedRoots.count == 1 ? "" : "s")",
                        model.selectedRoots.isEmpty ? "Only the folders you choose. Nothing added yet." : model.selectedRoots.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", ")) {
                    secondaryButton(model.selectedRoots.isEmpty ? "Add folder" : "Change") { Task { await model.chooseSourceRoots() } }
                        .disabled(model.snapshot.isPreview)
                }
                dataRow("clipboard", "Clipboard history", "Keep a local history of things you copy.") {
                    Toggle("Clipboard history", isOn: Binding(get: { model.clipboardEnabled }, set: { model.clipboardEnabled = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityIdentifier("glacier.onboarding.clipboard")
                        .disabled(model.snapshot.isPreview)
                }
                dataRow("power", "Open at login", "Have Glacier ready when you start your Mac.") {
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityIdentifier("glacier.onboarding.login")
                        .disabled(model.snapshot.isPreview)
                }
            }
            .padding(.top, 28)
            note("slider.horizontal.3", "Languages, capture folders and individual tool shortcuts are waiting in Settings whenever you need them.")
                .padding(.top, 18)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("YOUR FIRST SMALL WIN", "Try something.\nIt already works.", "Work out a date, calculate a number, find a symbol.\nNo account or AI connection needed.")
            Label("Runs on your Mac", systemImage: "laptopcomputer")
                .font(.system(size: 11)).foregroundStyle(colors.success)
                .padding(.top, 29)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(colors.muted)
                    Text(selectedDemo.command).font(.system(size: 13)).foregroundStyle(colors.ink)
                        .accessibilityIdentifier("glacier.onboarding.exampleCommand")
                    Spacer()
                    primaryButton("Try it") {
                        displayedDemo = selectedDemo
                        Task { await model.runDemo(selectedDemo) }
                    }
                        .accessibilityIdentifier("glacier.onboarding.tryExample")
                }
                .padding(15)
                HStack {
                    if displayedDemo == selectedDemo, let result = model.demoResult {
                        iconTile(selectedDemo == .date ? "calendar" : selectedDemo == .calculation ? "plus.forwardslash.minus" : "textformat")
                        Text(result).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.ink)
                    } else {
                        Text("A small task. One useful answer.").font(.system(size: 12)).foregroundStyle(colors.faint)
                    }
                    Spacer()
                }
                .frame(height: 75)
                .padding(.horizontal, 18)
                .background(colors.soft.opacity(0.3))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("glacier.onboarding.exampleResult")
            }
            .background(colors.raised, in: RoundedRectangle(cornerRadius: 15))
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(colors.line))
            .frame(maxWidth: 530)
            .frame(maxWidth: .infinity)
            .padding(.top, 15)
            HStack(spacing: 16) {
                demoButton(.date, icon: "calendar")
                demoButton(.calculation, icon: "plus.forwardslash.minus")
                demoButton(.symbol, icon: "textformat")
            }
            .padding(.top, 16)
            HStack(spacing: 19) {
                Label(model.snapshot.shortcut == nil ? "Menu bar" : "Shortcut chosen", systemImage: "keyboard")
                Label(model.snapshot.selectedModelProfileID == nil ? "AI set up later" : "AI model saved", systemImage: "laptopcomputer")
                Label(model.clipboardEnabled ? "Clipboard on" : "Clipboard off", systemImage: "clipboard")
            }
            .font(.system(size: 10))
            .foregroundStyle(colors.muted)
            .padding(.top, 21)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { colors.line.frame(height: 1).offset(y: 9) }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step != .welcome {
                secondaryButton("Back") { Task { await model.back() } }
            }
            if let skipLabel {
                Button(skipLabel) {
                    Task {
                        if model.step == .welcome { await model.tryFirst() }
                        else { await model.skipCurrent() }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(colors.muted)
                .accessibilityIdentifier("glacier.onboarding.skip")
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(0..<GlacierOnboardingStep.allCases.count, id: \.self) { index in
                    Capsule()
                        .fill(index == stepIndex ? colors.accent : index < stepIndex ? colors.faint : colors.line)
                        .frame(width: index == stepIndex ? 18 : 5, height: 5)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Step \(stepIndex + 1) of 6, \(model.step.rawValue)")
            Spacer()
            primaryButton(model.step == .welcome ? "Get started" : model.step == .ready ? "Open Glacier" : "Continue") {
                Task {
                    if model.step == .ready {
                        await finishAndOpen()
                    } else {
                        await model.next()
                    }
                }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("glacier.onboarding.continue")
        }
        .padding(.horizontal, 25)
        .frame(height: 69)
        .overlay(alignment: .top) { colors.line.frame(height: 1) }
        .overlay(alignment: .top) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 610)
                    .padding(8)
                    .background(colors.raised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red.opacity(0.5)))
                    .offset(y: -44)
                    .accessibilityIdentifier("glacier.onboarding.error")
            }
        }
    }

    private func keycap(_ label: String, width: CGFloat) -> some View {
        Text(label)
            .font(.system(size: width > 100 ? 17 : 23, weight: .regular))
            .foregroundStyle(colors.ink)
            .frame(width: width, height: 64)
            .background(colors.raised, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(colors.line))
            .shadow(color: colors.line.opacity(0.6), radius: 0, x: 0, y: 4)
    }

    private func benefit(_ symbol: String, _ label: String) -> some View {
        Label(label, systemImage: symbol).font(.system(size: 11)).foregroundStyle(colors.muted)
    }

    private func iconTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundStyle(colors.accent)
            .frame(width: 36, height: 36)
            .background(colors.soft, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }

    private func smallLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).tracking(0.8).foregroundStyle(colors.faint)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(colors.muted)
    }

    private func note(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).frame(width: 16).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(colors.muted)
    }

    private func dataRow<Accessory: View>(_ icon: String, _ title: String, _ subtitle: String,
                                          @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 14) {
            iconTile(icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.ink)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(colors.muted).lineLimit(2)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .frame(minHeight: 70)
        .overlay(alignment: .bottom) { colors.line.frame(height: 1) }
    }

    private func demoButton(_ demo: GlacierOnboardingDemo, icon: String) -> some View {
        Button {
            selectedDemo = demo
            // Clear the old result by selecting through the model's action on the next Try.
        } label: {
            Label(demo.title, systemImage: icon)
                .font(.system(size: 11))
                .foregroundStyle(selectedDemo == demo ? colors.accent : colors.muted)
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12, weight: .semibold)) }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? colors.accent : colors.ink)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(selected ? colors.soft : colors.raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? colors.accent : colors.line))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12, weight: .semibold)) }
            .buttonStyle(.plain)
            .foregroundStyle(colors.accentInk)
            .padding(.horizontal, 18)
            .frame(minWidth: 112, minHeight: 37)
            .background(colors.accent, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Records a physical key code and modifiers, without installing an event monitor or changing app key equivalents.
struct GlacierOnboardingShortcutRecorder: NSViewRepresentable {
    let chord: GlacierShortcutChord?
    let changed: (GlacierShortcutChord) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        RecorderButton(chord: chord, changed: changed)
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.changed = changed
        button.update(chord: chord)
    }

    @MainActor final class RecorderButton: NSButton {
        var changed: (GlacierShortcutChord) -> Void
        private var recording = false
        private var chord: GlacierShortcutChord?

        init(chord: GlacierShortcutChord?, changed: @escaping (GlacierShortcutChord) -> Void) {
            self.chord = chord
            self.changed = changed
            super.init(frame: .zero)
            bezelStyle = .rounded
            target = self
            action = #selector(beginRecording)
            update(chord: chord)
            setAccessibilityLabel("Record shortcut")
            setAccessibilityHelp("Press a modifier and a key. Escape cancels; Tab moves to the next control.")
        }

        required init?(coder: NSCoder) { fatalError("Use init(chord:changed:)") }
        override var acceptsFirstResponder: Bool { true }

        func update(chord: GlacierShortcutChord?) {
            self.chord = chord
            if !recording { title = "⌨  Record shortcut" }
        }

        @objc private func beginRecording() {
            recording = true
            title = "Press shortcut…"
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { endRecording(); return }
            if event.keyCode == 48 { endRecording(); window?.selectNextKeyView(self); return }
            var modifiers: [GlacierShortcutModifier] = []
            if event.modifierFlags.contains(.command) { modifiers.append(.command) }
            if event.modifierFlags.contains(.option) { modifiers.append(.option) }
            if event.modifierFlags.contains(.control) { modifiers.append(.control) }
            if event.modifierFlags.contains(.shift) { modifiers.append(.shift) }
            guard let chord = try? GlacierShortcutChord(keyCode: event.keyCode, modifiers: modifiers) else {
                NSSound.beep()
                return
            }
            endRecording()
            changed(chord)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        private func endRecording() {
            recording = false
            title = "⌨  Record shortcut"
        }
    }
}
