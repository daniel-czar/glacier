import AppKit
import OmniCore
import UniformTypeIdentifiers

/// Where a run's material came from, in Apple's provenance grammar (D3,
/// decision surface 569d5a7cf925cbd7): a preposition, the app's icon and
/// name, and the window title in quotes only when it says something the app
/// name does not. One formatter feeds the workspace header, the pad's chip
/// and the notification line, so the surfaces cannot drift.
public struct OmniProvenanceLine: Sendable, Equatable {
    public static let preposition = "From"

    /// The source app's name, or nil when capture could not name it.
    public let appName: String?
    /// The window title, kept only when non-empty and different from the app
    /// name (`Claude · Claude` was the bug this grammar replaces).
    public let windowTitle: String?
    /// Drives the icon; nil on records written before it was captured.
    public let bundleIdentifier: String?

    /// Nil when there is nothing to say: no app name and no distinct title.
    public init?(appName: String?, windowTitle: String?, bundleIdentifier: String? = nil) {
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keptName = name.flatMap { $0.isEmpty ? nil : $0 }
        var keptTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        if let keptName, let candidate = keptTitle, candidate.caseInsensitiveCompare(keptName) == .orderedSame {
            keptTitle = nil
        }
        guard keptName != nil || keptTitle != nil else { return nil }
        self.appName = keptName
        self.windowTitle = keptTitle
        let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleIdentifier = identifier.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `Mail “Re: invoice”`: the source without the preposition.
    public var source: String {
        [appName, windowTitle.map(Self.quoted)].compactMap { $0 }.joined(separator: " ")
    }

    /// `From Mail “Re: invoice”`: the plain form, for notifications and
    /// accessibility labels, where no icon can be drawn.
    public var text: String { "\(Self.preposition) \(source)" }

    static func quoted(_ title: String) -> String { "“\(title)”" }

    /// `From <icon> Mail “Re: invoice”`, with the app's icon as an inline
    /// attachment sized to the font. The icon is omitted only when the app
    /// is unnamed (a bare title has no app to draw).
    @MainActor
    public func attributed(
        attributes: [NSAttributedString.Key: Any],
        iconSize: CGFloat,
        compact: Bool = false,
        icons: OmniAppIconResolver = .shared
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: compact ? "" : Self.preposition + " ", attributes: attributes)
        if let appName {
            let attachment = NSTextAttachment()
            attachment.image = icons.icon(bundleIdentifier: bundleIdentifier, appName: appName)
            let font = (attributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            // Centre the icon on the text's x-height rather than its baseline.
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - iconSize) / 2, width: iconSize, height: iconSize)
            let icon = NSMutableAttributedString(attachment: attachment)
            icon.addAttributes(attributes, range: NSRange(location: 0, length: icon.length))
            // The gap between icon and name is kerning, not a space, so the
            // icon reads as part of the name (`From ⌘Claude`).
            icon.addAttribute(.kern, value: iconSize * 0.25, range: NSRange(location: 0, length: icon.length))
            result.append(icon)
            result.append(NSAttributedString(string: appName, attributes: attributes))
            if let windowTitle { result.append(NSAttributedString(string: compact ? " · " + windowTitle : " " + Self.quoted(windowTitle), attributes: attributes)) }
        } else if let windowTitle {
            result.append(NSAttributedString(string: compact ? windowTitle : Self.quoted(windowTitle), attributes: attributes))
        }
        return result
    }
}

/// App icons for provenance, by bundle identifier, then by name, then a
/// generic document icon. Lookups are cached per key: the header redraws on
/// every results poll and `NSWorkspace` lookups touch Launch Services.
@MainActor
public final class OmniAppIconResolver {
    public static let shared = OmniAppIconResolver()

    /// Which lookup produced an icon; exposed for tests.
    public enum Source: Equatable, Sendable {
        case bundleIdentifier(String)
        case appName(String)
        case generic
    }

    private let applicationURLForBundleIdentifier: @MainActor (String) -> URL?
    private let applicationURLForName: @MainActor (String) -> URL?
    private let iconForFile: @MainActor (String) -> NSImage
    private let genericIcon: @MainActor () -> NSImage
    private var cache: [String: (source: Source, image: NSImage)] = [:]

    public init(
        applicationURLForBundleIdentifier: @escaping @MainActor (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        applicationURLForName: @escaping @MainActor (String) -> URL? = { OmniAppIconResolver.applicationURL(named: $0) },
        iconForFile: @escaping @MainActor (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) },
        genericIcon: @escaping @MainActor () -> NSImage = { NSWorkspace.shared.icon(for: .data) }
    ) {
        self.applicationURLForBundleIdentifier = applicationURLForBundleIdentifier
        self.applicationURLForName = applicationURLForName
        self.iconForFile = iconForFile
        self.genericIcon = genericIcon
    }

    public func icon(bundleIdentifier: String?, appName: String?) -> NSImage {
        resolve(bundleIdentifier: bundleIdentifier, appName: appName).image
    }

    public func source(bundleIdentifier: String?, appName: String?) -> Source {
        resolve(bundleIdentifier: bundleIdentifier, appName: appName).source
    }

    private func resolve(bundleIdentifier: String?, appName: String?) -> (source: Source, image: NSImage) {
        let key = "\(bundleIdentifier ?? "")|\(appName ?? "")"
        if let cached = cache[key] { return cached }
        let resolved: (source: Source, image: NSImage)
        if let bundleIdentifier, let url = applicationURLForBundleIdentifier(bundleIdentifier) {
            resolved = (.bundleIdentifier(bundleIdentifier), iconForFile(url.path))
        } else if let appName, let url = applicationURLForName(appName) {
            resolved = (.appName(appName), iconForFile(url.path))
        } else {
            resolved = (.generic, genericIcon())
        }
        cache[key] = resolved
        return resolved
    }

    /// Name fallback for records captured before the bundle identifier was:
    /// a running app with that localized name, else the standard
    /// application folders. Never searches the disk beyond them.
    public static func applicationURL(named name: String) -> URL? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let url = running.bundleURL {
            return url
        }
        let folders = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            OmniLayout.homeDirectory.appendingPathComponent("Applications").path,
        ]
        for folder in folders {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
