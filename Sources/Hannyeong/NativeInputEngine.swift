import AppKit
import Carbon
import InputMethodKit
import HannyeongInputRuntime
import HannyeongCore
import os

/// IMK supplies source identity and owns KakaoTalk and Notion keys.
@MainActor
final class NativeInputEngine: NSObject {
    static let shared = NativeInputEngine()
    private let sourceID = "com.yeop.inputmethod.Hannyeong"
    private let logger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "TypingEngine")
    private var engine: TypingEngine?
    private var failed = false
    private var waitingForKeyboardAccess = false
    private var prepared = false
    private weak var inputClient: (any IMKTextInput)?
    private weak var nativeOutput: NativeNotionOutput?
    var experimentalEnabled: Bool { UserDefaults.standard.bool(forKey: CompositionPreviewSettings.liveEnabledKey) }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        do {
            engine = try TypingEngine.native(client: LocalModelService.client(), frequencies: LocalModelService.wordFrequencies(),
                correctionsURL: CorrectionStore.shared.url, memory: CorrectionStore.shared.load(),
                replaceNativeSheet: { [weak self] expected, replacement in
                    guard let self, let client = self.inputClient,
                          client.bundleIdentifier() == "com.apple.appkit.xpc.openAndSavePanelService" else {
                        throw NativeSheetReplacement.Failure(errorDescription: "The active save-field input client is unavailable.")
                    }
                    let began = DispatchTime.now().uptimeNanoseconds
                    try NativeSheetReplacement.replace(client: client, expected: expected, with: replacement)
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                    self.logger.notice("Native sheet language reversal; removedUTF16=\(expected.utf16.count) insertedUTF16=\(replacement.utf16.count) ms=\(elapsed)")
                }, replaceNativeText: { [weak self] deletedUTF16, text in
                    guard let output = self?.nativeOutput else {
                        throw NativeNotionOutput.Failure(errorDescription: "The active native input controller is unavailable.")
                    }
                    try output.replace(deletingUTF16: deletedUTF16, with: text)
                }, resetNativeText: { [weak self] in self?.nativeOutput?.reset() },
                advanceNativeText: { [weak self] in self?.nativeOutput?.advance(utf16: $0) }) { [weak self] in self?.report($0) }
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(sourceChanged),
                name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                name: UserDefaults.didChangeNotification, object: nil)
            configure()
            synchronizeSource()
            logger.notice("Shared nonblocking typing engine prepared; no IMK key queue or committed-text confirmation")
        } catch { report(error) }
    }

    func activate(client: any IMKTextInput) {
        if let output = nativeOutput, output.usesClientRoute, !output.belongsTo(client) {
            deactivateNativeOutput(output)
        }
        inputClient = client
        configure()
        synchronizeSource()
    }

    func handleNative(_ event: NSEvent, output: NativeNotionOutput) -> Bool {
        if IsSecureEventInputEnabled() {
            deactivateNativeOutput(output)
            return false
        }
        guard let engine, engine.enabled, let keyboardEvent = event.cgEvent else { return false }
        if output.usesClientRoute {
            guard let inputClient, output.belongsTo(inputClient) else { return false }
        }
        if nativeOutput !== output {
            if let current = nativeOutput { deactivateNativeOutput(current) }
            nativeOutput = output
            if !output.usesClientRoute { engine.reset() }
            logger.notice("Native controller bound for IMK keys; clientOwned=\(output.usesClientRoute) sourcePID=\(keyboardEvent.getIntegerValueField(.eventSourceUnixProcessID)) targetPID=\(keyboardEvent.getIntegerValueField(.eventTargetUnixProcessID))")
        }
        if output.usesClientRoute { engine.setNativeClientRoute(true) }
        return engine.handleNative(keyboardEvent)
    }

    func commitNativeComposition(_ output: NativeNotionOutput) {
        guard nativeOutput === output else { return }
        engine?.reset()
    }

    func deactivateNativeOutput(_ output: NativeNotionOutput) {
        guard nativeOutput === output else { return }
        if output.usesClientRoute { engine?.setNativeClientRoute(false) }
        else { engine?.reset() }
        nativeOutput = nil
    }

    func reset() { engine?.reset() }
    func recheckInputTarget() { engine?.recheckInputTarget() }
    func resumeAfterSecureInput(retrying: Bool = false) {
        if retrying {
            failed = false
            logger.notice("Manual input recovery requested")
        }
        synchronizeSource()
        engine?.resumeAfterSecureInput()
    }
    func hidePalettes() { engine?.dismissCandidates() }
    func refreshPermissions() {
        if waitingForKeyboardAccess { synchronizeSource() }
    }
    func close() {
        do { try engine?.close() } catch { report(error) }
    }

    @objc private func sourceChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.failed = false
            self.synchronizeSource()
        }
    }
    @objc private func preferencesChanged() {
        configure()
        if !experimentalEnabled { synchronizeSource() }
    }
    private func configure() {
        let defaults = UserDefaults.standard
        engine?.configure(live: true,
            fixedEnglish: nil,
            backfill: PriorWordCorrectionSettings.enabled(in: defaults))
    }

    private func synchronizeSource() {
        guard let engine else { return }
        do {
            let selected = TypingEngine.currentSourceID
            if selected == sourceID && experimentalEnabled {
                guard !failed else { return }
                if !engine.enabled {
                    guard TypingEngine.hasKeyboardAccess else {
                        if !waitingForKeyboardAccess {
                            logger.error("Accessibility permission is required for native typing")
                        }
                        waitingForKeyboardAccess = true
                        return
                    }
                    waitingForKeyboardAccess = false
                    try engine.start()
                    logger.notice("Native nonblocking typing enabled")
                }
            } else {
                if engine.enabled {
                    try engine.pause()
                    logger.notice("Native nonblocking typing paused; selectedSource=\(selected, privacy: .public) experimental=\(self.experimentalEnabled)")
                }
                failed = false
            }
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        failed = true
        if let failure = error as? DirectFailure { logger.error("Native typing error: \(failure.detail, privacy: .public)") }
        else if let failure = error as? NativeSheetReplacement.Failure {
            logger.error("Native save-field replacement failed: \(failure.localizedDescription, privacy: .public)")
        }
        else if let failure = error as? NativeNotionOutput.Failure {
            logger.error("Native text replacement failed: \(failure.localizedDescription, privacy: .public)")
        }
        else { logger.error("Native typing error: \(String(describing: error), privacy: .private)") }
    }
}
