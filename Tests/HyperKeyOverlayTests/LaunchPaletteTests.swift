import AppKit
@testable import HyperKeyOverlay
import Testing

private struct LaunchCaptureEntry: Decodable {
    let bundleID: String
    let key: String?
}

private struct LaunchCaptureEnvelope: Decodable {
    let launch: [LaunchCaptureEntry]
}

@MainActor private func captureApplications() throws -> [LaunchApplication] {
    let system = SystemLaunchApplicationEffects()
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["OMNI_LAUNCH_CAPTURE_MANIFEST"], !path.isEmpty {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        let specs: [LaunchCaptureEntry]
        if let array = try? decoder.decode([LaunchCaptureEntry].self, from: data) {
            specs = array
        } else {
            specs = try decoder.decode(LaunchCaptureEnvelope.self, from: data).launch
        }
        return try specs.map { spec in
            guard let resolved = system.resolve(bundleID: spec.bundleID) else {
                throw NSError(domain: "LaunchPaletteCaptureUnresolvedApp", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: spec.bundleID])
            }
            return LaunchApplication(bundleID: resolved.bundleID, name: resolved.name, url: resolved.url,
                                     icon: resolved.icon, key: spec.key)
        }
    }
    let standardAppleIDs = ["com.apple.finder", "com.apple.Safari", "com.apple.iCal", "com.apple.Notes",
                            "com.apple.Terminal", "com.apple.Music", "com.apple.systempreferences", "com.apple.AddressBook",
                            "com.apple.mail", "com.apple.Preview", "com.apple.TextEdit", "com.apple.Photos"]
    return Array(standardAppleIDs.compactMap { system.resolve(bundleID: $0) }.prefix(8))
}

@MainActor private final class FakeLaunchEffects: LaunchApplicationEffects {
    var entries: [String: LaunchApplication] = [:]
    var running: Set<String> = []
    var frontmost: String?
    var activated: [String] = []
    var failure: Error?
    var deferCompletions = false
    var completions: [(@MainActor (Error?) -> Void)] = []

    func resolve(bundleID: String) -> LaunchApplication? { entries[bundleID] }
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    func isFrontmost(bundleID: String) -> Bool { frontmost == bundleID }
    func activate(_ app: LaunchApplication, completion: @escaping @MainActor (Error?) -> Void) {
        activated.append(app.bundleID)
        if deferCompletions { completions.append(completion) }
        else { completion(failure) }
    }

    func makeEntries(_ count: Int) -> [LaunchApplication] {
        (0..<count).map { index in
            let id = "test.app.\(index)"
            let entry = LaunchApplication(bundleID: id, name: "App \(index)",
                                          url: URL(fileURLWithPath: "/Applications/App\(index).app"),
                                          icon: NSImage(systemSymbolName: ["folder", "safari", "bubble.left", "music.note", "terminal", "hammer", "calendar", "globe"][index % 8], accessibilityDescription: nil)!)
            entries[id] = entry
            return entry
        }
    }
}

@Suite(.serialized) @MainActor struct LaunchPaletteTests {
    @Test func layoutUsesOnlyOccupiedPositionalCells() {
        #expect(LaunchPaletteLayout.keys(forCount: 8) == ["Q", "W", "E", "R", "A", "S", "D", "F"])
        #expect(LaunchPaletteLayout.keys(forCount: 6) == ["Q", "W", "E", "A", "S", "D"])
        #expect(LaunchPaletteLayout.keys(forCount: 4) == ["Q", "W", "A", "S"])
        #expect(LaunchPaletteLayout.keys(forCount: 3) == ["Q", "W", "A"])
        #expect(LaunchPaletteLayout.size(forCount: 8).width == 640)
        #expect(LaunchPaletteLayout.size(forCount: 6).width < 640)
        #expect(LaunchPaletteLayout.size(forCount: 8).height == 324)
        #expect(LaunchPaletteLayout.index(forKeyCode: 0, count: 6) == 3)
        #expect(LaunchPaletteLayout.index(forKeyCode: 15, count: 6) == nil)
    }

    @Test func loadReportsBadIDsAndPreservesOrderedValidEntries() {
        let effects = FakeLaunchEffects()
        let entries = effects.makeEntries(3)
        let controller = LaunchPaletteController(effects: effects, presentsInterface: false)
        let problems = controller.load(bundleIDs: [entries[0].bundleID, "missing", entries[1].bundleID,
                                                  entries[0].bundleID, entries[2].bundleID])
        #expect(controller.applications.map(\.bundleID) == entries.map(\.bundleID))
        #expect(problems.count == 2)
        #expect(problems.map(\.bundleID) == ["missing", entries[0].bundleID])
    }

    @Test func keysEnterAndFrontmostCloseWithoutLaunchingOrigin() {
        let effects = FakeLaunchEffects()
        let entries = effects.makeEntries(6)
        let controller = LaunchPaletteController(effects: effects, presentsInterface: false)
        controller.load(entries: entries)
        controller.show()
        #expect(controller.isShown && controller.selectedIndex == 0)
        controller.keyDown(keyCode: 40) // Unmapped K is swallowed.
        #expect(controller.isShown && effects.activated.isEmpty)
        controller.keyDown(keyCode: 15) // R is absent for six apps.
        #expect(controller.isShown && effects.activated.isEmpty)
        controller.keyDown(keyCode: 2) // D = sixth app.
        #expect(!controller.isShown && effects.activated == [entries[5].bundleID])
        #expect(controller.lastLaunchedBundleID == entries[5].bundleID)
        controller.show()
        #expect(controller.selectedIndex == 5)
        effects.frontmost = entries[5].bundleID
        controller.keyDown(keyCode: 36) // Enter closes, never hides the app.
        #expect(!controller.isShown && effects.activated.count == 1)
    }

    @Test func escapeToggleHyperAndFailureLeaveNoPersistentSelection() {
        let effects = FakeLaunchEffects()
        let entries = effects.makeEntries(2)
        let controller = LaunchPaletteController(effects: effects, presentsInterface: false)
        controller.load(entries: entries)
        controller.toggle()
        controller.keyDown(keyCode: 53)
        #expect(!controller.isShown)
        controller.toggle()
        controller.keyDown(keyCode: 12, modifiers: [.command, .option, .control, .shift])
        #expect(controller.isShown && effects.activated.isEmpty)
        controller.toggle() // Carbon's Hyper+A callback owns the second press.
        #expect(!controller.isShown)
        effects.failure = NSError(domain: "test", code: 1)
        var message: String?
        controller.onError = { message = $0 }
        controller.show()
        controller.keyDown(keyCode: 13)
        #expect(effects.activated == [entries[1].bundleID])
        #expect(controller.lastLaunchedBundleID == nil)
        #expect(message?.contains("App 1") == true)
    }

    @Test func explicitLettersUsePhysicalKeysAndRejectConflictsAfterResolution() {
        let effects = FakeLaunchEffects()
        let entries = effects.makeEntries(8)
        let ids = entries.map(\.bundleID)
        let letters = ["T", "C", "F", "G", "N", "B", "S", "O"]
        let overrides = Dictionary(uniqueKeysWithValues: zip(ids, letters))
        let controller = LaunchPaletteController(effects: effects, presentsInterface: false)
        #expect(controller.load(bundleIDs: ids, keyOverrides: overrides).isEmpty)
        #expect(LaunchPaletteLayout.keys(for: controller.applications) == letters)
        controller.show()
        controller.keyDown(keyCode: 17) // Physical T.
        #expect(effects.activated == [ids[0]])
        controller.show()
        controller.keyDown(keyCode: 31) // Physical O.
        #expect(effects.activated == [ids[0], ids[7]])
        let conflicts = controller.load(bundleIDs: ids, keyOverrides: [ids[0]: "W"])
        #expect(conflicts.contains { $0.bundleID == ids[1] && $0.message.contains("more than once") })
        #expect(Set(LaunchPaletteLayout.keys(for: controller.applications)).count == controller.applications.count)
        #expect(controller.applications.first?.bundleID == ids[0])
    }

    @Test func lateCompletionCannotReplaceTheMostRecentLaunchSelection() {
        let effects = FakeLaunchEffects()
        effects.deferCompletions = true
        let entries = effects.makeEntries(2)
        let controller = LaunchPaletteController(effects: effects, presentsInterface: false)
        controller.load(entries: entries)
        controller.show()
        controller.keyDown(keyCode: 12) // Q
        controller.show()
        controller.keyDown(keyCode: 13) // W
        #expect(effects.completions.count == 2)
        effects.completions[1](nil)
        effects.completions[0](nil)
        #expect(controller.lastLaunchedBundleID == entries[1].bundleID)
    }

    @Test func failedOrFrontmostLaterChoiceDoesNotEraseEarlierSuccessfulLaunch() {
        let effects = FakeLaunchEffects()
        effects.deferCompletions = true
        let entries = effects.makeEntries(2)
        let controller = LaunchPaletteController(effects: effects, presentsInterface: false)
        controller.load(entries: entries)
        controller.show()
        controller.keyDown(keyCode: 12) // A pending.
        controller.show()
        effects.frontmost = entries[1].bundleID
        controller.keyDown(keyCode: 13) // Close only, no new launch.
        effects.completions[0](nil)
        #expect(controller.lastLaunchedBundleID == entries[0].bundleID)

        effects.frontmost = nil
        controller.show()
        controller.keyDown(keyCode: 12) // A pending again.
        controller.show()
        controller.keyDown(keyCode: 13) // B pending, later request.
        effects.completions[2](NSError(domain: "test", code: 2))
        effects.completions[1](nil)
        #expect(controller.lastLaunchedBundleID == entries[0].bundleID)
    }

    @Test func panelSharesFrostedNonactivatingBehaviorButCanConsumeKeys() {
        _ = NSApplication.shared
        let panel = LaunchPalettePanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.surface.cornerRadius == HyperKeyOverlayPanel.cornerRadius)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        var received: [UInt16] = []
        panel.onKeyDown = { code, _ in received.append(code) }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "k",
                                    charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)
        if let event { panel.keyDown(with: event) }
        #expect(received == [40])
    }

    @Test func appIconKeepsItsTopAndBottomInTheFlippedPaletteView() throws {
        _ = NSApplication.shared
        let size = NSSize(width: 56, height: 56)
        let icon = NSImage(size: size, flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: rect.height / 2).fill()
            NSColor.systemRed.setFill()
            NSRect(x: 0, y: rect.height / 2, width: rect.width, height: rect.height / 2).fill()
            return true
        }
        let view = LaunchPaletteView(frame: NSRect(origin: .zero, size: LaunchPaletteLayout.size(forCount: 1)))
        view.entries = [LaunchApplication(bundleID: "test.icon", name: "Test", url: URL(fileURLWithPath: "/test.app"), icon: icon)]
        let bounds = view.bounds.integral
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                    pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        let centerX = Int(bounds.midX * 2)
        let top = try #require(bitmap.colorAt(x: centerX, y: Int((LaunchPaletteLayout.padding + 34) * 2)))
        let bottom = try #require(bitmap.colorAt(x: centerX, y: Int((LaunchPaletteLayout.padding + 79) * 2)))
        #expect(top.redComponent > top.blueComponent, "red upper half should remain at the top")
        #expect(bottom.blueComponent > bottom.redComponent, "blue lower half should remain at the bottom")
    }

    @Test func launchPaletteDesignCapture() throws {
        guard let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let resolved = try captureApplications()
        guard resolved.count >= 8 else { throw NSError(domain: "LaunchPaletteCaptureMissingApps", code: resolved.count) }
        let system = SystemLaunchApplicationEffects()
        for count in [6, 8] {
            let panel = LaunchPalettePanel()
            panel.paletteView.entries = Array(resolved.prefix(count))
            panel.paletteView.runningBundleIDs = Set(resolved.filter { system.isRunning(bundleID: $0.bundleID) }.map(\.bundleID))
            panel.paletteView.selectedIndex = 0
            let natural = LaunchPaletteLayout.size(forCount: count)
            panel.setContentSize(natural)
            panel.surface.frame = NSRect(origin: .zero, size: natural)
            panel.paletteView.frame = panel.surface.bounds
            panel.paletteView.appearance = NSAppearance(named: .darkAqua)
            panel.surface.appearance = NSAppearance(named: .darkAqua)
            panel.surface.apply(transparency: .opaqueFallback)
            panel.surface.layoutSubtreeIfNeeded()
            let bounds = panel.surface.bounds.integral
            let scale: CGFloat = 2
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                        pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                                        bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = bounds.size
            panel.surface.effectiveAppearance.performAsCurrentDrawingAppearance {
                panel.surface.cacheDisplay(in: bounds, to: bitmap)
            }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("launch-palette-\(count).png"))
        }
    }
}
