import AppKit
import InputMethodKit
import HannyeongCore

/// The app reads rule-lexicon.json from its bundle; harnesses run from the repository root.
private let ruleLexicon = try! WordFrequencies.load(URL(fileURLWithPath: ".build/dependencies/rule-lexicon.json"))

/// Rewrites committed words without retaining a multi-word marked composition.
@MainActor
private final class Fixture {
    let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    let client = NativeInputClient()
    var errors: [String] = []
    var session: CompositionSession!
    var selectionAttempts = 0
    var selectionError: Error?

    init(prefix: String, store: CorrectionStore, local: LocalDecisionClient,
         axParagraphOffset: Int = 0,
         defaults: UserDefaults = .standard,
         onPreview: ((String?) -> Void)? = nil) {
        view.isRichText = false
        view.string = prefix
        view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
        client.view = view
        session = CompositionSession(client: client, corrections: store, localClient: local, wordFrequencies: ruleLexicon,
                                     previewDefaults: defaults,
                                     selectCommittedText: { [view, weak self] expected in
                                         self?.selectionAttempts += 1
                                         if let error = self?.selectionError { throw error }
                                         let end = view.selectedRange().location
                                         guard end >= expected.utf16.count else {
                                             throw LocalDecisionError(detail: "Native committed caret is before target")
                                         }
                                         let range = NSRange(location: end - expected.utf16.count, length: expected.utf16.count)
                                         guard view.selectCommittedText(in: range, expected: expected) else {
                                             throw LocalDecisionError(detail: "Native committed selection text changed")
                                         }
                                         return NSRange(location: range.location - axParagraphOffset, length: range.length)
                                     }, confirmCommittedText: { [view] expected in
                                         let end = view.selectedRange().location
                                         guard end >= expected.utf16.count,
                                               (view.string as NSString).substring(with: NSRange(location: end - expected.utf16.count, length: expected.utf16.count)) == expected else {
                                             throw LocalDecisionError(detail: "Native commit suffix differs")
                                         }
                                         return end - axParagraphOffset
                                     }, forwardHostEvent: { [view] event in view.applyHostEvent(event) },
                                     onPreview: onPreview) { [weak self] message in
            self?.errors.append(message)
        }
    }

    func key(_ text: String, code: UInt16 = 0) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        if !session.handle(event) {
            if code == 51 { view.deleteBackward(nil) }
            else if code == 36 { view.keyDown(with: event) }
            else { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }

    func type(_ raw: String) { for char in raw { key(String(char)) } }

    func settle() async throws {
        for _ in 0..<300 {
            guard errors.isEmpty else { throw LocalDecisionError(detail: errors.joined(separator: "; ")) }
            if !view.hasMarkedText() && !session.hasPendingRewrite { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LocalDecisionError(detail: "Native session did not settle within 30 seconds")
    }

    func expectError() async throws {
        for _ in 0..<300 {
            if !errors.isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LocalDecisionError(detail: "Unsafe replacement was not rejected")
    }
}

@main
private struct BackfillQA {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                for line in try await run() { print(line) }
                print("PASS committed-word backfill native session")
                exit(0)
            } catch {
                fputs("Backfill QA failed: \(error)\n", stderr)
                exit(1)
            }
        }
        application.run()
    }

    @MainActor
    static func run() async throws -> [String] {
        let runtime = try JSONDecoder().decode(LocalRuntimeConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CorrectionStore(url: folder.appendingPathComponent("corrections.json"))
        let local = LocalDecisionClient(runtime: runtime, personalURL: folder.appendingPathComponent("personal.json"))
        var log: [String] = []
        func expect(_ fixture: Fixture, _ expected: String, _ name: String) throws {
            guard fixture.view.string == expected, !fixture.view.hasMarkedText() else {
                throw LocalDecisionError(detail: "\(name): got \(fixture.view.string.debugDescription), expected \(expected.debugDescription), marked=\(fixture.view.hasMarkedText())")
            }
            log.append("\(name): \(fixture.view.string.debugDescription)")
        }
        let suite = "HannyeongIssue4QA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw LocalDecisionError(detail: name) }
            log.append(name)
        }
        try require(PriorWordCorrectionSettings.enabled(in: defaults), "priorCorrectionDefaultsToEnabled")
        defaults.set(false, forKey: PriorWordCorrectionSettings.enabledKey)
        try require(!PriorWordCorrectionSettings.enabled(in: UserDefaults(suiteName: suite)!), "priorCorrectionDisabledPersists")

        // A not-yet-reflected Chromium range must keep the existing bounded wait alive.
        try require(try !CommittedTextSelection.committedTextMatches(status: .noValue, text: nil, expected: "새 해 home "),
                    "transientMissingAXRangeWaits")
        try require(try CommittedTextSelection.committedTextMatches(status: .success, text: "새 해 home " as CFString, expected: "새 해 home "),
                    "reflectedAXRangeMatches")
        try require(try !CommittedTextSelection.committedTextMatches(status: .success, text: "다른 글자" as CFString, expected: "새 해 home "),
                    "changedAXTextDoesNotMatch")
        do {
            _ = try CommittedTextSelection.committedTextMatches(status: .parameterizedAttributeUnsupported, text: nil, expected: "새 해 home ")
            throw LocalDecisionError(detail: "Unsupported AX operation was silently accepted")
        } catch CommittedTextSelection.Failure.accessibility(_, .parameterizedAttributeUnsupported) {
            log.append("unsupportedAXRangeStillFails")
        }

        let disabled = Fixture(prefix: "", store: store, local: local, defaults: defaults)
        disabled.type("to go home ")
        try await disabled.settle()
        try expect(disabled, "새 해 home ", "disabledKeepsPriorWords")
        disabled.key("", code: 51)
        disabled.key(" ")
        disabled.type("dkssud")
        disabled.key("\r", code: 36)
        try await disabled.settle()
        try expect(disabled, "새 해 home 안녕\n", "disabledPreservesBackspaceSpaceReturnAndCurrentConversion")
        try require(disabled.selectionAttempts == 0, "disabledNeverSelectsCommittedText")

        disabled.type("dkssud")
        disabled.session.toggleLanguage()
        try expect(disabled, "새 해 home 안녕\ndkssud", "manualToggleWorksWhenDisabled")
        disabled.session.toggleLanguage()
        await disabled.session.finishLearning()
        try expect(disabled, "새 해 home 안녕\n안녕", "manualToggleRestoresWhenDisabled")

        defaults.set(true, forKey: PriorWordCorrectionSettings.enabledKey)
        let live = Fixture(prefix: "", store: store, local: local, defaults: defaults)
        live.type("to go ")
        defaults.set(false, forKey: PriorWordCorrectionSettings.enabledKey)
        live.type("home ")
        try await live.settle()
        try expect(live, "새 해 home ", "disablingClearsRetainedPriorWords")
        try require(live.selectionAttempts == 0, "liveDisableDoesNotRewrite")
        defaults.set(true, forKey: PriorWordCorrectionSettings.enabledKey)
        let enabled = Fixture(prefix: "", store: store, local: local, defaults: defaults)
        enabled.type("to go home ")
        try await enabled.settle()
        try expect(enabled, "to go home ", "reenabledPriorCorrectionWorks")
        try require(enabled.selectionAttempts == 1, "enabledUsesCommittedSelection")

        let failed = Fixture(prefix: "", store: store, local: local, defaults: defaults)
        failed.selectionError = CommittedTextSelection.Failure.accessibility("committed text", .parameterizedAttributeUnsupported)
        failed.type("to go home ")
        // Following physical events are buffered while the attempted rewrite runs.
        failed.type("hello ")
        try await failed.expectError()
        for _ in 0..<100 where failed.session.hasPendingRewrite { try await Task.sleep(for: .milliseconds(10)) }
        try expect(failed, "새 해 home hello ", "failedRewritePreservesAndDrainsTyping")
        try require(failed.errors.count == 1 && failed.errors[0].contains("앞 단어 교정") && !failed.errors[0].contains("Space"),
                    "rewriteFailureDoesNotOfferInvalidRetry")
        defaults.set(false, forKey: PriorWordCorrectionSettings.enabledKey)
        failed.errors.removeAll()
        failed.type("to go home ")
        try await failed.settle()
        try require(failed.selectionAttempts == 1 && failed.errors.isEmpty, "disableAfterFailureStopsRepeatedCorrectionErrors")

        if CommandLine.arguments.contains("--issue-4-only") { return log }

        // Hiding the real popup can reenter IMK and suspend the session during commit.
        var suspendOnHide = false
        var suspended: Fixture!
        suspended = Fixture(prefix: "", store: store, local: local, onPreview: { text in
            if text == nil, suspendOnHide {
                suspendOnHide = false
                suspended.session.suspend()
            }
        })
        suspended.type("dkssud")
        suspendOnHide = true
        suspended.key(" ")
        try expect(suspended, "안녕 ", "suspendWhileHidingPreview")
        suspended = nil

        // Ordinary ambiguous words must not wait for an AX confirmation before the next key.
        let immediate = Fixture(prefix: "", store: store, local: local)
        immediate.type("to ")
        guard !immediate.session.hasPendingRewrite else {
            throw LocalDecisionError(detail: "Ordinary word commitment holds subsequent typing for AX confirmation")
        }
        immediate.type("go ")
        guard !immediate.session.hasPendingRewrite else {
            throw LocalDecisionError(detail: "Retaining preceding words holds subsequent typing for AX confirmation")
        }
        try expect(immediate, "새 해 ", "ordinaryWordsDoNotPauseTyping")
        immediate.type("home ")
        try await immediate.settle()
        try expect(immediate, "to go home ", "immediateWordsStillBackfill")

        // Chromium paragraph boundaries have different offsets in IMK and AX.
        let paragraphPrefix = "문단 하나.\n문단 둘.\n"
        let paragraphs = Fixture(prefix: paragraphPrefix, store: store, local: local, axParagraphOffset: 2)
        paragraphs.type("to go home ")
        try await paragraphs.settle()
        try expect(paragraphs, paragraphPrefix + "to go home ", "paragraphCoordinateRewrite")
        paragraphs.session.toggleLanguage()
        try expect(paragraphs, paragraphPrefix + "to go ㅙㅡㄷ ", "paragraphCoordinateToggle")
        paragraphs.session.toggleLanguage()
        try expect(paragraphs, paragraphPrefix + "to go home ", "paragraphCoordinateToggleBack")
        await paragraphs.session.finishLearning()

        // Space-separated words, including fast typing while inference is pending.
        let cases: [(String, String, String)] = [
            ("reportedSentenceMiddle", "wlrma cjfja dlfjgrp clekrk to go home gkaus ", "지금 처럼 이렇게 치다가 to go home 하면 "),
            ("backfill", "to go home ", "to go home "),
            ("repeatedWord", "to go go home ", "to go go home "),
            ("repeatedGo", "go go go home ", "go go go home "),
            ("repeatedGoMixed", "go go go homedmf ", "go go go home을 "),
            ("mixedAnchor", "to go homedmf ", "to go home을 "),
            ("mixedAnchorLocation", "to go homedptj ", "to go home에서 "),
            ("koreanContext", "wlrma to go home ", "지금 to go home "),
            ("koreanContextRepeatedWord", "wlrma to go go home ", "지금 to go go home "),
            ("koreanContextMixed", "wlrma to go homedmf ", "지금 to go home을 "),
            ("koreanPairKept", "wlrma to go rPghlrdmf ", "지금 새 해 계획을 "),
            ("sentenceInitialPair", "did you see ", "did you see "),
            ("koreanThenEnglishKept", "dhsmf to review ghkrdlsgoTdj ", "오늘 새 review 확인했어 "),
            ("englishBetweenKoreanKept", "rmfja so npm aksemfdjTdj ", "그럼 내 npm 만들었어 "),
            ("koreanSentence", "togo qhr aksgdl qkedk ", "새해 복 많이 받아 "),
            ("englishToKorean", "dnjsgksms tor rmfmtdl ", "원하는 색 그릇이 "),
            // Sentence-initial words the model is sure of, held because both readings are common words.
            ("frequentSo", "so do it now ", "so do it now "),
            ("frequentGo", "go to bed ", "go to bed "),
            ("frequentSoWhat", "so what do you think ", "so what do you think "),
            ("frequentKoreanKept", "so rjdi rmrj ", "내 거야 그거 "),
            ("frequentKoreanVerbKept", "go qhfrp ", "해 볼게 "),
            ("frequentKoreanThenEnglishKept", "to branch aksemfdjTdj ", "새 branch 만들었어 "),
            ("frequentKoreanThenMixedKept", "to branchfmf aksemfdjTdj ", "새 branch를 만들었어 "),
            ("koreanContextSingleMixedKept", "wlrma to branchfmf aksemfdjTdj ", "지금 새 branch를 만들었어 "),
            ("frequentKoreanMacbookKept", "so macbook djel dlTwl ", "내 macbook 어디 있지 "),
        ]
        for mode in 0..<3 {
            for (name, keys, expected) in cases {
                let fixture = Fixture(prefix: "", store: store, local: local)
                fixture.view.commitsOnlyMarkedText = mode == 1
                fixture.client.hidesMarkedLocation = mode == 2
                fixture.type(keys)
                let label = name + ["", "MarkedOnly", "HiddenMarkedLocation"][mode]
                do {
                    try await fixture.settle()
                    try expect(fixture, expected, label)
                } catch { throw LocalDecisionError(detail: "\(label): \(error)") }
            }
        }
        let continuous = Fixture(prefix: "", store: store, local: local)
        continuous.client.hidesMarkedLocation = true
        for character in "to go homedmf " {
            continuous.key(String(character))
            try await Task.sleep(for: .milliseconds(15))
        }
        try await continuous.settle()
        try expect(continuous, "to go home을 ", "continuous15msHiddenMarkedLocation")
        // Return ends the composition with the anchor decided synchronously.
        let enter = Fixture(prefix: "", store: store, local: local)
        enter.type("to go home")
        enter.key("\r", code: 36)
        try await enter.settle()
        try expect(enter, "to go home\n", "returnBackfill")
        // Earlier words are ordinary committed text while only the current word is marked.
        let held = Fixture(prefix: "", store: store, local: local)
        held.view.commitsOnlyMarkedText = true
        held.type("to ")
        try await held.settle()
        try expect(held, "새 ", "firstWordCommitted")
        held.type("go ")
        try await held.settle()
        try expect(held, "새 해 ", "secondWordCommitted")
        held.type("homx")
        held.key("", code: 51)
        held.type("e")
        guard held.view.markedRange() == NSRange(location: "새 해 ".utf16.count, length: "ㅙㅡㄷ".utf16.count) else {
            throw LocalDecisionError(detail: "Current composition includes previously committed words")
        }
        held.key(" ")
        try await held.settle()
        try expect(held, "to go home ", "backfillAfterCurrentWordEdit")
        // Right Command after a rewrite toggles only the last word, then restores it.
        held.session.toggleLanguage()
        try expect(held, "to go ㅙㅡㄷ ", "toggleAnchor")
        held.session.toggleLanguage()
        try expect(held, "to go home ", "toggleAnchorBack")
        await held.session.finishLearning()

        let entered = Fixture(prefix: "", store: store, local: local)
        entered.view.commitsOnlyMarkedText = true
        entered.type("to ")
        try await entered.settle()
        entered.type("go ")
        try await entered.settle()
        entered.type("home")
        entered.key("\r", code: 36)
        try await entered.settle()
        try expect(entered, "to go home\n", "returnAfterCommittedWords")

        let emoji = Fixture(prefix: "🙂 ", store: store, local: local)
        emoji.view.commitsOnlyMarkedText = true
        for word in ["to ", "go ", "home "] {
            emoji.type(word)
            try await emoji.settle()
        }
        try expect(emoji, "🙂 to go home ", "utf16ReplacementRange")

        let spaced = Fixture(prefix: "", store: store, local: local)
        spaced.view.commitsOnlyMarkedText = true
        spaced.type("to ")
        try await spaced.settle()
        spaced.key(" ")
        spaced.type("go home ")
        try await spaced.settle()
        try expect(spaced, "to  go home ", "extraSpacePreserved")

        let respaced = Fixture(prefix: "", store: store, local: local)
        respaced.view.commitsOnlyMarkedText = true
        respaced.type("to go ")
        try await respaced.settle()
        respaced.key("", code: 51)
        respaced.key(" ")
        respaced.type("home ")
        try await respaced.settle()
        try expect(respaced, "to go home ", "deleteAndRetypeSpace")

        let editedGo = Fixture(prefix: "", store: store, local: local)
        editedGo.type("to ")
        try await editedGo.settle()
        editedGo.type("go")
        editedGo.key("", code: 51)
        editedGo.type(" home ")
        try await editedGo.settle()
        try expect(editedGo, "to g home ", "editCurrentGo")

        let hostCommits = Fixture(prefix: "", store: store, local: local)
        hostCommits.view.commitsOnlyMarkedText = true
        for word in ["to ", "go ", "go ", "home "] {
            hostCommits.type(word)
            try await hostCommits.settle()
            hostCommits.session.commitPending()
            hostCommits.session.suspend()
            hostCommits.session.resume()
        }
        try expect(hostCommits, "to go go home ", "hostCommitBetweenWords")

        let returned = Fixture(prefix: "", store: store, local: local)
        returned.view.commitsOnlyMarkedText = true
        returned.type("to go ")
        try await returned.settle()
        let end = returned.view.string.utf16.count
        returned.key("", code: 123)
        returned.view.setSelectedRange(NSRange(location: end - 1, length: 0))
        returned.key("", code: 124)
        returned.view.setSelectedRange(NSRange(location: end, length: 0))
        returned.type("home ")
        try await returned.settle()
        try expect(returned, "to go home ", "returnToPhraseEnd")

        let clickedBack = Fixture(prefix: "", store: store, local: local)
        clickedBack.type("to go ")
        try await clickedBack.settle()
        clickedBack.session.commitPending()
        clickedBack.view.setSelectedRange(NSRange(location: 0, length: 0))
        clickedBack.session.commitPending()
        clickedBack.view.setSelectedRange(NSRange(location: clickedBack.view.string.utf16.count, length: 0))
        clickedBack.type("home ")
        try await clickedBack.settle()
        try expect(clickedBack, "to go home ", "clickAwayAndBack")

        // Typing at a different location must leave the earlier phrase alone.
        let moved = Fixture(prefix: "", store: store, local: local)
        moved.type("to ")
        try await moved.settle()
        moved.session.commitPending()
        moved.view.setSelectedRange(NSRange(location: 0, length: 0))
        moved.type("home ")
        try await moved.settle()
        try expect(moved, "home 새 ", "typingElsewhereKeepsOldPhrase")

        let deleted = Fixture(prefix: "", store: store, local: local)
        deleted.type("to ")
        try await deleted.settle()
        deleted.key("", code: 51)
        deleted.key("", code: 51)
        deleted.type("home ")
        try await deleted.settle()
        try expect(deleted, "home ", "deleteCommittedWord")

        let rememberedStore = CorrectionStore(url: folder.appendingPathComponent("remembered.json"))
        try rememberedStore.record(raw: "so", before: "", rejected: "so", preferred: "내", scope: .always)
        let remembered = Fixture(prefix: "", store: rememberedStore, local: local)
        remembered.type("so do it now ")
        try await remembered.settle()
        guard remembered.view.string.hasPrefix("내 ") else {
            throw LocalDecisionError(detail: "Automatic correction overrode the user's saved language choice")
        }
        log.append("savedLanguagePreserved")

        // The host must expose the exact original text before an automatic rewrite.
        for opaque in [false, true] {
            let changed = Fixture(prefix: "", store: store, local: local)
            changed.type("to go ")
            try await changed.settle()
            let prefix = opaque ? changed.view.string : "다 해 "
            changed.view.string = prefix
            changed.view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            changed.view.hidesSurroundingText = opaque
            changed.type("home ")
            try await changed.expectError()
            guard changed.view.string.hasPrefix(prefix), !changed.view.string.contains("to go home") else {
                throw LocalDecisionError(detail: "Unsafe replacement changed committed text")
            }
            changed.session.commitRaw()
            log.append(opaque ? "opaqueHostRejected" : "changedTextRejected")
        }
        return log
    }
}
