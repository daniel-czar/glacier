import Foundation

public enum OmniCaptureDestination: String, Sendable, Equatable {
    case note
    case link

    public var routeTitle: String {
        switch self {
        case .note: "Note → Base/captures"
        case .link: "Link → Base/triage"
        }
    }

    public var dispatchToken: String {
        switch self {
        case .note: "/capture"
        case .link: "/fav"
        }
    }
}

/// A whole-input URL is a link; all other nonblank material is preserved as a note.
/// Classification is local and deterministic. It never reads network metadata.
public struct OmniCaptureRequest: Sendable, Equatable {
    public let destination: OmniCaptureDestination
    public let payload: String

    private init(destination: OmniCaptureDestination, payload: String) {
        self.destination = destination
        self.payload = payload
    }

    public static func classify(_ input: String) -> OmniCaptureRequest? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = normalizedURL(trimmed) {
            return OmniCaptureRequest(destination: .link, payload: url)
        }
        return OmniCaptureRequest(destination: .note, payload: input)
    }

    private static func normalizedURL(_ value: String) -> String? {
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        let candidate: String
        if value.lowercased().hasPrefix("www.") {
            candidate = "https://" + value
        } else {
            candidate = value
        }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.url != nil
        else { return nil }
        if value.lowercased().hasPrefix("www."),
           (host.hasSuffix(".") || host.split(separator: ".").count < 2) { return nil }
        return candidate
    }
}
