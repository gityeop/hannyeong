import AppKit
import Carbon
import HannyeongInputRuntime
import HannyeongCore
import os

/// IMK supplies source identity. The shared tap is the sole owner of typed words.
@MainActor
final class NativeInputEngine: NSObject {
    static let shared = NativeInputEngine()
    private let sourceID = "com.yeop.inputmethod.Hannyeong"
    private let logger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "TypingEngine")
    private var engine: TypingEngine?
    private var failed = false
    private var prepared = false
    var experimentalEnabled: Bool { UserDefaults.standard.bool(forKey: CompositionPreviewSettings.liveEnabledKey) }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        do {
            engine = try TypingEngine.native(client: LocalModelService.client(), frequencies: LocalModelService.wordFrequencies(),
                correctionsURL: CorrectionStore.shared.url, memory: CorrectionStore.shared.load()) { [weak self] in self?.report($0) }
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(sourceChanged),
                name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                name: UserDefaults.didChangeNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(focusChanged),
                name: NSWorkspace.didActivateApplicationNotification, object: nil)
            configure()
            synchronizeSource()
            logger.notice("Shared nonblocking typing engine prepared; no IMK key queue or committed-text confirmation")
        } catch { report(error) }
    }

    func activate(hostBundleID: String?) {
        configure()
        synchronizeSource()
    }

    func reset() { engine?.reset() }
    func recheckInputTarget() { engine?.recheckInputTarget() }
    func hidePalettes() { engine?.dismissCandidates() }
    func close() {
        do { try engine?.close() } catch { report(error) }
    }

    @objc private func sourceChanged() {
        DispatchQueue.main.async { [weak self] in self?.synchronizeSource() }
    }
    @objc private func preferencesChanged() {
        configure()
        if !experimentalEnabled { synchronizeSource() }
    }
    @objc private func focusChanged() { recheckInputTarget() }

    private func configure() {
        let defaults = UserDefaults.standard
        engine?.configure(live: true,
            fixedEnglish: nil,
            backfill: PriorWordCorrectionSettings.enabled(in: defaults))
    }

    private func synchronizeSource() {
        guard let engine else { return }
        do {
            if TypingEngine.currentSourceID == sourceID && experimentalEnabled {
                guard !failed else { return }
                if !engine.enabled { try engine.start(); logger.notice("Native nonblocking typing enabled") }
            } else {
                if engine.enabled { try engine.pause(); logger.notice("Native nonblocking typing paused") }
                failed = false
            }
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        failed = true
        if let failure = error as? DirectFailure { logger.error("Native typing error: \(failure.detail, privacy: .public)") }
        else { logger.error("Native typing error: \(String(describing: error), privacy: .private)") }
        AppSupport.shared.showError("자동 입력 처리를 중단했습니다. 입력 소스를 다시 선택해 주세요.")
    }
}
