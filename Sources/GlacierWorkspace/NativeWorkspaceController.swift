import AppKit
import Foundation
import HyperOverlayRuntime
import OmniApplication
import OmniCore
import OmniPresentation
import OmniRun

/// Development-only host for the native workspace candidate. Durable runs and
/// result versions remain owned by `OmniApplicationService`; this type only
/// coordinates AppKit surfaces, foreground identity, and editable drafts.
@MainActor
public final class OmniNativeWorkspaceController {
    public var contributedQuickLaunchTools: [OmniQuickLaunch] = [] {
        didSet { refreshActionAvailability() }
    }
    public var contributedSlashRoutes: [OmniContributedSlashRoute] = [] {
        didSet { quickPadController.contributedSlashRoutes = contributedSlashRoutes }
    }
    public var onContributedQuickLaunch: ((String) -> Bool)?
    /// `nil` means this slash text belongs to the ordinary parser.
    public var onContributedSlash: ((String) -> Bool?)?
    /// The composition owns the complete settings surface and action catalogue.
    public var onShowSettings: (@MainActor (Bool) async -> Void)?
    public var canInvoke: @MainActor (String) -> Bool = { _ in true } {
        didSet { refreshActionAvailability() }
    }
    /// Rechecks a stored or cached index path against the current source policy.
    /// The app supplies this from its live search service.
    public var canUseIndexedPath: @MainActor (String) -> Bool = { _ in false }

    public func refreshSourceAccess() async {
        lastDisplayedResult = nil
        lastDisplayedRows = []
        try? await refreshResults(orderWindows: false)
    }

    /// Invalidates the UI revision before provider credentials/routes change, so queued old deltas cannot render.
    public func invalidateModelSessions() {
        guard let id = visibleEphemeralToolID,
              ["translate", "quick-question", "concept-lens", "pronunciation", "express", "map", "recall", "regex", "emoji"].contains(id) else { return }
        dismissEphemeralTool(restoreFocus: false)
    }

    public func refreshActionAvailability() {
        quickPadController.isActionAvailable = { [weak self] actionID in
            self?.canInvoke(actionID) ?? false
        }
        let launcherEnabled = launcher != nil && canInvoke("launcher.open")
        if !launcherEnabled { launcherPipeline?.cancel() }
        quickPadController.launcherEnabled = launcherEnabled
        newCommandMenuItem?.isEnabled = launcherEnabled
        if let visibleEphemeralToolID {
            let actionID = "tool.\(visibleEphemeralToolID)"
            if !canInvoke(actionID) {
                dismissEphemeralTool(restoreFocus: false)
            }
        }
        ephemeralTool?.session.refreshAutomaticRequestMode()
        mapTool?.session.refreshAutomaticRequestMode()
        recallTool?.session.refreshAutomaticRequestMode()
        regexTool?.session.refreshAutomaticRequestMode()
        emojiTool?.session.refreshAutomaticRequestMode()
        let remoteEnabled = environment.remoteServicesEnabled()
        if lastRemoteServicesEnabled && !remoteEnabled,
           ephemeralTool?.session.descriptor.id == OmniEphemeralToolKind.pronunciation.descriptor.id {
            ephemeralTool?.session.cancelCurrentRequestPreservingInput()
        }
        lastRemoteServicesEnabled = remoteEnabled
        weatherTool?.session.refreshRemoteServices()
        if isCaptureVisible, !canInvoke("capture.new") {
            dismissCapture(restoreFocus: false)
        }
        quickPadController.quickLaunchTools = (OmniEphemeralToolKind.quickLaunchRegistry + contributedQuickLaunchTools).filter { tool in
            if tool.toolID == "clipboard-history" { return canInvoke("clipboard.history") }
            return canInvoke("tool.\(tool.toolID)")
        }.map { tool in
            let actionID = tool.toolID == "clipboard-history" ? "clipboard.history" : "tool.\(tool.toolID)"
            let title = tool.title + (environment.shortcutLabel(actionID).map { " · \($0)" } ?? "")
            return OmniQuickLaunch(letters: tool.letters, title: title, toolID: tool.toolID)
        }
        refreshOpenToolShortcutLabels()
        invalidateRoutePreviews()
    }

    private func refreshOpenToolShortcutLabels() {
        if let tool = ephemeralTool {
            tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.\(tool.session.descriptor.id)")
            tool.viewController.render()
        }
        if let tool = recallTool { tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.recall"); tool.viewController.render() }
        if let tool = emojiTool { tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.emoji"); tool.viewController.render() }
        if let tool = charactersTool { tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.characters"); tool.viewController.render() }
        if let tool = stashTool { tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.stash"); tool.viewController.render() }
        if let tool = ratioTool { tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.ratio"); tool.viewController.render() }
        if let tool = mapTool { tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.map"); tool.viewController.render() }
        if let tool = weatherTool { tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.weather"); tool.viewController.render() }
        if let tool = qrTool { tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.qr"); tool.viewController.render() }
        if let tool = regexTool { tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.regex"); tool.viewController.render() }
    }
    public let quickPadController: OmniCommandPadViewController
    public private(set) var quickPanel: OmniCommandPadPanel?
    public private(set) var ephemeralTool: OmniEphemeralWindowController?
    public private(set) var recallTool: OmniRecallWindowController?
    public private(set) var emojiTool: OmniEmojiWindowController?
    public private(set) var charactersTool: OmniCharactersWindowController?
    private var charactersInsertInFlight: ObjectIdentifier?
    private var charactersTarget: PasteTarget?
    /// Installed host presents this as a transient bezel, never a run notification.
    public var onInsertionNotice: ((String) -> Void)?
    public private(set) var lastInsertionNotice: String?
    public private(set) var stashTool: OmniStashWindowController?
    public private(set) var ratioTool: OmniRatioWindowController?
    public private(set) var mapTool: OmniMapWindowController?
    public private(set) var weatherTool: OmniWeatherWindowController?
    public private(set) var qrTool: OmniQRWindowController?
    public private(set) var regexTool: OmniRegexWindowController?
    /// The stash tool whose paste chain is running (see `pasteStashEntry`).
    private var stashPasteInFlight: ObjectIdentifier?
    public private(set) var captureTool: OmniCaptureWindowController?
    public let workspace: OmniWorkspace
    /// Arrival surface: runs left while working notify on done or failed.
    public let notifications: OmniNotificationClient
    /// Menu bar status (H4); nil when the host presents no interface.
    public private(set) var statusPresenter: OmniStatusItemPresenter?
    /// One state, several views (C10): the tracker alone decides that a run
    /// started or ended; the menu bar and notifications only react.
    public private(set) var activity = RunActivityTracker()
    public private(set) var selectedRunID: String?
    public private(set) var selectedVersion: Int?
    /// Where the pad's imported text came from; persisted with the run.
    public private(set) var quickProvenance: OmniRunProvenance?
    /// The selection the chip describes, kept with it so a tool opened by an
    /// abbreviation still receives it after the field was overtyped (quick-launch §1.2).
    private var quickSelectionText: String?
    /// The open Settings window. It stays set while it is merely ordered out
    /// (another Omni surface took the foreground), so Settings… returns it on
    /// the same pane; a real close (⌘W, the title-bar close button) clears it.
    public private(set) var settingsWindow: OmniSettingsWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    /// Settings choices with no owner of their own (H20): appearance, the
    /// ephemeral tools' model, paste, skin tone, Recall's sheet, last pane.
    public let preferences: OmniPreferencesStore
    /// The resident host's services for Settings; nil in development hosts.
    public var settingsHost: OmniSettingsHostHooks? {
        didSet { if let settingsHost { settingsHost.clipboard?.applyPreferences(preferences.current) } }
    }
    /// Set once quitting has begun (a quit prompt is up, or `stop()` ran), so a
    /// second ⌘Q cannot stack a prompt or read stale run states during the drain.
    private var isQuitting = false
    public private(set) var draftPersistenceError: String?
    public var selectedRunHasUnsubmittedFollowUp: Bool {
        guard let selectedRunID else { return false }
        return followUpDrafts.keys.contains { $0.runID == selectedRunID }
    }

    private struct DraftKey: Hashable {
        let runID: String
        let sourceVersion: Int
    }

    private struct DisplayedResult: Equatable {
        let runID: String
        let title: String
        let status: String
        let versions: [OmniWorkspaceVersion]
        let selectedVersion: Int
        let pendingText: String?
        let pendingAnnotations: [OmniTextAnnotation]
        let submittedInput: String?
        let submittedAnnotations: [OmniTextAnnotation]
        let resumeAvailable: Bool
        let canCancel: Bool
        let header: OmniWorkspaceRunHeader?
        let composerRoute: String?
        let annotationNotice: String?
    }

    private let environment: GlacierWorkspaceEnvironment
    private var lastRemoteServicesEnabled: Bool
    private let foreground: OmniForegroundCoordinator
    private let sharedForeground: ForegroundArbitrator
    let focusOrigin: FocusOriginTracker
    /// The shared host owns history; Omni carries its original external paste target.
    public var onClipboardRequested: ((String, pid_t?) -> Void)?
    private let pasteboardWriter: @MainActor (String) -> Void
    private let qrPasteboardWriter: (@MainActor (NSPasteboardItem) -> Bool)?
    /// Writes a stash entry with every flavour it kept (copy only, and the
    /// paste chain's write); tests inject a recorder.
    /// Writes an entry; `true` is ⇧↩'s plain text, whatever Settings says.
    private let stashWriter: @MainActor (OmniStashEntry, Bool) -> Bool
    /// The shared targeted paste (Clipboard's chain); tests inject the outcome.
    private let stashPaste: @MainActor (PasteTarget?, () -> Void, () -> Bool, () -> Bool) async -> TargetedPasteFailure?
    private let restoreOriginOverride: (@MainActor () -> Void)?
    private let selectionCapture: NativeSelectionCapture
    private let ephemeralProducers: [OmniEphemeralToolKind: OmniEphemeralProducer]
    private let mapProducer: OmniMapProducer
    private let recallSessionFactory: @MainActor () -> OmniRecallSession
    private let regexSessionFactory: @MainActor () -> OmniRegexSession
    private let characterWriter: @MainActor (String) -> Bool
    private let characterInsert: @MainActor (String, PasteTarget?, () -> Void, () -> Bool, () -> Bool) async -> TextInsertionOutcome
    private let charactersSessionFactory: @MainActor () -> OmniCharactersSession
    private let weatherSessionFactory: @MainActor () -> OmniWeatherSession
    private let emojiSessionFactory: @MainActor () -> OmniEmojiSession
    private let presentsInterface: Bool
    private let activationPolicy: NSApplication.ActivationPolicy
    private let displayName: String
    private let statusItemTitle: String
    private let ownsApplicationMenu: Bool
    private let beforeOmniForeground: (@MainActor () -> Void)?
    private let onForegroundIntentReserved: (@MainActor () -> Void)?
    private let followUpDraftStore: FollowUpDraftStore
    /// The file-finder fast lane (H10). Only the installed composition
    /// supplies one: development and candidate envelopes forbid `~/Base`,
    /// so there bare text keeps its pre-launcher behaviour.
    public let launcher: LauncherService?
    private var launcherPipeline: LauncherQueryPipeline?
    /// One launch at a time: a double Enter must not open twice.
    private var launchInFlight = false
    /// When the pending launch undo was registered; it expires at the next
    /// pad opening after `launchUndoLifetime`, or when a selection is imported.
    private var launchUndoRegisteredAt: Date?
    static let launchUndoLifetime: TimeInterval = 300
    private var visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    /// Fixture hosts without a provider runtime still say where replies come from.
    private var sampleRepliesRoute = false
    private var pollTask: Task<Void, Never>?
    private var lastResultsRevision: UInt64?
    private var followUpDraftRevision: UInt64 = 0
    private var renderedFollowUpDraftRevision: UInt64 = 0
    private var statusItem: NSStatusItem?
    private var newCommandMenuItem: NSMenuItem?
    private var menuTargets: [NativeWorkspaceMenuTarget] = []
    /// Detached working runs and workspace follow-ups owe notifications.
    /// Enter itself does not; Cmd+Enter never does (C53, C56).
    private var notifyingRunIDs: Set<String> = []
    /// Content owed while the permission ask is still up (spec §7).
    private var pendingDeliveries: [String: OmniNotificationContent] = [:]
    /// The run bound to the pad's working/result surface (H11).
    public private(set) var padRunID: String?
    private var padRunShape: OmniCommandShape?
    private var padResultSummary = ""
    private(set) var renderedInPadRunIDs: Set<String> = []
    private struct QuickSubmissionKey: Equatable {
        let generation: Int
        let revision: Int
        let text: String
        let profileID: String?
        let annotations: [OmniTextAnnotation]
    }
    @MainActor private final class PendingQuickSubmission {
        let key: QuickSubmissionKey
        var gesture: OmniSubmitGesture
        var sequence: Int
        init(key: QuickSubmissionKey, gesture: OmniSubmitGesture, sequence: Int) {
            self.key = key; self.gesture = gesture; self.sequence = sequence
        }
    }
    private var quickSubmissionsInFlight: [PendingQuickSubmission] = []
    private var latestQuickSubmission = 0
    private var confirmingProposalRunIDs: Set<String> = []
    /// One pick at a time per stance run: a double digit press drafts once.
    private var pickingStanceRunIDs: Set<String> = []
    /// Positions closed unpicked whose arrival notification is about to be owed.
    private var positionsArrivalsOwed: Set<String> = []
    /// A pick that returned to composing (edit first, or no draft command):
    /// the next pad submit that still carries its note links to the stance run.
    private var pendingPickOrigin: (stanceRunID: String, noteID: UUID)?
    /// Proposals whose pad was dismissed while waiting: courier them (spec §3).
    private var proposalCouriersOwed: Set<String> = []
    /// The chosen alternative's shape and token, for the confirmed run's arrival.
    private var confirmedProposalShapes: [String: (shape: OmniCommandShape, token: String)] = [:]
    private var authorizationTask: Task<Void, Never>?
    private var modelsByRunID: [String: ResultViewModel] = [:]
    private var lastDisplayedRows: [OmniWorkspaceRunRow] = []
    private var lastDisplayedResult: DisplayedResult?
    private var versionsByRunID: [String: [OmniResultVersion]] = [:]
    private var submittedInputsByRunID: [String: String] = [:]
    private var followUpStatesByRunID: [String: OmniFollowUpState] = [:]
    private struct AnnotatedDraft: Equatable {
        let text: String
        let annotations: [OmniTextAnnotation]
    }
    private var followUpDrafts: [DraftKey: AnnotatedDraft] = [:]
    /// Test seam for the live editor window between admission and UI cleanup.
    var afterFollowUpAdmission: (@MainActor () async -> Void)?
    /// Test seam for close versus rejected proposal admission, without a
    /// wall-clock race or a fake terminal store transition.
    var beforeProposalConfirmation: (@MainActor () async -> Void)?
    private var restoringComposer = false
    private var recoveredFollowUpRequestIDs: Set<String> = []
    private var discardedFollowUpRequestIDs: Set<String> = []
    private var expectedFollowUpVersionByRunID: [String: Int] = [:]
    private var composerKey: DraftKey?
    private var followsLatestVersion = true
    private var interactionRevision = 0
    private var captureRevision = 0
    private var foregroundBeforeToolRelinquish: Bool?
    private var resultsRefreshGeneration = 0
    var afterResultsSnapshot: (@MainActor ([ResultViewModel]) async -> Void)?
    var afterQuickAdmission: (@MainActor (String) async -> Void)?

    private struct ForegroundIntent: Equatable, Sendable {
        let interactionRevision: Int
        let captureRevision: Int
    }

    /// Reserve synchronously in UI callbacks, before their async work can be
    /// overtaken by another Hyper foreground request.
    /// An active host-owned picker can transfer its external return target.
    /// Selection capture still reads only the current foreground application.
    public var hostSurfaceOrigin: (@MainActor () -> (active: Bool, processID: pid_t?))?

    private func reserveForegroundIntent(preservingExistingOrigin: Bool = false) -> ForegroundIntent {
        let hadOmniForeground = preservingExistingOrigin || (foregroundBeforeToolRelinquish ?? hasForegroundSurface)
        foregroundBeforeToolRelinquish = nil
        if let origin = hostSurfaceOrigin?(), origin.active {
            focusOrigin.adoptOrigin(origin.processID, excluding: ProcessInfo.processInfo.processIdentifier)
        } else if !hadOmniForeground {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier,
                                      preserveExistingWhenExcluded: false)
        }
        dismissEphemeralTool(restoreFocus: false)
        dismissCapture(restoreFocus: false)
        interactionRevision += 1
        captureRevision += 1
        onForegroundIntentReserved?()
        return ForegroundIntent(interactionRevision: interactionRevision, captureRevision: captureRevision)
    }

    /// A newer native Hyper chord supersedes queued Omni menu/notification work
    /// before that work reaches its first actor continuation.
    public func invalidatePendingForegroundIntent() {
        interactionRevision += 1
        captureRevision += 1
    }

    private func isCurrent(_ intent: ForegroundIntent) -> Bool {
        interactionRevision == intent.interactionRevision && captureRevision == intent.captureRevision
    }

    private func enqueueQuickRequest() {
        guard !isQuitting, canInvoke("launcher.open") else { return }
        if padRunID != nil || quickPadController.isShowingLocalOptions { dismissQuickPad(restoreFocus: false) }
        let intent = reserveForegroundIntent()
        Task { [weak self] in await self?.beginQuickRequest(reservedIntent: intent) }
    }

    public init(
        environment: GlacierWorkspaceEnvironment,
        foreground sharedForeground: ForegroundArbitrator,
        presentsInterface: Bool = true,
        selectionCapture: NativeSelectionCapture = NativeSelectionCapture(),
        activationPolicy: NSApplication.ActivationPolicy = .accessory,
        displayName: String = "Glacier",
        statusItemTitle: String = "Glacier",
        developmentIndicator: String? = nil,
        workspaceTitle: String? = nil,
        notifications: OmniNotificationClient? = nil,
        ownsApplicationMenu: Bool = true,
        beforeOmniForeground: (@MainActor () -> Void)? = nil,
        onForegroundIntentReserved: (@MainActor () -> Void)? = nil,
        launcher: LauncherService? = nil,
        pasteboardWriter: (@MainActor (String) -> Void)? = nil,
        qrPasteboardWriter: (@MainActor (NSPasteboardItem) -> Bool)? = nil,
        restoreOrigin: (@MainActor () -> Void)? = nil,
        focusOrigin: FocusOriginTracker = FocusOriginTracker(),
        ephemeralTranslationProducer: OmniEphemeralProducer? = nil,
        ephemeralProducers: [OmniEphemeralToolKind: OmniEphemeralProducer] = [:],
        mapProducer: OmniMapProducer? = nil,
        recallSessionFactory: (@MainActor () -> OmniRecallSession)? = nil,
        regexSessionFactory: (@MainActor () -> OmniRegexSession)? = nil,
        emojiSessionFactory: (@MainActor () -> OmniEmojiSession)? = nil,
        charactersSessionFactory: (@MainActor () -> OmniCharactersSession)? = nil,
        weatherSessionFactory: (@MainActor () -> OmniWeatherSession)? = nil,
        characterInsert: (@MainActor (String, PasteTarget?, () -> Void, () -> Bool, () -> Bool) async -> TextInsertionOutcome)? = nil,
        stashWriter: (@MainActor (OmniStashEntry) -> Bool)? = nil,
        stashPaste: (@MainActor (PasteTarget?, () -> Void, () -> Bool, () -> Bool) async -> TargetedPasteFailure?)? = nil,
        preferences: OmniPreferencesStore? = nil
    ) {
        self.environment = environment
        lastRemoteServicesEnabled = environment.remoteServicesEnabled()
        let store = preferences ?? .forEnvironment(environment)
        self.preferences = store
        self.recallSessionFactory = recallSessionFactory ?? { OmniRecall.makeSession(environment: environment, preferences: store) }
        self.regexSessionFactory = regexSessionFactory ?? { OmniRegex.makeSession(environment: environment) }
        self.emojiSessionFactory = emojiSessionFactory ?? { OmniEmoji.makeSession(environment: environment, preferences: store) }
        self.charactersSessionFactory = charactersSessionFactory ?? { OmniCharacters.makeSession(environment: environment) }
        self.weatherSessionFactory = weatherSessionFactory ?? { OmniWeather.makeSession(environment: environment, preferences: store) }
        self.characterInsert = characterInsert ?? { text, target, hide, write, isCurrent in
            await TextInsertion.perform(text: text, into: target, hide: hide, write: write, isCurrent: isCurrent)
        }
        if charactersSessionFactory == nil { Task.detached(priority: .utility) { _ = CharacterCorpus.shared } }
        // The emoji index is built at launch, not on the first keystroke.
        if emojiSessionFactory == nil { Task.detached(priority: .utility) { _ = EmojiCorpus.shared } }
        self.launcher = launcher
        self.pasteboardWriter = pasteboardWriter ?? { text in
            HostPasteboardWriter.writeText(text)
        }
        self.qrPasteboardWriter = qrPasteboardWriter
        if let pasteboardWriter {
            self.characterWriter = { text in pasteboardWriter(text); return true }
        } else {
            self.characterWriter = { HostPasteboardWriter.writeText($0) }
        }
        self.restoreOriginOverride = restoreOrigin
        self.focusOrigin = focusOrigin
        if let stashWriter {
            self.stashWriter = { entry, _ in stashWriter(entry) }
        } else {
            self.stashWriter = { entry, plain in
                OmniStashPasteboard.write(entry, plainText: plain || store.current.pasteMode == .plainText)
            }
        }
        self.stashPaste = stashPaste ?? { target, hide, write, isCurrent in
            await TargetedPaste.perform(into: target, hide: hide, write: write, isCurrent: isCurrent)
        }
        self.sharedForeground = sharedForeground
        self.presentsInterface = presentsInterface
        self.selectionCapture = selectionCapture
        var overrides = ephemeralProducers
        if let ephemeralTranslationProducer { overrides[.translation] = ephemeralTranslationProducer }
        self.ephemeralProducers = Dictionary(uniqueKeysWithValues: OmniEphemeralToolKind.allCases.map { kind in
            (kind, overrides[kind] ?? OmniEphemeralTools.producer(for: kind, environment: environment, preferences: store))
        })
        self.mapProducer = mapProducer ?? OmniMapModelProducer.make(environment: environment)
        self.activationPolicy = activationPolicy
        self.displayName = displayName
        self.statusItemTitle = statusItemTitle
        self.ownsApplicationMenu = ownsApplicationMenu
        self.beforeOmniForeground = beforeOmniForeground
        self.onForegroundIntentReserved = onForegroundIntentReserved
        followUpDraftStore = FollowUpDraftStore(configuration: environment.configuration)
        if let notifications {
            self.notifications = notifications
        } else if presentsInterface, let system = SystemOmniNotificationClient.makeIfAvailable() {
            self.notifications = system
        } else {
            // A bare executable cannot register with the notification centre;
            // the host still runs, records what it would have delivered, and
            // reports the reason through `status`.
            let reason = presentsInterface
                ? (SystemOmniNotificationClient.unavailabilityReason ?? "no notification client")
                : "headless session"
            self.notifications = RecordingOmniNotificationClient(availability: .unavailable(reason: reason))
        }
        foreground = OmniForegroundCoordinator(runtime: sharedForeground)
        let modelLabel: String = if environment.usesSampleReplies {
            "Sample replies"
        } else if environment.providerRuntime != nil {
            "Configured providers · policy 6.0.0"
        } else {
            "Inference unavailable"
        }
        let profileIndicator = developmentIndicator ?? "Glacier · \(modelLabel)"
        quickPadController = OmniCommandPadViewController(
            parser: environment.service.parser,
            developmentIndicator: profileIndicator
        )
        sampleRepliesRoute = environment.usesSampleReplies
        workspace = OmniWorkspace(visibleFrame: visibleFrame, parser: environment.service.parser, developmentIndicator: profileIndicator)
        workspace.workspacePanel.title = workspaceTitle ?? "Glacier workspace"
        do {
            let document = try followUpDraftStore.load()
            for draft in document.drafts {
                followUpDrafts[DraftKey(runID: draft.runID, sourceVersion: draft.sourceVersion)] =
                    AnnotatedDraft(text: draft.text, annotations: draft.annotations)
            }
            discardedFollowUpRequestIDs = Set(document.discardedRequestIDs)
        } catch {
            draftPersistenceError = "Unable to restore follow-up drafts: \(error.localizedDescription)"
        }
        configureCallbacks()
        if presentsInterface {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidResignActive(_:)),
                name: NSApplication.didResignActiveNotification,
                object: NSApplication.shared
            )
        }
        if presentsInterface, environment.ownsStatusItem { configureStatusItem() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        let currentIsPasting = stashTool.map { stashPasteInFlight == ObjectIdentifier($0) } ?? false
        let currentIsInserting = charactersTool.map { charactersInsertInFlight == ObjectIdentifier($0) } ?? false
        if !currentIsPasting && !currentIsInserting { dismissEphemeralTool(restoreFocus: false) }
        dismissCapture(restoreFocus: false)
        guard isQuickPadVisible else { return }
        // Losing key to an Omni note card/settings panel is not deactivation.
        // A click into another app uses Escape's close path without stealing
        // focus back from the app the user just chose.
        dismissQuickPad(restoreFocus: false)
    }

    /// Starts menu-bar residency and history polling independently of windows.
    /// It deliberately does not capture selection until New request is invoked.
    public func show() async throws {
        guard !isQuitting, !Task.isCancelled else { throw CancellationError() }
        let isInstalled = environment.isInstalled
        if presentsInterface {
            NSApplication.shared.setActivationPolicy(activationPolicy)
            visibleFrame = currentVisibleFrame()
            workspace.updateVisibleFrame(visibleFrame)
        }
        try await refreshResults(orderWindows: false)
        guard !isQuitting, !Task.isCancelled else { throw CancellationError() }
        if let launcher {
            // Snapshot first (the pad never waits for a crawl), then a
            // background re-crawl when one is due.
            Task.detached(priority: .utility) {
                launcher.loadPersisted()
                launcher.refreshIfDue()
            }
        }
        if presentsInterface, isInstalled {
            // The resident host publishes this composition only after start()
            // succeeds. Keep every Omni entry point unreachable while the
            // initial durable history read can still fail or suspend.
            if statusItem == nil { configureStatusItem() }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, !self.isQuitting, !Task.isCancelled else { return }
                try? await self.refreshResults(orderWindows: false, onlyWhenChanged: true)
            }
        }
    }

    public func stop() {
        isQuitting = true
        resultsRefreshGeneration += 1
        flushStashEdits()
        if let stashObserver { NotificationCenter.default.removeObserver(stashObserver) }
        stashObserver = nil
        dismissEphemeralTool(restoreFocus: false)
        dismissCapture(restoreFocus: false)
        captureRevision += 1
        interactionRevision += 1
        saveActiveComposerDraft()
        pollTask?.cancel()
        pollTask = nil
        lastResultsRevision = nil
        quickPadController.closeAnnotationPanels()
        quickPanel?.orderOut(nil)
        closeSettingsPanel()
        workspace.hideWorkspace()
        if let statusPresenter { statusPresenter.tearDown() } else if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusPresenter = nil
        statusItem = nil
        switch foreground.snapshot().foreground {
        case .editing:
            foreground.closeBeforeSubmission()
        case .attached:
            foreground.detachAttachedResult()
        case .hidden, .legacy:
            break
        }
    }

    /// Refreshes durable root-run history. The workspace keeps the complete
    /// list while its compact launcher popover projects only the latest five.
    /// An active editor keeps both its text and caret.
    public func refreshResults(orderWindows: Bool = true, onlyWhenChanged: Bool = false) async throws {
        guard !isQuitting, !Task.isCancelled else { return }
        let localRevision = followUpDraftRevision
        let selected = selectedRunID
        let previousRevision = onlyWhenChanged && selected == workspace.selectedRunID
            && localRevision == renderedFollowUpDraftRevision ? lastResultsRevision : nil
        let interactionAtStart = interactionRevision
        guard let snapshot = try await environment.service.reconstructRecentResultsIfChanged(since: previousRevision) else { return }
        guard !isQuitting, !Task.isCancelled else { return }
        // A store mutation during projection has a newer revision and remains
        // due on the next tick. An unchanged tick does not cancel an explicit
        // refresh that is still in flight.
        if let lastResultsRevision, snapshot.revision < lastResultsRevision { return }
        resultsRefreshGeneration += 1
        let generation = resultsRefreshGeneration
        let models = snapshot.results
        await afterResultsSnapshot?(models)
        // Resolve latest full text before the synchronous arrival decision.
        // A close during this await detaches; observeActivity then sees that
        // ownership change and cannot also render the terminal result.
        var preparedVersions: [String: [OmniResultVersion]] = [:]
        if let padRunID, let id = RunID(rawValue: padRunID) {
            preparedVersions[padRunID] = (try? await environment.service.resultVersions(runID: id)) ?? []
        }
        guard !isQuitting, !Task.isCancelled, generation == resultsRefreshGeneration else { return }
        modelsByRunID = Dictionary(uniqueKeysWithValues: models.map { ($0.runID, $0) })
        versionsByRunID.merge(preparedVersions) { _, latest in latest }
        await observeActivity(models)
        guard !isQuitting, !Task.isCancelled, generation == resultsRefreshGeneration else { return }
        if let padRunID, case .result(let id) = quickPadController.mode, id == padRunID,
           let model = modelsByRunID[padRunID], RunActivityTracker.phase(of: model) != .active {
            renderPadResult(model, outcome: outcome(of: model))
        }

        // The pinned stash row shows no run; polling must not pick one.
        if selectedRunID == nil, !workspace.isShowingStash { selectedRunID = models.first?.runID }
        if let selectedRunID, modelsByRunID[selectedRunID] == nil {
            self.selectedRunID = models.first?.runID
            selectedVersion = nil
        }

        displayRowsIfChanged(models.map(runRow))
        lastResultsRevision = snapshot.revision
        renderedFollowUpDraftRevision = localRevision
        guard composerKey == nil, !workspace.isShowingStash, let selectedRunID else { return }
        await loadAndDisplayResult(runID: selectedRunID, expectedRevision: interactionAtStart)

        if !isQuitting, !Task.isCancelled, orderWindows, presentsInterface, workspace.workspacePanel.isVisible {
            workspace.workspacePanel.orderFront(nil)
        }
    }

    public func usesForeground(_ candidate: ForegroundArbitrator) -> Bool {
        sharedForeground === candidate
    }

    /// Starts the ordinary quick pad after capturing the current external
    /// selection. This method is public so offscreen integration tests can
    /// exercise the same race boundary as the real launcher.
    public func beginQuickRequest() async {
        guard !isQuitting, canInvoke("launcher.open") else { return }
        if padRunID != nil || quickPadController.isShowingLocalOptions { dismissQuickPad(restoreFocus: false) }
        await beginQuickRequest(reservedIntent: reserveForegroundIntent())
    }

    /// Begins a fresh in-memory tool. Selection capture precedes activation;
    /// closing or a newer foreground request invalidates any pending capture.
    @discardableResult
    public func beginEphemeralTranslation() async -> Bool {
        await beginEphemeralTool(.translation)
    }

    /// The foreground has one visible disposable panel at a time. Keeping the
    /// search in one method also avoids a large coalescing expression at each route.
    private func relinquishVisibleToolPanel() -> NSPanel? {
        foregroundBeforeToolRelinquish = hasForegroundSurface
        if let tool = ephemeralTool, tool.isVisible { return tool.relinquishPanelForReplacement() }
        if let tool = recallTool, tool.isVisible { return tool.relinquishPanelForReplacement() }
        if let tool = emojiTool, tool.isVisible { return tool.relinquishPanelForReplacement() }
        if let tool = charactersTool, tool.isVisible { return tool.relinquishPanelForReplacement() }
        if let tool = stashTool, tool.isVisible { return tool.relinquishPanelForReplacement() }
        if let tool = ratioTool, tool.isVisible { return tool.relinquishPanelForReplacement() }
        if let tool = mapTool, tool.isVisible { return tool.relinquishPanelForReplacement() }
        if let tool = weatherTool, tool.isVisible { return tool.relinquishPanelForReplacement() }
        if let tool = qrTool, tool.isVisible {
            let panel = tool.relinquishPanelForReplacement()
            tool.dismiss()
            return panel
        }
        if let tool = regexTool, tool.isVisible {
            let panel = tool.relinquishPanelForReplacement()
            tool.dismiss()
            return panel
        }
        return nil
    }

    /// A direct QR tool request reads the current external selection through
    /// the same AX-only capture path as the other input tools.
    private func beginQRFromSelection() async -> Bool {
        let hadVisibleTool = isEphemeralToolVisible
        let padVisible = isQuickPadVisible
        if hadVisibleTool { return beginQR(input: "") }
        if padVisible {
            let provenance = quickPadController.provenance
            let selection = provenance == nil ? "" : (quickSelectionText ?? "")
            return beginQR(input: selection, anchor: quickPanel, provenance: provenance)
        }
        focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        let intent = reserveForegroundIntent()
        let capture = await selectionCapture.captureCurrentSelection(
            excludingPID: ProcessInfo.processInfo.processIdentifier)
        guard isCurrent(intent), !isQuitting else { return false }
        if case .unavailable(.foregroundChanged) = capture { return false }
        switch capture {
        case .selected(let selection):
            let provenance = OmniPadProvenance(
                source: selection.appName ?? "Selection", detail: selection.windowTitle,
                wordCount: selection.text.split(whereSeparator: \.isWhitespace).count,
                bundleIdentifier: selection.bundleIdentifier)
            return beginQR(input: selection.text, provenance: provenance)
        case .empty, .unavailable:
            return beginQR(input: "")
        }
    }

    @discardableResult
    public func beginEphemeralTool(_ kind: OmniEphemeralToolKind) async -> Bool {
        guard canInvoke("tool.\(kind.descriptor.id)") else { return false }
        if kind == .recall { return beginRecall() }
        if kind == .emoji { return beginEmoji() }
        if kind == .characters { return beginCharacters() }
        if kind == .stash { return beginStash() }
        if kind == .ratio { return beginRatio() }
        if kind == .map { return beginMap() }
        if kind == .weather { return beginWeather() }
        if kind == .qr { return await beginQRFromSelection() }
        if kind == .regex { return await beginRegexFromSelection() }
        let previousRecall = recallTool.flatMap { $0.isVisible ? $0 : nil }
        let previousEmoji = emojiTool.flatMap { $0.isVisible ? $0 : nil }
        let previousCharacters = charactersTool.flatMap { $0.isVisible ? $0 : nil }
        let previousStash = stashTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRatio = ratioTool.flatMap { $0.isVisible ? $0 : nil }
        let previousMap = mapTool.flatMap { $0.isVisible ? $0 : nil }
        let previousWeather = weatherTool.flatMap { $0.isVisible ? $0 : nil }
        let previousQR = qrTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRegex = regexTool.flatMap { $0.isVisible ? $0 : nil }

        // A different K/L/M tool takes the current field and its capture chip
        // into a fresh disposable session. The foreground is now Omni itself,
        // so an external AX recapture would discard the field.
        let previousTool = ephemeralTool.flatMap { $0.isVisible && $0.session.descriptor.id != kind.descriptor.id ? $0 : nil }
        let carriedInput = kind == .pronunciation ? nil
            : (previousTool?.session.input ?? previousRecall?.session.input ?? previousCharacters?.session.input ?? previousEmoji?.session.input ?? previousMap?.session.input)
        let carriedProvenance = previousTool?.viewController.provenance ?? previousCharacters?.viewController.provenance ?? previousEmoji?.viewController.provenance ?? previousMap?.viewController.provenance
        let reusedPanel = relinquishVisibleToolPanel()
        let intent = reserveForegroundIntent()
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else {
            reusedPanel?.orderOut(nil)
            return false
        }
        let input: String
        let notice: String?
        let provenance: OmniPadProvenance?
        if kind == .pronunciation || previousStash != nil || previousRatio != nil || previousWeather != nil || previousQR != nil || previousRegex != nil,
           previousTool != nil || previousRecall != nil || previousCharacters != nil || previousEmoji != nil || previousStash != nil || previousRatio != nil || previousMap != nil || previousWeather != nil || previousQR != nil || previousRegex != nil {
            // U starts from an external selection or an empty input, never
            // a retained field from another tool or the clipboard. A stash
            // search, ratio, or weather place is not transferable material.
            input = ""
            notice = nil
            provenance = nil
        } else if let carriedInput {
            input = carriedInput
            notice = nil
            provenance = carriedProvenance
        } else {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
            let capture = await selectionCapture.captureCurrentSelection(
                excludingPID: ProcessInfo.processInfo.processIdentifier
            )
            guard isCurrent(intent), !isQuitting else { return false }
            if case .unavailable(.foregroundChanged) = capture { return false }
            switch capture {
            case .selected(let selection):
                input = selection.text
                notice = nil
                provenance = OmniPadProvenance(
                    source: selection.appName ?? "Selection",
                    detail: selection.windowTitle,
                    wordCount: selection.text.split(whereSeparator: \.isWhitespace).count,
                    bundleIdentifier: selection.bundleIdentifier
                )
            case .empty:
                input = ""
                notice = nil
                provenance = nil
            case .unavailable(let reason):
                input = ""
                notice = Self.unavailableNotice(reason)
                provenance = nil
            }
        }
        return showEphemeralTool(
            kind, input: input, notice: notice, provenance: provenance, reusing: reusedPanel
        )
    }

    /// A pad-local /pron consumes its explicit literal payload. AX and the
    /// clipboard are deliberately absent; the pad's external focus origin stays.
    @discardableResult
    public func beginPronunciation(term: String) -> Bool {
        guard canInvoke("tool.pronunciation") else { return false }
        let intent = reserveForegroundIntent(preservingExistingOrigin: true)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else { return false }
        setQuickText("")
        setQuickProvenance(nil)
        return showEphemeralTool(.pronunciation, input: term, notice: nil, provenance: nil)
    }

    /// A pad-local /express passes its literal tail to the disposable panel.
    @discardableResult
    public func beginExpress(text: String) -> Bool {
        guard canInvoke("tool.express") else { return false }
        let intent = reserveForegroundIntent(preservingExistingOrigin: true)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else { return false }
        setQuickText("")
        setQuickProvenance(nil)
        return showEphemeralTool(.express, input: text, notice: nil, provenance: nil)
    }

    /// Tab on an exact pad abbreviation (quick-launch §1.2): the pad becomes the tool in its
    /// own frame, as a Hyper key replaces one tool with another. The pad's
    /// focus origin stays and nothing is recaptured. The chip travels; a tool
    /// whose hotkey reads the selection also receives the text it describes.
    @discardableResult
    public func beginQuickLaunch(_ kind: OmniEphemeralToolKind) -> Bool {
        guard canInvoke("tool.\(kind.descriptor.id)") else { return false }
        let anchor = quickPanel
        // Recall's own hotkey never reads the selection, and it has no chip.
        if kind == .recall { return beginRecall(intent: "", anchor: anchor) }
        // The stack is its own material; the pad's chip and text do not travel.
        if kind == .stash { return beginStash(anchor: anchor, fromPad: true) }
        // Ratio opens on the reference without importing the pad's chip or text.
        if kind == .ratio { return beginRatio(input: "", anchor: anchor) }
        if kind == .weather { return beginWeather(input: "", anchor: anchor) }
        if kind == .qr {
            let provenance = quickPadController.provenance
            let selection = provenance == nil ? "" : (quickSelectionText ?? "")
            return beginQR(input: selection, anchor: anchor, provenance: provenance)
        }
        if kind == .regex {
            let provenance = quickPadController.provenance
            let selection = provenance == nil ? nil : quickSelectionText
            return beginRegex(input: selection ?? "", selection: selection, anchor: anchor, provenance: provenance)
        }
        if kind == .map {
            let provenance = quickPadController.provenance
            let selection = provenance == nil ? "" : (quickSelectionText ?? "")
            return beginMap(input: selection, anchor: anchor, provenance: provenance)
        }
        let intent = reserveForegroundIntent(preservingExistingOrigin: true)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else { return false }
        let provenance = quickPadController.provenance
        let selection = provenance == nil ? "" : (quickSelectionText ?? "")
        setQuickText("")
        setQuickProvenance(nil)
        // Emoji starts empty on the frequent set; its chip names where it inserts.
        if kind == .emoji { return showEmojiTool(provenance: provenance, reusing: anchor) }
        if kind == .characters { return showCharactersTool(input: "", provenance: provenance, reusing: anchor) }
        return showEphemeralTool(kind, input: selection, notice: nil, provenance: provenance, reusing: anchor)
    }

    /// Emoji outside the pad (no hotkey is bound): the origin is the app in
    /// front, read now; switching from another tool keeps that tool's origin.
    @discardableResult
    public func beginEmoji() -> Bool {
        guard canInvoke("tool.emoji") else { return false }
        let previousTool = ephemeralTool.flatMap { $0.isVisible ? $0 : nil }
        let previousCharacters = charactersTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRecall = recallTool.flatMap { $0.isVisible ? $0 : nil }
        let previousStash = stashTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRatio = ratioTool.flatMap { $0.isVisible ? $0 : nil }
        let previousMap = mapTool.flatMap { $0.isVisible ? $0 : nil }
        let previousWeather = weatherTool.flatMap { $0.isVisible ? $0 : nil }
        let previousQR = qrTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRegex = regexTool.flatMap { $0.isVisible ? $0 : nil }
        let carriedProvenance = previousCharacters?.viewController.provenance ?? previousTool?.viewController.provenance ?? previousMap?.viewController.provenance
        let reusedPanel = relinquishVisibleToolPanel()
        if previousCharacters == nil && previousTool == nil && previousRecall == nil && previousStash == nil && previousRatio == nil && previousMap == nil && previousWeather == nil && previousQR == nil && previousRegex == nil {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        }
        let intent = reserveForegroundIntent()
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else {
            reusedPanel?.orderOut(nil)
            return false
        }
        return showEmojiTool(provenance: carriedProvenance, reusing: reusedPanel)
    }

    private func showEmojiTool(provenance: OmniPadProvenance?, reusing reusedPanel: NSPanel?) -> Bool {
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniEmojiWindowController(session: emojiSessionFactory(), presentsInterface: presentsInterface)
        tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.emoji")
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        tool.onCopy = { [weak self, weak tool] entry in
            guard let self, let tool else { return }
            self.countEmojiPick(entry, in: tool)
            self.pasteboardWriter(tool.session.skinTone.apply(to: entry.emoji))
        }
        // A freed tool's identifier can be reused by this one.
        countedEmojiPick = nil
        emojiTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(provenance: provenance, reusing: reusedPanel)
        return true
    }

    /// The last emoji counted toward the frequent set, per open tool.
    private var countedEmojiPick: (tool: ObjectIdentifier, emoji: String)?

    /// Enter copies and closes (quick-launch §2.4); ⌘C copies and stays.
    /// A pick counts once per open tool and emoji, however it is repeated.
    private func countEmojiPick(_ entry: EmojiEntry, in tool: OmniEmojiWindowController) {
        let key = (tool: ObjectIdentifier(tool), emoji: entry.emoji)
        if let counted = countedEmojiPick, counted == key { return }
        countedEmojiPick = key
        tool.session.recordPick(entry)
    }

    /// Characters keeps the same disposable panel and external target as Emoji.
    /// Bare /char and ch+Tab start on the independent frequent set.
    @discardableResult
    public func beginCharacters(input explicitInput: String? = nil, anchor: NSPanel? = nil) -> Bool {
        guard canInvoke("tool.characters") else { return false }
        let previousTool = ephemeralTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRecall = recallTool.flatMap { $0.isVisible ? $0 : nil }
        let previousEmoji = emojiTool.flatMap { $0.isVisible ? $0 : nil }
        let previousCharacters = charactersTool.flatMap { $0.isVisible ? $0 : nil }
        let previousStash = stashTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRatio = ratioTool.flatMap { $0.isVisible ? $0 : nil }
        let previousMap = mapTool.flatMap { $0.isVisible ? $0 : nil }
        let previousWeather = weatherTool.flatMap { $0.isVisible ? $0 : nil }
        let previousQR = qrTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRegex = regexTool.flatMap { $0.isVisible ? $0 : nil }
        let provenance = previousTool?.viewController.provenance ?? previousCharacters?.viewController.provenance
            ?? previousEmoji?.viewController.provenance ?? previousMap?.viewController.provenance
        let reusedPanel = relinquishVisibleToolPanel()
        if previousTool == nil && previousRecall == nil && previousEmoji == nil && previousCharacters == nil
            && previousStash == nil && previousRatio == nil && previousMap == nil && previousWeather == nil && previousQR == nil && previousRegex == nil && explicitInput == nil && anchor == nil {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        }
        let intent = reserveForegroundIntent(preservingExistingOrigin: explicitInput != nil || anchor != nil)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else { reusedPanel?.orderOut(nil); return false }
        setQuickText("")
        setQuickProvenance(nil)
        return showCharactersTool(input: explicitInput ?? "", provenance: provenance, reusing: reusedPanel ?? anchor)
    }

    private var countedCharacterPick: (tool: ObjectIdentifier, scalar: UInt32)?

    private func showCharactersTool(input: String, provenance: OmniPadProvenance?, reusing panel: NSPanel?) -> Bool {
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniCharactersWindowController(session: charactersSessionFactory(), presentsInterface: presentsInterface)
        tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.characters")
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self, weak tool] in
            guard let self, let tool, self.charactersTool === tool,
                  self.charactersInsertInFlight != ObjectIdentifier(tool) else { return }
            self.dismissEphemeralTool(restoreFocus: false)
        }
        tool.onCopy = { [weak self, weak tool] entry, text in
            guard let self, let tool else { return }
            self.countCharacterPick(entry, in: tool)
            self.pasteboardWriter(text)
        }
        tool.onInsert = { [weak self, weak tool] entry, text in
            guard let self, let tool else { return }
            Task { await self.insertCharacter(entry, text: text, from: tool) }
        }
        countedCharacterPick = nil
        lastInsertionNotice = nil
        charactersTarget = PasteTarget(focusOrigin.capturedProcessID)
        charactersTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(input: input, provenance: provenance, reusing: panel)
        return true
    }

    private func countCharacterPick(_ entry: CharacterEntry, in tool: OmniCharactersWindowController) {
        let key = (tool: ObjectIdentifier(tool), scalar: entry.scalar)
        if let counted = countedCharacterPick, counted == key { return }
        countedCharacterPick = key
        tool.session.recordPick(entry)
    }

    private func insertCharacter(_ entry: CharacterEntry, text: String, from tool: OmniCharactersWindowController) async {
        let toolID = ObjectIdentifier(tool)
        guard charactersTool === tool, charactersInsertInFlight != toolID,
              tool.session.selectedEntry?.scalar == entry.scalar, tool.session.selectedText == text else { return }
        charactersInsertInFlight = toolID
        defer { if charactersInsertInFlight == toolID { charactersInsertInFlight = nil } }
        let generation = sharedForeground.generation
        let revision = interactionRevision
        let outcome = await characterInsert(text, charactersTarget,
            { tool.hideForInsert() },
            { self.characterWriter(text) },
            { self.charactersTool === tool && tool.session.selectedText == text && self.interactionRevision == revision
                && self.sharedForeground.isCurrent(overlay: "omni-ephemeral", generation: generation) })
        guard charactersTool === tool else { return }
        switch outcome {
        case .inserted:
            countCharacterPick(entry, in: tool)
            dismissEphemeralTool(restoreFocus: false)
        case .copied(let reason):
            countCharacterPick(entry, in: tool)
            dismissEphemeralTool(restoreFocus: true)
            lastInsertionNotice = reason
            onInsertionNotice?(reason)
        case .cancelled:
            dismissEphemeralTool(restoreFocus: false)
        }
    }

    /// Recall opens the deterministic sheet without capturing the external selection.
    /// Explicit /recall supplies literal intent; switching tools can carry a field.
    @discardableResult
    public func beginRecall(intent explicitIntent: String? = nil, anchor: NSPanel? = nil) -> Bool {
        guard canInvoke("tool.recall") else { return false }
        let previous = ephemeralTool.flatMap { $0.isVisible ? $0 : nil }
        let previousEmoji = emojiTool.flatMap { $0.isVisible ? $0 : nil }
        let previousCharacters = charactersTool.flatMap { $0.isVisible ? $0 : nil }
        let previousStash = stashTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRatio = ratioTool.flatMap { $0.isVisible ? $0 : nil }
        let previousMap = mapTool.flatMap { $0.isVisible ? $0 : nil }
        let previousWeather = weatherTool.flatMap { $0.isVisible ? $0 : nil }
        let previousQR = qrTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRegex = regexTool.flatMap { $0.isVisible ? $0 : nil }
        let input = explicitIntent ?? previous?.session.input ?? previousCharacters?.session.input ?? previousEmoji?.session.input ?? previousMap?.session.input ?? ""
        let reusedPanel = relinquishVisibleToolPanel()
        if previous == nil && previousCharacters == nil && previousEmoji == nil && previousStash == nil && previousRatio == nil && previousMap == nil && previousWeather == nil && previousQR == nil && previousRegex == nil && explicitIntent == nil {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        }
        let intent = reserveForegroundIntent(preservingExistingOrigin: explicitIntent != nil || anchor != nil)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else {
            reusedPanel?.orderOut(nil)
            return false
        }
        if explicitIntent != nil {
            setQuickText("")
            setQuickProvenance(nil)
        }
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniRecallWindowController(session: recallSessionFactory(), presentsInterface: presentsInterface)
        tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.recall")
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        tool.onCopy = { [weak self] text in self?.pasteboardWriter(text) }
        recallTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(input: input, reusing: reusedPanel ?? anchor)
        return true
    }

    /// The stack view (C93): the hotkey reads the app in front as the paste
    /// target; `st` + Tab keeps the pad's; switching from another tool keeps
    /// that tool's. Nothing is captured from the selection: the stack is the
    /// material.
    @discardableResult
    public func beginStash(anchor: NSPanel? = nil, fromPad: Bool = false) -> Bool {
        guard canInvoke("tool.stash") else { return false }
        flushStashEdits()
        let previousTool = ephemeralTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRecall = recallTool.flatMap { $0.isVisible ? $0 : nil }
        let previousEmoji = emojiTool.flatMap { $0.isVisible ? $0 : nil }
        let previousCharacters = charactersTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRatio = ratioTool.flatMap { $0.isVisible ? $0 : nil }
        let previousMap = mapTool.flatMap { $0.isVisible ? $0 : nil }
        let previousWeather = weatherTool.flatMap { $0.isVisible ? $0 : nil }
        let previousQR = qrTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRegex = regexTool.flatMap { $0.isVisible ? $0 : nil }
        let reusedPanel = relinquishVisibleToolPanel()
        if previousTool == nil && previousRecall == nil && previousCharacters == nil && previousEmoji == nil && previousRatio == nil && previousMap == nil && previousWeather == nil && previousQR == nil && previousRegex == nil && !fromPad {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        }
        let intent = reserveForegroundIntent(preservingExistingOrigin: fromPad || anchor != nil)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else {
            reusedPanel?.orderOut(nil)
            return false
        }
        if fromPad {
            setQuickText("")
            setQuickProvenance(nil)
        }
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniStashWindowController(session: OmniStashSession(stack: environment.stashStack), presentsInterface: presentsInterface)
        tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.stash")
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        tool.onPaste = { [weak self, weak tool] entry in
            guard let self, let tool else { return }
            Task { await self.pasteStashEntry(entry, from: tool) }
        }
        tool.onPastePlain = { [weak self, weak tool] entry in
            guard let self, let tool else { return }
            Task { await self.pasteStashEntry(entry, from: tool, plainText: true) }
        }
        tool.onCopyOnly = { [weak self] entry in
            guard let self else { return }
            _ = self.stashWriter(entry, false)
            self.dismissEphemeralTool(restoreFocus: true)
        }
        tool.onEdit = { [weak self] entry in self?.openStashInWorkspace(entryID: entry.id) }
        stashTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(reusing: reusedPanel ?? anchor)
        return true
    }

    /// Ratio (C117) opens on the reference. Explicit /ratio supplies the
    /// field and keeps the pad's origin; another tool's field never travels.
    @discardableResult
    public func beginRatio(input explicitInput: String? = nil, anchor: NSPanel? = nil) -> Bool {
        guard canInvoke("tool.ratio") else { return false }
        let previousTool = ephemeralTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRecall = recallTool.flatMap { $0.isVisible ? $0 : nil }
        let previousEmoji = emojiTool.flatMap { $0.isVisible ? $0 : nil }
        let previousCharacters = charactersTool.flatMap { $0.isVisible ? $0 : nil }
        let previousStash = stashTool.flatMap { $0.isVisible ? $0 : nil }
        let previousMap = mapTool.flatMap { $0.isVisible ? $0 : nil }
        let previousWeather = weatherTool.flatMap { $0.isVisible ? $0 : nil }
        let previousQR = qrTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRegex = regexTool.flatMap { $0.isVisible ? $0 : nil }
        let reusedPanel = relinquishVisibleToolPanel()
        if previousTool == nil && previousRecall == nil && previousCharacters == nil && previousEmoji == nil && previousStash == nil && previousMap == nil && previousWeather == nil && previousQR == nil && previousRegex == nil && explicitInput == nil {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        }
        let intent = reserveForegroundIntent(preservingExistingOrigin: explicitInput != nil || anchor != nil)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else {
            reusedPanel?.orderOut(nil)
            return false
        }
        if explicitInput != nil {
            setQuickText("")
            setQuickProvenance(nil)
        }
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniRatioWindowController(session: OmniRatioSession(tables: try? RatioTables.shared.get()),
                                             presentsInterface: presentsInterface)
        tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.ratio")
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        tool.onCopy = { [weak self] text in self?.pasteboardWriter(text) }
        ratioTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(input: explicitInput ?? "", reusing: reusedPanel ?? anchor)
        return true
    }

    /// Map consumes a literal /map question or opens its form chooser. Switching
    /// from another question tool carries its current field without AX recapture.
    @discardableResult
    public func beginMap(input explicitInput: String? = nil, anchor: NSPanel? = nil,
                         provenance explicitProvenance: OmniPadProvenance? = nil) -> Bool {
        guard canInvoke("tool.map") else { return false }
        let previousTool = ephemeralTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRecall = recallTool.flatMap { $0.isVisible ? $0 : nil }
        let previousEmoji = emojiTool.flatMap { $0.isVisible ? $0 : nil }
        let previousCharacters = charactersTool.flatMap { $0.isVisible ? $0 : nil }
        let previousStash = stashTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRatio = ratioTool.flatMap { $0.isVisible ? $0 : nil }
        let previousMap = mapTool.flatMap { $0.isVisible ? $0 : nil }
        let previousWeather = weatherTool.flatMap { $0.isVisible ? $0 : nil }
        let previousQR = qrTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRegex = regexTool.flatMap { $0.isVisible ? $0 : nil }
        let input = explicitInput ?? previousTool?.session.input ?? previousRecall?.session.input
            ?? previousCharacters?.session.input ?? previousEmoji?.session.input ?? previousMap?.session.input ?? ""
        let provenance = explicitProvenance ?? previousTool?.viewController.provenance ?? previousCharacters?.viewController.provenance ?? previousEmoji?.viewController.provenance
            ?? previousMap?.viewController.provenance
        let reusedPanel = relinquishVisibleToolPanel()
        if previousTool == nil && previousRecall == nil && previousCharacters == nil && previousEmoji == nil && previousStash == nil
            && previousRatio == nil && previousMap == nil && previousWeather == nil && previousQR == nil && previousRegex == nil && explicitInput == nil && anchor == nil {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        }
        let intent = reserveForegroundIntent(preservingExistingOrigin: explicitInput != nil || anchor != nil)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else {
            reusedPanel?.orderOut(nil)
            return false
        }
        if explicitInput != nil {
            setQuickText("")
            setQuickProvenance(nil)
        }
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniMapWindowController(producer: mapProducer, presentsInterface: presentsInterface,
                                           automaticRequestsEnabled: { [environment] in
            environment.automaticRequestsEnabled("tool.map")
        })
        tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.map")
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        mapTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(input: input, notice: nil, provenance: provenance, reusing: reusedPanel ?? anchor)
        return true
    }

    /// Weather's place is independent of every other tool field. A bare route
    /// starts with "here"; an explicit slash route keeps only its literal tail.
    @discardableResult
    public func beginWeather(input explicitInput: String? = nil, anchor: NSPanel? = nil) -> Bool {
        guard canInvoke("tool.weather") else { return false }
        let previousTool = ephemeralTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRecall = recallTool.flatMap { $0.isVisible ? $0 : nil }
        let previousEmoji = emojiTool.flatMap { $0.isVisible ? $0 : nil }
        let previousCharacters = charactersTool.flatMap { $0.isVisible ? $0 : nil }
        let previousStash = stashTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRatio = ratioTool.flatMap { $0.isVisible ? $0 : nil }
        let previousMap = mapTool.flatMap { $0.isVisible ? $0 : nil }
        let previousWeather = weatherTool.flatMap { $0.isVisible ? $0 : nil }
        let previousQR = qrTool.flatMap { $0.isVisible ? $0 : nil }
        let previousRegex = regexTool.flatMap { $0.isVisible ? $0 : nil }
        let reusedPanel = relinquishVisibleToolPanel()
        if previousTool == nil && previousRecall == nil && previousEmoji == nil && previousCharacters == nil
            && previousStash == nil && previousRatio == nil && previousMap == nil && previousWeather == nil && previousQR == nil && previousRegex == nil
            && explicitInput == nil && anchor == nil {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        }
        let intent = reserveForegroundIntent(preservingExistingOrigin: explicitInput != nil || anchor != nil)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else { reusedPanel?.orderOut(nil); return false }
        if explicitInput != nil {
            setQuickText("")
            setQuickProvenance(nil)
        }
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniWeatherWindowController(session: weatherSessionFactory(), presentsInterface: presentsInterface)
        tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.weather")
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        tool.onCopy = { [weak self] text in self?.pasteboardWriter(text) }
        weatherTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(input: explicitInput ?? "", reusing: reusedPanel ?? anchor)
        return true
    }

    /// QR consumes a literal slash payload or an already captured selection.
    /// This synchronous route never reads a clipboard or captures text itself.
    @discardableResult
    public func beginQR(input explicitInput: String? = nil, anchor: NSPanel? = nil,
                        provenance: OmniPadProvenance? = nil) -> Bool {
        guard canInvoke("tool.qr") else { return false }
        let hadVisibleTool = isEphemeralToolVisible
        let reusedPanel = relinquishVisibleToolPanel()
        if !hadVisibleTool && explicitInput == nil && anchor == nil {
            focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        }
        let intent = reserveForegroundIntent(preservingExistingOrigin: explicitInput != nil || anchor != nil)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else { reusedPanel?.orderOut(nil); return false }
        if explicitInput != nil {
            setQuickText("")
            setQuickProvenance(nil)
        }
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniQRWindowController(presentsInterface: presentsInterface)
        tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.qr")
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        if let qrPasteboardWriter { tool.writePasteboardItem = qrPasteboardWriter }
        qrTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(input: explicitInput ?? "", provenance: provenance, reusing: reusedPanel ?? anchor)
        return true
    }

    /// Regex keeps its field separate from the selection it tests. A slash
    /// payload is literal; its provenance chip can still supply match lines.
    @discardableResult
    public func beginRegex(input explicitInput: String? = nil, selection: String? = nil,
                           anchor: NSPanel? = nil, provenance: OmniPadProvenance? = nil) -> Bool {
        guard canInvoke("tool.regex") else { return false }
        let reusedPanel = relinquishVisibleToolPanel()
        let intent = reserveForegroundIntent(preservingExistingOrigin: explicitInput != nil || anchor != nil)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else { reusedPanel?.orderOut(nil); return false }
        if explicitInput != nil {
            setQuickText("")
            setQuickProvenance(nil)
        }
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniRegexWindowController(session: regexSessionFactory(), presentsInterface: presentsInterface)
        tool.viewController.toolPill.shortcutLabel = environment.shortcutLabel("tool.regex")
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        tool.onCopy = { [weak self] pattern in self?.pasteboardWriter(pattern) }
        regexTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(input: explicitInput ?? "", selection: selection, provenance: provenance,
                  reusing: reusedPanel ?? anchor)
        return true
    }

    private func beginRegexFromSelection() async -> Bool {
        if isQuickPadVisible {
            let provenance = quickPadController.provenance
            let selection = provenance == nil ? nil : quickSelectionText
            return beginRegex(input: selection ?? "", selection: selection,
                              anchor: quickPanel, provenance: provenance)
        }
        let hadVisibleTool = isEphemeralToolVisible
        if hadVisibleTool { return beginRegex(input: "") }
        focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        let intent = reserveForegroundIntent()
        let capture = await selectionCapture.captureCurrentSelection(
            excludingPID: ProcessInfo.processInfo.processIdentifier)
        guard isCurrent(intent), !isQuitting else { return false }
        if case .unavailable(.foregroundChanged) = capture { return false }
        switch capture {
        case .selected(let selection):
            let provenance = OmniPadProvenance(
                source: selection.appName ?? "Selection", detail: selection.windowTitle,
                wordCount: selection.text.split(whereSeparator: \.isWhitespace).count,
                bundleIdentifier: selection.bundleIdentifier)
            return beginRegex(input: selection.text, selection: selection.text,
                              provenance: provenance)
        case .empty, .unavailable:
            return beginRegex(input: "")
        }
    }

    /// ↩ applies the entry where the tool was opened from (C94): Clipboard's
    /// targeted paste, then close. The entry stays on the stack (paste is
    /// apply, not pop). Without a paste target or Accessibility the entry is
    /// copied instead, so ⌘V still works wherever focus lands.
    private func pasteStashEntry(_ entry: OmniStashEntry, from tool: OmniStashWindowController, plainText: Bool = false) async {
        let toolID = ObjectIdentifier(tool)
        guard stashTool === tool, stashPasteInFlight != toolID else { return }
        // Returning to the target deactivates Omni; that is the paste, not a
        // click away, so resigning active must not close the tool mid-chain.
        stashPasteInFlight = toolID
        defer { if stashPasteInFlight == toolID { stashPasteInFlight = nil } }
        let generation = sharedForeground.generation
        let target = PasteTarget(focusOrigin.capturedProcessID)
        let failure = await stashPaste(
            target,
            { tool.hideForPaste() },
            { self.stashWriter(entry, plainText) },
            { self.stashTool === tool && self.sharedForeground.isCurrent(overlay: "omni-ephemeral", generation: generation) }
        )
        // Replaced by another surface: that request owns the foreground now.
        guard stashTool === tool else { return }
        switch failure {
        case nil:
            dismissEphemeralTool(restoreFocus: false)
        case .superseded?:
            // Still this tool's turn, so the target itself went away mid-paste.
            _ = stashWriter(entry, plainText)
            dismissEphemeralTool(restoreFocus: false)
        case let failure?:
            _ = stashWriter(entry, plainText)
            dismissEphemeralTool(restoreFocus: !failure.surfaceHidden)
        }
    }

    private func showEphemeralTool(
        _ kind: OmniEphemeralToolKind, input: String, notice: String?,
        provenance: OmniPadProvenance?, reusing reusedPanel: NSPanel? = nil
    ) -> Bool {
        guard !isQuitting, canInvoke("tool.\(kind.descriptor.id)") else {
            reusedPanel?.orderOut(nil)
            return false
        }
        // Preserve ordinary Omni drafts through their existing close path;
        // no ephemeral text is ever assigned to those editors or stores.
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        var descriptor = kind.descriptor
        descriptor.shortcutLabel = environment.shortcutLabel("tool.\(descriptor.id)")
        let tool = OmniEphemeralWindowController(
            descriptor: descriptor,
            producer: ephemeralProducers[kind] ?? OmniEphemeralTools.producer(for: kind, environment: environment),
            presentsInterface: presentsInterface,
            automaticRequestsEnabled: { [environment] in
                environment.automaticRequestsEnabled("tool.\(kind.descriptor.id)")
            }
        )
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        tool.onCopy = { [weak self] text in self?.pasteboardWriter(text) }
        ephemeralTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(
            input: input, notice: notice, provenance: provenance, reusing: reusedPanel,
            submitImmediately: kind == .pronunciation && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        return true
    }

    /// A compiled contributor tool uses the same disposable text session as
    /// built-ins. The caller supplies any approved selection; this entry point
    /// never discovers clipboard contents or loads executable plugins.
    @discardableResult
    public func beginContributedTool(descriptor: OmniEphemeralToolDescriptor,
                                     producer: @escaping OmniEphemeralProducer,
                                     input: String? = nil) -> Bool {
        let actionID = "tool.\(descriptor.id)"
        guard canInvoke(actionID), descriptor.resultStyle == .plain,
              descriptor.interaction == .liveCopy else { return false }
        let fromPad = isQuickPadVisible
        let provenance = fromPad ? quickPadController.provenance : nil
        let approvedSelection = provenance == nil ? nil : quickSelectionText
        if !fromPad { focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier) }
        let reusedPanel = relinquishVisibleToolPanel()
        dismissEphemeralTool(restoreFocus: false)
        let intent = reserveForegroundIntent(preservingExistingOrigin: fromPad)
        beforeOmniForeground?()
        guard isCurrent(intent), !isQuitting else {
            reusedPanel?.orderOut(nil)
            return false
        }
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        var effectiveDescriptor = descriptor
        effectiveDescriptor.shortcutLabel = environment.shortcutLabel(actionID)
        let tool = OmniEphemeralWindowController(
            descriptor: effectiveDescriptor, producer: producer,
            presentsInterface: presentsInterface,
            automaticRequestsEnabled: { [environment] in environment.automaticRequestsEnabled(actionID) }
        )
        tool.onCloseRequested = { [weak self] in self?.dismissEphemeralTool(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissEphemeralTool(restoreFocus: false) }
        tool.onCopy = { [weak self] text in self?.pasteboardWriter(text) }
        ephemeralTool = tool
        _ = sharedForeground.show("omni-ephemeral")
        tool.show(input: input ?? approvedSelection ?? "", provenance: provenance,
                  reusing: reusedPanel)
        return true
    }

    /// Opens a fresh explicit-save capture. External selection is read before
    /// Omni activates; a newer foreground request invalidates a delayed read.
    @discardableResult
    public func beginCapture() async -> Bool {
        guard canInvoke("capture.new") else { return false }
        let intent = reserveForegroundIntent()
        beforeOmniForeground?()
        guard canInvoke("capture.new"), isCurrent(intent), !isQuitting else { return false }
        focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        let capture = await selectionCapture.captureCurrentSelection(
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
        guard canInvoke("capture.new"), isCurrent(intent), !isQuitting else { return false }
        if case .unavailable(.foregroundChanged) = capture { return false }
        let input: String
        let notice: String?
        let provenance: OmniPadProvenance?
        switch capture {
        case .selected(let selection):
            input = selection.text
            notice = nil
            provenance = OmniPadProvenance(
                source: selection.appName ?? "Selection", detail: selection.windowTitle,
                wordCount: selection.text.split(whereSeparator: \.isWhitespace).count,
                bundleIdentifier: selection.bundleIdentifier
            )
        case .empty:
            input = ""
            notice = nil
            provenance = nil
        case .unavailable(let reason):
            input = ""
            notice = Self.unavailableNotice(reason)
            provenance = nil
        }
        dismissQuickPad(restoreFocus: false)
        saveActiveComposerDraft()
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        let tool = OmniCaptureWindowController(presentsInterface: presentsInterface)
        tool.onCloseRequested = { [weak self] in self?.dismissCapture(restoreFocus: true) }
        tool.onFocusLost = { [weak self] in self?.dismissCapture(restoreFocus: false) }
        tool.onSaveRequested = { [weak self, weak tool] in
            guard let self, let tool else { return }
            Task { await self.saveCapture(from: tool) }
        }
        captureTool = tool
        _ = sharedForeground.show("omni-capture")
        tool.show(input: input, notice: notice, provenance: provenance)
        return true
    }

    public var isCaptureVisible: Bool { captureTool?.isVisible == true }

    public func dismissCapture(restoreFocus: Bool) {
        captureRevision += 1
        interactionRevision += 1
        guard let tool = captureTool else { return }
        captureTool = nil
        tool.dismiss()
        if sharedForeground.activeOverlay == "omni-capture" { _ = sharedForeground.close() }
        if restoreFocus { restoreOrigin() }
    }

    private func saveCapture(from tool: OmniCaptureWindowController) async {
        guard captureTool === tool, tool.session.beginSave() else { return }
        let text = tool.session.input
        let provenance = tool.viewController.provenance.map {
            OmniRunProvenance(appName: $0.source, windowTitle: $0.detail,
                              wordCount: $0.wordCount, bundleIdentifier: $0.bundleIdentifier)
        }
        do {
            let submission = try await environment.service.submitCapture(text, provenance: provenance)
            guard let runID = submission.runID else {
                if captureTool === tool { tool.session.finishSave(admitted: true, notice: "Save not confirmed. Check Runs before capturing again.") }
                return
            }
            let receipt = try await environment.service.waitForTerminal(runID: runID, timeout: .seconds(30))
            // Recent runs is the existing confirmation/history path. It stays
            // current even if the capture panel was closed while the owner ran.
            try? await refreshResults(orderWindows: false)
            guard captureTool === tool else { return }
            if receipt.state == .succeeded {
                dismissCapture(restoreFocus: true)
            } else {
                tool.session.finishSave(admitted: true, notice: "Save failed. Check Runs before capturing again. (\(runID.rawValue))")
            }
        } catch {
            try? await refreshResults(orderWindows: false)
            guard captureTool === tool else { return }
            tool.session.finishSave(admitted: true, notice: "Save not confirmed. Check Runs before capturing again. (\(error))")
        }
    }

    public var isEphemeralToolVisible: Bool {
        ephemeralTool?.isVisible == true || recallTool?.isVisible == true || emojiTool?.isVisible == true
            || stashTool?.isVisible == true || ratioTool?.isVisible == true || mapTool?.isVisible == true || charactersTool?.isVisible == true || weatherTool?.isVisible == true || qrTool?.isVisible == true || regexTool?.isVisible == true
    }
    public var visibleEphemeralToolID: String? {
        if recallTool?.isVisible == true { return OmniEphemeralToolKind.recall.descriptor.id }
        if charactersTool?.isVisible == true { return OmniEphemeralToolKind.characters.descriptor.id }
        if emojiTool?.isVisible == true { return OmniEphemeralToolKind.emoji.descriptor.id }
        if stashTool?.isVisible == true { return OmniEphemeralToolKind.stash.descriptor.id }
        if ratioTool?.isVisible == true { return OmniEphemeralToolKind.ratio.descriptor.id }
        if mapTool?.isVisible == true { return OmniEphemeralToolKind.map.descriptor.id }
        if weatherTool?.isVisible == true { return OmniEphemeralToolKind.weather.descriptor.id }
        if qrTool?.isVisible == true { return OmniEphemeralToolKind.qr.descriptor.id }
        if regexTool?.isVisible == true { return OmniEphemeralToolKind.regex.descriptor.id }
        return ephemeralTool?.isVisible == true ? ephemeralTool?.session.descriptor.id : nil
    }

    public func dismissEphemeralTool(restoreFocus: Bool) {
        captureRevision += 1
        interactionRevision += 1
        guard ephemeralTool != nil || recallTool != nil || emojiTool != nil || stashTool != nil || ratioTool != nil || mapTool != nil || charactersTool != nil || weatherTool != nil || qrTool != nil || regexTool != nil else { return }
        let tool = ephemeralTool
        let recall = recallTool
        let emoji = emojiTool
        let characters = charactersTool
        let stash = stashTool
        let ratio = ratioTool
        let map = mapTool
        let weather = weatherTool
        let qr = qrTool
        let regex = regexTool
        ephemeralTool = nil
        recallTool = nil
        emojiTool = nil
        charactersTool = nil
        charactersTarget = nil
        stashTool = nil
        ratioTool = nil
        mapTool = nil
        weatherTool = nil
        qrTool = nil
        regexTool = nil
        tool?.dismiss()
        recall?.dismiss()
        emoji?.dismiss()
        characters?.dismiss()
        stash?.dismiss()
        ratio?.dismiss()
        map?.dismiss()
        weather?.dismiss()
        qr?.dismiss()
        regex?.dismiss()
        if sharedForeground.activeOverlay == "omni-ephemeral" { _ = sharedForeground.close() }
        if restoreFocus { restoreOrigin() }
    }

    /// Hyper+backslash searches the current external selection through the
    /// ordinary /g owner. Capture never consults the clipboard or an old draft.
    @discardableResult
    public func beginSelectedWebSearch() async -> Bool {
        guard canInvoke("command.g") else { return false }
        let intent = reserveForegroundIntent()
        beforeOmniForeground?()
        guard canInvoke("command.g"), !isQuitting, isCurrent(intent) else { return false }
        focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        let capture = await selectionCapture.captureCurrentSelection(
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
        guard canInvoke("command.g"), !isQuitting, isCurrent(intent) else { return false }
        if case .unavailable(.foregroundChanged) = capture { return false }

        let feedback: String
        switch capture {
        case .selected(let selection) where !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            do {
                _ = try await environment.service.submitGoogleSearch(selection.text, provenance: OmniRunProvenance(
                    appName: selection.appName,
                    windowTitle: selection.windowTitle,
                    wordCount: selection.text.split(whereSeparator: \.isWhitespace).count,
                    bundleIdentifier: selection.bundleIdentifier
                ))
                // The admitted run owns execution even if another chord has
                // since won foreground. Updating Recent runs never takes focus.
                try? await refreshResults(orderWindows: false)
                return true
            } catch {
                feedback = "Unable to search: \(error)"
            }
        case .selected, .empty:
            feedback = "No text selected in front · type a Google query"
        case .unavailable(let reason):
            feedback = Self.unavailableNotice(reason)
        }
        guard canInvoke("command.g"), !isQuitting, isCurrent(intent) else { return false }
        showQuickDraft("/g ", feedback: feedback)
        return true
    }

    private func beginQuickRequest(reservedIntent: ForegroundIntent) async {
        guard !isQuitting, canInvoke("launcher.open"), isCurrent(reservedIntent) else { return }
        beforeOmniForeground?()
        guard !isQuitting, canInvoke("launcher.open"), isCurrent(reservedIntent) else { return }
        Task { [weak self] in
            await self?.notifications.refreshPermission()
        }
        saveActiveComposerDraft()
        // Activation is the launcher's freshness tick (throttled in the service).
        launcher?.refreshIfDue()
        // `/find`'s docs index loads off the main actor, so the facet menu
        // has values by the time Tab asks (D2); it re-reads only on a new
        // index generation.
        if let findIndex = environment.findIndex {
            Task.detached(priority: .utility) { _ = try? findIndex.currentIndex() }
        }
        expireLaunchUndoIfStale()
        let invocation = captureRevision
        focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        let capture = await selectionCapture.captureCurrentSelection(
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
        guard !isQuitting, !Task.isCancelled, canInvoke("launcher.open"), invocation == captureRevision else { return }
        if case .unavailable(.foregroundChanged) = capture { return }

        composerKey = nil
        quickPadController.showCommandEditor()
        // Rows shown before the pad closed may predate an index rebuild.
        quickPadController.refreshLauncherResults()
        switch capture {
        case .selected(let selection):
            importQuickSelection(selection)
        case .empty:
            break
        case .unavailable(let reason):
            quickPadController.showTransientNotice(Self.unavailableNotice(reason))
        }
        workspace.hideWorkspace()
        showQuickPanel()
    }

    /// The resident Hyper host uses this to arbitrate its shared foreground.
    /// An in-flight selection capture is cancelled even before a panel exists.
    public var isQuickPadVisible: Bool { quickPanel?.isVisible == true }
    public var quickPadFrame: NSRect? { quickPanel.flatMap { $0.isVisible ? $0.frame : nil } }
    public var capturedExternalOriginPID: pid_t? { focusOrigin.capturedProcessID }
    /// Host state lines at the top of the status menu (C108: `Collected · N`),
    /// read every time the menu opens. A line with an action is enabled.
    public var statusMenuExtras: (@MainActor () -> [OmniStatusMenuExtra])?

    public var hasForegroundSurface: Bool {
        if isCaptureVisible || isEphemeralToolVisible || isQuickPadVisible || workspace.workspacePanel.isVisible || settingsWindow?.isVisible == true { return true }
        switch foreground.snapshot().foreground {
        case .editing, .attached: return true
        case .hidden, .legacy: return false
        }
    }

    public func dismissQuickPad(restoreFocus: Bool) {
        if let runID = padRunID {
            if case .working = quickPadController.mode {
                detachPadRun(runID)
            } else if quickPadController.mode == .result(runID: runID), quickPadController.result?.kind == .options,
                      !pickingStanceRunIDs.contains(runID) {
                owePositionsArrival(runID)
            }
            padRunID = nil
            padRunShape = nil
            quickPadController.returnToComposing()
        } else if quickPadController.isShowingLocalOptions {
            // The lens picker is local: nothing ran, the text stays.
            quickPadController.returnToComposing()
        }
        captureRevision += 1
        interactionRevision += 1
        quickPadController.endLauncherSession()
        quickPadController.closeAnnotationPanels()
        // A closed pad ends its temporary request. Durable runs and workspace
        // follow-ups have already been handed to their separate owners.
        dropLaunchUndo()
        setQuickText("")
        setQuickProvenance(nil)
        quickPadController.clearModelSelection()
        quickPanel?.orderOut(nil)
        if case .editing = foreground.snapshot().foreground { foreground.closeBeforeSubmission() }
        if restoreFocus { restoreOrigin() }
    }

    /// Replacing Omni with another Hyper surface also hides its workspace and
    /// detaches an attached result. This is safe to call during capture, before
    /// any Omni panel is visible.
    public func dismissOmniForeground(restoreFocus: Bool) {
        dismissEphemeralTool(restoreFocus: false)
        dismissCapture(restoreFocus: false)
        dismissQuickPad(restoreFocus: false)
        workspace.hideWorkspace()
        settingsWindow?.orderOut(nil)
        saveActiveComposerDraft()
        if case .attached = foreground.snapshot().foreground { foreground.detachAttachedResult() }
        if restoreFocus { restoreOrigin() }
    }

    private func restoreOrigin() {
        if let restoreOriginOverride { restoreOriginOverride() }
        else { focusOrigin.restoreOrigin() }
    }

    /// Positions closed unpicked (by esc-less dismissal, a click away or a
    /// new surface) stay reachable: their arrival notification is owed now,
    /// and its Open reopens the pad on them (D6). Without it the only way
    /// back would be a fresh `/stance` call.
    private func owePositionsArrival(_ runID: String) {
        positionsArrivalsOwed.insert(runID)
        // One main-actor turn later: a dismissal that opens the run (⌘↩ to
        // the workspace) marks it opened first, which cancels this.
        Task { @MainActor [weak self] in
            guard let self, self.positionsArrivalsOwed.remove(runID) != nil else { return }
            // Same path as a working close: asks for permission in context.
            self.expectNotification(for: runID, shape: .optionsResult)
            guard let content = self.notificationIfOwed(runID: runID, outcome: .done) else { return }
            await self.deliverOrPark(content)
        }
    }

    private func detachPadRun(_ runID: String) {
        renderedInPadRunIDs.remove(runID)
        let shape = confirmedProposalShapes[runID]?.shape ?? padRunShape ?? shape(ofRun: runID)
        if shape == .proposal { proposalCouriersOwed.insert(runID) }
        expectNotification(for: runID, shape: shape)
        foreground.detachPadRun(runID)
    }

    /// C29: the strip's absence is the signal; the route line says why.
    static func unavailableNotice(_ reason: OmniSelectionUnavailableReason) -> String {
        switch reason {
        case .accessibilityPermissionRequired: "Accessibility permission is needed to read the selection · type or paste instead"
        default: "No text selected in front · type or paste instead"
        }
    }

    /// Presents a caller-supplied draft without consulting the system
    /// selection provider. Visual-study hosts use this for explicit sample
    /// commands while ordinary launcher requests keep the real capture path.
    public func presentQuickDraft(_ text: String, feedback: String) {
        if padRunID != nil || quickPadController.isShowingLocalOptions { dismissQuickPad(restoreFocus: false) }
        _ = reserveForegroundIntent()
        beforeOmniForeground?()
        showQuickDraft(text, feedback: feedback)
    }

    private func showQuickDraft(_ text: String, feedback: String) {
        saveActiveComposerDraft()
        composerKey = nil
        focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        quickPadController.showCommandEditor()
        setQuickProvenance(nil)
        setQuickText(text)
        workspace.hideWorkspace()
        showQuickPanel()
        quickPadController.showTransientNotice(feedback)
    }

    /// Replace, then undo (C27): the selection replaces the field even over an
    /// unsent draft, and the draft goes onto the text view's own undo stack.
    /// Nothing asks before acting; the loss is undoable instead.
    func importQuickSelection(_ selection: CapturedOmniSelection) {
        let editor = quickPadController.editor
        // An imported selection owns ⌘Z (C27); a pending launch undo would
        // otherwise restore an old query under the selection's chip.
        dropLaunchUndo()
        let draft = editor.string
        let replacedDraft = !draft.isEmpty && draft != selection.text
        if draft != selection.text {
            // One ⌘Z restores the whole draft, rewrites included, and the chip
            // that described it: a chip left over the restored draft would
            // make its bare text read as an imported selection.
            editor.undoManager?.beginUndoGrouping()
            registerProvenanceRestore(quickProvenance, selectionText: quickSelectionText)
            let whole = NSRange(location: 0, length: (draft as NSString).length)
            if editor.shouldChangeText(in: whole, replacementString: selection.text) {
                editor.textStorage?.replaceCharacters(in: whole, with: selection.text)
                editor.didChangeText()
            }
            editor.undoManager?.endUndoGrouping()
        }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        setQuickProvenance(OmniRunProvenance(
            appName: selection.appName,
            windowTitle: selection.windowTitle,
            wordCount: selection.text.split(whereSeparator: \.isWhitespace).count,
            bundleIdentifier: selection.bundleIdentifier
        ), selectionText: selection.text)
        if replacedDraft { quickPadController.showTransientNotice("Replaced your unsent draft · ⌘Z restores it") }
    }

    private func setQuickProvenance(_ provenance: OmniRunProvenance?, selectionText: String? = nil) {
        quickProvenance = provenance
        quickSelectionText = provenance == nil ? nil : selectionText
        quickPadController.setProvenance(provenance.map {
            OmniPadProvenance(source: $0.appName ?? "Selection", detail: $0.windowTitle, wordCount: $0.wordCount, bundleIdentifier: $0.bundleIdentifier)
        })
    }

    /// Shared by /cl and the bare cl Tab switch; the installed host owns the picker.
    private func requestClipboardHistory(query: String) {
        guard canInvoke("clipboard.history") else {
            quickPadController.showTransientNotice("Clipboard history is disabled in Settings.")
            return
        }
        guard let open = onClipboardRequested else {
            quickPadController.showTransientNotice("Clipboard history is unavailable in this app.")
            return
        }
        let originPID = focusOrigin.capturedProcessID
        dismissOmniForeground(restoreFocus: false)
        open(query, originPID)
    }

    /// Discards only the local, unsubmitted follow-up for the selected source.
    /// Pending generation cancellation remains a separate service operation.
    public func discardSelectedFollowUpDraft() {
        guard let key = composerKey else { return }
        discardFollowUpDraft(runID: key.runID, sourceVersion: key.sourceVersion)
    }

    public func discardFollowUpDraft(runID: String, sourceVersion: Int) {
        let key = DraftKey(runID: runID, sourceVersion: sourceVersion)
        if let state = followUpStatesByRunID[runID], state.sourceVersion == sourceVersion {
            discardedFollowUpRequestIDs.insert(state.requestID)
            recoveredFollowUpRequestIDs.insert(state.requestID)
        }
        followUpDrafts.removeValue(forKey: key)
        persistFollowUpDrafts()
        if composerKey == key { composerKey = nil }
        interactionRevision += 1
        selectedRunID = key.runID
        selectedVersion = key.sourceVersion
        followsLatestVersion = false
        displayCachedResult(runID: key.runID)
    }

    private func configureCallbacks() {
        quickPadController.onEscape = { [weak self] in
            guard let self else { return }
            if self.quickPadController.result?.kind == .proposal, let runID = self.padRunID {
                self.dismissProposal(runID: runID)
            } else if self.quickPadController.result?.kind == .options, let runID = self.padRunID {
                // A pick in flight owns the surface until its draft is bound.
                guard !self.pickingStanceRunIDs.contains(runID) else { return }
                // The custom path: back to the material to write a note and
                // a command by hand. The stance run stays a complete record.
                Task { await self.returnToMaterial(fromStanceRun: runID) }
            } else { self.dismissQuickPad() }
        }
        quickPadController.onPickOption = { [weak self] runID, index, ticked, gesture in
            // Marked in flight synchronously with the key, before any await:
            // a second digit or an esc in the same turn sees it.
            guard let self, !self.pickingStanceRunIDs.contains(runID) else { return }
            self.pickingStanceRunIDs.insert(runID)
            Task { await self.pickStanceOption(runID: runID, index: index, ticked: ticked, gesture: gesture) }
        }
        quickPadController.onSubmit = { [weak self] text, gesture in
            guard let self else { return }
            let generation = self.foreground.snapshot().uiGeneration
            // Canonical routing may normalize whitespace. Persist and execute
            // the visible field after its alias edits, preserving source layout.
            let visibleText = self.quickPadController.editor.string.isEmpty ? text : self.quickPadController.editor.string
            // The model chevron chooses a one-invocation override; it is consumed here.
            let selectedProfileID = self.quickPadController.selectedModelProfileID
            var annotations = self.quickPadController.annotations
            self.quickPadController.clearModelSelection()
            // `/stash:N` names material (C96): its entry's text stands where
            // the atom stood, and the run's source is the entry's.
            var submitted = visibleText
            var stash: OmniPadStashImport?
            if let found = self.quickPadController.stashImport,
               let composed = OmniStashCommand.replacingImport(found.literal, in: visibleText, with: found.text) {
                submitted = composed.text
                annotations = OmniAnnotationRanges.remap(annotations, replacing: composed.edit, withUTF16Length: composed.replacementLength)
                stash = found
            }
            Task { await self.submitQuick(text: submitted, gesture: gesture, expectedGeneration: generation, selectedProfileID: selectedProfileID, annotations: annotations, visibleDraft: visibleText, stashImport: stash) }
        }
        quickPadController.onRecallRequested = { [weak self] intent in
            _ = self?.beginRecall(intent: intent)
        }
        quickPadController.onRatioRequested = { [weak self] query in
            _ = self?.beginRatio(input: query)
        }
        quickPadController.onCharactersRequested = { [weak self] query in
            _ = self?.beginCharacters(input: query)
        }
        quickPadController.onMapRequested = { [weak self] query in
            _ = self?.beginMap(input: query)
        }
        quickPadController.onWeatherRequested = { [weak self] place in
            _ = self?.beginWeather(input: place)
        }
        quickPadController.onQRRequested = { [weak self] payload in
            _ = self?.beginQR(input: payload)
        }
        quickPadController.onRegexRequested = { [weak self] input in
            guard let self else { return }
            let provenance = self.quickPadController.provenance
            let selection = provenance == nil ? nil : self.quickSelectionText
            _ = self.beginRegex(input: input, selection: selection, provenance: provenance)
        }
        quickPadController.onClipboardRequested = { [weak self] query in
            self?.requestClipboardHistory(query: query)
        }
        quickPadController.onCalculatorCopy = { [weak self] number in
            guard let self else { return }
            self.pasteboardWriter(number)
            self.dismissQuickPad(restoreFocus: true)
        }
        quickPadController.onPronunciationRequested = { [weak self] term in
            _ = self?.beginPronunciation(term: term)
        }
        quickPadController.onExpressRequested = { [weak self] text in
            _ = self?.beginExpress(text: text)
        }
        refreshActionAvailability()
        quickPadController.onQuickLaunch = { [weak self] tool in
            if tool.toolID == "clipboard-history" {
                guard self?.canInvoke("clipboard.history") == true else { return }
                self?.requestClipboardHistory(query: "")
                return
            }
            if let kind = OmniEphemeralToolKind(quickLaunch: tool) {
                _ = self?.beginQuickLaunch(kind)
                return
            }
            guard let self, self.canInvoke("tool.\(tool.toolID)") else { return }
            if self.onContributedQuickLaunch?(tool.toolID) != true {
                self.quickPadController.showTransientNotice("This tool is unavailable in Settings.")
            }
        }
        quickPadController.onContributedSlashRequested = { [weak self] raw in
            guard let self else { return nil }
            return self.onContributedSlash?(raw)
        }
        quickPadController.onClearProvenance = { [weak self] in
            guard let self else { return }
            self.setQuickText("")
            self.setQuickProvenance(nil)
        }
        quickPadController.onConfirmProposal = { [weak self] runID, planHash in
            Task { await self?.confirmProposal(runID: runID, planHash: planHash) }
        }
        quickPadController.onDismissProposal = { [weak self] runID in
            self?.dismissProposal(runID: runID)
        }
        quickPadController.onCopyResult = { [weak self] runID in
            Task { await self?.copyPadResult(runID: runID) }
        }
        quickPadController.onRequestFindFacets = { [weak self] in self?.environment.findIndex?.cachedIndex()?.facets }
        quickPadController.onPickerAction = { [weak self] runID, index, action in
            Task { await self?.performFindRowAction(runID: runID, index: index, action: action) }
        }
        workspace.onPickerAction = { [weak self] runID, index, action in
            Task { await self?.performFindRowAction(runID: runID, index: index, action: action, fromWorkspace: true) }
        }
        quickPadController.onCloseResult = { [weak self] runID in
            guard self?.padRunID == runID else { return }
            self?.dismissQuickPad()
        }
        quickPadController.onOpenResult = { [weak self] runID in
            guard let self, self.padRunID == runID else { return }
            let intent = self.reserveForegroundIntent()
            // Moving the bound run to the workspace is its arrival surface;
            // it must never acquire background notification debt.
            self.padRunID = nil
            self.padRunShape = nil
            self.notifyingRunIDs.remove(runID)
            self.proposalCouriersOwed.remove(runID)
            self.quickPadController.returnToComposing()
            Task { await self.openRun(runID, reservedIntent: intent) }
        }
        quickPadController.onRetryResult = { [weak self] runID in
            Task { await self?.retryPadResult(runID: runID) }
        }
        quickPadController.onOpenSettings = { [weak self] focusModels in
            guard let self else { return }
            let intent = self.reserveForegroundIntent()
            Task { [weak self] in await self?.showSettings(focusModels: focusModels, reservedIntent: intent) }
        }
        quickPadController.onOpenWorkspace = { [weak self] in self?.openWorkspace() }
        if environment.providerRuntime != nil {
            let presenter = ProviderSettingsPresenter(environment: environment)
            quickPadController.onResolveRoute = { [weak self] intent, profileID in
                self?.padRoute(for: intent, profileID: profileID, presenter: presenter)
            }
            invalidateRoutePreviews()
        } else if sampleRepliesRoute {
            quickPadController.onResolveRoute = { [weak self] intent, _ in
                guard let self, let token = intent.dispatchToken,
                      let command = self.environment.service.parser.manifest.command(for: token),
                      command.execution == .modelBacked,
                      ProviderSettingsPresenter.asksModel(command: command, intent: intent) else { return nil }
                return OmniPadRoute(providerName: "Sample replies")
            }
        }
        if let launcher { configureLauncher(launcher) }
        quickPadController.onRequestReferenceChoices = { [weak self] atom in
            guard let self else { return [] }
            let key = atom.hasPrefix("@") ? String(atom.dropFirst()) : atom
            return self.environment.service.parser.references.all.filter { $0.key == key }.map {
                OmniReferenceChoice(
                    id: $0.id,
                    canonicalText: "@\($0.namespace):\($0.key)",
                    label: "\($0.namespace) · \($0.key)"
                )
            }
        }
        notifications.onAction = { [weak self] action, runID in
            guard let self else { return }
            let intent: ForegroundIntent? = switch action {
            case .open, .review: self.reserveForegroundIntent()
            case .copy, .retry: nil
            }
            Task { [weak self] in await self?.handleNotificationAction(action, runID: runID, reservedIntent: intent) }
        }
        workspace.onOpenWorkspace = { [weak self] in self?.openWorkspace() }
        workspace.onOpenRun = { [weak self] runID in
            guard let self else { return }
            let intent = self.reserveForegroundIntent()
            Task { [weak self] in await self?.openRun(runID, reservedIntent: intent) }
        }
        workspace.onNewRequest = { [weak self] in self?.enqueueQuickRequest() }
        workspace.onSelectRun = { [weak self] value in Task { await self?.selectRun(value) } }
        workspace.onSelectVersion = { [weak self] number in self?.selectVersion(number) }
        workspace.onContinue = { [weak self] runID, sourceVersion in
            Task { await self?.beginFollowUp(runID: runID, sourceVersion: sourceVersion) }
        }
        workspace.onSubmit = { [weak self] text, _ in
            guard let self else { return }
            let annotations = self.workspace.annotations
            Task { await self.submitWorkspace(text: text, annotations: annotations) }
        }
        workspace.onAnnotationsChanged = { [weak self] _ in self?.saveActiveComposerDraft() }
        workspace.onComposerTextChanged = { [weak self] _ in self?.saveActiveComposerDraft() }
        workspace.onCancel = { [weak self] runID in Task { await self?.cancelRunOrFollowUp(runID: runID) } }
        workspace.onDiscardDraft = { [weak self] runID, sourceVersion in
            self?.discardFollowUpDraft(runID: runID, sourceVersion: sourceVersion)
        }
        workspace.onCopy = { [weak self] runID, version in self?.copyResult(runID: runID, version: version) }
        workspace.onClose = { [weak self] in self?.workspaceClosed() }
        configureStashCallbacks()
    }

    // MARK: Stash (C42, C92–C97)

    private var stashObserver: NSObjectProtocol?

    /// The stack as last read, for the pad's `/stash:N` lookups: the field
    /// re-reads on every keystroke, the file only on change.
    private var stashSnapshot: [OmniStashEntry] = []

    private func configureStashCallbacks() {
        quickPadController.onResolveStashImport = { [weak self] position in
            guard let self, self.stashSnapshot.indices.contains(position - 1) else { return nil }
            let entry = self.stashSnapshot[position - 1]
            guard !entry.text.isEmpty else { return nil }
            return OmniPadStashImport(position: position, text: entry.text, source: entry.source, lineCount: entry.lineCount)
        }
        workspace.onSelectStash = { [weak self] in self?.stashSelected() }
        workspace.onStashEdited = { [weak self] id, text in self?.scheduleStashEdit(id: id, text: text) }
        workspace.onStashCopy = { [weak self] id in
            self?.flushStashEdits()
            guard let self, let entry = try? self.environment.stashStack?.entries().first(where: { $0.id == id }) else { return }
            _ = self.stashWriter(entry, false)
            self.refreshStash(notice: "Copied · \(Self.stashExcerpt(entry))")
        }
        workspace.onStashDrop = { [weak self] id in self?.dropStashEntry(id: id) }
        workspace.onStashClear = { [weak self] in self?.clearStashFromWorkspace() }
        guard let stack = environment.stashStack else { return }
        stashObserver = NotificationCenter.default.addObserver(forName: OmniStashStack.didChange, object: nil, queue: .main) { [weak self] note in
            let path = note.userInfo?["path"] as? String
            MainActor.assumeIsolated {
                guard path == stack.url.path else { return }
                self?.refreshStash()
            }
        }
        refreshStash()
    }

    /// Edits save silently (C42) but not per keystroke: the last text per
    /// entry is written after a short pause, and before anything else reads
    /// or changes the stack from this host.
    private var pendingStashEdits: [String: String] = [:]
    private var stashEditFlush: Task<Void, Never>?
    static let stashEditDelay: Duration = .milliseconds(400)

    private func scheduleStashEdit(id: String, text: String) {
        pendingStashEdits[id] = text
        stashEditFlush?.cancel()
        stashEditFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.stashEditDelay)
            guard !Task.isCancelled else { return }
            self?.flushStashEdits()
        }
    }

    func flushStashEdits() {
        stashEditFlush?.cancel()
        stashEditFlush = nil
        let edits = pendingStashEdits
        pendingStashEdits = [:]
        guard !edits.isEmpty, let stack = environment.stashStack else { return }
        for (id, text) in edits { _ = try? stack.updateText(id: id, text: text) }
        // A refresh skipped while the edit was pending is owed now.
        refreshStash()
    }

    /// The workspace's view of the stack, top first (C92).
    func refreshStash(notice: String? = nil) {
        // A pending edit is the newest truth for its entry; the store's
        // echo of an older text must not reach the editor.
        guard pendingStashEdits.isEmpty else { return }
        let entries = (try? environment.stashStack?.entries()) ?? []
        stashSnapshot = entries
        let now = Date()
        workspace.displayStash(entries.enumerated().map { index, entry in
            OmniWorkspaceStashEntry(
                id: entry.id,
                token: index == 0 ? OmniStashCommand.token : "\(OmniStashCommand.token):\(index + 1)",
                text: entry.text,
                kind: entry.kind,
                detail: "\(entry.source) · \(OmniRelativeTime.label(for: entry.editedAt ?? entry.createdAt, now: now))",
                isEditable: entry.isEditable,
                imageData: entry.representations.first { OmniStashRepresentation.isImageType($0.type) }?.data
            )
        }, notice: notice)
    }

    private func stashSelected() {
        saveActiveComposerDraft()
        composerKey = nil
        interactionRevision += 1
        selectedRunID = nil
        selectedVersion = nil
        lastDisplayedResult = nil
    }

    /// ⌘↩ Edit in the stack view (C94): the workspace at the stash row, with
    /// that entry's editor focused. The paste target captured at open stays.
    func openStashInWorkspace(entryID: String?) {
        let intent = reserveForegroundIntent()
        beforeOmniForeground?()
        guard isCurrent(intent) else { return }
        saveActiveComposerDraft()
        dismissQuickPad(restoreFocus: false)
        foreground.showOmni()
        stashSelected()
        refreshStash()
        workspace.showStash(focusing: entryID)
        if presentsInterface {
            workspace.showWorkspace()
            NSApplication.shared.activate(ignoringOtherApps: true)
            workspace.stashView.focus(entryID: entryID)
        }
    }

    private func dropStashEntry(id: String) {
        flushStashEdits()
        guard let stack = environment.stashStack, let removed = try? stack.remove(id: id) else { return }
        registerStashUndo { [weak self] in
            let restored = (try? stack.restore(removed.entry, at: removed.index)) == true
            self?.refreshStash(notice: restored ? nil : "The stash is full · \(Self.stashExcerpt(removed.entry)) not restored")
        }
        refreshStash(notice: "Dropped · \(Self.stashExcerpt(removed.entry)) · ⌘Z restores it")
    }

    private func clearStashFromWorkspace() {
        flushStashEdits()
        guard let stack = environment.stashStack, let removed = try? stack.clear(), !removed.isEmpty else { return }
        registerStashUndo { [weak self] in
            let restored = (try? stack.restoreAll(removed)) ?? 0
            let missing = removed.count - restored
            self?.refreshStash(notice: missing == 0 ? nil : "The stash filled since · \(missing) not restored")
        }
        refreshStash(notice: "Cleared · \(removed.count) \(removed.count == 1 ? "entry" : "entries") · ⌘Z restores")
    }

    /// Workspace drop and clear go on the window's undo stack, beside the
    /// entry editors' typing; they hold until Omni quits.
    private func registerStashUndo(_ undo: @escaping @MainActor () -> Void) {
        workspace.workspacePanel.undoManager?.registerUndo(withTarget: self) { _ in
            MainActor.assumeIsolated { undo() }
        }
    }

    nonisolated static func stashExcerpt(_ entry: OmniStashEntry) -> String {
        entry.text.isEmpty ? "Image" : OmniStashText.excerpt(entry.text, limit: 32)
    }

    private func configureStatusItem() {
        // The interface starts in the appearance Settings last saved.
        applyAppearance(preferences.current.appearance)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = makeStatusMenu()
        statusItem = item
        statusPresenter = OmniStatusItemPresenter(statusItem: item, accessibilityLabel: statusItemTitle)
        if ownsApplicationMenu {
            let policy = Self.applicationMenuPolicy(installed: environment.isInstalled)
            NSApplication.shared.mainMenu = makeApplicationMenu(includesEditMenu: policy.includesEditMenu)
        }
    }

    /// Who owns the app's main menu, and whether it carries an Edit menu. One
    /// rule for both hosts, so a silent flag flip (as in f0ffed7, which left the
    /// resident host with no menu and no ⌘W) fails a test.
    public struct ApplicationMenuPolicy: Equatable, Sendable {
        public let ownsMenu: Bool
        public let includesEditMenu: Bool
    }

    public nonisolated static func applicationMenuPolicy(installed: Bool) -> ApplicationMenuPolicy {
        ApplicationMenuPolicy(ownsMenu: true, includesEditMenu: !installed)
    }

    /// The app's main menu. Omni runs as an accessory (LSUIElement) app, so the
    /// menu bar never draws it; it exists because AppKit resolves ⌘W, ⌘Q and
    /// the other standard shortcuts through main-menu key equivalents, and
    /// without it they do nothing in Omni's windows.
    ///
    /// The installed host leaves out the Edit menu: its text views already
    /// handle the editing keys in `keyDown`, guarded so that undo never
    /// changes a locked proposal field or text under IME composition, and a
    /// menu key equivalent would reach the responder chain before that guard.
    func makeApplicationMenu(includesEditMenu: Bool = true) -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: displayName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: displayName)
        addMenuItem("Settings…", key: ",", to: appMenu) { [weak self] in self?.openSettingsFromMenu() }
        appMenu.addItem(.separator())
        addMenuItem(quitTitle, key: "q", to: appMenu) { [weak self] in self?.quitApplication() }
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newCommandItem = addMenuItem("New command", key: "n", to: fileMenu) { [weak self] in
            self?.enqueueQuickRequest()
        }
        newCommandItem.isEnabled = canInvoke("launcher.open")
        newCommandMenuItem = newCommandItem
        addMenuItem("Workspace", key: "1", to: fileMenu) { [weak self] in self?.openWorkspace() }
        addMenuItem("Close", key: "w", to: fileMenu) { [weak self] in self?.closeFrontSurface() }
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        if includesEditMenu {
            // Standard responder-chain editing actions make paste, selection and
            // undo work in real AppKit fields, not just direct test insertions.
            let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            let editMenu = NSMenu(title: "Edit")
            for (title, selector, key) in [
                ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
            ] {
                editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
            }
            editItem.submenu = editMenu
            mainMenu.addItem(editItem)
        }
        // Minimize goes down the responder chain to the key window, so AppKit
        // disables it for the pad and the Settings panel, which cannot miniaturize.
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        return mainMenu
    }

    /// What File → Close (⌘W) closes.
    enum CloseTarget: Equatable, Sendable { case quickPad, settings, workspace, nothing }
    /// The key window as File → Close sees it.
    enum FrontWindow: Equatable, Sendable { case settings, workspace, other, none }

    /// The focused Omni window closes first: Settings opened from the pad keeps
    /// the pad on screen, and ⌘W there means Settings. Otherwise the pad closes
    /// if it is up, since it floats above everything, including when its own
    /// note card or a Hyper overlay holds focus. Any other focused window is
    /// left alone; with no key window, the frontmost visible Omni window closes.
    nonisolated static func closeTarget(quickPadVisible: Bool, front: FrontWindow, settingsVisible: Bool, workspaceVisible: Bool) -> CloseTarget {
        switch front {
        case .settings: return .settings
        case .workspace: return .workspace
        case .other: return quickPadVisible ? .quickPad : .nothing
        case .none:
            if quickPadVisible { return .quickPad }
            return settingsVisible ? .settings : (workspaceVisible ? .workspace : .nothing)
        }
    }

    /// Hosts can own auxiliary windows outside this controller's native surfaces.
    /// Returning true consumes Close for that exact key window.
    public var onCloseHostWindow: (@MainActor (NSWindow) -> Bool)?

    func closeFrontSurface(keyWindow: NSWindow? = NSApplication.shared.keyWindow) {
        if let keyWindow, onCloseHostWindow?(keyWindow) == true { return }
        if isCaptureVisible, keyWindow == nil || keyWindow === captureTool?.panel {
            dismissCapture(restoreFocus: true)
            return
        }
        if isEphemeralToolVisible, keyWindow == nil || keyWindow === ephemeralTool?.panel || keyWindow === recallTool?.panel
            || keyWindow === emojiTool?.panel || keyWindow === stashTool?.panel || keyWindow === ratioTool?.panel
            || keyWindow === mapTool?.panel || keyWindow === charactersTool?.panel || keyWindow === weatherTool?.panel
            || keyWindow === qrTool?.panel || keyWindow === regexTool?.panel {
            dismissEphemeralTool(restoreFocus: true)
            return
        }
        let front: FrontWindow
        if let keyWindow {
            if let settingsWindow, keyWindow === settingsWindow { front = .settings }
            else if keyWindow === workspace.workspacePanel { front = .workspace }
            else { front = .other }
        } else {
            front = .none
        }
        switch Self.closeTarget(
            quickPadVisible: isQuickPadVisible,
            front: front,
            settingsVisible: settingsWindow?.isVisible == true,
            workspaceVisible: workspace.workspacePanel.isVisible
        ) {
        case .quickPad: dismissQuickPad()
        case .settings: closeSettingsPanel()
        case .workspace: workspace.hideWorkspace(notify: true)
        case .nothing: break
        }
    }

    private var quitTitle: String {
        "Quit \(displayName)"
    }

    /// The one quit path, shared by ⌘Q and the status menu. Under the resident
    /// LaunchAgent (KeepAlive) launchd relaunches the host at once, so for the
    /// installed app this is a restart; `launchctl bootout` is the real off switch.
    private func quitApplication() {
        quitApplication(activeRuns: Self.activeRunCount(in: activity.phases))
    }

    /// Shutdown cancels running work and can leave an owner effect uncertain,
    /// which nothing can undo, so quitting asks first only while runs are
    /// working. With nothing running it quits at once.
    func quitApplication(activeRuns: Int) {
        guard !isQuitting else { return }
        isQuitting = true
        if activeRuns > 0, !quitConfirmation(activeRuns) {
            isQuitting = false
            return
        }
        stop()
        applicationTerminator()
    }

    /// Replaced in tests, which must neither show a modal alert nor terminate.
    var quitConfirmation: @MainActor (Int) -> Bool = { OmniNativeWorkspaceController.askBeforeQuitting(activeRuns: $0) }
    var applicationTerminator: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }

    /// Runs still working, counted as the status menu's Working line counts them.
    nonisolated static func activeRunCount(in phases: [String: RunActivityPhase]) -> Int {
        phases.values.filter { $0 == .active }.count
    }

    nonisolated static func quitConfirmationText(activeRuns: Int) -> (message: String, detail: String) {
        activeRuns == 1
            ? ("1 run is still working", "Quitting stops it.")
            : ("\(activeRuns) runs are still working", "Quitting stops them.")
    }

    /// Cancel is the default button, so a stray ⌘Q followed by Return or esc
    /// keeps the work running.
    static func askBeforeQuitting(activeRuns: Int) -> Bool {
        let text = quitConfirmationText(activeRuns: activeRuns)
        let alert = NSAlert()
        alert.messageText = text.message
        alert.informativeText = text.detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func openSettingsFromMenu() {
        let intent = reserveForegroundIntent()
        // Settings already open (shown, or hidden when Omni lost focus or a Hyper
        // overlay took over) comes forward on its pane instead of rebuilding.
        // It takes the foreground the same way a fresh window does, so the host
        // closes any other overlay first.
        if let settingsWindow {
            beforeOmniForeground?()
            guard isCurrent(intent) else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        Task { [weak self] in await self?.showSettings(focusModels: false, reservedIntent: intent) }
    }

    /// The status menu owns its targets; rebuilding never grows app-menu retention.
    /// Its delegate reads the latest poll snapshot each time the menu opens (C60).
    func makeStatusMenu() -> NSMenu {
        NativeWorkspaceStatusMenu(title: displayName, populate: { [weak self] menu in
            self?.populateStatusMenu(menu)
        }, onOpen: { [weak self] menu in
            Task { [weak self, weak menu] in
                guard let self, let menu else { return }
                let previous = self.notifications.permission
                await self.notifications.refreshPermission()
                if self.notifications.permission != previous { menu.rebuild() }
            }
        })
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        let extras = statusMenuExtras?() ?? []
        for extra in extras {
            if let action = extra.action {
                let item = addMenuItem(extra.title, key: "", to: menu, action: action)
                item.identifier = .init(extra.identifier)
            } else {
                let item = NSMenuItem(title: extra.title, action: nil, keyEquivalent: "")
                item.identifier = .init(extra.identifier)
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        if !extras.isEmpty { menu.addItem(.separator()) }
        let active = lastDisplayedRows.filter { activity.phases[$0.id] == .active }
        if !active.isEmpty {
            let title: String
            if active.count == 1, let run = active.first {
                title = (["Working", run.token, run.title].filter { !$0.isEmpty }).joined(separator: " · ")
            } else {
                title = "Working · \(active.count) runs"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.identifier = .init("omni.status.working")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if canInvoke("launcher.open") {
            addMenuItem("New command", key: "n", to: menu) { [weak self] in self?.enqueueQuickRequest() }
        }
        addMenuItem("Workspace", key: "1", to: menu) { [weak self] in self?.openWorkspace() }
        menu.addItem(.separator())
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recent.isEnabled = false
        menu.addItem(recent)
        for row in lastDisplayedRows.prefix(5) {
            let title = [row.token, row.title, OmniWorkspace.dayLabel(for: row.submittedAt)].filter { !$0.isEmpty }.joined(separator: " · ")
            let item = addMenuItem(title, key: "", to: menu) { [weak self] in
                guard let self else { return }
                let intent = self.reserveForegroundIntent()
                Task { [weak self] in await self?.openRun(row.id, reservedIntent: intent) }
            }
            item.identifier = .init("omni.status.recent.\(row.id)")
            var subtitle = Self.menuExcerpt(row.summary)
            if row.activity == .failed {
                if let model = modelsByRunID[row.id] {
                    let reason = model.followUpKind == .failed ? model.followUpMessage ?? model.detail : model.detail
                    subtitle = Self.menuExcerpt(reason)
                }
                item.image = Self.recentFailureDot()
            }
            item.subtitle = subtitle
        }
        addMenuItem("All runs…", key: "", to: menu) { [weak self] in self?.openWorkspace() }
        menu.addItem(.separator())
        if notifications.permission == .denied {
            let item = addMenuItem("Notifications are off in System Settings…", key: "", to: menu) {
                NSWorkspace.shared.open(SystemOmniNotificationClient.systemSettingsURL)
            }
            item.identifier = .init("omni.notifications.settings")
        }
        addMenuItem("Settings…", key: ",", to: menu) { [weak self] in self?.openSettingsFromMenu() }
        addMenuItem(quitTitle, key: "q", to: menu) { [weak self] in self?.quitApplication() }
    }

    private static func menuExcerpt(_ text: String) -> String {
        String(text.replacingOccurrences(of: "[Synthetic fixture output]", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
    }

    private static func recentFailureDot() -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 6, height: 6)).fill()
            return true
        }
        image.accessibilityDescription = "Failed"
        return image
    }

    /// Inspectable through the candidate socket's `status` facts.
    public var notificationStatusFact: String {
        switch notifications.availability {
        case .available: "native-\(notifications.permission.rawValue)"
        case .unavailable(let reason): "unavailable-\(reason.replacingOccurrences(of: " ", with: "-"))"
        }
    }

    private func observeActivity(_ models: [ResultViewModel]) async {
        var deliveries: [OmniNotificationContent] = []
        var transitions = activity.observe(models)
        let finished = Set(transitions.compactMap { transition -> String? in
            if case .finished(let id, _) = transition { return id }
            return nil
        })
        // Admission may return after a poll already saw the terminal run.
        // Reconcile only newly established ownership/debt; consuming it
        // below makes this fallback exactly once, without replaying history.
        for model in models where !finished.contains(model.runID) && RunActivityTracker.phase(of: model) != .active {
            if confirmingProposalRunIDs.contains(model.runID), RunActivityTracker.phase(of: model) == .decision { continue }
            let workingHere = padRunID == model.runID && quickPadController.mode == .working(runID: model.runID)
            if workingHere || notifyingRunIDs.contains(model.runID) || proposalCouriersOwed.contains(model.runID) {
                transitions.append(.finished(runID: model.runID, outcome: outcome(of: model)))
            }
        }
        for transition in transitions {
            switch transition {
            case .started(let runID):
                statusPresenter?.runStarted(runID)
            case .finished(let runID, let outcome):
                if outcome == .proposalReady, confirmingProposalRunIDs.contains(runID) { continue }
                // This decision and the render/close are synchronous on the
                // main actor. Whichever happens first, close or arrival,
                // owns the run; there is no second asynchronous claim.
                let seenHere = consumePadArrival(runID: runID, outcome: outcome)
                let owed = notifyingRunIDs.contains(runID) || proposalCouriersOwed.contains(runID)
                statusPresenter?.runFinished(runID, outcome: outcome, announceOutcome: !seenHere && owed)
                if !seenHere, let courier = proposalCourierIfOwed(runID: runID, outcome: outcome) { deliveries.append(courier) }
                if let content = notificationIfOwed(runID: runID, outcome: outcome) { deliveries.append(content) }
            }
        }
        // Apply every activity/status/arrival transition before the first
        // notification await. A newer refresh cannot interleave half a
        // snapshot with the remainder of this one.
        for content in deliveries { await deliverOrPark(content) }
    }

    private func outcome(of model: ResultViewModel) -> RunActivityOutcome {
        switch RunActivityTracker.phase(of: model) {
        case .failed: .failed
        case .cancelled: .cancelled
        case .decision: .proposalReady
        case .active, .idle: .done
        }
    }

    private func consumePadArrival(runID: String, outcome: RunActivityOutcome) -> Bool {
        guard padRunID == runID, let model = modelsByRunID[runID] else { return false }
        switch quickPadController.mode {
        case .working(let id), .result(let id): guard id == runID else { return false }
        case .composing, .suggesting: return false
        }
        notifyingRunIDs.remove(runID)
        proposalCouriersOwed.remove(runID)
        pendingDeliveries.removeValue(forKey: runID)
        let shape = confirmedProposalShapes[runID]?.shape ?? padRunShape ?? shape(ofRun: runID)
        if outcome == .done, shape == .deterministicOpen || shape == .settings {
            // The target's open is the arrival. It gets no result mode and
            // never restores focus away from the app that just opened.
            padRunID = nil
            padRunShape = nil
            quickPadController.returnToComposing()
            dismissQuickPad(restoreFocus: false)
            return true
        }
        renderedInPadRunIDs.insert(runID)
        renderPadResult(model, outcome: outcome)
        if outcome == .failed { runOpened(runID) }
        return true
    }

    private func renderPadResult(_ model: ResultViewModel, outcome: RunActivityOutcome) {
        let runID = model.runID
        if outcome == .proposalReady {
            if case .result = quickPadController.mode, let result = quickPadController.result {
                switch result.kind {
                case .proposal, .failure, .options, .picker: return
                case .text, .confirmation: break
                }
            }
            presentProposalChooser(runID: runID)
            return
        }
        let shape = confirmedProposalShapes[runID]?.shape ?? padRunShape ?? shape(ofRun: runID)
        let result: OmniPadResult
        if outcome == .failed {
            let reason = model.followUpKind == .failed ? model.followUpMessage ?? model.detail : model.detail
            result = OmniPadResult(kind: .failure(retryAllowed: model.actions.contains(.retry)), body: reason, summary: "Unable to finish")
        } else if outcome == .cancelled {
            result = OmniPadResult(kind: .confirmation, body: "Cancelled", summary: "Run cancelled")
        } else if let find = model.find {
            // A `/find` result is a picker (D2), whatever tier answered it.
            quickPadController.showPicker(runID: runID, find: permittedFind(find))
            return
        } else if case .deterministicWrite(let destination) = shape {
            let token = confirmedProposalShapes[runID]?.token ?? Self.commandToken(of: model)
            result = OmniPadResult(kind: .confirmation, body: "\(token) · \(destination.receiptWording(summary: model.detail))", summary: "Saved · \(destination.rawValue)")
        } else if shape == .optionsResult {
            // Polling re-renders the bound result; a shown pick list keeps its
            // highlight and ticks.
            if quickPadController.result?.kind == .options, quickPadController.mode == .result(runID: runID) { return }
            let text = versionsByRunID[runID]?.max { $0.number < $1.number }?.resultText ?? model.fullText ?? ""
            guard let stance = StanceResult.parse(text) else {
                quickPadController.showResult(runID: runID, result: OmniPadResult(kind: .failure(retryAllowed: model.actions.contains(.retry)), body: "The positions could not be read · open the workspace to see the reply", summary: "Unable to read positions"))
                return
            }
            quickPadController.showOptions(runID: runID, options: padOptions(for: stance, provenance: model.provenance))
            return
        } else if shape == .textResult {
            let text = versionsByRunID[runID]?.max { $0.number < $1.number }?.resultText ?? model.fullText ?? model.detail
            result = OmniPadResult(kind: .text, body: text, summary: padResultSummary)
        } else {
            result = OmniPadResult(kind: .confirmation, body: model.detail, summary: padResultSummary)
        }
        quickPadController.showResult(runID: runID, result: result)
    }

    /// The proposal courier stays a background arrival; foreground proposal
    /// results use the same synchronous claim as every other H11 result.
    private func handleProposalTransition(runID: String, outcome: RunActivityOutcome) async {
        if let content = proposalCourierIfOwed(runID: runID, outcome: outcome) { await deliverOrPark(content) }
    }

    private func proposalCourierIfOwed(runID: String, outcome: RunActivityOutcome) -> OmniNotificationContent? {
        switch outcome {
        case .proposalReady:
            if proposalCouriersOwed.remove(runID) != nil, let model = modelsByRunID[runID] {
                notifyingRunIDs.remove(runID)
                return OmniNotificationContent(
                    runID: runID,
                    versionNumber: 1,
                    category: .proposal,
                    title: "Proposal ready",
                    subtitle: "Review",
                    body: RunNotificationPolicy.preview(of: model.commandText),
                    interruption: .active
                )
            }
        case .failed, .cancelled:
            proposalCouriersOwed.remove(runID)
        case .done:
            break
        }
        return nil
    }

    private func presentProposalChooser(runID: String) {
        guard let model = modelsByRunID[runID] else { return }
        padRunID = runID
        padRunShape = .proposal
        let alternatives = model.alternatives.map {
            OmniPadAlternative(id: $0.id, planHash: $0.planHash, title: $0.title, steps: $0.steps)
        }
        guard !alternatives.isEmpty else {
            quickPadController.showResult(runID: runID, result: OmniPadResult(kind: .failure(retryAllowed: false), body: "No safe proposal came back · open the workspace to edit and try again", summary: "Unable to propose"))
            return
        }
        quickPadController.showProposalChooser(runID: runID, alternatives: alternatives)
    }

    /// The courier's Review: the pad reopens in chooser state (spec §3).
    private func openProposalChooser(runID: String, reservedIntent: ForegroundIntent) async {
        guard isCurrent(reservedIntent) else { return }
        let expectedInteractionRevision = interactionRevision
        let expectedCaptureRevision = captureRevision
        try? await refreshResults(orderWindows: false)
        guard interactionRevision == expectedInteractionRevision,
              captureRevision == expectedCaptureRevision
        else { return }
        guard let model = modelsByRunID[runID], model.state == .proposalReady else {
            await openRun(runID, reservedIntent: reservedIntent)
            return
        }
        let receipt = if let id = RunID(rawValue: runID) {
            await environment.store.receipt(for: id)
        } else { nil as OmniRun.RunReceipt? }
        guard interactionRevision == expectedInteractionRevision,
              captureRevision == expectedCaptureRevision else { return }
        // Apply the entire new surface only after every await is complete.
        // A close/new Hyper intent during receipt lookup cannot reopen it.
        if padRunID != nil || quickPadController.isShowingLocalOptions { dismissQuickPad(restoreFocus: false) }
        interactionRevision += 1
        captureRevision += 1
        notifications.withdraw(runIDs: [runID])
        beforeOmniForeground?()
        focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        quickPadController.showCommandEditor()
        setQuickProvenance(model.provenance)
        setQuickText(receipt?.runtimeContext?.input?.rawText ?? model.commandText)
        quickPadController.setAnnotations(receipt?.runtimeContext?.annotations ?? model.annotations)
        workspace.hideWorkspace()
        showQuickPanel()
        quickPadController.beginWorking(runID: runID, requestText: quickPadController.editor.string, annotations: quickPadController.annotations)
        setQuickText("")
        setQuickProvenance(nil)
        presentProposalChooser(runID: runID)
    }

    /// A detached `/stance` run's Open: the pad comes back on its positions
    /// with the material, provenance and notes it was asked about.
    private func openOptionsInPad(runID: String, reservedIntent: ForegroundIntent) async {
        guard isCurrent(reservedIntent) else { return }
        let expectedInteractionRevision = interactionRevision
        let expectedCaptureRevision = captureRevision
        try? await refreshResults(orderWindows: false)
        guard interactionRevision == expectedInteractionRevision,
              captureRevision == expectedCaptureRevision
        else { return }
        guard let model = modelsByRunID[runID], model.state == .succeeded, let id = RunID(rawValue: runID) else {
            await openRun(runID, reservedIntent: reservedIntent)
            return
        }
        let receipt = await environment.store.receipt(for: id)
        guard interactionRevision == expectedInteractionRevision,
              captureRevision == expectedCaptureRevision else { return }
        if padRunID != nil || quickPadController.isShowingLocalOptions { dismissQuickPad(restoreFocus: false) }
        interactionRevision += 1
        captureRevision += 1
        runOpened(runID)
        beforeOmniForeground?()
        focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        quickPadController.showCommandEditor()
        setQuickProvenance(receipt?.runtimeContext?.provenance ?? model.provenance)
        setQuickText(receipt?.runtimeContext?.input?.rawText ?? model.commandText)
        quickPadController.setAnnotations(receipt?.runtimeContext?.annotations ?? model.annotations)
        workspace.hideWorkspace()
        showQuickPanel()
        quickPadController.beginWorking(runID: runID, requestText: quickPadController.editor.string, annotations: quickPadController.annotations, summary: OmniPadVocabulary.outcome(for: OmniDecisionStep.stanceToken))
        setQuickText("")
        setQuickProvenance(nil)
        padRunID = runID
        padRunShape = .optionsResult
        renderedInPadRunIDs.insert(runID)
        renderPadResult(model, outcome: .done)
    }

    private func confirmProposal(runID: String, planHash: String) async {
        guard padRunID == runID, case .result = quickPadController.mode,
              !confirmingProposalRunIDs.contains(runID),
              let id = RunID(rawValue: runID), let model = modelsByRunID[runID] else { return }
        confirmingProposalRunIDs.insert(runID)
        defer { confirmingProposalRunIDs.remove(runID) }
        // The chosen execution follows its own shape in the same pad. Decide
        // its shape before admission can suspend and Escape can detach it.
        if let chosen = model.alternatives.first(where: { $0.planHash == planHash }) {
            let shapes = chosen.steps.map { step -> (OmniCommandShape, String) in
                let token = environment.service.parser.parse(step).dispatchToken ?? ""
                return (shape(forCommandText: step), token)
            }
            let preferred = shapes.first { $0.0 == .textResult } ?? shapes.first
            if let preferred { confirmedProposalShapes[runID] = (preferred.0, preferred.1) }
        }
        padRunShape = confirmedProposalShapes[runID]?.shape ?? .other
        renderedInPadRunIDs.remove(runID)
        let request = quickPadController.submittedRequestText
        let annotations = model.annotations
        let provenance = quickPadController.submittedProvenance
        let token = confirmedProposalShapes[runID]?.token ?? Self.commandToken(of: model)
        padResultSummary = OmniPadVocabulary.outcome(for: token)
        quickPadController.beginWorking(runID: runID, requestText: request, annotations: annotations, summary: padResultSummary, provenance: provenance)
        selectedRunID = runID
        selectedVersion = nil
        followsLatestVersion = true
        do {
            await beforeProposalConfirmation?()
            try await environment.service.confirm(runID: id, exactPlanHash: planHash)
        } catch {
            if padRunID == runID {
                renderedInPadRunIDs.insert(runID)
                quickPadController.showResult(runID: runID, result: OmniPadResult(kind: .failure(retryAllowed: false), body: "Unable to run that alternative: \(error)", summary: "Unable to run"))
            } else if notifyingRunIDs.contains(runID) {
                // A rejected confirmation leaves the existing proposal
                // ready. Re-courier that decision using its existing shape;
                // no nonexistent execution is left owing a terminal event.
                confirmedProposalShapes.removeValue(forKey: runID)
                proposalCouriersOwed.insert(runID)
                await handleProposalTransition(runID: runID, outcome: .proposalReady)
            }
            return
        }
        try? await refreshResults(orderWindows: false)
    }

    // MARK: Decision step (D3, D6)

    /// Positions for the pad. The draft a pick runs follows the material's
    /// source (D6); without one, a pick returns to composing with its note.
    private func padOptions(for stance: StanceResult, provenance: OmniRunProvenance?) -> OmniPadOptions {
        let draft = Self.draftToken(for: provenance, manifest: environment.service.parser.manifest)
        let noun: [String: String] = ["/email": "an email", "/msg": "a message"]
        let summary = draft.map { "Positions · a pick drafts \(noun[$0] ?? OmniPadVocabulary.outcome(for: $0).lowercased())" }
            ?? "Positions · a pick returns here with its note"
        return OmniPadOptions(
            heading: "POSITIONS · PICK ONE",
            options: stance.positions.enumerated().map { index, position in
                OmniPadOption(id: String(index + 1), title: position.title, detail: position.approach)
            },
            // D6 step 2: what the pre-pass noticed, as tick rows, unticked.
            noticed: stance.noticed.enumerated().map { index, item in
                OmniPadNoticed(id: String(index), label: Self.noticedLabel(item.type), note: item.note, quote: item.quote)
            },
            summary: summary,
            pickVerb: draft == nil ? "Use" : "Draft"
        )
    }

    /// The draft token, plus `✓` / `✗` for a plain accept or decline when
    /// that command accepts the marker (`/msg` accepts none).
    nonisolated static func draftReplacement(token: String, kind: StancePositionKind, manifest: CommandManifest) -> String {
        let marker: String? = switch kind {
        case .accept: "✓"
        case .decline: "✗"
        case .other: nil
        }
        guard let marker, manifest.command(for: token)?.intentMarkers.contains(marker) == true else { return token }
        return "\(token) \(marker)"
    }

    nonisolated static func draftToken(for provenance: OmniRunProvenance?, manifest: CommandManifest) -> String? {
        OmniMaterialSource.draftToken(appName: provenance?.appName).flatMap { manifest.command(for: $0) == nil ? nil : $0 }
    }

    /// The request a pick produces: `/stance` replaced by the draft token
    /// (plus `✓`/`✗` for a plain accept or decline the command accepts), or
    /// removed when there is no draft. Earlier spans keep their offsets.
    nonisolated static func pickedRequest(
        fromStanceText raw: String,
        annotations: [OmniTextAnnotation],
        replacement: String?
    ) -> (text: String, annotations: [OmniTextAnnotation]) {
        let ns = raw as NSString
        var atom: NSRange?
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index].isWhitespace { index = raw.index(after: index); continue }
            let start = index
            while index < raw.endIndex, !raw[index].isWhitespace { index = raw.index(after: index) }
            if raw[start..<index] == OmniDecisionStep.stanceToken { atom = NSRange(start..<index, in: raw) }
        }
        guard var range = atom else {
            let text = replacement.map { raw + (raw.last?.isWhitespace == true ? "" : " ") + $0 } ?? raw
            return (text, OmniAnnotationRanges.validated(annotations, in: text))
        }
        let value: String
        if let replacement {
            value = replacement
        } else {
            // Take one adjacent space with the removed token.
            if range.location > 0, (ns.substring(with: NSRange(location: range.location - 1, length: 1)).first?.isWhitespace ?? false) {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            value = ""
        }
        let text = ns.replacingCharacters(in: range, with: value)
        let moved = OmniAnnotationRanges.remap(annotations, replacing: range, withUTF16Length: (value as NSString).length)
        return (text, OmniAnnotationRanges.validated(moved, in: text))
    }

    nonisolated static func noticedLabel(_ type: String?) -> String {
        guard let type = type?.trimmingCharacters(in: .whitespaces), let first = type.first else { return "Noticed" }
        return first.uppercased() + type.dropFirst()
    }

    /// A ticked noticed item as a proposed note (D2): on the span the model
    /// quoted when that text occurs once in the payload and overlaps no
    /// other note, otherwise on the whole request. The quote is named there
    /// only when it is real text (found twice, or under another note); a
    /// quote the material does not contain is never passed on as quoted.
    nonisolated static func noticedNote(_ item: StanceNoticedItem, inRawText raw: String, avoiding existing: [OmniTextAnnotation]) -> OmniTextAnnotation {
        let point = noticedPoint(item)
        let match = item.quote.map { OmniAnnotationRanges.quoteMatch(ofQuote: $0, inRawText: raw, avoiding: existing) } ?? .absent
        switch match {
        case .unique(let range):
            return OmniTextAnnotation(range: range, guidance: "Take this into account in the response (\(point))", origin: .proposed)
        // The point leads a whole-request note so the overview can show it.
        case .ambiguous:
            return .request(guidance: "\(point) (about “\(item.quote ?? "")”) — take this into account in the response.", origin: .proposed)
        case .absent:
            return .request(guidance: "\(point) — take this into account in the response.", origin: .proposed)
        }
    }

    nonisolated static func noticedPoint(_ item: StanceNoticedItem) -> String {
        (item.type.map { "\($0): " } ?? "") + item.note
    }

    /// Whether a note's guidance is one of the three forms `noticedNote`
    /// writes for this item; a shorter point inside another tick never counts.
    nonisolated static func isTickNote(_ guidance: String, for item: StanceNoticedItem) -> Bool {
        let point = noticedPoint(item)
        let quoted = item.quote.map { "\(point) (about “\($0)”) — take this into account in the response." }
        return guidance == "Take this into account in the response (\(point))"
            || guidance == "\(point) — take this into account in the response."
            || guidance == quoted
    }

    /// One note per tick, in tick order; unticked items are never stored,
    /// and an item already carried by a proposed note is not added twice.
    nonisolated static func tickNotes(for ticked: [Int], in stance: StanceResult, rawText: String, existing: [OmniTextAnnotation]) -> [OmniTextAnnotation] {
        var notes: [OmniTextAnnotation] = []
        for index in ticked where stance.noticed.indices.contains(index) {
            let item = stance.noticed[index]
            let carried = (existing + notes).contains { $0.origin == .proposed && Self.isTickNote($0.guidance, for: item) }
            guard !carried else { continue }
            notes.append(noticedNote(item, inRawText: rawText, avoiding: existing + notes))
        }
        return notes
    }

    /// Positions are single-pick (D6): a pick replaces the position an
    /// earlier pick on the same material set (a labelled proposed request
    /// note); the person's own notes and earlier ticks stay.
    nonisolated static func droppingEarlierPicks(_ annotations: [OmniTextAnnotation]) -> [OmniTextAnnotation] {
        // Only a pick writes a label, so a labelled request note is an
        // earlier position, rewritten or not.
        annotations.filter { !($0.isRequestScoped && $0.label != nil) }
    }

    /// The chosen position as a whole-request note (D2). A drafting pick says
    /// which way the reply runs: the material is a message the user received.
    nonisolated static func pickNote(for position: StancePosition, drafting: Bool) -> OmniTextAnnotation {
        // The live tick check (2026-10-05) saw a position such as "suggest a
        // later time" pull the drafter into naming 16:30 and an attachment;
        // a position is carried out only with what the material gives. Without
        // the example phrase the drafter named 17:00 (live M3 check). Both
        // notes carry the title only: the stance model writes causes into
        // approaches ("a later slot that fits your schedule") whatever its
        // prompt says, and drafts repeated them as the user's reasons; a
        // non-draft note can still reach a draft the person types.
        let guidance = drafting
            ? "The user text is a message the user received. Write the user's reply to its sender, taking the position the user chose: \(position.title). Carry the position out with only what the user text and the user's own notes contain. Never name a time, a date, a slot, an attachment, a sent item, a commitment, or a reason they do not give, and never say why an offered time does or does not suit the user: a reason the sender guesses on the user's behalf (their schedule, their workload, their stack) is not the user's reason. Where the position needs one of these, leave it open in general words (for example \"a later time\")."
            : "The user chose this approach to the material: \(position.title)."
        return .request(guidance: guidance, origin: .proposed, label: position.title)
    }

    /// Enter or a digit on a position (D6). With a draft command and no
    /// "edit first", the draft runs at once as a second run linked to the
    /// stance run; otherwise the pad returns to composing with the notes.
    private func pickStanceOption(runID: String, index: Int, ticked: [Int], gesture: OmniPadPickGesture) async {
        // The key handler marked this pick in flight; every exit clears it.
        defer { pickingStanceRunIDs.remove(runID) }
        guard padRunID == runID, quickPadController.mode == .result(runID: runID),
              let id = RunID(rawValue: runID), let model = modelsByRunID[runID] else { return }
        let text = versionsByRunID[runID]?.max { $0.number < $1.number }?.resultText ?? model.fullText ?? ""
        guard let stance = StanceResult.parse(text), stance.positions.indices.contains(index) else { return }
        let receipt = await environment.store.receipt(for: id)
        guard padRunID == runID, quickPadController.mode == .result(runID: runID) else { return }
        let position = stance.positions[index]
        let manifest = environment.service.parser.manifest
        let provenance = receipt?.runtimeContext?.provenance ?? model.provenance
        let raw = receipt?.runtimeContext?.input?.rawText ?? model.commandText
        let existing = Self.droppingEarlierPicks(receipt?.runtimeContext?.annotations ?? model.annotations)
        let draft = Self.draftToken(for: provenance, manifest: manifest)
        let replacement = draft.map { Self.draftReplacement(token: $0, kind: position.kind, manifest: manifest) }
        let picked = Self.pickedRequest(fromStanceText: raw, annotations: existing, replacement: replacement)
        let pickNote = Self.pickNote(for: position, drafting: draft != nil)
        // Ticks commit with the position (D6): one proposed note each.
        let ticks = Self.tickNotes(for: ticked, in: stance, rawText: picked.text, existing: picked.annotations)
        let notes = OmniAnnotationRanges.validated(picked.annotations + [pickNote] + ticks, in: picked.text)
        guard draft != nil, gesture == .run else {
            presentPickForEditing(stanceRunID: runID, text: picked.text, notes: notes, provenance: provenance, pickNoteID: pickNote.id)
            return
        }
        await submitPickedDraft(stanceRunID: id, text: picked.text, notes: notes, provenance: provenance, positionTitle: position.title, pickNoteID: pickNote.id)
    }

    /// The two-key path through the real pad and this controller, for the
    /// headless candidate and integration tests: material arrives as a
    /// capture, Enter takes the offer row, a digit picks. Default routing
    /// applies throughout; nothing here bypasses a check.
    func driveDecisionStep(
        material: String,
        provenance: OmniRunProvenance?,
        pick: Int?,
        ticks: [Int] = [],
        editFirst: Bool = false,
        timeout: Duration = .seconds(20)
    ) async throws -> [String: String] {
        if padRunID != nil || quickPadController.isShowingLocalOptions { dismissQuickPad(restoreFocus: false) }
        _ = quickPadController.view
        quickPadController.showCommandEditor()
        setQuickProvenance(nil)
        setQuickText("")
        importQuickSelection(CapturedOmniSelection(text: material, appName: provenance?.appName, processID: 0, windowTitle: provenance?.windowTitle, bundleIdentifier: provenance?.bundleIdentifier))
        var facts: [String: String] = [
            "offerRowVisible": String(quickPadController.isOfferRowVisible),
            "offerTitle": quickPadController.offerRowTitle ?? "",
        ]
        quickPadController.editor.onSubmit?(.enterShowHere)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var stanceRunID: String?
        while clock.now < deadline {
            try? await refreshResults(orderWindows: false)
            if let id = padRunID, quickPadController.mode == .result(runID: id) {
                if quickPadController.result?.kind == .options { stanceRunID = id; break }
                if case .failure = quickPadController.result?.kind {
                    facts["failure"] = quickPadController.result?.body
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        facts["stanceRunID"] = stanceRunID ?? padRunID ?? ""
        facts["positions"] = quickPadController.options?.options.map(\.title).joined(separator: " | ") ?? ""
        facts["noticed"] = quickPadController.options?.noticed.map { "\($0.label): \($0.note)" }.joined(separator: " | ") ?? ""
        guard let stanceRunID, let pick else { return facts }
        for tick in ticks { quickPadController.toggleNoticed(index: tick) }
        quickPadController.chooseOption(number: pick, gesture: editFirst ? .editFirst : .run)
        while clock.now < deadline {
            try? await refreshResults(orderWindows: false)
            if quickPadController.mode == .composing, padRunID == nil {
                facts["returnedToComposing"] = "true"
                facts["editorText"] = quickPadController.editor.string
                facts["notes"] = String(quickPadController.annotations.count)
                break
            }
            if let id = padRunID, id != stanceRunID, quickPadController.mode == .result(runID: id) {
                facts["draftRunID"] = id
                facts["draftRouteLine"] = quickPadController.routeLine.text
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return facts
    }

    /// Bare `/expand` through the real pad: the local lens picker, then a
    /// lens pick that runs `/expand:<lens>` by default routing.
    func driveExpandLens(material: String, lens: Int, timeout: Duration = .seconds(20)) async throws -> [String: String] {
        if padRunID != nil || quickPadController.isShowingLocalOptions { dismissQuickPad(restoreFocus: false) }
        _ = quickPadController.view
        quickPadController.showCommandEditor()
        setQuickProvenance(nil)
        setQuickText(material + " " + OmniDecisionStep.expandToken)
        let before = Set(await environment.store.recentRuns(limit: 50).map(\.id.rawValue))
        quickPadController.editor.onSubmit?(.enterShowHere)
        var facts: [String: String] = [
            "lensPickerShown": String(quickPadController.isShowingLocalOptions),
            "lenses": quickPadController.options?.options.map(\.title).joined(separator: " | ") ?? "",
            "runsAfterBareExpand": String(Set(await environment.store.recentRuns(limit: 50).map(\.id.rawValue)).subtracting(before).count),
        ]
        quickPadController.chooseOption(number: lens, gesture: .run)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try? await refreshResults(orderWindows: false)
            if let id = padRunID, quickPadController.mode == .result(runID: id) {
                facts["runID"] = id
                facts["routeLine"] = quickPadController.routeLine.text
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return facts
    }

    /// "Edit first", or a pick with no draft command: composing, the notes
    /// attached, the token (if any) in place. Nothing runs.
    private func presentPickForEditing(stanceRunID: String, text: String, notes: [OmniTextAnnotation], provenance: OmniRunProvenance?, pickNoteID: UUID?) {
        guard padRunID == stanceRunID else { return }
        pendingPickOrigin = pickNoteID.map { (stanceRunID, $0) }
        padRunID = nil
        padRunShape = nil
        renderedInPadRunIDs.remove(stanceRunID)
        quickPadController.returnToComposing()
        setQuickText(text)
        setQuickProvenance(provenance)
        quickPadController.setAnnotations(notes)
        quickPadController.showCommandEditor()
    }

    /// esc on the positions: the material back in the field with its notes,
    /// `/stance` removed. Nothing is invalidated.
    private func returnToMaterial(fromStanceRun runID: String) async {
        guard padRunID == runID, let id = RunID(rawValue: runID) else { return }
        let receipt = await environment.store.receipt(for: id)
        // A pick that started while this awaited owns the surface.
        guard padRunID == runID, quickPadController.result?.kind == .options, !pickingStanceRunIDs.contains(runID) else { return }
        let model = modelsByRunID[runID]
        let raw = receipt?.runtimeContext?.input?.rawText ?? model?.commandText ?? ""
        let restored = Self.pickedRequest(fromStanceText: raw, annotations: receipt?.runtimeContext?.annotations ?? model?.annotations ?? [], replacement: nil)
        presentPickForEditing(stanceRunID: runID, text: restored.text, notes: restored.annotations, provenance: receipt?.runtimeContext?.provenance ?? model?.provenance, pickNoteID: nil)
    }

    /// The pick's draft: a second run through the same broker, guides,
    /// qualification and receipt as a typed `/email`, linked to its stance.
    private func submitPickedDraft(stanceRunID: RunID, text: String, notes: [OmniTextAnnotation], provenance: OmniRunProvenance?, positionTitle: String, pickNoteID: UUID) async {
        if let token = environment.service.parser.parse(text).dispatchToken,
           !canInvoke("command.\(token.dropFirst())") {
            quickPadController.showTransientNotice("This module is disabled in Settings.")
            return
        }
        let runID = stanceRunID.rawValue
        let revision = interactionRevision
        let generation = foreground.snapshot().uiGeneration
        let presenter = ProviderSettingsPresenter(environment: environment)
        // C67: the same pre-check as a typed submit, before any run exists.
        if let route = await presenter.padRoute(commandText: text, selectedProfileID: nil), let reason = route.unavailable {
            guard padRunID == runID else { return }
            presentPickForEditing(stanceRunID: runID, text: text, notes: notes, provenance: provenance, pickNoteID: pickNoteID)
            quickPadController.showTransientNotice(reason)
            return
        }
        // The pad may have closed or moved on while the route was checked:
        // then no draft is created.
        guard padRunID == runID, quickPadController.mode == .result(runID: runID) else { return }
        do {
            let submission = try await environment.service.submit(text, provenance: provenance, annotations: notes, originRunID: stanceRunID)
            guard let newID = submission.runID?.rawValue else {
                if padRunID == runID { presentPickForEditing(stanceRunID: runID, text: text, notes: notes, provenance: provenance, pickNoteID: pickNoteID) }
                return
            }
            let shape = shape(forCommandText: text)
            guard padRunID == runID, interactionRevision == revision, foreground.isCurrent(generation: generation) else {
                // The pad closed while the draft was admitted: it owes arrival.
                expectNotification(for: newID, shape: shape)
                try? await refreshResults(orderWindows: false)
                return
            }
            padRunID = newID
            padRunShape = shape
            renderedInPadRunIDs.remove(newID)
            selectedRunID = newID
            selectedVersion = nil
            followsLatestVersion = true
            let token = environment.service.parser.parse(text).dispatchToken ?? ""
            // D2: the route line shows the position title on the draft run.
            padResultSummary = OmniPadVocabulary.outcome(for: token) + " · " + positionTitle
            if let notice = submission.annotationNotice { padResultSummary += " · " + notice }
            quickPadController.beginWorking(runID: newID, requestText: text, annotations: notes, summary: padResultSummary, provenance: quickPadController.submittedProvenance)
            try? await refreshResults(orderWindows: false)
        } catch {
            guard padRunID == runID else { return }
            presentPickForEditing(stanceRunID: runID, text: text, notes: notes, provenance: provenance, pickNoteID: pickNoteID)
            quickPadController.showTransientNotice("Unable to draft: \(error)")
        }
    }

    private func dismissProposal(runID: String) {
        guard padRunID == runID else { return }
        dismissQuickPad()
        proposalCouriersOwed.remove(runID)
        Task { [weak self] in
            guard let self, let id = RunID(rawValue: runID) else { return }
            try? await self.environment.service.invalidateProposal(runID: id)
            try? await self.refreshResults(orderWindows: false)
        }
    }

    private func notificationIfOwed(runID: String, outcome: RunActivityOutcome) -> OmniNotificationContent? {
        guard notifyingRunIDs.contains(runID), !renderedInPadRunIDs.contains(runID) else { return nil }
        // A proposal keeps its debt: the chosen alternative's run notifies (H2).
        guard outcome != .proposalReady else { return nil }
        notifyingRunIDs.remove(runID)
        guard let model = modelsByRunID[runID] else { return nil }
        if let find = model.find, find.rows.contains(where: { !canUseIndexedPath($0.path) }) { return nil }
        let confirmed = confirmedProposalShapes.removeValue(forKey: runID)
        let shape = confirmed?.shape ?? OmniCommandShape.shape(moduleID: model.moduleID, manifest: environment.service.parser.manifest)
        let provenance = model.provenance.flatMap(Self.provenanceLine(for:))?.text
        return RunNotificationPolicy.content(for: model, shape: shape, outcome: outcome, provenance: provenance, tokenOverride: confirmed?.token)
    }

    /// Delivers now, or parks the content while the permission ask is up (spec §7).
    private func deliverOrPark(_ content: OmniNotificationContent) async {
        if notifications.permission == .notRequested {
            pendingDeliveries[content.runID] = content
            return
        }
        await notifications.deliver(content)
    }

    /// A working close owes arrival (C53); workspace follow-ups retain their
    /// existing notification behavior. Ask in context at the first detach,
    /// and at the existing proposal/retry trigger points, never at launch.
    private func expectNotification(for runID: String, shape: OmniCommandShape) {
        // A later workspace version is a new arrival on this same durable
        // run. Having watched v1 must not suppress its v2 notification.
        renderedInPadRunIDs.remove(runID)
        notifyingRunIDs.insert(runID)
        switch shape {
        case .textResult, .optionsResult, .deterministicWrite, .deterministicOpen, .proposal, .other: requestAuthorizationIfNeeded()
        case .settings: break
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard notifications.permission == .notRequested, authorizationTask == nil else { return }
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.notifications.requestAuthorizationIfNeeded()
            self.authorizationTask = nil
            let owed = self.pendingDeliveries.values.sorted { $0.runID < $1.runID }
            self.pendingDeliveries.removeAll()
            for content in owed { await self.notifications.deliver(content) }
        }
    }

    private func shape(forCommandText text: String) -> OmniCommandShape {
        let manifest = environment.service.parser.manifest
        let token = environment.service.parser.parse(text).dispatchToken
        let moduleID = token.flatMap { token in manifest.commands.first { $0.token == token }?.moduleID }
        return OmniCommandShape.shape(moduleID: moduleID, manifest: manifest)
    }

    private func shape(ofRun runID: String) -> OmniCommandShape {
        guard let model = modelsByRunID[runID] else { return .other }
        return OmniCommandShape.shape(moduleID: model.moduleID, manifest: environment.service.parser.manifest)
    }

    /// Opening a run, from anywhere, withdraws its notification and clears its
    /// menu bar failure mark in the same step (C6, C14, spec §4.3).
    private func runOpened(_ runID: String) {
        positionsArrivalsOwed.remove(runID)
        notifyingRunIDs.remove(runID)
        proposalCouriersOwed.remove(runID)
        pendingDeliveries.removeValue(forKey: runID)
        notifications.withdraw(runIDs: [runID])
        statusPresenter?.runOpened(runID)
    }

    /// The workspace at one run: Recent menu item, sidebar row, notification
    /// click or menu bar all arrive here.
    public func openRun(_ runID: String) async {
        await openRun(runID, reservedIntent: reserveForegroundIntent())
    }

    private func openRun(_ runID: String, reservedIntent: ForegroundIntent) async {
        guard isCurrent(reservedIntent) else { return }
        let expectedInteractionRevision = interactionRevision
        let expectedCaptureRevision = captureRevision
        if modelsByRunID[runID] == nil { try? await refreshResults(orderWindows: false) }
        guard interactionRevision == expectedInteractionRevision,
              captureRevision == expectedCaptureRevision
        else { return }
        if modelsByRunID[runID] != nil {
            saveActiveComposerDraft()
            composerKey = nil
            selectedRunID = runID
            selectedVersion = nil
            followsLatestVersion = true
        }
        openWorkspace()
        await selectRun(runID)
    }

    private func handleNotificationAction(_ action: OmniNotificationAction, runID: String, reservedIntent: ForegroundIntent?) async {
        switch action {
        case .open:
            guard let reservedIntent else { return }
            // Positions are picked in the pad (D6): an options arrival reopens
            // it on the positions, as Review reopens a proposal chooser.
            if shape(ofRun: runID) == .optionsResult {
                await openOptionsInPad(runID: runID, reservedIntent: reservedIntent)
            } else {
                await openRun(runID, reservedIntent: reservedIntent)
            }
        case .review:
            guard let reservedIntent else { return }
            await openProposalChooser(runID: runID, reservedIntent: reservedIntent)
        case .copy:
            let shape = confirmedProposalShapes[runID]?.shape ?? shape(ofRun: runID)
            guard shape == .textResult else { return }
            let text = await latestResultText(runID: runID)
            guard let text else { return }
            pasteboardWriter(text)
        case .retry:
            guard let id = RunID(rawValue: runID), let model = modelsByRunID[runID] else { return }
            runOpened(runID)
            // Retry is a linked new run today (`retryOf`); "retry within the
            // same run" would need the run model to grow a version for it.
            do {
                let retried = try await environment.service.retry(runID: id)
                if let notice = retried.annotationNotice {
                    quickPadController.showTransientNotice(notice)
                    // Notification retry can arrive with the pad hidden. Its
                    // route-line notice must be on screen before the new run.
                    if !isQuickPadVisible { showQuickPanel() }
                }
                if let newID = retried.runID { expectNotification(for: newID.rawValue, shape: shape(ofRun: runID)) }
            } catch {
                await notifications.deliver(OmniNotificationContent(
                    runID: runID,
                    versionNumber: max(model.versionCount, 1),
                    category: .failure,
                    title: "\(model.title) · retry not possible",
                    subtitle: nil,
                    body: RunNotificationPolicy.preview(of: "\(error)"),
                    interruption: .active
                ))
            }
        }
    }

    @discardableResult
    private func addMenuItem(
        _ title: String,
        key: String,
        to menu: NSMenu,
        action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let target = NativeWorkspaceMenuTarget(action)
        if let statusMenu = menu as? NativeWorkspaceStatusMenu { statusMenu.menuTargets.append(target) }
        else { menuTargets.append(target) }
        let item = NSMenuItem(title: title, action: #selector(NativeWorkspaceMenuTarget.invoke(_:)), keyEquivalent: key)
        item.target = target
        menu.addItem(item)
        return item
    }

    /// Settings (H20): five panes on grouped forms, applied as changed.
    /// `focusModels` opens on Models; otherwise the last pane used.
    func showSettings(focusModels: Bool) async {
        await showSettings(focusModels: focusModels, reservedIntent: reserveForegroundIntent())
    }

    private func showSettings(focusModels: Bool, reservedIntent: ForegroundIntent) async {
        guard isCurrent(reservedIntent) else { return }
        beforeOmniForeground?()
        guard isCurrent(reservedIntent) else { return }
        await onShowSettings?(focusModels)
    }

    /// Settings → General → Appearance, for every Omni window in this process.
    public func applyAppearance(_ appearance: OmniAppearance) {
        guard presentsInterface else { return }
        NSApplication.shared.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// A real close: the next Settings… builds a fresh window.
    func closeSettingsPanel() {
        settingsWindow?.orderOut(nil)
        forgetSettingsWindow()
    }

    private func forgetSettingsWindow() {
        if let settingsCloseObserver { NotificationCenter.default.removeObserver(settingsCloseObserver) }
        settingsCloseObserver = nil
        settingsWindow = nil
    }

    /// Host-owned navigation stays available when the optional Launcher module is off.
    public func showWorkspaceWindow() {
        guard !isQuitting else { return }
        openWorkspace()
    }

    private func openWorkspace() {
        let intent = reserveForegroundIntent()
        beforeOmniForeground?()
        guard isCurrent(intent) else { return }
        saveActiveComposerDraft()
        focusOrigin.captureOrigin(excluding: ProcessInfo.processInfo.processIdentifier)
        dismissQuickPad(restoreFocus: false)
        foreground.showOmni()
        if let selectedRunID, composerKey == nil { runOpened(selectedRunID) }
        if presentsInterface {
            workspace.showWorkspace()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Task { [weak self] in try? await self?.refreshResults(orderWindows: true) }
    }

    private func showQuickPanel() {
        foreground.showOmni()
        invalidateRoutePreviews()
        guard presentsInterface else { return }
        visibleFrame = currentVisibleFrame()
        if quickPanel == nil {
            quickPanel = OmniPanelFactory.makePad(controller: quickPadController, visibleFrame: visibleFrame)
        } else if let quickPanel {
            // Fixed position regardless of how it was invoked (C23).
            quickPanel.setFrame(OmniPadPlacement.frame(size: NSSize(width: OmniPadPlacement.width, height: quickPanel.frame.height), visibleFrame: visibleFrame), display: false)
        }
        quickPanel?.makeKeyAndOrderFront(nil)
        quickPanel?.makeFirstResponder(quickPadController.editor)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func dismissQuickPad() {
        dismissQuickPad(restoreFocus: true)
    }

    private func workspaceClosed() {
        captureRevision += 1
        interactionRevision += 1
        saveActiveComposerDraft()
        switch foreground.snapshot().foreground {
        case .editing: foreground.closeBeforeSubmission()
        case .attached: foreground.detachAttachedResult()
        case .hidden, .legacy: break
        }
        restoreOrigin()
    }

    private var padRouteCache: [String: OmniPadRoute?] = [:]
    private var padRouteCachedAt: [String: Date] = [:]
    private var padRouteInFlight: Set<String> = []
    private var routePreviewGeneration = 0
    private var modelChoicesKey: String?
    private var modelChoicesUpdatedAt: Date?
    private var modelChoicesInFlight = false

    /// Synchronous accessor for the pad's route line. Resolution runs on the
    /// runtime actor; the first call schedules it and re-renders when known.
    func padRoute(for intent: ParsedIntent, profileID: String?, presenter: ProviderSettingsPresenter) -> OmniPadRoute? {
        if let token = intent.dispatchToken, token != "/workspace",
           !canInvoke("command.\(token.dropFirst())") {
            return OmniPadRoute(providerName: nil, unavailable: "This module is disabled in Settings.")
        }
        guard let commandID = presenter.modelCommandID(for: intent) else { return nil }
        let token = intent.dispatchToken ?? commandID
        let key = "\(token)|\(intent.modes.contains("/offline"))|\(profileID ?? "")"
        let choicesKey = "\(commandID)|\(intent.modes.contains("/offline"))"
        let choicesExpired = modelChoicesUpdatedAt.map { Date().timeIntervalSince($0) >= 30 } ?? true
        if modelChoicesKey != choicesKey || (choicesExpired && !modelChoicesInFlight) {
            refreshModelChoices(commandText: intent.canonicalText, key: choicesKey, presenter: presenter)
        }
        if let cached = padRouteCache[key], let date = padRouteCachedAt[key], Date().timeIntervalSince(date) < 30 { return cached }
        guard !padRouteInFlight.contains(key) else { return nil }
        padRouteInFlight.insert(key)
        let generation = routePreviewGeneration
        let text = intent.canonicalText
        Task { [weak self] in
            let route = await presenter.padRoute(commandText: text, selectedProfileID: profileID)
            guard let self else { return }
            self.padRouteInFlight.remove(key)
            // A result computed under an older settings/qualification state is dropped.
            guard generation == self.routePreviewGeneration else { return }
            self.padRouteCache[key] = route
            self.padRouteCachedAt[key] = Date()
            self.quickPadController.refreshRoute()
        }
        return nil
    }

    public func invalidateRoutePreviews() {
        padRouteCache.removeAll()
        padRouteCachedAt.removeAll()
        padRouteInFlight.removeAll()
        modelChoicesKey = nil
        modelChoicesUpdatedAt = nil
        modelChoicesInFlight = false
        routePreviewGeneration += 1
        if environment.providerRuntime != nil {
            let presenter = ProviderSettingsPresenter(environment: environment)
            let text = quickPadController.editor.string
            let intent = environment.service.parser.parse(text)
            let key = "\(presenter.modelCommandID(for: intent) ?? "answer.quick")|\(intent.modes.contains("/offline"))"
            refreshModelChoices(commandText: text, key: key, presenter: presenter)
        }
    }

    private func refreshModelChoices(commandText: String, key: String, presenter: ProviderSettingsPresenter) {
        modelChoicesKey = key
        modelChoicesInFlight = true
        let generation = routePreviewGeneration
        Task { [weak self] in
            _ = await presenter.modelChoices(commandText: commandText, didUpdate: { [weak self] choices in
                await MainActor.run {
                    guard let self, generation == self.routePreviewGeneration, self.modelChoicesKey == key else { return }
                    self.modelChoicesUpdatedAt = Date()
                    self.quickPadController.setModelChoices(choices)
                }
            })
            guard let self, generation == self.routePreviewGeneration, self.modelChoicesKey == key else { return }
            self.modelChoicesInFlight = false
        }
    }

    func submitQuick(text: String, gesture: OmniSubmitGesture, expectedGeneration: Int, selectedProfileID: String? = nil, annotations submittedAnnotations: [OmniTextAnnotation] = [], visibleDraft: String? = nil, stashImport: OmniPadStashImport? = nil) async {
        if let token = environment.service.parser.parse(text).dispatchToken,
           !canInvoke("command.\(token.dropFirst())") {
            quickPadController.showTransientNotice("This module is disabled in Settings.")
            return
        }
        // Positions are single-pick (D6): re-running /stance decides afresh,
        // so an earlier pick's position note never enters the stance prompt.
        let isStanceRequest = environment.service.parser.parse(text).dispatchToken == OmniDecisionStep.stanceToken
        let annotations = isStanceRequest ? Self.droppingEarlierPicks(submittedAnnotations) : submittedAnnotations
        let revision = interactionRevision
        let submissionKey = QuickSubmissionKey(generation: expectedGeneration, revision: revision, text: text, profileID: selectedProfileID, annotations: annotations)
        latestQuickSubmission += 1
        if let pending = quickSubmissionsInFlight.first(where: { $0.key == submissionKey }) {
            // Cmd+Enter during admission moves this same request to the
            // workspace; it must not silently vanish or execute a write twice.
            pending.gesture = gesture
            pending.sequence = latestQuickSubmission
            return
        }
        let pending = PendingQuickSubmission(key: submissionKey, gesture: gesture, sequence: latestQuickSubmission)
        quickSubmissionsInFlight.append(pending)
        defer { quickSubmissionsInFlight.removeAll { $0 === pending } }
        let provenance = stashImport.map {
            OmniRunProvenance(appName: $0.source, windowTitle: $0.chip.source, wordCount: $0.chip.wordCount, bundleIdentifier: nil)
        } ?? quickProvenance
        let routeSummary = quickPadController.statusLabel.stringValue
        do {
            let presenter = ProviderSettingsPresenter(environment: environment)
            // Enter may arrive before the async preview. Check the same route
            // at admission, before creating a run or making a model request.
            if let route = await presenter.padRoute(commandText: text, selectedProfileID: selectedProfileID), let reason = route.unavailable {
                guard revision == interactionRevision else { return }
                invalidateRoutePreviews()
                quickPadController.refreshRoute()
                quickPadController.showTransientNotice(reason)
                return
            }
            let selection = await presenter.selection(forProfileID: selectedProfileID)
            // A pick that came back to composing keeps its link while its
            // note is still part of what is submitted (D6).
            // A re-run `/stance` decides afresh: it is never itself linked.
            let origin = isStanceRequest ? nil : pendingPickOrigin.flatMap { pending in
                annotations.contains { $0.id == pending.noteID } ? RunID(rawValue: pending.stanceRunID) : nil
            }
            let submission = try await environment.service.submit(text, modelSelection: selection, provenance: provenance, annotations: annotations, originRunID: origin)
            // A used link is spent; a re-run /stance decides afresh, so the
            // earlier pick's pending link goes with its dropped note.
            if origin != nil || isStanceRequest { pendingPickOrigin = nil }
            guard let runID = submission.runID else {
                if let notice = submission.annotationNotice { quickPadController.showTransientNotice(notice) }
                // An id never asks for a proposal (D1); the pad already says
                // so for a note, this covers any other way in.
                else if submission.kind == .disabled, OmniIDAddress(text) != nil {
                    quickPadController.showTransientNotice(annotations.isEmpty ? OmniCommandPadViewController.idOpensFromLauncherLine : OmniCommandPadViewController.annotatedIDLine)
                }
                return
            }
            let id = runID.rawValue
            await afterQuickAdmission?(id)
            let effectiveGesture = pending.gesture
            let shape: OmniCommandShape = submission.kind == .tier2Proposing ? .proposal : shape(forCommandText: text)
            // The proposal permission trigger predates H11. Ordinary Enter
            // asks only if/when the person leaves this working run.
            if shape == .proposal, effectiveGesture == .enterShowHere { requestAuthorizationIfNeeded() }
            let current = pending.sequence == latestQuickSubmission && revision == interactionRevision && foreground.submit(runID: id, gesture: effectiveGesture, expectedGeneration: expectedGeneration)
            guard current else {
                // Close/replacement during async admission must not orphan
                // the new run or overwrite the next invocation's draft.
                if effectiveGesture.runsFromPad {
                    if shape == .proposal { proposalCouriersOwed.insert(id) }
                    expectNotification(for: id, shape: shape)
                }
                try? await refreshResults(orderWindows: false)
                return
            }
            saveActiveComposerDraft()
            composerKey = nil
            interactionRevision += 1
            selectedRunID = id
            selectedVersion = nil
            followsLatestVersion = true
            if effectiveGesture.runsFromPad {
                padRunID = id
                padRunShape = shape
                renderedInPadRunIDs.remove(id)
                let token = environment.service.parser.parse(text).dispatchToken ?? ""
                padResultSummary = shape == .proposal ? OmniCommandPadViewController.waitingLine : (routeSummary.isEmpty ? OmniPadVocabulary.outcome(for: token) : routeSummary)
                if let notice = submission.annotationNotice { padResultSummary += " · " + notice }
                quickPadController.beginWorking(runID: id, requestText: text, annotations: annotations, summary: padResultSummary, provenance: stashImport?.chip)
            }
            // A submit consumes its draft, but edits made during async
            // admission are a newer unsent draft and must survive.
            if quickPadController.editor.string == (visibleDraft ?? text) {
                setQuickText("")
                setQuickProvenance(nil)
            }
            quickPadController.closeAnnotationPanels()
            if effectiveGesture == .commandEnterAttach {
                padRunID = nil
                padRunShape = nil
                quickPadController.returnToComposing()
                if let notice = submission.annotationNotice { quickPadController.showTransientNotice(notice) }
                quickPanel?.orderOut(nil)
                if presentsInterface {
                    workspace.showWorkspace()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            if effectiveGesture == .commandYClose {
                // The stash chord (D4): closing now is a working close (C53),
                // so the run detaches and its receipt is the arrival.
                dismissQuickPad(restoreFocus: true)
            }
            try await refreshResults(orderWindows: effectiveGesture == .commandEnterAttach)
        } catch {
            if revision == interactionRevision { quickPadController.showTransientNotice("Unable to submit: \(error)") }
        }
    }

    private func submitWorkspace(text: String, annotations: [OmniTextAnnotation] = []) async {
        if let key = composerKey {
            let submittedDraft = AnnotatedDraft(text: text, annotations: annotations)
            followUpDrafts[key] = submittedDraft
            persistFollowUpDrafts()
            do {
                guard let runID = RunID(rawValue: key.runID) else { return }
                try await environment.service.submitFollowUp(
                    runID: runID,
                    sourceVersion: key.sourceVersion,
                    visibleText: text,
                    annotations: annotations
                )
                await afterFollowUpAdmission?()
                if let notice = await environment.service.followUpState(runID: runID)?.annotationNotice {
                    workspace.showComposerNotice(notice)
                }
                expectedFollowUpVersionByRunID[key.runID] =
                    (versionsByRunID[key.runID]?.map(\.number).max() ?? key.sourceVersion) + 1
                expectNotification(for: key.runID, shape: shape(ofRun: key.runID))
                // The editor stays live while admission awaits the service.
                // Keep any newer local draft; a selection change must not
                // dismiss or rewrite the composer for another run.
                let stillEditingSubmittedRun = composerKey == key
                    && selectedRunID == key.runID
                    && workspace.isShowingComposer
                if stillEditingSubmittedRun {
                    let liveDraft = AnnotatedDraft(text: workspace.editor.string, annotations: workspace.annotations)
                    if liveDraft != submittedDraft {
                        followUpDrafts[key] = liveDraft
                        persistFollowUpDrafts()
                    }
                }
                if followUpDrafts[key] == submittedDraft {
                    followUpDrafts.removeValue(forKey: key)
                    persistFollowUpDrafts()
                    if stillEditingSubmittedRun {
                        composerKey = nil
                        followsLatestVersion = true
                        interactionRevision += 1
                    }
                }
                try await refreshResults(orderWindows: true)
            } catch {
                if composerKey == key, selectedRunID == key.runID, workspace.isShowingComposer {
                    let liveDraft = AnnotatedDraft(text: workspace.editor.string, annotations: workspace.annotations)
                    if liveDraft != submittedDraft {
                        followUpDrafts[key] = liveDraft
                        persistFollowUpDrafts()
                    }
                    workspace.showComposerNotice("Unable to submit: \(error)")
                }
            }
            return
        }

        // New requests start in the pad. An unanchored workspace editor has no
        // result version to continue, so leave its live text and notes alone.
        workspace.showComposerNotice("Continue from a result version to apply a follow-up")
    }

    private func selectRun(_ value: String) async {
        guard modelsByRunID[value] != nil else { return }
        runOpened(value)
        saveActiveComposerDraft()
        composerKey = nil
        interactionRevision += 1
        selectedRunID = value
        selectedVersion = nil
        followsLatestVersion = true
        await loadAndDisplayResult(runID: value, expectedRevision: interactionRevision)
    }

    private func selectVersion(_ number: Int) {
        guard let runID = selectedRunID else { return }
        saveActiveComposerDraft()
        composerKey = nil
        interactionRevision += 1
        selectedVersion = number
        followsLatestVersion = false
        displayCachedResult(runID: runID)
    }

    /// Shown when Continue is requested on a result that no model wrote. The
    /// button is hidden for such runs; a programmatic Continue is refused in
    /// this one line instead of failing later for a missing model policy.
    public static let continueUnavailableNotice = "Continue needs a model-written result; this one was produced locally."

    private func beginFollowUp(runID: String, sourceVersion: Int) async {
        guard let model = modelsByRunID[runID],
              model.find == nil,
              OmniCommandShape.supportsFollowUp(moduleID: model.moduleID, manifest: environment.service.parser.manifest)
        else {
            workspace.showResultNotice(Self.continueUnavailableNotice)
            return
        }
        saveActiveComposerDraft()
        interactionRevision += 1
        selectedRunID = runID
        selectedVersion = sourceVersion
        followsLatestVersion = false
        let revision = interactionRevision
        if versionsByRunID[runID] == nil, let id = RunID(rawValue: runID) {
            versionsByRunID[runID] = try? await environment.service.resultVersions(runID: id)
        }
        guard revision == interactionRevision, selectedRunID == runID else { return }
        guard let source = versionsByRunID[runID]?.first(where: { $0.number == sourceVersion }) else { return }
        let key = DraftKey(runID: runID, sourceVersion: sourceVersion)
        let draft = followUpDrafts[key] ?? followUpStatesByRunID[runID].flatMap {
            $0.sourceVersion == sourceVersion
                && $0.kind != .pending
                && !discardedFollowUpRequestIDs.contains($0.requestID)
                ? AnnotatedDraft(text: $0.visibleText, annotations: $0.annotations) : nil
        } ?? AnnotatedDraft(text: source.resultText + "\n\n", annotations: [])
        composerKey = key
        restoringComposer = true
        workspace.showComposer(
            text: draft.text,
            runID: runID,
            sourceVersion: sourceVersion,
            sourceLabel: "Continuing version \(sourceVersion) · add /shorter or /formal",
            annotations: draft.annotations
        )
        restoringComposer = false
        placeWorkspaceCaretAtEnd()
    }

    private func cancelRunOrFollowUp(runID value: String) async {
        guard let runID = RunID(rawValue: value) else { return }
        do {
            if let state = await environment.service.followUpState(runID: runID), state.kind == .pending {
                let key = DraftKey(runID: value, sourceVersion: state.sourceVersion)
                if composerKey == key, workspace.isShowingComposer {
                    followUpDrafts[key] = AnnotatedDraft(text: workspace.editor.string, annotations: workspace.annotations)
                } else if followUpDrafts[key] == nil {
                    followUpDrafts[key] = AnnotatedDraft(text: state.visibleText, annotations: state.annotations)
                }
                persistFollowUpDrafts()
                try await environment.service.cancelFollowUp(runID: runID)
                expectedFollowUpVersionByRunID.removeValue(forKey: value)
            } else {
                try await environment.service.cancel(runID: runID)
            }
            interactionRevision += 1
            try await refreshResults(orderWindows: true)
        } catch {
            await loadAndDisplayResult(runID: value, expectedRevision: interactionRevision)
        }
    }

    private func copyResult(runID: String, version: Int) {
        if let find = modelsByRunID[runID]?.find,
           find.rows.contains(where: { !canUseIndexedPath($0.path) }) {
            workspace.showResultNotice("A source in this result is no longer available in Glacier.")
            return
        }
        guard var text = versionsByRunID[runID]?.first(where: { $0.number == version })?.resultText else { return }
        if let model = modelsByRunID[runID] { text = readableResult(text, of: model) }
        pasteboardWriter(text)
    }

    private func latestResultText(runID: String) async -> String? {
        guard let id = RunID(rawValue: runID) else { return nil }
        let versions = (try? await environment.service.resultVersions(runID: id)) ?? []
        return versions.max { $0.number < $1.number }?.resultText
            ?? modelsByRunID[runID]?.fullText ?? modelsByRunID[runID]?.detail
    }

    private func copyPadResult(runID: String) async {
        guard padRunID == runID, quickPadController.result?.kind == .text else { return }
        guard let text = await latestResultText(runID: runID), padRunID == runID,
              quickPadController.result?.kind == .text else { return }
        pasteboardWriter(text)
        dismissQuickPad()
    }

    private func retryPadResult(runID: String) async {
        guard padRunID == runID, let id = RunID(rawValue: runID),
              let model = modelsByRunID[runID], model.actions.contains(.retry),
              case .failure(retryAllowed: true) = quickPadController.result?.kind else { return }
        let generation = foreground.snapshot().uiGeneration
        let revision = interactionRevision
        let request = quickPadController.submittedRequestText
        let provenance = quickPadController.submittedProvenance
        let shape = confirmedProposalShapes[runID]?.shape ?? padRunShape ?? shape(ofRun: runID)
        // Retry keeps its existing in-context permission trigger.
        requestAuthorizationIfNeeded()
        runOpened(runID)
        do {
            let submission = try await environment.service.retry(runID: id)
            guard let newID = submission.runID?.rawValue else { return }
            let newShape: OmniCommandShape = submission.kind == .tier2Proposing ? .proposal : shape
            guard padRunID == runID, interactionRevision == revision, foreground.isCurrent(generation: generation) else {
                if newShape == .proposal { proposalCouriersOwed.insert(newID) }
                expectNotification(for: newID, shape: newShape)
                try? await refreshResults(orderWindows: false)
                return
            }
            padRunID = newID
            padRunShape = newShape
            selectedRunID = newID
            selectedVersion = nil
            followsLatestVersion = true
            let summary = submission.annotationNotice.map { padResultSummary + " · " + $0 } ?? padResultSummary
            quickPadController.beginWorking(runID: newID, requestText: request, annotations: model.annotations, summary: summary, provenance: provenance)
            try? await refreshResults(orderWindows: false)
        } catch {
            guard padRunID == runID else { return }
            quickPadController.showResult(runID: runID, result: OmniPadResult(kind: .failure(retryAllowed: false), body: "Retry not possible: \(error)", summary: "Unable to retry"))
        }
    }

    private func loadAndDisplayResult(runID: String, expectedRevision: Int) async {
        guard let id = RunID(rawValue: runID) else { return }
        async let versionsRequest = environment.service.resultVersions(runID: id)
        async let stateRequest = environment.service.followUpState(runID: id)
        async let receiptRequest = environment.store.receipt(for: id)
        let versions = (try? await versionsRequest) ?? []
        let state = await stateRequest
        let receipt = await receiptRequest
        guard !isQuitting, !Task.isCancelled else { return }
        versionsByRunID[runID] = versions
        if let receipt { submittedInputsByRunID[runID] = receipt.runtimeContext?.input?.rawText ?? receipt.commandText }
        if let state {
            followUpStatesByRunID[runID] = state
            if state.kind != .pending {
                expectedFollowUpVersionByRunID.removeValue(forKey: runID)
                if !recoveredFollowUpRequestIDs.contains(state.requestID),
                   !discardedFollowUpRequestIDs.contains(state.requestID) {
                    let key = DraftKey(runID: runID, sourceVersion: state.sourceVersion)
                    if followUpDrafts[key] == nil {
                        followUpDrafts[key] = AnnotatedDraft(text: state.visibleText, annotations: state.annotations)
                        persistFollowUpDrafts()
                    }
                    recoveredFollowUpRequestIDs.insert(state.requestID)
                }
            }
        } else {
            followUpStatesByRunID.removeValue(forKey: runID)
        }
        guard expectedRevision == interactionRevision, composerKey == nil, selectedRunID == runID else { return }
        if followsLatestVersion {
            selectedVersion = versions.map(\.number).max() ?? 0
            if let expected = expectedFollowUpVersionByRunID[runID],
               versions.contains(where: { $0.number == expected }) {
                expectedFollowUpVersionByRunID.removeValue(forKey: runID)
            }
        } else if selectedVersion == nil || !versions.contains(where: { $0.number == selectedVersion }) {
            selectedVersion = versions.map(\.number).max() ?? 0
        }
        displayCachedResult(runID: runID)
    }

    private func displayCachedResult(runID: String) {
        guard let model = modelsByRunID[runID] else { return }
        let versions = versionsByRunID[runID] ?? []
        let state = followUpStatesByRunID[runID]
        let pendingText = state?.kind == .pending ? state?.visibleText : nil
        let status: String
        if let state {
            status = state.message.map { "\(state.kind.rawValue) · \($0)" } ?? state.kind.rawValue
        } else {
            status = model.state.rawValue
        }
        let projected = DisplayedResult(
            runID: runID,
            title: model.title,
            status: status,
            versions: versions.map { workspaceVersion($0, of: model) },
            selectedVersion: selectedVersion ?? versions.map(\.number).max() ?? 0,
            pendingText: pendingText,
            pendingAnnotations: state?.kind == .pending ? state?.annotations ?? [] : [],
            submittedInput: submittedInputsByRunID[runID],
            submittedAnnotations: model.annotations,
            resumeAvailable: followUpDrafts[DraftKey(
                runID: runID,
                sourceVersion: selectedVersion ?? versions.map(\.number).max() ?? 0
            )] != nil,
            canCancel: state?.kind == .pending || model.actions.contains(.cancel),
            header: OmniWorkspaceRunHeader(
                token: Self.commandToken(of: model),
                provenance: model.provenance.flatMap(Self.provenanceLine(for:)),
                submittedAt: model.submittedAt,
                origin: Self.originLabel(for: model),
                route: Self.routeLabel(for: model, manifest: environment.service.parser.manifest, sampleReplies: sampleRepliesRoute || environment.providerRuntime?.registry.isFixture == true)
            ),
            composerRoute: [composerRoute(for: model), state?.annotationNotice ?? model.annotationNotice].compactMap { $0 }.joined(separator: " · "),
            annotationNotice: state?.annotationNotice ?? model.annotationNotice
        )
        guard projected != lastDisplayedResult || workspace.isShowingComposer else { return }
        lastDisplayedResult = projected
        workspace.displayResult(
            runID: projected.runID,
            title: projected.title,
            status: projected.status,
            versions: projected.versions,
            selectedVersion: projected.selectedVersion,
            pendingText: projected.pendingText,
            submittedInput: projected.submittedInput,
            resumeAvailable: projected.resumeAvailable,
            canCancel: projected.canCancel,
            header: projected.header,
            composerRoute: projected.composerRoute,
            annotationNotice: projected.annotationNotice,
            pendingAnnotations: projected.pendingAnnotations,
            submittedAnnotations: projected.submittedAnnotations,
            // A `/find` result is a list to act on, never a draft (D2).
            continueAvailable: OmniCommandShape.supportsFollowUp(moduleID: model.moduleID, manifest: environment.service.parser.manifest) && model.find == nil,
            pickerRows: model.find.map { permittedFind($0).rows } ?? []
        )
    }

    /// The one provenance formatter (D3) over a stored record; records from
    /// before bundle identifiers were captured fall back to a name lookup.
    nonisolated static func provenanceLine(for provenance: OmniRunProvenance) -> OmniProvenanceLine? {
        OmniProvenanceLine(appName: provenance.appName, windowTitle: provenance.windowTitle, bundleIdentifier: provenance.bundleIdentifier)
    }

    /// What ran the run, for the header (D3): the provider's route-line name
    /// when a model attempt was recorded, `On this Mac` when the command has
    /// no model tier, nil when a model command recorded no attempt (it did
    /// not run anywhere worth naming) or for proposals.
    nonisolated static func routeLabel(for model: ResultViewModel, manifest: CommandManifest, sampleReplies: Bool) -> String? {
        if let record = model.modelRecord {
            guard let attempt = record.attempts.last(where: { $0.outcome == .succeeded }) ?? record.attempts.last else { return nil }
            if sampleReplies || attempt.identity?.fixture == true { return "Sample replies" }
            let profile = ProviderRuntimeCatalog.profile(attempt.identity?.profileID ?? attempt.providerID)
            guard let connectionID = attempt.identity?.connectionID ?? profile?.connectionID else { return nil }
            return ProviderSettingsPresenter.providerName(connectionID: connectionID, displayName: profile?.displayName ?? connectionID)
        }
        guard let moduleID = model.moduleID,
              let command = manifest.commands.first(where: { $0.moduleID == moduleID && $0.role == .primary })
        else { return nil }
        // `/find` is declared model-backed for its tier 3 (D2). A run of it
        // that answered with no model attempt answered from the docs index on
        // this Mac; so did one that failed when its query never asks a model
        // (an id, filters, offline words). A words run that failed before any
        // attempt ran nowhere to name.
        if command.execution == .modelBacked {
            guard command.capabilities.contains(.readIndex) else { return nil }
            guard model.find.map({ !$0.ranModel }) ?? !Self.findAsksModel(model.commandText) else { return nil }
        }
        return OmniWorkspaceRunHeader.localRoute
    }

    /// Whether a stored `/find` command text would ask a model: words, online.
    nonisolated static func findAsksModel(_ commandText: String) -> Bool {
        !commandText.split(whereSeparator: \.isWhitespace).contains("/offline")
            && FindQuery(payload: SlashTokenSyntax.payloadText(from: commandText)).asksModel
    }

    /// A `/find` picker row (D2): open, reveal or copy the path of the row
    /// the receipt stored at `index`. The path comes from the run's stored
    /// result, never from editor text; it must still exist.
    func performFindRowAction(runID: String, index: Int, action: OmniPickerAction, fromWorkspace: Bool = false) async {
        // Notices go to the surface that asked: the pad is not on screen
        // when a workspace row is acted on.
        let notice: (String) -> Void = { [weak self] text in
            if fromWorkspace { self?.workspace.showResultNotice(text) } else { self?.quickPadController.showTransientNotice(text) }
        }
        guard let id = RunID(rawValue: runID) else { return }
        let rows: [OmniFindRow]
        if let model = modelsByRunID[runID], let find = model.find {
            rows = find.rows
        } else if let model = await environment.service.resultViewModel(runID: id), let find = model.find {
            rows = find.rows
        } else {
            return
        }
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        guard canUseIndexedPath(row.path) else {
            notice("This source is no longer available in Glacier.")
            return
        }
        let url = URL(fileURLWithPath: row.path).standardizedFileURL
        guard row.path.hasPrefix("/"), FileManager.default.fileExists(atPath: url.path) else {
            notice("\(row.title) is no longer at \(row.path)")
            return
        }
        switch action {
        case .copyPath:
            pasteboardWriter(row.path)
        case .open, .reveal:
            do {
                if let launcher {
                    // The launcher's openers and checks (policy, canonical
                    // path, exclusions), as for a launched row.
                    try await launcher.openFound(path: row.path, title: row.title, kind: row.kind, action: action == .reveal ? .reveal : .open)
                } else if !environment.platformReachesTheOS {
                    // Fixture and recorded hosts: the recorder keeps it.
                    _ = try await environment.platform.perform(action == .reveal ? .revealFile(url) : .openFile(url))
                } else {
                    // Live actions with no launcher composed (the isolated
                    // release, a degraded installed host): the launcher's
                    // checks are not here, so open and reveal stay off, as
                    // they were for resolver results before. Copy works.
                    notice(Self.findOpenNeedsLauncherLine)
                    return
                }
            } catch {
                notice("Couldn't \(action == .reveal ? "reveal" : "open") \(row.title) · \(error)")
                return
            }
            // Like a launcher open (C58): the opened file is the feedback.
            if quickPadController.mode == .result(runID: runID) { dismissQuickPad(restoreFocus: false) }
        }
    }

    static let findOpenNeedsLauncherLine = "Open and reveal need the launcher · ⌥⌘C copies the path"

    /// `from /stance · <position>` on a draft picked from positions (D6).
    nonisolated static func originLabel(for model: ResultViewModel) -> String? {
        guard model.originRunID != nil else { return nil }
        let base = "from " + OmniDecisionStep.stanceToken
        return model.annotations.first { $0.isRequestScoped && $0.label != nil }?.label.map { "\(base) · \($0)" } ?? base
    }

    /// `Follow-up · new version in this run · Cerebras` (C37); the provider
    /// comes from the same cached route the pad uses.
    private func composerRoute(for model: ResultViewModel) -> String {
        let base = "Follow-up · new version in this run"
        let token = Self.commandToken(of: model)
        guard !token.isEmpty else { return base }
        if sampleRepliesRoute { return "\(base) · Sample replies" }
        if let cached = padRouteCache["\(token)|false|"], let provider = cached?.providerName { return "\(base) · \(provider)" }
        return base
    }

    private func saveActiveComposerDraft() {
        guard let composerKey, !restoringComposer else { return }
        followUpDrafts[composerKey] = AnnotatedDraft(text: workspace.editor.string, annotations: workspace.annotations)
        persistFollowUpDrafts()
    }

    private func persistFollowUpDrafts() {
        followUpDraftRevision &+= 1
        let drafts = followUpDrafts.map { key, value in
            StoredFollowUpDraft(runID: key.runID, sourceVersion: key.sourceVersion, text: value.text, annotations: value.annotations)
        }.sorted { ($0.runID, $0.sourceVersion) < ($1.runID, $1.sourceVersion) }
        do {
            try followUpDraftStore.save(FollowUpDraftDocument(drafts: drafts, discardedRequestIDs: discardedFollowUpRequestIDs.sorted()))
            draftPersistenceError = nil
        } catch {
            draftPersistenceError = "Unable to save follow-up drafts: \(error.localizedDescription)"
            workspace.showComposerNotice("Your follow-up draft could not be saved")
        }
    }

    private func displayRowsIfChanged(_ rows: [OmniWorkspaceRunRow]) {
        guard rows != lastDisplayedRows || workspace.selectedRunID != selectedRunID else { return }
        lastDisplayedRows = rows
        workspace.displayRuns(rows, selectedID: selectedRunID)
    }

    /// Registers "restore this chip" on the field's undo stack; performing it
    /// registers the inverse, so redo after an undone import brings the
    /// selection's chip back with its text.
    private func registerProvenanceRestore(_ provenance: OmniRunProvenance?, selectionText: String?) {
        quickPadController.editor.undoManager?.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.registerProvenanceRestore(controller.quickProvenance, selectionText: controller.quickSelectionText)
                controller.setQuickProvenance(provenance, selectionText: selectionText)
            }
        }
    }

    // MARK: Launcher (H10, C50–C52)

    private func configureLauncher(_ launcher: LauncherService) {
        let pipeline = LauncherQueryPipeline(service: launcher)
        launcherPipeline = pipeline
        let pad = quickPadController
        pad.launcherHome = launcher.home
        pad.onLauncherQuery = { [weak self, weak pad, weak pipeline] text in
            guard let self, let pad, self.canInvoke("launcher.open") else { return }
            pipeline?.submit(text, lane: pad.launcherLane) { [weak self, weak pad] results in
                guard let self, self.canInvoke("launcher.open"), let pad, pad.launcherEnabled else { return }
                pad.showLauncherResults(results)
            }
        }
        pad.onResolveLauncher = { [weak self, weak pad] text in
            guard self?.canInvoke("launcher.open") == true else { return nil }
            return launcher.query(text, lane: pad?.launcherLane ?? .curated)
        }
        pad.onLaunch = { [weak self] candidateID, action, context in
            guard self?.canInvoke("launcher.open") == true else { return }
            Task { await self?.launch(candidateID: candidateID, action: action, context: context) }
        }
        pad.onLauncherFallthrough = { [weak self] context in
            guard self?.canInvoke("launcher.open") == true else { return }
            launcher.recordFallthrough(context)
        }
        pad.onCopyPath = { [weak self] path in
            guard let self else { return }
            guard self.canInvoke("launcher.open") else { return }
            guard self.canUseIndexedPath(path) else {
                self.quickPadController.showTransientNotice("This source is no longer available in Glacier.")
                return
            }
            self.pasteboardWriter(path)
        }
        pad.onLauncherHealth = { [weak self, weak pad] in
            guard self?.canInvoke("launcher.open") == true else { return nil }
            return launcher.healthLine(lane: pad?.launcherLane ?? .curated)
        }
        pad.onIDLookupPending = { [weak self] in self?.canInvoke("launcher.open") == true && launcher.idLookupPending }
        launcher.setIndexChangeHandler { [weak self] in
            Task { @MainActor in
                guard self?.canInvoke("launcher.open") == true else { return }
                self?.quickPadController.refreshLauncherResults()
            }
        }
        pad.launcherEnabled = canInvoke("launcher.open")
    }

    /// A launch is a deterministic open (C4): no run, no receipt, no
    /// notification; the opened app's arrival is the feedback. The pad
    /// closes without restoring focus, and ⌘Z in the pad restores the query.
    private func launch(candidateID: String, action: LauncherOpenAction, context: LaunchContext) async {
        // An exact-id hit (D1) opens through the lane that holds it, which
        // may not be the pad's lane: an agent-output document found from the
        // curated lane opens through the everywhere opener.
        let padLane = quickPadController.launcherLane
        guard canInvoke("launcher.open"), let launcher, !launchInFlight, quickPadController.annotations.isEmpty,
              padLane == context.lane || OmniIDAddress(context.query) != nil else { return }
        guard let candidate = launcher.candidate(id: candidateID, lane: context.lane),
              canUseIndexedPath(candidate.path) else {
            quickPadController.showTransientNotice("This source is no longer available in Glacier.")
            return
        }
        launchInFlight = true
        defer { launchInFlight = false }
        let revision = interactionRevision
        let query = quickPadController.editor.string
        let title = candidate.title
        do {
            try await launcher.launch(candidateID: candidateID, action: action, context: context)
        } catch {
            guard revision == interactionRevision else { return }
            // Enter must never go dead on a row that cannot open: fresh rows,
            // the row marked, *Ask for a proposal instead* first.
            // Both launcher and platform errors describe themselves in words.
            let reason = String(describing: error)
            quickPadController.markLaunchFailed(candidateID: candidateID)
            quickPadController.showTransientNotice("Couldn't open \(title) · \(reason)")
            return
        }
        guard revision == interactionRevision else { return }
        launcherPipeline?.cancel()
        // The field moved on while the open ran (new text, or Enter on the ask
        // row started a proposal): the open happened and is logged, but
        // nothing is cleared or closed under the user.
        let composing: Bool = switch quickPadController.mode {
        case .composing, .suggesting: true
        case .working, .result: false
        }
        guard composing, quickPadController.editor.string == query, quickPadController.annotations.isEmpty,
              quickPadController.launcherLane == padLane else { return }
        // A successful launch closes the pad like any other request. Register
        // its explicit recovery only after dismissal clears the old session.
        dismissQuickPad(restoreFocus: false)
        // Registered after the clear (`setQuickText` empties the undo stack),
        // in its own group like the replaced-draft restore (C27), so one ⌘Z
        // undoes exactly the launch whether or not a run-loop turn intervenes.
        if let undoManager = quickPadController.editor.undoManager {
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self) { controller in
                MainActor.assumeIsolated { controller.undoLaunch(query: query, candidateID: candidateID, lane: padLane, loggedLane: context.lane) }
            }
            undoManager.setActionName("Open")
            undoManager.endUndoGrouping()
            launchUndoRegisteredAt = launcher.now()
        }
    }

    private func dropLaunchUndo() {
        guard launchUndoRegisteredAt != nil else { return }
        quickPadController.editor.undoManager?.removeAllActions(withTarget: self)
        launchUndoRegisteredAt = nil
    }

    /// "The same pad session" (C50): the launch undo survives the pad
    /// closing on launch, but not a later visit.
    private func expireLaunchUndoIfStale() {
        guard let registered = launchUndoRegisteredAt, let launcher else { return }
        if launcher.now().timeIntervalSince(registered) > Self.launchUndoLifetime { dropLaunchUndo() }
    }

    /// ⌘Z after a launch (C50): the query comes back with the launched row
    /// marked and *Ask for a proposal instead* first; frecency forgets it.
    private func undoLaunch(query: String, candidateID: String, lane: LauncherLane, loggedLane: LauncherLane? = nil) {
        launchUndoRegisteredAt = nil
        guard let launcher else { return }
        // Only into a pristine, editable field: never under a pending
        // proposal, an imported selection, or text typed since.
        let editor = quickPadController.editor
        let pristine: Bool = switch quickPadController.mode {
        case .composing, .suggesting: editor.isEditable && quickPadController.provenance == nil
            && editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .working, .result: false
        }
        guard pristine else { return }
        quickPadController.setLauncherLane(lane)
        // Not `setQuickText`: this runs inside the undo manager's own undo,
        // and emptying its stack from here corrupts its grouping state.
        editor.string = query
        quickPadController.textDidChange(Notification(name: NSText.didChangeNotification))
        editor.setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
        // Frecency forgets the launch only when the undo was actually shown.
        if quickPadController.markLaunchUndo(candidateID: candidateID) {
            launcher.recordUndo(candidateID: candidateID, query: LauncherQuery(query).text, lane: loggedLane ?? lane)
        }
    }

    /// Programmatic text is a new draft: the undo stack belongs to the field
    /// the person is editing, not to a previous request (C27).
    private func setQuickText(_ text: String) {
        quickPadController.clearAnnotations()
        quickPadController.editor.string = text
        quickPadController.editor.undoManager?.removeAllActions()
        quickPadController.textDidChange(Notification(name: NSText.didChangeNotification))
        quickPadController.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    private func placeWorkspaceCaretAtEnd() {
        let length = (workspace.editor.string as NSString).length
        workspace.editor.setSelectedRange(NSRange(location: length, length: 0))
    }

    private func runRow(_ model: ResultViewModel) -> OmniWorkspaceRunRow {
        let hasDraft = followUpDrafts.keys.contains { $0.runID == model.runID }
        let activity: OmniWorkspaceRowActivity = switch RunActivityTracker.phase(of: model) {
        case .active: .running
        case .failed: .failed
        case .idle, .cancelled, .decision: .done
        }
        return OmniWorkspaceRunRow(
            id: model.runID,
            title: Self.derivedTitle(for: model),
            status: hasDraft ? "\(model.state.rawValue) · unsubmitted follow-up" : model.state.rawValue,
            summary: readableResult(model.fullText ?? model.detail, of: model),
            token: Self.commandToken(of: model),
            submittedAt: model.submittedAt,
            activity: activity
        )
    }

    /// The bare command token, or empty when the run has none (a proposal).
    nonisolated static func commandToken(of model: ResultViewModel) -> String {
        model.title.hasPrefix("/") ? model.title : ""
    }

    /// C34: `Reply · <subject>` once Mail provenance is stored; until then the
    /// first words of the request without its slash tokens and references.
    nonisolated static func derivedTitle(for model: ResultViewModel, wordLimit: Int = 6) -> String {
        if let provenance = model.provenance, provenance.appName == "Mail",
           let subject = provenance.windowTitle?.trimmingCharacters(in: .whitespaces), !subject.isEmpty,
           ["/email", "/msg", OmniDecisionStep.stanceToken].contains(model.title) {
            return model.title == OmniDecisionStep.stanceToken ? "Decide · \(subject)" : "Reply · \(subject)"
        }
        let words = model.commandText
            .split(whereSeparator: \.isWhitespace)
            .filter { !$0.hasPrefix("/") && !$0.hasPrefix("@") && $0 != "✓" && $0 != "✗" }
        let title = words.prefix(wordLimit).joined(separator: " ")
        if title.isEmpty {
            // A token-only run reads as its outcome, never as an identifier.
            return model.title.hasPrefix("/") ? OmniPadVocabulary.outcome(for: model.title) : model.title
        }
        return words.count > wordLimit ? title + "…" : title
    }

    /// A stored `/stance` result is canonical JSON; every text surface shows
    /// its positions instead. Other results pass through unchanged.
    private func readableResult(_ text: String, of model: ResultViewModel) -> String {
        if let find = model.find {
            return GlacierIndexedResultProjection.safeText(permittedFind(find))
        }
        guard OmniCommandShape.shape(moduleID: model.moduleID, manifest: environment.service.parser.manifest) == .optionsResult else { return text }
        return StanceResult.readable(text) ?? text
    }

    private func permittedFind(_ find: OmniFindResult) -> OmniFindResult {
        GlacierIndexedResultProjection.project(find, permits: canUseIndexedPath)
    }

    private func workspaceVersion(_ version: OmniResultVersion, of model: ResultViewModel? = nil) -> OmniWorkspaceVersion {
        OmniWorkspaceVersion(
            number: version.number,
            inputText: version.inputText,
            resultText: model.map { readableResult(version.resultText, of: $0) } ?? version.resultText,
            operation: version.operation.displayName,
            sourceVersion: version.sourceVersion,
            annotations: version.annotations
        )
    }

    private func currentVisibleFrame() -> NSRect {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? visibleFrame
    }

    private func selectionMessage(_ reason: OmniSelectionUnavailableReason) -> String {
        switch reason {
        case .accessibilityPermissionRequired: "Accessibility permission required"
        case .noFrontmostApplication: "no foreground application"
        case .excludedProcess: "Glacier already has focus"
        case .foregroundChanged: "foreground changed during capture"
        case .secureTextField: "secure text field"
        case .selectionTooLong: "selection is too long"
        case .sourceUnsupported: "source does not expose selection"
        case .sourceFailed(let code): "source failed (\(code))"
        case .timedOut: "capture timed out"
        }
    }
}

@MainActor
final class NativeWorkspaceMenuTarget: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func invoke(_ sender: Any?) {
        action()
    }
}

/// A host line in Omni's status menu: disabled state text, or an action.
public struct OmniStatusMenuExtra: Sendable {
    public let identifier: String
    public let title: String
    public let action: (@MainActor @Sendable () -> Void)?

    public init(identifier: String, title: String, action: (@MainActor @Sendable () -> Void)? = nil) {
        self.identifier = identifier
        self.title = title
        self.action = action
    }
}
