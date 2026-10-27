import AppKit
import Carbon
import InputMethodKit
import HannyeongCore
import os

private let bundleID = "com.yeop.inputmethod.Hannyeong"
private let sourceID = bundleID

private func sourceProperty(_ source: TISInputSource, _ key: CFString) -> String {
    guard let value = TISGetInputSourceProperty(source, key) else { return "" }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

private func sources() -> [TISInputSource] {
    TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
}

private func sourceFlag(_ source: TISInputSource, _ key: CFString) throws -> Bool {
    guard let value = TISGetInputSourceProperty(source, key) else {
        throw SetupError("Input source property is unavailable: \(key)")
    }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
}

private func setupCommand(_ command: String) throws {
    switch command {
    case "--register-input-source":
        // Versions before 0.2.0 registered as JevType; turn that source off so only one 한녕 remains.
        for legacy in sources() where sourceProperty(legacy, kTISPropertyInputSourceID) == LegacyMigration.bundleID {
            let disabled = TISDisableInputSource(legacy)
            print("Legacy input source disabled: \(LegacyMigration.bundleID) status=\(disabled)")
        }
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        guard status == noErr else { throw SetupError("Input source registration failed: \(status)") }
        guard let source = sources().first(where: { sourceProperty($0, kTISPropertyInputSourceID) == sourceID }) else {
            throw SetupError("한녕 was not found after registration.")
        }
        let enabled = TISEnableInputSource(source)
        guard enabled == noErr else { throw SetupError("Input source enable failed: \(enabled)") }
        print("Registration and enable commands accepted: \(sourceID)")
    case "--select-input-source":
        guard let source = sources().first(where: { sourceProperty($0, kTISPropertyInputSourceID) == sourceID }) else {
            throw SetupError("한녕 is not registered.")
        }
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw SetupError("Input source selection failed: \(status)") }
        print("Selected: \(sourceID)")
    case "--list-input-sources":
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        print("Current: \(sourceProperty(current, kTISPropertyInputSourceID))")
        for source in sources() where sourceProperty(source, kTISPropertyInputSourceID) == sourceID {
            print("한녕: \(sourceProperty(source, kTISPropertyInputSourceID)) \(sourceProperty(source, kTISPropertyLocalizedName))")
        }
    case "--verify-input-source":
        let matches = sources().filter { sourceProperty($0, kTISPropertyInputSourceID) == sourceID }
        guard matches.count == 1 else {
            throw SetupError("Expected one 한녕 input source, found \(matches.count).")
        }
        let source = matches[0]
        guard try sourceFlag(source, kTISPropertyInputSourceIsEnabled) else {
            throw SetupError("한녕 is registered but is not enabled.")
        }
        guard try sourceFlag(source, kTISPropertyInputSourceIsSelectCapable) else {
            throw SetupError("한녕 is not selectable.")
        }
        print("Verified one enabled, selectable input source: \(sourceID)")
    default: throw SetupError("Unknown setup command: \(command)")
    }
}

private struct SetupError: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?
    private let secureInputSource = SecureInputSource()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigration.run()
        NativeInputEngine.shared.prepare()
        guard let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
              !connectionName.isEmpty else {
            Logger(subsystem: bundleID, category: "Lifecycle").error("InputMethodConnectionName is missing")
            AppSupport.shared.showError("입력기를 시작하지 못했습니다. 한녕을 다시 설치해 주세요.")
            return
        }
        server = IMKServer(name: connectionName, bundleIdentifier: bundleID)
        guard server != nil else {
            AppSupport.shared.showError("입력기를 시작하지 못했습니다. 한녕을 다시 실행해 주세요.")
            return
        }
        AppSupport.shared.prepareLaunch(arguments: CommandLine.arguments)
        secureInputSource.start()
        AppUpdater.shared.start()
        Logger(subsystem: bundleID, category: "Lifecycle").notice("Input method server started")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Logger(subsystem: bundleID, category: "Lifecycle").notice("Application reopen received")
        AppSupport.shared.showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        secureInputSource.stop()
        NativeInputEngine.shared.close()
    }
}

@main
struct HannyeongApplication {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--verify-local-model" {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    let local = try LocalModelService.client()
                    let info = try await local.prepare()
                    let candidates = try CandidateBuilder.candidates(for: "dkssud", includeSplits: true)
                    let decision = try await local.decide(raw: "dkssud", before: "", candidates: candidates)
                    print("Verified bundled local runtime: \(info.modelID), predicted=\(decision.predicted), API calls=0")
                    exit(0)
                } catch {
                    fputs("Local runtime verification failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            application.run()
            return
        }
        if let argument = CommandLine.arguments.dropFirst().first,
           ["--register-input-source", "--select-input-source", "--list-input-sources", "--verify-input-source"].contains(argument) {
            do { try setupCommand(argument); exit(0) }
            catch { fputs("Error: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
