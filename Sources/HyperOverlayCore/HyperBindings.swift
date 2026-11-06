import Foundation

/// The tint of a bound key (C102): teal opens a surface you type into, blue
/// runs a command. Derived from what the binding opens, never tagged in data.
public enum HyperBindingKind: String, Sendable, Equatable {
    case surface
    case command

    /// The overlays that open a surface. Everything else a native chord does,
    /// and every Keyboard Maestro macro, runs a command.
    public static let surfaceOverlays: Set<String> = [
        OverlayID.space,
        OverlayID.clipboard,
        OverlayID.stash,
        OverlayID.translate,
        OverlayID.pronounce,
        OverlayID.semanticTools,
        OverlayID.quickQuestion,
        OverlayID.reference,
        OverlayID.express,
        OverlayID.help,
    ]

    public static func of(overlayID: String) -> HyperBindingKind {
        overlayID == "launch.open" || surfaceOverlays.contains(overlayID) ? .surface : .command
    }
}

/// Who answers the chord. The host only hears its own chords; Keyboard
/// Maestro's are drawn from data until they move into the host.
public enum HyperBindingOwner: String, Codable, Sendable, Equatable {
    case native
    case keyboardMaestro = "keyboard-maestro"
}

/// `hyper-bindings.json`, beside the hotkey manifest and never inside it: the
/// manifest is parity-coupled to the binary, this file is read-only display
/// data that an older binary ignores.
public struct HyperBindingsFile: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let owner: HyperBindingOwner
        /// The native overlay id; required for `native`, absent otherwise.
        public let overlay: String?
        /// The cap id in the layout table. Required for Keyboard Maestro; for a
        /// native binding it overrides the key code (Hyper+? arrives as F18).
        public let key: String?
        /// At most two lines on the cap (C101).
        public let label: String
        /// The long description, shown on hover when pinned.
        public let description: String
        /// The popover's last line, e.g. `Deterministic · no notification`.
        public let shape: String?

        public init(owner: HyperBindingOwner, overlay: String? = nil, key: String? = nil, label: String, description: String, shape: String? = nil) {
            self.owner = owner
            self.overlay = overlay
            self.key = key
            self.label = label
            self.description = description
            self.shape = shape
        }
    }

    public let version: Int
    public let bindings: [Entry]

    public init(version: Int = 1, bindings: [Entry]) {
        self.version = version
        self.bindings = bindings
    }

    public static let fileName = "hyper-bindings.json"

    public static func decode(_ data: Data) throws -> HyperBindingsFile {
        try JSONDecoder().decode(HyperBindingsFile.self, from: data)
    }
}

/// One drawn binding, keyed by its cap.
public struct HyperCapBinding: Sendable, Equatable {
    public let capID: String
    public let label: String
    public let description: String
    public let kind: HyperBindingKind
    public let owner: HyperBindingOwner
    public let overlayID: String?
    public let shape: String
    /// The effective registered chord(s), including modifiers. Nil only for
    /// imported display-only Keyboard Maestro entries.
    public let chordLabel: String?
    public let actionCount: Int

    public init(capID: String, label: String, description: String, kind: HyperBindingKind, owner: HyperBindingOwner, overlayID: String?, shape: String,
                chordLabel: String? = nil, actionCount: Int = 1) {
        self.capID = capID
        self.label = label
        self.description = description
        self.kind = kind
        self.owner = owner
        self.overlayID = overlayID
        self.shape = shape
        self.chordLabel = chordLabel
        self.actionCount = actionCount
    }
}

/// What the overlay draws: the chords that actually registered, named by the
/// bindings file, plus the Keyboard Maestro keys the file lists. Problems are
/// reported and skipped, never fatal: the overlay is a hint.
public struct HyperBindingCatalog: Sendable, Equatable {
    public let bindings: [String: HyperCapBinding]
    public let problems: [String]

    public init(bindings: [String: HyperCapBinding], problems: [String]) {
        self.bindings = bindings
        self.problems = problems
    }

    public static func build(registered: [OverlayHotKeyBinding], file: HyperBindingsFile?, layout: HyperKeyboardLayout,
                             labels: [String: String] = [:]) -> HyperBindingCatalog {
        var bindings: [String: HyperCapBinding] = [:]
        var problems: [String] = []
        let entries = file?.bindings ?? []
        var named: [String: HyperBindingsFile.Entry] = [:]
        for entry in entries where entry.owner == .native {
            guard let overlay = entry.overlay else {
                problems.append("a native entry (\(entry.label)) names no overlay")
                continue
            }
            if named[overlay] != nil { problems.append("\(overlay) is named twice; the first entry wins") }
            else { named[overlay] = entry }
        }

        for binding in registered {
            let entry = named[binding.overlayID]
            let capID = entry?.key ?? layout.cap(forKeyCode: binding.chord.keyCode)?.id
            guard let capID, layout.cap(id: capID) != nil else {
                problems.append("\(binding.overlayID): key code \(binding.chord.keyCode) has no cap in \(layout.name)")
                continue
            }
            let kind = HyperBindingKind.of(overlayID: binding.overlayID)
            let label = labels[binding.overlayID] ?? entry?.label ?? fallbackLabel(binding.overlayID)
            let cap = layout.cap(id: capID)!
            let chord = chordDescription(binding.chord, cap: cap)
            if let existing = bindings[capID] {
                let earlier = existing.actionCount == 1
                    ? "\(existing.chordLabel ?? cap.glyph): \(existing.label)"
                    : existing.description
                bindings[capID] = HyperCapBinding(
                    capID: capID, label: "\(existing.actionCount + 1) actions",
                    description: earlier + "\n\(chord): \(label)",
                    kind: existing.kind == .surface || kind == .surface ? .surface : .command,
                    owner: .native, overlayID: nil, shape: "Multiple shortcuts",
                    chordLabel: [existing.chordLabel, chord].compactMap { $0 }.joined(separator: " / "),
                    actionCount: existing.actionCount + 1
                )
                continue
            }
            bindings[capID] = HyperCapBinding(
                capID: capID, label: label, description: entry?.description ?? label, kind: kind,
                owner: .native, overlayID: binding.overlayID, shape: entry?.shape ?? defaultShape(kind: kind, owner: .native),
                chordLabel: chord
            )
        }

        for entry in entries where entry.owner == .keyboardMaestro {
            guard let capID = entry.key, layout.cap(id: capID) != nil else {
                problems.append("\(entry.label): \(entry.key.map { "\"\($0)\"" } ?? "no key") is not a cap in \(layout.name)")
                continue
            }
            if let existing = bindings[capID] {
                problems.append("\(entry.label): \(capID) is taken by \(existing.overlayID ?? existing.label)")
                continue
            }
            if entry.overlay != nil { problems.append("\(entry.label): a Keyboard Maestro entry names an overlay; ignored") }
            bindings[capID] = HyperCapBinding(
                capID: capID, label: entry.label, description: entry.description, kind: .command,
                owner: .keyboardMaestro, overlayID: nil, shape: entry.shape ?? defaultShape(kind: .command, owner: .keyboardMaestro)
            )
        }
        return HyperBindingCatalog(bindings: bindings, problems: problems)
    }

    /// Live labels over the file's, by overlay id: Collect's counts (C108).
    public func relabeled(_ labels: [String: String]) -> HyperBindingCatalog {
        guard !labels.isEmpty else { return self }
        let updated = bindings.mapValues { binding -> HyperCapBinding in
            guard let id = binding.overlayID, let label = labels[id] else { return binding }
            return HyperCapBinding(capID: binding.capID, label: label, description: binding.description, kind: binding.kind,
                                   owner: binding.owner, overlayID: id, shape: binding.shape,
                                   chordLabel: binding.chordLabel, actionCount: binding.actionCount)
        }
        return HyperBindingCatalog(bindings: updated, problems: problems)
    }

    private static func chordDescription(_ chord: HotKeyChord, cap: HyperKeyCap) -> String {
        let modifiers = chord.modifiers.map { modifier -> String in
            switch modifier {
            case .command: "⌘"
            case .option: "⌥"
            case .control: "⌃"
            case .shift: "⇧"
            }
        }.joined()
        return modifiers + (cap.glyph.isEmpty ? cap.id : cap.glyph)
    }

    /// `hyper-web-search` → `Web search`, for a native chord the file does not
    /// name yet: it still appears, and the file can name it later.
    static func fallbackLabel(_ overlayID: String) -> String {
        let words = overlayID.split(separator: "-").dropFirst(overlayID.hasPrefix("hyper-") ? 1 : 0)
        let joined = words.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    static func defaultShape(kind: HyperBindingKind, owner: HyperBindingOwner) -> String {
        switch (kind, owner) {
        case (.surface, _): "Opens a surface"
        case (.command, .native): "Runs at once"
        case (.command, .keyboardMaestro): "Runs at once · Keyboard Maestro"
        }
    }
}
