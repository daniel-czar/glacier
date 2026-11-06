import Foundation

public enum OverlayTransitionKind: Equatable, Sendable {
    case opened(String)
    case closed
    case replaced(from: String, to: String)
    case unchanged
    case rejected(String)
}

public struct OverlayTransition: Equatable, Sendable {
    public var kind: OverlayTransitionKind
    public var state: OverlayRuntimeState
    public var overlay: String?
    public var generation: Int

    public init(
        kind: OverlayTransitionKind,
        state: OverlayRuntimeState,
        overlay: String?,
        generation: Int
    ) {
        self.kind = kind
        self.state = state
        self.overlay = overlay
        self.generation = generation
    }
}

public struct OverlayLifecycle: Sendable {
    public private(set) var activeOverlay: String?
    public private(set) var generation: Int
    private let allowedOverlays: Set<String>

    public init(allowedOverlays: Set<String>, generation: Int = 0, activeOverlay: String? = nil) {
        self.allowedOverlays = allowedOverlays
        self.generation = generation
        self.activeOverlay = activeOverlay
    }

    public var state: OverlayRuntimeState {
        activeOverlay == nil ? .idle : .showing
    }

    public mutating func show(_ overlay: String) -> OverlayTransition {
        guard allowedOverlays.contains(overlay) else {
            return OverlayTransition(
                kind: .rejected("unknown-or-unimplemented-overlay"),
                state: state,
                overlay: activeOverlay,
                generation: generation
            )
        }

        if activeOverlay == overlay {
            generation += 1
            activeOverlay = nil
            return OverlayTransition(kind: .closed, state: .idle, overlay: nil, generation: generation)
        }

        if let previous = activeOverlay {
            generation += 1
            activeOverlay = overlay
            return OverlayTransition(
                kind: .replaced(from: previous, to: overlay),
                state: .showing,
                overlay: overlay,
                generation: generation
            )
        }

        generation += 1
        activeOverlay = overlay
        return OverlayTransition(kind: .opened(overlay), state: .showing, overlay: overlay, generation: generation)
    }

    public mutating func close() -> OverlayTransition {
        guard activeOverlay != nil else {
            return OverlayTransition(kind: .unchanged, state: .idle, overlay: nil, generation: generation)
        }

        generation += 1
        activeOverlay = nil
        return OverlayTransition(kind: .closed, state: .idle, overlay: nil, generation: generation)
    }
}
