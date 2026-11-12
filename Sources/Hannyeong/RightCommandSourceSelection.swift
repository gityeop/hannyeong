import AppKit
import Carbon
import os

/// IMK only sees keys while 한녕 is selected. From any other source, a lone right Command tap selects 한녕;
/// while 한녕 is selected the controller's RightCommandGesture keeps the tap.
@MainActor
final class RightCommandSourceSelection {
    private let sourceID: String
    private let logger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "Shortcut")
    private var monitors: [Any] = []
    private var pressedAt: TimeInterval?

    init(sourceID: String) { self.sourceID = sourceID }

    func start() {
        // Global monitors receive key events only for trusted processes; without the permission this stays silent.
        if !AXIsProcessTrusted() {
            logger.error("Right Command source selection needs Accessibility permission")
        }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pressedAt = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged, event.keyCode == 54 else { pressedAt = nil; return }
        if event.modifierFlags.contains(.command) {
            let otherModifiers = event.modifierFlags.intersection([.shift, .control, .option])
            // 0x08 is the left Command device bit: both Commands held is not a right Command tap.
            pressedAt = otherModifiers.isEmpty && event.modifierFlags.rawValue & 0x08 == 0 ? event.timestamp : nil
            return
        }
        guard let down = pressedAt else { return }
        pressedAt = nil
        guard event.timestamp - down <= 0.5, !IsSecureEventInputEnabled() else { return }
        selectHannyeong()
    }

    private func selectHannyeong() {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let currentID = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else {
            logger.error("Current input source has no identifier")
            return
        }
        if Unmanaged<CFString>.fromOpaque(currentID).takeUnretainedValue() as String == sourceID { return }
        let matches = TISCreateInputSourceList([kTISPropertyInputSourceID: sourceID] as CFDictionary, false)
            .takeRetainedValue() as! [TISInputSource]
        guard let source = matches.first else {
            logger.error("Right Command source selection: 한녕 is not enabled")
            return
        }
        let status = TISSelectInputSource(source)
        guard status == noErr else {
            logger.error("Right Command source selection failed: status=\(status)")
            return
        }
        logger.notice("Right Command selected 한녕")
    }
}
