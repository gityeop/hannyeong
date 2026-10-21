import AppKit
import Carbon
import os

/// Secure input belongs to the system keyboard, never to our composition or event tap.
@MainActor
final class SecureInputSource: NSObject {
    private let hannyeong = "com.yeop.inputmethod.Hannyeong"
    private let ascii = "com.apple.keylayout.ABC"
    private let logger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "SecureInput")
    private var timer: Timer?
    private var previousSource = ""
    private var secure = false
    private var restoreHannyeong = false
    private var failed = false

    func start() {
        previousSource = currentSource()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(check),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        // Secure input can start without an input-source notification. This check never reads keys or text.
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(check), userInfo: nil, repeats: true)
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    @objc private func check() {
        guard !failed else { return }
        let enabled = IsSecureEventInputEnabled()
        let source = currentSource()
        if enabled {
            if !secure {
                restoreHannyeong = source == hannyeong || previousSource == hannyeong
                secure = true
                if restoreHannyeong { logger.notice("Secure input entered; remembering Hannyeong") }
            }
            if restoreHannyeong, source == hannyeong { select(ascii) }
        } else {
            let restore = secure && restoreHannyeong && source == ascii
            secure = false
            restoreHannyeong = false
            if restore { select(hannyeong) }
            previousSource = currentSource()
        }
    }

    private func currentSource() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)!
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private func select(_ id: String) {
        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false)
            .takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first else {
            logger.error("Secure input source is unavailable: \(id, privacy: .public)")
            failed = true
            timer?.invalidate()
            return
        }
        let status = TISSelectInputSource(source)
        if status == noErr {
            logger.notice("Secure input source selected: \(id, privacy: .public)")
        } else {
            logger.error("Secure input source selection failed: \(id, privacy: .public), status=\(status)")
            failed = true
            timer?.invalidate()
        }
    }
}
