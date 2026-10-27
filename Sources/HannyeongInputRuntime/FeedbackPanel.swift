import AppKit
import HannyeongCore

@MainActor
private final class FeedbackButton: NSButton {
    var number: Int?
    var candidate = ""
    var selected = false

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = selected || isHighlighted
        if highlighted {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if let number {
            let badge = NSAttributedString(string: String(number), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: highlighted ? NSColor.white : NSColor.secondaryLabelColor])
            badge.draw(at: NSPoint(x: 9, y: (bounds.height - badge.size().height) / 2))
            let text = NSAttributedString(string: candidate, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: highlighted ? NSColor.white : NSColor.labelColor])
            text.draw(at: NSPoint(x: 30, y: (bounds.height - text.size().height) / 2))
        } else {
            let text = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor])
            text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2,
                                 y: (bounds.height - text.size().height) / 2))
        }
    }
}

@MainActor
final class FeedbackPanel {
    // Reuses the original Hannyeong candidate UI in this separate prototype target.
    private let pageSize = 9
    private let panel = InputPopupPanel()
    private var candidates: [String] = []
    private var scope: CorrectionScope = .context
    private var selectedIndex = 0
    private var caretRect = NSRect.zero
    private var onSelect: ((Int) -> Void)?

    func contains(_ event: CGEvent) -> Bool {
        let desktopTop = NSScreen.screens.first!.frame.maxY
        return panel.frame.contains(NSPoint(x: event.location.x, y: desktopTop - event.location.y))
    }

    func handle(code: Int64, text: String) -> Bool {
        if let number = Int(text), (1...9).contains(number) { _ = selectNumber(number); return true }
        switch code {
        case 36, 76: chooseSelected()
        case 125: moveSelection(1)
        case 126: moveSelection(-1)
        case 124, 121: page(1)
        case 123, 116: page(-1)
        default: return false
        }
        return true
    }

    func show(candidates: [String], scope: CorrectionScope, at caretRect: NSRect,
              onSelect: @escaping (Int) -> Void) {
        self.candidates = candidates
        self.scope = scope
        self.caretRect = caretRect
        self.onSelect = onSelect
        selectedIndex = 0
        render()
        panel.orderFrontRegardless()
    }

    func updateScope(_ scope: CorrectionScope) {
        self.scope = scope
        render()
    }

    func hide() {
        panel.orderOut(nil)
        onSelect = nil
        candidates.removeAll()
        selectedIndex = 0
    }

    @discardableResult
    func selectNumber(_ number: Int) -> Bool {
        guard (1...pageSize).contains(number) else { return false }
        let index = (selectedIndex / pageSize) * pageSize + number - 1
        guard candidates.indices.contains(index) else { return false }
        selectedIndex = index
        onSelect?(index)
        return true
    }

    func moveSelection(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), candidates.count - 1)
        render()
    }

    func page(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        let nextPage = min(max(0, selectedIndex / pageSize + delta), (candidates.count - 1) / pageSize)
        selectedIndex = min(nextPage * pageSize + selectedIndex % pageSize, candidates.count - 1)
        render()
    }

    func chooseSelected() {
        guard candidates.indices.contains(selectedIndex) else { return }
        onSelect?(selectedIndex)
    }

    private func render() {
        let start = (selectedIndex / pageSize) * pageSize
        let count = min(pageSize, candidates.count - start)
        let width: CGFloat = 220
        let pages = max(1, (candidates.count + pageSize - 1) / pageSize)
        let headerHeight: CGFloat = scope == .always ? 30 : 6
        let footerHeight: CGFloat = pages > 1 ? 46 : 24
        let height = headerHeight + CGFloat(count) * 30 + footerHeight + 6
        let content = InputPopupPanel.content(size: NSSize(width: width, height: height))
        if scope == .always {
            let scopeLabel = NSTextField(labelWithString: "항상 기억")
            scopeLabel.font = .systemFont(ofSize: 10)
            scopeLabel.textColor = .secondaryLabelColor
            scopeLabel.alignment = .right
            scopeLabel.frame = NSRect(x: 112, y: height - 23, width: width - 124, height: 16)
            content.addSubview(scopeLabel)
        }
        for offset in 0..<count {
            let index = start + offset
            let button = makeButton("\(offset + 1). \(candidates[index])", action: #selector(selectCandidate(_:)))
            button.tag = index
            button.number = offset + 1
            button.candidate = candidates[index]
            button.selected = index == selectedIndex
            button.setAccessibilityLabel(button.title)
            button.frame = NSRect(x: 6, y: height - headerHeight - CGFloat(offset + 1) * 30, width: width - 12, height: 30)
            content.addSubview(button)
        }
        let help = NSTextField(labelWithString: "↑↓ 이동 · ↵ 선택 · esc 취소")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 12, y: pages > 1 ? 27 : 6, width: width - 24, height: 16)
        content.addSubview(help)
        if pages > 1 {
            let previous = makeButton("‹", action: #selector(previousPage(_:)))
            previous.frame = NSRect(x: width / 2 - 48, y: 4, width: 24, height: 20)
            previous.isEnabled = start > 0
            content.addSubview(previous)
            let next = makeButton("›", action: #selector(nextPage(_:)))
            next.frame = NSRect(x: width / 2 + 24, y: 4, width: 24, height: 20)
            next.isEnabled = selectedIndex / pageSize + 1 < pages
            content.addSubview(next)
            let pageLabel = NSTextField(labelWithString: "\(selectedIndex / pageSize + 1) / \(pages)")
            pageLabel.alignment = .center
            pageLabel.font = .systemFont(ofSize: 10)
            pageLabel.textColor = .secondaryLabelColor
            pageLabel.frame = NSRect(x: width / 2 - 24, y: 7, width: 48, height: 14)
            content.addSubview(pageLabel)
        }
        panel.contentView = content
        panel.setContentSize(NSSize(width: width, height: height))
        position()
    }

    private func makeButton(_ title: String, action: Selector) -> FeedbackButton {
        let button = FeedbackButton(title: title, target: self, action: action)
        button.isBordered = false
        button.refusesFirstResponder = true
        return button
    }

    private func position() {
        panel.position(at: caretRect)
    }

    @objc private func selectCandidate(_ sender: NSButton) {
        selectedIndex = sender.tag
        onSelect?(selectedIndex)
    }

    @objc private func previousPage(_ sender: NSButton) { page(-1) }
    @objc private func nextPage(_ sender: NSButton) { page(1) }
}
