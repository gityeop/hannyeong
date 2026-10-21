import AppKit
import ApplicationServices

/// Run with the PID of an owned Chrome window showing fixture-paragraphs.html.
@main
struct CommittedCaretQA {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let pid = pid_t(CommandLine.arguments[1])!
        let host = NSRunningApplication(processIdentifier: pid)!
        precondition(host.bundleIdentifier == "com.google.Chrome")
        let root = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        precondition(AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success)
        var title: CFTypeRef?
        precondition(AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success)
        precondition((title as? String)?.contains("Hannyeong IMK QA — paragraphs") == true)
        host.activate()
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
                let start = DispatchTime.now().uptimeNanoseconds
                let caret = try await CommittedTextSelection.confirmedCaret(expectedSuffix: "home ", hostBundleID: "com.google.Chrome")
                let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                precondition(milliseconds < 1_000, "Paragraph confirmation still holds typing")
                print("PASS paragraph caret \(caret), confirmation \(milliseconds) ms")
                exit(0)
            } catch {
                fputs("Paragraph caret confirmation failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        application.run()
    }
}
