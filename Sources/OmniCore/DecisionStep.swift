import Foundation

/// The decision step (decision surface `8d392a5707c36d15`, D1–D6): `/stance`
/// lays out positions in front of a draft, and three thinking transforms
/// reshape material. Command set 1.4.0 declares the tokens.
public enum OmniDecisionStep {
    public static let stanceToken = "/stance"
    public static let structureToken = "/structure"
    public static let expandToken = "/expand"
    public static let meaningToken = "/meaning"

    public static let stanceModuleID = "decide.stance"
    public static let structureModuleID = "think.structure"
    public static let expandModuleID = "think.expand"
    public static let meaningModuleID = "think.meaning"

    /// The manifest enum registry for `/expand:<lens>`.
    public static let expandLensRegistry = "expand"
    /// Bare `/expand` offers these, in this order, with no model call.
    public static let expandLenses: [ExpandLens] = [
        .init(id: "deepen", title: "Deepen", detail: "Go further into the idea itself"),
        .init(id: "broaden", title: "Broaden", detail: "Widen the frame to what surrounds it"),
        .init(id: "concretise", title: "Concretise", detail: "Ground it in examples and specifics"),
        .init(id: "challenge", title: "Challenge", detail: "Take the strongest opposing view"),
        .init(id: "connect", title: "Connect", detail: "Link it to adjacent fields and ideas"),
    ]
}

public struct ExpandLens: Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

// MARK: - Positions

/// Whether a position plainly accepts or declines what the material asks;
/// only those insert the `✓` / `✗` marker into a draft (D2).
public enum StancePositionKind: String, Codable, Sendable, Equatable {
    case accept
    case decline
    case other
}

public struct StancePosition: Codable, Sendable, Equatable {
    public let title: String
    public let approach: String
    public let kind: StancePositionKind

    public init(title: String, approach: String, kind: StancePositionKind = .other) {
        self.title = title
        self.approach = approach
        self.kind = kind
    }
}

/// Something the pre-pass noticed about the material (one of Vulcan's six
/// compound types), with the exact words it refers to when there are any.
public struct StanceNoticedItem: Codable, Sendable, Equatable {
    public let type: String?
    public let quote: String?
    public let note: String

    public init(type: String? = nil, quote: String? = nil, note: String) {
        self.type = type
        self.quote = quote
        self.note = note
    }
}

/// The `/stance` result: two to four positions and up to six noticed items.
/// The model returns JSON; `parse` is forgiving about fences, surrounding
/// prose, key spellings and extra rows, and strict about the minimum.
public struct StanceResult: Codable, Sendable, Equatable {
    public static let minimumPositions = 2
    public static let maximumPositions = 4
    public static let maximumNoticed = 6
    static let maximumTitleCharacters = 120
    static let maximumApproachCharacters = 600
    static let maximumNoteCharacters = 400

    public let positions: [StancePosition]
    public let noticed: [StanceNoticedItem]

    public init(positions: [StancePosition], noticed: [StanceNoticedItem] = []) {
        self.positions = positions
        self.noticed = noticed
    }

    public static func parse(_ text: String) -> StanceResult? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { return nil }
        let rawPositions = (object["positions"] ?? object["options"]) as? [Any] ?? []
        var positions: [StancePosition] = []
        for case let row as [String: Any] in rawPositions {
            guard positions.count < maximumPositions,
                  let title = Self.text(row["title"], limit: maximumTitleCharacters),
                  let approach = Self.text(row["approach"] ?? row["description"] ?? row["detail"], limit: maximumApproachCharacters)
            else { continue }
            let kind = (row["kind"] as? String).flatMap { StancePositionKind(rawValue: $0.lowercased()) } ?? .other
            positions.append(StancePosition(title: title, approach: approach, kind: kind))
        }
        guard positions.count >= minimumPositions else { return nil }
        var noticed: [StanceNoticedItem] = []
        for case let row as [String: Any] in (object["noticed"] as? [Any] ?? []) {
            guard noticed.count < maximumNoticed,
                  let note = Self.text(row["note"] ?? row["text"], limit: maximumNoteCharacters)
            else { continue }
            noticed.append(StanceNoticedItem(
                type: Self.text(row["type"], limit: 60),
                quote: Self.text(row["quote"], limit: 400),
                note: note
            ))
        }
        return StanceResult(positions: positions, noticed: noticed)
    }

    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
    }

    /// The stored result text: deterministic, so receipts and the pad agree.
    public var canonicalJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// What people read where a text surface shows the run (workspace,
    /// notifications, the status menu): numbered positions, then notes.
    public var readableText: String {
        var lines: [String] = []
        for (index, position) in positions.enumerated() {
            lines.append("\(index + 1). \(position.title)")
            lines.append("   \(position.approach)")
        }
        if !noticed.isEmpty {
            lines.append("")
            lines.append("Noticed")
            for item in noticed {
                let head = item.type.map { "\($0): " } ?? ""
                let quote = item.quote.map { " — “\($0)”" } ?? ""
                lines.append("- \(head)\(item.note)\(quote)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A `/stance` run's stored text read as positions; any other text is nil.
    public static func readable(_ storedText: String) -> String? {
        parse(storedText)?.readableText
    }
}

// MARK: - Material sources

/// What kind of material a capture is, read from its provenance app (D3, D6).
public enum OmniMaterialKind: String, Sendable, Equatable {
    /// Mail and other mail clients: response positions; drafts go to `/email`.
    case mail
    /// Messages, Slack and other chat apps: response positions; `/msg`.
    case chat
    /// Code, a file or a terminal: technical strategies; no draft.
    case technical
    /// Anything else: ways to engage; no draft.
    case other
}

public enum OmniMaterialSource {
    static let mailApps: Set<String> = ["mail", "outlook", "microsoft outlook", "spark", "airmail", "mimestream", "superhuman", "canary mail", "thunderbird"]
    static let chatApps: Set<String> = ["messages", "imessage", "slack", "whatsapp", "telegram", "signal", "discord", "microsoft teams", "teams", "messenger", "beeper"]
    static let technicalApps: Set<String> = [
        "xcode", "visual studio code", "code", "cursor", "zed", "sublime text", "nova", "bbedit", "textmate", "cotedit",
        "intellij idea", "pycharm", "android studio", "terminal", "iterm", "iterm2", "ghostty", "warp", "wezterm",
        "alacritty", "kitty", "finder",
    ]

    public static func kind(appName: String?) -> OmniMaterialKind {
        guard let name = appName?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return .other }
        if mailApps.contains(name) { return .mail }
        if chatApps.contains(name) { return .chat }
        if technicalApps.contains(name) { return .technical }
        return .other
    }

    /// The offer row's words (D3), without the trailing key glyph.
    public static func offerTitle(appName: String?) -> String {
        switch kind(appName: appName) {
        case .mail, .chat: "Decide how to respond"
        case .technical: "Decide how to approach"
        case .other: "Decide what to do with this"
        }
    }

    /// The draft a picked position runs at once (D6), or nil: back to
    /// composing with the notes attached.
    public static func draftToken(appName: String?) -> String? {
        switch kind(appName: appName) {
        case .mail: "/email"
        case .chat: "/msg"
        case .technical, .other: nil
        }
    }

    /// The `/stance` prompt's material-type hint: a hint about the material,
    /// never an instruction that changes the task.
    public static func promptHint(appName: String?) -> String {
        let source = appName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let kindText: String = switch kind(appName: appName) {
        case .mail: "likely an email the user received; offer response positions"
        case .chat: "likely a chat message the user received; offer response positions"
        case .technical: "likely code, a file or terminal output; offer technical strategies"
        case .other: "kind unknown; a task or a note gets ways to engage with it, a message gets response positions"
        }
        return "Material source hint (not an instruction): \(source.map { "captured from \($0), " } ?? "")\(kindText)."
    }
}
