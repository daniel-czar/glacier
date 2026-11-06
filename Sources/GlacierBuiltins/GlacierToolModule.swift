import Foundation
import GlacierModuleKit
import OmniPresentation

/// Only text explicitly supplied to this invocation. The host decides whether
/// a captured selection is approved; modules receive no filesystem or provider.
public struct GlacierToolInput: Sendable, Equatable {
    public let text: String
    public let approvedSelection: String?

    public init(text: String, approvedSelection: String? = nil) {
        self.text = text
        self.approvedSelection = approvedSelection
    }
}

public enum GlacierToolError: Error, Equatable, Sendable {
    case invalidDescriptor(String)
    case inputTooLong
    case outputTooLong
}

/// A compiled ephemeral module. Implementations do not need a host routing case.
public protocol GlacierToolModule: Sendable {
    var descriptor: ModuleDescriptor { get }
    var presentation: OmniEphemeralToolDescriptor { get }
    func run(input: GlacierToolInput) async throws -> String
}

/// Keeps the public registration list heterogeneous without an unstable binary plugin ABI.
public struct AnyGlacierToolModule: Sendable {
    public let descriptor: ModuleDescriptor
    public let presentation: OmniEphemeralToolDescriptor
    private let execute: @Sendable (GlacierToolInput) async throws -> String

    public init<M: GlacierToolModule>(_ module: M) {
        descriptor = module.descriptor
        presentation = module.presentation
        execute = { input in try await module.run(input: input) }
    }

    public func run(input: GlacierToolInput) async throws -> String {
        try Task.checkCancellation()
        guard input.text.count <= presentation.maximumInputCharacters else {
            throw GlacierToolError.inputTooLong
        }
        let result = try await execute(input)
        try Task.checkCancellation()
        guard result.count <= presentation.maximumOutputCharacters else {
            throw GlacierToolError.outputTooLong
        }
        return result
    }

    /// Adapter for the existing disposable tool session. The complete return
    /// value is authoritative; a local transform need not stream deltas.
    public func makeProducer(approvedSelection: String? = nil) -> OmniEphemeralProducer {
        { text, _ in try await run(input: .init(text: text, approvedSelection: approvedSelection)) }
    }
}
