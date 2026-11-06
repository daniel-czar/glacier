import Foundation
import OmniCore

/// Destination of a deterministic write, for receipt wording (notification spec §5).
public enum OmniWriteDestination: String, Equatable, Sendable {
    case ledger = "Task list"
    case office = "Reminder queue"
    case favourites = "Favourites"
    case stash = "Stash"
    case base = "Notes"

    /// The wording for one run: a stash push that cost the bottom entry
    /// says so (C97, `/stash · stashed · oldest dropped`).
    public func receiptWording(summary: String?) -> String {
        self == .stash ? OmniStashReceipt.wording(summary: summary) : receiptWording
    }

    /// Notification wording for completed work.
    public var receiptWording: String {
        switch self {
        case .ledger: "added to task list"
        case .office: "kept in mind"
        case .favourites: "captured"
        case .stash: "stashed"
        case .base: "saved to notes"
        }
    }
}

/// The command *shape* decides whether and how a run notifies (C4, spec §3).
/// New commands inherit the rule from their manifest execution path and
/// capabilities; nothing is decided per command.
public enum OmniCommandShape: Equatable, Sendable {
    /// Model-backed text, `/find` whose result is a list to read, and a
    /// pure computation such as `/span`.
    case textResult
    /// Positions to pick from (`/stance`, amendment 1.4.0): notify like a
    /// text result when detached, but never offer Copy.
    case optionsResult
    case deterministicWrite(destination: OmniWriteDestination)
    /// `/g`, `/open`, `/rv`: the browser or Finder appearing is the arrival.
    case deterministicOpen
    case settings
    /// No module: a Tier 2 proposal run.
    case proposal
    case other

    public static func shape(moduleID: String?, manifest: CommandManifest) -> OmniCommandShape {
        guard let moduleID else { return .proposal }
        guard let command = manifest.commands.first(where: {
            $0.moduleID == moduleID && ($0.role == .primary || $0.role == .settings)
        }) else { return .other }
        switch command.execution {
        case .modelBacked:
            // The policy row's output shape is the one source: a command
            // whose result is options is never a text to copy.
            return ModelProviderPolicy.v6.command(named: moduleID)?.outputShape == .stancePositions ? .optionsResult : .textResult
        case .settings, .policy: return .settings
        case .deterministicLocal:
            let capabilities = Set(command.capabilities)
            // A local command that needs no capability is a pure computation
            // (`/span`, C82): it reaches nothing outside the run, so its only
            // observable result is the text it returns.
            if capabilities.isEmpty { return .textResult }
            if capabilities.contains(.readIndex) { return .textResult }
            if !capabilities.isDisjoint(with: [.openURL, .openTarget, .revealTarget]) { return .deterministicOpen }
            if capabilities.contains(.appendLedger) { return .deterministicWrite(destination: .ledger) }
            if capabilities.contains(.appendOfficeQueue) { return .deterministicWrite(destination: .office) }
            if capabilities.contains(.captureLink) { return .deterministicWrite(destination: .favourites) }
            if capabilities.contains(.writeCurrentStash) { return .deterministicWrite(destination: .stash) }
            if capabilities.contains(.captureBaseNote) { return .deterministicWrite(destination: .base) }
            return .other
        }
    }

    /// Whether a run's result can be continued: a follow-up rewrites a
    /// model's prose into a new version, so only a model-backed execution
    /// path with a prose output qualifies. Deterministic results have no
    /// model text to rewrite; positions and search queries are structured
    /// outputs that are acted on instead of continued.
    public static func supportsFollowUp(moduleID: String?, manifest: CommandManifest) -> Bool {
        guard let moduleID,
              let command = manifest.commands.first(where: {
                  $0.moduleID == moduleID && ($0.role == .primary || $0.role == .settings)
              }),
              command.execution == .modelBacked
        else { return false }
        return ModelProviderPolicy.v6.command(named: moduleID)?.outputShape != .findQuery
            && shape(moduleID: moduleID, manifest: manifest) != .optionsResult
    }
}

public enum OmniNotificationCategory: String, Equatable, Sendable, CaseIterable {
    case result = "omni.result"
    case failure = "omni.failure"
    case receipt = "omni.receipt"
    case proposal = "omni.proposal"
    case options = "omni.options"

    public var actions: [OmniNotificationAction] {
        switch self {
        case .result: [.copy, .open]
        case .failure: [.retry, .open]
        case .receipt: [.open]
        case .proposal: [.review]
        case .options: [.open]
        }
    }
}

public enum OmniNotificationAction: String, Equatable, Sendable {
    case copy
    case open
    case retry
    case review

    public var title: String {
        switch self {
        case .copy: "Copy result"
        case .open: "Open in Glacier"
        case .retry: "Retry"
        case .review: "Review"
        }
    }

    /// Foreground actions bring Omni forward; the others run quietly.
    public var bringsToForeground: Bool {
        switch self {
        case .open, .review: true
        case .copy, .retry: false
        }
    }
}

/// Semantic level only; never time-sensitive or critical (C5, spec §8).
public enum OmniNotificationInterruption: String, Equatable, Sendable {
    case active
    case passive
}

/// A renderer-neutral notification. The system client maps it to
/// `UNNotificationContent`; tests and headless hosts record it.
public struct OmniNotificationContent: Equatable, Sendable {
    public let runID: String
    public let versionNumber: Int
    public let category: OmniNotificationCategory
    public let title: String
    public let subtitle: String?
    public let body: String
    public let interruption: OmniNotificationInterruption

    /// The run ID: a later version replaces the delivered notification (spec §5).
    public var identifier: String { runID }
    public var threadIdentifier: String { runID }

    public init(
        runID: String,
        versionNumber: Int,
        category: OmniNotificationCategory,
        title: String,
        subtitle: String?,
        body: String,
        interruption: OmniNotificationInterruption
    ) {
        self.runID = runID
        self.versionNumber = versionNumber
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.interruption = interruption
    }
}

/// Maps a terminal run to its notification, or to none (spec §3–§5).
public enum RunNotificationPolicy {
    public static let previewLimit = 160

    public static func content(
        for model: ResultViewModel,
        shape: OmniCommandShape,
        outcome: RunActivityOutcome,
        provenance: String? = nil,
        tokenOverride: String? = nil
    ) -> OmniNotificationContent? {
        let token = tokenOverride.flatMap { $0.isEmpty ? nil : $0 } ?? model.title
        let version = max(model.versionCount, 1)
        let versionLabel: String? = version > 1 ? "v\(version)" : nil
        switch outcome {
        case .cancelled, .proposalReady:
            // Cancellation never notifies; the proposal courier belongs to the pad (H2).
            return nil
        case .failed:
            // A failed follow-up reports its own message, not v1's summary.
            let reason = model.followUpKind == .failed
                ? (model.followUpMessage ?? "The follow-up failed")
                : model.detail
            return OmniNotificationContent(
                runID: model.runID,
                versionNumber: version,
                category: .failure,
                title: "\(token) · failed",
                subtitle: joined([versionLabel, provenance]),
                body: firstLine(of: reason),
                interruption: .active
            )
        case .done:
            switch shape {
            case .textResult:
                return OmniNotificationContent(
                    runID: model.runID,
                    versionNumber: version,
                    category: .result,
                    title: "\(token) · done",
                    subtitle: joined([versionLabel, provenance]),
                    body: preview(of: model.fullText ?? model.detail),
                    interruption: .active
                )
            case .optionsResult:
                let first = (model.fullText.flatMap(StanceResult.parse)?.positions.first).map { "1. \($0.title) — \($0.approach)" }
                return OmniNotificationContent(
                    runID: model.runID,
                    versionNumber: version,
                    category: .options,
                    title: "\(token) · positions ready",
                    subtitle: joined([versionLabel, provenance]),
                    body: preview(of: first ?? model.detail),
                    interruption: .active
                )
            case .deterministicWrite(let destination):
                return OmniNotificationContent(
                    runID: model.runID,
                    versionNumber: version,
                    category: .receipt,
                    title: "\(token) · \(destination.receiptWording(summary: model.detail))",
                    subtitle: destination.rawValue,
                    // Deterministic writes store the request itself (spec §5:
                    // "the stored item's first line"); adapters set no fullText.
                    body: firstLine(of: model.fullText ?? requestBody(model.commandText).nonEmpty ?? model.detail),
                    interruption: .passive
                )
            case .deterministicOpen, .settings, .proposal, .other:
                return nil
            }
        }
    }

    /// The request without its slash tokens and references.
    static func requestBody(_ commandText: String) -> String {
        commandText.split(whereSeparator: \.isWhitespace)
            .filter { !$0.hasPrefix("/") && !$0.hasPrefix("@") }
            .joined(separator: " ")
    }

    static func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return preview(of: line)
    }

    /// Plain text, whitespace collapsed, cut on a word boundary.
    static func preview(of text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > previewLimit else { return collapsed }
        let head = collapsed.prefix(previewLimit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return String(cut) + "…"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
