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
        var received = false
    }
    private static var sequence = 0
    private static var pending: [Int: Pending] = [:]

    static func forward(_ event: NSEvent, hostBundleID: String?) async throws {
        let pid = try CommittedTextSelection.hostApplication(hostBundleID).processIdentifier
        guard CGPreflightPostEventAccess(), let original = CGEvent(keyboardEventSource: nil, virtualKey: event.keyCode, keyDown: true) else {
            throw CommittedTextSelection.Failure.invalidTarget("host event unavailable")
        }
        sequence += 1
        let id = sequence
        original.setIntegerValueField(.eventSourceUserData, value: CommittedInputEvents.forwardedEventMarker)
        original.flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(pid: pid, modifiers: event.modifierFlags.intersection([.command, .control, .option, .shift, .capsLock]),
                                      code: event.keyCode, continuation: continuation)
                let released = original.copy()!
                released.type = .keyUp
                original.post(tap: .cghidEventTap)
                released.post(tap: .cghidEventTap)
            }
        } onCancel: {
            Task { @MainActor in
                if let command = pending.removeValue(forKey: id) {
                    command.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    /// IMK reconstructs NSEvent without the original timestamp or CGEvent identifiers.
    /// Only one host command is forwarded at a time while subsequent events stay buffered.
    static func consume(_ event: NSEvent, hostBundleID: String?) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift, .capsLock])
        guard let entry = pending.first(where: {
            !$0.value.received && NSRunningApplication(processIdentifier: $0.value.pid)?.bundleIdentifier == hostBundleID &&
                $0.value.code == event.keyCode && $0.value.modifiers == modifiers
        }) else { return false }
        guard event.type == .keyDown else { return false }
        pending[entry.key]?.received = true
        let command = entry.value
        // A focus read acknowledges dispatch only; it does not prove a terminal text edit completed.
        Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(command.pid)
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
            await MainActor.run {
                guard let acknowledged = pending.removeValue(forKey: entry.key) else { return }
                if status == .success { acknowledged.continuation.resume() }
                else { acknowledged.continuation.resume(throwing: CommittedTextSelection.Failure.accessibility("forwarded host command", status)) }
            }
        }
        return true
    }
}
