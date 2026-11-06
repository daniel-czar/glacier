import Foundation

/// A pad-local entry to the native pronunciation panel. The term is material,
/// so slash-looking words after `/pron` are never parsed as Omni commands.
public enum OmniPronunciationRoute {
    public static let token = "/pron"

    /// Returns an empty string for bare `/pron`, and nil for every other route.
    /// Command spelling follows the manifest's exact, lowercase token policy.
    public static func term(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        guard input.hasPrefix(token) else { return nil }
        let tail = input.dropFirst(token.count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
