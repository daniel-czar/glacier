import Foundation

public struct OmniDevelopmentRoot: Sendable, Equatable {
    public let url: URL

    public init(validating candidate: URL, allowedRoot: URL, forbiddenRoots: [URL] = []) throws {
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw OmniRunError.developmentRootMustBeAbsolute
        }
        guard allowedRoot.isFileURL, allowedRoot.path.hasPrefix("/") else {
            throw OmniRunError.developmentRootMustBeAbsolute
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: candidate.path) else { throw OmniRunError.developmentRootMissing }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OmniRunError.developmentRootNotDirectory
        }
        let standardized = candidate.standardizedFileURL.path
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let allowedStandardized = allowedRoot.standardizedFileURL.path
        let allowedResolved = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard standardized == resolved, allowedStandardized == allowedResolved else { throw OmniRunError.developmentRootIsSymlink }
        guard standardized == allowedStandardized || standardized.hasPrefix(allowedStandardized + "/") else {
            throw OmniRunError.pathEscapesDevelopmentRoot
        }
        let forbidden = forbiddenRoots.map { $0.standardizedFileURL.path }
        guard !forbidden.contains(where: { standardized == $0 || standardized.hasPrefix($0 + "/") }) else {
            throw OmniRunError.forbiddenDevelopmentRoot(standardized)
        }
        url = URL(fileURLWithPath: standardized, isDirectory: true)
    }

    public func containedURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw OmniRunError.pathEscapesDevelopmentRoot
        }
        let candidate = url.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = url.resolvingSymlinksInPath().standardizedFileURL
        guard (candidate.path == url.path || candidate.path.hasPrefix(url.path + "/")),
              (resolvedParent.path == resolvedRoot.path || resolvedParent.path.hasPrefix(resolvedRoot.path + "/")),
              (resolvedCandidate.path == resolvedRoot.path || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")) else {
            throw OmniRunError.pathEscapesDevelopmentRoot
        }
        return candidate
    }
}
