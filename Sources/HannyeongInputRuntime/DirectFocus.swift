import AppKit
import ApplicationServices
import Carbon

struct DirectFocus {
    struct RouteError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }
    let pid: pid_t
    let field: AXUIElement
    let window: AXUIElement
    let commands: KeyboardOutput.Commands

    struct Probe {
        let pid: pid_t?
        let target: DirectFocus?
    }

    static func capture() throws -> DirectFocus? { try probe().target }

    static func probe() throws -> Probe {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var value: CFTypeRef?
        let focused = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        if focused == .noValue { return .init(pid: nil, target: nil) }
        guard focused == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw RouteError(detail: "Reading the input route failed (AX \(focused.rawValue)).")
        }
        let field = value as! AXUIElement
        AXUIElementSetMessagingTimeout(field, 0.1)
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, pid > 0 else {
            throw RouteError(detail: "The focused input field has no process owner.")
        }
        var role: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role)
        guard roleStatus == .success else {
            throw RouteError(detail: "Reading the input route role failed (AX \(roleStatus.rawValue)).")
        }
        guard let roleName = role as? String, [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(roleName)
        else { return .init(pid: pid, target: nil) }
        var enabled: CFTypeRef?
        let enabledStatus = AXUIElementCopyAttributeValue(field, kAXEnabledAttribute as CFString, &enabled)
        guard enabledStatus == .success || enabledStatus == .attributeUnsupported || enabledStatus == .noValue else {
            throw RouteError(detail: "Reading the input route enabled state failed (AX \(enabledStatus.rawValue)).")
        }
        if enabled as? Bool == false { return .init(pid: pid, target: nil) }
        var subrole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole)
        guard status == .success || status == .attributeUnsupported || status == .noValue else {
            throw RouteError(detail: "Reading the focused field role failed (AX \(status.rawValue)).")
        }
        guard subrole as? String != kAXSecureTextFieldSubrole else { return .init(pid: pid, target: nil) }
        var valueWritable: DarwinBoolean = false
        let capabilityStatus = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &valueWritable)
        guard capabilityStatus == .success || capabilityStatus == .attributeUnsupported else {
            throw RouteError(detail: "Reading input editing capabilities failed (AX \(capabilityStatus.rawValue)).")
        }
        return .init(pid: pid, target: DirectFocus(pid: pid, field: field, window: try element(field, kAXWindowAttribute),
                                                 commands: valueWritable.boolValue ? .keyBindings : .controlCharacters))
    }

    func validate() throws -> Bool {
        guard let current = try Self.capture() else { return false }
        // System-wide focus covers non-activating panels such as Spotlight.
        guard current.pid == pid, CFEqual(field, current.field), CFEqual(window, current.window) else {
            return false
        }
        // AX validation runs on a worker. TIS property access requires the main
        // queue; the tap's enabled/generation guards reject source changes there.
        return true
    }

    func matches(_ other: DirectFocus) -> Bool {
        pid == other.pid && CFEqual(field, other.field) && CFEqual(window, other.window)
    }

    /// AX uses screen coordinates with a top-left origin. Called only on the candidate worker.
    func caretBounds() throws -> CGRect {
        var selected: CFTypeRef?
        let selectionStatus = AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selected)
        guard selectionStatus == .success, let selected, CFGetTypeID(selected) == AXValueGetTypeID() else {
            throw RouteError(detail: "Reading the candidate caret range failed (AX \(selectionStatus.rawValue)).")
        }
        var range = CFRange()
        guard AXValueGetValue(selected as! AXValue, .cfRange, &range) else {
            throw RouteError(detail: "The candidate caret range is invalid.")
        }
        range.location += range.length
        range.length = 0
        let parameter = AXValueCreate(.cfRange, &range)!
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                              parameter, &value)
        var bounds = CGRect.zero
        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgRect, &bounds) else {
            throw RouteError(detail: "Reading the candidate caret bounds failed (AX \(status.rawValue)).")
        }
        return bounds
    }

    private static func element(_ owner: AXUIElement, _ name: String) throws -> AXUIElement {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(owner, name as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw RouteError(detail: "Reading the direct-input focus failed (AX \(status.rawValue)).")
        }
        return value as! AXUIElement
    }
}

enum DirectInputSource {
    static let direct = "com.yeop.inputmethod.HannyeongDirectSource"
    static func initialLanguage(for id: String, defaults: UserDefaults = .standard) throws -> DirectBackfill.Language {
        if id == direct {
            if let saved = defaults.string(forKey: "direct.preferredLanguage"), let language = DirectBackfill.Language(rawValue: saved) { return language }
            return .korean
        }
        if id == "com.yeop.inputmethod.Hannyeong" {
            // This domain can reject init(suiteName:), including from its own IME process.
            // Read the existing preference directly; an absent preference means the defined Korean default.
            return try nativeLanguage(CFPreferencesCopyAppValue("composition.previewEnglish" as CFString, id as CFString))
        }
        let matches = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
        guard let source = matches.first, let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            throw DirectFailure(detail: "The previous input language could not be read.")
        }
        let languages = Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue() as! [String]
        return languages.contains("ko") ? .korean : .english
    }
    static func nativeLanguage(_ preference: CFPropertyList?) throws -> DirectBackfill.Language {
        guard let preference else { return .korean }
        guard let english = preference as? Bool else {
            throw DirectFailure(detail: "The native input language preference is not a Boolean.")
        }
        return english ? .english : .korean
    }
    static func current() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)!
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
    static func select(_ id: String) throws {
        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first else { throw DirectFailure(detail: "The requested keyboard source is unavailable.") }
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw DirectFailure(detail: "Keyboard source selection failed (\(status)).") }
    }
}
