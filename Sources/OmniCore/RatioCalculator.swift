import Foundation

// Ratio (`ra` · `/ratio`, C117–C121, H21): an aspect-ratio reference and
// calculator with a drawn result. Deterministic: ratios are arithmetic and
// names are a presets table. The tables are data (`ratio-tables.json` in
// OmniCore's bundle), so a new preset is a row, not code. No model, no
// network, nothing stored.

/// A width-to-height proportion, or a size read as one.
public struct RatioShape: Sendable, Hashable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var decimal: Double { width / height }

    /// Lowest whole terms when both sides are whole (1200 × 628 → 300:157).
    public var reduced: (width: Int, height: Int)? {
        guard let w = RatioFormat.whole(width), let h = RatioFormat.whole(height), w > 0, h > 0 else { return nil }
        let divisor = Self.gcd(w, h)
        return (w / divisor, h / divisor)
    }

    /// Same proportion: equal lowest terms, or equal decimals when a side is fractional.
    public func isSameRatio(as other: RatioShape) -> Bool {
        if let lhs = reduced, let rhs = other.reduced { return lhs == rhs }
        return abs(decimal - other.decimal) <= 1e-9 * max(decimal, other.decimal)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

/// A size in the tables: `1280 × 720`, optionally named (`HD`).
public struct RatioSize: Sendable, Hashable, Decodable {
    public let w: Int
    public let h: Int
    public let name: String?

    public init(w: Int, h: Int, name: String? = nil) {
        self.w = w
        self.h = h
        self.name = name
    }

    public var text: String { RatioFormat.size(Double(w), Double(h)) }
}

/// One of the common ratios the reference grid draws (C118).
public struct RatioCommon: Sendable, Hashable {
    /// `16:9`, `1.91:1`: what Enter copies from the grid.
    public let label: String
    public let shape: RatioShape
    /// The summary line's word for it: `square`, `cinema`.
    public let name: String?
    /// Shown under the cell in place of the decimal: `OG`, `cinema`.
    public let tag: String?
    public let typical: RatioSize
    /// "Common sizes at this ratio", in the order the rows list them.
    public let sizes: [RatioSize]

    public init(label: String, shape: RatioShape, name: String? = nil, tag: String? = nil, typical: RatioSize, sizes: [RatioSize]) {
        self.label = label
        self.shape = shape
        self.name = name
        self.tag = tag
        self.typical = typical
        self.sizes = sizes
    }

    /// The dimmed note under a grid cell: the tag, else the two-place decimal.
    public var gridNote: String { tag ?? RatioFormat.decimal(shape.decimal) }

    /// `1:1 · square · 1080 × 1080`.
    public var summary: String { [label, name, typical.text].compactMap { $0 }.joined(separator: " · ") }
}

/// One platform preset: `Instagram · Post · 1:1 · 1080 × 1080`.
public struct RatioPreset: Sendable, Hashable {
    public let platform: String
    public let name: String
    /// The ratio as the platform states it (`1:1.414` for A4).
    public let ratio: String
    public let width: Double
    public let height: Double
    /// `px` unless the preset is paper (`mm`, `in`).
    public let unit: String
    /// Extra words the name search accepts: `og`, `story`, `twitter`.
    public let aliases: [String]

    public init(platform: String, name: String, ratio: String, width: Double, height: Double, unit: String = "px", aliases: [String] = []) {
        self.platform = platform
        self.name = name
        self.ratio = ratio
        self.width = width
        self.height = height
        self.unit = unit
        self.aliases = aliases
    }

    public var shape: RatioShape { RatioShape(width: width, height: height) }

    /// `1080 × 1080`, or `210 × 297 mm` for paper: what Enter copies.
    public var size: String { RatioFormat.size(width, height, unit: unit) }
}

public enum RatioTablesError: Error, Equatable {
    case missingResource
    case invalid(String)
}

public struct RatioTables: Sendable {
    public static let resourceName = "ratio-tables"
    /// Ordered by ratio, narrowest first, whatever order the file lists them in.
    public let common: [RatioCommon]
    public let presets: [RatioPreset]

    public init(common: [RatioCommon], presets: [RatioPreset]) {
        self.common = common.sorted { $0.shape.decimal < $1.shape.decimal }
        self.presets = presets
    }

    public init(data: Data) throws {
        struct Payload: Decodable {
            struct Common: Decodable {
                let ratio: String
                let width: Double
                let height: Double
                let name: String?
                let tag: String?
                let typical: RatioSize
                let sizes: [RatioSize]
            }
            struct Preset: Decodable {
                let platform: String
                let name: String
                let ratio: String
                let w: Double
                let h: Double
                let unit: String?
                let aliases: [String]?
            }
            let version: Int
            let common: [Common]
            let presets: [Preset]
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch { throw RatioTablesError.invalid("\(error)") }
        guard payload.version == 1 else { throw RatioTablesError.invalid("version \(payload.version)") }
        let common = try payload.common.enumerated().map { offset, row in
            guard !row.ratio.isEmpty, row.width > 0, row.height > 0, row.typical.w > 0, row.typical.h > 0,
                  row.sizes.allSatisfy({ $0.w > 0 && $0.h > 0 }) else { throw RatioTablesError.invalid("common \(offset)") }
            return RatioCommon(label: row.ratio, shape: RatioShape(width: row.width, height: row.height),
                               name: row.name, tag: row.tag, typical: row.typical, sizes: row.sizes)
        }
        let presets = try payload.presets.enumerated().map { offset, row in
            guard !row.platform.isEmpty, !row.name.isEmpty, !row.ratio.isEmpty, row.w > 0, row.h > 0 else {
                throw RatioTablesError.invalid("preset \(offset)")
            }
            return RatioPreset(platform: row.platform, name: row.name, ratio: row.ratio, width: row.w, height: row.h,
                               unit: row.unit ?? "px", aliases: row.aliases ?? [])
        }
        self.init(common: common, presets: presets)
    }

    /// Parsed once per process.
    public static let shared: Result<RatioTables, RatioTablesError> = {
        do { return .success(try bundled()) }
        catch let error as RatioTablesError { return .failure(error) }
        catch { return .failure(.invalid("\(error)")) }
    }()

    /// Reads the copy packaged in OmniCore's resource bundle.
    public static func bundled() throws -> RatioTables {
        try RatioTables(data: bundledData())
    }

    public static func bundledData() throws -> Data {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json") else {
            throw RatioTablesError.missingResource
        }
        return try Data(contentsOf: url)
    }

    /// The common ratio with exactly this proportion (7:3 is 21:9).
    public func common(matching shape: RatioShape) -> RatioCommon? {
        common.first { $0.shape.isSameRatio(as: shape) }
    }
}

public enum RatioSide: String, Sendable, Equatable {
    case wide
    case high
}

/// The grammar (spec §2), read deterministically.
public enum RatioQuery: Sendable, Equatable {
    /// Empty: the reference grid.
    case reference
    /// `16:9`, `16/9`, `16x9`, `1.91:1`, `2.39`.
    case ratio(RatioShape)
    /// `1200x628`, `1200×628`, `1200 628`.
    case size(width: Int, height: Int)
    /// `16:9 at 1200 wide`, `16:9 1200w`, `16:9 w1200`, `16:9 at 600 high`, `16:9 h600`.
    case ratioAt(RatioShape, side: RatioSide, length: Int)
    /// Anything else: a preset name, fuzzy over name and platform.
    case name(String)
}

public enum RatioParser {
    public static let maximumInputCharacters = 200
    /// Sides beyond this are typos, not sizes.
    static let maximumSide: Double = 100_000
    /// Terms below this are typos too; they also keep every computed side
    /// far inside `Int` (100 000 × 100 000 / 0.01).
    static let minimumTerm: Double = 0.01
    /// `AxB` reads as a size when either side reaches this (H21).
    static let sizeThreshold = 100

    public static func parse(_ input: String) -> RatioQuery {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .reference }
        // `16 : 9` and `1200 × 628` read as one token.
        let normalized = text.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: #"(\d)\s*([:/x])\s*(\d)"#, with: "$1$2$3", options: .regularExpression)
        let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count == 1 {
            if let pair = pair(tokens[0]) {
                if pair.separator == "x", let w = RatioFormat.whole(pair.width), let h = RatioFormat.whole(pair.height),
                   w >= sizeThreshold || h >= sizeThreshold {
                    return .size(width: w, height: h)
                }
                return .ratio(RatioShape(width: pair.width, height: pair.height))
            }
            if let value = number(tokens[0]), value < Double(sizeThreshold) {
                return .ratio(RatioShape(width: value, height: 1))
            }
        }
        if tokens.count == 2, let w = number(tokens[0]).flatMap(RatioFormat.whole), let h = number(tokens[1]).flatMap(RatioFormat.whole),
           w >= sizeThreshold, h >= sizeThreshold {
            return .size(width: w, height: h)
        }
        if tokens.count >= 2, let shape = ratio(tokens[0]), let dimension = dimension(Array(tokens.dropFirst())) {
            return .ratioAt(shape, side: dimension.side, length: dimension.length)
        }
        return .name(text)
    }

    /// The ratio half of `<ratio> at N wide`: any pair, or a bare decimal.
    private static func ratio(_ token: String) -> RatioShape? {
        if let pair = pair(token) { return RatioShape(width: pair.width, height: pair.height) }
        if let value = number(token), value < Double(sizeThreshold) { return RatioShape(width: value, height: 1) }
        return nil
    }

    /// `at 1200 wide`, `at 1200` (wide), `1200 wide`, `1200w`, `w1200`, `at 600 high`, `h600`.
    private static func dimension(_ tokens: [String]) -> (side: RatioSide, length: Int)? {
        var rest = tokens
        if rest.first == "at" { rest.removeFirst() }
        switch rest.count {
        case 1:
            let token = rest[0]
            if let length = length(token) { return tokens.first == "at" ? (.wide, length) : nil }
            for (letter, side) in [("w", RatioSide.wide), ("h", .high)] {
                if token.hasPrefix(letter), let length = length(String(token.dropFirst())) { return (side, length) }
                if token.hasSuffix(letter), let length = length(String(token.dropLast())) { return (side, length) }
            }
            return nil
        case 2:
            guard let length = length(rest[0]), let side = side(rest[1]) else { return nil }
            return (side, length)
        default:
            return nil
        }
    }

    private static func side(_ word: String) -> RatioSide? {
        switch word {
        case "wide", "w", "width": .wide
        case "high", "h", "height", "tall": .high
        default: nil
        }
    }

    private static func length(_ token: String) -> Int? {
        guard let value = number(token), let whole = RatioFormat.whole(value) else { return nil }
        return whole
    }

    private static func pair(_ token: String) -> (width: Double, height: Double, separator: Character)? {
        guard let separator = token.first(where: { $0 == ":" || $0 == "/" || $0 == "x" }) else { return nil }
        let parts = token.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2, let width = number(String(parts[0])), let height = number(String(parts[1])) else { return nil }
        return (width, height, separator)
    }

    /// A positive plain number within bounds: `16`, `1.91`. No signs or exponents.
    private static func number(_ token: String) -> Double? {
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              token.filter({ $0 == "." }).count <= 1, token.first != ".", token.last != ".",
              let value = Double(token), value >= minimumTerm, value <= maximumSide else { return nil }
        return value
    }
}

/// One row beneath the drawing (C119): the kind cell draws `shape` in
/// miniature; `copyText` is what Enter copies and `summary` is what the
/// summary line says while the row is selected (C120).
public struct RatioRow: Sendable, Equatable {
    public let shape: RatioShape
    public let text: String
    public let qualifier: String?
    public let note: String?
    public let copyText: String
    public let summary: String

    public init(shape: RatioShape, text: String, qualifier: String? = nil, note: String? = nil, copyText: String, summary: String) {
        self.shape = shape
        self.text = text
        self.qualifier = qualifier
        self.note = note
        self.copyText = copyText
        self.summary = summary
    }
}

/// The dimensioned drawing: width above, height beside, ratio inside.
public struct RatioDrawing: Sendable, Equatable {
    public let shape: RatioShape
    public let widthLabel: String
    public let heightLabel: String
    /// Spaced for the drawing: `16 : 9`, `1.91 : 1`.
    public let ratioLabel: String

    public init(shape: RatioShape, widthLabel: String, heightLabel: String, ratioLabel: String) {
        self.shape = shape
        self.widthLabel = widthLabel
        self.heightLabel = heightLabel
        self.ratioLabel = ratioLabel
    }
}

public struct RatioResult: Sendable, Equatable {
    /// The reference (empty field): every common ratio, narrowest first.
    public let grid: [RatioCommon]
    public let drawing: RatioDrawing?
    public let rows: [RatioRow]
    /// `no ratio in "…"` when nothing parsed (C121); there is no cascade.
    public let miss: String?
    /// 1:1 in the reference (the canvas state), the first row otherwise.
    public let initialSelection: Int?

    public static let empty = RatioResult(grid: [], drawing: nil, rows: [], miss: nil, initialSelection: nil)

    public var itemCount: Int { grid.isEmpty ? rows.count : grid.count }

    /// Enter's text for item `index`: a grid ratio, else the row's copy value.
    public func copyText(at index: Int) -> String? {
        if !grid.isEmpty { return grid.indices.contains(index) ? grid[index].label : nil }
        return rows.indices.contains(index) ? rows[index].copyText : nil
    }

    /// The summary line for item `index`; always contains its copy text.
    public func summary(at index: Int?) -> String? {
        if let miss { return miss }
        guard let index else { return nil }
        if !grid.isEmpty { return grid.indices.contains(index) ? grid[index].summary : nil }
        return rows.indices.contains(index) ? rows[index].summary : nil
    }
}

public enum RatioCalculator {
    /// Preset rows on a size or uncommon ratio: within 1 % of its ratio (H21).
    public static let presetTolerance = 0.01
    public static let maximumPresetRows = 4
    /// Reduced terms up to this read as the ratio (`16 : 9`); larger ones as a decimal (`1.91 : 1`).
    static let readableTerm = 32

    public static func evaluate(_ input: String, tables: RatioTables) -> RatioResult {
        guard input.count <= RatioParser.maximumInputCharacters else { return miss(input) }
        switch RatioParser.parse(input) {
        case .reference:
            let square = tables.common.firstIndex { $0.shape.isSameRatio(as: RatioShape(width: 1, height: 1)) }
            return RatioResult(grid: tables.common, drawing: nil, rows: [], miss: nil,
                               initialSelection: tables.common.isEmpty ? nil : (square ?? 0))
        case .size(let width, let height):
            return size(width: width, height: height, tables: tables)
        case .ratio(let shape):
            return ratio(shape, tables: tables)
        case .ratioAt(let shape, let side, let length):
            return ratio(shape, side: side, length: length, tables: tables)
        case .name(let text):
            let rows = RatioPresetMatcher.search(text, in: tables.presets).map(presetRow)
            guard !rows.isEmpty else { return miss(input) }
            return RatioResult(grid: [], drawing: nil, rows: rows, miss: nil, initialSelection: 0)
        }
    }

    private static func size(width: Int, height: Int, tables: RatioTables) -> RatioResult {
        let shape = RatioShape(width: Double(width), height: Double(height))
        let sizeText = RatioFormat.size(shape.width, shape.height)
        let label = readableLabel(shape, tables: tables)
        let decimal = decimalRow(shape, context: sizeText)
        var rows = [decimal]
        if let nearest = nearestRow(shape, excluding: decimal.copyText, context: sizeText, tables: tables) { rows.append(nearest) }
        rows += presetRows(near: shape, size: (width, height), tables: tables)
        let drawing = RatioDrawing(shape: shape, widthLabel: "\(width)", heightLabel: "\(height)", ratioLabel: RatioFormat.spaced(label))
        return RatioResult(grid: [], drawing: drawing, rows: rows, miss: nil, initialSelection: 0)
    }

    private static func ratio(_ shape: RatioShape, tables: RatioTables) -> RatioResult {
        let label = readableLabel(shape, tables: tables)
        let terms = label.split(separator: ":").map(String.init)
        let drawing = RatioDrawing(shape: shape, widthLabel: terms.first ?? "", heightLabel: terms.last ?? "",
                                   ratioLabel: RatioFormat.spaced(label))
        let rows: [RatioRow]
        if let common = tables.common(matching: shape) {
            rows = sizeRows(common)
        } else {
            let decimal = decimalRow(shape, context: label)
            rows = [decimal]
                + [nearestRow(shape, excluding: decimal.copyText, context: label, tables: tables)].compactMap { $0 }
                + presetRows(near: shape, size: nil, tables: tables)
        }
        return RatioResult(grid: [], drawing: drawing, rows: rows, miss: nil, initialSelection: rows.isEmpty ? nil : 0)
    }

    private static func ratio(_ shape: RatioShape, side: RatioSide, length: Int, tables: RatioTables) -> RatioResult {
        let label = readableLabel(shape, tables: tables)
        let other = side == .wide ? Double(length) * shape.height / shape.width : Double(length) * shape.width / shape.height
        // An answer no screen or page has is a typo, not a size.
        guard other.isFinite, other.rounded() <= RatioParser.maximumSide else {
            return miss("\(label) at \(length) \(side.rawValue)")
        }
        let rounded = max(1, Int(other.rounded()))
        let (width, height) = side == .wide ? (length, rounded) : (rounded, length)
        let sizeText = RatioFormat.size(Double(width), Double(height))
        let at = "at \(length) \(side.rawValue)"
        let exact = abs(other - other.rounded()) < 1e-9
        let answer = RatioRow(shape: RatioShape(width: Double(width), height: Double(height)), text: sizeText,
                              qualifier: exact ? nil : "rounded from \(RatioFormat.number(other))", note: at,
                              copyText: sizeText, summary: "\(label) \(at) · \(sizeText)")
        let drawing = RatioDrawing(shape: answer.shape, widthLabel: "\(width)", heightLabel: "\(height)",
                                   ratioLabel: RatioFormat.spaced(label))
        let rows = [answer] + (tables.common(matching: shape).map(sizeRows) ?? [])
        return RatioResult(grid: [], drawing: drawing, rows: rows, miss: nil, initialSelection: 0)
    }

    /// The ratio as people say it: the common label when it is one (`16:10`,
    /// `21:9`), small lowest terms (`4:7`), else the decimal (`1.91:1`).
    static func readableLabel(_ shape: RatioShape, tables: RatioTables) -> String {
        if let common = tables.common(matching: shape) { return common.label }
        if let reduced = shape.reduced, reduced.width <= readableTerm, reduced.height <= readableTerm {
            return "\(reduced.width):\(reduced.height)"
        }
        return RatioFormat.decimal(shape.decimal) + ":1"
    }

    /// `1.91:1 · decimal · 300:157 reduced`.
    private static func decimalRow(_ shape: RatioShape, context: String) -> RatioRow {
        let text = RatioFormat.decimal(shape.decimal) + ":1"
        let note = shape.reduced.map { "\($0.width):\($0.height) reduced" }
        return RatioRow(shape: shape, text: text, qualifier: "decimal", note: note, copyText: text, summary: "\(context) · \(text)")
    }

    /// The nearest common ratio other than the one the decimal row already
    /// names, with its error relative to the common ratio (`≈ 2:1 · 4.5 % wider`).
    private static func nearestRow(_ shape: RatioShape, excluding label: String, context: String, tables: RatioTables) -> RatioRow? {
        let candidates = tables.common.filter { $0.label != label }
        guard let nearest = candidates.min(by: { abs($0.shape.decimal - shape.decimal) < abs($1.shape.decimal - shape.decimal) }) else {
            return nil
        }
        let exact = nearest.shape.isSameRatio(as: shape)
        let error = abs(nearest.shape.decimal - shape.decimal) / nearest.shape.decimal
        let direction = nearest.shape.decimal > shape.decimal ? "wider" : "narrower"
        let percent = (error * 1000).rounded() / 10
        let note = exact ? "exact" : (percent < 0.1 ? "< 0.1 % \(direction)" : "\(RatioFormat.number(percent)) % \(direction)")
        return RatioRow(shape: nearest.shape, text: exact ? nearest.label : "≈ \(nearest.label)",
                        qualifier: exact ? "common" : "nearest common", note: note,
                        copyText: nearest.label, summary: "\(context) · \(nearest.label)")
    }

    /// Presets within 1 % of the ratio. For a typed size the closest sizes
    /// lead, so `1200x628` puts LinkedIn and Open Graph before Instagram.
    private static func presetRows(near shape: RatioShape, size: (Int, Int)?, tables: RatioTables) -> [RatioRow] {
        let near = tables.presets.enumerated().compactMap { offset, preset -> (Double, Double, Int, RatioPreset)? in
            let error = abs(preset.shape.decimal - shape.decimal) / preset.shape.decimal
            guard error < presetTolerance else { return nil }
            var distance = Double.infinity
            if let size, preset.unit == "px" {
                distance = abs(preset.width / Double(size.0) - 1) + abs(preset.height / Double(size.1) - 1)
            }
            return (size == nil ? error : distance, error, offset, preset)
        }.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        return near.prefix(maximumPresetRows).map { _, _, _, preset in
            RatioRow(shape: preset.shape, text: preset.name, qualifier: "\(preset.platform) · \(preset.size)", note: "preset",
                     copyText: preset.size, summary: "\(preset.name) · \(preset.ratio) · \(preset.size)")
        }
    }

    /// `1280 × 720 · HD · common`.
    private static func sizeRows(_ common: RatioCommon) -> [RatioRow] {
        common.sizes.map { size in
            RatioRow(shape: RatioShape(width: Double(size.w), height: Double(size.h)), text: size.text, qualifier: size.name,
                     note: "common", copyText: size.text,
                     summary: [common.label, size.name, size.text].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// `Post · 1:1 · 1080 × 1080 · Instagram`.
    private static func presetRow(_ preset: RatioPreset) -> RatioRow {
        RatioRow(shape: preset.shape, text: preset.name, qualifier: "\(preset.ratio) · \(preset.size)", note: preset.platform,
                 copyText: preset.size, summary: "\(preset.name) · \(preset.ratio) · \(preset.size)")
    }

    private static func miss(_ input: String) -> RatioResult {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let echo = text.count > 40 ? String(text.prefix(40)) + "…" : text
        return RatioResult(grid: [], drawing: nil, rows: [], miss: "no ratio in \u{201C}\(echo)\u{201D}", initialSelection: nil)
    }
}

/// Names reuse Recall's scorer and minimum (H21: "threshold as Recall's"):
/// each preset is offered to `RecallMatcher` as a labelled record, title
/// `<platform> <name>`, with its aliases as saved intents.
public enum RatioPresetMatcher {
    public static func search(_ query: String, in presets: [RatioPreset]) -> [RatioPreset] {
        guard query.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        let records = presets.map { preset in
            RecallCommand(category: preset.platform, command: preset.name, label: "\(preset.platform) \(preset.name)",
                          note: preset.aliases.joined(separator: " "), intentAliases: preset.aliases)
        }
        var used = Set<Int>()
        return RecallMatcher.search(query, in: records).sheet.compactMap { record in
            guard let index = records.indices.first(where: { !used.contains($0) && records[$0] == record }) else { return nil }
            used.insert(index)
            return presets[index]
        }
    }
}

public enum RatioFormat {
    /// The whole number a value is, if it is one.
    public static func whole(_ value: Double) -> Int? {
        guard value.isFinite, value.rounded() == value, abs(value) < 1e9 else { return nil }
        return Int(value)
    }

    /// `1200`, `8.5`, `628.27`: whole numbers bare, others to two places.
    public static func number(_ value: Double) -> String {
        if let whole = whole(value) { return "\(whole)" }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Two places, always: `1.91`, `1.00`, `0.56`.
    public static func decimal(_ value: Double) -> String { String(format: "%.2f", value) }

    /// `1200 × 675`, `210 × 297 mm`.
    public static func size(_ width: Double, _ height: Double, unit: String = "px") -> String {
        "\(number(width)) × \(number(height))" + (unit == "px" ? "" : " \(unit)")
    }

    /// `16:9` → `16 : 9` for the drawing.
    public static func spaced(_ label: String) -> String { label.replacingOccurrences(of: ":", with: " : ") }
}
