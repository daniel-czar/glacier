import Foundation
import OmniPresentation

public struct GlacierPronunciationPaths: Sendable {
    public let bundleRoot: URL
    public let pythonExecutable: URL
    public let supportDirectory: URL
    public let cacheDirectory: URL
    public let configFile: URL

    public init(bundleRoot: URL, supportDirectory: URL) {
        self.bundleRoot = bundleRoot
        pythonExecutable = bundleRoot.appendingPathComponent("runtime/bin/python3")
        self.supportDirectory = supportDirectory
        cacheDirectory = supportDirectory.appendingPathComponent("cache", isDirectory: true)
        configFile = supportDirectory.appendingPathComponent("config.toml")
    }

    /// No PATH, Homebrew, uv home, sibling repository or user-specific folder
    /// is consulted. The interpreter must resolve inside the app's bundle.
    public func prepare() throws -> URL {
        guard bundleRoot.isFileURL, supportDirectory.isFileURL,
              Self.contains(bundleRoot.resolvingSymlinksInPath(),
                            pythonExecutable.resolvingSymlinksInPath()),
              FileManager.default.isExecutableFile(atPath: pythonExecutable.path),
              Self.contains(supportDirectory, cacheDirectory),
              Self.contains(supportDirectory, configFile) else {
            throw EphemeralToolFailure("The bundled pronunciation runtime is unavailable.")
        }
        do {
            for url in [supportDirectory, cacheDirectory, configFile] {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    throw EphemeralToolFailure("Pronunciation support paths cannot be symlinks.")
                }
            }
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: configFile.path) {
                guard FileManager.default.createFile(atPath: configFile.path, contents: Data(),
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw EphemeralToolFailure("The pronunciation configuration could not be created.")
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        } catch let failure as EphemeralToolFailure { throw failure }
        catch { throw EphemeralToolFailure("The pronunciation support directory is unavailable.") }
        return pythonExecutable
    }

    private static func contains(_ root: URL, _ child: URL) -> Bool {
        let rootPath = root.standardizedFileURL.pathComponents
        let childPath = child.standardizedFileURL.pathComponents
        return childPath.count > rootPath.count && childPath.starts(with: rootPath)
    }
}
