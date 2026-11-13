import AppKit
import Carbon
import InputMethodKit
import HannyeongCore
import HannyeongInputRuntime
import os

@MainActor
@objc(HannyeongInputController)
final class InputController: IMKInputController {
    private var session: CompositionSession?
    private var directMode = false
    private var nativeOutput: NativeNotionOutput?
    private var isActiveController = false
    private var feedbackWindow: FeedbackPanel?
    private var alternatePreview: AlternatePreviewPanel?
    private var previewHostBundleID: String?
    private var feedbackCandidates: [Candidate] = []
    private var feedbackScope: CorrectionScope = .always
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
            self.showFeedback(scope: .always, completePending: true)
            self.shortcutLogger.notice("Right Command double tap handled")
        }
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        guard let client = inputClient as? any IMKTextInput else {
            reportError("The input client does not implement IMKTextInput.")
            return nil
        }
        // The client already exists at initialization; its first key may precede activation.
        isActiveController = true
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification, object: nil)
        synchronizeMode(for: client)
        shortcutLogger.notice("Input controller initialized; id=\(String(describing: ObjectIdentifier(self)), privacy: .public) client=\(String(describing: client.bundleIdentifier()), privacy: .public)")
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        if directMode { return Int(NSEvent.EventTypeMask.keyDown.rawValue) }
        return Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        rightCommand.cancel()
        closeFeedback()
        super.activateServer(sender)
        guard let client = sender as? any IMKTextInput else {
            reportError("The input client does not implement IMKTextInput.")
            return
        }
        isActiveController = true
        synchronizeMode(for: client)
        shortcutLogger.notice("Input controller activated; id=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
    }

    @objc private func preferencesChanged() {
        guard isActiveController, directMode != NativeInputEngine.shared.experimentalEnabled,
              let client = client() as? any IMKTextInput else { return }
        synchronizeMode(for: client)
    }

    private func synchronizeMode(for client: any IMKTextInput) {
        let direct = NativeInputEngine.shared.experimentalEnabled
        if direct != directMode {
            rightCommand.cancel()
            closeFeedback()
            alternatePreview?.hide()
            session?.deactivate()
            session = nil
            directMode = direct
        }
        let bundleID = client.bundleIdentifier()
        let usesClientRoute = bundleID == TypingEngine.clientOwnedBundleID ||
            (bundleID == nil && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TypingEngine.clientOwnedBundleID)
        if let output = nativeOutput, !direct || (output.usesClientRoute && !output.belongsTo(client)) {
            NativeInputEngine.shared.deactivateNativeOutput(output)
            nativeOutput = nil
        }
        if direct, nativeOutput == nil, usesClientRoute || bundleID == "notion.id" {
            nativeOutput = NativeNotionOutput(client: client, usesClientRoute: usesClientRoute)
        }
        NativeInputEngine.shared.activate(client: client)
        if direct {
            let layouts = TISCreateInputSourceList([kTISPropertyInputSourceID: "com.apple.keylayout.ABC"] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
            guard let abc = layouts.first else {
                reportError("The ABC keyboard layout is unavailable.")
                return
            }
            let status = TISSetInputMethodKeyboardLayoutOverride(abc)
            guard status == noErr else {
                reportError("Keyboard layout override failed: status=\(status)")
                return
            }
        } else {
            prepareSession(for: client)
        }
        shortcutLogger.notice("Input owner selected; experimental=\(direct) clientOwned=\(usesClientRoute && direct) legacySession=\(self.session != nil)")
    }

    private func prepareSession(for client: any IMKTextInput) {
        if let session, session.belongsTo(client) {
            session.resume()
        } else {
            session?.deactivate()
            previewHostBundleID = client.bundleIdentifier()
            session = CompositionSession(client: client, hostBundleID: previewHostBundleID,
                                         liveDetectionOverride: false,
                                         onPreviewStart: { [weak self] in self?.prepareAlternatePreview() },
                                         onPreview: { [weak self] text in self?.showAlternatePreview(text) })
        }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        if directMode {
            if let event, event.type == .keyDown, let output = nativeOutput {
                if output.usesClientRoute {
                    guard isActiveController, let sender = sender as? any IMKTextInput, output.belongsTo(sender) else {
                        return false
                    }
                }
                return NativeInputEngine.shared.handleNative(event, output: output)
            }
            // An existing IMK client can keep its old modifier mask after the mode changes.
            return event?.type == .flagsChanged && event?.keyCode == 54 &&
                (sender as? any IMKTextInput)?.bundleIdentifier() == "com.apple.Terminal"
        }
        guard let event else {
            reportError("InputMethodKit delivered no key event.")
            return false
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
        guard sender is any IMKTextInput else {
            reportError("The key event has no IMKTextInput client.")
            return false
        }
        guard let session else {
            reportError("Input key arrived without a session; controller=\(ObjectIdentifier(self))")
            return false
        }
        rightCommand.handle(event)
        if event.type == .flagsChanged {
            if event.keyCode == 54 {
                shortcutLogger.notice("IMK right Command modifier; flags=\(event.modifierFlags.rawValue) time=\(event.timestamp)")
                // Terminal interprets unhandled modifier events as invalid text (<ffffffff>).
                if previewHostBundleID == "com.apple.Terminal" { return true }
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
                        feedbackLogger.notice("No correction candidate for number \(number)")
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
        if directMode {
            if let output = nativeOutput, output.usesClientRoute,
               let sender = sender as? any IMKTextInput, output.belongsTo(sender) {
                NativeInputEngine.shared.commitNativeComposition(output)
            }
            return
        }
        shortcutLogger.info("Host requested composition commitment")
        session?.logDiagnostic("host_commit_requested")
        closeFeedback()
        session?.commitPending()
    }

    // Keys enter through handle(_:) or the shared event tap.
    override func inputText(_ string: String!, client sender: Any!) -> Bool { false }

    override func deactivateServer(_ sender: Any!) {
        isActiveController = false
        if let output = nativeOutput { NativeInputEngine.shared.deactivateNativeOutput(output) }
        if directMode { NativeInputEngine.shared.recheckInputTarget() }
        rightCommand.cancel()
        closeFeedback()
        session?.suspend()
        shortcutLogger.notice("Input controller suspended; id=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
        super.deactivateServer(sender)
    }

    override func inputControllerWillClose() {
        isActiveController = false
        if let output = nativeOutput { NativeInputEngine.shared.deactivateNativeOutput(output) }
        NotificationCenter.default.removeObserver(self)
        if directMode { NativeInputEngine.shared.recheckInputTarget() }
        shortcutLogger.notice("Input controller closing; id=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
        rightCommand.cancel()
        closeFeedback()
        session?.deactivate()
        session = nil
        super.inputControllerWillClose()
    }

    override func hidePalettes() {
        NativeInputEngine.shared.hidePalettes()
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
            } catch {
                reportFeedbackError(error)
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
        let recovery = menu.addItem(withTitle: "한녕 다시 켜기", action: #selector(recoverInput(_:)), keyEquivalent: "")
        recovery.target = self
        let settings = menu.addItem(withTitle: "설정…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        settings.target = self
        return menu
    }

    @objc private func recoverInput(_ sender: Any?) {
        SecureInputSource.shared.reselect()
    }

    // InputMethodKit dispatches menu selectors with a command dictionary as sender.
    override func showPreferences(_ sender: Any!) {
        NativeInputEngine.shared.reset()
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
                feedbackLogger.error("The correction panel has no IMKTextInput client")
                return
            }
            var caretRect = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caretRect)
            feedbackCandidates = candidates
            feedbackScope = scope
            if feedbackWindow == nil { feedbackWindow = FeedbackPanel() }
            feedbackWindow?.show(candidates: displayCandidates, scope: scope, at: caretRect) { [weak self] index in
                self?.applyFeedback(index: index)
            }
            feedbackLogger.notice("Correction panel shown: \(candidates.count) candidates")
        } catch {
            closeFeedback()
            reportFeedbackError(error)
        }
    }

    private func closeFeedback() {
        feedbackCandidates.removeAll()
        feedbackWindow?.hide()
        session?.cancelFeedback()
    }

    private func reportFeedbackError(_ error: Error) {
        session?.logFailure(error, stage: "feedback_failed")
        let failure = error as NSError
        feedbackLogger.error("Correction failed: \(failure.domain, privacy: .public) code \(failure.code)")
    }

    private func logCommandAction(_ action: String) {
        let currentClient = client()
        shortcutLogger.notice("Command action; action=\(action, privacy: .public) controller=\(String(describing: ObjectIdentifier(self)), privacy: .public) session=\(String(describing: self.session?.diagnosticID), privacy: .public) app=\(String(describing: currentClient?.bundleIdentifier()), privacy: .public) sameClient=\(currentClient.map { self.session?.belongsTo($0) == true } == true)")
    }

    private func reportError(_ message: String) {
        shortcutLogger.error("\(message, privacy: .public)")
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
}
