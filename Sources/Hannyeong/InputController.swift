import AppKit
import InputMethodKit
import HannyeongCore
import os

@MainActor
@objc(HannyeongInputController)
final class InputController: IMKInputController {
    private var session: CompositionSession?
    private var feedbackWindow: FeedbackPanel?
    private var alternatePreview: AlternatePreviewPanel?
    private var previewHostBundleID: String?
    private var feedbackCandidates: [Candidate] = []
    private var feedbackScope: CorrectionScope = .context
    private let feedbackLogger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "Feedback")
    private let shortcutLogger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "Shortcuts")
    private lazy var rightCommand = RightCommandGesture { [weak self] action in
        guard let self else { return }
        self.logCommandAction(action == .toggleLanguage ? "right_command_single" : "right_command_double")
        NotificationCenter.default.post(name: RightCommandGesture.actionNotification, object: action)
        switch action {
        case .toggleLanguage:
            self.closeFeedback()
            self.session?.toggleLanguage()
            self.shortcutLogger.notice("Right Command single tap handled")
        case .correction:
            self.showFeedback(scope: .context, completePending: true)
            self.shortcutLogger.notice("Right Command double tap handled")
        }
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        guard let client = inputClient as? any IMKTextInput else {
            reportError("입력 클라이언트가 IMKTextInput을 제공하지 않습니다. 입력란을 다시 선택해 주세요.")
            return nil
        }
        // The client already exists at initialization; its first key may precede activation.
        prepareSession(for: client)
        shortcutLogger.notice("Input controller initialized; id=\(String(describing: ObjectIdentifier(self)), privacy: .public) client=\(String(describing: client.bundleIdentifier()), privacy: .public)")
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        rightCommand.cancel()
        closeFeedback()
        super.activateServer(sender)
        guard let client = sender as? any IMKTextInput else {
            reportError("입력 클라이언트가 IMKTextInput을 제공하지 않습니다. 입력란을 다시 선택해 주세요.")
            return
        }
        prepareSession(for: client)
        shortcutLogger.notice("Input controller activated; id=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
    }

    private func prepareSession(for client: any IMKTextInput) {
        if let session, session.belongsTo(client) {
            session.resume()
        } else {
            session?.deactivate()
            previewHostBundleID = client.bundleIdentifier()
            session = CompositionSession(client: client, hostBundleID: previewHostBundleID,
                                         onPreviewStart: { [weak self] in self?.prepareAlternatePreview() },
                                         onPreview: { [weak self] text in self?.showAlternatePreview(text) }) { [weak self] message in
                self?.showNotice(message)
            }
        }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else {
            reportError("InputMethodKit에서 키 이벤트를 받지 못했습니다.")
            return true
        }
        defer { if event.type == .keyDown { session?.finishInputEvent() } }
        if ReplayedInputEvent.consume(event, hostBundleID: (sender as? any IMKTextInput)?.bundleIdentifier()) { return false }
        if event.type == .leftMouseDown {
            rightCommand.cancel()
            closeFeedback()
            session?.commitPending()
            return false
        }
        guard event.type == .keyDown || event.type == .flagsChanged else { return false }
        if event.type == .keyDown {
            if event.keyCode == 53, AppSupport.shared.dismissError() {
                rightCommand.cancel()
                return true
            }
            AppSupport.shared.clearError()
        }
        guard sender is any IMKTextInput else {
            reportError("활성 입력 클라이언트가 없습니다. 입력란을 다시 선택해 주세요.")
            return true
        }
        guard let session else {
            shortcutLogger.error("Input key arrived without a session; id=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
            reportError("한녕 입력 세션이 활성화되지 않았습니다. 입력 소스를 다시 선택해 주세요.")
            return true
        }
        rightCommand.handle(event)
        if event.type == .flagsChanged {
            if event.keyCode == 54 {
                shortcutLogger.notice("IMK right Command modifier; flags=\(event.modifierFlags.rawValue) time=\(event.timestamp)")
            }
            return false
        }
        if !feedbackCandidates.isEmpty {
            if event.keyCode == 53 {
                closeFeedback()
                return true
            }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                if let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number) {
                    feedbackLogger.notice("Correction number received: \(number)")
                    if feedbackWindow?.selectNumber(number) != true {
                        showNotice("해당 번호의 후보가 없습니다. 표시된 번호를 선택해 주세요.")
                    }
                    return true
                }
                switch event.keyCode {
                case 36, 76:
                    feedbackWindow?.chooseSelected()
                    return true
                case 125, 126:
                    feedbackWindow?.moveSelection(event.keyCode == 125 ? 1 : -1)
                    return true
                case 123, 124, 116, 121:
                    feedbackWindow?.page(event.keyCode == 124 || event.keyCode == 121 ? 1 : -1)
                    return true
                default: break
                }
            }
            closeFeedback()
        }
        return session.handle(event)
    }

    override func commitComposition(_ sender: Any!) {
        shortcutLogger.info("Host requested composition commitment")
        session?.logDiagnostic("host_commit_requested")
        closeFeedback()
        session?.commitPending()
    }

    override func deactivateServer(_ sender: Any!) {
        rightCommand.cancel()
        closeFeedback()
        session?.suspend()
        shortcutLogger.notice("Input controller suspended; id=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
        super.deactivateServer(sender)
    }

    override func inputControllerWillClose() {
        shortcutLogger.notice("Input controller closing; id=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
        rightCommand.cancel()
        closeFeedback()
        session?.deactivate()
        session = nil
        super.inputControllerWillClose()
    }

    override func hidePalettes() {
        alternatePreview?.hide()
        closeFeedback()
        super.hidePalettes()
    }

    private func applyFeedback(index: Int) {
        guard let session, feedbackCandidates.indices.contains(index) else { return }
        let preferred = feedbackCandidates[index].text
        let scope = feedbackScope
        feedbackCandidates.removeAll()
        feedbackWindow?.hide()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await session.applyFeedback(preferred: preferred, scope: scope)
                feedbackLogger.notice("Correction candidate applied: \(index + 1)")
                AppSupport.shared.clearError()
            } catch {
                reportFeedbackError(error, message: "교정 내용을 모두 반영하지 못했습니다. 다시 시도해 주세요.")
            }
        }
    }

    override func doCommand(by selector: Selector!, command: [AnyHashable: Any]!) {
        shortcutLogger.notice("Input menu command received; selector=\(NSStringFromSelector(selector), privacy: .public)")
        super.doCommand(by: selector, command: command)
    }

    override func menu() -> NSMenu! {
        // A call here means the system reached this controller; "…" in the menu without this line means it did not.
        shortcutLogger.notice("Input menu requested; id=\(String(describing: ObjectIdentifier(self)), privacy: .public) session=\(self.session != nil)")
        let menu = NSMenu(title: "한녕")
        menu.autoenablesItems = false
        let settings = menu.addItem(withTitle: "설정…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        settings.target = self
        return menu
    }

    // InputMethodKit dispatches menu selectors with a command dictionary as sender.
    override func showPreferences(_ sender: Any!) {
        shortcutLogger.notice("Input menu showPreferences received")
        closeFeedback()
        alternatePreview?.hide()
        AppSupport.shared.showSettings()
    }

    private func showFeedback(scope: CorrectionScope, completePending: Bool = false) {
        alternatePreview?.hide()
        guard let session else { return }
        session.logDiagnostic("feedback_requested")
        if !feedbackCandidates.isEmpty {
            feedbackScope = scope
            feedbackWindow?.updateScope(scope)
            return
        }
        do {
            if completePending { try session.completeForCorrection() }
            let candidates = try session.prepareFeedback()
            let displayCandidates = try candidates.map { try session.feedbackDisplayText(for: $0) }
            guard let client = client() as? any IMKTextInput else {
                session.cancelFeedback()
                showNotice("입력란의 위치를 확인하지 못했습니다. 입력란을 다시 선택해 주세요.")
                return
            }
            var caretRect = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caretRect)
            feedbackCandidates = candidates
            feedbackScope = scope
            AppSupport.shared.clearError()
            if feedbackWindow == nil { feedbackWindow = FeedbackPanel() }
            feedbackWindow?.show(candidates: displayCandidates, scope: scope, at: caretRect) { [weak self] index in
                self?.applyFeedback(index: index)
            }
            feedbackLogger.notice("Correction panel shown: \(candidates.count) candidates")
        } catch {
            closeFeedback()
            reportFeedbackError(error, message: "지금 고칠 수 있는 변환이 없습니다. 자동 변환 직후에 시도하세요.")
        }
    }

    private func closeFeedback() {
        feedbackCandidates.removeAll()
        feedbackWindow?.hide()
        session?.cancelFeedback()
    }

    private func reportFeedbackError(_ error: Error, message: String) {
        session?.logFailure(error, stage: "feedback_failed")
        let failure = error as NSError
        feedbackLogger.error("Correction failed: \(failure.domain, privacy: .public) code \(failure.code)")
        showNotice(message)
    }

    private func logCommandAction(_ action: String) {
        let currentClient = client()
        shortcutLogger.notice("Command action; action=\(action, privacy: .public) controller=\(String(describing: ObjectIdentifier(self)), privacy: .public) session=\(String(describing: self.session?.diagnosticID), privacy: .public) app=\(String(describing: currentClient?.bundleIdentifier()), privacy: .public) sameClient=\(currentClient.map { self.session?.belongsTo($0) == true } == true)")
    }

    private func reportError(_ message: String) {
        NSLog("Hannyeong InputController: %@", message)
        showNotice(message)
    }

    private func prepareAlternatePreview() {
        guard let client = client() else { return }
        // Refresh the host's selection geometry before its first marked-text update.
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
    }

    private func showAlternatePreview(_ text: String?) {
        guard let text, !text.isEmpty, let client = client() else {
            alternatePreview?.hide()
            return
        }
        if alternatePreview == nil { alternatePreview = AlternatePreviewPanel() }
        let delay = Self.previewPresentationDelay(for: previewHostBundleID)
        alternatePreview?.show(text, delay: delay,
                               at: Self.previewCaretRect(from: client, atInlineStart: delay > .zero))
    }

    static func previewPresentationDelay(for bundleID: String?) -> Duration {
        // Aside's new-tab field still reports toolbar geometry during the first marked-text update.
        // Two recorded reproductions returned the field geometry 100 ms later.
        bundleID == "at.studio.AsideBrowser" ? .milliseconds(100) : .zero
    }

    static func previewCaretRect(from client: any IMKTextInput, atInlineStart: Bool = false) -> NSRect {
        let marked = client.markedRange()
        // IMK uses inline indices; index 0 refers to the selection when no inline range exists.
        let index = atInlineStart || marked.location == NSNotFound || marked.length == NSNotFound ? 0 : max(0, marked.length - 1)
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
        return rect
    }

    private func showNotice(_ message: String) {
        alternatePreview?.hide()
        var caretRect: NSRect?
        if let client = client() {
            var rect = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            caretRect = rect
        }
        AppSupport.shared.showError(message, at: caretRect)
    }
}
