import AppKit
import OmniCore

// Picked filters for `/find` (D2, decision surface 569d5a7cf925cbd7) on the
// existing completion menu (C25, C78): after `/find `, Tab lists the facets
// `kind:`, `in:` and `tags:` with live values in the help column; picking a
// facet inserts it and lists its values; picking a value inserts plain text
// such as `kind:review `. A typed prefix narrows both: `k` offers `kind:`,
// `rev` offers `kind:review`. The menu never changes what Enter does.

extension OmniCommandPadViewController {
    /// Values listed under one facet before the list asks for a prefix.
    static let facetValueCap = 40
    /// Values offered for a bare prefix such as `rev`, across all facets.
    static let crossFacetValueCap = 8

    static let facetHelp: [FindFacet: String] = [
        .kind: "The kind the document's frontmatter names.",
        .project: "A project the document names: in:helios finds projects that contain project_helios.",
        .tags: "A tag the document carries.",
    ]

    static let filterKindLine = "Filter · runs on this Mac"

    /// Whether the caret sits in `/find`'s payload, after its token.
    func isInFindPayload() -> Bool {
        let source = editor.string as NSString
        let caret = min(editor.selectedRange().location, source.length)
        let intent = parser.parse(editor.string)
        guard intent.dispatchToken == "/find", intent.primaryTokens.count == 1 else { return false }
        let before = source.substring(to: caret)
        guard let tokenRange = before.range(of: #"(^|\s)/(find|retrieve)(?=\s|$)"#, options: .regularExpression) else { return false }
        // The caret is past the token and the space after it.
        return before[tokenRange.upperBound...].first?.isWhitespace == true
    }

    /// The menu items for the word being typed after `/find`, or nil when the
    /// caret is not in a `/find` payload (the slash palette then decides).
    func findCompletionItems(for atom: String) -> [OmniCompletionItem]? {
        guard !atom.hasPrefix("/"), !atom.hasPrefix("@"), isInFindPayload() else { return nil }
        let facets = onRequestFindFacets?() ?? .empty
        if let colon = atom.firstIndex(of: ":") {
            guard let facet = FindFacet(rawValue: String(atom[..<colon])) else { return [] }
            let typed = String(atom[atom.index(after: colon)...]).lowercased()
            let values = facets.values(for: facet).filter { typed.isEmpty || ($0.value.lowercased().hasPrefix(typed) && $0.value.lowercased() != typed) }
            return values.prefix(Self.facetValueCap).map { Self.valueItem(facet: facet, value: $0) }
        }
        let folded = atom.lowercased()
        var items = FindFacet.allCases.filter { $0.prefix.hasPrefix(folded) && $0.prefix != folded }.map { Self.facetItem($0, facets: facets) }
        var values: [OmniCompletionItem] = []
        for facet in FindFacet.allCases {
            for value in facets.values(for: facet) where value.value.lowercased().hasPrefix(folded) {
                values.append(Self.valueItem(facet: facet, value: value))
                if values.count >= Self.crossFacetValueCap { break }
            }
            if values.count >= Self.crossFacetValueCap { break }
        }
        items.append(contentsOf: values)
        return items
    }

    /// The three facets, for Tab after `/find ` (an explicit ask: a space
    /// alone never opens the menu, C78).
    func findFacetItems() -> [OmniCompletionItem] {
        let facets = onRequestFindFacets?() ?? .empty
        return FindFacet.allCases.map { Self.facetItem($0, facets: facets) }
    }

    static func facetItem(_ facet: FindFacet, facets: FindFacets) -> OmniCompletionItem {
        let top = facets.values(for: facet).prefix(4).map { "\($0.value) \(Self.count($0.count))" }
        return OmniCompletionItem(
            choice: OmniReferenceChoice(id: facet.prefix, canonicalText: facet.prefix, label: facetHelp[facet] ?? ""),
            role: .modifier,
            help: OmniCommandHelp(
                token: facet.prefix,
                kind: filterKindLine,
                body: facetHelp[facet] ?? "",
                usage: top.isEmpty ? ["Values appear once the docs index has loaded"] : [top.joined(separator: " · ")]
            )
        )
    }

    static func valueItem(facet: FindFacet, value: FindFacetValue) -> OmniCompletionItem {
        let text = facet.prefix + value.value
        let documents = value.count == 1 ? "1 document" : "\(count(value.count)) documents"
        return OmniCompletionItem(
            choice: OmniReferenceChoice(id: text, canonicalText: text, label: documents),
            role: .modifier,
            help: OmniCommandHelp(token: text, kind: filterKindLine, body: documents, usage: [])
        )
    }

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_GB")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Tab after `/find ` (or after a finished filter): opens the facet list.
    @discardableResult
    func openFindFacets() -> Bool {
        guard mode == .composing, editor.isEditable, !editor.hasMarkedText() else { return false }
        var source = editor.string as NSString
        var caret = min(editor.selectedRange().location, source.length)
        // Right after the `/find` token itself (`/fi` Tab completes it with
        // no space): the space, then the facets.
        if let word = source.substring(to: caret).split(whereSeparator: \.isWhitespace).last,
           ["/find", "/retrieve"].contains(String(word)), source.substring(to: caret).hasSuffix(String(word)),
           parser.parse(editor.string).dispatchToken == "/find" {
            replace(NSRange(location: caret, length: 0), with: " ")
            caret += 1
            editor.setSelectedRange(NSRange(location: caret, length: 0))
            source = editor.string as NSString
        }
        let before = source.substring(to: caret)
        guard before.last?.isWhitespace == true, isInFindPayload() else { return false }
        completionItems = findFacetItems()
        completionIndex = 0
        renderFooter()
        showCompletionMenu()
        return true
    }

    /// Inserts a picked facet or value. A facet keeps the menu open on its
    /// values; a value ends with a space, ready for the next word.
    func acceptFindCompletion(_ text: String) {
        let source = editor.string as NSString
        let caret = min(editor.selectedRange().location, source.length)
        let before = source.substring(to: caret)
        let isFacet = FindFacet.allCases.contains { $0.prefix == text }
        let insertion = isFacet ? text : text + " "
        // The word at the caret is replaced; after a space the pick is inserted.
        var target = NSRange(location: caret, length: 0)
        if let last = before.last, !last.isWhitespace, let atom = before.split(whereSeparator: \.isWhitespace).last {
            let found = source.range(of: String(atom), options: .backwards, range: NSRange(location: 0, length: caret))
            if found.location != NSNotFound { target = found }
        }
        replace(target, with: insertion)
        editor.setSelectedRange(NSRange(location: target.location + (insertion as NSString).length, length: 0))
        if isFacet {
            // The facet's values, at once (D2: picking a facet lists its values).
            refreshCompletionItemsForFind()
        } else {
            dismissCompletion()
        }
    }

    func refreshCompletionItemsForFind() {
        let source = editor.string as NSString
        let caret = min(editor.selectedRange().location, source.length)
        let before = source.substring(to: caret)
        guard let atom = before.split(whereSeparator: \.isWhitespace).last, let items = findCompletionItems(for: String(atom)), !items.isEmpty else {
            dismissCompletion()
            return
        }
        completionItems = items
        completionIndex = 0
        renderFooter()
        showCompletionMenu()
    }
}
