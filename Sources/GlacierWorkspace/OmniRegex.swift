import Foundation
import OmniAdapters
import OmniCore
import OmniModels
import OmniPresentation

/// Composes the ephemeral Regex session with a separate sheet and the
/// configured high-effort provider route. Isolated hosts stay in their own
/// support root; only the installed composition sees the installed sheet.
public enum OmniRegex {
    public static func sheetURL(environment: GlacierWorkspaceEnvironment) -> URL {
        environment.configuration.regexSheet
    }

    @MainActor
    public static func makeSession(environment: GlacierWorkspaceEnvironment) -> OmniRegexSession {
        let store = RegexSheetStore(url: sheetURL(environment: environment))
        let entries: [RegexSheetEntry]
        let notice: String?
        do {
            entries = try store.load()
            notice = nil
        } catch {
            entries = []
            notice = "Could not read the Regex sheet. Check regex-sheet.json."
        }
        let runtime = environment.providerRuntime
        return OmniRegexSession(
            entries: entries,
            initialNotice: notice,
            automaticRequestsEnabled: { environment.automaticRequestsEnabled("tool.regex") },
            generator: { intent in
                guard let runtime else { throw EphemeralToolFailure("Regex needs a configured language provider.") }
                do {
                    return try await RegexModelGenerator.generate(
                        intent: intent, broker: runtime,
                        runID: "ephemeral-regex-" + UUID().uuidString.lowercased(),
                        profileID: environment.profileID("regex.write") ?? ProviderRuntimeCatalog.cerebrasRegexHighProfileID
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as RegexModelError {
                    throw EphemeralToolFailure(error.description)
                } catch ModelBrokerError.invalidSettings {
                    throw EphemeralToolFailure("Regex needs a compatible provider profile. Check the connection and profile in Settings.")
                } catch let error as ModelBrokerError {
                    if case .cancelled = error { throw CancellationError() }
                    throw EphemeralToolFailure(error.description)
                } catch {
                    throw EphemeralToolFailure("The selected provider could not write a pattern. Edit the request to try again.")
                }
            },
            add: { entry, intent in try await Task.detached { try store.add(entry, intent: intent) }.value },
            undo: { try await Task.detached { try store.undoLastAdd() }.value },
            reload: { try await Task.detached { try store.load() }.value }
        )
    }
}
