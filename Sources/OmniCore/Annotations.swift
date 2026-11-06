import Foundation

/// What a note is attached to (decision D2, amending C47/C49). A span note
/// steers its span and dies with it; a request note steers the whole request,
/// has no tint and no span lifecycle, and goes when the request is cleared.
public enum OmniAnnotationScope: String, Codable, Sendable, Equatable {
    case span
    case request
}

/// Who wrote a note: the person, or the model as a proposal the person ticked
/// (D6). Unticked proposals are never stored as notes.
public enum OmniAnnotationOrigin: String, Codable, Sendable, Equatable {
    case user
    case proposed
}

/// A comment on the editor's raw text. `range` uses UTF-16 offsets, matching
/// NSTextView and NSRange; guidance is never part of the request text. A
/// request-scoped note keeps the empty range at 0 and is never projected onto
/// a span. `label` is a role marker for the route line only (a chosen
/// position's title); it never reaches a prompt.
public struct OmniTextAnnotation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let range: NSRange
    public let guidance: String
    public let scope: OmniAnnotationScope
    public let origin: OmniAnnotationOrigin
    public let label: String?

    public init(id: UUID = UUID(), range: NSRange, guidance: String, origin: OmniAnnotationOrigin = .user) {
        self.id = id
        self.range = range
        self.guidance = guidance
        scope = .span
        self.origin = origin
        label = nil
    }

    private init(id: UUID, range: NSRange, guidance: String, scope: OmniAnnotationScope, origin: OmniAnnotationOrigin, label: String?) {
        self.id = id
        self.range = scope == .request ? NSRange(location: 0, length: 0) : range
        self.guidance = guidance
        self.scope = scope
        self.origin = origin
        self.label = label
    }

    /// A note on the whole request, such as a chosen position.
    public static func request(id: UUID = UUID(), guidance: String, origin: OmniAnnotationOrigin, label: String? = nil) -> OmniTextAnnotation {
        OmniTextAnnotation(id: id, range: NSRange(location: 0, length: 0), guidance: guidance, scope: .request, origin: origin, label: label)
    }

    public var isRequestScoped: Bool { scope == .request }

    public func with(range: NSRange) -> OmniTextAnnotation {
        OmniTextAnnotation(id: id, range: range, guidance: guidance, scope: scope, origin: origin, label: label)
    }

    public func with(guidance: String) -> OmniTextAnnotation {
        OmniTextAnnotation(id: id, range: range, guidance: guidance, scope: scope, origin: origin, label: label)
    }

    /// The person rewrote this note: its words are now theirs, so it is no
    /// longer a model's suggestion. A position note keeps its label: it is
    /// still the position, shown in the route line and replaced by a later
    /// pick or a re-run `/stance` (single-pick, D6).
    public func editedByUser(guidance: String) -> OmniTextAnnotation {
        guard guidance != self.guidance else { return self }
        return OmniTextAnnotation(id: id, range: range, guidance: guidance, scope: scope, origin: .user, label: label)
    }

    private enum CodingKeys: String, CodingKey {
        case id, range, guidance, scope, origin, label
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let scope = try values.decodeIfPresent(OmniAnnotationScope.self, forKey: .scope) ?? .span
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            range: try values.decode(NSRange.self, forKey: .range),
            guidance: try values.decode(String.self, forKey: .guidance),
            scope: scope,
            origin: try values.decodeIfPresent(OmniAnnotationOrigin.self, forKey: .origin) ?? .user,
            label: try values.decodeIfPresent(String.self, forKey: .label)
        )
    }

    /// Defaults are omitted, so a user's span note encodes exactly as before
    /// the decision step and older hosts decode every stored note.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(range, forKey: .range)
        try values.encode(guidance, forKey: .guidance)
        if scope != .span { try values.encode(scope, forKey: .scope) }
        if origin != .user { try values.encode(origin, forKey: .origin) }
        try values.encodeIfPresent(label, forKey: .label)
    }
}

public enum OmniAnnotationRanges {
    /// Drop malformed annotations at an application boundary. UI attachment
    /// rejects overlap; this also protects callers that bypass the UI.
    public static func validated(_ annotations: [OmniTextAnnotation], in rawText: String) -> [OmniTextAnnotation] {
        // Request notes list first, in their given order, once each; they
        // need guidance and a request to steer, never a span.
        var requestIDs: Set<UUID> = []
        let requestNotes = rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : annotations.filter { note in
            note.isRequestScoped
                && !note.guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && requestIDs.insert(note.id).inserted
        }
        return requestNotes + validatedSpans(annotations.filter { !$0.isRequestScoped }, in: rawText)
    }

    private static func validatedSpans(_ annotations: [OmniTextAnnotation], in rawText: String) -> [OmniTextAnnotation] {
        let count = rawText.utf16.count
        let ordered = annotations.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length < $1.range.length }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result: [OmniTextAnnotation] = []
        var lastEnd = 0
        for annotation in ordered {
            let range = annotation.range
            guard range.location >= 0, range.length > 0,
                  range.location <= count, range.length <= count - range.location,
                  range.location >= lastEnd,
                  !annotation.guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Range(range, in: rawText) != nil
            else { continue }
            result.append(annotation)
            lastEnd = NSMaxRange(range)
        }
        return result
    }

    /// Reconcile one exact edit in old-text coordinates. Insertion strictly
    /// inside a span extends it; insertion at either boundary does not.
    public static func remap(
        _ annotations: [OmniTextAnnotation],
        replacing oldRange: NSRange,
        withUTF16Length replacementLength: Int
    ) -> [OmniTextAnnotation] {
        guard oldRange.location >= 0, oldRange.length >= 0,
              oldRange.length <= Int.max - oldRange.location,
              replacementLength >= 0 else { return annotations }
        let editStart = oldRange.location
        let editEnd = NSMaxRange(oldRange)
        let delta = replacementLength - oldRange.length
        return annotations.compactMap { annotation in
            // A request note has no span lifecycle: edits never move or end it.
            if annotation.isRequestScoped { return annotation }
            let start = annotation.range.location
            guard start >= 0, annotation.range.length > 0,
                  annotation.range.length <= Int.max - start else { return nil }
            let end = NSMaxRange(annotation.range)
            if oldRange.length == 0 {
                if editStart <= start { return annotation.with(range: NSRange(location: start + replacementLength, length: end - start)) }
                if editStart >= end { return annotation }
                return annotation.with(range: NSRange(location: start, length: end - start + replacementLength))
            }
            if editEnd <= start { return annotation.with(range: NSRange(location: start + delta, length: end - start)) }
            if editStart >= end { return annotation }

            let leftSurvives = start < editStart
            let rightSurvives = end > editEnd
            guard leftSurvives || rightSurvives else { return nil }
            let newStart = leftSurvives ? start : editStart + replacementLength
            let newEnd = rightSurvives ? end + delta : editStart + replacementLength
            guard newEnd > newStart else { return nil }
            return annotation.with(range: NSRange(location: newStart, length: newEnd - newStart))
        }
    }

    /// An edit that replaces the whole previous text (a new capture, or
    /// select-all and paste) is a new request: its request notes go with the
    /// old one, exactly as a cleared request's do.
    public static func droppingRequestNotesIfReplaced(
        _ annotations: [OmniTextAnnotation],
        replacing oldRange: NSRange,
        inOldTextOfLength oldLength: Int
    ) -> [OmniTextAnnotation] {
        guard oldLength > 0, oldRange.location == 0, oldRange.length == oldLength else { return annotations }
        return annotations.filter { !$0.isRequestScoped }
    }

    /// A cleared request takes its request notes with it; span notes have
    /// already died with their spans.
    public static func droppingRequestNotesIfBlank(_ annotations: [OmniTextAnnotation], in rawText: String) -> [OmniTextAnnotation] {
        guard rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return annotations }
        return annotations.filter { !$0.isRequestScoped }
    }

    /// Keys a note by text the model quoted (D2/D6): the exact quote found
    /// exactly once in the payload, mapped back to raw editor coordinates,
    /// and only where it overlaps none of `existing`. Nil means the note
    /// belongs to the whole request instead.
    public static func uniqueRawRange(
        ofQuote quote: String,
        inRawText rawText: String,
        avoiding existing: [OmniTextAnnotation] = []
    ) -> NSRange? {
        if case .unique(let range) = quoteMatch(ofQuote: quote, inRawText: rawText, avoiding: existing) { return range }
        return nil
    }

    /// Where a model's quote sits in the material. Matching is exact and
    /// case-sensitive; only when that finds nothing are typographic quotes
    /// and apostrophes folded to straight ones on both sides (mail text has
    /// `’` where a model writes `'`). Every fold is one UTF-16 unit for one,
    /// so folded offsets are raw offsets.
    public static func quoteMatch(
        ofQuote quote: String,
        inRawText rawText: String,
        avoiding existing: [OmniTextAnnotation] = []
    ) -> OmniQuoteMatch {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .absent }
        let (payload, segments) = OmniAnnotationProjection.segments(of: rawText)
        var found = occurrence(of: needle, in: payload as NSString)
        if case .absent = found {
            found = occurrence(of: Self.foldingQuotes(needle), in: Self.foldingQuotes(payload) as NSString)
        }
        guard case .unique(let first) = found else { return found }
        var rawStart: Int?
        var rawEnd: Int?
        for segment in segments {
            let lower = max(first.location, segment.payload.location)
            let upper = min(NSMaxRange(first), NSMaxRange(segment.payload))
            guard upper > lower else { continue }
            if rawStart == nil { rawStart = segment.raw.location + lower - segment.payload.location }
            rawEnd = segment.raw.location + upper - segment.payload.location
        }
        guard let rawStart, let rawEnd, rawEnd > rawStart else { return .absent }
        let range = NSRange(location: rawStart, length: rawEnd - rawStart)
        guard Range(range, in: rawText) != nil else { return .absent }
        if existing.contains(where: { !$0.isRequestScoped && NSIntersectionRange($0.range, range).length > 0 }) {
            return .ambiguous
        }
        return .unique(range)
    }

    /// Overlapping second occurrences count: the quote must be unambiguous.
    private static func occurrence(of needle: String, in haystack: NSString) -> OmniQuoteMatch {
        let first = haystack.range(of: needle)
        guard first.location != NSNotFound else { return .absent }
        let tail = NSRange(location: first.location + 1, length: haystack.length - first.location - 1)
        guard haystack.range(of: needle, range: tail).location == NSNotFound else { return .ambiguous }
        return .unique(first)
    }

    static func foldingQuotes(_ text: String) -> String {
        var units = Array(text.utf16)
        for index in units.indices {
            switch units[index] {
            case 0x2018, 0x2019, 0x201A, 0x201B, 0x2032: units[index] = 0x27 // ‘ ’ ‚ ‛ ′ → '
            case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033: units[index] = 0x22 // “ ” „ ‟ ″ → "
            default: break
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// A model quote's place in the material: on one span, real text that is
/// not unique (it occurs twice, or overlaps a note), or not in the text.
public enum OmniQuoteMatch: Sendable, Equatable {
    case unique(NSRange)
    case ambiguous
    case absent
}

public struct OmniProjectedAnnotation: Sendable, Equatable {
    public let annotation: OmniTextAnnotation
    /// Nil when a span note covers only a stripped slash atom or marker, and
    /// always nil for a request note (which `annotation.scope` tells apart).
    public let payloadRange: NSRange?
    public let rawSelectedText: String

    public init(annotation: OmniTextAnnotation, payloadRange: NSRange?, rawSelectedText: String) {
        self.annotation = annotation
        self.payloadRange = payloadRange
        self.rawSelectedText = rawSelectedText
    }
}

public struct OmniAnnotationRemapResult: Sendable, Equatable {
    public let annotations: [OmniTextAnnotation]
    public let unmappedCount: Int

    public init(annotations: [OmniTextAnnotation], unmappedCount: Int) {
        self.annotations = annotations
        self.unmappedCount = unmappedCount
    }
}

public enum OmniAnnotationProjectionError: Error, Sendable, Equatable {
    case payloadMismatch
    case invalidRemovedRange
}

public enum OmniAnnotationProjection {
    fileprivate struct Segment {
        let raw: NSRange
        let payload: NSRange
    }

    fileprivate static func segments(of rawText: String) -> (String, [Segment]) {
        payloadSegments(from: rawText)
    }

    /// Mirrors SlashTokenSyntax's split/filter/join transform while retaining
    /// origin offsets. Duplicate words are mapped by position, never search.
    public static func payload(
        from rawText: String,
        matching payloadText: String,
        annotations: [OmniTextAnnotation]
    ) throws -> [OmniProjectedAnnotation] {
        let (reconstructed, segments) = payloadSegments(from: rawText)
        guard reconstructed == payloadText else { throw OmniAnnotationProjectionError.payloadMismatch }
        return project(annotations, rawText: rawText, segments: segments)
    }

    /// Carry comments into a proposal-chosen input only when their anchor has
    /// an unambiguous correspondence. The proposal model never sees the notes.
    public static func remap(
        _ annotations: [OmniTextAnnotation],
        fromRawText sourceText: String,
        toRawText targetText: String
    ) -> OmniAnnotationRemapResult {
        let source = OmniAnnotationRanges.validated(annotations, in: sourceText)
        guard !source.isEmpty else { return OmniAnnotationRemapResult(annotations: [], unmappedCount: 0) }
        let (sourcePayload, sourceSegments) = payloadSegments(from: sourceText)
        let (targetPayload, targetSegments) = payloadSegments(from: targetText)
        let sourceProjected = project(source, rawText: sourceText, segments: sourceSegments)
        var mapped: [OmniTextAnnotation] = []
        var unmapped = 0
        for item in sourceProjected {
            // A request note travels with the request, whatever its text became.
            if item.annotation.isRequestScoped {
                mapped.append(item.annotation)
                continue
            }
            var targetRange: NSRange?
            if sourcePayload == targetPayload, let payloadRange = item.payloadRange {
                let lower = payloadRange.location
                let upper = NSMaxRange(payloadRange)
                var rawStart: Int?
                var rawEnd: Int?
                for segment in targetSegments {
                    let overlapStart = max(lower, segment.payload.location)
                    let overlapEnd = min(upper, NSMaxRange(segment.payload))
                    guard overlapEnd > overlapStart else { continue }
                    let start = segment.raw.location + overlapStart - segment.payload.location
                    let end = segment.raw.location + overlapEnd - segment.payload.location
                    if rawStart == nil { rawStart = start }
                    rawEnd = end
                }
                if let rawStart, let rawEnd, rawEnd > rawStart {
                    targetRange = NSRange(location: rawStart, length: rawEnd - rawStart)
                }
            }
            if targetRange == nil {
                targetRange = anchoredUniqueRange(for: item, in: sourceText, targetText: targetText)
            }
            if let targetRange {
                mapped.append(item.annotation.with(range: targetRange))
            } else {
                unmapped += 1
            }
        }
        let validated = OmniAnnotationRanges.validated(mapped, in: targetText)
        return OmniAnnotationRemapResult(
            annotations: validated,
            unmappedCount: unmapped + mapped.count - validated.count
        )
    }

    private static func anchoredUniqueRange(
        for item: OmniProjectedAnnotation, in sourceText: String, targetText: String
    ) -> NSRange? {
        let selection = item.annotation.range
        let selectionEnd = NSMaxRange(selection)
        let atoms = rawAtomRanges(in: sourceText).filter {
            max(selection.location, $0.location) < min(selectionEnd, NSMaxRange($0))
        }
        guard let firstAtom = atoms.first, let lastAtom = atoms.last,
              selection.location >= firstAtom.location,
              selectionEnd <= NSMaxRange(lastAtom) else { return nil }
        let anchor = NSRange(location: firstAtom.location, length: NSMaxRange(lastAtom) - firstAtom.location)
        guard let sourceRange = Range(anchor, in: sourceText) else { return nil }
        let wholeAtoms = String(sourceText[sourceRange])
        // A repeated source atom cannot identify which occurrence survived a
        // proposal rewrite, even when the target contains it only once.
        guard uniqueWholeAtomRange(of: wholeAtoms, in: sourceText) == anchor,
              let onlyMatch = uniqueWholeAtomRange(of: wholeAtoms, in: targetText)
        else { return nil }
        return NSRange(
            location: onlyMatch.location + selection.location - anchor.location,
            length: selection.length
        )
    }

    private static func uniqueWholeAtomRange(of wholeAtoms: String, in text: String) -> NSRange? {
        let target = text as NSString
        var searchStart = 0
        var onlyMatch: NSRange?
        while searchStart <= target.length - (wholeAtoms as NSString).length {
            let candidate = target.range(
                of: wholeAtoms,
                range: NSRange(location: searchStart, length: target.length - searchStart)
            )
            guard candidate.location != NSNotFound else { break }
            if let swiftRange = Range(candidate, in: text) {
                let leftBoundary = swiftRange.lowerBound == text.startIndex ||
                    text[..<swiftRange.lowerBound].last?.isWhitespace == true
                let rightBoundary = swiftRange.upperBound == text.endIndex ||
                    text[swiftRange.upperBound...].first?.isWhitespace == true
                if leftBoundary && rightBoundary {
                    guard onlyMatch == nil else { return nil }
                    onlyMatch = candidate
                }
            }
            // Advance one unit so overlapping matches count as ambiguous.
            searchStart = candidate.location + 1
        }
        return onlyMatch
    }

    private static func rawAtomRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            ranges.append(NSRange(start..<index, in: text))
        }
        return ranges
    }

    private static func payloadSegments(from rawText: String) -> (String, [Segment]) {
        var segments: [Segment] = []
        var reconstructed = ""
        var index = rawText.startIndex
        while index < rawText.endIndex {
            if rawText[index].isWhitespace {
                index = rawText.index(after: index)
                continue
            }
            let start = index
            while index < rawText.endIndex, !rawText[index].isWhitespace {
                index = rawText.index(after: index)
            }
            let atom = String(rawText[start..<index])
            guard atom != "✓", atom != "✗", SlashAtom.parse(atom) == nil else { continue }
            if !reconstructed.isEmpty { reconstructed += " " }
            let offset = reconstructed.utf16.count
            reconstructed += atom
            segments.append(Segment(
                raw: NSRange(start..<index, in: rawText),
                payload: NSRange(location: offset, length: atom.utf16.count)
            ))
        }
        return (reconstructed, segments)
    }

    /// Mirrors the follow-up parser's one token removal and outer trim.
    public static func followUp(
        from rawText: String,
        matching sourceText: String,
        annotations: [OmniTextAnnotation]
    ) throws -> [OmniProjectedAnnotation] {
        var operationRanges: [NSRange] = []
        var index = rawText.startIndex
        while index < rawText.endIndex {
            if rawText[index].isWhitespace {
                index = rawText.index(after: index)
                continue
            }
            let start = index
            while index < rawText.endIndex, !rawText[index].isWhitespace {
                index = rawText.index(after: index)
            }
            if OmniFollowUpOperation(token: rawText[start..<index]) != nil {
                operationRanges.append(NSRange(start..<index, in: rawText))
            }
        }
        guard operationRanges.count == 1, let range = operationRanges.first else {
            throw OmniAnnotationProjectionError.invalidRemovedRange
        }
        return try followUp(from: rawText, removing: range, matching: sourceText, annotations: annotations)
    }

    public static func followUp(
        from rawText: String,
        removing operationRange: NSRange,
        matching sourceText: String,
        annotations: [OmniTextAnnotation]
    ) throws -> [OmniProjectedAnnotation] {
        guard let removed = Range(operationRange, in: rawText) else {
            throw OmniAnnotationProjectionError.invalidRemovedRange
        }
        var edited = rawText
        edited.removeSubrange(removed)
        guard edited.trimmingCharacters(in: .whitespacesAndNewlines) == sourceText else {
            throw OmniAnnotationProjectionError.payloadMismatch
        }
        let retainedBefore = String(rawText[..<removed.lowerBound])
        let retainedAfter = String(rawText[removed.upperBound...])
        let merged = retainedBefore + retainedAfter
        let scalars = merged.unicodeScalars
        var first = scalars.startIndex
        while first < scalars.endIndex, CharacterSet.whitespacesAndNewlines.contains(scalars[first]) {
            scalars.formIndex(after: &first)
        }
        var last = scalars.endIndex
        while last > first {
            let previous = scalars.index(before: last)
            guard CharacterSet.whitespacesAndNewlines.contains(scalars[previous]) else { break }
            last = previous
        }
        let trimStart = merged.utf16.distance(from: merged.startIndex, to: first)
        let trimEnd = merged.utf16.distance(from: merged.startIndex, to: last)
        let beforeCount = retainedBefore.utf16.count
        let removeEnd = NSMaxRange(operationRange)
        var segments: [Segment] = []
        if trimStart < min(beforeCount, trimEnd) {
            let lower = trimStart
            let upper = min(beforeCount, trimEnd)
            segments.append(Segment(raw: NSRange(location: lower, length: upper - lower), payload: NSRange(location: 0, length: upper - lower)))
        }
        if trimEnd > max(beforeCount, trimStart) {
            let lower = max(beforeCount, trimStart)
            let upper = trimEnd
            segments.append(Segment(
                raw: NSRange(location: removeEnd + lower - beforeCount, length: upper - lower),
                payload: NSRange(location: lower - trimStart, length: upper - lower)
            ))
        }
        return project(annotations, rawText: rawText, segments: segments)
    }

    private static func project(
        _ annotations: [OmniTextAnnotation], rawText: String, segments: [Segment]
    ) -> [OmniProjectedAnnotation] {
        OmniAnnotationRanges.validated(annotations, in: rawText).map { annotation in
            // A request note selects no text and never maps onto the payload.
            if annotation.isRequestScoped {
                return OmniProjectedAnnotation(annotation: annotation, payloadRange: nil, rawSelectedText: "")
            }
            let selected = String(rawText[Range(annotation.range, in: rawText)!])
            var mappedStart: Int?
            var mappedEnd: Int?
            let sourceStart = annotation.range.location
            let sourceEnd = NSMaxRange(annotation.range)
            for segment in segments {
                let lower = max(sourceStart, segment.raw.location)
                let upper = min(sourceEnd, NSMaxRange(segment.raw))
                guard upper > lower else { continue }
                let start = segment.payload.location + lower - segment.raw.location
                let end = segment.payload.location + upper - segment.raw.location
                if mappedStart == nil { mappedStart = start }
                mappedEnd = end
            }
            let mappedRange = mappedStart.flatMap { start in mappedEnd.map { NSRange(location: start, length: $0 - start) } }
            return OmniProjectedAnnotation(annotation: annotation, payloadRange: mappedRange, rawSelectedText: selected)
        }
    }

    public static func rawOnly(from rawText: String, annotations: [OmniTextAnnotation]) -> [OmniProjectedAnnotation] {
        OmniAnnotationRanges.validated(annotations, in: rawText).compactMap { annotation in
            if annotation.isRequestScoped {
                return OmniProjectedAnnotation(annotation: annotation, payloadRange: nil, rawSelectedText: "")
            }
            guard let range = Range(annotation.range, in: rawText) else { return nil }
            return OmniProjectedAnnotation(annotation: annotation, payloadRange: nil, rawSelectedText: String(rawText[range]))
        }
    }
}

/// The A/B switch is internal to the prompt boundary; both formats carry the
/// same projected spans. The absent variable keeps the current default until
/// the isolated A/B chooses a winner.
public enum OmniAnnotationPromptFormat: String, Codable, Sendable, Equatable {
    case structured
    case delimited

    public static var configuredDefault: OmniAnnotationPromptFormat {
        guard let value = ProcessInfo.processInfo.environment["OMNI_ANNOTATION_FORMAT"] else { return .structured }
        return OmniAnnotationPromptFormat(rawValue: value.lowercased()) ?? .structured
    }
}

public struct OmniAnnotationPromptRendering: Sendable, Equatable {
    public let userText: String
    /// Append to the original prompt, after the user-text block.
    public let metaSuffix: String

    public init(userText: String, metaSuffix: String) {
        self.userText = userText
        self.metaSuffix = metaSuffix
    }
}

public enum OmniAnnotationPrompt {
    private struct Span: Encodable {
        let start: Int
        let end: Int
        let text: String
    }

    private struct Row: Encodable {
        let id: String
        let sourceSpan: Span?
        let payloadSpan: Span?
        let guidance: String
        let marker: String?
        /// Present only for request notes, so span rows keep their bytes.
        let scope: String?
        /// Present only for model-proposed notes: a user's note keeps its bytes.
        let origin: String?
    }

    private struct Block: Encodable {
        let annotations: [Row]
    }

    /// Only the marked user-text view differs in the delimited variant. All
    /// guidance remains in the explicit meta block after the existing prompt.
    public static func render(
        payloadText: String,
        projected: [OmniProjectedAnnotation],
        format: OmniAnnotationPromptFormat,
        sourceText: String = ""
    ) -> OmniAnnotationPromptRendering {
        guard !projected.isEmpty else { return OmniAnnotationPromptRendering(userText: payloadText, metaSuffix: "") }
        // Request notes exist only in the structured rows: the delimited
        // variant marks spans and has nowhere to put one, so their presence
        // selects the structured rendering for the whole request.
        let hasRequestNotes = projected.contains { $0.annotation.isRequestScoped }
        let hasProposedNotes = projected.contains { $0.annotation.origin == .proposed }
        let format = hasRequestNotes ? .structured : format
        let namespace = delimiterNamespace(payloadText: payloadText, sourceText: sourceText, projected: projected)
        let payloadCount = payloadText.utf16.count
        let ordered = projected.enumerated().sorted {
            let a = $0.element.payloadRange?.location ?? Int.max
            let b = $1.element.payloadRange?.location ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }
        var markedText = ""
        var cursor = 0
        var markers: [UUID: String] = [:]
        if format == .delimited {
            for (index, entry) in ordered.enumerated() {
                let item = entry.element
                guard let span = item.payloadRange, span.length > 0,
                      span.location >= cursor,
                      span.location <= payloadCount,
                      span.length <= payloadCount - span.location,
                      let before = Range(NSRange(location: cursor, length: span.location - cursor), in: payloadText),
                      let selected = Range(span, in: payloadText)
                else { continue }
                let marker = "N\(index + 1)"
                markers[item.annotation.id] = marker
                markedText += payloadText[before]
                markedText += "«\(namespace)_\(marker)_START»"
                markedText += payloadText[selected]
                markedText += "«\(namespace)_\(marker)_END»"
                cursor = NSMaxRange(span)
            }
            if let remaining = Range(NSRange(location: cursor, length: payloadCount - cursor), in: payloadText) {
                markedText += payloadText[remaining]
            }
        }
        let rows = projected.map { item in
            if item.annotation.isRequestScoped {
                return Row(id: item.annotation.id.uuidString.lowercased(), sourceSpan: nil, payloadSpan: nil, guidance: item.annotation.guidance, marker: nil, scope: OmniAnnotationScope.request.rawValue, origin: Self.originField(item.annotation))
            }
            let source = item.annotation.range
            let payloadSpan: Span? = item.payloadRange.flatMap { range in
                guard let swiftRange = Range(range, in: payloadText) else { return nil }
                return Span(start: range.location, end: NSMaxRange(range), text: String(payloadText[swiftRange]))
            }
            return Row(
                id: item.annotation.id.uuidString.lowercased(),
                sourceSpan: Span(start: source.location, end: NSMaxRange(source), text: item.rawSelectedText),
                payloadSpan: payloadSpan,
                guidance: item.annotation.guidance,
                marker: markers[item.annotation.id],
                scope: nil,
                origin: Self.originField(item.annotation)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(Block(annotations: rows))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // Prevent guidance text from spelling a delimiter inside the block.
        let escapedJSON = json.replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
        let suffix = """


        <\(namespace)_META_BEGIN>
        The following annotations are model-facing guidance attached to spans of the user's text. They are not user text, are not to be rewritten or quoted, and must never appear in the output. sourceSpan UTF-16 positions refer to the raw editor text; payloadSpan UTF-16 positions refer to the unmarked payload. A null payloadSpan means the selected raw text was removed as a command token or marker; apply its guidance to that command context without adding the selected token to the output. If markers appear in the user-text block, they only locate spans and must not appear in the output.
        Follow every annotation together within the task requested in the user text. A note steers its span and does not replace the task. Preserve context outside the requested changes, including anything a note says to keep; do not invent participants or facts from the quoted spans.
        When the task asks to reply to a message or accept or decline an invitation, draft the response from that message's recipient to its sender. Do not rewrite the incoming message or copy its greeting and signature as the response's recipient and writer.\(hasRequestNotes ? "\n" + requestNotesPreamble : "")\(hasProposedNotes ? "\n" + proposedNotesPreamble : "")
        \(escapedJSON)
        <\(namespace)_META_END>
        """
        return OmniAnnotationPromptRendering(userText: format == .delimited ? markedText : payloadText, metaSuffix: suffix)
    }

    /// Added only when a request row exists, so span-only prompts keep the
    /// exact preamble the H7 comparison measured.
    public static let requestNotesPreamble = "A row whose scope is \"request\" has no span: its guidance applies to the whole request, such as the position the user chose after reading the material or a point the user wants handled, and it may say which way the response runs. Request guidance is not user text: follow it without quoting or restating it."

    /// Added only when a model-proposed row exists: a suggestion the user
    /// chose steers direction and is never a source of circumstances.
    public static let proposedNotesPreamble = "A row whose origin is \"proposed\" was suggested by a model and chosen by the user: it sets direction only. It never supplies availability, times, dates, workload, deadlines, attachments, sent items, commitments, reasons, or history; those come only from the user text and the user's own notes."

    private static func originField(_ annotation: OmniTextAnnotation) -> String? {
        annotation.origin == .proposed ? OmniAnnotationOrigin.proposed.rawValue : nil
    }

    private static func delimiterNamespace(
        payloadText: String,
        sourceText: String,
        projected: [OmniProjectedAnnotation]
    ) -> String {
        let sources = [payloadText, sourceText] + projected.flatMap { [$0.rawSelectedText, $0.annotation.guidance] }
        // FNV-1a supplies a repeatable seed; the collision loop, rather than
        // the hash alone, guarantees the chosen namespace is absent in input.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for source in sources {
            for byte in source.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            hash = (hash ^ 255) &* 1_099_511_628_211
        }
        let base = "OMNI_" + String(format: "%016llx", hash)
        var candidate = base
        var suffix = 0
        while sources.contains(where: { $0.contains(candidate) }) {
            suffix += 1
            candidate = "\(base)_\(suffix)"
        }
        return candidate
    }
}
