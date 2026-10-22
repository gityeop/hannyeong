import AppKit

/// Separate process so AX requests reach AppKit's main run loop, as they do in a real input host.
@main
private struct CommittedSelectionHost {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Hannyeong committed selection QA"
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        view.isRichText = false
        view.string = "새 해 home "
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            print("READY")
            fflush(stdout)
        }
        withExtendedLifetime(window) { app.run() }
    }
}
