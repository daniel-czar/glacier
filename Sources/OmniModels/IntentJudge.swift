import Foundation

/// The C52 slow-lane interface reserved by the file-finder handoff
/// (`docs/intent-extension/omni-intent-file-finder_2ba3b06ed1db135d.md`, §5).
/// The fast lane already narrowed the world to at most 15 candidate rows; a
/// judge only distributes probability mass over that closed set and never
/// returns free text or names a file itself. Defined now, wired to nothing:
/// no caller constructs an `IntentJudge`, and no provider catalog registers
/// one. It exists so a conformer can be built and tested ahead of the
/// trigger in §5 without granting the fast lane a live dependency.
public protocol IntentJudge: Sendable {
    /// Judges `state` for request `sequence`. Callers apply a judgment only
    /// when its `sequence` is the newest one they have sent — supersession by
    /// sequence number, never blocking on the network (handoff §5).
    func judge(_ state: JudgeState, sequence: UInt64) async throws -> Judgment
}

/// Ambient context in the Jev shape: enough to disambiguate a query without
/// ever carrying free text beyond the query itself. Kept deliberately
/// minimal; add fields only when a ranking rule needs them.
public struct JudgeContext: Sendable, Equatable {
    public let frontmostAppBundleID: String?
    public let clipboardKind: String?
    public let localHour: Int
    public let weekday: Int

    public init(
        frontmostAppBundleID: String? = nil,
        clipboardKind: String? = nil,
        localHour: Int = 0,
        weekday: Int = 1
    ) {
        self.frontmostAppBundleID = frontmostAppBundleID
        self.clipboardKind = clipboardKind
        self.localHour = localHour
        self.weekday = weekday
    }
}

/// One fast-lane row rendered as evidence text (age, folder, tags), never a
/// file's contents. The judge sees only what the caller chooses to write
/// into `evidence`; it has no filesystem access of its own. `title`, `kind`,
/// and `evidence` are untrusted, filesystem-derived text — a conformer must
/// sanitise them before interpolating them into a request to a model.
public struct CandidateEvidence: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: String
    public let evidence: String

    public init(id: String, title: String, kind: String, evidence: String) {
        self.id = id
        self.title = title
        self.kind = kind
        self.evidence = evidence
    }
}

/// The closed set handed to a judge on one keystroke: a query plus at most
/// 15 candidate rows the fast lane already selected. These value types are
/// pure data with no I/O; they could move to `OmniCore` later if something
/// outside `OmniModels` needs the shape without the network conformer.
public struct JudgeState: Sendable, Equatable {
    public let query: String
    public let context: JudgeContext
    public let candidates: [CandidateEvidence]

    public init(query: String, context: JudgeContext, candidates: [CandidateEvidence]) {
        self.query = query
        self.context = context
        self.candidates = candidates
    }

    /// Enforces the C52 closed-set shape: 1...15 candidates with unique ids.
    /// A conformer calls this before dispatch; it is not run at init so a
    /// caller assembling `candidates` incrementally can check once.
    public func validate() throws {
        guard (1...15).contains(candidates.count) else {
            throw IntentJudgeError.candidateCountOutOfRange(candidates.count)
        }
        var seenIDs = Set<String>()
        for candidate in candidates {
            guard seenIDs.insert(candidate.id).inserted else {
                throw IntentJudgeError.duplicateCandidateID(candidate.id)
            }
        }
    }
}

/// A judge's answer: a probability distribution over `state.candidates`
/// (candidate id -> 0...1, summing to 1 over the supplied candidates), and
/// optionally a ready probability and an action class. Never free text.
public struct Judgment: Sendable, Equatable {
    public let sequence: UInt64
    public let target: [String: Double]
    public let ready: Double?
    public let action: String?

    public init(sequence: UInt64, target: [String: Double], ready: Double? = nil, action: String? = nil) {
        self.sequence = sequence
        self.target = target
        self.ready = ready
        self.action = action
    }
}

public enum IntentJudgeError: Error, Sendable, Equatable, CustomStringConvertible {
    case candidateCountOutOfRange(Int)
    case duplicateCandidateID(String)
    case missingCredential
    case transport(statusCode: Int, body: String)
    case malformedResponse(String)
    case retriesExhausted(lastStatusCode: Int, body: String)

    public var description: String {
        switch self {
        case .candidateCountOutOfRange(let count): "candidate count \(count) is outside 1...15"
        case .duplicateCandidateID(let id): "duplicate candidate id \(id)"
        case .missingCredential: "no credential resolved for the slow-lane backend"
        case .transport(let statusCode, let body): "HTTP \(statusCode): \(body)"
        case .malformedResponse(let detail): "malformed response: \(detail)"
        case .retriesExhausted(let lastStatusCode, let body): "retries exhausted after HTTP \(lastStatusCode): \(body)"
        }
    }
}
