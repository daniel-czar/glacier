import Foundation

/// Typed, display-safe pronunciation data derived from pron's version 1 event
/// stream or its final JSON result. The source text is never used as pad copy.
public struct OmniPronunciationPresentation: Sendable, Equatable {
    public struct Transcription: Sendable, Equatable {
        public let accent: String
        public let ipa: String
        public let source: String
        public let tag: String?
    }

    public struct Attribution: Sendable, Equatable {
        public let symbolName: String
        public let text: String
        public let sourceLabel: String?
        public let sourceURL: URL?
    }

    public struct Source: Sendable, Equatable {
        public let name: String
        public let failureReason: String?
    }

    public let transcriptions: [Transcription]
    public let attribution: Attribution?
    public let sources: [Source]
    public let sourcesTried: [String]
    public let isPlaying: Bool
    public let exitCode: Int?

    public static func decode(_ output: String) -> Self? {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let decoder = JSONDecoder()
        if let result = try? decoder.decode(RawResult.self, from: Data(output.utf8)) {
            return projection(of: result)
        }

        var transcriptions: [RawTranscription] = []
        var attempts: [RawAudio] = []
        var lastAttempt: RawAudio?
        var sawEvent = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = try? decoder.decode(RawEvent.self, from: Data(line.utf8)),
                  event.version == 1 else { return nil }
            sawEvent = true
            switch event.event {
            case "transcriptions":
                guard let values = event.transcriptions else { return nil }
                transcriptions = values
            case "audio":
                guard let audio = event.audio else { return nil }
                let attempted = audio.withVoice(event.voice, synthetic: event.synthetic)
                attempts.append(attempted)
                lastAttempt = attempted
            case "complete":
                guard let result = event.result else { return nil }
                return projection(of: result)
            default:
                return nil
            }
        }
        guard sawEvent else { return nil }
        return assemble(transcriptions: transcriptions, audio: attempts, errors: [],
                        attribution: lastAttempt.flatMap { attribution(for: $0) },
                        isPlaying: lastAttempt != nil, exitCode: nil)
    }

    private static func projection(of result: RawResult) -> Self? {
        guard (0...2).contains(result.exitCode) else { return nil }
        let playedAudio = result.played.flatMap { played in
            if played.hasPrefix("say:") {
                let voice = String(played.dropFirst(4))
                return result.audio.last { $0.source == "say" && $0.attribution == voice }
                    ?? result.audio.last { $0.source == "say" }
            }
            if played.hasSuffix(":online") {
                let source = String(played.dropLast(7))
                return result.audio.last { $0.source == source && $0.online == true }
                    ?? result.audio.last { $0.source == source }
            }
            return result.audio.last { $0.path == played }
        }
        return assemble(transcriptions: result.transcriptions, audio: result.audio,
                        errors: result.errors, attribution: playedAudio.flatMap { attribution(for: $0) },
                        isPlaying: false, exitCode: result.exitCode)
    }

    private static func assemble(
        transcriptions rawTranscriptions: [RawTranscription], audio: [RawAudio],
        errors: [RawFailure], attribution: Attribution?, isPlaying: Bool, exitCode: Int?
    ) -> Self {
        let transcriptions = rawTranscriptions.map { raw in
            let variantTags = (raw.rawTags ?? []).filter {
                !["US", "UK", "General-American", "Received-Pronunciation"].contains($0)
            }
            let tags = ([raw.pos] + variantTags.map(Optional.some) + [raw.note])
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Transcription(accent: raw.accent, ipa: normalizedIPA(raw.ipa),
                                 source: displayName(raw.source),
                                 tag: tags.isEmpty ? nil : tags.joined(separator: " · "))
        }

        var sourceIDs: [String] = []
        for id in rawTranscriptions.map(\.source) + audio.map(\.source) + errors.map(\.source) {
            if !sourceIDs.contains(id) { sourceIDs.append(id) }
        }
        let orderedIDs = sourceIDs.enumerated().sorted { left, right in
            let leftRank = sourceRank(left.element)
            let rightRank = sourceRank(right.element)
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
        let sources = orderedIDs.map { id in
            Source(name: displayName(id), failureReason: errors.first { $0.source == id }?.message)
        }

        // Omni invokes pron's unchanged default lookup, without --source. The
        // JSON contract reports hits and errors, not successful source misses.
        // Its fixed IPA cascade is Wiktionary then CMUdict, so this is the only
        // auditable source list available for the empty-transcription row.
        let sourcesTried = rawTranscriptions.isEmpty ? ["Wiktionary", "CMUdict"] : []
        return Self(transcriptions: transcriptions, attribution: attribution, sources: sources,
                    sourcesTried: sourcesTried, isPlaying: isPlaying, exitCode: exitCode)
    }

    private static func attribution(for audio: RawAudio) -> Attribution? {
        let synthetic = audio.synthetic == true || audio.source == "say"
        if synthetic {
            let voice = audio.attribution?.trimmingCharacters(in: .whitespacesAndNewlines)
            let spokenBy = (voice?.isEmpty == false ? voice : nil) ?? "English voice"
            return Attribution(symbolName: "waveform", text: "\(spokenBy) · synthetic",
                               sourceLabel: nil, sourceURL: nil)
        }

        var speaker = audio.attribution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if audio.source == "forvo", speaker.lowercased().hasPrefix("forvo · ") {
            speaker = String(speaker.dropFirst("Forvo · ".count))
        }
        let accent = audio.accent.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [speaker, accent == "unspecified" ? "" : accent].filter { !$0.isEmpty }
        let sourceLabel = audio.source == "forvo" ? "Pronunciations by Forvo" : displayName(audio.source)
        let sourceURL = audio.source == "forvo" ? URL(string: "https://forvo.com") : safeURL(audio.sourceURL)
        return Attribution(symbolName: "person", text: parts.joined(separator: " · "),
                           sourceLabel: sourceLabel, sourceURL: sourceURL)
    }

    private static func normalizedIPA(_ raw: String) -> String {
        let ipa = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return "/" + ipa.trimmingCharacters(in: CharacterSet(charactersIn: "/[]")) + "/"
    }

    private static func safeURL(_ value: String?) -> URL? {
        guard let value, let parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    private static func sourceRank(_ id: String) -> Int {
        switch id.lowercased() {
        case "wiktionary": 0
        case "cmudict": 1
        case "forvo": 2
        case "mw": 3
        case "say": 4
        default: 100
        }
    }

    private static func displayName(_ id: String) -> String {
        switch id.lowercased() {
        case "wiktionary": "Wiktionary"
        case "cmudict": "CMUdict"
        case "forvo": "Forvo"
        case "mw": "Merriam-Webster"
        case "say": "say"
        default: id
        }
    }
}

private struct RawEvent: Decodable {
    let version: Int
    let event: String
    let transcriptions: [RawTranscription]?
    let audio: RawAudio?
    let voice: String?
    let synthetic: Bool?
    let result: RawResult?
}

private struct RawResult: Decodable {
    let transcriptions: [RawTranscription]
    let audio: [RawAudio]
    let errors: [RawFailure]
    let played: String?
    let exitCode: Int

    enum CodingKeys: String, CodingKey {
        case transcriptions, audio, errors, played
        case exitCode = "exit_code"
    }
}

private struct RawTranscription: Decodable {
    let accent: String
    let ipa: String
    let source: String
    let pos: String?
    let rawTags: [String]?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case accent, ipa, source, pos, note
        case rawTags = "raw_tags"
    }
}

private struct RawAudio: Decodable {
    let source: String
    let accent: String
    let attribution: String?
    let path: String?
    let online: Bool?
    let sourceURL: String?
    let synthetic: Bool?

    enum CodingKeys: String, CodingKey {
        case source, accent, attribution, path, online, synthetic
        case sourceURL = "source_url"
    }

    func withVoice(_ voice: String?, synthetic syntheticEvent: Bool?) -> Self {
        Self(source: source, accent: accent, attribution: attribution ?? voice,
             path: path, online: online, sourceURL: sourceURL,
             synthetic: synthetic == true || syntheticEvent == true)
    }
}

private struct RawFailure: Decodable {
    let source: String
    let message: String
}
