import AppKit
import Carbon

/// Opt-in check of either installed input source. No windows, key events or password text.
@main private struct DirectSecureInputLiveQA {
    private static var owner: String { CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.yeop.inputmethod.HannyeongDirectSource" }
    private static let abc = "com.apple.keylayout.ABC"

    @MainActor static func main() {
        do { try run(); print("PASS installed input source secure entry/exit twice; original source restored; no keys or text") }
        catch { fputs("Direct secure input live QA failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func current() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)!
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    @MainActor private static func select(_ id: String) throws {
        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first else { throw failure("Missing input source: \(id)") }
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw failure("Selecting \(id) failed: \(status)") }
    }

    @MainActor private static func expect(_ id: String, label: String) throws {
        let deadline = Date().addingTimeInterval(2)
        while current() != id, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard current() == id else { throw failure("\(label): expected \(id), got \(current())") }
        print("PASS \(label): \(id)"); fflush(stdout)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DirectSecureInputLiveQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor private static func run() throws {
        guard !IsSecureEventInputEnabled() else { throw failure("Secure input is already active; the live check was not started") }
        let original = current()
        var ownsSecureInput = false
        defer {
            if ownsSecureInput {
                let status = DisableSecureEventInput()
                if status != noErr { fputs("Secure input cleanup failed: \(status)\n", stderr) }
            }
            do { try select(original) }
            catch { fputs("Original input source restoration failed: \(error)\n", stderr) }
        }
        try select(owner)
        try expect(owner, label: "Input source selected")
        // Only the test settles distributed notifications; production key handling never waits.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        for cycle in 1...2 {
            let enabled = EnableSecureEventInput()
            guard enabled == noErr else { throw failure("EnableSecureEventInput failed: \(enabled)") }
            ownsSecureInput = true
            try expect(abc, label: "secure entry \(cycle)")
            let disabled = DisableSecureEventInput()
            guard disabled == noErr else { throw failure("DisableSecureEventInput failed: \(disabled)") }
            ownsSecureInput = false
            try expect(owner, label: "Input source restored \(cycle)")
        }
        let enabled = EnableSecureEventInput()
        guard enabled == noErr else { throw failure("EnableSecureEventInput failed: \(enabled)") }
        ownsSecureInput = true
        try expect(abc, label: "Enter-login secure entry")
        let disabled = DisableSecureEventInput()
        guard disabled == noErr else { throw failure("DisableSecureEventInput failed: \(disabled)") }
        ownsSecureInput = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.075))
        try select(abc)
        try expect(owner, label: "Enter-login delayed ABC restoration")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard current() == owner else { throw failure("The restored source did not remain selected after login") }
        print("PASS restored input source remains selected after the login transition")
    }
}
