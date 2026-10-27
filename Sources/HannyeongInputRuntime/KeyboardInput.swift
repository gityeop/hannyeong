import AppKit
import Carbon

/// Direct's input source uses ABC. Decode its physical keys even when CGEvent has no Unicode payload.
struct KeyboardInput {
    /// Software Unicode payloads are text, not a physical key at their placeholder keycode.
    static func isSoftwareText(_ event: CGEvent, systemKeyboardPIDs: Set<Int64> = []) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp,
              event.getIntegerValueField(.eventSourceUnixProcessID) > 0 else { return false }
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        // macOS remote keyboards attach Unicode and a source PID to real virtual keys.
        // Keep multi-unit completed text intact, including text from the same producer.
        if length == 1, systemKeyboardPIDs.contains(event.getIntegerValueField(.eventSourceUnixProcessID)) { return false }
        return length > 0
    }

    static func isFunctionKey(_ code: Int64) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].contains(Int(code))
    }
    private let layout: Data

    init() throws {
        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: "com.apple.keylayout.ABC"] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first,
              let value = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw DirectFailure(detail: "The Direct ABC keyboard layout is unavailable.")
        }
        layout = Unmanaged<CFData>.fromOpaque(value).takeUnretainedValue() as Data
    }

    func text(_ event: CGEvent) throws -> String {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = UInt16(exactly: code) else { throw DirectFailure(detail: "The physical key code is invalid.") }
        var modifiers: UInt32 = 0
        if event.flags.contains(.maskShift) { modifiers |= UInt32(shiftKey >> 8) }
        if event.flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock >> 8) }
        var deadKey: UInt32 = 0, length = 0
        var units = [UniChar](repeating: 0, count: 8)
        let status = layout.withUnsafeBytes { bytes in
            units.withUnsafeMutableBufferPointer { output in
                UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!, key,
                    UInt16(kUCKeyActionDown), modifiers,
                    UInt32(event.getIntegerValueField(.keyboardEventKeyboardType)),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, output.count, &length, output.baseAddress!)
            }
        }
        guard status == noErr else { throw DirectFailure(detail: "Physical key translation failed (\(status)).") }
        return String(utf16CodeUnits: units, count: length)
    }
}
