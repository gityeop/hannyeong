import AppKit
import InputMethodKit
import HannyeongCore

/// The app reads rule-lexicon.json from its bundle; harnesses run from the repository root.
private let ruleLexicon = try! WordFrequencies.load(URL(fileURLWithPath: ".build/dependencies/rule-lexicon.json"))

@MainActor
private final class Fixture {
    let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var errors: [String] = []
    var session: CompositionSession!

    init(prefix: String, store: CorrectionStore, local: LocalDecisionClient) {
        view.isRichText = false
        view.string = prefix
        view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
        session = CompositionSession(client: view,
                                     corrections: store, localClient: local, wordFrequencies: ruleLexicon,
                                     selectCommittedText: { [view] expected in
                                         let end = view.selectedRange().location
                                         guard end >= expected.utf16.count else {
                                             throw LocalDecisionError(detail: "Native committed caret is before target")
                                         }
                                         let range = NSRange(location: end - expected.utf16.count, length: expected.utf16.count)
                                         guard view.selectCommittedText(in: range, expected: expected) else {
                                             throw LocalDecisionError(detail: "Native committed selection text changed")
                                         }
                                         return range
                                     }, confirmCommittedText: { [view] expected in
                                         let end = view.selectedRange().location
                                         guard end >= expected.utf16.count,
                                               (view.string as NSString).substring(with: NSRange(location: end - expected.utf16.count, length: expected.utf16.count)) == expected else {
                                             throw LocalDecisionError(detail: "Native commit suffix differs")
                                         }
                                         return end
                                     }, forwardHostEvent: { [view] event in view.applyHostEvent(event) }) { [weak self] message in
            self?.errors.append(message)
        }
    }

    @discardableResult
    func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) throws -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        let handled = session.handle(event)
        if !handled {
            if code == 51 { view.deleteBackward(nil) }
            else if code == 36 || code == 76 { view.keyDown(with: event) }
            else if !text.isEmpty { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        return handled
    }

    func type(_ raw: String) throws { for char in raw { try key(String(char)) } }

    func wait() async throws {
        for _ in 0..<300 {
            guard errors.isEmpty else { throw LocalDecisionError(detail: errors.joined(separator: "; ")) }
            if !view.hasMarkedText() && !session.hasPendingRewrite { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LocalDecisionError(detail: "Native session did not finish within 30 seconds")
    }
}

@main
private struct LocalSessionQA {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let result = try await run()
                let output = URL(fileURLWithPath: CommandLine.arguments[2])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(result).write(to: output)
                print("PASS native local input, F8 correction, punctuation, immediate replay, other-context isolation and Option-Delete; API calls=0")
                exit(0)
            } catch {
                fputs("Native local QA failed: \(error)\n", stderr)
                exit(1)
            }
        }
        application.run()
    }

    @MainActor
    static func run() async throws -> [String: String] {
        let runtime = try JSONDecoder().decode(LocalRuntimeConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CorrectionStore(url: folder.appendingPathComponent("corrections.json"))
        let local = LocalDecisionClient(runtime: runtime, personalURL: folder.appendingPathComponent("personal.json"))
        var result: [String: String] = [:]
        for (index, input) in ["dkssud", "hello", "slackdptj", "dkssud "].enumerated() {
            let expected = ["안녕", "hello", "slack에서", "안녕 "][index]
            let chat = Fixture(prefix: "앞부분은 남겨둘게. ", store: store, local: local)
            chat.view.sendsOnReturn = true
            try chat.type(input)
            let start = ContinuousClock.now
            let consumed = try chat.key("\r", code: index == 1 ? 76 : 36)
            guard !consumed, chat.view.returnEvents == 1,
                  !chat.view.receivedReturnWithMarkedText,
                  chat.view.lastSubmittedText == "앞부분은 남겨둘게. " + expected,
                  chat.view.string.isEmpty else {
                throw LocalDecisionError(detail: "Return must commit the decided text and reach the chat host once: \(chat.view.string)")
            }
            try await chat.wait()
            result["chatReturn\(index)"] = chat.view.lastSubmittedText
            result["chatReturnDuration\(index)"] = String(describing: start.duration(to: .now))
        }
        let shiftReturn = Fixture(prefix: "앞부분은 남겨둘게. ", store: store, local: local)
        shiftReturn.view.sendsOnReturn = true
        try shiftReturn.type("hello")
        let shiftConsumed = try shiftReturn.key("\r", code: 36, flags: .shift)
        guard !shiftConsumed, shiftReturn.view.returnEvents == 1,
              !shiftReturn.view.receivedReturnWithMarkedText,
              NSEvent.ModifierFlags(rawValue: shiftReturn.view.lastReturnModifiers).contains(.shift),
              shiftReturn.view.string == "앞부분은 남겨둘게. hello\n",
              shiftReturn.view.lastSubmittedText == nil else {
            throw LocalDecisionError(detail: "Shift+Return must reach the chat host as Shift+Return after commitment")
        }
        result["chatShiftReturn"] = shiftReturn.view.string
        let prefix = "나는 설거지부터 "
        let first = Fixture(prefix: prefix, store: store, local: local)
        try first.type("go")
        try first.key("?")
        try first.key(" ")
        try await first.wait()
        result["initial"] = first.view.string
        let candidates = try first.session.prepareFeedback()
        let displayed = try candidates.map { try first.session.feedbackDisplayText(for: $0) }
        guard displayed.count == 3, displayed.contains("해? "), displayed.contains("go? "), displayed.contains("gㅐ? ") else {
            throw LocalDecisionError(detail: "F8 must show B3 interpretations with punctuation")
        }
        try await first.session.applyFeedback(preferred: "해", scope: .context)
        guard first.view.string == prefix + "해? " else { throw LocalDecisionError(detail: "Native F8 correction did not preserve punctuation/space") }
        result["corrected"] = first.view.string
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("personal.json"))) as! [String: Any]
        guard persisted["revision"] as? Int == 1 else { throw LocalDecisionError(detail: "Online model update was not saved immediately") }
        let next = Fixture(prefix: prefix, store: CorrectionStore(url: store.url), local: local)
        try next.type("go")
        try next.key(" ")
        try await next.wait()
        guard next.view.string == prefix + "해 " else { throw LocalDecisionError(detail: "Correction did not apply to next word") }
        result["nextSameContext"] = next.view.string
        guard try store.load().preferred(raw: "go", before: "If the tests pass, we can ") == nil else {
            throw LocalDecisionError(detail: "Context correction became an unconditional preference")
        }
        let english = Fixture(prefix: "If the tests pass, we can ", store: store, local: local)
        try english.type("go")
        try english.key(" ")
        try await english.wait()
        result["otherContext"] = english.view.string
        guard english.view.string == "If the tests pass, we can go " else {
            throw LocalDecisionError(detail: "Korean correction changed the English reading of go")
        }
        let deletion = Fixture(prefix: "", store: store, local: local)
        try deletion.type("dkssud")
        try deletion.key("", code: 51, flags: .option)
        guard deletion.view.string.isEmpty else { throw LocalDecisionError(detail: "Option-Delete did not delete the whole word") }
        result["optionDelete"] = deletion.view.string
        let committedDeletion = Fixture(prefix: "", store: store, local: local)
        try committedDeletion.type("backspace ")
        try await committedDeletion.wait()
        try committedDeletion.key("", code: 51)
        try committedDeletion.key("", code: 51)
        guard committedDeletion.view.string == "backspac", !committedDeletion.view.hasMarkedText() else {
            throw LocalDecisionError(detail: "Backspace reopened a decided word instead of deleting characters: \(committedDeletion.view.string)")
        }
        try committedDeletion.key(" ")
        guard committedDeletion.view.string == "backspac " else {
            throw LocalDecisionError(detail: "Space reclassified a deleted word")
        }
        result["committedBackspace"] = committedDeletion.view.string
        let koreanDeletion = Fixture(prefix: "", store: store, local: local)
        try koreanDeletion.type("dkssud ")
        try await koreanDeletion.wait()
        try koreanDeletion.key("", code: 51)
        try koreanDeletion.key("", code: 51)
        guard koreanDeletion.view.string == "안", !koreanDeletion.view.hasMarkedText() else {
            throw LocalDecisionError(detail: "Confirmed Hangul deletion must remove a syllable")
        }
        result["confirmedHangulBackspace"] = koreanDeletion.view.string
        let pendingDeletion = Fixture(prefix: "", store: store, local: local)
        try pendingDeletion.type("backspace ")
        try pendingDeletion.key("", code: 51)
        try await pendingDeletion.wait()
        guard pendingDeletion.view.string == "backspace" else {
            throw LocalDecisionError(detail: "Backspace during a pending decision must remove the separator")
        }
        result["pendingSeparatorBackspace"] = pendingDeletion.view.string
        let enter = Fixture(prefix: "앞선 문장은 그대로 남아야 해. ", store: store, local: local)
        try enter.type("dkssud")
        try enter.key("\r", code: 36)
        try enter.type("gktpdy ")
        try await enter.wait()
        guard enter.view.string == "앞선 문장은 그대로 남아야 해. 안녕\n하세요 ", enter.view.markedLineBreaks == 0 else {
            throw LocalDecisionError(detail: "Return must retain prior text and keep newlines out of marked composition: \(enter.view.string)")
        }
        result["returnRetainsPrefix"] = enter.view.string
        let opaque = Fixture(prefix: "", store: store, local: local)
        opaque.view.hidesSurroundingText = true
        try opaque.type("ajswj ")
        try await opaque.wait()
        try opaque.type("previewgoqhfuekrk ")
        try await opaque.wait()
        guard opaque.view.string == "먼저 preview해보려다가 " else {
            throw LocalDecisionError(detail: "Host without surrounding-text access lost session context: \(opaque.view.string)")
        }
        result["opaqueHostContext"] = opaque.view.string
        let mixedPrefix = "지금 slack에서 작업해. 방금 "
        let mixed = Fixture(prefix: mixedPrefix, store: store, local: local)
        try mixed.type("slackdptj")
        try mixed.key("?")
        try mixed.key(" ")
        try await mixed.wait()
        result["mixedInitial"] = mixed.view.string
        let mixedCandidates = try mixed.session.prepareFeedback()
        guard mixedCandidates.contains(where: { $0.text == "slack에서" }),
              try mixedCandidates.map({ try mixed.session.feedbackDisplayText(for: $0) }).contains("slack에서? ") else {
            throw LocalDecisionError(detail: "F8 did not include the mixed interpretation and punctuation")
        }
        try await mixed.session.applyFeedback(preferred: "slack에서", scope: .context)
        guard mixed.view.string == mixedPrefix + "slack에서? " else {
            throw LocalDecisionError(detail: "Mixed feedback changed punctuation or spacing")
        }
        let repeated = Fixture(prefix: mixedPrefix, store: CorrectionStore(url: store.url), local: local)
        try repeated.type("slackdptj")
        try repeated.key(" ")
        try await repeated.wait()
        guard repeated.view.string == mixedPrefix + "slack에서 " else {
            throw LocalDecisionError(detail: "Mixed correction was not applied immediately")
        }
        result["mixedCorrected"] = mixed.view.string
        result["mixedRepeated"] = repeated.view.string
        let examples: [(String, String)] = [
            ("xptmxm goqhsms wnd dlrj dhodlfo rkskekfk\n\nwlrma xptmxmgoqhrh dlTsmsep\n\nwlrma dlfjgrp Wnr wjrrh dlTsmsep tlfwp tkdydwnddlwl dksgsms duddjemfdlsep dlfjgrp tjsxorehlsms wnd. dlrj rotjsgodigkfrj rkxdk. ",
             "테스트 해보는 중 이거 왜이래 가나다라\n\n지금 테스트해보고 있는데\n\n지금 이렇게 쭉 적고 있는데 실제 사용중이지 않는 영어들인데 이렇게 선택되는 중. 이거 개선해야할거 같아. "),
            ("If the tests pass, we can go home. ", "If the tests pass, we can go home. ")
        ]
        for (index, example) in examples.enumerated() {
            let fixture = Fixture(prefix: "", store: store, local: local)
            try fixture.type(example.0)
            try await fixture.wait()
            guard fixture.view.string == example.1 else {
                throw LocalDecisionError(detail: "Sequential native input mismatch: \(fixture.view.string)")
            }
            result["sequential\(index)"] = fixture.view.string
        }
        let boundaries: [(String, String, String)] = [
            ("회의록은 ", "craftdp", "craft에"),
            ("혹시 ", "raycastfh", "raycast로"),
            ("이건 ", "bugdlsrk", "bug인가"),
            ("이건 bug인가 ", "featuredlsrk", "feature인가"),
            ("먼저 ", "testgoqhrh", "test해보고"),
            ("먼저 test해보고 이상 없으면 ", "meargegkfrp", "mearge할게"),
            ("새 ", "repofmf", "repo를"),
            ("새 repo를 열었는데 ", "READMErk", "README가"),
            ("늦기 전에 unmute해두고 끝난 알림은 ", "snoozegkfrpbb", "snooze할게ㅠㅠ"),
            ("저녁 약속 전에 ", "nextjsbb", "nextjsㅠㅠ")
        ]
        for (index, example) in boundaries.enumerated() {
            let fixture = Fixture(prefix: example.0, store: store, local: local)
            try fixture.type(example.1)
            try fixture.key("?")
            try fixture.key(" ")
            try await fixture.wait()
            guard fixture.view.string == example.0 + example.2 + "? " else {
                throw LocalDecisionError(detail: "Mixed boundary regression: \(fixture.view.string)")
            }
            result["boundary\(index)"] = fixture.view.string
        }
        let decomposed = Fixture(prefix: "회의록은 ".decomposedStringWithCanonicalMapping, store: store, local: local)
        try decomposed.type("craftdp")
        try decomposed.key(" ")
        try await decomposed.wait()
        guard decomposed.view.string == "회의록은 craft에 " else {
            throw LocalDecisionError(detail: "Decomposed context changed the mixed decision")
        }
        result["decomposedContext"] = decomposed.view.string
        let paragraph = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: String]
        let continuous = Fixture(prefix: "", store: store, local: local)
        try continuous.type(paragraph["raw"]!)
        try await continuous.wait()
        guard continuous.view.string == paragraph["expected"]! else {
            throw LocalDecisionError(detail: "Continuous user paragraph mismatch: \(continuous.view.string)")
        }
        result["userParagraph"] = continuous.view.string
        let fresh = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))) as! [String: String]
        for opaqueHost in [false, true] {
            let fixture = Fixture(prefix: "", store: store, local: local)
            fixture.view.hidesSurroundingText = opaqueHost
            for char in fresh["raw"]! {
                try fixture.key(String(char), code: char == "\n" ? 36 : 0)
                if !char.isLetter && fixture.view.hasMarkedText() { try await fixture.wait() }
            }
            try await fixture.wait()
            guard fixture.view.string == fresh["expected"]! else {
                throw LocalDecisionError(detail: "Fresh user paragraph with opaque=\(opaqueHost) mismatch: \(fixture.view.string)")
            }
            guard fixture.view.markedLineBreaks == 0 else {
                throw LocalDecisionError(detail: "Fresh paragraph entered newline into marked text")
            }
            result[opaqueHost ? "freshOpaqueParagraph" : "freshReadableParagraph"] = fixture.view.string
        }
        return result
    }
}
