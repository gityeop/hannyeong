import AppKit
import Sparkle
import SwiftUI

@MainActor
private final class Recorder: NSObject, SPUUpdaterDelegate {
    var cycles = 0
    var found: String?
    var error: NSError?
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { found = item.versionString }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        self.error = error as NSError?
        cycles += 1
    }
}

@main
private struct UpdaterQA {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let recorder = Recorder()
        let updates = AppUpdater(delegate: recorder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "한녕 업데이트 QA"
        window.contentView = NSHostingView(rootView: UpdateSettingsView(updates: updates).padding(24))
        window.center()
        if CommandLine.arguments.contains("--manual") {
            updates.start()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        } else {
            Task { @MainActor in
                do {
                    let updater = updates.controller.updater
                    precondition(updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates)
                    precondition(!updater.sendsSystemProfile)
                    UserDefaults.standard.set(Date(), forKey: "SULastCheckTime")
                    updater.automaticallyChecksForUpdates = false
                    updater.automaticallyDownloadsUpdates = false
                    updates.start()
                    let feed = URL(fileURLWithPath: CommandLine.arguments[1])
                    @MainActor func probe(_ contents: String) async throws {
                        try contents.write(to: feed, atomically: true, encoding: .utf8)
                        recorder.found = nil
                        recorder.error = nil
                        let cycle = recorder.cycles
                        updater.checkForUpdateInformation()
                        let deadline = Date().addingTimeInterval(10)
                        while recorder.cycles == cycle {
                            guard Date() < deadline else { throw NSError(domain: "UpdaterQA", code: 1) }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        try await Task.sleep(for: .milliseconds(40))
                        precondition(updates.canCheckForUpdates)
                    }
                    let current = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
                    try await probe(current)
                    precondition(recorder.found == nil && recorder.error?.code == Int(SUError.noUpdateError.rawValue))
                    print("PASS current version; check button becomes available again")
                    try await probe(current.replacingOccurrences(of: "<sparkle:version>110</sparkle:version>",
                                                                 with: "<sparkle:version>111</sparkle:version>"))
                    precondition(recorder.found == "111")
                    print("PASS newer version discovered through real Sparkle HTTP check")
                    try await probe("not an appcast")
                    precondition(recorder.error != nil && recorder.error?.code != Int(SUError.noUpdateError.rawValue))
                    print("PASS malformed feed reports failure, not up-to-date")
                    updater.automaticallyChecksForUpdates = true
                    updater.automaticallyDownloadsUpdates = true
                    precondition(UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks"))
                    precondition(UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate"))
                    print("PASS automatic update preferences persist; system profile disabled")
                    exit(0)
                } catch {
                    fputs("Updater QA failed: \(error)\n", stderr)
                    exit(1)
                }
            }
        }
        app.run()
        withExtendedLifetime((updates, recorder, window)) {}
    }
}
