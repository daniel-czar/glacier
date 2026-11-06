import Foundation

/// Pad-local QR entry. The first separator after `/qr` belongs to the route;
/// every following character belongs to the payload, including whitespace.
public enum OmniQRRoute {
    public static let token = "/qr"

    public static func payload(in text: String) -> String? {
        let input = text.drop(while: \.isWhitespace)
        guard input.hasPrefix(token) else { return nil }
        let tail = input.dropFirst(token.count)
        guard tail.isEmpty || tail.first?.isWhitespace == true else { return nil }
        return tail.isEmpty ? "" : String(tail.dropFirst())
    }
}
