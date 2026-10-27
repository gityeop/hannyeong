import AppKit

/// Each batch enters the event stream after our tap, before the triggering host key.
enum KeyboardOutput {
    enum Commands { case keyBindings, controlCharacters }
    static let tapLocation: CGEventTapLocation = .cgAnnotatedSessionEventTap
    static let outputMarker: Int64 = 0x48414E4449524F55
    static let wakeMarker: Int64 = 0x48414E444952574B

    static func events(for edit: DirectSession.Edit, routingEvent: CGEvent, commands: Commands = .keyBindings) throws -> [CGEvent] {
        var result: [CGEvent] = []
        if commands == .keyBindings {
            // Keep the text unchanged while selecting the owned suffix. One insertion
            // replaces it, so search completions never observe partially deleted words.
            for _ in 0..<edit.deleteCount {
                result += try pair(code: 123, text: "\u{F702}", flags: .maskShift, routingEvent: routingEvent)
            }
            if !edit.text.isEmpty {
                result += try pair(code: 0, text: edit.text, routingEvent: routingEvent)
            } else if edit.deleteCount > 0 {
                result += try pair(code: 51, text: "\u{08}", routingEvent: routingEvent)
            }
        } else {
            for _ in 0..<edit.deleteCount {
                result += try pair(code: 11, text: nil, flags: .maskControl, routingEvent: routingEvent)
                result += try pair(code: 2, text: nil, flags: .maskControl, routingEvent: routingEvent)
            }
            for character in edit.text { result += try pair(code: 0, text: String(character), routingEvent: routingEvent) }
        }
        return result
    }

    private static func pair(code: CGKeyCode, text: String?, flags: CGEventFlags = [], routingEvent: CGEvent) throws -> [CGEvent] {
        let down: CGEvent, up: CGEvent
        if text == nil {
            guard let source = CGEventSource(stateID: .privateState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                throw DirectFailure(detail: "An editing command event could not be created.")
            }
            down = keyDown; up = keyUp
            for event in [down, up] {
                for field: CGEventField in [.eventTargetUnixProcessID, .eventTargetProcessSerialNumber] {
                    event.setIntegerValueField(field, value: routingEvent.getIntegerValueField(field))
                }
            }
        } else {
            guard let keyDown = routingEvent.copy(), let keyUp = routingEvent.copy() else {
                throw DirectFailure(detail: "A direct keyboard output event could not be created.")
            }
            down = keyDown; up = keyUp
        }
        down.type = .keyDown
        up.type = .keyUp
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            event.setIntegerValueField(.eventSourceUserData, value: outputMarker)
            if let text {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            }
        }
        return [down, up]
    }

    static func text(_ event: CGEvent) -> String {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        var units = [UniChar](repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: $0.baseAddress) }
        return String(utf16CodeUnits: units, count: length)
    }

    static func wake() throws -> CGEvent {
        guard let event = CGEvent(source: nil) else { throw DirectFailure(detail: "The direct-input wake event could not be created.") }
        // Post directly to the conversion tap; null events do not cross tap stages.
        event.type = .null
        event.setIntegerValueField(.eventSourceUserData, value: wakeMarker)
        return event
    }
}
