import AppKit
import Carbon
import HannyeongInputRuntime
import os

@MainActor
final class SecureInputSource: NSObject, NSMenuDelegate {
    static let shared = SecureInputSource()

    private enum Presentation {
        case hidden
        case pending(Timer)
        case visible(NSStatusItem)
        case awaitingSelection(NSStatusItem)

        var statusItem: NSStatusItem? {
            switch self {
            case .visible(let item), .awaitingSelection(let item): return item
            case .hidden, .pending: return nil
            }
        }
    }

    private static let sourceID = "com.yeop.inputmethod.Hannyeong"
    private let logger = Logger(subsystem: SecureInputSource.sourceID, category: "SecureInputRecovery")
    private var presentation = Presentation.hidden
    private lazy var monitor = SecureInputMonitor(sourceID: Self.sourceID,
        entering: { [weak self] in self?.beginRecovery() },
        restored: { NativeInputEngine.shared.resumeAfterSecureInput() },
        ownedEpisodeEnded: { [weak self] restored in self?.endEpisode(restored: restored) })

    func start() {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sourceNotification),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        monitor.start()
    }

    func stop() {
        monitor.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        dismiss()
    }

    private func beginRecovery() {
        NativeInputEngine.shared.reset()
        switch presentation {
        case .hidden:
            let timer = Timer(timeInterval: 5, target: self, selector: #selector(showRecovery), userInfo: nil,
                              repeats: false)
            presentation = .pending(timer)
            RunLoop.main.add(timer, forMode: .common)
        case .awaitingSelection(let item):
            presentation = .visible(item)
        case .pending, .visible:
            break
        }
    }

    private func endEpisode(restored: Bool) {
        if !restored, let item = presentation.statusItem {
            presentation = .awaitingSelection(item)
        } else {
            dismiss()
        }
    }

    @objc private func showRecovery() {
        guard case .pending = presentation else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "한녕"
        item.button?.setAccessibilityLabel("한녕 입력 복구")
        item.button?.toolTip = "한녕 입력 복구"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(menuItem("한녕 입력 복구"))
        item.menu = menu
        presentation = .visible(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if monitor.isSecureInputActive {
            menu.addItem(menuItem("보안 입력이 켜져 있습니다."))
            menu.addItem(menuItem("암호 입력을 마치거나 입력란을 벗어나세요."))
            menu.addItem(menuItem("계속되면 작업을 저장하고 암호 입력에 사용한 앱을 종료하세요."))
            menu.addItem(.separator())
            menu.addItem(menuItem("상태 다시 확인", action: #selector(reselect)))
        } else {
            menu.addItem(menuItem("보안 입력이 끝났습니다."))
            menu.addItem(menuItem("한녕 다시 켜기", action: #selector(reselect)))
            if case .awaitingSelection = presentation {
                menu.addItem(menuItem("안내 닫기", action: #selector(dismissAfterEpisode)))
            }
        }
    }

    private func menuItem(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        return item
    }

    @objc func reselect() {
        do {
            guard try monitor.requestReselection() else {
                AppSupport.shared.showError("보안 입력이 아직 켜져 있습니다. 암호 입력을 마치거나 입력란을 벗어나세요.")
                return
            }
            if TypingEngine.currentSourceID == Self.sourceID {
                NativeInputEngine.shared.resumeAfterSecureInput(retrying: true)
            }
            dismissIfSelected()
        } catch {
            logger.error("Input source recovery failed: \(String(describing: error), privacy: .public)")
            AppSupport.shared.showError("한녕으로 전환하지 못했습니다. 입력 메뉴에서 한녕을 선택해 주세요.")
        }
    }

    @objc private func sourceNotification() {
        DispatchQueue.main.async { [weak self] in self?.dismissIfSelected() }
    }

    private func dismissIfSelected() {
        guard case .awaitingSelection = presentation, !monitor.isSecureInputActive,
              TypingEngine.currentSourceID == Self.sourceID else { return }
        dismiss()
    }

    @objc private func dismissAfterEpisode() {
        guard case .awaitingSelection = presentation else { return }
        dismiss()
    }

    private func dismiss() {
        if case .pending(let timer) = presentation { timer.invalidate() }
        if let item = presentation.statusItem { NSStatusBar.system.removeStatusItem(item) }
        presentation = .hidden
    }
}
