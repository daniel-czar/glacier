import HyperOverlayCore

/// Main-actor owner for foreground identity and generation validity. It keeps
/// AppKit orchestration from reimplementing lifecycle rules at each ingress.
public final class ForegroundArbitrator {
    private var lifecycle: OverlayLifecycle

    public init(allowedOverlays: Set<String>, generation: Int = 0, activeOverlay: String? = nil) {
        self.lifecycle = OverlayLifecycle(
            allowedOverlays: allowedOverlays,
            generation: generation,
            activeOverlay: activeOverlay
        )
    }

    @MainActor public var activeOverlay: String? { lifecycle.activeOverlay }
    @MainActor public var generation: Int { lifecycle.generation }
    @MainActor public var state: OverlayRuntimeState { lifecycle.state }

    @MainActor public func show(_ overlay: String) -> OverlayTransition {
        lifecycle.show(overlay)
    }

    @MainActor public func close() -> OverlayTransition {
        lifecycle.close()
    }

    @MainActor public func isCurrent(overlay: String, generation: Int) -> Bool {
        lifecycle.activeOverlay == overlay && lifecycle.generation == generation
    }
}
