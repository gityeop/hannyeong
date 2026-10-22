import AppKit
import ApplicationServices

@_silgen_name("hannyeongDelayRangeReads") private func delayRangeReads(_ count: Int32)
@_silgen_name("hannyeongInjectedRangeReads") private func injectedRangeReads() -> Int32

@main
private struct CommittedSelectionQA {
    private static func check(_ status: AXError, _ operation: String) throws {
        guard status == .success else { throw CommittedTextSelection.Failure.accessibility("QA " + operation, status) }
    }

    @MainActor static func main() async {
        let host = Process()
        host.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let ready = Pipe()
        host.standardOutput = ready
        do {
            try host.run()
            defer { host.terminate(); host.waitUntilExit() }
            let handshake = try ready.fileHandleForReading.read(upToCount: 6)
            precondition(handshake == Data("READY\n".utf8))
            let hostID = "com.yeop.hannyeong.tests.committedselection"
            let running = try CommittedTextSelection.hostApplication(hostID)
            precondition(running.processIdentifier == host.processIdentifier)
            let app = AXUIElementCreateApplication(host.processIdentifier)
            var value: CFTypeRef?
            try check(AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value), "focused field")
            let field = value as! AXUIElement

            // Keep correction enabled throughout, including another attempt after delayed reads.
            for count: Int32 in [0, 1, 3, 1] {
                let expected = "새 해 home ", replacement = "to go home "
                try check(AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, expected as CFString), "reset value")
                var caret = CFRange(location: expected.utf16.count, length: 0)
                try check(AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString,
                                                       AXValueCreate(.cfRange, &caret)!), "reset caret")
                delayRangeReads(count)
                let range = try await CommittedTextSelection.select(expected, hostBundleID: hostID)
                precondition(range == NSRange(location: 0, length: expected.utf16.count))
                precondition(injectedRangeReads() == count)
                // Replace the real selected text and verify the post-rewrite caret through production AX code.
                try check(AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, replacement as CFString), "replace selected text")
                var actual: CFTypeRef?
                try check(AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &actual), "read replaced text")
                precondition(actual as? String == replacement)
                let end = try await CommittedTextSelection.confirmedCaret(expectedSuffix: "home ", hostBundleID: hostID)
                precondition(end == replacement.utf16.count)
                print("PASS enabled correction: delayed AX reads=\(count), text=\(replacement.debugDescription), caret=\(end)")
            }
        } catch {
            fputs("Committed selection QA failed: \(error.localizedDescription), delayed reads=\(injectedRangeReads())\n", stderr)
            exit(1)
        }
    }
}
