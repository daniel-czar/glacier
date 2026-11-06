import Foundation

public struct ExpressOption: Codable, Sendable, Equatable {
    public enum Group: String, Codable, Sendable {
        case close
        case broader
    }

    public let group: Group
    public let phrase: String
    public let cue: String

    public init(group: Group, phrase: String, cue: String) {
        self.group = group
        self.phrase = phrase
        self.cue = cue
    }
}

public struct ExpressResult: Codable, Sendable, Equatable {
    public let options: [ExpressOption]

    public init(options: [ExpressOption]) { self.options = options }
}

/// Version 1 newline-delimited events from the independent Express CLI.
public struct ExpressEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case option
        case complete
        case error
    }

    public let version: Int
    public let event: Kind
    public let option: ExpressOption?
    public let result: ExpressResult?
    public let message: String?
    public let exitCode: Int?

    public init(version: Int = 1, event: Kind, option: ExpressOption? = nil,
                result: ExpressResult? = nil, message: String? = nil, exitCode: Int? = nil) {
        self.version = version
        self.event = event
        self.option = option
        self.result = result
        self.message = message
        self.exitCode = exitCode
    }

    enum CodingKeys: String, CodingKey {
        case version, event, option, result, message
        case exitCode = "exit_code"
    }
}

/// Parses displayable stream events separately from the authoritative final
/// result. Partial or malformed transport text never becomes clipboard text.
public enum OmniExpressProjection {
    public static func decodeStreaming(_ output: String) -> [ExpressOption] {
        var options: [ExpressOption] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = try? JSONDecoder().decode(ExpressEvent.self, from: Data(line.utf8)),
                  event.version == 1 else { break }
            guard event.event == .option, let option = event.option,
                  validPrefix(options + [option]) else { break }
            options.append(option)
        }
        return options
    }

    public static func decodeFinal(_ output: String) -> ExpressResult? {
        guard let result = try? JSONDecoder().decode(ExpressResult.self, from: Data(output.utf8)),
              (2...6).contains(result.options.count),
              result.options.contains(where: { $0.group == .close }),
              result.options.contains(where: { $0.group == .broader }),
              validPrefix(result.options) else { return nil }
        return result
    }

    public static func validOption(_ option: ExpressOption) -> Bool {
        let phrase = option.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let cue = option.cue.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "\r\n\0")
        guard !phrase.isEmpty, phrase == option.phrase, option.phrase.count <= 500,
              option.cue.count <= 100, option.cue == cue,
              option.phrase.rangeOfCharacter(from: forbidden) == nil,
              option.cue.rangeOfCharacter(from: forbidden) == nil else { return false }
        return option.group == .close || !cue.isEmpty
    }

    /// Validates a stream prefix as well as the complete result's option list.
    /// A final result additionally requires at least one option in each group.
    public static func validPrefix(_ options: [ExpressOption]) -> Bool {
        guard options.count <= 6, options.allSatisfy(validOption),
              options.filter({ $0.group == .close }).count <= 3,
              options.filter({ $0.group == .broader }).count <= 3 else { return false }
        var sawBroader = false
        var seen: Set<String> = []
        for option in options {
            if option.group == .broader { sawBroader = true }
            if sawBroader && option.group == .close { return false }
            let key = option.phrase.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else { return false }
        }
        return true
    }

    public static func formatAll(_ result: ExpressResult) -> String {
        let groups: [(ExpressOption.Group, String)] = [(.close, "Close alternatives"), (.broader, "Broader options")]
        return groups.compactMap { group, heading in
            let lines = result.options.filter { $0.group == group }.map { option in
                "• \(option.phrase)" + (option.cue.isEmpty ? "" : " — \(option.cue)")
            }
            return lines.isEmpty ? nil : ([heading] + lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

}
