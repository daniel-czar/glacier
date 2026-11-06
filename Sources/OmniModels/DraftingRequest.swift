import Foundation
import OmniCore

/// A drafting request keeps captured material separate from the instruction
/// appended to a standalone `/email` or `/msg` command. This is prompt data;
/// it does not change command parsing or the stored ModuleInput payload.
public struct DraftingRequest: Sendable, Equatable {
    public let suppliedMaterial: String
    public let userRequest: String
    public let materialSourceHint: String?
    public let annotations: [DraftingAnnotation]

    public init(
        input: ModuleInput,
        workflow: LanguageWorkflow,
        annotations: [OmniTextAnnotation] = [],
        materialSource: String? = nil
    ) {
        let raw = input.rawText
        let command = workflow == .message ? "/msg" : "/email"
        let atoms = Self.atoms(in: raw)
        let commandAtoms = atoms.filter { $0.text == command }
        let commandAtom = commandAtoms.count == 1 ? commandAtoms[0] : nil
        let sourceRegion = NSRange(location: 0, length: commandAtom?.range.location ?? 0)
        let requestStart = commandAtom.map { NSMaxRange($0.range) } ?? 0
        let requestRegion = NSRange(location: requestStart, length: (raw as NSString).length - requestStart)
        // Only recognized control atoms are removed. Slash-shaped words in
        // quoted material and ordinary prose remain literal source content.
        let controls = atoms.filter { atom in
            guard let commandAtom else { return false }
            if atom.range == commandAtom.range { return true }
            if atom.text == "/style:formal" || atom.text == "/formal" {
                return input.modifiers.contains("/style:formal")
            }
            if atom.text == "/offline" { return input.modes.contains("/offline") }
            if atom.text == "✓" || atom.text == "✗" { return input.markers.contains(atom.text) }
            return false
        }.map(\.range)
        let source = Self.section(raw: raw, region: sourceRegion, excluding: controls)
        let request = Self.section(raw: raw, region: requestRegion, excluding: controls)
        suppliedMaterial = source.text
        // Some synthetic/older callers provide a payload independently of raw
        // editor text. The raw request is authoritative whenever it contains a
        // substantive command-relative request or a source/annotation span.
        if commandAtom == nil || (request.text.isEmpty && source.text.isEmpty && annotations.isEmpty) {
            userRequest = input.payloadText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            userRequest = request.text
        }
        materialSourceHint = materialSource?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.annotations = OmniAnnotationRanges.validated(annotations, in: raw).map { note in
            let selected = note.isRequestScoped ? nil : Self.substring(raw, range: note.range)
            let placement: (String, NSRange)? = note.isRequestScoped || commandAtom == nil ? nil :
                source.mappedRange(for: note.range).map { ("supplied_material", $0) } ??
                request.mappedRange(for: note.range).map { ("user_request", $0) }
            let field: String = note.isRequestScoped ? "whole_request" :
                placement?.0 ?? (controls.contains { NSIntersectionRange($0, note.range).length > 0 } ? "cross_boundary_or_command" : "whole_request")
            return DraftingAnnotation(
                scope: note.isRequestScoped ? "request" : "span",
                origin: note.origin == .proposed ? "proposed" : "user",
                guidance: note.guidance,
                field: field,
                range: placement?.1,
                selectedText: selected
            )
        }
    }

    /// The entire value is JSON encoded so names, quotes, line breaks and
    /// delimiter-like text in source material cannot escape their data fields.
    public func promptEnvelope() throws -> String {
        let envelope = Envelope(
            suppliedMaterial: suppliedMaterial,
            userRequest: userRequest,
            materialSourceHint: materialSourceHint,
            annotations: annotations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(envelope), as: UTF8.self)
    }

    private struct Atom {
        let text: String
        let range: NSRange
    }

    private struct Section {
        let text: String
        /// An entry per retained UTF-16 unit, in output order.
        let rawOffsets: [Int]

        func mappedRange(for rawRange: NSRange) -> NSRange? {
            guard rawRange.length > 0,
                  let first = rawOffsets.firstIndex(of: rawRange.location),
                  first + rawRange.length <= rawOffsets.count else { return nil }
            for index in 0..<rawRange.length where rawOffsets[first + index] != rawRange.location + index {
                return nil
            }
            return NSRange(location: first, length: rawRange.length)
        }
    }

    private struct Envelope: Encodable {
        let suppliedMaterial: String
        let userRequest: String
        let materialSourceHint: String?
        let annotations: [DraftingAnnotation]

        enum CodingKeys: String, CodingKey {
            case suppliedMaterial = "supplied_material"
            case userRequest = "user_request"
            case materialSourceHint = "material_source_hint"
            case annotations
        }
    }

    private static func atoms(in raw: String) -> [Atom] {
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
        return regex.matches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)).compactMap { match in
            guard let range = Range(match.range, in: raw) else { return nil }
            return Atom(text: String(raw[range]), range: match.range)
        }
    }

    private static func section(raw: String, region: NSRange, excluding controls: [NSRange]) -> Section {
        let rawUnits = Array(raw.utf16)
        guard region.length > 0 else { return Section(text: "", rawOffsets: []) }
        var units: [UInt16] = []
        var rawOffsets: [Int] = []
        for offset in region.location..<NSMaxRange(region) {
            guard !controls.contains(where: { NSLocationInRange(offset, $0) }) else { continue }
            units.append(rawUnits[offset])
            rawOffsets.append(offset)
        }
        var lower = 0
        var upper = units.count
        while lower < upper, isEdgeWhitespace(units[lower]) { lower += 1 }
        while upper > lower, isEdgeWhitespace(units[upper - 1]) { upper -= 1 }
        return Section(
            text: String(decoding: units[lower..<upper], as: UTF16.self),
            rawOffsets: Array(rawOffsets[lower..<upper])
        )
    }

    private static func isEdgeWhitespace(_ unit: UInt16) -> Bool {
        UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }

    private static func substring(_ raw: String, range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: raw) else { return nil }
        return String(raw[swiftRange])
    }
}

public struct DraftingAnnotation: Sendable, Equatable, Encodable {
    public let scope: String
    public let origin: String
    public let guidance: String
    public let field: String
    /// UTF-16 coordinates in the named JSON string field, when exact.
    public let range: NSRange?
    public let selectedText: String?

    enum CodingKeys: String, CodingKey {
        case scope, origin, guidance, field, range
        case selectedText = "selected_text"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scope, forKey: .scope)
        try values.encode(origin, forKey: .origin)
        try values.encode(guidance, forKey: .guidance)
        try values.encode(field, forKey: .field)
        if let range {
            try values.encode(["start": range.location, "end": NSMaxRange(range)], forKey: .range)
        }
        try values.encodeIfPresent(selectedText, forKey: .selectedText)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
