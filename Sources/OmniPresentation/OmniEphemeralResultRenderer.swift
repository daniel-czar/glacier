import AppKit

/// Presentation only: the session retains the original full result for copying.
/// The existing Concept Lens producer emits PRIMARY/Name/Definition, NEAR MISSES
/// and MAP. Recognize those headings without imposing a new transport schema.
@MainActor
public enum OmniEphemeralResultRenderer {
    public static func attributed(_ text: String, style: OmniEphemeralResultStyle) -> NSAttributedString {
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: OmniFrostedStyle.ink,
            .paragraphStyle: body
        ]
        let result = NSMutableAttributedString(string: "")
        var lastSection: String?
        for line in text.components(separatedBy: "\n") {
            if style == .structured, let section = sectionLine(line) {
                if section.title != lastSection || !section.value.isEmpty && section.title != "BEST NAME" {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.paragraphSpacingBefore = result.length == 0 ? 0 : 10
                    paragraph.paragraphSpacing = 4
                    result.append(NSAttributedString(string: section.title + "\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: OmniFrostedStyle.secondaryInk,
                        .kern: 0.5, .paragraphStyle: paragraph
                    ]))
                }
                lastSection = section.title
                if !section.value.isEmpty {
                    result.append(inline(section.value + "\n", attributes: attributes))
                }
            } else {
                result.append(inline(line + "\n", attributes: attributes))
            }
        }
        if result.length > 0 { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    private static func sectionLine(_ line: String) -> (title: String, value: String)? {
        var candidate = line.trimmingCharacters(in: .whitespaces)
        while candidate.hasPrefix("#") { candidate.removeFirst() }
        candidate = candidate.trimmingCharacters(in: .whitespaces)
        if candidate.hasPrefix("- ") || candidate.hasPrefix("* ") { candidate.removeFirst(2) }
        candidate = candidate.replacingOccurrences(of: "**", with: "")
        let parts = candidate.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts.first ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        let title: String
        switch key {
        case "PRIMARY", "BEST NAME", "NAME": title = "BEST NAME"
        case "DEFINITION": title = "DEFINITION"
        case "NEAR MISSES": title = "NEAR MISSES"
        case "MAP": title = "MAP"
        default: return nil
        }
        return (title, parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "")
    }

    private static func inline(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let rendered = NSMutableAttributedString(string: text, attributes: attributes)
        guard let expression = try? NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#) else { return rendered }
        let source = text as NSString
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let value = source.substring(with: match.range(at: 1))
            rendered.replaceCharacters(in: match.range, with: value)
            rendered.addAttribute(.font, value: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                  range: NSRange(location: match.range.location, length: (value as NSString).length))
        }
        return rendered
    }
}
