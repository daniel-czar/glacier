import AppKit

/// Typesets the CLI's structured values in one native selectable text surface.
/// Tabs keep the short accent column fixed and the source at the trailing edge;
/// crowded rows put the source on its own trailing line instead of colliding.
@MainActor
enum OmniPronunciationResultRenderer {
    static func attributed(_ result: OmniPronunciationPresentation, width: CGFloat) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let dim = OmniFrostedStyle.secondaryInk
        let sourceFont = NSFont.systemFont(ofSize: 12)
        let tagFont = NSFont.systemFont(ofSize: 13)
        let valueFont = NSFont.systemFont(ofSize: 23, weight: .medium)
        let accentFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        // The CLI can also return full accent names (Canada, Australia). Keep
        // one shared column wide enough for them so a tab never skips to the
        // trailing source stop. GA/UK-only results retain the reference width.
        let accentColumn = max(38, (result.transcriptions.map {
            NSAttributedString(string: $0.accent, attributes: [.font: accentFont, .kern: 0.6]).size().width
        }.max() ?? 0).rounded(.up) + 12)

        func row(accent: String, value: String, tag: String?, source: String, miss: Bool = false) {
            let font = miss ? NSFont.systemFont(ofSize: 15) : valueFont
            let valueWidth = (value as NSString).size(withAttributes: [.font: font]).width
            let tagText = tag.map { "  " + $0 } ?? ""
            let tagWidth = (tagText as NSString).size(withAttributes: [.font: tagFont]).width
            let sourceWidth = (source as NSString).size(withAttributes: [.font: sourceFont]).width
            let separateSource = accentColumn + valueWidth + tagWidth + 12 + sourceWidth > width
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: accentColumn),
                                  NSTextTab(textAlignment: .right, location: max(accentColumn + 1, width - 1))]
            paragraph.headIndent = accentColumn
            paragraph.paragraphSpacing = separateSource ? 2 : 8
            paragraph.lineSpacing = 3
            let line = NSMutableAttributedString(string: accent + "\t", attributes: [
                .font: accentFont, .foregroundColor: dim, .kern: 0.6
            ])
            line.append(NSAttributedString(string: value, attributes: [
                .font: font, .foregroundColor: miss ? dim : OmniFrostedStyle.ink
            ]))
            line.append(NSAttributedString(string: tagText, attributes: [.font: tagFont, .foregroundColor: dim]))
            if !separateSource {
                line.append(NSAttributedString(string: "\t" + source, attributes: [.font: sourceFont, .foregroundColor: dim]))
            }
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            output.append(line)
            if separateSource {
                let trailing = NSMutableParagraphStyle()
                trailing.alignment = .right
                trailing.paragraphSpacing = 8
                output.append(NSAttributedString(string: source + "\n", attributes: [
                    .font: sourceFont, .foregroundColor: dim, .paragraphStyle: trailing
                ]))
            }
        }

        if result.transcriptions.isEmpty {
            row(accent: "—", value: "no transcription", tag: nil,
                source: result.sourcesTried.joined(separator: " · "), miss: true)
        } else {
            for transcription in result.transcriptions {
                row(accent: transcription.accent, value: transcription.ipa,
                    tag: transcription.tag, source: transcription.source)
            }
        }
        if let attribution = result.attribution {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = 4
            paragraph.lineSpacing = 3
            let attributes: [NSAttributedString.Key: Any] = [
                .font: tagFont, .foregroundColor: dim, .paragraphStyle: paragraph
            ]
            let symbol = NSTextAttachment()
            symbol.image = NSImage(systemSymbolName: attribution.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [dim]))
            symbol.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            let line = NSMutableAttributedString(attachment: symbol)
            line.append(NSAttributedString(string: "  " + attribution.text, attributes: attributes))
            if let source = attribution.sourceLabel {
                if !attribution.text.isEmpty { line.append(NSAttributedString(string: " · ", attributes: attributes)) }
                let link = NSMutableAttributedString(string: source, attributes: attributes)
                if let url = attribution.sourceURL { link.addAttribute(.link, value: url, range: NSRange(location: 0, length: link.length)) }
                line.append(link)
            }
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            output.append(line)
        } else if output.length > 0 {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }
}

/// Individually accessible sources keep a failure's tooltip on that source.
/// The footer can wrap these tokens on a narrow display without hiding a failure.
@MainActor
final class OmniPronunciationSourceRoute: NSView {
    private(set) var sourceLabels: [NSTextField] = []
    private var labels: [NSTextField] = []

    func setSources(_ sources: [OmniPronunciationPresentation.Source]) {
        subviews.forEach { $0.removeFromSuperview() }
        sourceLabels = []
        labels = []
        if sources.isEmpty {
            let fallback = NSTextField(labelWithString: "Sources")
            fallback.font = .systemFont(ofSize: 13)
            fallback.textColor = OmniFrostedStyle.secondaryInk
            labels.append(fallback)
        }
        for (index, source) in sources.enumerated() {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.textColor = OmniFrostedStyle.secondaryInk
            let text = NSMutableAttributedString(string: index == 0 ? "" : "·  ", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk
            ])
            if source.failureReason != nil {
                text.append(NSAttributedString(string: "● ", attributes: [
                    .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.systemRed, .baselineOffset: 2
                ]))
            }
            text.append(NSAttributedString(string: source.name, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: OmniFrostedStyle.secondaryInk
            ]))
            label.allowsEditingTextAttributes = true
            label.attributedStringValue = text
            // A source is one wrapping unit. NSTextField otherwise wraps its
            // name after the separator into a clipped second line.
            label.lineBreakMode = .byClipping
            label.cell?.wraps = false
            label.cell?.isScrollable = true
            label.toolTip = source.failureReason
            label.setAccessibilityLabel(source.name + (source.failureReason.map { ": " + $0 } ?? ""))
            sourceLabels.append(label)
            labels.append(label)
        }
        labels.forEach { addSubview($0) }
    }

    var fittingWidth: CGFloat { labels.reduce(0) { $0 + ceil($1.attributedStringValue.size().width) + 10 } - 6 }

    @discardableResult
    func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0
        var row: CGFloat = 0
        var frames: [NSRect] = []
        for label in labels {
            let labelWidth = min(width, ceil(label.attributedStringValue.size().width) + 4)
            if x > 0, x + labelWidth > width { x = 0; row += 20 }
            frames.append(NSRect(x: x, y: row, width: labelWidth, height: 18))
            x += labelWidth + 6
        }
        let height = row + 18
        if apply {
            for (label, frame) in zip(labels, frames) {
                label.frame = NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
            }
        }
        return height
    }
}
