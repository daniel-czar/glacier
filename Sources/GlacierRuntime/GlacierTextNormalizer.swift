import Foundation

/// Portable equivalent of the original path-wrap normalizer; never reads or writes a clipboard itself.
public enum GlacierTextNormalizer {
    private static func match(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static func replace(_ pattern: String, _ text: String, _ replacement: String) -> String { text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
    private static func body(_ text: String) -> String { replace(#"^\s*(?:[-*]\s+|\d+[.)]\s+)"#, text, "").trimmingCharacters(in: .whitespaces) }
    private static func pathish(_ text: String) -> Bool {
        let value = body(text)
        guard !value.hasPrefix("http://"), !value.hasPrefix("https://") else { return false }
        return match(#"^(?:/|~/|\./|\.\./)"#, value) || (value.contains("/") && !match(#"\s"#, value))
    }
    private static func join(_ previous: String, _ current: String) -> Bool {
        let text = current.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !previous.hasSuffix("\\"), pathish(previous),
              !match(#"^\s*(?:[-*]\s+|\d+[.)]\s+)"#, current),
              !["--", "|", "&&", "||", "#", ">", "```"].contains(where: text.hasPrefix),
              match(#"^[A-Za-z0-9._~@%+=:,/-]+(?::\d+)?$"#, text),
              text.contains(where: { "/._-".contains($0) }) else { return false }
        let old = body(previous)
        let segment = old.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last.map(String.init) ?? old
        return match(#"^[ \t]{2,}\S"#, current) || ["/", "-", "_", "."].contains(where: old.hasSuffix)
            || match(#"\.[A-Za-z0-9]{1,12}(?::\d+)?$"#, text)
            || (segment.contains(where: { "_-".contains($0) }) && text.contains(where: { "_-".contains($0) }))
    }
    public static func normalize(_ input: String) -> String {
        let text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let trailing = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n"); if trailing { lines.removeLast() }
        var output: [String] = []
        for raw in lines {
            let line = replace(#"\s+$"#, raw, "")
            if let last = output.last, join(last, line) { output[output.count - 1] += line.trimmingCharacters(in: .whitespaces) }
            else { output.append(line) }
        }
        output = output.map { line in pathish(line) && match(#"^(?:[-*]\s+|\d+[.)]\s+)?(?:/|~/|\./|\.\./)"#, line.trimmingCharacters(in: .whitespaces)) ? replace(#"(?<=\S)[ \t]{2,}(?=\S)"#, line, "") : line }
        return output.joined(separator: "\n") + (trailing ? "\n" : "")
    }
}
