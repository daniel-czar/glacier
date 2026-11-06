import Carbon
import Foundation

/// One chord claimed for a moment: plain `esc` while the Hyper overlay is
/// pinned (H18), so the overlay can close without ever taking key status.
/// Its own signature keeps its events apart from `HotKeyCenter`'s handler on
/// the same application target; each declines the other's events.
@MainActor
public final class TransientHotKey {
    private static let signature: OSType = 0x48595045 // HYPE
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var context: Unmanaged<TransientHotKeyContext>?

    public init() {}

    public var isClaimed: Bool { hotKeyRef != nil }

    /// Claims `keyCode` with no modifiers. Returns false when another app
    /// owns the chord; the caller then falls back to observing the key.
    @discardableResult
    public func claim(keyCode: UInt32, handler: @escaping @MainActor () -> Void) -> Bool {
        release()
        let box = TransientHotKeyContext(handler: handler)
        let retained = Unmanaged.passRetained(box)
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                let result = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &key
                )
                guard result == noErr, key.signature == TransientHotKey.signature else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    Unmanaged<TransientHotKeyContext>.fromOpaque(context).takeUnretainedValue().handler?()
                    return noErr
                }
            },
            1, &events, retained.toOpaque(), &handlerRef
        )
        guard installed == noErr else {
            retained.release()
            handlerRef = nil
            return false
        }
        context = retained
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, 0, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            release()
            return false
        }
        hotKeyRef = ref
        return true
    }

    public func release() {
        if let hotKeyRef {
            let status = UnregisterEventHotKey(hotKeyRef)
            if status != noErr {
                FileHandle.standardError.write(Data("hyper keys: esc release failed (OSStatus \(status))\n".utf8))
            }
            self.hotKeyRef = nil
        }
        // The context goes inert first, so a late Carbon call does nothing.
        context?.takeUnretainedValue().handler = nil
        if let handlerRef {
            guard RemoveEventHandler(handlerRef) == noErr else {
                // Carbon may still call the handler: keep its context alive
                // (a small leak) rather than free it under a live callback.
                self.handlerRef = nil
                context = nil
                return
            }
            self.handlerRef = nil
        }
        context?.release()
        context = nil
    }
}

@MainActor
private final class TransientHotKeyContext {
    var handler: (@MainActor () -> Void)?
    init(handler: @escaping @MainActor () -> Void) { self.handler = handler }
}
