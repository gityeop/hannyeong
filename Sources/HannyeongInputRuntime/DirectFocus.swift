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
    // The system save panel exposes its filename field without an AXWindow value.
    // Field identity and process ownership remain mandatory even on that surface.
    let window: AXUIElement?
    let commands: KeyboardOutput.Commands
    var sheet: AXUIElement?
    var keyboardTargets: Set<Int64> = []
    var hostBundleID: String?
    var isMenuInput = false
    var usesOpenAIKeyboardRoute = false
    var keyboardOwnerForFocus: pid_t?

    struct Probe {
        let pid: pid_t?
        let target: DirectFocus?
    }

    static func capture(for keyboardPID: pid_t?) throws -> DirectFocus? { try probe(for: keyboardPID).target }

    static func probe(for keyboardPID: pid_t? = nil) throws -> Probe {
        let application = NSWorkspace.shared.frontmostApplication
        let openAIPID = application?.bundleIdentifier == TypingEngine.openAIKeyboardBundleID ? application?.processIdentifier : nil
        let scopedPID = keyboardPID == nil || keyboardPID == openAIPID ? openAIPID : nil
        let root = scopedPID.map(AXUIElementCreateApplication) ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.1)
        var value: CFTypeRef?
        let focused = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
        if focused == .noValue { return .init(pid: nil, target: nil) }
        guard focused == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw RouteError(detail: "Reading the input route failed (AX \(focused.rawValue)).")
        }
        let focusedField = value as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(focusedField, &pid) == .success, pid > 0 else {
            throw RouteError(detail: "The focused input field has no process owner.")
        }
        if let scopedPID, scopedPID != pid { return .init(pid: pid, target: nil) }
        guard let field = try inputField(for: focusedField) else {
            return .init(pid: pid, target: nil)
        }
        AXUIElementSetMessagingTimeout(field, 0.1)
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
        let window = try inputWindow(for: field)
        var target = DirectFocus(pid: pid, field: field, window: window,
                                 commands: valueWritable.boolValue ? .keyBindings : .controlCharacters)
        target.hostBundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        target.usesOpenAIKeyboardRoute = scopedPID != nil
        target.isMenuInput = try inputIsInMenu(field)
        if window == nil, let sheet = try inputSheet(for: field) {
            target.sheet = sheet
            // AX represents the sheet under its host app, while AppKit sends keys
            // to its system panel service. Discover that transport off the key tap.
            let serviceID = "com.apple.appkit.xpc.openAndSavePanelService"
            let servicePath = "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/\(serviceID).xpc"
            target.keyboardTargets = Set(NSRunningApplication.runningApplications(withBundleIdentifier: serviceID)
                .filter { $0.bundleURL?.path == servicePath }.map { Int64($0.processIdentifier) })
        }
        if let keyboardPID {
            guard target.acceptsKeyboardTarget(Int64(keyboardPID)) else { return .init(pid: pid, target: nil) }
            target.keyboardOwnerForFocus = keyboardPID
        }
        return .init(pid: pid, target: target)
    }

    /// Cold key admission only needs the foreground OpenAI composer's writable text area.
    static func initialOpenAIComposer(pid: pid_t) throws -> DirectFocus? {
        let messagingTimeout: Float = 0.012
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        let focused = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        if focused == .noValue { return nil }
        guard focused == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw RouteError(detail: "Reading the OpenAI composer focus failed (AX \(focused.rawValue)).")
        }
        let field = value as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(field, &owner) == .success, owner == pid else { return nil }
        AXUIElementSetMessagingTimeout(field, messagingTimeout)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute, kAXWindowAttribute]
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(field, names as CFArray, [], &values)
        guard result == .success, let attributes = values as? [AnyObject], attributes.count == names.count else {
            throw RouteError(detail: "Reading the OpenAI composer attributes failed (AX \(result.rawValue)).")
        }
        guard attributes[0] as? String == kAXTextAreaRole,
              attributes[1] as? String != kAXSecureTextFieldSubrole,
              attributes[2] as? Bool == true, CFGetTypeID(attributes[3]) == AXUIElementGetTypeID() else { return nil }
        var writable: DarwinBoolean = false
        let capability = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &writable)
        guard capability == .success else {
            throw RouteError(detail: "Reading the OpenAI composer's editing capability failed (AX \(capability.rawValue)).")
        }
        guard writable.boolValue else { return nil }
        return DirectFocus(pid: pid, field: field, window: (attributes[3] as! AXUIElement),
                           commands: .keyBindings, hostBundleID: TypingEngine.openAIKeyboardBundleID,
                           usesOpenAIKeyboardRoute: true)
    }

    /// aria-activedescendant gives AX focus to a suggestion while the editor keeps keyboard focus.
    /// Resolve the editor through its explicit aria-controls / AXLinkedUIElements relationship.
    static func inputField(for focused: AXUIElement,
                           read: (AXUIElement, String) throws -> CFTypeRef? = readAttribute) throws -> AXUIElement? {
        func isText(_ element: AXUIElement) throws -> Bool {
            let role = try read(element, kAXRoleAttribute) as? String
            return [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role ?? "")
        }
        if try isText(focused) { return focused }

        var ancestors: [AXUIElement] = [], node: AXUIElement? = focused
        while let current = node, !ancestors.contains(where: { CFEqual($0, current) }) {
            ancestors.append(current)
            let role = try read(current, kAXRoleAttribute) as? String
            if role == "AXWebArea" || role == kAXWindowRole { break }
            node = try read(current, kAXParentAttribute) as! AXUIElement?
        }
        // Ordinary menus and other non-text controls do not own a web autocomplete editor.
        guard try ancestors.contains(where: { try read($0, kAXRoleAttribute) as? String == kAXListRole }),
              try ancestors.contains(where: { try read($0, kAXRoleAttribute) as? String == "AXWebArea" }) else { return nil }
        var visited: [AXUIElement] = []
        func editor(in element: AXUIElement) throws -> AXUIElement? {
            guard !visited.contains(where: { CFEqual($0, element) }) else { return nil }
            visited.append(element)
            if try isText(element),
               let linked = try read(element, kAXLinkedUIElementsAttribute) as? [AXUIElement],
               linked.contains(where: { link in ancestors.contains { CFEqual($0, link) } }),
               try read(element, kAXSelectedTextRangeAttribute) != nil {
                return element
            }
            for child in try read(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let result = try editor(in: child) { return result }
            }
            return nil
        }
        for ancestor in ancestors {
            if let result = try editor(in: ancestor) { return result }
        }
        return nil
    }

    private static func readAttribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success else {
            throw RouteError(detail: "Reading autocomplete input \(name) failed (AX \(status.rawValue)).")
        }
        return value
    }

    static func inputIsInMenu(_ field: AXUIElement,
                              read: (AXUIElement, String) throws -> CFTypeRef? = readAttribute) throws -> Bool {
        var node: AXUIElement? = field
        var visited: [AXUIElement] = []
        while let current = node, !visited.contains(where: { CFEqual($0, current) }) {
            visited.append(current)
            let role = try read(current, kAXRoleAttribute) as? String
            if role == kAXMenuRole { return true }
            if role == kAXWindowRole || role == kAXApplicationRole { return false }
            node = try read(current, kAXParentAttribute) as! AXUIElement?
        }
        return false
    }

    func validate() throws -> Bool {
        guard let current = try Self.capture(for: keyboardOwnerForFocus ?? pid) else { return false }
        // System-wide focus covers non-activating panels such as Spotlight.
        guard matches(current) else { return false }
        // AX validation runs on a worker. TIS property access requires the main
        // queue; the tap's enabled/generation guards reject source changes there.
        return true
    }

    func matches(_ other: DirectFocus) -> Bool {
        guard pid == other.pid, CFEqual(field, other.field) else { return false }
        switch (sheet, other.sheet) {
        case (nil, nil): break
        case let (sheet?, otherSheet?): if !CFEqual(sheet, otherSheet) { return false }
        default: return false
        }
        switch (window, other.window) {
        case (nil, nil): return true
        case let (window?, otherWindow?): return CFEqual(window, otherWindow)
        default: return false
        }
    }

    func acceptsKeyboardTarget(_ targetPID: Int64) -> Bool {
        (!usesOpenAIKeyboardRoute && targetPID <= 0) || targetPID == Int64(pid) || keyboardTargets.contains(targetPID)
    }

    static func inputSheet(for field: AXUIElement,
                           read: (AXUIElement, String) throws -> CFTypeRef? = readAttribute) throws -> AXUIElement? {
        var node: AXUIElement? = field
        var visited: [AXUIElement] = []
        while let current = node, !visited.contains(where: { CFEqual($0, current) }) {
            visited.append(current)
            let role = try read(current, kAXRoleAttribute) as? String
            if role == kAXSheetRole { return current }
            if role == kAXWindowRole || role == kAXApplicationRole { return nil }
            guard let parent = try read(current, kAXParentAttribute) else { return nil }
            guard CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                throw RouteError(detail: "The input sheet parent is not an accessibility element.")
            }
            node = (parent as! AXUIElement)
        }
        return nil
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

    static func inputWindow(for field: AXUIElement,
                            read: (AXUIElement, String) -> (AXError, CFTypeRef?) = { element, name in
                                var value: CFTypeRef?
                                let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                                return (status, value)
                            }) throws -> AXUIElement? {
        let (status, value) = read(field, kAXWindowAttribute)
        if status == .noValue { return nil }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw RouteError(detail: "Reading the input window failed (AX \(status.rawValue)).")
        }
        return (value as! AXUIElement)
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
