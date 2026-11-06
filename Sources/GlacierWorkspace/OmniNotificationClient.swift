import AppKit
import Foundation
import UserNotifications

public enum OmniNotificationPermission: String, Equatable, Sendable {
    case notRequested
    case authorized
    case denied
    /// The process cannot register: not an app bundle, or no client composed.
    case unavailable
}

public enum OmniNotificationAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

/// The host's boundary to the system notification centre (H1). One
/// implementation talks to `UNUserNotificationCenter`; another records, for
/// tests and headless sessions. Delivery is fire-and-forget by design: a
/// notification is an event, never state the app depends on.
@MainActor
public protocol OmniNotificationClient: AnyObject {
    var availability: OmniNotificationAvailability { get }
    var permission: OmniNotificationPermission { get }
    /// Invoked on the main actor when the person acts on a delivered notification.
    var onAction: ((OmniNotificationAction, String) -> Void)? { get set }
    /// Asks once, in context, for `.alert` only (spec §7). Never nags.
    func requestAuthorizationIfNeeded() async -> OmniNotificationPermission
    /// Re-reads the grant so a revocation in System Settings shows up (spec §7).
    func refreshPermission() async
    func deliver(_ content: OmniNotificationContent) async
    /// Remove on open (C6): delivered and pending notifications for these runs.
    func withdraw(runIDs: [String])
}

/// Records instead of delivering. Tests drive it; headless and unbundled
/// hosts fall back to it so the rest of the host behaves identically.
@MainActor
public final class RecordingOmniNotificationClient: OmniNotificationClient {
    public let availability: OmniNotificationAvailability
    public private(set) var permission: OmniNotificationPermission
    public var onAction: ((OmniNotificationAction, String) -> Void)?
    public private(set) var delivered: [OmniNotificationContent] = []
    public private(set) var withdrawn: [String] = []
    public private(set) var authorizationRequests = 0
    /// When set, the ask stays open until `resolveAuthorization` is called,
    /// like the system prompt.
    public var deferredAuthorization = false
    private let grants: OmniNotificationPermission
    private var authorizationContinuations: [CheckedContinuation<Void, Never>] = []

    public init(grants: OmniNotificationPermission = .authorized, availability: OmniNotificationAvailability = .available) {
        self.grants = grants
        self.availability = availability
        if case .unavailable = availability { permission = .unavailable } else { permission = .notRequested }
    }

    public func requestAuthorizationIfNeeded() async -> OmniNotificationPermission {
        guard permission == .notRequested else { return permission }
        authorizationRequests += 1
        if deferredAuthorization {
            await withCheckedContinuation { authorizationContinuations.append($0) }
        }
        if permission == .notRequested { permission = grants }
        return permission
    }

    public func resolveAuthorization(_ outcome: OmniNotificationPermission) {
        permission = outcome
        let waiting = authorizationContinuations
        authorizationContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    public func refreshPermission() async {}

    public func deliver(_ content: OmniNotificationContent) async {
        guard permission == .authorized else { return }
        delivered.removeAll { $0.identifier == content.identifier }
        delivered.append(content)
    }

    public func withdraw(runIDs: [String]) {
        withdrawn.append(contentsOf: runIDs)
        delivered.removeAll { runIDs.contains($0.identifier) }
    }

    public func simulateAction(_ action: OmniNotificationAction, runID: String) {
        onAction?(action, runID)
    }
}

/// `UNUserNotificationCenter` client. Only an app bundle with an identifier
/// may construct it; a bare executable crashes inside the framework, so
/// `makeIfAvailable()` refuses instead.
@MainActor
public final class SystemOmniNotificationClient: NSObject, OmniNotificationClient, UNUserNotificationCenterDelegate {
    public static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    public static var unavailabilityReason: String? {
        guard Bundle.main.bundleIdentifier != nil else { return "process has no bundle identifier" }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return "process is not an app bundle" }
        return nil
    }

    /// The delegate is installed at construction, which the host performs
    /// during `applicationDidFinishLaunching` (spec §9).
    public static func makeIfAvailable() -> SystemOmniNotificationClient? {
        guard unavailabilityReason == nil else { return nil }
        return SystemOmniNotificationClient(center: UNUserNotificationCenter.current())
    }

    private let center: UNUserNotificationCenter
    public let availability: OmniNotificationAvailability = .available
    public private(set) var permission: OmniNotificationPermission = .notRequested
    public var onAction: ((OmniNotificationAction, String) -> Void)?

    init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        Task { await refreshPermission() }
    }

    static var categories: Set<UNNotificationCategory> {
        Set(OmniNotificationCategory.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: category.actions.map { action in
                    UNNotificationAction(
                        identifier: action.rawValue,
                        title: action.title,
                        options: action.bringsToForeground ? [.foreground] : []
                    )
                },
                intentIdentifiers: [],
                options: []
            )
        })
    }

    public func refreshPermission() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: permission = .notRequested
        case .denied: permission = .denied
        case .authorized, .provisional, .ephemeral: permission = .authorized
        @unknown default: permission = .denied
        }
    }

    public func requestAuthorizationIfNeeded() async -> OmniNotificationPermission {
        await refreshPermission()
        guard permission == .notRequested else { return permission }
        do {
            permission = try await center.requestAuthorization(options: [.alert]) ? .authorized : .denied
        } catch {
            permission = .denied
        }
        return permission
    }

    public func deliver(_ content: OmniNotificationContent) async {
        guard permission == .authorized else { return }
        let payload = UNMutableNotificationContent()
        payload.title = content.title
        if let subtitle = content.subtitle { payload.subtitle = subtitle }
        payload.body = content.body
        payload.categoryIdentifier = content.category.rawValue
        payload.threadIdentifier = content.threadIdentifier
        payload.interruptionLevel = content.interruption == .active ? .active : .passive
        payload.userInfo = [
            "runID": content.runID,
            "versionNumber": content.versionNumber,
            "kind": content.category.rawValue,
        ]
        let request = UNNotificationRequest(identifier: content.identifier, content: payload, trigger: nil)
        try? await center.add(request)
    }

    public func withdraw(runIDs: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: runIDs)
        center.removePendingNotificationRequests(withIdentifiers: runIDs)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The pad or workspace may be frontmost; the banner still shows (C1).
        [.banner, .list]
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        guard let runID = content.userInfo["runID"] as? String else { return }
        let category = OmniNotificationCategory(rawValue: content.categoryIdentifier)
        let action: OmniNotificationAction
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            action = category == .proposal ? .review : .open
        case UNNotificationDismissActionIdentifier:
            return
        default:
            guard let named = OmniNotificationAction(rawValue: response.actionIdentifier) else { return }
            action = named
        }
        await MainActor.run { self.onAction?(action, runID) }
    }
}
