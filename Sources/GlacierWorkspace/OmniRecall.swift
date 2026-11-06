import Foundation
import OmniAdapters
import OmniCore
import OmniModels
import OmniPresentation

/// Composes Recall with the app-selected sheet and configured provider.
public enum OmniRecall {
    /// The sheet Settings → Tools names: the chosen file, else the app path.
    public static func sheetURL(environment: GlacierWorkspaceEnvironment, preferences: OmniPreferencesStore? = nil) -> URL {
        if let chosen = preferences?.current.recallSheetPath { return URL(fileURLWithPath: chosen) }
        return environment.configuration.recallSheet
    }

    @MainActor
    public static func makeSession(environment: GlacierWorkspaceEnvironment, preferences: OmniPreferencesStore? = nil) -> OmniRecallSession {
        let url = sheetURL(environment: environment, preferences: preferences)
        let store = RecallCorpusStore(
            url: url,
            builderScript: nil
        )
        let commands: [RecallCommand]
        let notice: String?
        do {
            if url.standardizedFileURL == environment.configuration.recallSheet.standardizedFileURL {
                try RecallCorpusStore.seedIfMissing(at: url)
            }
            commands = try store.load()
            notice = nil
        } catch {
            commands = []
            notice = "Could not read the command sheet. Choose a sheet in Settings."
        }
        let runtime = environment.providerRuntime
        return OmniRecallSession(
            commands: commands,
            initialNotice: notice,
            automaticRequestsEnabled: { environment.automaticRequestsEnabled("tool.recall") },
            generator: { intent, sheet in
                guard let runtime else { throw EphemeralToolFailure("Recall needs a configured language provider.") }
                do {
                    return try await RecallModelGenerator.generate(
                        intent: intent, sheet: sheet, broker: runtime,
                        runID: "ephemeral-recall-" + UUID().uuidString.lowercased(),
                        environment: environment.recallEnvironment(),
                        profileID: environment.profileID("recall.command") ?? preferences?.current.ephemeralProfileID ?? ProviderRuntimeCatalog.cerebrasFastProfileID
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw EphemeralToolFailure("The selected provider could not suggest a command. Edit the intent to try again.")
                }
            },
            add: { command, intent in try await Task.detached { try store.add(command, intent: intent) }.value },
            undo: { try await Task.detached { try store.undoLastAdd() }.value },
            reload: { try await Task.detached { try store.load() }.value }
        )
    }
}
