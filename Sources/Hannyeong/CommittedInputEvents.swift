import AppKit
import ApplicationServices
import os

/// Hold keys before the host receives them. Chromium dispatches raw editing keys even
/// when IMK returns true without changing marked text, so buffering inside IMK is too late.
final class CommittedInputEvents: @unchecked Sendable {
    static let shared = CommittedInputEvents()
    static let forwardedEventMarker: Int64 = 0x48414E4657444544
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var owner: String?
    private var processID: pid_t?
    private var events: [CGEvent] = []
    private var releasing = false
    private var failed = false
    private static let flushMarker: Int64 = 0x48414E4E59454F4E

    @MainActor func pause(owner: String, hostBundleID: String) throws {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == hostBundleID else {
            throw CommittedTextSelection.Failure.invalidTarget("input queue application changed")
        }
        try start()
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { throw CommittedTextSelection.Failure.invalidTarget("input event tap stopped") }
        guard self.owner == nil || self.owner == owner else {
            throw CommittedTextSelection.Failure.invalidTarget("another committed edit owns the input queue")
        }
        self.owner = owner
        processID = front.processIdentifier
        releasing = false
    }

    @MainActor func release(owner: String) {
        lock.lock()
        guard self.owner == owner, !releasing else { lock.unlock(); return }
        if events.isEmpty {
            self.owner = nil
            processID = nil
            lock.unlock()
            return
        }
        releasing = true
        lock.unlock()
        // Flush inside the tap, after older physical keys have reached it. Posting the
        // queued keys back to HID would let a newer physical key overtake them.
        let marker = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        marker.setIntegerValueField(.eventSourceUserData, value: Self.flushMarker)
        marker.post(tap: .cgSessionEventTap)
    }

    func cancel(owner: String) {
        lock.lock()
        defer { lock.unlock() }
        guard self.owner == owner else { return }
        self.owner = nil
        processID = nil
        events.removeAll()
        releasing = false
    }

    @MainActor private func start() throws {
        if tap != nil { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, context in
                    let queue = Unmanaged<CommittedInputEvents>.fromOpaque(context!).takeUnretainedValue()
                    return queue.receive(proxy, type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            lock.lock(); tap = created; lock.unlock()
            guard let created else { ready.signal(); return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)!
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Hannyeong committed input queue"
        thread.start()
        ready.wait()
        guard tap != nil else { throw CommittedTextSelection.Failure.invalidTarget("input event tap could not be created") }
    }

    private func receive(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        defer { lock.unlock() }
        if type == .keyUp, event.getIntegerValueField(.eventSourceUserData) == Self.flushMarker {
            guard releasing else { return nil }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID {
                // Deliver one key-down, then wait for IMK to finish it before releasing
                // the next. That key may start another asynchronous committed edit.
                let count = events.firstIndex(where: { $0.type == .keyDown }).map { $0 + 1 } ?? events.count
                let batch = Array(events.prefix(count))
                events.removeFirst(count)
                releasing = false
                for queued in batch { queued.tapPostEvent(proxy) }
                if !batch.contains(where: { $0.type == .keyDown }) {
                    owner = nil
                    processID = nil
                }
                return nil
            }
            events.removeAll()
            owner = nil
            processID = nil
            releasing = false
            return nil
        }
        // A host command already being awaited by the IMK queue must reach the host
        // before that queue can release any later physical keys.
        if event.getIntegerValueField(.eventSourceUserData) == Self.forwardedEventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            failed = true
            owner = nil
            events.removeAll()
            Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "Composition")
                .error("Committed input event tap stopped")
            Task { @MainActor in AppSupport.shared.showError("입력 대기를 처리하지 못했습니다. 한녕을 다시 실행해 주세요.") }
            return Unmanaged.passUnretained(event)
        }
        guard owner != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
            return Unmanaged.passUnretained(event)
        }
        events.append(event.copy()!)
        return nil
    }
}
