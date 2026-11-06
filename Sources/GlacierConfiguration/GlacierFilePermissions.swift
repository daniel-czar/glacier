import Darwin
import Foundation

/// Tightens only app-owned state paths. Descriptor operations never follow a final symlink.
public enum GlacierFilePermissions {
    public static func ensurePrivateDirectory(at url: URL) throws {
        guard url.isFileURL else { throw GlacierConfigurationError.invalidPath(url.absoluteString) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func ensurePrivateFile(at url: URL) throws {
        guard url.isFileURL else { throw GlacierConfigurationError.invalidPath(url.absoluteString) }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        var state = stat()
        guard fstat(descriptor, &state) == 0, (state.st_mode & S_IFMT) == S_IFREG else {
            throw GlacierConfigurationError.invalidPath(url.path)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
