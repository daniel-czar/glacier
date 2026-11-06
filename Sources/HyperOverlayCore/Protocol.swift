import Foundation

public enum OverlayCommand: String, Codable, Sendable {
    case show
    case close
    case ping
    case status
    case reloadHotkeys = "reload-hotkeys"
}

public enum OverlayResponseStatus: String, Codable, Sendable {
    case applied
    case rejected
    case error
}

public enum OverlayRuntimeState: String, Codable, Sendable {
    case idle
    case showing
    case closing
}

public struct OverlayRequest: Codable, Sendable {
    public var command: OverlayCommand
    public var overlay: String?
    public var requestID: String
    public var sentAt: String?

    enum CodingKeys: String, CodingKey {
        case command
        case overlay
        case requestID = "request_id"
        case sentAt = "sent_at"
    }

    public init(command: OverlayCommand, overlay: String?, requestID: String, sentAt: String? = nil) {
        self.command = command
        self.overlay = overlay
        self.requestID = requestID
        self.sentAt = sentAt
    }
}

public struct OverlayResponse: Codable, Equatable, Sendable {
    public var requestID: String
    public var status: OverlayResponseStatus
    public var state: OverlayRuntimeState
    public var overlay: String?
    public var generation: Int
    public var reason: String?
    public var host: OverlayHostStatus?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status
        case state
        case overlay
        case generation
        case reason
        case host
    }

    public init(
        requestID: String,
        status: OverlayResponseStatus,
        state: OverlayRuntimeState,
        overlay: String?,
        generation: Int,
        reason: String? = nil,
        host: OverlayHostStatus? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.state = state
        self.overlay = overlay
        self.generation = generation
        self.reason = reason
        self.host = host
    }
}

public struct OverlayHostStatus: Codable, Equatable, Sendable {
    public var processID: Int32
    public var resident: Bool
    public var hotkeysEnabled: Bool
    public var registeredOverlays: [String]
    public var manifestPath: String
    public var hotkeyError: String?
    public var appBundlePath: String?
    public var releaseVersion: String?
    public var sourceRevision: String?
    public var omni: OverlayOmniStatus?
    public var clipboard: [String: String]?
    /// The Hyper overlay (H18): what it draws and any binding problems.
    public var hyperKeys: [String: String]?
    /// Collect (H19): count, busy, paused, readiness; never content.
    public var collect: [String: String]?
    /// Every direct action's fires: count, last time, last outcome; never
    /// content (plan f71f8baac8f0149e).
    public var directActions: [String: String]?

    enum CodingKeys: String, CodingKey {
        case processID = "pid"
        case resident
        case hotkeysEnabled = "hotkeys_enabled"
        case registeredOverlays = "registered_overlays"
        case manifestPath = "manifest_path"
        case hotkeyError = "hotkey_error"
        case appBundlePath = "app_bundle_path"
        case releaseVersion = "release_version"
        case sourceRevision = "source_revision"
        case omni
        case clipboard
        case hyperKeys = "hyper_keys"
        case collect
        case directActions = "direct_actions"
    }

    public init(processID: Int32, resident: Bool, hotkeysEnabled: Bool, registeredOverlays: [String],
                manifestPath: String, hotkeyError: String?, appBundlePath: String?,
                releaseVersion: String? = nil, sourceRevision: String? = nil,
                omni: OverlayOmniStatus? = nil, clipboard: [String: String]? = nil,
                hyperKeys: [String: String]? = nil, collect: [String: String]? = nil,
                directActions: [String: String]? = nil) {
        self.processID = processID
        self.resident = resident
        self.hotkeysEnabled = hotkeysEnabled
        self.registeredOverlays = registeredOverlays
        self.manifestPath = manifestPath
        self.hotkeyError = hotkeyError
        self.appBundlePath = appBundlePath
        self.releaseVersion = releaseVersion
        self.sourceRevision = sourceRevision
        self.omni = omni
        self.clipboard = clipboard
        self.hyperKeys = hyperKeys
        self.collect = collect
        self.directActions = directActions
    }
}

/// Installed Omni activation facts on the resident host's ordinary status.
/// Absent when the explicit installed-live flag is off.
public struct OverlayOmniStatus: Codable, Equatable, Sendable {
    public var active: Bool
    public var supportRoot: String
    public var error: String?
    public var indexing: OverlayIndexingStatus?

    enum CodingKeys: String, CodingKey {
        case active
        case supportRoot = "support_root"
        case error
        case indexing
    }

    public init(active: Bool, supportRoot: String, error: String?, indexing: OverlayIndexingStatus? = nil) {
        self.active = active
        self.supportRoot = supportRoot
        self.error = error
        self.indexing = indexing
    }
}

/// Read-only operational facts. Kept in the host protocol without importing
/// Omni's application layer. Counter names are stable snake-case keys.
public struct OverlayIndexingStatus: Codable, Equatable, Sendable {
    public var state: String
    public var recoveryRequired: Bool
    public var cursor: UInt64?
    public var currentReason: String?
    public var pendingReason: String?
    public var lastFullSeconds: TimeInterval?
    public var nextRecoveryUnix: TimeInterval?
    public var counters: [String: UInt64]
    public var nativeExclusions: [String]

    enum CodingKeys: String, CodingKey {
        case state, cursor, counters
        case recoveryRequired = "recovery_required"
        case currentReason = "current_reason"
        case pendingReason = "pending_reason"
        case lastFullSeconds = "last_full_seconds"
        case nextRecoveryUnix = "next_recovery_unix"
        case nativeExclusions = "native_exclusions"
    }

    public init(state: String, recoveryRequired: Bool, cursor: UInt64? = nil,
                currentReason: String? = nil, pendingReason: String? = nil,
                lastFullSeconds: TimeInterval? = nil, nextRecoveryUnix: TimeInterval? = nil,
                counters: [String: UInt64] = [:], nativeExclusions: [String] = []) {
        self.state = state
        self.recoveryRequired = recoveryRequired
        self.cursor = cursor
        self.currentReason = currentReason
        self.pendingReason = pendingReason
        self.lastFullSeconds = lastFullSeconds
        self.nextRecoveryUnix = nextRecoveryUnix
        self.counters = counters
        self.nativeExclusions = nativeExclusions
    }
}

public enum OverlayProtocol {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> OverlayRequest {
        try decoder.decode(OverlayRequest.self, from: data)
    }

    public static func decodeResponse(_ data: Data) throws -> OverlayResponse {
        try decoder.decode(OverlayResponse.self, from: data)
    }
}
