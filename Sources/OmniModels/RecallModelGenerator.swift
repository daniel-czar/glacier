import Foundation
import CoreFoundation
import OmniCore

public enum RecallModelError: Error, Sendable, Equatable {
    case invalidReply
}

public struct RecallEnvironment: Sendable, Equatable {
    public let macOSVersion: String
    public let shell: String
    public let availableTools: [String]

    public init(macOSVersion: String, shell: String = "zsh", availableTools: [String]) {
        self.macOSVersion = macOSVersion
        self.shell = shell
        self.availableTools = availableTools
    }

    public static func current() -> RecallEnvironment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let names = ["fd", "rg", "jq", "uv", "just", "brew", "ollama", "git", "python3", "ls", "find", "grep", "sed", "awk", "xargs", "ps", "pgrep", "pkill", "lsof"]
        // A Finder-launched app may supply a smaller PATH than a terminal.
        // Probe only real executable locations and describe the result as a
        // detected inventory, not a guarantee about shell configuration.
        let paths = Array(Set((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]))
        let available = names.filter { name in
            paths.contains { path in FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: path).appendingPathComponent(name).path) }
        }
        return RecallEnvironment(macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", availableTools: available)
    }
}

/// The generator receives the current sheet and a measured local environment.
/// Its output is text to copy, never a request to execute a command.
public enum RecallModelGenerator {
    public static let commandID = "recall.command"
    public static let maximumReplyCharacters = 6_000

    public static func request(intent: String, sheet: [RecallCommand], environment: RecallEnvironment = .current(), runID: String = UUID().uuidString.lowercased(),
                               profileID: String = ProviderRuntimeCatalog.cerebrasFastProfileID) -> ModelGenerationRequest {
        let entries = sheet.map { row in
            let aliases = row.intentAliases.isEmpty ? "" : " | aliases: " + row.intentAliases.joined(separator: "; ")
            return "- [\(row.category)] \(row.command) | \(row.label) | \(row.note)\(aliases)"
        }.joined(separator: "\n")
        let prompt = """
        Suggest one to three terminal commands for a user on macOS. They will copy a command into their terminal app; you never execute one.

        Environment: macOS \(environment.macOSVersion), \(environment.shell) shell. System utilities are BSD variants, not GNU: macOS find has no -printf. Installed tools from the current PATH: \(environment.availableTools.isEmpty ? "none detected" : environment.availableTools.joined(separator: ", ")). Use only installed optional tools. Use <name>, <pid>, <query> for values the user must supply. Fill in values given by the intent. Prefer the macOS-native form; mention an fd/rg/GNU alternative in the note only when materially shorter and available.

        Existing sheet commands (do not re-propose an identical command):
        \(entries.isEmpty ? "(empty)" : entries)

        Return exactly one JSON object with a candidates array of 1 to 3 objects. Every candidate must have exactly these keys: command, label, note, category, destructive. The first four are nonempty strings except note may be empty; destructive is a Boolean. Category should be short and useful. Set destructive true for deletion, irreversible Git operations, force push, force kill, or similarly risky commands. Never invent flags. No Markdown, prose, or code fences.

        Intent: \(intent)
        """
        return ModelGenerationRequest(
            runID: runID,
            commandID: commandID,
            prompt: prompt,
            offline: false,
            outputConstraint: .init(shape: .jsonObject, maximumCharacters: maximumReplyCharacters),
            dispatch: .init(
                generationID: UUID().uuidString.lowercased(),
                selection: ModelInvocationSelection(profileID: profileID)
            )
        )
    }

    public static func generate(intent: String, sheet: [RecallCommand], broker: any ModelGenerating, runID: String = UUID().uuidString.lowercased(), environment: RecallEnvironment = .current(),
                                profileID: String = ProviderRuntimeCatalog.cerebrasFastProfileID) async throws -> [RecallCommand] {
        let result = try await broker.execute(request(intent: intent, sheet: sheet, environment: environment, runID: runID, profileID: profileID))
        try Task.checkCancellation()
        guard let commands = parse(result.response.text, excluding: sheet) else { throw RecallModelError.invalidReply }
        return commands
    }

    public static func parse(_ text: String, excluding sheet: [RecallCommand] = []) -> [RecallCommand]? {
        guard text.count <= maximumReplyCharacters,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys) == ["candidates"],
              let raw = object["candidates"] as? [[String: Any]],
              (1...3).contains(raw.count)
        else { return nil }
        let existing = Set(sheet.map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) })
        var seen = existing
        var commands: [RecallCommand] = []
        for row in raw {
            guard Set(row.keys) == ["command", "label", "note", "category", "destructive"],
                  let line = row["command"] as? String,
                  let label = row["label"] as? String,
                  let note = row["note"] as? String,
                  let category = row["category"] as? String,
                  let flagNumber = row["destructive"] as? NSNumber,
                  CFGetTypeID(flagNumber) == CFBooleanGetTypeID()
            else { return nil }
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty, !trimmedLabel.isEmpty, !trimmedCategory.isEmpty,
                  !trimmedLine.contains("\n"), !trimmedLine.contains("\r")
            else { return nil }
            guard seen.insert(trimmedLine).inserted else { continue }
            commands.append(RecallCommand(category: trimmedCategory, command: trimmedLine, label: trimmedLabel, note: note.trimmingCharacters(in: .whitespacesAndNewlines), destructive: flagNumber.boolValue))
        }
        return commands.isEmpty ? nil : commands
    }
}
