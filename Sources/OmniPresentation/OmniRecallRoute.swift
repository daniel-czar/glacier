import Foundation

/// Pad-local tool entry. The tail is literal intent, including slash words.
public enum OmniRecallRoute {
    public static let token = "/recall"

    public static func intent(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        guard input.hasPrefix(token) else { return nil }
        let tail = input.dropFirst(token.count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
