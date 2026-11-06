import Foundation

/// A recipient-free draft that can be handed to a destination application's
/// composer. Omni never supplies a send action or a recipient address.
public enum ComposerChannel: String, Codable, Sendable, Equatable {
    case email
    case message
}

public struct ComposerDraft: Codable, Sendable, Equatable {
    public let channel: ComposerChannel
    public let subject: String?
    public let body: String

    public init(channel: ComposerChannel, subject: String? = nil, body: String) {
        self.channel = channel
        self.subject = subject
        self.body = body
    }
}
