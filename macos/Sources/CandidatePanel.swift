import AppKit
import QuartzCore
import CoreText

private final class CandidateContent: NSView {
    override var isFlipped: Bool { true }
}

final class CandidateCell: NSButton {
    var word = ""
    var ordinal = ""
    var gloss = ""
    var isCurrentCandidate = false
    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    // Centre the actual glyph ink, rather than a guessed line-height rectangle.
    // CoreText's baseline bounds differ for Chinese, Latin text and small digits.
    private func drawText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, rect.width, .end, ellipsis) ?? ellipsis
        }
        let ink = CTLineGetImageBounds(line, nil)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 16)
        let numberFont = NSFont.systemFont(ofSize: 9)
        let numberWidth = ordinal.isEmpty ? 0 : (ordinal as NSString).size(withAttributes: [.font: numberFont]).width
        let gap: CGFloat = ordinal.isEmpty ? 0 : 5
        let wordWidth = min(bounds.width - numberWidth - gap - 14,
                            (word as NSString).size(withAttributes: [.font: font]).width)
        let groupWidth = wordWidth + numberWidth + gap
        let left = (bounds.width - groupWidth) / 2
        let rowHeight = min(28, bounds.height)
        if isCurrentCandidate {
            NSColor.systemBlue.setFill()
            let pillWidth = min(bounds.width - 2, groupWidth + 16)
            let pillHeight = rowHeight - 2
            let pill = NSRect(x: (bounds.width - pillWidth) / 2, y: (rowHeight - pillHeight) / 2,
                              width: pillWidth, height: pillHeight)
            NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
        }
        let color: NSColor = isCurrentCandidate ? .white : .labelColor
        let secondary: NSColor = isCurrentCandidate ? .white : .secondaryLabelColor
        drawText(word, font: font, color: color,
                 in: NSRect(x: left + numberWidth + gap, y: 0, width: wordWidth, height: rowHeight))
        if !ordinal.isEmpty {
            drawText(ordinal, font: numberFont, color: secondary,
                     in: NSRect(x: left, y: 0, width: numberWidth, height: rowHeight))
        }
        if !gloss.isEmpty {
            drawText(gloss, font: .systemFont(ofSize: 10), color: .secondaryLabelColor,
                     in: NSRect(x: 8, y: 29, width: bounds.width - 16, height: 17))
        }
    }
}

// Persistent, nonactivating candidate window. Compact and expanded layouts
// share the same window and top edge, so expansion can animate continuously.
final class CandidatePanel: NSPanel {
    let candidateContentView: NSView = CandidateContent()
    private var cells: [CandidateCell] = []
    private var rowDividers: [NSBox] = []
    private let expandButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let settingsButton = NSButton()
    private let footer = NSTextField(labelWithString: "")
    private let divider = NSBox()
    private var lastExpanded = false
    var onSelect: ((Int) -> Void)?
    var onToggleExpand: (() -> Void)?
    var onPage: ((Int) -> Void)?
    var onSettings: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 14
            glass.contentView = candidateContentView
            background = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 14
            material.layer?.masksToBounds = true
            material.addSubview(candidateContentView)
            background = material
        }
        contentView = background
        candidateContentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            candidateContentView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            candidateContentView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            candidateContentView.topAnchor.constraint(equalTo: background.topAnchor),
            candidateContentView.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        for (button, symbol, label, action) in [
            (expandButton, "chevron.down", "展开或收起候选词", #selector(toggleExpansion)),
            (previousButton, "chevron.left", "上一页", #selector(previousPage)),
            (nextButton, "chevron.right", "下一页", #selector(nextPage)),
            (settingsButton, "gearshape", "设置", #selector(openSettings))
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            candidateContentView.addSubview(button)
        }
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        candidateContentView.addSubview(footer)
        divider.boxType = .separator
        candidateContentView.addSubview(divider)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(composition: Composition, caret: NSRect) {
        guard !composition.raw.isEmpty, !composition.visibleCandidates.isEmpty else {
            if !composition.awaitingCandidates || composition.raw.isEmpty { orderOut(nil) }
            return
        }
        let words = composition.visibleCandidates
        while cells.count < words.count {
            let cell = CandidateCell()
            cell.isBordered = false
            cell.target = self
            cell.action = #selector(selectCandidate(_:))
            candidateContentView.addSubview(cell)
            cells.append(cell)
        }
        let glossary = composition.preferences.showGlossary ? PreferencesStore.shared.glossary.entries : [:]
        let hasGlosses = words.contains { glossary[$0.text] != nil }
        let rowHeight: CGFloat = hasGlosses ? 48 : 24
        let lowerRowHeight: CGFloat = hasGlosses ? 48 : 28
        let topCount = min(composition.pageSize, words.count)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let font = NSFont.systemFont(ofSize: 16)
        var widths = words.prefix(topCount).map { min(180, max(40, ($0.text as NSString).size(withAttributes: [.font: font]).width + 29)) }
        let available = max(200, bounds.width - 32)
        let sum = widths.reduce(0, +)
        let width = min(available, max(composition.expanded ? 360 : 0, sum + 33))
        if sum + 33 > width { widths = widths.map { $0 * (width - 33) / sum } }
        let lowerCount = max(0, words.count - topCount)
        let lowerRows = composition.expanded ? (lowerCount + composition.gridColumns - 1) / composition.gridColumns : 0
        let height = rowHeight + lowerRowHeight * CGFloat(lowerRows) + 4 + (composition.expanded ? 34 : 0)
        for (index, cell) in cells.enumerated() {
            cell.isHidden = index >= words.count
            guard index < words.count else { continue }
            if index < topCount {
                cell.frame = NSRect(x: 3 + widths.prefix(index).reduce(0, +), y: 2, width: widths[index], height: rowHeight)
            } else {
                let lower = index - topCount
                let column = lower % composition.gridColumns, row = lower / composition.gridColumns
                let cellWidth = (width - 10) / CGFloat(composition.gridColumns)
                cell.frame = NSRect(x: 5 + CGFloat(column) * cellWidth, y: rowHeight + lowerRowHeight * CGFloat(row) + 2,
                                    width: cellWidth, height: lowerRowHeight)
            }
            cell.word = words[index].text
            let numbered = composition.numberedCandidateRange
            cell.ordinal = numbered.contains(index) ? String((index - numbered.lowerBound + 1) % 10) : ""
            cell.gloss = glossary[cell.word] ?? ""
            cell.isCurrentCandidate = index == composition.selectedVisibleIndex
            cell.tag = index
            cell.isEnabled = !composition.awaitingCandidates
            cell.setAccessibilityLabel("\(cell.ordinal) \(cell.word) \(cell.gloss)")
            cell.needsDisplay = true
        }
        while rowDividers.count < lowerRows {
            let line = NSBox()
            line.boxType = .separator
            candidateContentView.addSubview(line)
            rowDividers.append(line)
        }
        for (index, line) in rowDividers.enumerated() {
            line.isHidden = index >= lowerRows
            line.frame = NSRect(x: 0, y: rowHeight + lowerRowHeight * CGFloat(index) + 2, width: width, height: 1)
        }
        expandButton.image = NSImage(systemSymbolName: composition.expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        expandButton.frame = NSRect(x: width - 30, y: 2, width: 24, height: 24)
        for view in [previousButton, nextButton, settingsButton, footer, divider] as [NSView] { view.isHidden = !composition.expanded }
        let footY = height - 29
        divider.frame = NSRect(x: 8, y: height - 34, width: width - 16, height: 1)
        previousButton.frame = NSRect(x: width / 2 - 60, y: footY, width: 24, height: 24)
        footer.frame = NSRect(x: width / 2 - 30, y: footY + 5, width: 60, height: 17)
        nextButton.frame = NSRect(x: width / 2 + 36, y: footY, width: 24, height: 24)
        settingsButton.frame = NSRect(x: width - 36, y: footY, width: 24, height: 24)
        let pageCount = max(1, (composition.candidates.count + composition.displayPageSize - 1) / composition.displayPageSize)
        footer.stringValue = "\(composition.page + 1) / \(pageCount)"
        previousButton.isEnabled = composition.page > 0
        nextButton.isEnabled = composition.page + 1 < pageCount
        let x = max(bounds.minX, min(caret.minX, bounds.maxX - width))
        var y = caret.minY - height - 5
        if y < bounds.minY { y = min(caret.maxY + 5, bounds.maxY - height) }
        let next = NSRect(x: x, y: y, width: width, height: height)
        let animate = isVisible && lastExpanded != composition.expanded && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lastExpanded = composition.expanded
        if frame != next {
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    animator().setFrame(next, display: true)
                }
            } else { setFrame(next, display: false) }
        }
        if !isVisible { orderFrontRegardless() }
    }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= 1 { onPage?(event.scrollingDeltaY > 0 ? -1 : 1) }
    }
    @objc private func selectCandidate(_ sender: NSButton) { onSelect?(sender.tag) }
    @objc private func toggleExpansion() { onToggleExpand?() }
    @objc private func previousPage() { onPage?(-1) }
    @objc private func nextPage() { onPage?(1) }
    @objc private func openSettings() { onSettings?() }
}

func inputKey(for event: NSEvent, composition: Composition) -> InputKey? {
    guard event.type == .keyDown else { return nil }
    if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return .shortcut }
    switch event.keyCode {
    case 49: return .space
    case 51: return .backspace
    case 53: return .escape
    case 36, 76: return .enter
    case 116: return .page(-1)
    case 121: return .page(1)
    case 126: return .arrow(0, -1)
    case 125: return .arrow(0, 1)
    case 123: return .arrow(-1, 0)
    case 124: return .arrow(1, 0)
    case 115, 119, 117: return .shortcut
    default: break
    }
    guard let text = event.characters, !text.isEmpty else { return nil }
    if !composition.raw.isEmpty {
        if text == "-" || text == "[" { return .page(-1) }
        if text == "=" || text == "]" { return .page(1) }
    }
    if let scalar = text.unicodeScalars.first, text.count == 1,
       (65...90).contains(scalar.value) {
        if composition.raw.isEmpty && event.modifierFlags.contains(.shift) { return .text(text) }
        return .text(text.lowercased())
    }
    if text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return .shortcut }
    return .text(text)
}
