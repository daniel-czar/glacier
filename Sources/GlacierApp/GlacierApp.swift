import AppKit
import Darwin
import Foundation
import GlacierRuntime

@main
struct GlacierApp {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 3, args[0] == "--headless-check", args[1] == "--test-root", args[2].hasPrefix("/") {
            Task {
                do {
                    let receipt = try await GlacierSmoke.check(root: URL(fileURLWithPath: args[2]))
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    FileHandle.standardOutput.write(try encoder.encode(receipt) + Data([10]))
                    exit(receipt.localCommandSucceeded ? 0 : 1)
                } catch { fail(String(describing: error)) }
            }
            dispatchMain()
        }
        var root: URL?
        if let i = args.firstIndex(of: "--support-root"), args.indices.contains(i + 1), args[i + 1].hasPrefix("/") { root = URL(fileURLWithPath: args[i + 1]) }
        let allowed = args.isEmpty || args == ["--preview"] || (args.count == 3 && args[0] == "--preview" && args[1] == "--support-root" && root != nil)
        guard allowed else { fail("Usage: glacier [--preview [--support-root ABSOLUTE_PATH_ENDING_IN_Glacier]] | --headless-check --test-root ABSOLUTE_PATH") }
        let delegate = GlacierDesktop(supportOverride: root, preview: args.contains("--preview"))
        NSApplication.shared.delegate = delegate
        NSApplication.shared.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("glacier: \(message)\n".utf8)); exit(78)
    }
}
