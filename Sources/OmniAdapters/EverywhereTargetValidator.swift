import Foundation
import OmniCore

/// Cheap open-time recheck of a published row. No scan or content reads.
struct EverywhereTargetValidator {
    let configuration: EverywhereSourceConfiguration

    struct DirectoryFlags {
        let optedOut: Bool
        let linkedWorktree: Bool
        let package: Bool
    }

    func admits(_ candidate: LauncherCandidate) -> Bool {
        var cache: [String: DirectoryFlags] = [:]
        return admits(candidate, cache: &cache)
    }

    func admits(_ candidate: LauncherCandidate, cache: inout [String: DirectoryFlags]) -> Bool {
        // Applications enter through the curated half of the widened union.
        if candidate.source == .apps { return true }
        let home = configuration.home.path
        let path = candidate.path
        let cloud = configuration.iCloudRoots.first { path == $0.path || path.hasPrefix($0.path + "/") }
        guard cloud != nil || path.hasPrefix(home + "/") else { return false }
        let anchor = cloud?.path ?? home
        let parts = path.dropFirst(anchor.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first else { return false }
        if cloud == nil && first == "Library" { return false }
        let output = home + "/Tooling/agent-output"
        let inOutput = path.hasPrefix(output + "/")
        if inOutput {
            let run = path.dropFirst(output.count + 1).split(separator: "/").first.map(String.init)
            guard let run, EverywhereScope.isRunFolder(run) else { return false }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        let area: EverywhereScope.Area = cloud != nil ? .iCloud : (parts.count == 1 ? .homeRoot : .topLevel(first))
        if !isDirectory.boolValue, !inOutput,
           EverywhereScope.fileClass(name: candidate.basename, area: area, downloadsMediaEnabled: configuration.downloadsMediaEnabled) == nil { return false }
        if !isDirectory.boolValue, inOutput,
           !EverywhereScope.documentExtensions.contains((path as NSString).pathExtension.lowercased()) { return false }
        let directoryParts = isDirectory.boolValue ? parts : Array(parts.dropLast())
        var directory = URL(fileURLWithPath: anchor, isDirectory: true)
        var ancestor = directory
        while ancestor.path == home || ancestor.path.hasPrefix(home + "/") {
            let flags = flags(ancestor, cache: &cache)
            if flags.optedOut || flags.linkedWorktree || flags.package { return false }
            if ancestor.path == home { break }
            ancestor.deleteLastPathComponent()
        }
        for (offset, name) in directoryParts.enumerated() {
            directory.appendPathComponent(name, isDirectory: true)
            if directory.path != output, EverywhereScope.prunesDirectory(name) { return false }
            let flags = flags(directory, cache: &cache)
            if flags.optedOut || flags.linkedWorktree { return false }
            if flags.package {
                let opaqueDocument = isDirectory.boolValue && offset == directoryParts.count - 1
                    && (EverywhereScope.documentExtensions.contains(directory.pathExtension.lowercased())
                        || EverywhereScope.revealExtensions.contains(directory.pathExtension.lowercased()))
                if !opaqueDocument { return false }
            }
        }
        return true
    }

    private func hasOptOut(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(LauncherPathRules.noLaunchMarker).path)
    }

    private func flags(_ directory: URL, cache: inout [String: DirectoryFlags]) -> DirectoryFlags {
        if let flags = cache[directory.path] { return flags }
        let git = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        let linked = FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        let value = DirectoryFlags(optedOut: hasOptOut(directory), linkedWorktree: linked,
                                   package: (try? directory.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true)
        cache[directory.path] = value
        return value
    }
}

/// Curated metadata remains authoritative, while stale cached filesystem
/// rows cannot bypass C72 opt-outs, removals or worktree/package exclusions.
/// Rechecks happen during background publication, never per keystroke.
public struct EverywhereUnionFilter: Sendable {
    private let configuration: EverywhereSourceConfiguration
    public init(configuration: EverywhereSourceConfiguration) { self.configuration = configuration }
    public func filter(_ curated: [LauncherCandidate]) -> [LauncherCandidate] {
        let validator = EverywhereTargetValidator(configuration: configuration)
        var cache: [String: EverywhereTargetValidator.DirectoryFlags] = [:]
        return curated.filter { validator.admits($0, cache: &cache) }
    }
}
