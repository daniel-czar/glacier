import Foundation
import OmniCore

/// Port of `rh_probe.py`'s `TypeSafeBackend` (`research-harness/rh_probe.py`,
/// class around line 325) into a Swift conformer of `IntentJudge`
/// (`IntentJudge.swift`). Wire format: `POST {base}/v1/systemone`, bearer
/// auth, body `{"state": {...}, "model": ..., "questions": {...}}`, response
/// `{"answers": {...}, "usage": {...}}`.
///
/// Unwired by design (C52, file-finder handoff §5): nothing constructs this
/// type, and it is not registered in `ProviderRuntimeCatalog`,
/// `ModelProviderRegistry`, or `Phase5ModelProviderMatrix`. It exists so the
/// slow lane has a working, tested conformer ready for the trigger named in
/// the handoff, without granting the fast lane a live dependency today.
///
/// Choice-question wire shape: the Python client passes `criteria` through
/// opaquely, but `research-harness/README.md` ("Probe suite format") is
/// explicit — `criteria: {option_id: description}` for a `choice` question —
/// which matches the Jev README's per-row bars, `probabilities[cK]`. This
/// conformer follows that reading: `target`'s criteria keys are the row
/// labels `c1...cN`, one per supplied candidate, mirrored from the same text
/// written into the `candidates` state line.
///
/// Candidate text (`title`, `kind`, `evidence`) and the ambient context
/// values (frontmost app, clipboard kind) come from the filesystem and the
/// active session — untrusted content this type did not author. `requestBody`
/// sanitises every rendered field before it is interpolated into the
/// newline-delimited `candidates` state block: sanitisation stops row
/// forgery (a title that fakes an extra `cK: ...` line or a `·`-delimited
/// field), but it cannot stop persuasion — text that argues its own case to
/// the model once it is legitimately on its own row. That residual
/// prompt-injection surface is one reason this lane stays unwired and off by
/// default (see the "Unwired by design" paragraph above).
///
/// Unlike the Python client this ports, this conformer never reads
/// `TYPESAFE_BASE_URL` from the environment; `baseURL` is an ordinary init
/// parameter here, matching this repo's style of passing configuration in
/// rather than reading it from the process environment at construction time.
public struct TypeSafeIntentJudge: IntentJudge {
    public static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!
    public static let defaultModel = "jev-latest"

    private let transport: any ModelHTTPTransport
    private let credentials: any ModelCredentialResolver
    private let credentialReference: ModelCredentialReference
    private let baseURL: URL
    private let model: String
    private let timeoutSeconds: TimeInterval
    private let maximumRetries: Int
    private let initialBackoffSeconds: Double
    private let sleeper: @Sendable (Duration) async throws -> Void

    /// Credentials are never resolved here. `judge(_:sequence:)` resolves
    /// `credentialReference` lazily on every call, matching the runtime's
    /// "construction scans no credential" rule (`ProviderRegistry.swift`).
    /// `sleeper` stands in for the Python client's `time.sleep` between
    /// retries; tests inject a non-sleeping recorder so the suite never
    /// blocks on wall-clock time.
    public init(
        transport: any ModelHTTPTransport,
        credentials: any ModelCredentialResolver,
        credentialReference: ModelCredentialReference = .environmentVariable(name: "TYPESAFE_API_KEY"),
        baseURL: URL = TypeSafeIntentJudge.defaultBaseURL,
        model: String = TypeSafeIntentJudge.defaultModel,
        timeoutSeconds: TimeInterval = 60,
        maximumRetries: Int = 3,
        initialBackoffSeconds: Double = 2.0,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.credentials = credentials
        self.credentialReference = credentialReference
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.maximumRetries = maximumRetries
        self.initialBackoffSeconds = initialBackoffSeconds
        self.sleeper = sleeper
    }

    public func judge(_ state: JudgeState, sequence: UInt64) async throws -> Judgment {
        try state.validate()

        let secret: ModelResolvedSecret
        do {
            secret = try credentials.resolve(credentialReference)
        } catch {
            throw IntentJudgeError.missingCredential
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1").appendingPathComponent("systemone"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(state: state, model: model),
            options: [.sortedKeys]
        )
        secret.apply(to: &request, header: "Authorization", prefix: "Bearer ")

        // Mirrors the Python client's retry loop: up to `maximumRetries`
        // retries (so `maximumRetries + 1` total attempts) on 429/529, with
        // exponential backoff starting at `initialBackoffSeconds`. Any other
        // non-200 status fails immediately without retrying.
        var delaySeconds = initialBackoffSeconds
        for attempt in 0...maximumRetries {
            let response = try await transport.send(request)
            if response.statusCode == 200 {
                return try Self.judgment(from: response.body, state: state, sequence: sequence)
            }
            if response.statusCode == 429 || response.statusCode == 529 {
                guard attempt < maximumRetries else {
                    throw IntentJudgeError.retriesExhausted(
                        lastStatusCode: response.statusCode,
                        body: Self.truncatedBody(response.body)
                    )
                }
                try await sleeper(.seconds(delaySeconds))
                delaySeconds *= 2
                continue
            }
            throw IntentJudgeError.transport(statusCode: response.statusCode, body: Self.truncatedBody(response.body))
        }
        // Unreachable: every branch of the loop above returns or throws before
        // falling out the bottom. Kept only because the compiler cannot prove
        // that from a `for` loop over a non-empty, statically-unknown range.
        throw IntentJudgeError.retriesExhausted(lastStatusCode: -1, body: "")
    }

    /// Decodes `data` as UTF-8 and truncates it to 500 *characters*
    /// (`String.prefix`, grapheme-cluster counting) rather than 500 bytes, so
    /// a multi-byte character straddling the cut point is never split into an
    /// invalid byte sequence.
    private static func truncatedBody(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return String(text.prefix(500))
    }

    /// Renders `state` into the wire body: three string state fields (query,
    /// a compact context line, one `cK: title · kind · evidence` line per
    /// candidate) and three typed questions (`target` choice over `c1...cN`,
    /// `ready` noul, `action` choice over a fixed action-class vocabulary).
    static func requestBody(state: JudgeState, model: String) -> [String: Any] {
        var candidateLines: [String] = []
        var targetCriteria: [String: String] = [:]
        for (index, candidate) in state.candidates.enumerated() {
            let label = "c\(index + 1)"
            let title = sanitizeField(candidate.title)
            let kind = sanitizeField(candidate.kind)
            let evidence = sanitizeField(candidate.evidence)
            let line = "\(title) · \(kind) · \(evidence)"
            candidateLines.append("\(label): \(line)")
            targetCriteria[label] = line
        }
        let stateBlock: [String: String] = [
            "query": state.query,
            "context": contextLine(state.context),
            "candidates": candidateLines.joined(separator: "\n")
        ]
        let questions: [String: Any] = [
            "target": [
                "type": "choice",
                "instructions": "Which candidate row is the intended target of the query?",
                "criteria": targetCriteria
            ],
            "ready": [
                "type": "noul",
                "instructions": "Is the query unambiguous enough to open the top candidate on Enter without looking?",
                "criteria": [
                    "true": "The top candidate can be opened on Enter without looking at the row.",
                    "false": "The query is still ambiguous enough that looking before opening matters."
                ]
            ],
            "action": [
                "type": "choice",
                "instructions": "What class of action does this query intend?",
                "criteria": [
                    "open_app": "Launch or activate an application by name.",
                    "open_folder": "Open a folder location in Finder or an editor.",
                    "open_file": "Open a specific file with its default or house-convention app.",
                    "system_action": "Perform a deterministic system action such as sleep, lock, or dark mode.",
                    "web_search": "Search the web for the query text.",
                    "unclear": "None of the above fits confidently."
                ]
            ]
        ]
        return ["state": stateBlock, "model": model, "questions": questions]
    }

    static func contextLine(_ context: JudgeContext) -> String {
        let app = sanitizeField(context.frontmostAppBundleID ?? "unknown")
        let clipboard = sanitizeField(context.clipboardKind ?? "none")
        return "app=\(app) clipboard=\(clipboard) hour=\(context.localHour) weekday=\(context.weekday)"
    }

    /// Sanitises one rendered field (candidate title/kind/evidence, or a
    /// context value) before it is interpolated into the wire request: any
    /// run of `\r`, `\n`, or `\t` collapses to a single space (so untrusted
    /// text cannot forge an extra newline-delimited `cK: ...` row in the
    /// `candidates` state block), the `·` field separator is replaced with
    /// `-` (so it cannot fake an extra `title · kind · evidence` field), and
    /// the result is trimmed. This defeats row forgery; it does not and
    /// cannot defeat prompt injection — see the type-level doc comment.
    static func sanitizeField(_ raw: String) -> String {
        var collapsed = ""
        collapsed.reserveCapacity(raw.count)
        var previousWasControlWhitespace = false
        for character in raw {
            switch character {
            case "\r", "\n", "\t":
                if !previousWasControlWhitespace {
                    collapsed.append(" ")
                }
                previousWasControlWhitespace = true
            case "·":
                collapsed.append("-")
                previousWasControlWhitespace = false
            default:
                collapsed.append(character)
                previousWasControlWhitespace = false
            }
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Maps `{"answers": {"target": {"probabilities": {"cK": p, ...}}, "ready":
    /// {"noul": p}, "action": {"probabilities": {label: p, ...}}}}` back onto
    /// candidate ids. A `target` label that does not match a supplied
    /// candidate (`c1...cN`) is unrecognised and is silently dropped. A
    /// *recognised* `cK` label whose value cannot be parsed as a number (a
    /// string, `null`, an object, etc.) throws
    /// `IntentJudgeError.malformedResponse`, naming that label — a
    /// recognised label with an unparseable value is a confidently wrong
    /// distribution, not something to drop quietly. After dropping
    /// unrecognised labels the remaining mass is renormalised to sum to 1; a
    /// `target` with zero mass after dropping is also a malformed response,
    /// not a valid all-zero judgment.
    static func judgment(from body: Data, state: JudgeState, sequence: UInt64) throws -> Judgment {
        guard let top = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw IntentJudgeError.malformedResponse("response is not a JSON object")
        }
        guard let answers = top["answers"] as? [String: Any] else {
            throw IntentJudgeError.malformedResponse("response has no answers object")
        }
        guard let targetAnswer = answers["target"] as? [String: Any],
              let rawProbabilities = targetAnswer["probabilities"] as? [String: Any] else {
            throw IntentJudgeError.malformedResponse("target answer is missing probabilities")
        }

        var labelToID: [String: String] = [:]
        for (index, candidate) in state.candidates.enumerated() {
            labelToID["c\(index + 1)"] = candidate.id
        }

        var mapped: [String: Double] = [:]
        for (label, value) in rawProbabilities {
            guard let id = labelToID[label] else { continue }
            guard let probability = asDouble(value) else {
                throw IntentJudgeError.malformedResponse("target probability for \(label) is not a number")
            }
            mapped[id, default: 0] += probability
        }
        let totalMass = mapped.values.reduce(0, +)
        guard totalMass > 0 else {
            throw IntentJudgeError.malformedResponse("target probabilities sum to zero after dropping unrecognised labels")
        }
        let target = mapped.mapValues { $0 / totalMass }

        let ready = (answers["ready"] as? [String: Any]).flatMap { asDouble($0["noul"]) }
        let action = (answers["action"] as? [String: Any])
            .flatMap { $0["probabilities"] as? [String: Any] }
            .flatMap { probabilities -> String? in
                let doubled = probabilities.compactMapValues { asDouble($0) }
                // Dictionary iteration order is not guaranteed, so `max(by:)`
                // over ties is non-deterministic. Break ties explicitly on
                // the lexicographically smallest label.
                return doubled.sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }.first?.key
            }

        return Judgment(sequence: sequence, target: target, ready: ready, action: action)
    }

    private static func asDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
}
