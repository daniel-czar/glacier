import Carbon
import Foundation
import GlacierConfiguration
import HyperOverlayCore

@MainActor
public protocol ShortcutLabeling {
    func keyLabel(for keyCode: UInt16) -> String
}

/// Uses the selected macOS keyboard input source. It never guesses the key's
/// character from a hardcoded UK/US table; unavailable layout data is shown
/// as a physical key code instead of a false glyph.
@MainActor
public struct CurrentKeyboardShortcutLabels: ShortcutLabeling {
    public init() {}

    public func keyLabel(for keyCode: UInt16) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = unsafeBitCast(rawData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return "Key \(keyCode)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length: Int = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        let label = String(utf16CodeUnits: characters, count: Int(length))
        return label.isEmpty ? "Key \(keyCode)" : label.uppercased()
    }
}

@MainActor
public struct ShortcutLabelProjection {
    public let labeler: any ShortcutLabeling
    public init(labeler: any ShortcutLabeling = CurrentKeyboardShortcutLabels()) { self.labeler = labeler }

    public func label(_ chord: GlacierShortcutChord) -> String {
        let prefix = chord.modifiers.map { modifier -> String in
            switch modifier {
            case .command: "⌘"
            case .option: "⌥"
            case .control: "⌃"
            case .shift: "⇧"
            }
        }.joined()
        return prefix + labeler.keyLabel(for: chord.keyCode)
    }

    public func keyboardLayout() -> HyperKeyboardLayout {
        let base = HyperKeyboardLayout.ukISOMacBook
        let labels = Dictionary(uniqueKeysWithValues: base.caps.compactMap { cap -> (UInt32, String)? in
            guard cap.style == .character, let code = cap.keyCode else { return nil }
            return (code, labeler.keyLabel(for: UInt16(code)))
        })
        return base.relabelingCharacters(labels, name: "Current input source labels (UK ISO geometry)")
    }
}
