import AppKit
@testable import OmniPresentation
import Testing
import Vision

struct OmniQRTests {
    @Test func payloadClassificationPreservesTextAndEscapesWiFiGrammar() {
        let link = OmniQRPayload(input: "HTTPS://Example.com/a?x=1")
        #expect(link.kind == .link)
        #expect(link.encoded == link.input)
        #expect(link.defaultFilename == "Example.com")

        let mail = OmniQRPayload(input: "mailto:me@example.com")
        #expect(mail.kind == .link)
        #expect(mail.encoded == mail.input)

        let phone = OmniQRPayload(input: "tel:+44 123")
        #expect(phone.kind == .link)
        #expect(phone.encoded == phone.input)

        let wifi = OmniQRPayload(input: "wifi:Lab;Room,h\\;,:\"")
        #expect(wifi.kind == .wifi)
        #expect(wifi.encoded == #"WIFI:T:WPA;S:Lab\;Room;P:h\\\;\,\:\";;"#)
        #expect(wifi.defaultFilename.hasPrefix("wifi-Lab"))

        let standard = OmniQRPayload(input: "wifi:Home,hunter2")
        #expect(standard.encoded == "WIFI:T:WPA;S:Home;P:hunter2;;")

        let open = OmniQRPayload(input: "wifi:Café")
        #expect(open.encoded == "WIFI:T:nopass;S:Café;;")
        #expect(open.defaultFilename == "wifi-Cafe")

        let text = OmniQRPayload(input: "  🐈 café\n")
        #expect(text.kind == .text)
        #expect(text.encoded == text.input)
        #expect(Array(text.encoded.utf8) == Array(text.input.utf8))
        #expect(OmniQRPayload(input: "One two three four").defaultFilename == "One-two-three")
        #expect(OmniQRPayload(input: "https://open-meteo.com/en/docs").defaultFilename == "open-meteo.com")
    }

    @Test func coreImageMatrixUsesRealVersionAndMFirstFallback() throws {
        let link = try OmniQRCode.generate(OmniQRPayload(input: "https://example.com/qr-demo"))
        #expect(link.correction == .m)
        #expect(link.modules == 29)
        #expect(link.version == 3)
        #expect(link.isDark(row: 0, column: 0))
        #expect(link.isDark(row: 0, column: 28))
        #expect(link.isDark(row: 28, column: 0))

        let requestedURL = "https://open-meteo.com/en/docs"
        #expect(requestedURL.count == 30)
        let requested = try OmniQRCode.generate(OmniQRPayload(input: requestedURL))
        #expect(requested.modules == 29)
        #expect(requested.version == 3)

        let lowerCase = try OmniQRCode.generate(OmniQRPayload(input: String(repeating: "a", count: 232)))
        #expect(lowerCase.correction == .m)
        #expect(lowerCase.modules == 61)
        #expect(lowerCase.version == 11)

        let lastM = try OmniQRCode.generate(OmniQRPayload(input: String(repeating: "a", count: 2_331)))
        #expect(lastM.correction == .m)
        #expect(lastM.version == 40)
        let firstL = try OmniQRCode.generate(OmniQRPayload(input: String(repeating: "a", count: 2_332)))
        #expect(firstL.correction == .l)
        let lastL = try OmniQRCode.generate(OmniQRPayload(input: String(repeating: "a", count: 2_953)))
        #expect(lastL.correction == .l)
        #expect(lastL.version == 40)
        #expect(throws: OmniQRCode.Failure.tooLong(bytes: 2_954, maximum: 2_953)) {
            try OmniQRCode.generate(OmniQRPayload(input: String(repeating: "a", count: 2_954)))
        }
    }

    @Test func utf8ByteLimitAppliesToTransformedPayload() throws {
        let input = String(repeating: "é", count: 1_477)
        let payload = OmniQRPayload(input: input)
        #expect(payload.encoded.utf8.count == 2_954)
        #expect(throws: OmniQRCode.Failure.tooLong(bytes: 2_954, maximum: 2_953)) {
            try OmniQRCode.generate(payload)
        }
        let expanded = OmniQRPayload(input: "wifi:" + String(repeating: ";", count: 1_500))
        #expect(expanded.encoded.utf8.count > OmniQRCode.maximumBytes)
        #expect(throws: OmniQRCode.Failure.self) { try OmniQRCode.generate(expanded) }
    }

    @Test func pngIsExactIntegerPixelsWithQuietZoneAndVisionDecode() throws {
        let value = "https://example.com/qr-demo"
        let code = try OmniQRCode.generate(OmniQRPayload(input: value))
        let png = try code.pngData()
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == 1_024)
        #expect(bitmap.pixelsHigh == 1_024)
        #expect(code.modulePixels == 27)
        #expect(code.renderedPixels == (code.modules + 8) * code.modulePixels)
        #expect(code.insetPixels == (1_024 - code.renderedPixels) / 2)
        let firstDark = code.insetPixels + 4 * code.modulePixels
        for coordinate in [0, code.insetPixels, firstDark - 1] {
            #expect(bitmap.colorAt(x: coordinate, y: coordinate)?.usingColorSpace(.deviceRGB)?.redComponent == 1)
        }
        #expect(bitmap.colorAt(x: firstDark, y: firstDark)?.usingColorSpace(.deviceRGB)?.redComponent == 0)
        #expect(bitmap.colorAt(x: firstDark + code.modulePixels - 1, y: firstDark)?.usingColorSpace(.deviceRGB)?.redComponent == 0)
        #expect(bitmap.colorAt(x: firstDark + code.modulePixels, y: firstDark)?.usingColorSpace(.deviceRGB)?.redComponent == 0)
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(data: png).perform([request])
        #expect(request.results?.contains(where: { $0.payloadStringValue == value }) == true)
    }

    @Test func svgUsesSameTopDownModuleMatrixAndWhiteQuietZone() throws {
        let code = try OmniQRCode.generate(OmniQRPayload(input: "scan me"))
        let svg = try #require(String(data: code.svgData(), encoding: .utf8))
        let side = code.modules + 8
        #expect(svg.contains("viewBox=\"0 0 \(side) \(side)\""))
        #expect(svg.contains("width=\"512\" height=\"512\""))
        #expect(svg.contains("<rect width=\"\(side)\" height=\"\(side)\" fill=\"#fff\"/>"))
        #expect(svg.contains("<rect x=\"4\" y=\"4\" width=\"1\" height=\"1\" fill=\"#000\"/>"))
        #expect(svg.contains("<rect x=\"\(code.modules + 3)\" y=\"4\" width=\"1\" height=\"1\" fill=\"#000\"/>"))
        let rectCount = svg.components(separatedBy: "<rect x=").count - 1
        let darkCount = (0..<code.modules).reduce(0) { total, row in
            total + (0..<code.modules).filter { code.isDark(row: row, column: $0) }.count
        }
        #expect(rectCount == darkCount)
    }

    @Test @MainActor func sessionClearsExportOnFailureAndRestoresOnEdit() throws {
        let session = OmniQRSession()
        var changes = 0
        session.onChange = { changes += 1 }
        session.open(input: "hello")
        _ = try #require(session.code)
        #expect(session.summary == "Text · 5 chars · v1 · 21 × 21 · M")
        #expect(session.canExport)
        #expect(session.previewOpacity == 1)

        session.inputChanged("https://open-meteo.com/en/docs")
        #expect(session.summary == "Link · 30 chars · v3 · 29 × 29 · M")

        session.inputChanged(String(repeating: "é", count: 1_477))
        #expect(session.code == nil)
        #expect(session.lastFittingCode?.payload.input == "https://open-meteo.com/en/docs")
        #expect(session.payload?.encoded.utf8.count == 2_954)
        #expect(session.failure == "Too long · 2,954 of 2,953 bytes at L")
        #expect(session.summary == session.failure)
        #expect(!session.canExport)
        #expect(session.previewOpacity == 0.35)

        session.inputChanged("again")
        #expect(session.code != nil)
        #expect(session.failure == nil)
        #expect(session.canExport)
        #expect(session.previewOpacity == 1)
        session.close()
        #expect(!session.isOpen)
        #expect(session.code == nil && session.lastFittingCode == nil)
        #expect(session.payload == nil && session.summary == nil)
        #expect(!session.canExport)
        #expect(changes == 5)
    }
}
