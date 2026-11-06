import Foundation

/// Serializes in-process edits and writes an atomic JSON replacement before publishing a snapshot.
public actor GlacierSettingsStore {
    public let url: URL
    private var settings: GlacierSettings

    public init(paths: GlacierPaths) throws {
        self.url = paths.settings
        try GlacierFilePermissions.ensurePrivateDirectory(at: paths.support)
        try Self.rejectSymlink(at: paths.settings)
        if FileManager.default.fileExists(atPath: paths.settings.path) {
            try GlacierFilePermissions.ensurePrivateFile(at: paths.settings)
            self.settings = try JSONDecoder().decode(GlacierSettings.self, from: Data(contentsOf: paths.settings))
        } else {
            self.settings = GlacierSettings()
        }
    }

    public func snapshot() -> GlacierSettings { settings }

    /// The transform is synchronous: actor isolation cannot be suspended between read and write.
    /// A failed validation or disk write leaves the in-memory snapshot untouched.
    @discardableResult
    public func update(authorizeCommit: @Sendable () throws -> Void = {},
                       _ transform: @Sendable (inout GlacierSettings) throws -> Void) throws -> GlacierSettings {
        var candidate = settings
        try transform(&candidate)
        try candidate.validate()
        try Self.rejectSymlink(at: url)
        let data = try JSONEncoder.glacierEncoder.encode(candidate)
        // This check is the commit boundary. Once it returns, the synchronous
        // atomic replacement finishes even if its originating UI is dismissed.
        try authorizeCommit()
        try GlacierFilePermissions.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try GlacierFilePermissions.ensurePrivateFile(at: url)
        settings = candidate
        return candidate
    }

    private static func rejectSymlink(at url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw GlacierConfigurationError.invalidPath(url.path)
        }
    }
}

private extension JSONEncoder {
    static var glacierEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
