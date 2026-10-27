import AppKit
import ApplicationServices

enum TerminalInputReplacement {
    /// Codex's bundled xterm labels its input textarea "Terminal input".
    /// Detect that field, rather than changing every input field in the app.
    @MainActor static func applies(hostBundleID: String?) async throws -> Bool {
        if hostBundleID == "com.apple.Terminal" { return true }
        guard hostBundleID == "com.openai.codex" else { return false }
        guard CommittedTextSelection.isTrusted else { throw CommittedTextSelection.Failure.permissionRequired }
        let pid = try CommittedTextSelection.hostApplication(hostBundleID).processIdentifier
        return try await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
            guard status == .success else {
                throw CommittedTextSelection.Failure.accessibility("terminal field", status)
            }
            guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                throw CommittedTextSelection.Failure.invalidTarget("terminal field missing")
            }
            let field = focused as! AXUIElement
            var labels: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(field,
                [kAXTitleAttribute, kAXDescriptionAttribute] as CFArray, [], &labels)
            guard result == .success else {
                throw CommittedTextSelection.Failure.accessibility("terminal label", result)
            }
            guard let labels else {
                throw CommittedTextSelection.Failure.invalidTarget("terminal labels missing")
            }
            return (labels as [AnyObject]).contains { ($0 as? String) == "Terminal input" }
        }.value
    }
}
