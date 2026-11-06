import Foundation
import OmniPresentation
import Testing

private func pronunciationJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try #require(String(data: data, encoding: .utf8))
}

@Test func pronunciationProjectionPreservesHomographRowsAndTags() throws {
    let result = try pronunciationJSON([
        "transcriptions": [
            ["accent": "GA", "ipa": "/ɹiːd/", "source": "wiktionary", "pos": "present",
             "raw_tags": ["US"], "note": "verb"],
            ["accent": "GA", "ipa": "ɹɛd", "source": "wiktionary", "pos": "past",
             "raw_tags": [], "note": "verb"],
            ["accent": "UK", "ipa": "[ɹɛd]", "source": "cmudict", "raw_tags": []]
        ],
        "audio": [], "errors": [], "played": NSNull(), "exit_code": 0
    ])
    let view = try #require(OmniPronunciationPresentation.decode(result))
    #expect(view.transcriptions.map(\.ipa) == ["/ɹiːd/", "/ɹɛd/", "/ɹɛd/"])
    #expect(view.transcriptions.map(\.accent) == ["GA", "GA", "UK"])
    #expect(view.transcriptions.map(\.source) == ["Wiktionary", "Wiktionary", "CMUdict"])
    #expect(view.transcriptions.map(\.tag) == ["present · verb", "past · verb", nil])
    #expect(view.sources.map(\.name) == ["Wiktionary", "CMUdict"])
    #expect(view.attribution == nil)
    #expect(!view.isPlaying)
    #expect(view.exitCode == 0)
}

@Test func pronunciationProjectionUsesLastAttemptUntilCompletionAndPlayedAfter() throws {
    let transcription: [String: Any] = ["accent": "GA", "ipa": "wɝd", "source": "wiktionary"]
    let forvo: [String: Any] = ["source": "forvo", "accent": "US", "attribution": "Forvo · Alice", "online": true]
    let wiki: [String: Any] = ["source": "wiktionary", "accent": "UK", "attribution": "Wikimedia Commons · sample",
                               "path": "/cache/word.mp3", "source_url": "https://commons.wikimedia.org/wiki/File:word"]
    let lines = try [
        pronunciationJSON(["version": 1, "event": "transcriptions", "transcriptions": [transcription]]),
        pronunciationJSON(["version": 1, "event": "audio", "audio": forvo, "synthetic": false]),
        pronunciationJSON(["version": 1, "event": "audio", "audio": wiki, "synthetic": false])
    ]
    let firstAttempt = try #require(OmniPronunciationPresentation.decode(lines.prefix(2).joined(separator: "\n") + "\n"))
    #expect(firstAttempt.isPlaying)
    #expect(firstAttempt.attribution?.text == "Alice · US")
    #expect(firstAttempt.attribution?.sourceLabel == "Pronunciations by Forvo")
    #expect(firstAttempt.attribution?.sourceURL?.absoluteString == "https://forvo.com")

    let secondAttempt = try #require(OmniPronunciationPresentation.decode(lines.joined(separator: "\n")))
    #expect(secondAttempt.isPlaying)
    #expect(secondAttempt.attribution?.text == "Wikimedia Commons · sample · UK")

    let complete = try pronunciationJSON([
        "transcriptions": [transcription], "audio": [forvo, wiki],
        "errors": [["source": "forvo", "message": "quota reached"]],
        "played": "/cache/word.mp3", "exit_code": 2
    ])
    let resting = try #require(OmniPronunciationPresentation.decode(complete))
    #expect(!resting.isPlaying)
    #expect(resting.exitCode == 2)
    #expect(resting.attribution?.text == "Wikimedia Commons · sample · UK")
    #expect(resting.attribution?.sourceURL?.scheme == "https")
    #expect(resting.sources.map(\.name) == ["Wiktionary", "Forvo"])
    #expect(resting.sources.last?.failureReason == "quota reached")
}

@Test func pronunciationProjectionMissAndSyntheticFallback() throws {
    let say: [String: Any] = ["source": "say", "accent": "synthetic", "attribution": "Samantha", "synthetic": true]
    let final = try pronunciationJSON([
        "transcriptions": [], "audio": [say], "errors": [],
        "played": "say:Samantha", "exit_code": 1
    ])
    let view = try #require(OmniPronunciationPresentation.decode(final))
    #expect(view.transcriptions.isEmpty)
    #expect(view.sourcesTried == ["Wiktionary", "CMUdict"])
    #expect(view.sources.map(\.name) == ["say"])
    #expect(view.attribution?.symbolName == "waveform")
    #expect(view.attribution?.text == "Samantha · synthetic")
    #expect(view.attribution?.sourceURL == nil)
    #expect(view.exitCode == 1)

    let event = try pronunciationJSON([
        "version": 1, "event": "audio", "synthetic": true, "voice": "Samantha",
        "audio": ["source": "say", "accent": "synthetic"]
    ])
    let playing = try #require(OmniPronunciationPresentation.decode(event))
    #expect(playing.isPlaying)
    #expect(playing.attribution?.text == "Samantha · synthetic")
}

@Test func pronunciationProjectionDoesNotInventPlaybackOrExposeUnsafeURLs() throws {
    let audio: [String: Any] = ["source": "mw", "accent": "US", "attribution": "Dictionary voice",
                                "path": "/cache/audio.mp3", "source_url": "file:///private/source"]
    let final = try pronunciationJSON([
        "transcriptions": [], "audio": [audio], "errors": [],
        "played": NSNull(), "exit_code": 1, "unexpected": "must not display"
    ])
    let noPlayback = try #require(OmniPronunciationPresentation.decode(final))
    #expect(noPlayback.attribution == nil)
    #expect(!noPlayback.isPlaying)
    #expect(noPlayback.sources.map(\.name) == ["Merriam-Webster"])

    let withPlayback = try pronunciationJSON([
        "transcriptions": [], "audio": [audio], "errors": [],
        "played": "/cache/audio.mp3", "exit_code": 1
    ])
    let attributed = try #require(OmniPronunciationPresentation.decode(withPlayback))
    #expect(attributed.attribution?.sourceURL == nil)
    #expect(attributed.attribution?.sourceLabel == "Merriam-Webster")
    #expect(OmniPronunciationPresentation.decode("{\"version\":2,\"event\":\"audio\",\"audio\":{}}") == nil)
    let badExit = try pronunciationJSON([
        "transcriptions": [], "audio": [], "errors": [], "played": NSNull(), "exit_code": 3
    ])
    #expect(OmniPronunciationPresentation.decode(badExit) == nil)
}
