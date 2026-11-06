import AppKit
import Foundation
import GlacierConfiguration

extension GlacierDesktop {
    /// A settings file from an earlier build is not evidence of an unfinished wizard.
    /// A dedicated checkpoint, when present, owns resume/completion independently.
    func presentInitialOnboarding(paths: GlacierPaths) {
        let store = GlacierOnboardingStore(supportDirectory: paths.support)
        do {
            if try store.shouldPresent(settingsExists: FileManager.default.fileExists(atPath: paths.settings.path)) {
                showOnboarding()
            }
        } catch {
            report(error.localizedDescription)
            showSettings()
        }
    }

    public func showOnboarding() {
        guard onboardingIsActive, let composition else { return }
        if onboardingWindow == nil {
            let store = GlacierOnboardingStore(supportDirectory: composition.paths.support)
            let model = GlacierOnboardingModel(store: store, actions: GlacierOnboardingLiveActions(host: self))
            let controller = GlacierOnboardingWindowController(model: model)
            controller.onFinish = { [weak self] in
                guard let self, self.onboardingIsActive else { return }
                if self.composition?.snapshot.permits("launcher.open") == true {
                    self.invoke("launcher.open")
                } else {
                    self.native?.showWorkspaceWindow()
                }
            }
            onboardingWindow = controller
        }
        onboardingWindow?.show()
    }
}
