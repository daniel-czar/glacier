import Foundation

/// Pad-local Characters entry. The tail is literal search or Identify input.
public enum OmniCharactersRoute {
    public static let token = "/char"

    public static func query(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        guard input.hasPrefix(token) else { return nil }
        let tail = input.dropFirst(token.count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
