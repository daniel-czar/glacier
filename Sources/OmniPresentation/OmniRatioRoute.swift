import Foundation

/// Pad-local tool entry (C117). The tail is the Ratio field: `/ratio 16:9`.
public enum OmniRatioRoute {
    public static let token = "/ratio"

    public static func query(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        guard input.hasPrefix(token) else { return nil }
        let tail = input.dropFirst(token.count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
