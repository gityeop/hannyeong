import AppKit
import os

@MainActor
final class NoticePanel {
    private let panel = InputPopupPanel()
    private let logger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "Notice")
    private var escapeMonitor: Any?
    var isVisible: Bool { panel.isVisible }

    func show(_ message: String, at caretRect: NSRect?) {
        let width: CGFloat = 220
        let font = NSFont.systemFont(ofSize: 13)
        let messageHeight = ceil((message as NSString).boundingRect(
            with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height)
        let height = messageHeight + 48
        let content = InputPopupPanel.content(size: NSSize(width: width, height: height))
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = font
        label.textColor = .labelColor
        label.frame = NSRect(x: 12, y: 30, width: width - 24, height: messageHeight)
        label.setAccessibilityIdentifier("input-notice-message")
        content.addSubview(label)

        let help = NSTextField(labelWithString: "esc 닫기")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 12, y: 6, width: width - 48, height: 16)
        content.addSubview(help)
        let close = NSButton(title: "×", target: self, action: #selector(hide))
        close.font = .systemFont(ofSize: 16)
        close.isBordered = false
        close.refusesFirstResponder = true
        close.setAccessibilityLabel("안내 닫기")
        close.frame = NSRect(x: width - 30, y: 4, width: 22, height: 20)
        content.addSubview(close)
        panel.contentView = content
        panel.setContentSize(NSSize(width: width, height: height))
        if let caretRect {
            panel.position(at: caretRect)
        } else if let frame = NSScreen.main?.visibleFrame {
            // App startup errors have no input client; keep their existing screen-corner placement.
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - width - 24, y: frame.maxY - 24))
        }
        if escapeMonitor == nil {
            // Terminal handles Escape itself once no marked composition remains.
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.hide() }
            }
        }
        panel.orderFrontRegardless()
        logger.notice("Notice shown; visible=\(self.panel.isVisible) key=\(self.panel.isKeyWindow) width=\(self.panel.frame.width) height=\(self.panel.frame.height)")
    }

    @objc func hide() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        logger.notice("Notice dismissed; visible=\(self.panel.isVisible)")
    }
}
