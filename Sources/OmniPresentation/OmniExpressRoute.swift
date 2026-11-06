import Foundation

/// Pad-local Express route. Everything after the leading token is literal input.
public enum OmniExpressRoute {
    public static let token = "/express"

    public static func text(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        guard input.hasPrefix(token) else { return nil }
        let tail = input.dropFirst(token.count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
