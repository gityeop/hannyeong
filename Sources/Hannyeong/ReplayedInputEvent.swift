import AppKit
import ApplicationServices

/// Host commands buffered during an AX edit retain their normal Return/navigation behavior.
@MainActor
enum ReplayedInputEvent {
    private struct Pending {
        let pid: pid_t
        let modifiers: NSEvent.ModifierFlags
        let code: UInt16
        let continuation: CheckedContinuation<Void, Error>
    }
    private static var sequence = 0
    private static var pending: [Int: Pending] = [:]

    static func forward(_ event: NSEvent) async throws {
        guard CGPreflightPostEventAccess(), let original = CGEvent(keyboardEventSource: nil, virtualKey: event.keyCode, keyDown: true),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw CommittedTextSelection.Failure.invalidTarget("host event unavailable")
        }
        sequence += 1
        let id = sequence
        original.setIntegerValueField(.eventSourceUserData, value: CommittedInputEvents.forwardedEventMarker)
        original.flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(pid: pid, modifiers: event.modifierFlags.intersection([.command, .control, .option, .shift, .capsLock]),
                                  code: event.keyCode, continuation: continuation)
            original.post(tap: .cghidEventTap)
            let released = original.copy()!
            released.type = .keyUp
            released.post(tap: .cghidEventTap)
        }
    }

    /// IMK reconstructs NSEvent without the original timestamp or CGEvent identifiers.
    /// Only one host command is forwarded at a time while subsequent events stay buffered.
    static func consume(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift, .capsLock])
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let entry = pending.first(where: { $0.value.pid == pid && $0.value.code == event.keyCode && $0.value.modifiers == modifiers }) else { return false }
        guard event.type == .keyDown else { return false }
        pending.removeValue(forKey: entry.key)
        let command = entry.value
        // Read from AX after returning false to observe completion of the host command.
        Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(command.pid)
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
            if status == .success { command.continuation.resume() }
            else { command.continuation.resume(throwing: CommittedTextSelection.Failure.accessibility("forwarded host command", status)) }
        }
        return true
    }
}
