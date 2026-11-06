import AppKit
import QuickLookUI

/// Quick Look's file is private, transient, and removed on edit, dismissal or close.
@MainActor
final class OmniDrawnPreview: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private(set) var url: URL?
    private(set) var isPresenting = false
    private weak var panel: QLPreviewPanel?
    private var keyMonitor: Any?
    var onReturnToTool: (() -> Void)?

    func prepare(_ png: Data, title: String = "Concept lens") throws {
        close()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omni-drawn-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(title + ".png")
        do { try png.write(to: file, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        url = file
        // Set before key-window transfer, so the pad's resignKey keeps its session.
        isPresenting = true
    }

    func beginControl(_ panel: QLPreviewPanel) {
        removeKeyMonitor()
        self.panel = panel
        panel.dataSource = self
        panel.delegate = self
        // Quick Look handles Escape itself before consulting its delegate.
        // Intercept only this owned panel's two dismissal keys so cleanup and
        // focus restoration happen even when the shared panel merely orders out.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window === panel,
                      event.keyCode == 53 || event.keyCode == 49 else { return false }
                self.close()
                self.onReturnToTool?()
                return true
            }
            return handled ? nil : event
        }
    }

    func endControl(_ panel: QLPreviewPanel) {
        removeKeyMonitor()
        panel.dataSource = nil
        panel.delegate = nil
        self.panel = nil
        discardFile()
        isPresenting = false
    }

    func close() {
        removeKeyMonitor()
        let previous = panel
        panel = nil
        previous?.orderOut(nil)
        if previous?.dataSource === self { previous?.dataSource = nil; previous?.delegate = nil }
        discardFile()
        isPresenting = false
    }

    private func discardFile() {
        if let url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        url = nil
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url.map { $0 as NSURL }
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 || event.keyCode == 49 else { return false }
        close()
        onReturnToTool?()
        return true
    }
    func windowWillClose(_ notification: Notification) {
        close()
        onReturnToTool?()
    }
}

@MainActor
protocol OmniDrawnPreviewProviding {
    var drawnPreview: OmniDrawnPreview { get }
}
