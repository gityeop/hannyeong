import AppKit
import HannyeongCore

/// The app reads rule-lexicon.json from its bundle; harnesses run from the repository root.
private let ruleLexicon = try! WordFrequencies.load(URL(fileURLWithPath: ".build/dependencies/rule-lexicon.json"))

@main
private struct RightCommandQA {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await gestures(flags: .command)
                try await gestures(flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10))
                let runtime = try JSONDecoder().decode(LocalRuntimeConfiguration.self,
                    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
                try await composition(runtime)
                try await toggleDoesNotLearn(runtime)
                print("PASS right Command single/double taps, held/chord/context cancellation; pending/completed/mixed/queued words, correction readiness, caret protection; single taps never learn; explicit correction saves")
                exit(0)
            } catch {
                fputs("Right Command QA failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func gestures(flags right: NSEvent.ModifierFlags) async throws {
        var actions: [RightCommandGesture.Action] = []
        let gesture = RightCommandGesture { actions.append($0) }
        func tap(_ start: Double) {
            gesture.handle(event(.flagsChanged, 54, flags: right, at: start))
            gesture.handle(event(.flagsChanged, 54, at: start + 0.04))
        }
        tap(1)
        try require(actions.isEmpty, "Single action ran before the double-tap interval")
        try await Task.sleep(for: .milliseconds(300))
        try require(actions == [.toggleLanguage], "Single tap did not toggle exactly once")
        actions.removeAll()
        tap(2); tap(2.15)
        try await Task.sleep(for: .milliseconds(300))
        try require(actions == [.correction], "Double tap also toggled the word")
        actions.removeAll()
        tap(3)
        gesture.handle(event(.flagsChanged, 54, flags: right, at: 3.24))
        try await Task.sleep(for: .milliseconds(300))
        try require(actions.isEmpty, "Single action fired while the second Command was held")
        gesture.handle(event(.flagsChanged, 54, at: 3.30))
        try require(actions == [.correction], "Second press within 250ms was not a double tap")
        actions.removeAll()
        for code: UInt16 in [8, 9] {
            gesture.handle(event(.flagsChanged, 54, flags: right, at: 4))
            gesture.handle(event(.keyDown, code, flags: right, at: 4.05))
            gesture.handle(event(.flagsChanged, 54, at: 4.1))
        }
        gesture.handle(event(.flagsChanged, 55, flags: .command, at: 5))
        gesture.handle(event(.flagsChanged, 55, at: 5.1))
        gesture.handle(event(.flagsChanged, 54, flags: right.union(.shift), at: 6))
        gesture.handle(event(.flagsChanged, 54, at: 6.1))
        gesture.handle(event(.flagsChanged, 54, flags: right, at: 7))
        gesture.handle(event(.flagsChanged, 54, at: 8))
        try await Task.sleep(for: .milliseconds(300))
        try require(actions.isEmpty, "Copy/paste, left Command, modified Command or a long hold triggered an action")
        tap(9)
        gesture.handle(event(.keyDown, 0, at: 9.1))
        try await Task.sleep(for: .milliseconds(300))
        try require(actions.isEmpty, "Delayed toggle replaced subsequent typing")
        tap(10); gesture.cancel()
        try await Task.sleep(for: .milliseconds(300))
        try require(actions.isEmpty, "Delayed toggle survived a client/source change")
    }

    @MainActor private static func composition(_ runtime: LocalRuntimeConfiguration) async throws {
        let suite = "HannyeongRightCommandQA." + UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CorrectionStore(url: folder.appendingPathComponent("corrections.json"))
        for (raw, selected) in [("dkssud", "안녕"), ("hello", "hello"), ("slackdptj", "slack에서")] {
            try store.record(raw: raw, before: "", rejected: raw == selected ? "" : raw, preferred: selected, scope: .always)
        }
        let seeded = Set(try store.load().entries.map(Pair.init))
        let local = LocalDecisionClient(runtime: runtime, personalURL: folder.appendingPathComponent("personal.json"))
        let view = NativeTextView(frame: .zero)
        view.string = "😀 앞말 "
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        let errors = NSMutableArray()
        let session = CompositionSession(client: view, corrections: store, localClient: local, wordFrequencies: ruleLexicon,
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
                                     }, forwardHostEvent: { [view] event in view.applyHostEvent(event) }) { errors.add($0) }
        func type(_ text: String) {
            for char in text { _ = session.handle(event(.keyDown, 0, text: String(char))) }
        }
        type("dkssud")
        session.toggleLanguage()
        try require(view.string == "😀 앞말 dkssud" && !view.hasMarkedText(), "Pending Hangul did not reverse to its original keys")
        session.toggleLanguage()
        try require(view.string == "😀 앞말 안녕", "Pending-word reversal could not restore Hangul")
        type("  ")
        session.toggleLanguage()
        try require(view.string == "😀 앞말 dkssud  ", "Reversal changed the prefix or trailing spaces")
        session.toggleLanguage()
        type("hello ")
        try await wait(view, errors, session)
        try require(view.string == "😀 앞말 안녕  hello ", "English decision changed")
        session.toggleLanguage()
        try require(view.string == "😀 앞말 안녕  ㅗ디ㅣㅐ ", "English did not reverse to Hangul")
        session.toggleLanguage()
        type("slackdptj ")
        try await wait(view, errors, session)
        let mixed = view.string
        try require(mixed == "😀 앞말 안녕  hello slack에서 ", "Mixed word did not retain its saved correction")
        session.toggleLanguage()
        try require(view.string == "😀 앞말 안녕  hello slackdptj ", "Mixed word did not reverse to original keys")
        try require(try store.alwaysEntry(raw: "slackdptj")?.preferred == "slack에서", "Single tap changed the saved mixed word")
        session.toggleLanguage()
        try require(view.string == mixed, "Mixed result was replaced by full Hangul transliteration when restored")
        try require(try store.alwaysEntry(raw: "slackdptj")?.preferred == "slack에서", "Even taps did not restore the saved mixed word")
        session.suspend(); session.resume(); session.toggleLanguage(); session.toggleLanguage()
        try require(view.string == mixed, "Same-client activation lost the exact mixed result")
        type("hello dkssud")
        session.toggleLanguage()
        try require(view.string == mixed + "hello dkssud", "Queued word's model choice changed during a pending-word toggle")
        try await Task.sleep(for: .milliseconds(50))
        try require(view.string == mixed + "hello dkssud", "Cancelled inference overwrote the gesture")
        session.toggleLanguage()
        try session.completeForCorrection()
        let candidates = try session.prepareFeedback()
        try require(candidates.contains(where: { $0.text == "안녕" }), "Correction candidates were unavailable after reversal")
        session.cancelFeedback()
        type(" hello")
        try session.completeForCorrection()
        try require(view.string.hasSuffix("안녕 hello"), "Double-tap preparation changed the model result")
        _ = try session.prepareFeedback()
        session.cancelFeedback()
        let beforeMove = view.string
        view.setSelectedRange(NSRange(location: 0, length: 0))
        session.toggleLanguage()
        try require(view.string == beforeMove && errors.count == 1, "Moved caret silently changed the old word")
        try require(Set(try store.load().entries.map(Pair.init)) == seeded, "Even taps left saved corrections changed")
        try require(errors.count == 1, "Personal model update failed: \(errors)")
    }

    /// Single taps only change the current text; candidate selection explicitly saves a correction.
    @MainActor private static func toggleDoesNotLearn(_ runtime: LocalRuntimeConfiguration) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HannyeongRightCommandQA." + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CorrectionStore(url: folder.appendingPathComponent("corrections.json"))
        let personal = folder.appendingPathComponent("personal.json")
        let local = LocalDecisionClient(runtime: runtime, personalURL: personal)
        let view = NativeTextView(frame: .zero)
        view.string = "앞말 "
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        let errors = NSMutableArray()
        let session = CompositionSession(client: view, corrections: store, localClient: local, wordFrequencies: ruleLexicon,
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
                                     }, forwardHostEvent: { [view] event in view.applyHostEvent(event) }) { errors.add($0) }
        func type(_ text: String) {
            for char in text { _ = session.handle(event(.keyDown, 0, text: String(char))) }
        }
        type("rkskek")
        session.toggleLanguage()
        try require(view.string == "앞말 rkskek", "Pending Hangul did not reverse to its original keys")
        try require(try store.load().entries.isEmpty, "Single tap saved a correction")
        try require(!FileManager.default.fileExists(atPath: personal.path), "Single tap wrote personal learning")
        session.toggleLanguage()
        try require(view.string == "앞말 가나다", "Second tap did not restore Hangul")
        try require(try store.load().entries.isEmpty, "Repeated single taps saved a correction")
        session.toggleLanguage()
        try session.completeForCorrection()
        let candidates = try session.prepareFeedback()
        let selected = candidates.firstIndex { $0.text == "가나다" }!
        try await session.applyFeedback(preferred: candidates[selected].text, scope: .context)
        try require(try store.load().preferred(raw: "rkskek", before: "앞말 ") == "가나다",
                    "Explicit candidate selection did not save the correction")
        try require(errors.count == 0, "Unexpected error: \(errors)")
    }

    private struct Pair: Hashable {
        let raw, before, preferred: String
        let scope: CorrectionScope
        init(_ entry: CorrectionExample) {
            raw = entry.raw; before = entry.before; preferred = entry.preferred; scope = entry.scope
        }
    }

    @MainActor private static func wait(_ view: NativeTextView, _ errors: NSMutableArray, _ session: CompositionSession) async throws {
        for _ in 0..<100 {
            try require(errors.count == 0, "Unexpected error: \(errors)")
            if !view.hasMarkedText() && !session.hasPendingRewrite { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalDecisionError(detail: "Space commitment did not finish")
    }
    private static func event(_ type: NSEvent.EventType, _ code: UInt16, text: String = "", flags: NSEvent.ModifierFlags = [], at timestamp: Double = 0) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: timestamp, windowNumber: 0,
                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw LocalDecisionError(detail: message) }
    }
}
