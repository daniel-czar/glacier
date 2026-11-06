import Foundation
import OmniCore

/// The prompt for `/find` in words (D2, tier 3). It carries the facet
/// vocabulary (kinds, project names, common tags) so the model maps words
/// to real values, the person's typed filters as constraints, and their
/// words. It never carries a result row: the model writes the query and the
/// local index answers it.
public enum FindQueryPrompt {
    /// Vocabulary caps (agent-owned): enough to map ordinary words, small
    /// enough to keep the prompt short.
    public static let kindCap = 40
    public static let projectCap = 40
    public static let tagCap = 80
    public static let termCap = 2

    public static func prompt(typed: FindQuery, facets: FindFacets) -> String {
        func list(_ values: [FindFacetValue], cap: Int) -> String {
            let names = values.prefix(cap).map(\.value)
            return names.isEmpty ? "(none)" : names.joined(separator: ", ")
        }
        var lines = [
            "Turn a request for documents into a search query over the user's own notes index. You do not search and you will not see what the query finds: you only write the query.",
            "",
            "The best results match every filter and every term, so each one you add narrows them. Write the smallest query that still says what the request asks for.",
            "",
            "The query has two parts:",
            "- filters: space-separated words of the form kind:<value>, in:<project> or tags:<tag>. Use the fewest the request clearly names: usually one, at most two. kind: takes a value from Kinds only, in: a value from Projects only, tags: a value from Tags only, written exactly as listed; never move a value to another key, and leave a filter out when no listed value fits.",
            "- terms: at most \(termCap) distinctive lowercase words a matching title or summary would contain, in their singular form (review, not reviews). Leave out what a filter already covers and generic words (document, note, something, about). Leave terms empty when the filters say it all.",
            "",
            "Kinds: " + list(facets.kinds, cap: kindCap),
            "Projects (for in:): " + list(facets.projects, cap: projectCap),
            "Tags: " + list(facets.tags, cap: tagCap),
        ]
        if !typed.filters.isEmpty {
            let keys = Array(Set(typed.filters.map(\.facet))).sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)
            lines.append("")
            lines.append("Already chosen by the user and kept as they are: " + typed.filters.map(\.text).joined(separator: " ") + ". Do not add another filter on " + keys.joined(separator: " or ") + ".")
        }
        lines.append("")
        lines.append(ModelOutputDiscipline.findQuery)
        lines.append("")
        lines.append("Request: " + typed.terms.joined(separator: " "))
        return lines.joined(separator: "\n")
    }
}
