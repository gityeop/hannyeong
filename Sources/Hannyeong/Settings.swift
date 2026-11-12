import AppKit
import HannyeongInputRuntime
import SwiftUI

@MainActor
final class SettingsWindowActivity: ObservableObject {
    @Published var isVisible = false
    @Published var hasAccessibility = CommittedTextSelection.isTrusted
    @Published var hasKeyboardAccess = TypingEngine.hasKeyboardAccess
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private lazy var corrections = CorrectionsViewController()
    private let activity = SettingsWindowActivity()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 950, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "한녕 설정"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 850, height: 650)
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView(
            corrections: corrections, windowActivity: activity
        ))
        window.setContentSize(NSSize(width: 950, height: 700))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not use a storyboard")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updateActivity()
        updatePermissions()
        if corrections.isViewLoaded { corrections.reload() }
    }

    func windowDidBecomeKey(_ notification: Notification) { updatePermissions() }
    func windowWillClose(_ notification: Notification) { activity.isVisible = false }
    func windowDidMiniaturize(_ notification: Notification) { updateActivity() }
    func windowDidDeminiaturize(_ notification: Notification) { updateActivity() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateActivity() }

    private func updateActivity() {
        activity.isVisible = window?.isVisible == true && window?.isMiniaturized == false && !NSApp.isHidden
    }

    private func updatePermissions() {
        activity.hasAccessibility = CommittedTextSelection.isTrusted
        activity.hasKeyboardAccess = TypingEngine.hasKeyboardAccess
        NativeInputEngine.shared.refreshPermissions()
    }
}
