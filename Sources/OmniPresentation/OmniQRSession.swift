import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

public struct OmniQRPayload: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case link = "Link"
        case wifi = "Wi-Fi"
        case text = "Text"
    }

    public let input: String
    public let encoded: String
    public let kind: Kind
    public let defaultFilename: String

    public init(input: String) {
        self.input = input
        let lower = input.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") {
            kind = .link
            encoded = input
            let host = URLComponents(string: input)?.host
            let fallback = String(input.drop(while: { $0 != ":" }).dropFirst())
            defaultFilename = Self.filename(from: host ?? fallback, keepPeriods: host != nil)
        } else if lower.hasPrefix("wifi:") {
            kind = .wifi
            let value = String(input.dropFirst(5))
            let parts = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let password = parts.count > 1 ? String(parts[1]) : ""
            let escapedName = Self.escapeWiFi(name)
            if password.isEmpty {
                encoded = "WIFI:T:nopass;S:\(escapedName);;"
            } else {
                encoded = "WIFI:T:WPA;S:\(escapedName);P:\(Self.escapeWiFi(password));;"
            }
            defaultFilename = "wifi-\(Self.filename(from: name))"
        } else {
            kind = .text
            encoded = input
            let firstWords = input.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
            defaultFilename = Self.filename(from: firstWords)
        }
    }

    private static func escapeWiFi(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\;,:\"".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func filename(from text: String, keepPeriods: Bool = false) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        var result = ""
        for character in folded.prefix(60) {
            if character.isASCII && (character.isLetter || character.isNumber || (keepPeriods && character == ".")) {
                result.append(character)
            } else if !result.isEmpty && result.last != "-" {
                result.append("-")
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "qr-code" : trimmed
    }
}

public struct OmniQRCode: Sendable {
    public enum Correction: String, Sendable {
        case m = "M"
        case l = "L"
    }

    public enum Failure: Error, Sendable, Equatable {
        case empty
        case tooLong(bytes: Int, maximum: Int)
        case generationFailed
        case invalidGeometry
        case pngEncodingFailed
    }

    public static let maximumBytes = 2_953
    public static let exportPixels = 1_024
    public static let quietZoneModules = 4

    public let payload: OmniQRPayload
    public let modules: Int
    public let version: Int
    public let correction: Correction
    private let dark: [Bool]

    private init(payload: OmniQRPayload, modules: Int, correction: Correction, dark: [Bool]) {
        self.payload = payload
        self.modules = modules
        version = (modules - 17) / 4
        self.correction = correction
        self.dark = dark
    }

    public static func generate(_ payload: OmniQRPayload) throws -> OmniQRCode {
        guard !payload.input.isEmpty else { throw Failure.empty }
        let bytes = Data(payload.encoded.utf8)
        guard bytes.count <= maximumBytes else {
            throw Failure.tooLong(bytes: bytes.count, maximum: maximumBytes)
        }
        for correction: Correction in [.m, .l] {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = bytes
            filter.correctionLevel = correction.rawValue
            guard let image = filter.outputImage else { continue }
            let width = Int(image.extent.width)
            // Core Image supplies one white module on every side. The actual
            // QR matrix is the extent minus those two border modules.
            let modules = width - 2
            guard image.extent.origin == .zero, Int(image.extent.height) == width,
                  modules >= 21, modules <= 177, (modules - 17).isMultiple(of: 4) else {
                throw Failure.invalidGeometry
            }
            var pixels = [UInt8](repeating: 255, count: width * width * 4)
            pixels.withUnsafeMutableBytes { raw in
                CIContext().render(image, toBitmap: raw.baseAddress!, rowBytes: width * 4,
                                   bounds: image.extent, format: .RGBA8,
                                   colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            var dark = [Bool](repeating: false, count: modules * modules)
            for row in 0..<modules {
                for column in 0..<modules {
                    dark[row * modules + column] = pixels[((row + 1) * width + column + 1) * 4] < 128
                }
            }
            return OmniQRCode(payload: payload, modules: modules, correction: correction, dark: dark)
        }
        throw Failure.tooLong(bytes: bytes.count, maximum: maximumBytes)
    }

    public func isDark(row: Int, column: Int) -> Bool {
        guard (0..<modules).contains(row), (0..<modules).contains(column) else { return false }
        return dark[row * modules + column]
    }

    public var modulePixels: Int { Self.exportPixels / (modules + 2 * Self.quietZoneModules) }
    public var renderedPixels: Int { modulePixels * (modules + 2 * Self.quietZoneModules) }
    public var insetPixels: Int { (Self.exportPixels - renderedPixels) / 2 }

    public func pngData() throws -> Data {
        let size = Self.exportPixels
        let scale = modulePixels
        let origin = insetPixels + Self.quietZoneModules * scale
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for row in 0..<modules {
            for column in 0..<modules where isDark(row: row, column: column) {
                let startX = origin + column * scale
                let startY = origin + row * scale
                for y in startY..<(startY + scale) {
                    for x in startX..<(startX + scale) {
                        let index = (y * size + x) * 4
                        pixels[index] = 0
                        pixels[index + 1] = 0
                        pixels[index + 2] = 0
                    }
                }
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw Failure.pngEncodingFailed
        }
        let output = NSMutableData()
        guard let finalDestination = CGImageDestinationCreateWithData(output as CFMutableData,
                                                                     "public.png" as CFString, 1, nil) else {
            throw Failure.pngEncodingFailed
        }
        CGImageDestinationAddImage(finalDestination, image, nil)
        guard CGImageDestinationFinalize(finalDestination) else { throw Failure.pngEncodingFailed }
        return output as Data
    }

    public func svgData() -> Data {
        let side = modules + 2 * Self.quietZoneModules
        var svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 \(side) \(side)" shape-rendering="crispEdges">
        <rect width="\(side)" height="\(side)" fill="#fff"/>

        """
        for row in 0..<modules {
            for column in 0..<modules where isDark(row: row, column: column) {
                svg += "<rect x=\"\(column + Self.quietZoneModules)\" y=\"\(row + Self.quietZoneModules)\" width=\"1\" height=\"1\" fill=\"#000\"/>\n"
            }
        }
        svg += "</svg>\n"
        return Data(svg.utf8)
    }
}

/// Synchronous QR state. A failed edit never makes the retained preview exportable.
@MainActor
public final class OmniQRSession {
    public var onChange: (@MainActor () -> Void)?
    public private(set) var input = ""
    public private(set) var isOpen = false
    public private(set) var payload: OmniQRPayload?
    public private(set) var code: OmniQRCode?
    public private(set) var lastFittingCode: OmniQRCode?
    public private(set) var failure: String?

    public init() {}

    public var canExport: Bool { isOpen && code != nil }
    public var previewOpacity: Double { failure != nil && lastFittingCode != nil ? 0.35 : 1 }
    public var summary: String? {
        guard isOpen else { return nil }
        if let failure { return failure }
        guard let code else { return nil }
        let fallback = code.correction == .l ? " (M would not fit)" : ""
        return "\(code.payload.kind.rawValue) · \(input.count) chars · v\(code.version) · \(code.modules) × \(code.modules) · \(code.correction.rawValue)\(fallback)"
    }

    public func open(input: String = "") {
        isOpen = true
        self.input = ""
        payload = nil
        code = nil
        lastFittingCode = nil
        failure = nil
        inputChanged(input)
    }

    public func close() {
        isOpen = false
        input = ""
        payload = nil
        code = nil
        lastFittingCode = nil
        failure = nil
        onChange?()
    }

    public func inputChanged(_ next: String) {
        guard isOpen else { return }
        input = next
        code = nil
        failure = nil
        guard !next.isEmpty else {
            payload = nil
            lastFittingCode = nil
            onChange?()
            return
        }
        let nextPayload = OmniQRPayload(input: next)
        payload = nextPayload
        do {
            let generated = try OmniQRCode.generate(nextPayload)
            code = generated
            lastFittingCode = generated
        } catch OmniQRCode.Failure.tooLong(let bytes, let maximum) {
            failure = "Too long · \(bytes.formatted()) of \(maximum.formatted()) bytes at L"
        } catch {
            failure = "Could not generate QR code."
        }
        onChange?()
    }
}
