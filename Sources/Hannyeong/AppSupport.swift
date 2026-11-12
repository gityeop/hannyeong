import AppKit
import os

@MainActor
final class AppSupport: NSObject {
    static let shared = AppSupport()

    private let logger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "Configuration")
    private lazy var settings = SettingsWindowController()

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    func prepareLaunch(arguments: [String]) {
        installEditingMenu()
        if arguments.contains("--settings") { showSettings() }
        if arguments.contains("--request-accessibility") { CommittedTextSelection.requestAccess() }
        prepareLocalModel()
    }

    private func prepareLocalModel() {
        Task { @MainActor in
            do {
                let local = try LocalModelService.client()
                _ = try await local.prepare()
            } catch {
                reportConfigurationError(error)
            }
        }
    }

    func showSettings() {
        logger.notice("Settings presentation requested")
        installEditingMenu()
        present(settings)
        if let window = settings.window {
            logger.notice("Settings presentation completed; visible=\(window.isVisible) minimized=\(window.isMiniaturized) key=\(window.isKeyWindow) window=\(window.windowNumber)")
        }
    }

    func present(_ controller: NSWindowController) {
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, !(closing is NSPanel) else { return }
        let hasWindow = NSApp.windows.contains {
            $0 !== closing && !($0 is NSPanel) && ($0.isVisible || $0.isMiniaturized)
        }
        if !hasWindow { NSApp.setActivationPolicy(.accessory) }
    }

    func reportConfigurationError(_ error: Error) {
        let failure = error as NSError
        logger.error("Configuration operation failed; domain=\(failure.domain, privacy: .public) code=\(failure.code) detail=\(error.localizedDescription, privacy: .private)")
    }

    private func installEditingMenu() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "한녕", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "한녕")
        appMenu.addItem(NSMenuItem(title: "한녕 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem(title: "파일", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "파일")
        let closeItem = NSMenuItem(title: "창 닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.target = nil
        closeItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(closeItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "편집")
        let commands: [(String, Selector, String)] = [
            ("잘라내기", #selector(NSText.cut(_:)), "x"),
            ("복사", #selector(NSText.copy(_:)), "c"),
            ("붙여넣기", #selector(NSText.paste(_:)), "v"),
            ("전체 선택", #selector(NSText.selectAll(_:)), "a")
        ]
        for (title, action, key) in commands {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = nil
            item.keyEquivalentModifierMask = .command
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

}
