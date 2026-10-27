import AppKit

@MainActor
final class InputPopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    static func content(size: NSSize) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        return view
    }

    func position(at caretRect: NSRect) {
        let size = frame.size
        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caretRect.origin) })?.visibleFrame {
            if origin.y < screen.minY { origin.y = caretRect.maxY + 6 }
            origin.x = max(screen.minX, min(origin.x, screen.maxX - size.width))
            origin.y = max(screen.minY, min(origin.y, screen.maxY - size.height))
        }
        setFrameOrigin(origin)
    }
}
