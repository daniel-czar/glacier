import AppKit
import OmniCore
import OmniPresentation
import Testing

@Test @MainActor func captureComposerRendersRoutesAndClearsUnsavedState() throws {
    _ = NSApplication.shared
    let tool = OmniCaptureWindowController(presentsInterface: false)
    defer { tool.dismiss() }
    var saves = 0
    tool.onSaveRequested = { saves += 1 }
    let cases: [(String, String, OmniCaptureDestination?)] = [
        ("empty", "", nil),
        ("note", "A fragment worth keeping.\nIt can stay a fragment.", .note),
        ("link", "www.example.com/read", .link)
    ]
    for (name, input, destination) in cases {
        tool.show(input: input)
        #expect(tool.session.request?.destination == destination)
        #expect(tool.session.canSave == !input.isEmpty)
        #expect(saves == 0)
        let view = tool.viewController.view
        #expect(view.bounds.contains(tool.viewController.saveButton.frame))
        #expect(view.bounds.contains(tool.viewController.routeLabel.frame))
        #expect(tool.viewController.routeLabel.frame.maxX < tool.viewController.saveButton.frame.minX)
        if let path = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"], !path.isEmpty {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            view.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            let image = OmniNativeCaptureHarness.image(of: view)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("capture-\(name).png"))
        }
        tool.dismiss()
        #expect(tool.session.input.isEmpty)
        #expect(!tool.session.canSave)
    }
}
