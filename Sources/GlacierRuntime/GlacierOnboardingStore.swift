import Darwin
import Foundation

/// Navigation state only. Preferences and credentials remain in their existing stores.
public struct GlacierOnboardingState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var currentStep: GlacierOnboardingStep
    public var completed: Bool

    public init(currentStep: GlacierOnboardingStep = .welcome, completed: Bool = false) {
        self.schemaVersion = Self.currentSchemaVersion
        self.currentStep = currentStep
        self.completed = completed
    }
}

public enum GlacierOnboardingStoreError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalidStateFile
    case ioFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Onboarding state version \(version) is not supported."
        case .invalidStateFile: "Onboarding state is not a regular file."
        case .ioFailure(let code): "Onboarding state could not be saved (system error \(code))."
        }
    }
}

/// Separate, private, atomic file so a resumed wizard cannot overwrite settings.
public struct GlacierOnboardingStore: Sendable {
    public let url: URL

    public init(supportDirectory: URL) {
        self.url = supportDirectory.appendingPathComponent("onboarding.json")
    }

    public init(url: URL) { self.url = url }

    public func load() throws -> GlacierOnboardingState? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw GlacierOnboardingStoreError.ioFailure(errno)
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw GlacierOnboardingStoreError.invalidStateFile
        }
        let state = try JSONDecoder().decode(GlacierOnboardingState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == GlacierOnboardingState.currentSchemaVersion else {
            throw GlacierOnboardingStoreError.unsupportedVersion(state.schemaVersion)
        }
        return state
    }

    /// Existing installations without a state file skip automatic onboarding.
    public func shouldPresent(settingsExists: Bool) throws -> Bool {
        if let state = try load() { return !state.completed }
        return !settingsExists
    }

    public func save(_ state: GlacierOnboardingState) throws {
        guard state.schemaVersion == GlacierOnboardingState.currentSchemaVersion else {
            throw GlacierOnboardingStoreError.unsupportedVersion(state.schemaVersion)
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var existing = stat()
        if lstat(url.path, &existing) == 0,
           (existing.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG) {
            throw GlacierOnboardingStoreError.invalidStateFile
        }
        let data = try JSONEncoder().encode(state)
        var template = Array(directory.appendingPathComponent(".onboarding-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw GlacierOnboardingStoreError.ioFailure(errno) }
        let temporaryPath = String(cString: template)
        defer { close(descriptor); unlink(temporaryPath) }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw GlacierOnboardingStoreError.ioFailure(errno)
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw GlacierOnboardingStoreError.ioFailure(errno) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw GlacierOnboardingStoreError.ioFailure(errno) }
        guard rename(temporaryPath, url.path) == 0 else {
            throw GlacierOnboardingStoreError.ioFailure(errno)
        }
    }
}
