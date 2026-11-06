import Foundation

/// Pad-local entry to the shared host's clipboard history picker. The tail is
/// literal search text; it is never parsed as another Omni command.
public enum OmniClipboardRoute {
    public static let tokens = ["/cl", "/clipboard"]

    /// Returns an empty query for a bare route and nil for other input.
    public static func query(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        for token in tokens {
            guard input.hasPrefix(token) else { continue }
            let tail = input.dropFirst(token.count)
            guard tail.isEmpty || tail.first?.isWhitespace == true else { continue }
            return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
