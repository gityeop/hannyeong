import AppKit
import Carbon

/// Shared by the integrated input method and the standalone Direct prototype.
@MainActor
public final class SecureInputMonitor: NSObject {
    private let sourceID: String
    private let entering: @MainActor () -> Void
    private let restored: @MainActor () -> Void
    private var activePID: pid_t?
    private lazy var sudoPassword: SudoPasswordMonitor = SudoPasswordMonitor { [weak self] in self?.state.check() }
    private lazy var state: DirectSecureInputSource = DirectSecureInputSource(sourceID: sourceID, entering: entering, restored: restored,
        isSecure: { [weak self] in IsSecureEventInputEnabled() || self?.sudoPassword.active == true },
        poll: { [weak self] in
            guard let self else { return }
            self.sudoPassword.refresh(rootPID: self.activePID, needed: self.state.shouldObserveSudo)
        })

    public init(sourceID: String, entering: @escaping @MainActor () -> Void,
                restored: @escaping @MainActor () -> Void = {}) {
        self.sourceID = sourceID
        self.entering = entering
        self.restored = restored
    }

    public func start() {
        activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sourceNotification),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        state.start()
    }

    public func stop() {
        state.stop()
        sudoPassword.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    public func isTemporaryABC(_ source: String) -> Bool { state.isTemporaryABC(source) }
    public func sourceChanged() { state.sourceChanged() }

    @objc private func activated(_ notification: Notification) {
        activePID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        state.check()
    }

    @objc private func sourceNotification() {
        DispatchQueue.main.async { [weak self] in self?.state.sourceChanged() }
    }
}
