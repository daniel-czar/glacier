import Foundation
import OmniCore
import OmniModels
import OmniPresentation

/// The disposable pronunciation UI delegates lookup and playback to an
/// app-bundled helper. No ambient CLI, config or credential is discovered.
public actor GlacierPronunciationClient {
    public typealias ProcessFactory = @Sendable (String) throws -> any CLIProcessHandle
    public typealias RequestPayload = @Sendable (String) async throws -> Data
    private let processFactory: ProcessFactory
    private let requestPayload: RequestPayload
    private var active: (revision: UInt64, process: any CLIProcessHandle)?
    private var teardown: Task<Bool, Never>?
    private var revision: UInt64 = 0

    public init(processFactory: @escaping ProcessFactory) {
        self.processFactory = processFactory
        requestPayload = { Data($0.utf8) }
    }

    public init(paths: GlacierPronunciationPaths, settings: PronunciationSettingsStore,
                offline: @escaping @Sendable () -> Bool) {
        processFactory = { _ in try Self.bundledProcess(paths: paths) }
        requestPayload = { term in try await settings.requestPayload(term: term, offline: offline()) }
    }

    /// A fixture can exercise the secure stdin protocol without launching a
    /// helper. The process factory remains injected for cancellation tests.
    public init(processFactory: @escaping ProcessFactory, requestPayload: @escaping RequestPayload) {
        self.processFactory = processFactory
        self.requestPayload = requestPayload
    }

    public nonisolated var producer: OmniEphemeralProducer {
        { input, onDelta in try await self.pronounce(input, onDelta: onDelta) }
    }

    public static func bundledProcess(paths: GlacierPronunciationPaths) throws -> any CLIProcessHandle {
        let executable = try paths.prepare()
        let environment = try CLIChildEnvironment.build(
            parent: [:], home: paths.supportDirectory.path,
            executableDirectory: executable.deletingLastPathComponent().path,
            additions: ["PYTHONUNBUFFERED": "1",
                        "PRON_HOME": paths.cacheDirectory.path]
        )
        return try CLIOwnedProcess(
            executable: executable,
            arguments: ["-B", "-I", "-m", "pron.cli", "--json-events", "--stdin-json"],
            environment: environment, workingDirectory: paths.supportDirectory
        )
    }

    private func pronounce(
        _ input: String, onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw EphemeralToolFailure("Enter a word or short phrase.") }
        guard term.utf8.count <= 4_096 else { throw EphemeralToolFailure("Pronunciation input is too long.") }
        revision &+= 1
        let current = revision
        let previous = active
        active = nil
        if let previous {
            let priorTeardown = teardown
            teardown = Task {
                if let priorTeardown, !(await priorTeardown.value) { return false }
                await previous.process.terminate(graceful: .seconds(2), interruptFirst: false)
                // A concurrent cancellation may already own terminate's work;
                // its idempotent return is not proof that the child exited.
                return await previous.process.waitForExit(.seconds(2))
            }
        }
        if let teardown, !(await teardown.value) {
            throw EphemeralToolFailure("Previous pronunciation is still stopping. Try again.")
        }
        try Task.checkCancellation()
        guard revision == current else { throw CancellationError() }
        teardown = nil
        let payload: Data
        do { payload = try await requestPayload(term) }
        catch is CancellationError { throw CancellationError() }
        catch { throw EphemeralToolFailure("Pronunciation settings or credentials need attention.") }
        try Task.checkCancellation()
        let process: any CLIProcessHandle
        do { process = try processFactory(term) }
        catch let failure as EphemeralToolFailure { throw failure }
        catch { throw EphemeralToolFailure("The bundled pronunciation helper could not be started.") }
        active = (current, process)
        do {
            try process.start()
            try process.write(payload)
            process.closeStdin()
            let result = try await withTaskCancellationHandler {
                try await Self.readResult(process, onDelta: onDelta)
            } onCancel: {
                // --json-events handles TERM, reaps active afplay/say and removes
                // temporary Forvo files before exiting. Esc never leaves audio behind.
                Task { await process.terminate(graceful: .seconds(2), interruptFirst: false) }
            }
            await process.terminate(graceful: .seconds(2), interruptFirst: false)
            if active?.revision == current { active = nil }
            try Task.checkCancellation()
            return result
        } catch {
            await process.terminate(graceful: .seconds(2), interruptFirst: false)
            let stopped = await process.waitForExit(.seconds(2))
            if stopped, active?.revision == current { active = nil }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let failure = error as? EphemeralToolFailure { throw failure }
            throw EphemeralToolFailure("Pronunciation could not finish. Press Enter to try again.")
        }
    }

    private static func readResult(
        _ process: any CLIProcessHandle,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        var final: (result: PronunciationResult, json: String)?
        var receivedText = false
        var byteCount = 0
        while let line = try await process.nextLine(until: deadline) {
            try Task.checkCancellation()
            byteCount += line.count
            guard byteCount <= 1_000_000 else {
                throw EphemeralToolFailure("Pronunciation output is too large.")
            }
            let event = try JSONDecoder().decode(PronunciationEvent.self, from: line)
            guard event.version == 1 else {
                throw EphemeralToolFailure("The bundled pronunciation helper has an incompatible event version.")
            }
            switch event.event {
            case "transcriptions":
                guard !receivedText, event.transcriptions != nil else {
                    throw EphemeralToolFailure("The pronunciation CLI returned an invalid response.")
                }
                receivedText = true
                guard let json = String(data: line, encoding: .utf8) else {
                    throw EphemeralToolFailure("The pronunciation CLI returned an invalid response.")
                }
                await onDelta(json + "\n")
            case "audio":
                guard event.audio != nil, let json = String(data: line, encoding: .utf8) else {
                    throw EphemeralToolFailure("The pronunciation CLI returned an invalid response.")
                }
                await onDelta(json + "\n")
            case "complete":
                guard let result = event.result, (0...2).contains(result.exitCode) else {
                    throw EphemeralToolFailure("The pronunciation CLI returned an invalid result.")
                }
                guard let envelope = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let object = envelope["result"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                      let json = String(data: data, encoding: .utf8) else {
                    throw EphemeralToolFailure("The pronunciation CLI returned an invalid result.")
                }
                final = (result, json)
            case "error":
                throw EphemeralToolFailure(event.message ?? "Pronunciation configuration needs attention.")
            default:
                throw EphemeralToolFailure("The pronunciation CLI returned an unknown response.")
            }
        }
        guard await process.waitForExit(.seconds(2)), let final,
              process.terminationStatus == Int32(final.result.exitCode) else {
            throw EphemeralToolFailure("Pronunciation stopped before returning a result. Press Enter to retry.")
        }
        return final.json
    }
}

private struct PronunciationEvent: Decodable {
    let version: Int
    let event: String
    let transcriptions: [PronunciationTranscription]?
    let audio: PronunciationAudio?
    let result: PronunciationResult?
    let message: String?
}

private struct PronunciationTranscription: Decodable {
    let accent: String
    let ipa: String
    let source: String
    let pos: String?
    let note: String?
    let rawTags: [String]?
    enum CodingKeys: String, CodingKey {
        case accent, ipa, source, pos, note
        case rawTags = "raw_tags"
    }
}

private struct PronunciationAudio: Decodable {
    let source: String
    let accent: String
    let attribution: String?
}

private struct PronunciationResult: Decodable {
    struct Failure: Decodable { let source: String; let message: String }
    let transcriptions: [PronunciationTranscription]
    let audio: [PronunciationAudio]
    let errors: [Failure]
    let exitCode: Int
    enum CodingKeys: String, CodingKey {
        case transcriptions, audio, errors
        case exitCode = "exit_code"
    }

}
