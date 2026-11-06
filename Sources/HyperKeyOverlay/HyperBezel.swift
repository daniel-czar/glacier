import AppKit

/// A small bottom-centre HUD, the system's own idiom for keyboard-triggered
/// state (volume, Caps Lock). The one timed element Omni allows, never a
/// notification. Failures (C109), plus a shorter notice for a success you
/// could not otherwise see: a result that lands only on the clipboard
/// (D1 of plan f71f8baac8f0149e).
@MainActor
public final class HyperBezel {
    public static let visibleDuration: TimeInterval = 1.0
    public static let noticeDuration: TimeInterval = 0.6
    public static let fadeDuration: TimeInterval = 0.2
    public private(set) var message: String?
    public private(set) var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var generation = 0
    private let presentsInterface: Bool

    public init(presentsInterface: Bool = true) {
        self.presentsInterface = presentsInterface
    }

    public func show(_ text: String, notice: Bool = false, pointer: NSPoint = NSEvent.mouseLocation) {
        message = text
        generation += 1
        let mine = generation
        guard presentsInterface else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.stringValue = text
        let width = min(420, ceil(label.intrinsicContentSize.width) + 40)
        let size = NSSize(width: max(160, width), height: 44)
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 120,
                              width: size.width, height: size.height), display: false)
        label.frame = NSRect(x: 20, y: 12, width: size.width - 40, height: 20)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + (notice ? Self.noticeDuration : Self.visibleDuration)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = Self.fadeDuration; panel.animator().alphaValue = 0 },
                                                     completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == mine else { return }
                        self.panel?.orderOut(nil)
                        self.message = nil
                    }
                })
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = HyperBezelPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Not "Hyper Overlay": the release probe must never count the bezel.
        panel.title = "Hyper bezel"
        let background = NSVisualEffectView(frame: panel.contentLayoutRect)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("hyper.bezel.message")
        background.addSubview(label)
        panel.contentView = background
        return panel
    }
}

final class HyperBezelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
