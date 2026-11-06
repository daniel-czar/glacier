import GlacierConfiguration

/// Optional starting layout. Loading it only saves suggestions; the platform adapter owns registration.
public enum SuggestedHyperPreset {
    public static func applying(to settings: GlacierSettings, modifiers: [GlacierShortcutModifier] = [.command, .option, .control, .shift]) throws -> GlacierSettings {
        let keys: [String: UInt16] = [
            "launcher.open": 49, "launch.open": 0, "tool.translate": 37, "tool.concept-lens": 46,
            "capture.new": 45, "tool.pronunciation": 32, "tool.express": 14,
            "tool.stash": 16, "clipboard.history": 39, "browser.search-selection": 42,
            "tool.recall": 30, "help.pin": 4,
            "clipboard.collect": 8, "clipboard.paste-next": 9, "clipboard.paste-all": 11,
            "clipboard.clear-collection": 27, "clipboard.equalize": 24,
            "native.reveal": 15, "native.open": 31, "native.jump-to-root": 38,
            "native.editor": 1, "native.terminal": 17, "native.copy-path": 35,
            "native.fence": 13, "native.gather-files": 5
        ]
        var result = settings
        for (action, keyCode) in keys {
            result.shortcuts[action] = .init(enabled: true, chord: try .init(keyCode: keyCode, modifiers: modifiers))
        }
        try result.validate()
        return result
    }
}
