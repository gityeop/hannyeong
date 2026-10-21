import AppKit
import ApplicationServices

/// Selection runs off the IMK event thread so the host can finish its key event and answer AX requests.
enum CommittedTextSelection {
    enum Failure: LocalizedError {
        case permissionRequired
        case invalidTarget(String)
        case accessibility(String, AXError)
        var errorDescription: String? {
            switch self {
            case .permissionRequired: return "앞 단어를 고치려면 한녕 설정에서 손쉬운 사용 권한을 허용해 주세요."
            case .invalidTarget(let detail): return "Committed edit target: " + detail
            case .accessibility(let operation, let code): return "Accessibility \(operation) failed: \(code.rawValue)"
            }
        }
    }
    static var isTrusted: Bool { AXIsProcessTrusted() }
    @MainActor static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    @MainActor static func select(_ expected: String, hostBundleID: String?) async throws -> NSRange {
        guard isTrusted else { throw Failure.permissionRequired }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == hostBundleID else {
            throw Failure.invalidTarget("focused application changed")
        }
        let pid = front.processIdentifier
        return try await Task.detached(priority: .userInitiated) { try select(expected, processID: pid) }.value
    }
    @MainActor static func confirmedCaret(expectedSuffix: String, hostBundleID: String?) async throws -> Int {
        guard isTrusted else { throw Failure.permissionRequired }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == hostBundleID else {
            throw Failure.invalidTarget("focused application changed")
        }
        let pid = front.processIdentifier
        return try await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            var focused: CFTypeRef?
            try check(AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused), "commit field")
            guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw Failure.invalidTarget("commit field missing") }
            let field = focused as! AXUIElement
            let deadline = Date().addingTimeInterval(2)
            repeat {
                var selected: CFTypeRef?
                try check(AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selected), "commit caret")
                var caret = CFRange()
                if let selected, CFGetTypeID(selected) == AXValueGetTypeID(),
                   AXValueGetValue(selected as! AXValue, .cfRange, &caret), caret.length == 0,
                   caret.location >= expectedSuffix.utf16.count {
                    var text: CFTypeRef?
                    // Chromium can return AXNoValue for a range while applying Backspace.
                    try check(AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &text), "committed value")
                    guard let text = text as? String else { throw Failure.invalidTarget("committed value is not text") }
                    let value = text as NSString
                    let span = NSRange(location: caret.location - expectedSuffix.utf16.count, length: expectedSuffix.utf16.count)
                    if caret.location <= value.length, value.substring(with: span) == expectedSuffix { return caret.location }
                }
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.005)
            } while Date() < deadline
            throw Failure.invalidTarget("commit was not reflected by the host")
        }.value
    }

    private static func select(_ expected: String, processID: pid_t) throws -> NSRange {
        let application = AXUIElementCreateApplication(processID)
        var focused: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused), "focused element")
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw Failure.invalidTarget("focused element missing") }
        let field = focused as! AXUIElement
        var owner: pid_t = 0
        try check(AXUIElementGetPid(field, &owner), "element owner")
        guard owner == processID else { throw Failure.invalidTarget("element owner changed") }
        var target: CFRange?
        let readyDeadline = Date().addingTimeInterval(2)
        repeat {
            var selected: CFTypeRef?
            try check(AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selected), "caret")
            var caret = CFRange()
            if let selected, CFGetTypeID(selected) == AXValueGetTypeID(),
               AXValueGetValue(selected as! AXValue, .cfRange, &caret), caret.length == 0, caret.location >= expected.utf16.count {
                var span = CFRange(location: caret.location - expected.utf16.count, length: expected.utf16.count)
                var text: CFTypeRef?
                try check(AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
                                                                   AXValueCreate(.cfRange, &span)!, &text), "committed text")
                if text as? String == expected { target = span; break }
            }
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < readyDeadline
        guard var target else { throw Failure.invalidTarget("committed span or caret changed") }
        let targetValue = AXValueCreate(.cfRange, &target)!
        try Task.checkCancellation()
        try check(AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, targetValue), "select range")
        // Chromium applies AX selection in its renderer after the setter returns.
        let deadline = Date().addingTimeInterval(1)
        repeat {
            var after: CFTypeRef?
            try check(AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &after), "selected range")
            var actual = CFRange()
            if let after, CFGetTypeID(after) == AXValueGetTypeID(),
               AXValueGetValue(after as! AXValue, .cfRange, &actual),
               actual.location == target.location, actual.length == target.length {
                return NSRange(location: target.location, length: target.length)
            }
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline
        throw Failure.invalidTarget("selection was not applied")
    }
    private static func check(_ code: AXError, _ operation: String) throws {
        guard code == .success else { throw Failure.accessibility(operation, code) }
    }
}
