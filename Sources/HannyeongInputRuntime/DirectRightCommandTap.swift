import AppKit

/// Only the gesture waits for a second tap. Physical typing never waits.
struct DirectRightCommandTap {
    enum Action { case waiting, correction }
    static let interval: TimeInterval = 0.25
    private var pressedAt: CGEventTimestamp?
    private var firstRelease: CGEventTimestamp?
    var isPressed: Bool { pressedAt != nil }
    var hasPending: Bool { firstRelease != nil }

    mutating func handle(_ event: CGEvent) -> Action? {
        let other = event.flags.intersection([.maskShift, .maskControl, .maskAlternate])
        guard other.isEmpty, event.flags.rawValue & 0x08 == 0 else { cancel(); return nil }
        if event.flags.contains(.maskCommand) {
            pressedAt = event.timestamp
            return nil
        }
        let down = pressedAt
        pressedAt = nil
        guard let down, event.timestamp >= down, event.timestamp - down <= 500_000_000 else {
            cancel(); return nil
        }
        if let firstRelease, down >= firstRelease, down - firstRelease <= 250_000_000 {
            cancel()
            return .correction
        }
        firstRelease = event.timestamp
        return .waiting
    }

    mutating func takeSingle() -> Bool {
        guard hasPending, !isPressed else { return false }
        firstRelease = nil
        return true
    }

    mutating func cancel() { pressedAt = nil; firstRelease = nil }
}
