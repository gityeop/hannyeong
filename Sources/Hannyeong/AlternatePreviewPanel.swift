import AppKit

@MainActor
final class AlternatePreviewPanel {
    private let panel = InputPopupPanel()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let content = InputPopupPanel.content(size: .zero)
    private var wordOrigin: NSPoint?
    private var wordCaretRect: NSRect?
    private var pendingText: String?
    private var presentationTask: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.ignoresMouseEvents = true
        label.textColor = .labelColor
        label.lineBreakMode = .byCharWrapping
        label.setAccessibilityIdentifier("alternate-word-preview")
        label.setAccessibilityLabel("반대 언어 미리보기")
        content.addSubview(label)
        panel.contentView = content
    }

    func show(_ text: String, delay: Duration = .zero, at caretRect: @autoclosure @escaping () -> NSRect) {
        pendingText = text
        guard presentationTask == nil else { return }
        if wordCaretRect == nil, delay > .zero {
            presentationTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: delay) }
                catch { return }
                guard let self, let text = self.pendingText else { return }
                self.presentationTask = nil
                self.show(text, at: caretRect())
            }
            return
        }
        if wordCaretRect == nil {
            let rect = caretRect()
            guard rect.height > 0 else { return }
            wordCaretRect = rect
        }
        let caretRect = wordCaretRect!
        let screen = NSScreen.screens.first { $0.frame.contains(caretRect.origin) }
        let fontSize = CompositionPreviewSettings.alternateSize(in: .standard).fontSize
        let scale = fontSize / 16
        let inset = NSSize(width: round(12 * scale), height: round(8 * scale))
        let maxWidth = min(480 * scale, (screen?.visibleFrame.width ?? 480 * scale) - 24)
        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.stringValue = text
        let bounds = label.cell!.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: maxWidth - inset.width * 2, height: .greatestFiniteMagnitude))
        let size = NSSize(width: max(44 * scale, ceil(bounds.width) + inset.width * 2),
                          height: ceil(bounds.height) + inset.height * 2)
        label.frame = NSRect(x: inset.width, y: inset.height,
                             width: size.width - inset.width * 2, height: size.height - inset.height * 2)
        let origin = Self.origin(for: size, above: caretRect, in: screen?.visibleFrame, previousOrigin: wordOrigin)
        wordOrigin = origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    static func origin(for size: NSSize, above caretRect: NSRect, in screen: NSRect?, previousOrigin: NSPoint? = nil) -> NSPoint {
        var origin = previousOrigin ?? NSPoint(x: caretRect.midX - size.width / 2 + 6, y: caretRect.maxY + 8)
        if let screen {
            origin.x = max(screen.minX, min(origin.x, screen.maxX - size.width))
            origin.y = max(screen.minY, min(origin.y, screen.maxY - size.height))
        }
        return origin
    }

    func hide() {
        presentationTask?.cancel()
        presentationTask = nil
        pendingText = nil
        wordOrigin = nil
        wordCaretRect = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        label.stringValue = ""
    }
}
