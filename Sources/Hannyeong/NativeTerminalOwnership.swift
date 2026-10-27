import AppKit
import ApplicationServices
import Darwin

/// Terminal reports the caret in display cells but AX strings use UTF-16 offsets.
enum TerminalCaretMapping {
    static func logicalCaret(_ caret: NSRange, lineStart: Int, lineText: String) throws -> Int {
        guard caret.length == 0, caret.location >= lineStart,
              let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else {
            throw CommittedTextSelection.Failure.invalidTarget("terminal caret cannot be mapped")
        }
        let previous = uselocale(locale)
        defer { uselocale(previous); freelocale(locale) }
        let column = caret.location - lineStart
        var cells = 0, offset = 0
        for character in lineText {
            if cells == column { return lineStart + offset }
            // Do not guess the display width of a joined grapheme.
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
                throw CommittedTextSelection.Failure.invalidTarget("terminal grapheme width is unavailable")
            }
            let width = Int(wcwidth(wchar_t(scalar.value)))
            guard width > 0, cells + width <= column else {
                throw CommittedTextSelection.Failure.invalidTarget("terminal caret is inside a display cell")
            }
            cells += width
            offset += String(character).utf16.count
        }
        guard cells == column else {
            throw CommittedTextSelection.Failure.invalidTarget("terminal caret is outside its line")
        }
        return lineStart + offset
    }
}

/// Completion is observable text and caret state, not receipt of the IME event.
struct TerminalEditConfirmation {
    let originalBefore: String
    let originalCaret: Int
    let expected: String
    private let prefix: String

    init(before: String, caret: Int, expected: String) throws {
        guard before.hasSuffix(expected), caret >= expected.utf16.count else {
            throw CommittedTextSelection.Failure.invalidTarget("terminal owned suffix changed")
        }
        self.originalBefore = before
        self.originalCaret = caret
        self.expected = expected
        self.prefix = String(before.dropLast(expected.count))
    }

    func observed(before: String, caret: Int, replacement: String) throws -> Bool {
        if before == prefix + replacement,
           caret == originalCaret - expected.utf16.count + replacement.utf16.count { return true }
        guard before == originalBefore, caret == originalCaret else {
            throw CommittedTextSelection.Failure.invalidTarget("terminal edit changed outside its owned suffix")
        }
        return false
    }
}

/// A read-only lease around one input-client write. Only an unchanged pre-state may wait for echo.
enum NativeTerminalOwnership {
    struct Edit {
        let confirm: (String) async throws -> Void
    }

    private struct State {
        let field: AXUIElement
        let window: AXUIElement
        let lineStart: Int
        let caret: Int
        let before: String
    }

    @MainActor static func prepare(_ expected: String) async throws -> Edit {
        guard CommittedTextSelection.isTrusted else { throw CommittedTextSelection.Failure.permissionRequired }
        let pid = try CommittedTextSelection.hostApplication("com.apple.Terminal").processIdentifier
        let original = try await Task.detached(priority: .userInitiated) { try read(pid) }.value
        let completion = try TerminalEditConfirmation(before: original.before, caret: original.caret, expected: expected)
        return Edit { replacement in
            try await Task.detached(priority: .userInitiated) {
                let deadline = ContinuousClock.now + .milliseconds(150)
                while true {
                    try Task.checkCancellation()
                    let current = try read(pid)
                    guard CFEqual(current.field, original.field), CFEqual(current.window, original.window),
                          current.lineStart == original.lineStart else { throw CancellationError() }
                    if try completion.observed(before: current.before, caret: current.caret, replacement: replacement) { return }
                    guard ContinuousClock.now < deadline else {
                        throw CommittedTextSelection.Failure.invalidTarget("terminal edit was not confirmed")
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }.value
        }
    }

    private static func read(_ pid: pid_t) throws -> State {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw CancellationError() }
        let app = AXUIElementCreateApplication(pid)
        let field = try element(app, kAXFocusedUIElementAttribute)
        let window = try element(field, kAXWindowAttribute)
        guard CFEqual(window, try element(app, kAXFocusedWindowAttribute)) else { throw CancellationError() }
        var owner: pid_t = 0
        try check(AXUIElementGetPid(field, &owner), "terminal field owner")
        guard owner == pid else { throw CancellationError() }
        let selected = try selection(field)
        let line = try attribute(field, kAXInsertionPointLineNumberAttribute)
        guard CFGetTypeID(line) == CFNumberGetTypeID() else {
            throw CommittedTextSelection.Failure.invalidTarget("terminal insertion line missing")
        }
        let lineValue = try parameter(field, kAXRangeForLineParameterizedAttribute, line)
        let span = try range(lineValue)
        let value = try parameter(field, kAXStringForRangeParameterizedAttribute, lineValue)
        guard let text = value as? String else {
            throw CommittedTextSelection.Failure.invalidTarget("terminal line text missing")
        }
        let caret = try TerminalCaretMapping.logicalCaret(selected, lineStart: span.location, lineText: text)
        let count = caret - span.location
        guard count <= text.utf16.count else {
            throw CommittedTextSelection.Failure.invalidTarget("terminal mapped caret is outside its line")
        }
        let before = (text as NSString).substring(to: count)
        // These reads cross processes. Recheck the same owner before granting the lease.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              CFEqual(field, try element(app, kAXFocusedUIElementAttribute)),
              CFEqual(window, try element(app, kAXFocusedWindowAttribute)),
              selected == (try selection(field)) else { throw CancellationError() }
        return State(field: field, window: window, lineStart: span.location, caret: caret, before: before)
    }

    private static func attribute(_ owner: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(owner, name as CFString, &value), name)
        guard let value else { throw CommittedTextSelection.Failure.invalidTarget("terminal attribute missing") }
        return value
    }

    private static func parameter(_ owner: AXUIElement, _ name: String, _ argument: CFTypeRef) throws -> CFTypeRef {
        var value: CFTypeRef?
        try check(AXUIElementCopyParameterizedAttributeValue(owner, name as CFString, argument, &value), name)
        guard let value else { throw CommittedTextSelection.Failure.invalidTarget("terminal parameter result missing") }
        return value
    }

    private static func element(_ owner: AXUIElement, _ name: String) throws -> AXUIElement {
        let value = try attribute(owner, name)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw CommittedTextSelection.Failure.invalidTarget("terminal ownership element missing")
        }
        return value as! AXUIElement
    }

    private static func range(_ value: CFTypeRef) throws -> NSRange {
        var span = CFRange()
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cfRange, &span),
              span.location >= 0, span.length >= 0 else {
            throw CommittedTextSelection.Failure.invalidTarget("terminal range missing")
        }
        return NSRange(location: span.location, length: span.length)
    }

    private static func selection(_ field: AXUIElement) throws -> NSRange {
        try range(attribute(field, kAXSelectedTextRangeAttribute))
    }

    private static func check(_ status: AXError, _ operation: String) throws {
        guard status == .success else { throw CommittedTextSelection.Failure.accessibility(operation, status) }
    }
}
