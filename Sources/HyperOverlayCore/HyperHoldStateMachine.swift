import Foundation

/// Hold to reveal (C98, C99). Pure: the controller feeds it keyboard events
/// and carries out the effects. Holding Hyper past the chord threshold with no
/// key means "I don't know the key"; the overlay appears because of that
/// state, and releasing is the close. Hyper+H pins it.
public struct HyperHoldStateMachine: Sendable, Equatable {
    /// A fluent chord is under 250 ms. If the overlay ever flashes during one,
    /// raise this constant; never add an animation in.
    public static let holdThreshold: TimeInterval = 0.4
    public static let fadeDuration: TimeInterval = 0.12

    public enum Presentation: Sendable, Equatable {
        case hidden
        /// Hyper is down: Caps Lock is drawn pressed, nothing to close.
        case held
        /// Hyper+H: stays after release, `esc` closes, hover shows detail.
        case pinned
    }

    public enum Effect: Sendable, Equatable {
        /// Arm the threshold timer; `timerFired(token:)` must echo the token.
        case startTimer(token: Int)
        case cancelTimer
        /// Show at once, no fade in; a show cancels a running fade out.
        case present(Presentation)
        case hide(fade: Bool)
        /// Plain `esc` belongs to the overlay only while it is pinned.
        case claimEscape
        case releaseEscape
    }

    public private(set) var presentation: Presentation = .hidden
    private var hyperDown = false
    /// A key went down during this hold: no overlay until the next hold.
    private var chordStarted = false
    private var timerToken = 0
    private var timerArmed = false
    /// Hyper went down while pinned; Hyper+H then closes instead of re-pinning.
    private var heldFromPin = false

    public init() {}

    public mutating func hyperChanged(down: Bool) -> [Effect] {
        guard down != hyperDown else { return [] }
        hyperDown = down
        if down {
            chordStarted = false
            switch presentation {
            case .pinned:
                // Already visible: Caps Lock goes down on the picture at once.
                presentation = .held
                heldFromPin = true
                return [.releaseEscape, .present(.held)]
            case .held:
                return []
            case .hidden:
                timerToken += 1
                timerArmed = true
                return [.startTimer(token: timerToken)]
            }
        }
        var effects = disarm()
        if presentation == .held {
            presentation = .hidden
            heldFromPin = false
            effects.append(.hide(fade: true))
        }
        return effects
    }

    /// Any key while Hyper is down that the host did not bind itself: an
    /// unbound key changes nothing on screen, but it is a chord, not a pause.
    public mutating func keyDown() -> [Effect] {
        guard hyperDown else { return [] }
        chordStarted = true
        return disarm()
    }

    /// A native binding fired (not Hyper+H): its action runs, the hint goes.
    public mutating func bindingFired() -> [Effect] {
        if hyperDown { chordStarted = true }
        var effects = disarm()
        effects += close(fade: false)
        return effects
    }

    /// Hyper+H, or `show hyper-help` on the socket.
    public mutating func helpPressed() -> [Effect] {
        if hyperDown { chordStarted = true }
        var effects = disarm()
        switch presentation {
        case .pinned:
            effects += close(fade: false)
        case .held where heldFromPin:
            effects += close(fade: false)
        case .held, .hidden:
            presentation = .pinned
            heldFromPin = false
            effects += [.present(.pinned), .claimEscape]
        }
        return effects
    }

    public mutating func timerFired(token: Int) -> [Effect] {
        guard timerArmed, token == timerToken else { return [] }
        timerArmed = false
        guard hyperDown, !chordStarted, presentation == .hidden else { return [] }
        presentation = .held
        return [.present(.held)]
    }

    public mutating func escape() -> [Effect] {
        guard presentation == .pinned else { return [] }
        return close(fade: false)
    }

    /// Socket `close`, a surface taking over, shutdown.
    public mutating func dismiss() -> [Effect] {
        var effects = disarm()
        effects += close(fade: false)
        return effects
    }

    private mutating func disarm() -> [Effect] {
        guard timerArmed else { return [] }
        timerArmed = false
        return [.cancelTimer]
    }

    private mutating func close(fade: Bool) -> [Effect] {
        let was = presentation
        guard was != .hidden else { return [] }
        presentation = .hidden
        heldFromPin = false
        return (was == .pinned ? [.releaseEscape] : []) + [.hide(fade: fade)]
    }
}
