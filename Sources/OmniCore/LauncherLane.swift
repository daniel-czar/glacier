import Foundation

/// The curated launcher and the widened file search have distinct indexes.
public enum LauncherLane: String, Codable, Sendable, Equatable {
    case curated
    case everywhere
}
