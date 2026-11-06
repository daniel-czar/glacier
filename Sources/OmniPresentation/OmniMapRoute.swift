import Foundation

/// Pad-local Map entry. Everything after `/map` is literal question material.
public enum OmniMapRoute {
    public static let token = "/map"

    public static func query(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        guard input.hasPrefix(token) else { return nil }
        let tail = input.dropFirst(token.count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
