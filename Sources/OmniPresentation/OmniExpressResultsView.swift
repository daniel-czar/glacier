import AppKit

/// A disposable, grouped result surface. It holds no history or clipboard
/// state; the session owns the current revision and selected option.
@MainActor
public final class OmniExpressResultsView: NSView {
    public override var isFlipped: Bool { true }
    public var onSelect: ((Int) -> Void)?
    public private(set) var rowViews: [OmniExpressOptionRow] = []
    public private(set) var contentHeight: CGFloat = 0

    private var options: [ExpressOption] = []
    private var headings: [NSTextField] = []

    public func display(options: [ExpressOption], selectedIndex: Int?, dimmed: Bool) {
        if self.options != options {
            self.options = options
            rebuild()
        }
        for (index, row) in rowViews.enumerated() {
            row.setAppearance(selected: selectedIndex == index, dimmed: dimmed)
        }
        for heading in headings {
            heading.alphaValue = dimmed ? 0.42 : 1
        }
        arrange(width: max(1, bounds.width))
    }

    public func arrange(width: CGFloat) {
        var y: CGFloat = 10
        for group in [ExpressOption.Group.close, .broader] {
            guard let heading = headings.first(where: { $0.identifier?.rawValue == group.rawValue }) else { continue }
            if group == .broader { y += 9 }
            heading.frame = NSRect(x: 8, y: y, width: max(1, width - 16), height: 16)
            y += 20
            for row in rowViews where row.option.group == group {
                let rowHeight = row.measuredHeight(width: width)
                row.frame = NSRect(x: 0, y: y, width: width, height: rowHeight)
                row.arrange()
                y += rowHeight
            }
        }
        contentHeight = y + 8
        frame.size = NSSize(width: width, height: contentHeight)
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        rowViews = []
        headings = []
        for group in [ExpressOption.Group.close, .broader] where options.contains(where: { $0.group == group }) {
            let heading = NSTextField(labelWithString: group == .close ? "CLOSE ALTERNATIVES" : "BROADER OPTIONS")
            heading.identifier = NSUserInterfaceItemIdentifier(group.rawValue)
            heading.font = .systemFont(ofSize: 10.5, weight: .semibold)
            heading.textColor = OmniFrostedStyle.secondaryInk
            heading.setAccessibilityIdentifier("omni.express.group.\(group.rawValue)")
            addSubview(heading)
            headings.append(heading)
        }
        for (index, option) in options.enumerated() {
            let row = OmniExpressOptionRow(option: option)
            row.setAccessibilityIdentifier("omni.express.row.\(index)")
            row.onSelect = { [weak self] in self?.onSelect?(index) }
            addSubview(row)
            rowViews.append(row)
        }
    }
}

@MainActor
public final class OmniExpressOptionRow: NSView {
    public override var isFlipped: Bool { true }
    public let option: ExpressOption
    public var onSelect: (() -> Void)?
    public let phraseLabel = NSTextField(wrappingLabelWithString: "")
    public let cueLabel = NSTextField(wrappingLabelWithString: "")

    public init(option: ExpressOption) {
        self.option = option
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        phraseLabel.stringValue = option.phrase
        phraseLabel.font = .systemFont(ofSize: 15, weight: .medium)
        phraseLabel.textColor = OmniFrostedStyle.ink
        phraseLabel.lineBreakMode = .byWordWrapping
        cueLabel.stringValue = option.cue
        cueLabel.font = .systemFont(ofSize: 11.5)
        cueLabel.textColor = OmniFrostedStyle.secondaryInk
        cueLabel.lineBreakMode = .byWordWrapping
        addSubview(phraseLabel)
        addSubview(cueLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([option.phrase, option.cue].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func mouseDown(with event: NSEvent) { onSelect?() }

    public func setAppearance(selected: Bool, dimmed: Bool) {
        layer?.backgroundColor = selected ? OmniFrostedStyle.selectedFill.cgColor : NSColor.clear.cgColor
        alphaValue = dimmed ? 0.42 : 1
        setAccessibilityValue(selected ? "Selected" : "")
    }

    public func arrange() {
        let textWidth = max(1, bounds.width - 24)
        let phraseHeight = measuredTextHeight(phraseLabel, width: textWidth)
        phraseLabel.frame = NSRect(x: 12, y: 7, width: textWidth, height: phraseHeight)
        cueLabel.frame = NSRect(x: 12, y: 10 + phraseHeight, width: textWidth,
                                height: option.cue.isEmpty ? 0 : measuredTextHeight(cueLabel, width: textWidth))
    }

    public func measuredHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - 24)
        let phraseHeight = measuredTextHeight(phraseLabel, width: textWidth)
        let cueHeight = option.cue.isEmpty ? 0 : measuredTextHeight(cueLabel, width: textWidth)
        return 15 + phraseHeight + (option.cue.isEmpty ? 0 : 3 + cueHeight)
    }

    private func measuredTextHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        max(label.font?.pointSize ?? 12, ceil(label.sizeThatFits(NSSize(width: width, height: 2_000)).height))
    }
}
