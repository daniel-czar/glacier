import Foundation

/// Pad-local Regex entry. The first separator belongs to the route; the
/// remaining characters are literal input, including backslashes and spaces.
public enum OmniRegexRoute {
    public static let token = "/regex"

    public static func input(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        guard input.hasPrefix(token) else { return nil }
        let tail = input.dropFirst(token.count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return tail.isEmpty ? "" : String(tail.dropFirst())
    }
}
