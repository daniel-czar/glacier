import Foundation

/// Pad-local Weather entry. Everything after `/weather` is a literal place.
public enum OmniWeatherRoute {
    public static let token = "/weather"

    public static func query(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        guard input.hasPrefix(token) else { return nil }
        let tail = input.dropFirst(token.count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
