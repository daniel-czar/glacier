import AppKit
import OmniCore
@testable import OmniPresentation
import Testing

private struct WriteFailure: Error {}

@MainActor private func sampleModel(clipboardHost: OmniClipboardSettingsHost? = nil) -> OmniSettingsModel {
    let choices = [OmniSettingsChoice(value: "cerebras-fast", label: "Cerebras Qwen 3.8 27B"),
                   OmniSettingsChoice(value: "cerebras-careful", label: "Cerebras Llama 3.3 70B")]
    let rows = ["/email", "/expand", "/find", "/meaning", "/msg", "/qq", "/slug", "/translate"].map {
        OmniModelRow(token: $0, model: $0 == "/find" ? "cerebras-careful" : nil, fallback: nil,
                     defaultDetail: "Cerebras Qwen 3.8 27B", models: choices, fallbacks: choices)
    }
    let clipboard = OmniClipboardSettings(
        history: .init(capture: true, retentionHours: 168, itemCount: 12, usedBytes: 1_400_000),
        keepChoices: [24, 36, 72, 168, 336, 720], stashDepth: 5, collectedCount: 3,
        pasteMode: .asCopied, batchSeparator: .newLine)
    clipboard.host = clipboardHost
    return OmniSettingsModel(
        general: OmniGeneralSettings(openAtLogin: "On · launch agent", notifications: "Allowed", notificationsOff: false, appearance: .system),
        models: OmniModelSettings(defaultModel: "Cerebras Qwen 3.8 27B", defaultFallback: "OpenRouter GPT-OSS 120B, then Local",
                                  rows: rows, deterministicTokens: ["/capture", "/fav", "/g"],
                                  ephemeralChoices: choices),
        clipboard: clipboard,
        tools: OmniToolSettings(skinTone: .none, recallSheetPath: "/tmp/command-reference.json", forvoKey: "Set",
                                merriamWebsterKey: "Not set", pronConfigPath: "/tmp/pron/config.toml"),
        shortcuts: OmniShortcutSettings(manifestPath: "/tmp/hyper-bindings.json", overlaySize: NSSize(width: 900, height: 360), makeOverlayView: {
            NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 360))
        })
    )
}

@Suite(.serialized) struct OmniSettingsWindowTests {
    @Test @MainActor func fivePanesAtAFixedWidthWithTheirOwnHeightsAndTitles() throws {
        let window = OmniSettingsWindow(model: sampleModel(), pane: .models)
        #expect(window.toolbarStyle == .preference)
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.title == "Models")
        var heights: [OmniSettingsPane: CGFloat] = [:]
        for pane in OmniSettingsPane.allCases {
            let controller = try #require(window.paneController(pane))
            controller.view.layoutSubtreeIfNeeded()
            let size = controller.view.fittingSize
            #expect(size.width == OmniSettingsWindow.width, "\(pane)")
            #expect(size.height > 100, "\(pane)")
            heights[pane] = size.height
            window.select(pane)
            #expect(window.title == pane.title)
            #expect(window.pane == pane)
        }
        #expect(Set(heights.values).count > 1)
        #expect(heights[.models]! > heights[.general]!)
        // The overlay picture is scaled into the form: 900 × 360 at 560 wide.
        #expect(heights[.shortcuts]! > 224)
        print("settings pane heights", heights.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key)=\($0.value)" })
    }

    @Test @MainActor func aPaneTallerThanTheScreenIsCappedAndTheOthersKeepTheirHeight() throws {
        let window = OmniSettingsWindow(model: sampleModel(), pane: .models, maximumPaneHeight: 500)
        let models = try #require(window.paneController(.models)).view
        models.layoutSubtreeIfNeeded()
        #expect(models.fittingSize == NSSize(width: OmniSettingsWindow.width, height: 500))
        let general = try #require(window.paneController(.general)).view
        general.layoutSubtreeIfNeeded()
        #expect(general.fittingSize.height < 500)
    }

    @Test @MainActor func modelWritesApplyInOrderAndAFailureShowsInPlace() async throws {
        let model = sampleModel().models
        var writes: [String] = []
        var failNext = false
        model.onRouteChange = { token, chosen, fallback in
            if failNext { failNext = false; throw WriteFailure() }
            writes.append("\(token)=\(chosen ?? "default")/\(fallback ?? "none")")
        }
        model.setModel("cerebras-fast", for: "/qq")
        model.setFallback("cerebras-careful", for: "/qq")
        #expect(model.row("/qq")?.write == .saving)
        await model.drainWrites()
        #expect(writes == ["/qq=cerebras-fast/none", "/qq=cerebras-fast/cerebras-careful"])
        #expect(model.row("/qq")?.write == .idle)
        // Default clears the fallback: none is saved without a main.
        model.setModel(nil, for: "/qq")
        await model.drainWrites()
        #expect(writes.last == "/qq=default/none")
        #expect(model.row("/qq")?.fallback == nil)
        // A fallback with no main is not a choice.
        model.setFallback("cerebras-fast", for: "/qq")
        await model.drainWrites()
        #expect(writes.count == 3)
        failNext = true
        model.setModel("cerebras-careful", for: "/slug")
        await model.drainWrites()
        #expect(model.row("/slug")?.write == .failed)
        model.retry("/slug")
        await model.drainWrites()
        #expect(model.row("/slug")?.write == .idle)
        #expect(writes.last == "/slug=cerebras-careful/none")
    }

    @Test @MainActor func aReloadNeverOverwritesAChoiceThatIsSavingOrNotSaved() async throws {
        let model = sampleModel().models
        var stored: [String: String?] = [:]
        var failEmail = true
        model.onRouteChange = { token, chosen, _ in
            if token == "/email", failEmail { throw WriteFailure() }
            stored[token] = chosen
            // Every successful write reloads from the store, as the composer does.
            model.replaceRows(model.rows.map { row in
                var row = row
                row.model = stored[row.token] ?? nil
                row.write = .idle
                return row
            })
        }
        model.setModel("cerebras-careful", for: "/email")
        await model.drainWrites()
        #expect(model.row("/email")?.write == .failed)
        model.setModel("cerebras-fast", for: "/qq")
        await model.drainWrites()
        // The reload after /qq's write keeps /email's unsaved choice and mark.
        #expect(model.row("/email")?.model == "cerebras-careful")
        #expect(model.row("/email")?.write == .failed)
        failEmail = false
        model.retry("/email")
        await model.drainWrites()
        #expect(stored["/email"] == "cerebras-careful")
        #expect(model.row("/email")?.write == .idle)
    }

    @Test @MainActor func queuedWritesRunAfterTheWindowLetsGoOfTheModel() async throws {
        var writes: [String] = []
        var models: OmniModelSettings? = sampleModel().models
        models?.onRouteChange = { token, _, _ in
            try await Task.sleep(for: .milliseconds(20))
            writes.append(token)
        }
        models?.setModel("cerebras-fast", for: "/qq")
        models?.setModel("cerebras-fast", for: "/slug")
        let queue = models
        models = nil
        await queue?.drainWrites()
        #expect(writes == ["/qq", "/slug"])
    }

    @Test @MainActor func clipboardChangesReachTheHostAndClearRefreshesTheCount() async throws {
        var state = OmniClipboardHistoryState(capture: true, retentionHours: 168, itemCount: 12, usedBytes: 1_400_000)
        var collected = 3
        var applied: [String] = []
        let host = OmniClipboardSettingsHost(
            retentionChoices: [24, 36, 72, 168],
            state: { state },
            setCapture: { state.capture = $0; applied.append("capture=\($0)") },
            setRetention: { state.retentionHours = $0; applied.append("keep=\($0)") },
            clearHistory: { state.itemCount = 0; state.usedBytes = 0; applied.append("clear") },
            collectedCount: { collected },
            clearCollected: { collected = 0; applied.append("clear-collected") },
            applyPreferences: { _ in }
        )
        let model = sampleModel(clipboardHost: host).clipboard
        var preferences = OmniPreferences()
        model.onPreferences = { change in change(&preferences) }
        #expect(model.itemsKept.hasPrefix("12 · "))
        model.setCapture(false)
        model.setKeepFor(24)
        model.clearHistory()
        model.clearCollected()
        model.setBatchSeparator(.blankLine)
        model.setPasteMode(.plainText)
        await model.drainWrites()
        #expect(applied == ["capture=false", "keep=24", "clear", "clear-collected"])
        #expect(!model.capture && model.keepForHours == 24 && model.itemCount == 0 && model.collectedCount == 0)
        #expect(model.itemsKept.hasPrefix("0"))
        #expect(preferences.batchSeparator == .blankLine && preferences.pasteMode == .plainText)
        #expect(model.failed.isEmpty)
        model.onPreferences = { _ in throw WriteFailure() }
        model.setPasteMode(.asCopied)
        #expect(model.failed == [.pasteMode])
    }

    @Test @MainActor func weatherUnitsWriteAndRetryNotifyOnlyAfterSave() {
        let model = sampleModel().tools
        var saved: [OmniWeatherUnits] = []
        var shouldFail = true
        model.onWeatherUnits = { units in
            if shouldFail { throw WriteFailure() }
            saved.append(units)
        }
        #expect(model.weatherUnits == .followSystem)
        model.setWeatherUnits(.imperial)
        #expect(model.weatherUnits == .imperial)
        #expect(model.weatherUnitsWrite == .failed)
        #expect(saved.isEmpty)
        shouldFail = false
        model.setWeatherUnits(model.weatherUnits)
        #expect(model.weatherUnitsWrite == .idle)
        #expect(saved == [.imperial])
    }

    @Test @MainActor func noProviderRuntimeOrHostLeavesValuesNotDeadControls() throws {
        let models = OmniModelSettings(notice: "Model settings need a configured provider runtime.")
        let clipboard = OmniClipboardSettings(history: nil, keepChoices: [], stashDepth: 5, collectedCount: nil,
                                              pasteMode: .asCopied, batchSeparator: .newLine)
        #expect(clipboard.historyNotice == "Clipboard history runs in the installed host.")
        let base = sampleModel()
        let window = OmniSettingsWindow(model: OmniSettingsModel(general: base.general, models: models, clipboard: clipboard,
                                                                 tools: base.tools, shortcuts: OmniShortcutSettings(manifestPath: nil)),
                                        pane: .clipboard)
        for pane in OmniSettingsPane.allCases {
            let view = try #require(window.paneController(pane)).view
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width == OmniSettingsWindow.width)
        }
    }

    @Test @MainActor func listsAndLabelsReadAsSentences() {
        #expect(omniSettingsList(["/capture", "/fav", "/g"]) == "/capture, /fav and /g")
        #expect(omniSettingsList(["/g"]) == "/g")
        #expect(OmniClipboardSettings.keepLabel(24) == "1 day")
        #expect(OmniClipboardSettings.keepLabel(168) == "7 days")
        #expect(OmniClipboardSettings.keepLabel(36) == "36 hours")
        #expect(OmniSkinTone.medium.apply(to: "👍") == "👍🏽")
        #expect(OmniSkinTone.medium.apply(to: "✋️") == "✋🏽")
        #expect(OmniSkinTone.medium.apply(to: "🍕") == "🍕")
        #expect(OmniSkinTone.medium.apply(to: "👨‍👩‍👧") == "👨‍👩‍👧")
        #expect(OmniSkinTone.none.apply(to: "👍") == "👍")
    }
}
