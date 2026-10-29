import AppKit
import ApplicationServices
import HannyeongCore

private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw DirectFailure(detail: message) }
}

private final class FocusChecks: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var shouldBlock = false
    private var isValid = true
    private var onMain = false
    private var isText = true
    private var captures = 0
    private var routeError = false
    var failsAX: Bool {
        get { lock.lock(); defer { lock.unlock() }; return routeError }
        set { lock.lock(); defer { lock.unlock() }; routeError = newValue }
    }
    var captureCount: Int { lock.lock(); defer { lock.unlock() }; return captures }
    var textEligible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isText }
        set { lock.lock(); defer { lock.unlock() }; isText = newValue }
    }
    var valid: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isValid }
        set { lock.lock(); defer { lock.unlock() }; isValid = newValue }
    }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    func blockFirstCapture() { lock.lock(); defer { lock.unlock() }; shouldBlock = true }
    func releaseCapture() { gate.signal() }
    func capture(_ pid: pid_t) throws -> DirectFocus? {
        lock.lock()
        captures += 1
        onMain = onMain || Thread.isMainThread
        let block = shouldBlock; shouldBlock = false
        let text = isText
        let failed = routeError
        lock.unlock()
        if block, gate.wait(timeout: .now() + 2) == .timedOut {
            throw DirectFailure(detail: "QA blocked AX capture was not released")
        }
        guard text else { return nil }
        if failed { throw DirectFocus.RouteError(detail: "QA AX communication failure") }
        let element = AXUIElementCreateApplication(pid)
        return DirectFocus(pid: pid, field: element, window: element, commands: .keyBindings)
    }
    func caretBounds() -> CGRect {
        lock.lock(); onMain = onMain || Thread.isMainThread; lock.unlock()
        return CGRect(x: 321, y: 456, width: 1, height: 20)
    }
    func validate() throws -> Bool {
        lock.lock(); onMain = onMain || Thread.isMainThread; let valid = isValid; lock.unlock()
        return valid
    }
}

@MainActor
private final class Harness {
    let nativeMode: Bool
    init(nativeMode: Bool = false) { self.nativeMode = nativeMode }
    let proxy = CGEventTapProxy(bitPattern: 1)!
    let pid = getpid() + 1234
    var text = ""
    var submitted: [String] = []
    var errors: [Error] = []
    var wakeCount = 0
    var routeRefreshes = 0
    var keyDurations: [TimeInterval] = []
    var inlineCompletionVisible = false
    var mutations: [String] = []
    private var backwardMoves = 0
    private var selectedSuffix = 0
    var hostEditable = true
    var deliveredPhysical: [String] = []
    var outputEventCount = 0
    var feedback: [String] = []
    var feedbackShowCount = 0
    var feedbackBounds = CGRect.zero
    var corrections: [(DirectSession.FeedbackTarget, String)] = []
    let focusChecks = FocusChecks()
    var focusValid: Bool {
        get { focusChecks.valid }
        set { focusChecks.valid = newValue }
    }
    var requests: [(DirectSession.Snapshot, CheckedContinuation<DirectSession.Decision, Error>)] = []
    var remoteKeyboardPID: Int64?
    lazy var input: DirectInputTap = try! DirectInputTap(decide: { [self] request in
        try await decision(request)
    }, changed: { _ in }, failure: { [self] in errors.append($0) }, captureFocus: { [self] in
        try focusChecks.capture(pid)
    }, validateFocus: { [self] _ in
        try focusChecks.validate()
    }, post: { [self] event, _ in outputEventCount += 1; host(event) }, wake: { [self] in wakeCount += 1 },
    showFeedback: { [self] candidates, bounds in feedback = candidates; feedbackBounds = bounds; feedbackShowCount += 1 },
    caretBounds: { [self] _ in focusChecks.caretBounds() },
    hideFeedback: { [self] in feedback = [] },
    feedbackCommand: { [self] code, text in
        if code == 36 { input.chooseFeedback(0); return true }
        if let number = Int(text), (1...9).contains(number) { input.chooseFeedback(number - 1); return true }
        return false
    }, correct: { [self] target, preferred in await MainActor.run { corrections.append((target, preferred)) } },
    sourceID: nativeMode ? "com.yeop.inputmethod.Hannyeong" : DirectInputSource.direct, managesInputSource: !nativeMode,
    refreshRoute: { [self] in routeRefreshes += 1 })

    func decision(_ request: DirectSession.Snapshot) async throws -> DirectSession.Decision {
        try await withCheckedThrowingContinuation { requests.append((request, $0)) }
    }

    func settle() async throws {
        for _ in 0..<100 {
            if wakeCount > 0 || !requests.isEmpty || !input.enabled { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func host(_ event: CGEvent, physicalText: String? = nil) {
        guard event.type == .keyDown else { return }
        guard hostEditable else { return }
        let original = text
        defer { if text != original { mutations.append(text) } }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if event.flags.contains(.maskCommand) { return }
        if code == 123, event.flags.contains(.maskShift) {
            inlineCompletionVisible = false
            selectedSuffix = min(selectedSuffix + 1, text.count)
            return
        }
        if selectedSuffix > 0 {
            text.removeLast(selectedSuffix)
            selectedSuffix = 0
            if code == 51 { return }
        }
        if (code == 51 || (code == 4 && event.flags.contains(.maskControl))), inlineCompletionVisible, event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty {
            inlineCompletionVisible = false
            return // Aside's first plain Backspace dismisses its suggestion without deleting text.
        }
        if code == 11, event.flags.contains(.maskControl) {
            inlineCompletionVisible = false
            backwardMoves = min(backwardMoves + 1, text.count)
        }
        else if code == 2, event.flags.contains(.maskControl) {
            if backwardMoves > 0 { text.remove(at: text.index(text.endIndex, offsetBy: -backwardMoves)); backwardMoves -= 1 }
        }
        else if code == 51 || (code == 4 && event.flags.contains(.maskControl)) { if !text.isEmpty { text.removeLast() } }
        else if code == 36 { submitted.append(text); text = "" }
        else if code == 49 { text += " " }
        else { text += physicalText ?? KeyboardOutput.text(event) }
    }
    func key(_ text: String, code: CGKeyCode? = nil, flags: CGEventFlags = [], targetPID: pid_t? = nil) {
        let letterKeys: [Character: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,".":47," ":49]
        let physicalCode = code ?? letterKeys[text.lowercased().first!]!
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: physicalCode, keyDown: down)!
            event.flags = flags
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID ?? pid))
            // Physical events may have no Unicode payload at the session tap.
            event.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
            if let remoteKeyboardPID {
                event.setIntegerValueField(.eventSourceUnixProcessID, value: remoteKeyboardPID)
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            }
            let began = CFAbsoluteTimeGetCurrent()
            input.observeCommand(event.type, event)
            let delivered = input.receive(proxy, event.type, event) != nil
            keyDurations.append(CFAbsoluteTimeGetCurrent() - began)
            if delivered {
                if down { deliveredPhysical.append(text) }
                host(event, physicalText: text)
            }
        }
    }
    func type(_ text: String) { for c in text { key(String(c)) } }
    func softwareText(_ text: String) throws {
        let source = CGEventSource(stateID: .privateState)!
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)!
            event.flags = []
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            input.observeCommand(event.type, event)
            let delivered = input.receive(proxy, event.type, event)?.takeUnretainedValue()
            try require(delivered === event, "Software Unicode down/up was consumed or replaced")
            try require(KeyboardOutput.text(event) == text, "Software Unicode payload was modified")
            host(event)
        }
    }
    func modifier(code: Int64 = 54, down: Bool, time: CGEventTimestamp, extra: CGEventFlags = []) {
        let event = CGEvent(source: nil)!
        event.type = .flagsChanged
        event.timestamp = time
        event.setIntegerValueField(.keyboardEventKeycode, value: code)
        event.flags = (down ? CGEventFlags.maskCommand : []).union(extra)
        _ = input.receive(proxy, .flagsChanged, event)
    }
    func rightTap(time: CGEventTimestamp = 1_000_000_000) {
        modifier(down: true, time: time)
        modifier(down: false, time: time + 50_000_000)
        input.completeSingleTapForQA()
        flushWake()
    }
    func doubleRightTap() {
        modifier(down: true, time: 1_000_000_000)
        modifier(down: false, time: 1_050_000_000)
        modifier(down: true, time: 1_150_000_000)
        modifier(down: false, time: 1_200_000_000)
    }
    func waitForFeedback() async throws {
        for _ in 0..<100 {
            flushWake()
            if !feedback.isEmpty { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw DirectFailure(detail: "The correction candidates did not appear")
    }
    func waitForWake() async throws {
        for _ in 0..<100 {
            if wakeCount > 0 { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw DirectFailure(detail: "The correction selection did not wake the tap")
    }
    func waitForRequest() async throws {
        for _ in 0..<100 {
            if !requests.isEmpty { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw DirectFailure(detail: "The decision request did not start")
    }
    func resolve(_ value: String) async throws {
        try await waitForRequest()
        let (request, continuation) = requests.removeFirst()
        if let separator = request.separator {
            if let manual = request.manualText {
                continuation.resume(returning: .boundary(.init(text: manual, replacement: nil, next: nil)))
                try await settle()
                return
            }
            // Existing tests use certain decisions, so they do not retain ambiguous history.
            let reading = DirectBackfill.Reading(text: value, probabilities: [value: 1])
            let frequencies = try JSONDecoder().decode(WordFrequencies.self, from: Data("{\"english\":{},\"korean\":{}}".utf8))
            let result = try DirectBackfill.resolve(word: .init(raw: request.raw, separator: separator), before: request.before,
                previous: request.recent, decided: reading, alternate: request.recent == nil ? nil : reading, frequencies: frequencies)
            continuation.resume(returning: .boundary(result))
        } else { continuation.resume(returning: .live(try .init(text: value, raw: request.raw))) }
        try await settle()
    }
    func resolveReading(_ decided: DirectBackfill.Reading, alternate: DirectBackfill.Reading?, frequencies: WordFrequencies) async throws {
        try await waitForRequest()
        let (request, continuation) = requests.removeFirst()
        if let separator = request.separator {
            let result = try DirectBackfill.resolve(word: .init(raw: request.raw, separator: separator), before: request.before,
                previous: request.recent, decided: decided, alternate: alternate, frequencies: frequencies)
            continuation.resume(returning: .boundary(result))
        } else { continuation.resume(returning: .live(try .init(text: decided.text, raw: request.raw))) }
        try await settle()
    }
    func flushWake() {
        while wakeCount > 0 {
            wakeCount -= 1
            let event = try! KeyboardOutput.wake()
            _ = input.receive(proxy, event.type, event)
        }
    }
}

@main
struct DirectInputQA {
    @MainActor static func main() async {
        do { try await run(); print("PASS direct input QA (isolated events only; no event tap, posting, or input-source switch)") }
        catch { fputs("Direct input QA failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        try autocompleteFocusChecks()
        do {
            let h = Harness(); h.input.enableForQA(); h.input.beginRouteCheck(); h.type("rmflrh")
            let field = AXUIElementCreateApplication(h.pid)
            h.input.updateRoute(.init(pid: h.pid, field: field, window: field, commands: .keyBindings), known: true)
            h.mutations.removeAll()
            try await h.resolve("그리고"); h.flushWake()
            try require(h.text == "그리고" && h.mutations == ["그리고"], "Correction exposed partially deleted words to the host")
            h.input.reset()
        }
        print("PASS owned suffix replacement exposes one text mutation without an input hold")
        for native in [false, true] {
            for (raw, expected) in [("so", "내"), ("oncast", "oncast"), ("dkssud", "안녕")] {
                let h = Harness(nativeMode: native); h.input.enableForQA()
                h.input.beginRouteCheck()
                h.type(raw)
                try require(h.text == raw && h.outputEventCount == 0 && h.requests.isEmpty,
                            "The first keys typed during rechecking were delayed or rewritten")
                let field = AXUIElementCreateApplication(h.pid)
                h.input.updateRoute(.init(pid: h.pid, field: field, window: field, commands: .keyBindings), known: true)
                try await h.resolve(expected); h.flushWake()
                try require(h.text == expected && h.errors.isEmpty && h.input.enabled,
                            "A word started during rechecking lost its output route: \(h.errors)")
                h.input.reset()
            }
        }
        print("PASS native/Direct first-key-during-recheck: immediate raw delivery, English/Hangul correction, engine remains enabled")
        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA(); h.input.beginRouteCheck()
            h.type("oncast so")
            let field = AXUIElementCreateApplication(h.pid)
            h.input.updateRoute(.init(pid: h.pid, field: field, window: field, commands: .keyBindings), known: true)
            try await h.resolve("oncast"); h.flushWake()
            try await h.resolve("내"); h.flushWake()
            try require(h.text == "oncast 내" && h.errors.isEmpty && h.input.enabled,
                        "A first word started during rechecking lost its route across Space")
            h.input.reset()
        }
        print("PASS native/Direct first-key-during-recheck retains routing across Space and a following Hangul word")
        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA()
            h.input.configure(live: true, fixedEnglish: false, backfill: true)
            h.type("o"); try await h.waitForRequest()
            try require(h.text == "ㅐ", "The continuity fixture did not start with Korean O")
            h.input.beginRouteCheck()
            for character in "ncast" { h.input.beginRouteCheck(); h.key(String(character)) }
            try require(h.text == "ㅐncast", "Rechecking retained physical keys instead of passing them immediately")
            try await h.resolve("o")
            let field = AXUIElementCreateApplication(h.pid)
            h.input.updateRoute(.init(pid: h.pid, field: field, window: field, commands: .keyBindings), known: true)
            try await h.resolve("oncast"); h.flushWake()
            try require(h.text == "oncast" && h.errors.isEmpty && h.input.enabled,
                        "A same-field recheck orphaned the first Korean O")
            h.input.reset()
        }
        print("PASS native/Direct same-field recheck preserves the full oncast word with no retained keys")
        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA()
            h.input.configure(live: true, fixedEnglish: false, backfill: true)
            h.type("o"); try await h.resolve("o")
            h.input.beginRouteCheck(); h.flushWake()
            try require(h.text == "ㅐ", "An unconfirmed route applied a ready correction")
            let field = AXUIElementCreateApplication(h.pid)
            h.input.updateRoute(.init(pid: h.pid, field: field, window: field, commands: .keyBindings), known: true); h.flushWake()
            try require(h.text == "o", "A same-field result lost its wake during rechecking")
            h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA()
            h.input.configure(live: true, fixedEnglish: false, backfill: true)
            h.type("o"); try await h.waitForRequest(); h.input.beginRouteCheck()
            h.type("ncast so"); try await h.resolve("o")
            let field = AXUIElementCreateApplication(h.pid)
            h.input.updateRoute(.init(pid: h.pid, field: field, window: field, commands: .keyBindings), known: true)
            try await h.resolve("oncast"); h.flushWake()
            try await h.resolve("so"); h.flushWake()
            try require(h.text == "oncast so", "A recheck crossing Space lost word ownership or the following suffix")
            h.input.reset()
        }
        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA()
            h.input.configure(live: true, fixedEnglish: false, backfill: true)
            h.type("o"); try await h.waitForRequest(); h.input.beginRouteCheck()
            h.text = "" // The host moved to a different field in the same application.
            h.type("n")
            let otherField = AXUIElementCreateApplication(h.pid + 77)
            h.input.updateRoute(.init(pid: h.pid, field: otherField, window: otherField, commands: .keyBindings), known: true)
            let outputs = h.outputEventCount
            try await h.resolve("o"); h.flushWake()
            try require(h.text == "n" && h.outputEventCount == outputs && h.errors.isEmpty,
                        "A real field change reused the previous field's word or ready decision")
            h.input.reset()
        }
        print("PASS rechecking suspends writes, resumes ready output, retains Space suffixes and cancels actual field changes")
        do {
            let h = Harness(); h.input.enableForQA()
            h.input.configure(live: true, fixedEnglish: false, backfill: true)
            h.focusChecks.textEligible = false
            h.type("o"); try await h.settle()
            h.focusChecks.textEligible = true
            h.type("ncast")
            let field = AXUIElementCreateApplication(h.pid)
            h.input.updateRoute(.init(pid: h.pid, field: field, window: field, commands: .keyBindings), known: true)
            try await h.resolve("oncast"); h.flushWake()
            try require(h.text == "oncast" && h.errors.isEmpty, "A transient model focus check erased the owned prefix")
            h.input.reset()
        }
        print("PASS transient worker focus checks defer ownership decisions to the route monitor")
        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA()
            let physical = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            physical.flags = []
            physical.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            physical.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
            physical.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(h.pid))
            _ = h.input.receive(h.proxy, .keyDown, physical)
            try await h.waitForRequest()
            let count = h.outputEventCount
            let chunks = ["대시", "UI 디자인", "a", "🙂", "1234567890abcdef"]
            for text in chunks { try h.softwareText(text) }
            physical.type = .keyUp
            try require(h.input.receive(h.proxy, .keyUp, physical) == nil,
                        "Software keyup stole the physical A keyup ownership")
            try require(h.text == "a" + chunks.joined(), "Software text was decoded as physical A")
            try require(h.outputEventCount == count, "Software text generated conversion output")
            try await h.resolve("a")
            try require(h.wakeCount == 0, "A stale physical decision scheduled software text replacement")
            try require(h.text == "a" + chunks.joined(), "A stale physical decision overwrote software text")
            try require(h.errors.isEmpty && h.input.enabled, "Software text stopped the input engine")
            h.type("s"); try await h.resolve("s"); h.flushWake()
            h.type("o"); try await h.resolve("내"); h.flushWake()
            try require(h.text == "a" + chunks.joined() + "내", "Physical typing did not resume after software text")
            h.input.reset()
        }
        print("PASS native/Direct software Unicode down/up, mixed scripts, stale decision cancellation and physical resume")
        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA()
            h.remoteKeyboardPID = 12345
            h.input.systemKeyboardPIDs = [12345]
            h.type("s")
            try await h.settle()
            try require(h.text == "s" && !h.requests.isEmpty, "Remote keyboard Unicode bypassed the typing engine")
            try await h.resolve("s"); h.flushWake()
            h.type("o")
            try await h.resolve("내"); h.flushWake()
            try require(h.text == "내", "Remote keyboard correction did not replace the owned prefix")
            h.input.reset(); h.text = ""
            h.type("a")
            try await h.settle()
            try require(!h.requests.isEmpty, "A remote first A was mistaken for placeholder-key software text")
            try await h.resolve("ㅁ"); h.flushWake()
            try require(h.text == "ㅁ" && h.errors.isEmpty, "Remote first A failed to convert")
            h.input.reset()
        }
        print("PASS native/Direct remote Unicode keyboard input, prefix replacement and first A")
        for native in [false, true] {
            for sameField in [true, false] {
                let h = Harness(nativeMode: native); h.input.enableForQA()
                h.remoteKeyboardPID = 12345; h.input.systemKeyboardPIDs = [12345]
                h.key("a", flags: .maskCommand)
                h.type("akdma")
                try require(h.text == "akdma" && h.outputEventCount == 0 && h.requests.isEmpty,
                            "Typing immediately after a shortcut waited for or wrote to an unconfirmed field")
                let field = AXUIElementCreateApplication(h.pid + (sameField ? 0 : 77))
                h.input.updateRoute(.init(pid: h.pid, field: field, window: field, commands: .keyBindings), known: true)
                if sameField {
                    try await h.resolve("마음"); h.flushWake()
                    try require(h.text == "마음", "A shortcut discarded the same field's first word")
                } else {
                    try await h.settle()
                    try require(h.text == "akdma" && h.requests.isEmpty, "A shortcut applied old field ownership to a different field")
                }
                try require(h.errors.isEmpty, "Shortcut route rechecking stopped typing")
                h.input.reset()
            }
        }
        print("PASS native/Direct immediate first-A word after Command-A: immediate delivery, same-field correction, changed-field cancellation")
        var session = DirectSession()
        _ = try session.append("dkssud")
        let old = session.snapshot
        let edit = session.accept(try .init(text: "안녕", raw: "dkssud"), for: old)!
        try require(edit == .init(deleteCount: 6, text: "안녕"), "ASCII-to-Hangul edit did not own exactly six characters")
        let deletion = try session.backspace()
        try require(session.displayed == "안녀" && deletion == .init(deleteCount: 1, text: "녀"), "Hangul Backspace used bytes or cells instead of characters")
        _ = try session.append("d")
        try require(session.displayed == "안녕", "Korean decision did not carry to the next physical key")
        session.beginBoundary(" ")
        _ = try session.finish(.init(text: "안녕", replacement: nil, next: nil), for: session.snapshot)
        _ = try session.append("claude")
        try require(session.displayed == "claude", "The next English word inherited Korean mode")
        session.reset()
        _ = try session.append("dkssud")
        try require(session.accept(try .init(text: "안녕", raw: "dkssud"), for: old) == nil, "A canceled result edited a newer occurrence of the same word")
        let route = CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: true)!
        route.setIntegerValueField(.eventTargetUnixProcessID, value: 12345)
        route.setIntegerValueField(.eventTargetProcessSerialNumber, value: 54321)
        var originalCharacter: UniChar = 100 // Real input events already carry the typed letter.
        route.keyboardSetUnicodeString(stringLength: 1, unicodeString: &originalCharacter)
        let events = try KeyboardOutput.events(for: edit, routingEvent: route)
        try require(events.allSatisfy { $0.getIntegerValueField(.eventTargetUnixProcessID) == 12345 }, "Output events lost the captured target route")
        try require(events.allSatisfy { $0.getIntegerValueField(.eventTargetProcessSerialNumber) == 54321 }, "Output events lost the captured target serial number")
        try require(events.count == 14 && events.prefix(12).allSatisfy {
            $0.getIntegerValueField(.keyboardEventKeycode) == 123 && $0.flags.contains(.maskShift)
        }, "The output batch did not select the owned suffix before replacement")
        try require(events.suffix(2).allSatisfy { KeyboardOutput.text($0) == edit.text }, "Replacement text was split across host mutations")
        try require(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == KeyboardOutput.outputMarker }, "Output events are not distinguishable from physical input")
        for event in events.prefix(12) {
            try require(NSEvent(cgEvent: event)?.charactersIgnoringModifiers == "\u{F702}", "An editing command retained the original Unicode letter")
        }
        let rawCommands = try KeyboardOutput.events(for: .init(deleteCount: 1, text: ""), routingEvent: route, commands: .controlCharacters)
        try require(rawCommands.map { NSEvent(cgEvent: $0)?.characters } == ["\u{02}", "\u{02}", "\u{04}", "\u{04}"], "Read-only text surfaces lost their terminal control characters")
        try require(rawCommands.allSatisfy { $0.getIntegerValueField(.eventTargetUnixProcessID) == 12345 && $0.getIntegerValueField(.eventTargetProcessSerialNumber) == 54321 }, "Terminal commands lost the captured route")
        print("PASS minimal suffix edits, Hangul deletion, retained language, stale result, and output event order")

        do {
            let keyboard = try KeyboardInput()
            let s = CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: true)!
            s.flags = []; s.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
            try require(try keyboard.text(s) == "s", "A physical S without explicit Unicode was lost")
            let differentPayload = Array("z".utf16)
            differentPayload.withUnsafeBufferPointer { s.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            s.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            try require(!KeyboardInput.isSoftwareText(s), "Hardware Unicode was mistaken for software text")
            try require(try keyboard.text(s) == "s", "The key decoder used the Unicode payload instead of the physical key")
            s.flags = .maskShift
            try require(try keyboard.text(s) == "S", "The physical-key decoder lost Shift")
            s.flags = .maskAlphaShift
            try require(try keyboard.text(s) == "S", "The physical-key decoder lost Caps Lock")
            let h = Harness(); h.input.enableForQA()
            h.type("s"); try await h.resolve("s"); h.flushWake()
            h.inlineCompletionVisible = true
            h.type("o"); try await h.resolve("내"); h.flushWake()
            try require(h.text == "내" && h.errors.isEmpty, "An inline completion consumed the correction's first deletion: s내")
            h.input.reset()
        }
        print("PASS physical keys without Unicode and inline-completion deletion: so → 내 with no leftover s")

        do {
            let h = Harness(); h.input.enableForQA(); h.type("so")
            h.rightTap()
            try require(h.text == "내", "Right Command waited for the model or failed to switch the current word")
            h.rightTap(time: 2_000_000_000)
            try require(h.text == "so", "Right Command did not reverse the exact current reading")
            try await h.resolve("s"); h.flushWake()
            try require(h.text == "so" && h.errors.isEmpty, "An old model result undid the manual switch")
            h.key(" ", code: 49)
            try await h.resolve("내"); h.flushWake()
            try require(h.text == "so ", "The boundary model ignored a manual selection")
            h.key(" ", code: 49)
            h.rightTap(time: 3_000_000_000)
            try require(h.text == "내  ", "Switching the last completed word lost trailing spaces")
            h.rightTap(time: 4_000_000_000)
            try require(h.text == "so  ", "Completed-word reversal lost the previous reading")
            h.key("\r", code: 36); h.rightTap(time: 5_000_000_000)
            try require(h.submitted == ["so  "] && h.text.isEmpty, "Right Command reached a submitted line")
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.text = "prompt $ "
            h.type("so"); h.key(" ", code: 49)
            h.rightTap()
            try require(h.text == "prompt $ 내 ", "Right Command waited for a completed-word model result")
            try await h.resolve("s"); try await h.resolve("so"); h.flushWake()
            try require(h.text == "prompt $ 내 ", "A pending boundary overwrote the manual completed word")
            h.input.reset()
        }
        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA(); h.hostEditable = false
            // A nonactivating command panel owns the very first I; AX still names the old document.
            h.key("i", targetPID: h.pid + 1)
            try require(h.deliveredPhysical == ["i"] && h.outputEventCount == 0 && h.requests.isEmpty && h.errors.isEmpty,
                        "A keyboard owner different from the cached text field received synthesized input")
            let target = AXUIElementCreateApplication(h.pid)
            h.input.updateRoute(.init(pid: h.pid, field: target, window: target, commands: .keyBindings), known: true)
            h.hostEditable = true; h.type("so")
            try await h.resolve("s"); try await h.resolve("내"); h.flushWake()
            try require(h.text == "내", "A command in another keyboard owner disabled subsequent normal typing")
            h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.type("chrome")
            try await h.resolve("c"); try await h.resolve("chrome")
            h.rightTap(); h.flushWake()
            try require(h.text == (try HangulComposer.compose("chrome")), "A ready result undid Right Command")
            h.type("s")
            try require(h.text == (try HangulComposer.compose("chromes")), "Typing after a manual switch lost the chosen language")
            h.input.reset()
        }
        for code: Int64 in [54, 55] {
            let h = Harness(); h.input.enableForQA(); h.type("so")
            h.modifier(code: code, down: true, time: 1_000_000_000)
            h.key("c", flags: .maskCommand)
            h.modifier(code: code, down: false, time: 1_100_000_000)
            try require(h.text == "so", "A Command shortcut also switched the word")
            try await h.resolve("s"); h.flushWake(); h.input.reset()
        }
        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA(); h.type("so")
            h.modifier(down: true, time: 1_000_000_000)
            h.modifier(down: false, time: 1_050_000_000)
            try await Task.sleep(for: .milliseconds(300)); h.flushWake()
            try require(h.text == "내" && h.feedbackShowCount == 0, "The real single-tap timer failed or opened candidates")
            try require(h.corrections.isEmpty, "A single Command tap saved a correction")
            try await h.resolve("s"); h.flushWake(); h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.type("so")
            h.modifier(down: true, time: 1_000_000_000)
            h.modifier(down: false, time: 1_600_000_000)
            try require(h.text == "so", "Holding right Command acted as a short tap")
            try await h.resolve("s"); try await h.resolve("so"); h.flushWake(); h.input.reset()
        }
        print("PASS right Command: current/completed-word toggle, exact reversal, manual override, Space preservation, Enter cancellation and Command chords")

        do {
            let h = Harness(); h.input.enableForQA(); h.type("so")
            h.modifier(down: true, time: 1_000_000_000)
            h.modifier(down: false, time: 1_050_000_000)
            try require(h.text == "so" && h.corrections.isEmpty, "The first tap changed or saved the text before double-tap detection")
            h.key("s")
            try require(h.text == (try HangulComposer.compose("sos")), "Typing waited for the double-tap interval or lost the single toggle")
            try await h.resolve("s"); h.flushWake(); h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.text = "prompt $ "; h.type("so")
            h.doubleRightTap()
            try require(h.text == "prompt $ so", "Double tapping performed a single-tap toggle")
            try await h.waitForFeedback()
            try require(h.feedback.contains("내") && h.feedback.contains("so"), "The original engine candidates were not offered")
            try require(!h.focusChecks.usedMainThread, "Feedback AX work ran in the key callback")
            try require(h.feedbackBounds == CGRect(x: 321, y: 456, width: 1, height: 20), "The candidate panel did not receive the caret bounds")
            let number = h.feedback.firstIndex(of: "내")! + 1
            h.key(String(number))
            try await h.waitForWake(); h.flushWake()
            for _ in 0..<100 where h.corrections.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
            try require(h.text == "prompt $ 내" && h.corrections.count == 1 && h.corrections[0].0.text == "so",
                        "Selecting a candidate failed to replace exactly the owned word or retain the rejected reading")
            h.key(" ", code: 49)
            try await h.resolve("s"); try await h.resolve("so"); h.flushWake()
            try require(h.text == "prompt $ 내 " && h.errors.isEmpty, "An old model result undid the chosen correction")
            h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.type("so"); h.key(" ", code: 49); h.key(" ", code: 49)
            h.doubleRightTap(); try await h.waitForFeedback()
            let index = h.feedback.firstIndex(of: "내  ")!
            h.input.chooseFeedback(index)
            try await h.waitForWake(); h.flushWake()
            try require(h.text == "내  ", "Candidate selection lost completed-word trailing spaces")
            try await h.resolve("s"); try await h.resolve("so"); h.flushWake(); h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.type("so"); h.doubleRightTap()
            try await h.waitForFeedback(); h.key("", code: 53)
            try require(h.feedback.isEmpty && h.text == "so" && h.corrections.isEmpty, "Esc changed or learned the word")
            h.doubleRightTap(); try await h.waitForFeedback()
            h.input.chooseFeedback(h.feedback.firstIndex(of: "내")!)
            try await h.waitForWake()
            h.key("s"); h.flushWake()
            try require(h.text == "sos" && h.feedback.isEmpty && h.corrections.isEmpty, "A queued selection rewrote subsequent typing")
            try await h.resolve("s"); try await h.resolve("sos"); h.flushWake(); h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.type("so"); h.doubleRightTap(); h.key("\r", code: 36)
            try await Task.sleep(for: .milliseconds(20)); h.flushWake()
            try require(h.feedbackShowCount == 0 && h.submitted == ["so"], "A candidate panel crossed Enter")
            try await h.resolve("s"); h.flushWake(); h.input.reset()
        }
        print("PASS double right Command: original candidates, no intermediate toggle, selection/learning, suffix preservation, Esc and stale-selection cancellation; typing never waits")

        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA(); h.hostEditable = false
            h.key("", code: 122) // F1 is a function key, not an application-specific exception.
            h.input.updateRoute(nil, known: true)
            h.type("ka"); h.key("", code: 53)
            try require(h.deliveredPhysical == ["", "k", "a", ""] && h.outputEventCount == 0,
                        "A non-text command sequence was consumed or synthesized")
            try require(h.errors.isEmpty && h.input.enabled && h.requests.isEmpty,
                        "A normal non-text route stopped the engine or started the model")
            h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.type("so")
            let count = h.outputEventCount
            let function = CGEvent(keyboardEventSource: nil, virtualKey: 120, keyDown: true)!
            // A consuming upstream handler can hide the opener from the converter.
            h.input.observeCommand(.keyDown, function)
            function.type = .keyUp; h.input.observeCommand(.keyUp, function)
            try await h.resolve("s"); h.flushWake()
            try require(h.text == "so" && h.outputEventCount == count && h.errors.isEmpty && h.input.enabled,
                        "A command opener consumed upstream left an active late correction")
            h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.input.updateRoute(nil, known: false)
            h.type("s")
            let target = AXUIElementCreateApplication(h.pid)
            h.input.updateRoute(.init(pid: h.pid, field: target, window: target, commands: .keyBindings), known: true)
            h.input.beginRouteCheck()
            h.type("o")
            h.input.updateRoute(.init(pid: h.pid, field: target, window: target, commands: .keyBindings), known: true)
            try require(h.text == "so" && h.outputEventCount == 0, "Route discovery converted the middle of a passed-through word")
            h.key(" ", code: 49); h.type("so")
            try await h.resolve("s"); try await h.resolve("내"); h.flushWake()
            try require(h.text == "so 내" && h.errors.isEmpty && h.input.enabled,
                        "Normal typing did not resume at the next word after route discovery")
            h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA(); h.focusChecks.textEligible = false
            h.type("so"); try await h.settle(); h.flushWake()
            try require(h.errors.isEmpty && h.input.enabled && h.requests.isEmpty && h.text == "so",
                        "A late non-text focus result became a fatal model error")
            h.input.reset()
        }
        print("PASS generic input routing in both sources: non-text keys pass unchanged, no model/popup/stop; command openers cancel late work; unknown routes never retain keys or split a word")

        do {
            let h = Harness(); h.input.enableForQA()
            h.focusChecks.textEligible = false; h.focusChecks.blockFirstCapture(); h.type("so")
            for _ in 0..<100 where h.focusChecks.captureCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
            try require(h.focusChecks.captureCount > 0, "The delayed route inspection did not start")
            h.input.reset(); h.focusChecks.textEligible = true; h.type("chrome")
            h.focusChecks.releaseCapture(); try await h.waitForRequest()
            try require(h.requests[0].0.raw == "chrome", "An old non-text inspection suppressed the latest normal word")
            try await h.resolve("chrome"); h.flushWake(); h.input.reset()
        }
        print("PASS delayed non-text route result: latest normal word is scheduled after invalidation with no retained key")
        do {
            let h = Harness(); h.input.enableForQA(); h.focusChecks.failsAX = true
            h.type("so"); try await h.settle(); h.flushWake()
            try require(h.input.enabled && h.errors.isEmpty && h.requests.isEmpty, "An AX route error stopped the engine or started a retry")
            let count = h.outputEventCount
            let refreshes = h.routeRefreshes
            h.type("ka")
            try require(h.outputEventCount == count && h.deliveredPhysical == ["k", "a"], "Keys were retained after an AX route error")
            try require(h.routeRefreshes > refreshes, "New typing did not recheck the input field after an AX route error")
            h.input.reset()
        }
        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA()
            h.input.configure(live: true, fixedEnglish: false, backfill: true)
            h.focusChecks.failsAX = true
            h.type("d"); try await h.settle()
            let refreshes = h.routeRefreshes
            h.focusChecks.failsAX = false
            h.type("kssud")
            try require(h.routeRefreshes > refreshes, "Typing after secure login did not request a fresh route")
            let field = AXUIElementCreateApplication(h.pid)
            h.input.updateRoute(.init(pid: h.pid, field: field, window: field, commands: .keyBindings), known: true)
            try await h.resolve("안녕"); h.flushWake()
            try require(h.text == "안녕" && h.input.enabled && h.errors.isEmpty,
                        "Typing did not resume Hangul conversion after an AX route error")
            h.input.reset()
        }
        print("PASS AX routing failure: no automatic retry or retained keys; a new key rechecks the route and resumes Hangul in native/Direct")

        for native in [false, true] {
            let h = Harness(nativeMode: native); h.input.enableForQA()
            h.input.configure(live: true, fixedEnglish: false, backfill: true)
            let monitor = InputRouteMonitor(sourceID: "QA", checking: {}, changed: { _, _, _ in })
            let field = AXUIElementCreateApplication(h.pid)
            let target = DirectFocus(pid: h.pid, field: field, window: field, commands: .keyBindings)
            monitor.menuOpenedForQA()
            h.input.updateRoute(monitor.targetForQA(target), known: true)
            h.type("so")
            try require(h.text == "so" && h.outputEventCount == 0, "An open menu allowed text conversion")
            h.input.reset(); h.text = ""
            // A source/password transition can omit the matching menu-closed notification.
            monitor.resume()
            h.input.updateRoute(monitor.targetForQA(target), known: true)
            h.type("so")
            try require(h.text == "내", "A stale menu state blocked Hangul typing after input-source restoration")
            try await h.resolve("s"); try await h.resolve("내"); h.flushWake()
            try require(h.text == "내" && h.input.enabled && h.errors.isEmpty,
                        "The resumed route did not keep Hangul conversion active")
            h.input.reset()
        }
        print("PASS native/Direct source restoration clears a stale menu gate and resumes real composition/output")

        for live in [false, true] {
            let h = Harness(nativeMode: true); h.input.enableForQA()
            h.input.configure(live: live, fixedEnglish: live ? nil : false, backfill: true)
            h.focusChecks.blockFirstCapture()
            h.type("chrome"); h.key(" ", code: 49); h.type("claude"); h.key("\r", code: 36)
            let expected = live ? "chrome claude" : try HangulComposer.compose("chrome") + " " + HangulComposer.compose("claude")
            try require(h.submitted == [expected], "Native typing waited for focus/model work or swallowed Return")
            h.focusChecks.releaseCapture()
            try await h.resolve("c"); h.flushWake()
            try require(h.text.isEmpty && h.errors.isEmpty && !h.focusChecks.usedMainThread, "A native late result crossed Return or queried AX in the key callback")
            h.input.reset()
        }
        do {
            let h = Harness(nativeMode: true); h.input.enableForQA()
            h.input.configure(live: false, fixedEnglish: false, backfill: false)
            h.type("chrome"); try await h.resolve("c"); try await h.resolve("chrome"); h.flushWake()
            try require(h.text == (try HangulComposer.compose("chrome")), "Basic mode stopped using its configured preview")
            h.key("\r", code: 36)
            try require(h.submitted == ["chrome"] && h.errors.isEmpty, "Basic Return did not use an already prepared decision immediately")
            h.input.reset()
        }
        print("PASS native source in live/basic modes: suspended AX/model never retains Space, later keys or Return; basic preview and cached Return decision preserved")

        // A suspended model must not withhold Space, later letters, punctuation, or Enter.
        do {
            let h = Harness(); h.input.enableForQA()
            h.type("dkssud"); h.key(" ", code: 49); h.type("claude"); h.key(".", code: 47)
            try require(h.text == "dkssud claude.", "Typing waited for a suspended model")
            h.key("\r", code: 36)
            try require(h.submitted == ["dkssud claude."] && h.text.isEmpty, "Enter was retained or duplicated")
            try await h.resolve("d")
            h.flushWake()
            try require(h.submitted == ["dkssud claude."] && h.text.isEmpty && h.errors.isEmpty,
                        "A late correction crossed Enter")
        }
        // Space is already visible; a late correction must include the freshly typed suffix.
        do {
            let h = Harness(); h.input.enableForQA()
            h.type("dkssud"); h.key(" ", code: 49); h.type("claude")
            try require(h.text == "dkssud claude", "The next word waited behind Space")
            try await h.resolve("d")
            try await h.resolve("안녕")
            h.flushWake()
            try require(h.text == "안녕 claude", "A completed-word correction lost the current suffix")
            try await h.resolve("claude"); h.flushWake()
            h.key("\r", code: 36)
            try require(h.submitted == ["안녕 claude"] && h.errors.isEmpty, "Enter did not reach the host exactly once")
        }
        print("PASS suspended model: immediate Space, punctuation, later letters and Enter; late correction preserves current suffix")
        do {
            let h = Harness(); h.input.enableForQA()
            h.focusChecks.blockFirstCapture()
            h.type("chrome"); h.key(" ", code: 49); h.type("hello"); h.key("\r", code: 36)
            try require(h.submitted == ["chrome hello"], "Slow AX work blocked physical input")
            h.focusChecks.releaseCapture()
            try await h.resolve("c")
            try require(!h.focusChecks.usedMainThread, "AX capture or validation ran on the key event thread")
        }
        print("PASS slow AX capture: typing and Enter continue; focus checks run off the main/key thread")
        do {
            let h = Harness(); h.input.enableForQA()
            h.type("dkssud"); try await h.waitForRequest()
            h.input.reset(); h.type("chrome")
            try require(h.requests.count == 1, "Reset queued a second model job behind a suspended job")
            try await h.resolve("d")
            try await h.waitForRequest()
            try require(h.requests[0].0.raw == "chrome", "A stale job prevented the newest word from being scheduled")
            try await h.resolve("chrome"); h.flushWake()
            try require(h.text == "dkssudchrome" && h.errors.isEmpty, "A canceled result changed the newer input")
            h.input.reset()
        }
        do {
            let h = Harness(); h.input.enableForQA()
            h.type("dkssud"); h.key(" ", code: 49)
            h.focusValid = false
            try await h.resolve("d")
            try require(h.text == "dkssud " && h.errors.isEmpty && h.input.enabled,
                        "A normal focus change edited text, stopped the engine or swallowed Space")
        }
        do {
            let h = Harness(); h.input.enableForQA()
            h.type("dkssud"); h.key(" ", code: 49)
            try await h.waitForRequest()
            h.requests.removeFirst().1.resume(throwing: DirectFailure(detail: "QA model failure"))
            try await h.settle()
            try require(h.errors.count == 1 && !h.input.enabled && h.text == "dkssud ",
                        "Model failure retried or withheld physical input")
        }
        print("PASS one in-flight job across resets; focus loss and model failure do not replay or withhold keys")

        do {
            let h = Harness(); h.input.enableForQA()
            for _ in 0..<100 {
                h.type("to go home"); h.key(" ", code: 49); h.key("\r", code: 36)
            }
            try require(h.submitted == Array(repeating: "to go home ", count: 100),
                        "A suspended worker delayed or lost stress input")
            let timings = h.keyDurations.sorted()
            print(String(format: "KEY_CALLBACK isolated suspended worker: events=%d p95=%.3fms max=%.3fms", timings.count,
                         timings[Int(Double(timings.count - 1) * 0.95)] * 1000, timings.last! * 1000))
            try await h.resolve("t")
            try require(h.text.isEmpty && h.errors.isEmpty, "A stress result crossed the last Enter")
        }

        let backfillFrequencies = try JSONDecoder().decode(WordFrequencies.self,
            from: Data("{\"english\":{\"to\":6,\"go\":6},\"korean\":{\"새\":6,\"해\":6}}".utf8))
        let first = DirectBackfill.Reading(text: "새", probabilities: ["새": 0.6, "to": 0.4])
        let second = DirectBackfill.Reading(text: "해", probabilities: ["해": 0.6, "go": 0.4])
        let alternative = DirectBackfill.Reading(text: "go", probabilities: ["go": 0.6, "해": 0.4])
        let anchor = DirectBackfill.Reading(text: "home", probabilities: ["home": 0.99, "ㅗㅐㅡㄷ": 0.01])
        do {
            let h = Harness(); h.input.enableForQA()
            h.type("to"); h.key(" ", code: 49); h.type("go"); h.key(" ", code: 49)
            h.type("home"); h.key(" ", code: 49); h.type("chrome")
            try require(h.text == "to go home chrome", "Three completed words blocked ongoing typing")
            try await h.resolve("t")
            try await h.resolveReading(first, alternate: nil, frequencies: backfillFrequencies); h.flushWake()
            try require(h.text == "새 go home chrome", "The first late result damaged later completed words")
            try await h.resolveReading(second, alternate: alternative, frequencies: backfillFrequencies); h.flushWake()
            try require(h.text == "새 해 home chrome", "The second late result lost the suffix")
            try await h.resolveReading(anchor, alternate: anchor, frequencies: backfillFrequencies); h.flushWake()
            try require(h.text == "to go home chrome", "Ordered late backfill did not restore the English chain")
            try await h.resolve("chrome"); h.flushWake(); h.input.reset()
        }
        for pressEnterBeforeResult in [false, true] {
            let h = Harness(); h.input.enableForQA(); h.text = "prompt $ "
            h.type("to"); h.key(" ", code: 49)
            try await h.resolve("t")
            try await h.resolveReading(first, alternate: nil, frequencies: backfillFrequencies)
            h.flushWake()
            h.key(" ", code: 49)
            h.type("go"); h.key(" ", code: 49)
            try await h.resolve("g")
            try await h.resolveReading(second, alternate: alternative, frequencies: backfillFrequencies)
            h.flushWake()
            try require(h.text == "prompt $ 새  해 ", "The pipeline lost the words or double space")
            h.type("home"); h.key(" ", code: 49)
            if pressEnterBeforeResult { h.key("\r", code: 36) }
            else { h.type("chr") }
            try await h.resolve("h")
            if pressEnterBeforeResult {
                h.flushWake()
                try require(h.submitted == ["prompt $ 새  해 home "] && h.text.isEmpty && h.errors.isEmpty,
                            "A late result edited a submitted line")
            } else {
                try await h.resolveReading(anchor, alternate: anchor, frequencies: backfillFrequencies)
                h.flushWake()
                try require(h.text == "prompt $ to  go home chr" && h.errors.isEmpty,
                            "Backfill corrupted the prompt, spaces, or newly typed suffix")
                h.key("\r", code: 36)
                try require(h.submitted == ["prompt $ to  go home chr"], "Enter was delayed or duplicated after backfill")
                try await h.resolve("chr")
            }
            h.input.reset()
        }
        print("PASS nonblocking backfill: prompt, double space and current suffix preserved; Enter cancels late edits")

        try languageChecks()
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hannyeong-direct-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try DirectRuntime(resources: resources, personalDirectory: directory, memory: CorrectionMemory())
        _ = try await runtime.client.prepare()
        try policyChecks()
        for (keys, expected) in [("to go home", "to go home "),
                                  ("so rkqtdmfh rkatk", "내 값으로 감사 "),
                                  ("togo qhr aksgdl qkedmtpdy", "새해 복 많이 받으세요 "),
                                  ("Let's go home", "Let's go home ")] {
            // Alphabetic tokens exercise the same model and backfill path as the tap.
            // Apostrophes are delivered as separate boundaries below.
            var session = DirectSession(), host = ""
            for character in keys + " " {
                if character.isASCII && character.isLetter {
                    apply(try session.append(String(character)), to: &host)
                } else if !session.raw.isEmpty {
                    host += String(character)
                    session.beginBoundary(String(character))
                    let request = session.snapshot
                    guard case .boundary(let result) = try await runtime.decide(request) else {
                        throw DirectFailure(detail: "The real model did not resolve the word boundary")
                    }
                    guard let edit = try session.finish(result, for: request) else {
                        throw DirectFailure(detail: "The real model boundary went stale without input")
                    }
                    apply(edit, to: &host)
                    if keys == "to go home" {
                        print("MODEL_BOUNDARY \(request.raw) -> \(host) rewrite=\(result.replacement != nil) retained=\(result.next?.words.count ?? 0)")
                    }
                } else {
                    session.recordSeparator(String(character))
                    host += String(character)
                }
            }
            print("MODEL_CONTINUATION \(keys) -> \(host)")
            try require(host == expected, "Real model continuation differed: \(keys) -> \(host)")
        }
        for (raw, before) in [("dkssud", ""), ("claude", ""), ("chrome", ""), ("gksrmf", ""), ("githubdp", ""), ("to", "Let's ")] {
            let request = DirectSession.Snapshot(revision: 1, raw: raw, before: before)
            let direct = try await runtime.decide(request)
            let candidates = try CandidateBuilder.candidates(for: raw, includeSplits: true)
            let original = try await runtime.client.decide(raw: raw, before: before, candidates: candidates)
            try require(direct == .live(try .init(text: original.predicted, raw: raw)), "The direct prototype changed the existing model decision")
            if raw == "dkssud" { try require(direct == .live(try .init(text: "안녕", raw: raw)), "Existing model Korean sanity case failed") }
            if raw == "claude" || raw == "chrome" { try require(direct == .live(try .init(text: raw, raw: raw)), "Existing model English sanity case failed") }
        }
        print("PASS existing model/candidate preservation: same decisions for six full-word and context cases")

        let correction = DirectSession.FeedbackTarget(revision: 1, raw: "so", before: "typing ", text: "so", separator: " ")
        try await runtime.correct(correction, preferred: "내")
        let correctionsURL = directory.appendingPathComponent("corrections.json")
        let saved = try JSONDecoder().decode(CorrectionMemory.self, from: Data(contentsOf: correctionsURL))
        try require(saved.preferred(raw: "so", before: "typing ") == "내", "The Direct correction memory was not saved")
        let attributes = try FileManager.default.attributesOfItem(atPath: correctionsURL.path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "The correction file permissions changed")
        let decision = try await runtime.decide(.init(revision: 2, raw: "so", before: "typing "))
        try require(decision == .live(try .init(text: "내", raw: "so")), "The runtime ignored the new contextual correction")
        print("PASS contextual correction: temporary private memory, permissions, model update and subsequent decision")

        // The integrated mode and the settings browser use the very same store and worker.
        let store = CorrectionStore(url: correctionsURL)
        let integrated = DirectRuntime(client: runtime.client,
            frequencies: try WordFrequencies.load(resources.appendingPathComponent("rule-lexicon.json")),
            correctionsURL: store.url, memory: try store.load())
        let koreanChrome = try HangulComposer.compose("chrome")
        let target = DirectSession.FeedbackTarget(revision: 1, raw: "chrome", before: "shared settings ", text: "chrome", separator: "")
        try await integrated.correct(target, preferred: koreanChrome)
        let entry = try store.load().entries.first { $0.raw == "chrome" }!
        try require(entry.preferred == koreanChrome, "The settings store cannot see experimental-mode learning")
        let always = try await store.changeScope(of: entry, to: .always, local: runtime.client)
        let result = try await integrated.decide(.init(revision: 2, raw: "chrome", before: "another context "))
        try require(result == .live(try .init(text: koreanChrome, raw: "chrome")), "The experimental engine ignored a scope change in settings")
        _ = try await runtime.client.forget([always])
        try store.remove(always)
        let removed = try await integrated.decide(.init(revision: 3, raw: "chrome", before: "another context "))
        try require(removed == .live(try .init(text: "chrome", raw: "chrome")), "Deleting a shared correction left a cached forced reading")
        print("PASS shared correction management: learning visible, scope change applied, deletion removes memory and personal adjustment")
    }
    static func autocompleteFocusChecks() throws {
        let nodes = (0..<7).map { AXUIElementCreateApplication(pid_t(20000 + $0)) }
        let (option, list, popup, editor, unrelated, web, window) =
            (nodes[0], nodes[1], nodes[2], nodes[3], nodes[4], nodes[5], nodes[6])
        var selection = CFRange(location: 0, length: 0)
        let range = AXValueCreate(.cfRange, &selection)!
        var attributes: [CFHashCode: [String: CFTypeRef]] = [:]
        func set(_ node: AXUIElement, _ values: [String: CFTypeRef]) { attributes[CFHash(node)] = values }
        set(option, [kAXRoleAttribute: "AXStaticText" as CFString, kAXParentAttribute: list])
        set(list, [kAXRoleAttribute: "AXList" as CFString, kAXParentAttribute: popup, kAXChildrenAttribute: [option] as CFArray])
        set(popup, [kAXRoleAttribute: "AXGroup" as CFString, kAXParentAttribute: web,
                    kAXChildrenAttribute: [unrelated, editor, list] as CFArray])
        set(editor, [kAXRoleAttribute: kAXComboBoxRole as CFString,
                     kAXLinkedUIElementsAttribute: [list] as CFArray, kAXSelectedTextRangeAttribute: range])
        set(unrelated, [kAXRoleAttribute: kAXTextFieldRole as CFString, kAXSelectedTextRangeAttribute: range])
        set(web, [kAXRoleAttribute: "AXWebArea" as CFString, kAXParentAttribute: window, kAXChildrenAttribute: [popup] as CFArray])
        set(window, [kAXRoleAttribute: kAXWindowRole as CFString])
        func read(_ node: AXUIElement, _ key: String) throws -> CFTypeRef? { attributes[CFHash(node)]?[key] }
        let resolved = try DirectFocus.inputField(for: option, read: read)
        try require(resolved.map { CFEqual($0, editor) } == true,
                    "An active autocomplete suggestion did not resolve to its controlling editor")
        try require(try DirectFocus.inputField(for: unrelated, read: read).map { CFEqual($0, unrelated) } == true,
                    "An ordinary text field changed identity")
        attributes[CFHash(editor)]?.removeValue(forKey: kAXLinkedUIElementsAttribute)
        try require(try DirectFocus.inputField(for: option, read: read) == nil,
                    "An unrelated text field was treated as the autocomplete editor")
        attributes[CFHash(editor)]?[kAXLinkedUIElementsAttribute] = [list] as CFArray
        attributes[CFHash(editor)]?.removeValue(forKey: kAXSelectedTextRangeAttribute)
        try require(try DirectFocus.inputField(for: option, read: read) == nil,
                    "A non-editable combobox was treated as a text editor")
        do {
            _ = try DirectFocus.inputField(for: option, read: { _, _ in throw DirectFocus.RouteError(detail: "QA AX communication failure") })
            throw DirectFailure(detail: "Autocomplete AX errors were silently ignored")
        } catch is DirectFocus.RouteError {}
        print("PASS autocomplete suggestion focus resolves only to its explicitly linked editable input; AX failures propagate")
    }

    static func apply(_ edit: DirectSession.Edit, to host: inout String) {
        precondition(edit.deleteCount <= host.count)
        host.removeLast(edit.deleteCount)
        host += edit.text
    }

    static func policyChecks() throws {
        let frequencies = try JSONDecoder().decode(WordFrequencies.self,
            from: Data("{\"english\":{\"to\":6,\"go\":6,\"so\":6},\"korean\":{\"새\":6,\"해\":6,\"내\":6}}".utf8))
        func reading(_ text: String, raw: String, confidence: Double) throws -> DirectBackfill.Reading {
            let other = text == raw ? try HangulComposer.compose(raw) : raw
            return .init(text: text, probabilities: [text: confidence, other: 1 - confidence])
        }
        var session = DirectSession(), host = "prompt $ "
        func word(_ raw: String, selected: String, alternate: String?, confidence: Double, separator: String = " ") throws -> DirectBackfill.Resolution {
            apply(try session.append(raw), to: &host)
            // Final live display and final model choice need not match while the word is being typed.
            _ = session.accept(try .init(text: selected, raw: raw), for: session.snapshot).map { apply($0, to: &host) }
            host += separator
            session.beginBoundary(separator)
            let request = session.snapshot
            let result = try DirectBackfill.resolve(word: .init(raw: raw, separator: separator), before: request.before,
                previous: request.recent, decided: reading(selected, raw: raw, confidence: confidence),
                alternate: try alternate.map { try reading($0, raw: raw, confidence: confidence) }, frequencies: frequencies)
            apply(try session.finish(result, for: request)!, to: &host)
            return result
        }
        _ = try word("to", selected: "새", alternate: nil, confidence: 0.6)
        _ = try word("go", selected: "해", alternate: "go", confidence: 0.6)
        try require(host == "prompt $ 새 해 " && session.recent?.words.count == 2, "Ambiguous words were not retained")
        let corrected = try word("home", selected: "home", alternate: "home", confidence: 0.99)
        try require(corrected.replacement == "to go home" && host == "prompt $ to go home " && session.context == "to go home ",
                    "Backfill corrupted the prompt, separators, or subsequent model context")
        session.reset(); host = ""
        _ = try word("to", selected: "새", alternate: nil, confidence: 0.6)
        session.recordSeparator(" "); host += " "
        _ = try word("go", selected: "해", alternate: "go", confidence: 0.6)
        _ = try word("home", selected: "home", alternate: "home", confidence: 0.99)
        try require(host == "to  go home ", "Extra spaces fell outside the owned backfill suffix")
        session.reset(); host = ""
        _ = try word("so", selected: "so", alternate: nil, confidence: 0.6)
        let held = try word("rkqtdmfh", selected: "값으로", alternate: "값으로", confidence: 0.99)
        try require(held.replacement == nil && session.recent?.confirming == .korean,
                    "The existing sentence-initial single-word confirmation rule changed")
        _ = try word("rkatk", selected: "감사", alternate: "감사", confidence: 0.99)
        try require(host == "내 값으로 감사 ", "The confirming anchor did not correct the previous chain")
        session.reset(); host = ""
        for index in 0..<4 {
            _ = try word("zz", selected: "zz", alternate: index == 0 ? nil : "ㅋㅋ", confidence: 0.6)
        }
        try require(session.recent == nil, "The reconsideration window exceeded four words")
        session.reset(); host = ""
        _ = try word("so", selected: "so", alternate: nil, confidence: 0.6)
        session.recordSeparator(".")
        try require(session.recent == nil, "Punctuation retained an invalid editable suffix")
        _ = try session.append("word")
        session.beginBoundary(" ")
        let old = session.snapshot
        session.reset()
        _ = try session.append("chrome")
        try require(try session.finish(.init(text: "chrome", replacement: "late", next: nil), for: old) == nil,
                    "A canceled backfill changed the new cursor's word")
        print("PASS existing backfill rules: two alternate chains, confirming anchor, four-word limit, spaces, punctuation, prompt/context preservation, stale result")
    }

    static func languageChecks() throws {
        var session = DirectSession()
        session.setInitialLanguage(.korean)
        _ = try session.append("dk")
        try require(session.displayed == "아", "The previous Korean source did not compose immediately")
        session.beginBoundary(" ")
        _ = try session.finish(.init(text: "아", replacement: nil, next: nil), for: session.snapshot)
        _ = try session.append("s")
        try require(session.displayed == "ㄴ", "A word boundary reset the preferred language to English")
        session.reset()
        _ = try session.append("r")
        try require(session.displayed == "ㄱ", "Navigation reset the remembered input language")
        session.reset()
        func confirm(_ raw: String, text: String, language: DirectBackfill.Language?) throws {
            _ = try session.append(raw)
            session.beginBoundary(" ")
            _ = try session.finish(.init(text: text, replacement: nil, next: nil, confirmedLanguage: language), for: session.snapshot)
        }
        for _ in 0..<3 { try confirm("gksrmf", text: "한글", language: .korean) }
        try confirm("home", text: "home", language: .english)
        try require(session.preferredLanguage == .korean, "One English word displaced the recent Korean majority")
        try confirm("chrome", text: "chrome", language: .english)
        try require(session.preferredLanguage == .korean, "A tied language window changed the existing preference")
        try confirm("claude", text: "claude", language: .english)
        try require(session.preferredLanguage == .english, "The recent English majority did not become the default")
        _ = try session.append("c")
        try require(session.displayed == "c", "English-dominant typing still started in Korean")
        session.reset()
        let frequencies = try JSONDecoder().decode(WordFrequencies.self, from: Data("{\"english\":{},\"korean\":{}}".utf8))
        let short = try DirectBackfill.resolve(word: .init(raw: "to", separator: " "), before: "", previous: nil,
            decided: .init(text: "새", probabilities: ["새":0.99,"to":0.01]), alternate: nil, frequencies: frequencies)
        let mixed = try DirectBackfill.resolve(word: .init(raw: "AIfh", separator: " "), before: "", previous: nil,
            decided: .init(text: "AI로", probabilities: ["AI로":0.99,"AIfh":0.01]), alternate: nil, frequencies: frequencies)
        try require(short.confirmedLanguage == nil && mixed.confirmedLanguage == nil,
                    "A short or mixed word changed the preferred input language")
        let suite = "HannyeongDirectLanguageQA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("english", forKey: "direct.preferredLanguage")
        try require(try DirectInputSource.initialLanguage(for: DirectInputSource.direct, defaults: defaults) == .english,
                    "The Direct source did not resume its stored language")
        try require(try DirectInputSource.initialLanguage(for: "com.apple.keylayout.ABC", defaults: defaults) == .english,
                    "ABC was not recognized as an English starting source")
        try require(try DirectInputSource.nativeLanguage(nil) == .korean, "The native unset preference did not use its defined Korean default")
        try require(try DirectInputSource.nativeLanguage(kCFBooleanTrue) == .english, "The native English preference was lost")
        try require(try DirectInputSource.nativeLanguage(kCFBooleanFalse) == .korean, "The native Korean preference was lost")
        var invalidPreferenceRejected = false
        do { _ = try DirectInputSource.nativeLanguage("invalid" as CFString) }
        catch is DirectFailure { invalidPreferenceRejected = true }
        try require(invalidPreferenceRejected, "An invalid native language preference was silently replaced")
        _ = try DirectInputSource.initialLanguage(for: "com.yeop.inputmethod.Hannyeong")
        print("PASS native startup language: existing domain read without suite initialization, true/false/unset and invalid preference")
        print("PASS sticky input language: initial Korean, word/navigation/Enter retention, four-word majority, short/mixed-word exclusion, stored language and ABC source")
    }

}
