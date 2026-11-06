import Foundation

/// A bare 16-hex id is an address, not a query (D1, decision surface
/// 569d5a7cf925cbd7, amended by the steering session 2026-10-10): exactly 16
/// hex characters in either case (stored lowercase), optionally prefixed
/// `doc:` or `run:` (either case), with surrounding whitespace, control and
/// format characters (zero-width spaces, a BOM, direction marks), quotes,
/// backticks, brackets and trailing punctuation ignored. 15- or 17-character
/// strings are ordinary text. Nothing that parses as an address
/// may ever reach a model, hit or miss; the launcher lookup, `/find` tier 1
/// and the service's Tier 2 guard all parse with this one normaliser.
public struct OmniIDAddress: Sendable, Equatable, Hashable {
    public enum Namespace: String, Sendable, Equatable, Hashable {
        case doc
        case run
    }

    public static let length = 16

    public let namespace: Namespace?
    public let id: String

    /// What a copied or quoted id carries around it: whitespace, control and
    /// format characters (zero-width spaces, a BOM, direction marks), quotes,
    /// backticks, brackets and sentence punctuation.
    static let ignorable = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}`'\"“”‘’()[]{}<>.,;!?"))

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: Self.ignorable).lowercased()
        var namespace: Namespace?
        var body = Substring(trimmed)
        for candidate in [Namespace.doc, .run] where trimmed.hasPrefix(candidate.rawValue + ":") {
            namespace = candidate
            body = trimmed.dropFirst(candidate.rawValue.count + 1)
        }
        guard Self.isExactID(body) else { return nil }
        self.namespace = namespace
        self.id = String(body)
    }

    /// Exactly 16 characters of `0-9a-f`.
    public static func isExactID<S: StringProtocol>(_ value: S) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The id a file carries in its name by the filename ADR
    /// (`<title>_<16-hex>.<ext>`): split on the last `_`, exactly 16 lowercase
    /// hex characters, then an extension. Basename only; nothing is read.
    public static func filenameID(_ basename: String) -> String? {
        let ns = basename as NSString
        let ext = ns.pathExtension
        guard !ext.isEmpty else { return nil }
        let stem = ns.deletingPathExtension
        guard let separator = stem.lastIndex(of: "_"), separator > stem.startIndex else { return nil }
        let suffix = stem[stem.index(after: separator)...]
        return isExactID(suffix) ? String(suffix) : nil
    }

    /// The id a run folder carries as its name prefix (`<16-hex>_<slug>`),
    /// lowercase only, like every other address.
    public static func runFolderID(_ name: String) -> String? {
        guard let separator = name.firstIndex(of: "_") else { return nil }
        let prefix = name[..<separator]
        guard isExactID(prefix), name.index(after: separator) < name.endIndex else { return nil }
        return String(prefix)
    }
}
