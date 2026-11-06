import Carbon
import Foundation
import HyperOverlayCore

public enum HotKeyError: Error, CustomStringConvertible {
    case registration(String, OSStatus)
    case invalidBindings
    case cleanup([String])

    public var description: String {
        switch self {
        case .registration(let operation, let status):
            return "\(operation) failed (OSStatus \(status)); check for another app owning the chord"
        case .invalidBindings:
            return "hotkey bindings must have unique overlay IDs and chords"
        case .cleanup(let details):
            return "hotkey cleanup incomplete: \(details.joined(separator: "; ")); reload to retry or restart the host"
        }
    }
}

@MainActor
protocol HotKeyBackend: AnyObject, Sendable {
    func start(handler: @escaping @MainActor (UInt32, Bool) -> Void) throws
    func register(_ chord: HotKeyChord, id: UInt32) throws
    func unregister(id: UInt32) throws
    func stop() -> [String]
}

/// Registrations are replaced transactionally: acquire new chords first, then
/// release removed ones. A conflict leaves the previous mapping fully usable.
@MainActor
public final class HotKeyCenter {
    private let backend: any HotKeyBackend
    private let onTrigger: @MainActor (String) -> Void
    private var registrations: [HotKeyChord: UInt32] = [:]
    private var overlays: [UInt32: String] = [:]
    private var held: Set<UInt32> = []
    private var nextID: UInt32 = 1
    private var started = false
    private var pendingCleanup: [HotKeyChord: UInt32] = [:]
    public private(set) var bindings: [OverlayHotKeyBinding] = []

    public convenience init(onTrigger: @escaping @MainActor (String) -> Void) {
        self.init(backend: CarbonHotKeyBackend(), onTrigger: onTrigger)
    }

    init(backend: any HotKeyBackend, onTrigger: @escaping @MainActor (String) -> Void) {
        self.backend = backend
        self.onTrigger = onTrigger
    }

    deinit {
        let backend = backend
        Task { @MainActor in
            let failures = backend.stop()
            if !failures.isEmpty {
                FileHandle.standardError.write(Data("\(HotKeyError.cleanup(failures))\n".utf8))
            }
        }
    }

    public func replace(with bindings: [OverlayHotKeyBinding]) throws {
        guard Set(bindings.map(\.overlayID)).count == bindings.count,
              Set(bindings.map(\.chord)).count == bindings.count
        else { throw HotKeyError.invalidBindings }

        let cleanupFailures = retryCleanup()
        guard cleanupFailures.isEmpty else { throw HotKeyError.cleanup(cleanupFailures) }

        if !started {
            try backend.start { [weak self] id, pressed in self?.receive(id: id, pressed: pressed) }
            started = true
        }

        var acquired: [HotKeyChord: UInt32] = [:]
        do {
            for binding in bindings where registrations[binding.chord] == nil {
                guard nextID < UInt32.max else { throw HotKeyError.invalidBindings }
                let id = nextID
                nextID += 1
                try backend.register(binding.chord, id: id)
                acquired[binding.chord] = id
            }
        } catch {
            pendingCleanup.merge(acquired) { _, new in new }
            let failures = retryCleanup()
            if !failures.isEmpty { throw HotKeyError.cleanup([String(describing: error)] + failures) }
            throw error
        }

        let desired = Set(bindings.map(\.chord))
        for (chord, id) in registrations where !desired.contains(chord) {
            pendingCleanup[chord] = id
            held.remove(id)
        }
        registrations = registrations.filter { desired.contains($0.key) }
        registrations.merge(acquired) { _, new in new }
        overlays = Dictionary(uniqueKeysWithValues: bindings.compactMap { binding in
            registrations[binding.chord].map { ($0, binding.overlayID) }
        })
        self.bindings = bindings
        let failures = retryCleanup()
        guard failures.isEmpty else { throw HotKeyError.cleanup(failures) }
    }

    @discardableResult
    public func stop() -> [String] {
        pendingCleanup.merge(registrations) { _, new in new }
        let failures = backend.stop()
        if failures.isEmpty { pendingCleanup.removeAll() }
        registrations.removeAll()
        overlays.removeAll()
        held.removeAll()
        bindings.removeAll()
        started = false
        if !failures.isEmpty {
            FileHandle.standardError.write(Data("\(HotKeyError.cleanup(failures))\n".utf8))
        }
        return failures
    }

    private func retryCleanup() -> [String] {
        var failures: [String] = []
        for (chord, id) in pendingCleanup {
            do {
                try backend.unregister(id: id)
                pendingCleanup.removeValue(forKey: chord)
            } catch {
                failures.append("keycode \(chord.keyCode): \(error)")
            }
        }
        return failures
    }

    private func receive(id: UInt32, pressed: Bool) {
        if !pressed {
            held.remove(id)
        } else if let overlay = overlays[id], held.insert(id).inserted {
            onTrigger(overlay)
        }
    }
}

@MainActor
private final class HotKeyCallbackContext {
    var handle: ((EventRef) -> OSStatus)?
}

@MainActor
private final class CarbonHotKeyBackend: HotKeyBackend {
    private static let signature: OSType = 0x48595052 // HYPR
    private var handlerRef: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: (@MainActor (UInt32, Bool) -> Void)?
    private var callbackContext: HotKeyCallbackContext?

    func start(handler: @escaping @MainActor (UInt32, Bool) -> Void) throws {
        self.handler = handler
        if let callbackContext, handlerRef != nil {
            callbackContext.handle = { [weak self] event in self?.receive(event) ?? OSStatus(eventNotHandledErr) }
            return
        }
        let callbackContext = HotKeyCallbackContext()
        callbackContext.handle = { [weak self] event in self?.receive(event) ?? OSStatus(eventNotHandledErr) }
        let retainedContext = Unmanaged.passRetained(callbackContext)
        let events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let callback = Unmanaged<HotKeyCallbackContext>.fromOpaque(context).takeUnretainedValue()
                    return callback.handle?(event) ?? OSStatus(eventNotHandledErr)
                }
            },
            events.count, events,
            retainedContext.toOpaque(), &handlerRef
        )
        guard status == noErr else {
            retainedContext.release()
            throw HotKeyError.registration("install hotkey event handler", status)
        }
        self.callbackContext = callbackContext
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var key = EventHotKeyID()
        let result = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &key
        )
        guard result == noErr, key.signature == Self.signature, refs[key.id] != nil else {
            return OSStatus(eventNotHandledErr)
        }
        handler?(key.id, GetEventKind(event) == UInt32(kEventHotKeyPressed))
        return noErr
    }

    func register(_ chord: HotKeyChord, id: UInt32) throws {
        let modifiers = chord.modifiers.reduce(UInt32(0)) { flags, modifier in
            switch modifier {
            case .command: return flags | UInt32(cmdKey)
            case .option: return flags | UInt32(optionKey)
            case .control: return flags | UInt32(controlKey)
            case .shift: return flags | UInt32(shiftKey)
            }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            chord.keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref
        )
        guard status == noErr, let ref else {
            throw HotKeyError.registration("register keycode \(chord.keyCode)", status)
        }
        refs[id] = ref
    }

    func unregister(id: UInt32) throws {
        guard let ref = refs[id] else { return }
        let status = UnregisterEventHotKey(ref)
        guard status == noErr else { throw HotKeyError.registration("unregister hotkey \(id)", status) }
        refs.removeValue(forKey: id)
    }

    func stop() -> [String] {
        var failures: [String] = []
        for id in Array(refs.keys) {
            do { try unregister(id: id) }
            catch { failures.append(String(describing: error)) }
        }
        callbackContext?.handle = nil
        if let handlerRef {
            let status = RemoveEventHandler(handlerRef)
            if status == noErr {
                if let callbackContext { Unmanaged.passUnretained(callbackContext).release() }
                self.callbackContext = nil
                self.handlerRef = nil
            } else {
                // Carbon may still invoke the retained, now inert callback context.
                failures.append("remove hotkey event handler failed (OSStatus \(status))")
            }
        }
        handler = nil
        return failures
    }
}

extension HotKeyCenter {
    /// Registers `required` and, when possible, `optional` alongside it in one
    /// transaction. If the optional binding cannot be registered (its chord is
    /// owned by another app, or it collides with a required chord or ID), the
    /// required set is registered on its own and the reason is returned, so a
    /// surface that is optional by contract does not take the required set
    /// down with it, on a fresh start included. A failure of the required set
    /// still throws, as does an OS cleanup failure, which blocks every reload.
    public func replace(required: [OverlayHotKeyBinding], optional: OverlayHotKeyBinding?) throws -> String? {
        guard let optional else {
            try replace(with: required)
            return nil
        }
        if let collision = required.first(where: { $0.chord == optional.chord || $0.overlayID == optional.overlayID }) {
            try replace(with: required)
            return "\(optional.overlayID) collides with \(collision.overlayID) (keycode \(collision.chord.keyCode)); registered the required set only"
        }
        do {
            try replace(with: required + [optional])
            return nil
        } catch {
            try replace(with: required)
            return "\(error); registered the required set only"
        }
    }
}
