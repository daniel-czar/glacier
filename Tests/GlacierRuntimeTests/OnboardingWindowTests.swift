import AppKit
import Foundation
import GlacierConfiguration
import GlacierConnections
import SwiftUI
import Testing
import Vision
@testable import GlacierRuntime

@MainActor
private final class WindowFixtureActions: GlacierOnboardingActions {
    var state = GlacierOnboardingSnapshot(
        modelChoices: [.init(id: "cerebras-test", label: "Local fixture model", provider: .cerebras, modelSelector: "fixture")],
        connectionEndpoints: [.cerebras: URL(string: "https://fixture.invalid/v1")!]
    )
    var demoCalls = 0

    func snapshot() async throws -> GlacierOnboardingSnapshot { state }
    func saveShortcut(_ choice: GlacierOnboardingShortcutChoice) async throws { state.shortcut = choice.chord }
    func openAccessibilitySettings() { }
    func checkAccessibility() async throws -> Bool { false }
    func saveConnection(provider: ConnectionProvider, modelProfileID: String,
                        expectedEndpoint: URL, apiKey: String?) async throws {
        state.connectionSavedProviders.insert(provider)
        state.selectedModelProfileID = modelProfileID
    }
    func testConnection(provider: ConnectionProvider) async throws -> String { "Fixture responded" }
    func chooseSourceRoots() async throws -> [GlacierSourceRoot]? { nil }
    func saveSourceRoots(_ roots: [GlacierSourceRoot]) async throws { state.sourceRoots = roots }
    func setClipboardEnabled(_ enabled: Bool) async throws { state.clipboardEnabled = enabled }
    func setLaunchAtLogin(_ enabled: Bool) async throws { state.launchAtLogin = enabled }
    func runDemo(_ demo: GlacierOnboardingDemo) async throws -> String {
        demoCalls += 1
        return "Fixture: \(demo.command)"
    }
}

@MainActor
private func captureOnboarding(_ window: NSWindow, step: GlacierOnboardingStep,
                               appearance: String = "light") throws -> NSBitmapImageRep {
    window.displayIfNeeded()
    guard let content = window.contentView,
          let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        Issue.record("The native onboarding view did not provide a bitmap")
        throw CocoaError(.fileReadCorruptFile)
    }
    content.cacheDisplay(in: content.bounds, to: image)
    if let path = ProcessInfo.processInfo.environment["ONBOARDING_CAPTURE_DIR"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = image.representation(using: .png, properties: [:]) else {
            Issue.record("The native onboarding bitmap could not be encoded")
            throw CocoaError(.fileReadCorruptFile)
        }
        try data.write(to: directory.appendingPathComponent("focused-\(appearance)-\(step.rawValue).png"))
    }
    return image
}

@MainActor
private func expectVisibleHeader(in image: NSBitmapImageRep, step: GlacierOnboardingStep) throws {
    guard let png = image.representation(using: .png, properties: [:]) else {
        Issue.record("The native onboarding bitmap could not be encoded for text recognition")
        throw CocoaError(.fileReadCorruptFile)
    }
    let request = VNRecognizeTextRequest()
    // These are large, fixed English chrome labels. Vision's fast path uses a
    // smaller character model than the accurate neural text pipeline.
    request.recognitionLevel = .fast
    // Hosted macOS runners may have no usable GPU or Neural Engine. Keep the
    // image and OCR assertions real while choosing Vision's CPU path.
    request.usesCPUOnly = true
    do {
        try VNImageRequestHandler(data: png, options: [:]).perform([request])
    } catch {
        let failure = error as NSError
        Issue.record("Vision OCR failed on \(step.rawValue): \(failure.domain) code \(failure.code): \(failure.localizedDescription)")
        throw error
    }
    let headerText = (request.results ?? [])
        .filter { $0.boundingBox.midY > 0.94 }
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
    #expect(headerText.localizedCaseInsensitiveContains("Glacier"),
            "The Glacier chrome must remain visible on \(step.rawValue); recognized top strip: \(headerText)")
    #expect(headerText.localizedCaseInsensitiveContains("Getting started"),
            "The onboarding chrome must remain visible on \(step.rawValue); recognized top strip: \(headerText)")
    let footerText = (request.results ?? [])
        .filter { $0.boundingBox.midY < 0.10 }
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
    let expectedAction = switch step {
    case .welcome: "Get started"
    case .ready: "Open Glacier"
    default: "Continue"
    }
    #expect(footerText.localizedCaseInsensitiveContains(expectedAction),
            "The primary action must remain visible on \(step.rawValue); recognized footer: \(footerText)")
}

@MainActor @Test func onboardingWindowPresentsSixScreensAtMinimumHeightAndClosesWithoutFinishing() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-window-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let actions = WindowFixtureActions()
    let model = GlacierOnboardingModel(store: GlacierOnboardingStore(supportDirectory: directory), actions: actions)
    let controller = GlacierOnboardingWindowController(model: model)
    let window = try #require(controller.window)
    window.appearance = NSAppearance(named: .aqua)
    window.orderFrontRegardless()
    defer { window.close() }
    await model.open()

    #expect(window.title == "Glacier — Getting started")
    #expect(window.contentRect(forFrameRect: window.frame).size.height == 680)
    #expect(window.styleMask.contains(.titled))
    #expect(!window.styleMask.contains(.resizable))

    for expected in GlacierOnboardingStep.allCases {
        #expect(model.step == expected)
        try await Task.sleep(for: .milliseconds(80))
        let image = try captureOnboarding(window, step: expected)
        try expectVisibleHeader(in: image, step: expected)
        if expected != .ready { await model.next() }
    }
    #expect(!model.completed)
    #expect(actions.demoCalls == 0, "The Ready screen must not run a sample before Try it is pressed")

    window.appearance = NSAppearance(named: .darkAqua)
    for _ in 0..<5 { await model.back() }
    for expected in GlacierOnboardingStep.allCases {
        #expect(model.step == expected)
        try await Task.sleep(for: .milliseconds(80))
        let image = try captureOnboarding(window, step: expected, appearance: "dark")
        try expectVisibleHeader(in: image, step: expected)
        if expected != .ready { await model.next() }
    }

    model.apiKey = "transient-fixture-secret"
    window.close()
    #expect(model.apiKey.isEmpty)
    #expect(!model.completed)
}

@MainActor @Test func onboardingRecorderHandlesEscapeTabAndPhysicalShortcut() throws {
    var recorded: GlacierShortcutChord?
    let recorder = GlacierOnboardingShortcutRecorder.RecorderButton(chord: nil) { recorded = $0 }
    #expect(recorder.accessibilityLabel() == "Record shortcut")

    func event(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                     isARepeat: false, keyCode: keyCode))
    }

    recorder.performClick(nil)
    recorder.keyDown(with: try event(53))
    #expect(recorded == nil)
    recorder.performClick(nil)
    recorder.keyDown(with: try event(48))
    #expect(recorded == nil)
    recorder.performClick(nil)
    recorder.keyDown(with: try event(49, .option))
    #expect(recorded?.keyCode == 49)
    #expect(recorded?.modifiers == [.option])
}

@MainActor @Test func completedOnboardingOpensOnlyFromExplicitReadyActionEvenAfterReopening() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-completed-window-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlacierOnboardingStore(supportDirectory: directory)
    try store.save(GlacierOnboardingState(currentStep: .ready, completed: true))
    let model = GlacierOnboardingModel(store: store, actions: WindowFixtureActions())
    let controller = GlacierOnboardingWindowController(model: model)
    let window = try #require(controller.window)
    let host = try #require(window.contentView as? NSHostingView<GlacierOnboardingView>)
    var openCalls = 0
    controller.onFinish = { openCalls += 1 }

    func waitForOpen() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.isOpen && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isOpen)
    }

    controller.show()
    try await waitForOpen()
    #expect(window.isVisible)
    #expect(model.completed)
    #expect(openCalls == 0, "Loading completed setup must not open the command pad")
    await host.rootView.finishAndOpen()
    #expect(openCalls == 1)
    #expect(!window.isVisible)
    #expect(!model.isOpen)

    controller.show()
    try await waitForOpen()
    #expect(window.isVisible)
    #expect(openCalls == 1, "Reopening must wait for another explicit Ready action")
    await host.rootView.finishAndOpen()
    #expect(openCalls == 2)
    #expect(!window.isVisible)
}

@MainActor @Test func longerSavedConnectionAndTestStatusKeepWindowChromeVisible() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-long-endpoint-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlacierOnboardingStore(supportDirectory: directory)
    try store.save(GlacierOnboardingState(currentStep: .intelligence))
    let actions = WindowFixtureActions()
    actions.state.connectionEndpoints[.cerebras] = try #require(URL(string:
        "https://fixture.invalid/custom/api/v1/organization/a-long-team-name/region/europe-west/provider/cerebras"))
    actions.state.connectionSavedProviders = [.cerebras]
    actions.state.selectedModelProfileID = "cerebras-test"
    let model = GlacierOnboardingModel(store: store, actions: actions)
    let controller = GlacierOnboardingWindowController(model: model)
    let window = try #require(controller.window)
    window.orderFrontRegardless()
    defer { window.close() }
    await model.open()
    await model.testConnection()
    #expect(model.connectionTestResult == "Fixture responded")

    for appearance in ["light", "dark"] {
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        try await Task.sleep(for: .milliseconds(100))
        let image = try captureOnboarding(window, step: .intelligence, appearance: "\(appearance)-longEndpoint")
        try expectVisibleHeader(in: image, step: .intelligence)
    }
}
