import CoreGraphics
import Foundation

/// How a cap is drawn (H18, C100). Letters carry a glyph top-left; modifiers a
/// word bottom-left and a symbol top-right; the function row is half height.
public enum HyperKeyCapStyle: String, Sendable, Equatable {
    case character
    case modifier
    case function
    case arrow
    case space
    case isoEnter
}

/// One key of the picture. `frame` is in points, origin top-left, inside the
/// keyboard's own bounds. The ISO Enter spans two rows: `frame` is its top
/// part and `stemFrame` the narrower part beneath.
public struct HyperKeyCap: Sendable, Equatable {
    public let id: String
    public let glyph: String
    public let shifted: String?
    public let symbol: String?
    public let keyCode: UInt32?
    public let style: HyperKeyCapStyle
    public let frame: CGRect
    public let stemFrame: CGRect?

    /// The cap's full outline, both parts of the ISO Enter included.
    public var bounds: CGRect { stemFrame.map { frame.union($0) } ?? frame }
}

/// The picture is the user's keyboard, drawn from this table (C100): a future
/// keyboard is a data change. Rows end on one right edge; each row's flexible
/// key (esc, delete, Enter, right shift, space) absorbs the remainder.
public struct HyperKeyboardLayout: Sendable {
    public static let keySize: Double = 58
    public static let gap: Double = 6
    public static let functionRowHeight: Double = 28
    public static let width: Double = 925

    public let name: String
    public let caps: [HyperKeyCap]
    public let size: CGSize

    public func cap(id: String) -> HyperKeyCap? { caps.first { $0.id == id } }
    public func cap(forKeyCode keyCode: UInt32) -> HyperKeyCap? { caps.first { $0.keyCode == keyCode } }

    /// Reuses physical geometry while projecting glyphs from the selected
    /// input source. Caps Lock is named literally; Glacier does not assume a
    /// physical Hyper remapper or a UK key legend.
    public func relabelingCharacters(_ labels: [UInt32: String], name: String) -> HyperKeyboardLayout {
        let projected = caps.map { cap in
            let glyph: String
            if cap.id == "caps" { glyph = "caps lock" }
            else if cap.style == .character, let code = cap.keyCode { glyph = labels[code] ?? "Key \(code)" }
            else { glyph = cap.glyph }
            return HyperKeyCap(id: cap.id, glyph: glyph,
                               shifted: cap.style == .character ? nil : cap.shifted,
                               symbol: cap.symbol, keyCode: cap.keyCode, style: cap.style,
                               frame: cap.frame, stemFrame: cap.stemFrame)
        }
        return HyperKeyboardLayout(name: name, caps: projected, size: size)
    }

    /// A row entry before geometry: `width` nil takes the row's remainder.
    struct Entry {
        let id: String
        let glyph: String
        var shifted: String? = nil
        var symbol: String? = nil
        let keyCode: UInt32?
        var style: HyperKeyCapStyle = .character
        var width: Double? = HyperKeyboardLayout.keySize
    }

    /// UK ISO MacBook: half-height function row, `§ ±` top-left, `"` on 2, `£`
    /// on 3, `@` on `'`, `\ |` beside Enter, the tall ISO Enter, `` ` ~ ``
    /// beside left shift, inverted-T arrows. Key codes are macOS virtual codes.
    public static let ukISOMacBook: HyperKeyboardLayout = {
        let k = keySize
        let functionRow: [Entry] = [
            Entry(id: "esc", glyph: "esc", keyCode: 53, style: .function, width: nil),
            Entry(id: "F1", glyph: "F1", keyCode: 122, style: .function),
            Entry(id: "F2", glyph: "F2", keyCode: 120, style: .function),
            Entry(id: "F3", glyph: "F3", keyCode: 99, style: .function),
            Entry(id: "F4", glyph: "F4", keyCode: 118, style: .function),
            Entry(id: "F5", glyph: "F5", keyCode: 96, style: .function),
            Entry(id: "F6", glyph: "F6", keyCode: 97, style: .function),
            Entry(id: "F7", glyph: "F7", keyCode: 98, style: .function),
            Entry(id: "F8", glyph: "F8", keyCode: 100, style: .function),
            Entry(id: "F9", glyph: "F9", keyCode: 101, style: .function),
            Entry(id: "F10", glyph: "F10", keyCode: 109, style: .function),
            Entry(id: "F11", glyph: "F11", keyCode: 103, style: .function),
            Entry(id: "F12", glyph: "F12", keyCode: 111, style: .function),
            Entry(id: "touch-id", glyph: "", keyCode: nil, style: .function),
        ]
        let numberRow: [Entry] = [
            Entry(id: "§", glyph: "§", shifted: "±", keyCode: 10),
            Entry(id: "1", glyph: "1", shifted: "!", keyCode: 18),
            Entry(id: "2", glyph: "2", shifted: "\"", keyCode: 19),
            Entry(id: "3", glyph: "3", shifted: "£", keyCode: 20),
            Entry(id: "4", glyph: "4", shifted: "$", keyCode: 21),
            Entry(id: "5", glyph: "5", shifted: "%", keyCode: 23),
            Entry(id: "6", glyph: "6", shifted: "^", keyCode: 22),
            Entry(id: "7", glyph: "7", shifted: "&", keyCode: 26),
            Entry(id: "8", glyph: "8", shifted: "*", keyCode: 28),
            Entry(id: "9", glyph: "9", shifted: "(", keyCode: 25),
            Entry(id: "0", glyph: "0", shifted: ")", keyCode: 29),
            Entry(id: "-", glyph: "-", shifted: "_", keyCode: 27),
            Entry(id: "=", glyph: "=", shifted: "+", keyCode: 24),
            Entry(id: "delete", glyph: "delete", keyCode: 51, style: .modifier, width: nil),
        ]
        let topRow: [Entry] = [
            Entry(id: "tab", glyph: "tab", symbol: "⇥", keyCode: 48, style: .modifier, width: 72.5),
            Entry(id: "Q", glyph: "Q", keyCode: 12), Entry(id: "W", glyph: "W", keyCode: 13),
            Entry(id: "E", glyph: "E", keyCode: 14), Entry(id: "R", glyph: "R", keyCode: 15),
            Entry(id: "T", glyph: "T", keyCode: 17), Entry(id: "Y", glyph: "Y", keyCode: 16),
            Entry(id: "U", glyph: "U", keyCode: 32), Entry(id: "I", glyph: "I", keyCode: 34),
            Entry(id: "O", glyph: "O", keyCode: 31), Entry(id: "P", glyph: "P", keyCode: 35),
            Entry(id: "[", glyph: "[", shifted: "{", keyCode: 33),
            Entry(id: "]", glyph: "]", shifted: "}", keyCode: 30),
            Entry(id: "return", glyph: "↩", keyCode: 36, style: .isoEnter, width: nil),
        ]
        let homeRow: [Entry] = [
            Entry(id: "caps", glyph: "hyper", symbol: "⇪", keyCode: 57, style: .modifier, width: 90),
            Entry(id: "A", glyph: "A", keyCode: 0), Entry(id: "S", glyph: "S", keyCode: 1),
            Entry(id: "D", glyph: "D", keyCode: 2), Entry(id: "F", glyph: "F", keyCode: 3),
            Entry(id: "G", glyph: "G", keyCode: 5), Entry(id: "H", glyph: "H", keyCode: 4),
            Entry(id: "J", glyph: "J", keyCode: 38), Entry(id: "K", glyph: "K", keyCode: 40),
            Entry(id: "L", glyph: "L", keyCode: 37),
            Entry(id: ";", glyph: ";", shifted: ":", keyCode: 41),
            Entry(id: "'", glyph: "'", shifted: "@", keyCode: 39),
            Entry(id: "\\", glyph: "\\", shifted: "|", keyCode: 42),
        ]
        let bottomRow: [Entry] = [
            Entry(id: "shift", glyph: "shift", symbol: "⇧", keyCode: 56, style: .modifier, width: 72.5),
            Entry(id: "`", glyph: "`", shifted: "~", keyCode: 50),
            Entry(id: "Z", glyph: "Z", keyCode: 6), Entry(id: "X", glyph: "X", keyCode: 7),
            Entry(id: "C", glyph: "C", keyCode: 8), Entry(id: "V", glyph: "V", keyCode: 9),
            Entry(id: "B", glyph: "B", keyCode: 11), Entry(id: "N", glyph: "N", keyCode: 45),
            Entry(id: "M", glyph: "M", keyCode: 46),
            Entry(id: ",", glyph: ",", shifted: "<", keyCode: 43),
            Entry(id: ".", glyph: ".", shifted: ">", keyCode: 47),
            Entry(id: "/", glyph: "/", shifted: "?", keyCode: 44),
            Entry(id: "right-shift", glyph: "shift", symbol: "⇧", keyCode: 60, style: .modifier, width: nil),
        ]
        let modifierRow: [Entry] = [
            Entry(id: "fn", glyph: "fn", symbol: "🌐", keyCode: 63, style: .modifier),
            Entry(id: "control", glyph: "control", symbol: "⌃", keyCode: 59, style: .modifier),
            Entry(id: "option", glyph: "option", symbol: "⌥", keyCode: 58, style: .modifier),
            Entry(id: "command", glyph: "command", symbol: "⌘", keyCode: 55, style: .modifier, width: 72.5),
            Entry(id: "space", glyph: "", keyCode: 49, style: .space, width: nil),
            Entry(id: "right-command", glyph: "command", symbol: "⌘", keyCode: 54, style: .modifier, width: 72.5),
            Entry(id: "right-option", glyph: "option", symbol: "⌥", keyCode: 61, style: .modifier),
            Entry(id: "left", glyph: "◀", keyCode: 123, style: .arrow),
            Entry(id: "up-down", glyph: "", keyCode: nil, style: .arrow),
            Entry(id: "right", glyph: "▶", keyCode: 124, style: .arrow),
        ]

        var caps: [HyperKeyCap] = []
        var y = 0.0
        func place(_ row: [Entry], height: Double) -> [HyperKeyCap] {
            let fixed = row.compactMap(\.width).reduce(0, +)
            let gaps = Double(row.count - 1) * gap
            let flexible = width - fixed - gaps
            var x = 0.0
            return row.map { entry in
                let w = entry.width ?? flexible
                defer { x += w + gap }
                return HyperKeyCap(id: entry.id, glyph: entry.glyph, shifted: entry.shifted, symbol: entry.symbol,
                                   keyCode: entry.keyCode, style: entry.style,
                                   frame: CGRect(x: x, y: y, width: w, height: height), stemFrame: nil)
            }
        }
        caps += place(functionRow, height: functionRowHeight)
        y += functionRowHeight + gap
        caps += place(numberRow, height: k)
        y += k + gap
        let top = place(topRow, height: k)
        y += k + gap
        // The home row has no flexible key: it stops where the Enter stem
        // begins, and the stem right-aligns under Enter's wider top part (the
        // ISO shape).
        let home = place(homeRow, height: k)
        let homeEnd = home.last.map { $0.frame.maxX } ?? 0
        let enterTop = top[top.count - 1]
        let stem = CGRect(x: homeEnd + gap, y: y, width: width - homeEnd - gap, height: k)
        caps += top.dropLast()
        caps.append(HyperKeyCap(id: enterTop.id, glyph: enterTop.glyph, shifted: nil, symbol: nil, keyCode: enterTop.keyCode,
                                style: .isoEnter, frame: enterTop.frame, stemFrame: stem))
        caps += home
        y += k + gap
        caps += place(bottomRow, height: k)
        y += k + gap
        var modifiers = place(modifierRow, height: k)
        // Inverted T: the middle arrow column holds ▲ over ▼, each half height.
        if let index = modifiers.firstIndex(where: { $0.id == "up-down" }) {
            let column = modifiers[index].frame
            let half = (column.height - 2) / 2
            modifiers.remove(at: index)
            modifiers.insert(HyperKeyCap(id: "up", glyph: "▲", shifted: nil, symbol: nil, keyCode: 126, style: .arrow,
                                         frame: CGRect(x: column.minX, y: column.minY, width: column.width, height: half), stemFrame: nil), at: index)
            modifiers.insert(HyperKeyCap(id: "down", glyph: "▼", shifted: nil, symbol: nil, keyCode: 125, style: .arrow,
                                         frame: CGRect(x: column.minX, y: column.minY + half + 2, width: column.width, height: half), stemFrame: nil), at: index + 1)
        }
        caps += modifiers
        y += k
        return HyperKeyboardLayout(name: "UK ISO MacBook", caps: caps, size: CGSize(width: width, height: y))
    }()
}
