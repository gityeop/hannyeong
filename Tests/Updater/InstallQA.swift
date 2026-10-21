import AppKit
import Sparkle

@MainActor
private final class InstallRecorder: NSObject, SPUUpdaterDelegate {
    let journal: URL
    init(journal: URL) { self.journal = journal }
    func record(_ line: String) {
        let data = Data((line + "\n").utf8)
        let handle = try! FileHandle(forWritingTo: journal)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: data)
        try! handle.close()
    }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { record("downloaded " + item.versionString) }
    // Sparkle 2.10 invokes this when launching the installer, before archive verification.
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) { record("installer-started " + item.versionString) }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        record("ready " + item.versionString)
        DispatchQueue.main.async { install() }
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        record("ERROR \(failure.domain) \(failure.code)")
        fputs("\(failure)\n", stderr)
        exit(1)
    }
}

@main
private struct InstallQA {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let journal = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "QAJournal") as! String)
        let recorder = InstallRecorder(journal: journal)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        recorder.record("launched " + version)
        precondition(Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true)
        if version == "111" { exit(0) }
        let updater = AppUpdater(delegate: recorder)
        precondition(updater.controller.updater.automaticallyChecksForUpdates)
        precondition(updater.controller.updater.automaticallyDownloadsUpdates)
        updater.start()
        updater.controller.updater.checkForUpdatesInBackground()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            recorder.record("ERROR install timed out")
            exit(1)
        }
        app.run()
        withExtendedLifetime((recorder, updater)) {}
    }
}
