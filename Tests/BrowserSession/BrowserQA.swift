import AppKit
import ApplicationServices
import Carbon

private enum Action { case text(String), key(CGKeyCode) }
private struct Case {
    let name: String
    let actions: [Action]
    let expected: String
    var initial = ""
    var caret = 0
}
private struct Result: Codable { let name: String; let delay: Double; let expected: String; let actual: String; let passed: Bool }

@main
private struct BrowserQA {
    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return status == .success ? value : nil
    }
    static func main() throws {
        guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else { fatalError("Browser QA requires keyboard and Accessibility permission") }
        let requestedPID = CommandLine.arguments.first(where: { $0.hasPrefix("--pid=") })
            .map { pid_t($0.dropFirst(6))! }
        let app = requestedPID.map { NSRunningApplication(processIdentifier: $0)! }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first!
        precondition(app.bundleIdentifier == "com.google.Chrome")
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let window = attribute(root, kAXFocusedWindowAttribute) as! AXUIElement
        precondition((attribute(window, kAXTitleAttribute) as? String)?.contains("Hannyeong IMK QA") == true,
                     "Open the owned Hannyeong IMK QA page before running")
        let field = attribute(root, kAXFocusedUIElementAttribute) as! AXUIElement
        precondition(attribute(field, kAXRoleAttribute) as? String == kAXTextAreaRole, "QA textarea is not focused")
        let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
        let source = sources.first { source in
            guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
            return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String == "com.yeop.inputmethod.Hannyeong"
        }!
        precondition(TISSelectInputSource(source) == noErr)
        Thread.sleep(forTimeInterval: 0.3)
        func post(_ code: CGKeyCode, flags: CGEventFlags = []) {
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, "Chrome lost focus")
            precondition(CFEqual(attribute(root, kAXFocusedUIElementAttribute) as! AXUIElement, field), "QA field lost focus")
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }
        func trace(_ label: String) {
            guard CommandLine.arguments.contains("--trace") else { return }
            var range = CFRange()
            let value = attribute(field, kAXSelectedTextRangeAttribute) as! AXValue
            precondition(AXValueGetValue(value, .cfRange, &range))
            print("TRACE \(label) caret=\(range) text=\((attribute(field, kAXValueAttribute) as! String).debugDescription)")
            fflush(stdout)
        }
        post(53); Thread.sleep(forTimeInterval: 0.05)
        post(0, flags: .maskCommand); Thread.sleep(forTimeInterval: 0.08)
        post(51); Thread.sleep(forTimeInterval: 0.12)
        for stroke in try Keyboard.strokes(for: "dkssud ") {
            post(stroke.code)
            Thread.sleep(forTimeInterval: 0.04)
        }
        Thread.sleep(forTimeInterval: 0.5)
        precondition(attribute(field, kAXValueAttribute) as? String == "안녕 ",
                     "The selected Hannyeong source is not converting in this host; reconnect the input source before testing")
        print("PASS active input source: dkssud -> 안녕"); fflush(stdout)
        let cases: [Case] = [
            Case(name: "reportedSentenceMiddle", actions: [.text("지금 처럼 이렇게 치다가 to go home 하면 ")], expected: "지금 처럼 이렇게 치다가 to go home 하면 "),
            Case(name: "paragraphRewriteAndContinue", actions: [.text("안녕\n안녕\nto go home 안녕 ")], expected: "안녕\n안녕\nto go home 안녕 "),
            Case(name: "backfill", actions: [.text("to go home ")], expected: "to go home "),
            Case(name: "reportedRepeatedGo", actions: [.text("go go go home ")], expected: "go go go home "),
            Case(name: "mixedSuffix", actions: [.text("to go homedmf ")], expected: "to go home을 "),
            Case(name: "repeatedMixed", actions: [.text("go go go homedmf ")], expected: "go go go home을 "),
            Case(name: "repeatedWord", actions: [.text("to go go home ")], expected: "to go go home "),
            Case(name: "sentenceStart", actions: [.text("so do it now ")], expected: "so do it now "),
            Case(name: "deleteAndRetypeSpace", actions: [.text("to go "), .key(51), .text(" home ")], expected: "to go home "),
            Case(name: "editCurrentWord", actions: [.text("to go"), .key(51), .text(" home ")], expected: "to g home "),
            Case(name: "caretAwayAndBack", actions: [.text("to go "), .key(123), .key(124), .text("home ")], expected: "to go home "),
            Case(name: "extraSpace", actions: [.text("to  go home ")], expected: "to  go home "),
            Case(name: "punctuation", actions: [.text("to go home.")], expected: "to go home."),
            Case(name: "koreanContextMixed", actions: [.text("wlrma to go homedmf ")], expected: "지금 to go home을 "),
            Case(name: "koreanKept", actions: [.text("togo qhr aksgdl qkedk ")], expected: "새해 복 많이 받아 "),
            Case(name: "returnBackfill", actions: [.text("to go home\n")], expected: "to go home\n"),
            Case(name: "returnAndContinue", actions: [.text("to go home\nhello ")], expected: "to go home\nhello "),
            Case(name: "continuousAfterRewrite", actions: [.text("go go go home hello ")], expected: "go go go home hello "),
            Case(name: "backspaceAfterRewrite", actions: [.text("go go go home "), .key(51), .text(" hello ")], expected: "go go go home hello "),
            Case(name: "caretAfterRewrite", actions: [.text("go go go home "), .key(123), .key(124), .text("hello ")], expected: "go go go home hello "),
            Case(name: "utf16PrefixAndSuffix", actions: [.text("to go home ")], expected: "🙂 to go home  [tail]", initial: "🙂  [tail]", caret: 3),
            Case(name: "mixedMiddleHome", actions: [.text("오늘 to go home을 ")], expected: "오늘 to go home을 "),
            Case(name: "mixedMiddleSo", actions: [.text("내일 so do it now ")], expected: "내일 so do it now "),
            Case(name: "mixedBetweenPhrases", actions: [.text("to go home 지금 so do it now ")], expected: "to go home 지금 so do it now "),
            Case(name: "mixedBackToKorean", actions: [.text("한글 쓰다가 to go home 다시 한글 ")], expected: "한글 쓰다가 to go home 다시 한글 "),
            Case(name: "mixedRepeatedGo", actions: [.text("go go go home 그리고 so do it now ")], expected: "go go go home 그리고 so do it now "),
            Case(name: "mixedProperNoun", actions: [.text("오늘 할 일은 Lunatask에 적고 to go home을 입력해 ")], expected: "오늘 할 일은 Lunatask에 적고 to go home을 입력해 "),
            Case(name: "ambiguousKoreanBeforeEnglish", actions: [.text("내 생각은 to go home이 맞아 ")], expected: "내 생각은 to go home이 맞아 "),
            Case(name: "ambiguousSoInKorean", actions: [.text("오늘 기분은 so so 그래도 괜찮아 ")], expected: "오늘 기분은 so so 그래도 괜찮아 "),
            Case(name: "mixedQuotedSuffix", actions: [.text("so do it now라고 말했어 ")], expected: "so do it now라고 말했어 "),
            Case(name: "mixedTypingInstruction", actions: [.text("to go home을 치다가 다시 한글로 ")], expected: "to go home을 치다가 다시 한글로 "),
        ]
        var results: [Result] = []
        let repetitions = CommandLine.arguments.first(where: { $0.hasPrefix("--repeats=") })
            .map { Int($0.dropFirst(10))! } ?? 1
        precondition(repetitions > 0)
        for delay in [0.015, 0.12] {
          for _ in 0..<repetitions {
            for fixture in cases {
                let filters = CommandLine.arguments.filter { $0.hasPrefix("--case=") }.map { String($0.dropFirst(7)) }
                if !filters.isEmpty && !filters.contains(fixture.name) { continue }
                post(53); Thread.sleep(forTimeInterval: 0.05)
                post(0, flags: .maskCommand); Thread.sleep(forTimeInterval: 0.08)
                post(51); Thread.sleep(forTimeInterval: 0.12)
                if !fixture.initial.isEmpty {
                    precondition(AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, fixture.initial as CFString) == .success)
                    let valueDeadline = Date().addingTimeInterval(2)
                    while attribute(field, kAXValueAttribute) as? String != fixture.initial && Date() < valueDeadline {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    precondition(attribute(field, kAXValueAttribute) as? String == fixture.initial, "QA initial text was not applied")
                    // Native cursor keys also synchronize the host's input-method caret cache.
                    post(123, flags: .maskCommand)
                    Thread.sleep(forTimeInterval: 0.05)
                    let prefix = (fixture.initial as NSString).substring(to: fixture.caret)
                    for _ in prefix {
                        post(124)
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    func caretReady() -> Bool {
                        guard let value = attribute(field, kAXSelectedTextRangeAttribute) else { return false }
                        var actual = CFRange()
                        return AXValueGetValue(value as! AXValue, .cfRange, &actual)
                            && actual.location == fixture.caret && actual.length == 0
                    }
                    let caretDeadline = Date().addingTimeInterval(2)
                    while !caretReady() && Date() < caretDeadline { Thread.sleep(forTimeInterval: 0.005) }
                    precondition(caretReady(), "QA initial caret was not applied")
                }
                for action in fixture.actions {
                    switch action {
                    case .text(let text):
                        for stroke in try Keyboard.strokes(for: text) {
                            post(stroke.code, flags: stroke.shift ? .maskShift : [])
                            Thread.sleep(forTimeInterval: delay)
                            trace("key \(stroke.code)")
                        }
                    case .key(let key): post(key); Thread.sleep(forTimeInterval: delay); trace("command \(key)")
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
                let actual = attribute(field, kAXValueAttribute) as! String
                let result = Result(name: fixture.name, delay: delay, expected: fixture.expected, actual: actual, passed: actual == fixture.expected)
                results.append(result)
                print("\(result.passed ? "PASS" : "FAIL") \(fixture.name) \(delay): \(actual.debugDescription)")
                fflush(stdout)
            }
          }
        }
        try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(results.allSatisfy(\.passed), "Real browser input regression failed")
    }
}
