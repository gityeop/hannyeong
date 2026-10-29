import AppKit
import InputMethodKit
import HannyeongCore
import os

/// Raw keys stay available until a word is decided and committed in its boundary event.
@MainActor
final class CompositionSession {
    /// How the committed text for a word was chosen.
    enum SelectionSource {
        case automaticOrMemory
        case inlinePreview
        case languageShortcut
        case correction
    }

    private struct Word {
        let id = UUID()
        var raw: String
        var separator: String
    }

    private struct Conversion {
        var id = UUID()
        let raw: String
        let selected: String
        var separator: String
        let before: String
        var range: NSRange
        var languageAlternative: String? = nil
        var source: SelectionSource = .automaticOrMemory
        var text: String { selected + separator }
    }

    private enum Language { case english, korean }

    /// A word's reading with the probability of every candidate reading.
    private struct Decided: Sendable {
        let text: String
        let probabilities: [String: Double]
        var confidence: Double { probabilities[text]! }
    }

    /// Already committed words that can be reconsidered after an unsure Korean/English choice.
    /// `decided` follows the model word by word; `other` starts from the other reading of the first word.
    /// A later confident word (the anchor) picks `other` when it agrees with it; see scripts/backfill-sim.py.
    private struct Reconsideration {
        let before: String
        var words: [Word]
        var decided: [String]
        var other: [String]
        var range: NSRange
        var text: String { zip(decided, words).map { $0 + $1.separator }.joined() }
        /// A sentence-initial single word waits for a second anchor in this language.
        var confirming: Language? = nil
    }

    /// Thresholds measured by scripts/backfill-sim.py (2026-10-20).
    private enum Backfill {
        static let hold = 0.9
        static let anchor = 0.95
        static let floor = 0.05
        static let window = 4
        /// Keep both interpretations when both readings are at least this common (Zipf).
        static let englishZipf = 5.5
        static let koreanZipf = 5.0
    }

    private struct Feedback {
        let conversionID: UUID
        let raw: String
        let before: String
        let rejected: String
        let separator: String
        let range: NSRange
        let expectedText: String
        let source: SelectionSource
    }

    private let client: any IMKTextInput
    private let inlineComposition: InlineComposition
    private let corrections: CorrectionStore
    private let localClient: LocalDecisionClient?
    private let wordFrequencies: WordFrequencies?
    private let previewDefaults: UserDefaults
    private let liveDetectionOverride: Bool?
    private var liveDetectionEnabled: Bool {
        liveDetectionOverride ?? previewDefaults.bool(forKey: CompositionPreviewSettings.liveEnabledKey)
    }
    private let hostBundleID: String?
    private let onPreviewStart: (() -> Void)?
    private let onPreview: ((String?) -> Void)?
    private let onError: (String) -> Void
    private let logger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "Composition")
    private let diagnosticLogger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "CommandDiagnostics")
    let diagnosticID = UUID().uuidString
    private var words: [Word] = []
    private var reconsideration: Reconsideration?
    private var raw = "" {
        didSet {
            if raw != oldValue {
                cancelLivePreview()
                if raw.isEmpty { livePreviewKoreanStart = nil }
            }
        }
    }
    private var livePreviewTask: Task<Void, Never>?
    private var livePreviewText: String?
    /// nil keeps English; 0 composes Korean; a mixed reading retains its English prefix.
    private var livePreviewKoreanStart: Int?
    private let selectCommittedText: (String) async throws -> NSRange
    private let confirmCommittedText: (String) async throws -> Int
    private let forwardHostEvent: (NSEvent) async throws -> Void
    private let usesTerminalKeyReplacement: () async throws -> Bool
    private let nativeTerminalClient: Bool
    private let prepareNativeTerminalEdit: (String) async throws -> NativeTerminalOwnership.Edit
    private var inputGeneration = 0
    private var rewriteTask: Task<Void, Never>?
    private var inlineTask: Task<Void, Never>?
    private var bufferedEvents: [NSEvent] = []
    private var drainingEvents = false
    var hasPendingRewrite: Bool { rewriteTask != nil || inlineTask != nil || drainingEvents }
    private var context = ""
    private var contextSelection: NSRange?
    private var active = true
    private var lastCommit: Conversion?
    private var feedback: Feedback?

    init(client: any IMKTextInput, corrections: CorrectionStore? = nil,
         localClient: LocalDecisionClient? = nil, wordFrequencies: WordFrequencies? = nil,
         previewDefaults: UserDefaults = .standard,
         hostBundleID: String? = nil,
         liveDetectionOverride: Bool? = nil,
         selectCommittedText: ((String) async throws -> NSRange)? = nil,
         confirmCommittedText: ((String) async throws -> Int)? = nil,
         forwardHostEvent: ((NSEvent) async throws -> Void)? = nil,
         usesTerminalKeyReplacement: (() async throws -> Bool)? = nil,
         nativeTerminalClient: Bool? = nil,
         prepareNativeTerminalEdit: ((String) async throws -> NativeTerminalOwnership.Edit)? = nil,
         onPreviewStart: (() -> Void)? = nil,
         onPreview: ((String?) -> Void)? = nil,
         onError: @escaping (String) -> Void) {
        self.client = client
        self.inlineComposition = InlineComposition(client: client)
        self.corrections = corrections ?? CorrectionStore.shared
        self.localClient = localClient
        self.wordFrequencies = wordFrequencies
        self.previewDefaults = previewDefaults
        self.liveDetectionOverride = liveDetectionOverride
        self.hostBundleID = hostBundleID
        self.selectCommittedText = selectCommittedText ?? { expected in
            try await CommittedTextSelection.select(expected, hostBundleID: hostBundleID)
        }
        self.confirmCommittedText = confirmCommittedText ?? { expected in
            try await CommittedTextSelection.confirmedCaret(expectedSuffix: expected, hostBundleID: hostBundleID)
        }
        self.forwardHostEvent = forwardHostEvent ?? { event in
            try await ReplayedInputEvent.forward(event, hostBundleID: hostBundleID)
        }
        self.usesTerminalKeyReplacement = usesTerminalKeyReplacement ?? {
            try await TerminalInputReplacement.applies(hostBundleID: hostBundleID)
        }
        self.nativeTerminalClient = nativeTerminalClient ?? (hostBundleID == "com.apple.Terminal")
        self.prepareNativeTerminalEdit = prepareNativeTerminalEdit ?? NativeTerminalOwnership.prepare
        self.onPreviewStart = onPreviewStart
        self.onPreview = onPreview
        self.onError = onError
        logDiagnostic("session_created")
    }

    func handle(_ event: NSEvent) -> Bool {
        guard active else { return false }
        if hasPendingRewrite {
            bufferedEvents.append(event)
            return true
        }
        return handleNow(event)
    }

    func finishInputEvent() {
        if !hasPendingRewrite { CommittedInputEvents.shared.release(owner: diagnosticID) }
    }

    private func handleNow(_ event: NSEvent) -> Bool {
        if !PriorWordCorrectionSettings.enabled(in: previewDefaults) { reconsideration = nil }
        if event.modifierFlags.intersection([.command, .control]).isEmpty == false,
           !(123...126).contains(event.keyCode) {
            commitHangul()
            return false
        }
        switch event.keyCode {
        case 53: // Escape explicitly chooses the original keys.
            reconsideration = nil
            if !raw.isEmpty || !words.isEmpty { commitRaw(); return true }
            return false
        case 51:
            if event.modifierFlags.contains(.option) { return deleteWord() }
            let handled = backspace()
            if !handled, reconsideration != nil, !drainingEvents {
                // Chromium applies a host deletion after IMK returns. Keep following keys queued
                // until the shortened committed span is visible at the actual caret.
                confirmRecentCommit()
            }
            return handled
        case 36, 76:
            do {
                try commitForReturn()
                if rewriteTask != nil || inlineTask != nil {
                    bufferedEvents.append(event)
                    return true
                }
                lastCommit = nil
                feedback = nil
                trackHostInsertion("\n")
                // The host receives the original Return, including its Shift modifier.
                return false
            } catch {
                report(error)
                return true
            }
        case 48: // Tab ends the composition immediately before host focus navigation.
            commitHangul()
            return false
        case 123...126: // Navigation belongs to the host after ending the current composition.
            commitPending()
            return false
        default: break
        }
        guard let characters = event.characters, !characters.isEmpty else { return false }
        if characters.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || (97...122).contains($0.value) }) {
            if raw.isEmpty && words.isEmpty {
                // Own commits already contain the context, even when the host cannot return it.
                if contextSelection != client.selectedRange() {
                    if let recent = reconsideration, !recentMatchesCaret(recent) { reconsideration = nil }
                    context = precedingText()
                }
                lastCommit = nil
            }
            feedback = nil
            if raw.isEmpty, CompositionPreviewSettings.alternateEnabled(in: previewDefaults) {
                onPreviewStart?()
            }
            raw += characters
            render()
            return true
        }
        // Numbers and punctuation delimit the alphabetic word, and retain their original text.
        if !raw.isEmpty || !words.isEmpty { return boundary(characters) }
        if appendToLastConversion(characters) { return true }
        trackHostInsertion(characters)
        return false
    }

    /// Immediate host commits preserve the Hangul composition shown to the user.
    func commitPending() {
        if inlineTask != nil || rewriteTask != nil { cancelInlineEdit(); return }
        if !rawText.isEmpty { commitHangul() }
    }

    func belongsTo(_ client: any IMKTextInput) -> Bool {
        (self.client as AnyObject) === (client as AnyObject)
    }

    func resume() {
        if !active { inputGeneration += 1 }
        active = true
        logDiagnostic("session_resumed")
    }

    func suspend() {
        inputGeneration += 1
        cancelLivePreviewTask()
        CommittedInputEvents.shared.cancel(owner: diagnosticID)
        if inlineTask != nil || rewriteTask != nil { cancelInlineEdit() } else { commitPending() }
        onPreview?(nil)
        active = false
        feedback = nil
        logDiagnostic("session_suspended")
    }

    func deactivate() {
        inputGeneration += 1
        cancelLivePreviewTask()
        CommittedInputEvents.shared.cancel(owner: diagnosticID)
        if inlineTask != nil || rewriteTask != nil { cancelInlineEdit() } else { commitPending() }
        reconsideration = nil
        onPreview?(nil)
        active = false
        lastCommit = nil
        feedback = nil
        logDiagnostic("session_deactivated")
    }

    func commitRaw() {
        logDiagnostic("commit_raw_before_clear")
        let text = rawText
        words.removeAll()
        reconsideration = nil
        raw = ""
        onPreview?(nil)
        if !text.isEmpty {
            do { try insertPending(text) }
            catch { report(error); return }
        }
        lastCommit = nil
        feedback = nil
        AppSupport.shared.clearError()
    }

    func commitHangul() {
        if lastCommit != nil || !rawText.isEmpty { logDiagnostic("commit_hangul_before_clear") }
        do {
            let text = try previewText()
            words.removeAll()
            reconsideration = nil
            raw = ""
            onPreview?(nil)
            if !text.isEmpty {
                try insertPending(text)
            }
            lastCommit = nil
            feedback = nil
            AppSupport.shared.clearError()
        } catch { report(error) }
    }

    /// Keep the exact model/correction result when reversing a completed word twice.
    func toggleLanguage() {
        logDiagnostic("toggle_begin")
        do {
            if !raw.isEmpty {
                defer { reconsideration = nil }
                try decideQueuedWords()
                let pending = Conversion(raw: raw, selected: try currentPreview(), separator: "", before: context,
                                         range: client.markedRange(), source: .inlinePreview)
                let alternate = try pending.selected == pending.raw ? HangulComposer.compose(pending.raw) : pending.raw
                words.append(Word(raw: pending.raw, separator: ""))
                raw = ""
                // Replace the owned marked text before sending anything to the terminal's PTY.
                try commitWords([alternate], source: .languageShortcut)
                lastCommit?.languageAlternative = pending.selected
                logDiagnostic("toggle_complete")
                return
            }
            try finishPendingForShortcut(preservePreview: true)
            guard let previous = lastCommit else {
                logDiagnostic("toggle_no_recent_conversion")
                return
            }
            logDiagnostic("toggle_target_ready")
            try validateFeedback(Feedback(conversionID: previous.id, raw: previous.raw, before: previous.before,
                                          rejected: previous.selected, separator: previous.separator,
                                          range: previous.range, expectedText: previous.text, source: previous.source))
            let alternate = try previous.languageAlternative ??
                (previous.selected == previous.raw ? HangulComposer.compose(previous.raw) : previous.raw)
            let conversion = Conversion(id: previous.id, raw: previous.raw, selected: alternate, separator: previous.separator,
                                        before: previous.before,
                                        range: NSRange(location: previous.range.location,
                                                       length: (alternate + previous.separator).utf16.count),
                                        languageAlternative: previous.selected, source: .languageShortcut)
            client.insertText(conversion.text, replacementRange: previous.range)
            context = String((conversion.before + conversion.text).suffix(120))
            contextSelection = client.selectedRange()
            lastCommit = conversion
            feedback = nil
            AppSupport.shared.clearError()
            logDiagnostic("toggle_complete")
        } catch {
            logFailure(error, stage: "toggle_failed")
            let failure = error as NSError
            logger.error("Language toggle failed: \(failure.domain, privacy: .public) code \(failure.code)")
            onError("방금 입력한 단어를 바꾸지 못했습니다. 입력 위치를 확인해 주세요.")
        }
    }

    func completeForCorrection() throws {
        logDiagnostic("correction_prepare_begin")
        try finishPendingForShortcut(preservePreview: false)
    }

    private func finishPendingForShortcut(preservePreview: Bool) throws {
        defer { reconsideration = nil }
        guard !rawText.isEmpty else { return }
        // Earlier queued words retain their model decisions even during rapid typing.
        try decideQueuedWords()
        if !raw.isEmpty {
            let keys = raw
            let displayed = try currentPreview()
            words.append(Word(raw: keys, separator: ""))
            raw = ""
            if !inlineComposition.isActive { render() }
            let selected = try preservePreview ? displayed :
                ReturnDecision.resolve(decision(for: keys, before: context)).text
            try commitWords([selected], source: preservePreview ? .inlinePreview : .automaticOrMemory)
        }
    }

    /// Decides and commits every queued word in order.
    private func decideQueuedWords() throws {
        while rewriteTask == nil, inlineTask == nil, let next = try nextRequests() {
            try advance(next.requests.map { try ReturnDecision.resolve($0) })
        }
    }

    /// Explicit language keys can also change the word immediately before the caret.
    /// Host navigation and session shutdown continue to commit only pending composition.
    private var rawText: String {
        words.map { $0.raw + $0.separator }.joined() + raw
    }

    private func preview(_ keys: String) throws -> String {
        if liveDetectionEnabled { return keys }
        return CompositionPreviewSettings.english(for: hostBundleID, in: previewDefaults)
            ? keys : try HangulComposer.compose(keys)
    }

    private func previewText() throws -> String {
        return try words.map { word in
            (word.raw.isEmpty ? "" : try preview(word.raw)) + word.separator
        }.joined() + (raw.isEmpty ? "" : try currentPreview())
    }

    private func currentPreview() throws -> String {
        if liveDetectionEnabled {
            if let livePreviewText { return livePreviewText }
            if let start = livePreviewKoreanStart {
                return String(raw.prefix(start)) + (try HangulComposer.compose(String(raw.dropFirst(start))))
            }
            return raw
        }
        return try preview(raw)
    }

    private func cancelLivePreviewTask() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
    }

    private func cancelLivePreview() {
        cancelLivePreviewTask()
        livePreviewText = nil
    }

    private func requestLivePreview() {
        guard active, liveDetectionEnabled,
              inlineTask == nil, !raw.isEmpty, livePreviewTask == nil, livePreviewText == nil else { return }
        let keys = raw, before = context
        livePreviewTask = Task { @MainActor [weak self] in
            do {
                // Coalesce rapid keystrokes; typing itself never waits for the model.
                try await Task.sleep(for: .milliseconds(80))
                guard let self else { return }
                let result = try await self.decision(for: keys, before: before)()
                guard !Task.isCancelled, self.active, self.raw == keys,
                      self.liveDetectionEnabled else { return }
                guard let reading = try CandidateBuilder.candidates(for: keys, includeSplits: true)
                    .first(where: { $0.text == result.text }) else {
                    throw SessionError("The live decision is not a valid candidate.")
                }
                self.livePreviewKoreanStart = result.text == keys ? nil : (reading.splitIndex ?? 0)
                self.livePreviewText = result.text
                self.render()
            } catch is CancellationError {
                // A newer key or a completed composition owns the display now.
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.report(error)
            }
        }
    }

    private func render(replacementRange: NSRange = NSRange(location: NSNotFound, length: 0)) {
        guard inlineTask == nil else { return }
        do {
            // A paragraph break is committed separately; marking it can replace a host paragraph.
            let text = try previewText().replacingOccurrences(of: "\n", with: "")
            if liveDetectionEnabled || inlineComposition.isActive {
                try updateInline(text, committing: false)
            } else {
                client.setMarkedText(text,
                                     selectionRange: NSRange(location: text.utf16.count, length: 0),
                                     replacementRange: replacementRange)
            }
            if let onPreview {
                // Only the word still being typed belongs in the alternate preview.
                let alternate = raw.isEmpty || !CompositionPreviewSettings.alternateEnabled(in: previewDefaults) ? nil :
                    (try currentPreview() == raw ? HangulComposer.compose(raw) : raw)
                onPreview(alternate)
            }
            requestLivePreview()
        } catch is CancellationError {
        } catch { report(error) }
    }

    private func boundary(_ separator: String) -> Bool {
        guard !raw.isEmpty || !words.isEmpty else { return false }
        do { try pauseInput() }
        catch { report(error); return true }
        feedback = nil
        if raw.isEmpty {
            words[words.count - 1].separator += separator
        } else {
            words.append(Word(raw: raw, separator: separator))
            raw = ""
        }
        beginRequest()
        return true
    }

    private func commitForReturn() throws {
        if !raw.isEmpty {
            words.append(Word(raw: raw, separator: ""))
            raw = ""
            if !inlineComposition.isActive { render() }
        }
        try decideQueuedWords()
        reconsideration = nil
    }

    private func appendToLastConversion(_ suffix: String) -> Bool {
        guard var commit = lastCommit else { return false }
        guard commit.range.location != NSNotFound,
              client.selectedRange() == NSRange(location: commit.range.location + commit.range.length, length: 0) else {
            reconsideration = nil
            lastCommit = nil
            return false
        }
        client.insertText(suffix, replacementRange: NSRange(location: NSNotFound, length: 0))
        commit.separator += suffix
        commit.range.length += suffix.utf16.count
        lastCommit = commit
        if Self.spaces(suffix), var recent = reconsideration {
            recent.words[recent.words.count - 1].separator += suffix
            recent.range.length += suffix.utf16.count
            reconsideration = recent
        } else {
            reconsideration = nil
        }
        context = String((commit.before + commit.text).suffix(120))
        contextSelection = client.selectedRange()
        feedback = nil
        return true
    }

    private func trackHostInsertion(_ text: String) {
        reconsideration = nil
        let caret = client.selectedRange()
        if contextSelection == caret, caret.length == 0, caret.location != NSNotFound {
            context = String((context + text).suffix(120))
            contextSelection = NSRange(location: caret.location + text.utf16.count, length: 0)
        }
    }

    private func backspace() -> Bool {
        if !raw.isEmpty {
            feedback = nil
            raw.removeLast()
            let text: String
            do { text = try previewText() }
            catch { report(error); return true }
            if nativeTerminalClient {
                render()
                return true
            }
            if inlineComposition.isActive, inlineComposition.requiresReplacement(text) {
                // Chromium also applies the original Backspace when no composition
                // is active. Let that host edit complete, then compose the remaining keys.
                do { try pauseInput() }
                catch { report(error); return true }
                let remaining = String(inlineComposition.finishMarked().dropLast())
                inlineComposition.adoptCommitted(remaining)
                let generation = inputGeneration
                inlineTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try self.checkInput(generation)
                        let terminal = try await self.usesTerminalKeyReplacement()
                        try self.checkInput(generation)
                        guard !terminal else { throw SessionError("Terminal deletion has no host completion acknowledgement.") }
                        _ = try await self.confirmCommittedText(remaining)
                        try self.checkInput(generation)
                        self.inlineTask = nil
                        self.render()
                        await self.drainBufferedEvents()
                    } catch {
                        self.failAutomaticEdit(error, generation: generation)
                    }
                }
                return false
            }
            render()
            return true
        }
        if let word = words.last {
            if !word.separator.isEmpty {
                words[words.count - 1].separator.removeLast()
                render()
                return true
            }
            words.removeLast()
            raw = word.raw
            raw.removeLast()
            render()
            beginRequest()
            return true
        }
        if nativeTerminalClient {
            reconsideration = nil
            lastCommit = nil
            contextSelection = nil
            return false
        }
        if var recent = reconsideration, var commit = lastCommit,
           recent.words.last?.separator.last == " ", commit.separator.last == " ",
           recentMatchesCaret(recent) {
            recent.words[recent.words.count - 1].separator.removeLast()
            recent.range.length -= 1
            commit.separator.removeLast()
            commit.range.length -= 1
            reconsideration = recent
            lastCommit = commit
            context = String((commit.before + commit.text).suffix(120))
            contextSelection = NSRange(location: NSMaxRange(recent.range), length: 0)
        } else {
            reconsideration = nil
            lastCommit = nil
            if contextSelection == client.selectedRange(), let last = context.last {
                context.removeLast()
                let caret = client.selectedRange()
                contextSelection = NSRange(location: max(0, caret.location - String(last).utf16.count), length: 0)
            }
        }
        feedback = nil
        return false
    }

    private func deleteWord() -> Bool {
        lastCommit = nil
        feedback = nil
        if !raw.isEmpty {
            raw = ""
            if inlineComposition.isActive {
                _ = inlineComposition.finishMarked()
                inlineComposition.adoptCommitted("")
                return false
            }
            render()
            return true
        }
        guard !words.isEmpty else {
            reconsideration = nil
            return false
        }
        while let word = words.popLast() {
            if !word.raw.isEmpty { break }
        }
        render()
        beginRequest()
        return true
    }

    var feedbackAvailable: Bool {
        active && !hasPendingRewrite && words.isEmpty && raw.isEmpty && lastCommit != nil
    }

    func prepareFeedback() throws -> [Candidate] {
        guard feedbackAvailable else {
            logDiagnostic("correction_not_available")
            throw SessionError("No completed word is available for correction.")
        }
        let target: Feedback
        if let commit = lastCommit {
            target = Feedback(conversionID: commit.id, raw: commit.raw, before: commit.before, rejected: commit.selected,
                              separator: commit.separator, range: commit.range, expectedText: commit.text, source: commit.source)
        } else {
            throw SessionError("The last conversion is no longer available.")
        }
        try validateFeedback(target)
        let candidates = try CandidateBuilder.candidates(for: target.raw, includeSplits: true)
        feedback = target
        return candidates
    }

    func cancelFeedback() {
        feedback = nil
    }

    func feedbackDisplayText(for candidate: Candidate) throws -> String {
        guard let feedback else {
            throw SessionError("No correction is being selected.")
        }
        return candidate.text + feedback.separator
    }

    func applyFeedback(preferred: String, scope: CorrectionScope) async throws {
        guard let target = feedback else {
            throw SessionError("No correction is being selected.")
        }
        try validateFeedback(target)
        try corrections.record(raw: target.raw, before: target.before, rejected: target.rejected,
                               preferred: preferred, scope: scope)
        let text = preferred + target.separator
        words.removeAll()
        reconsideration = nil
        raw = ""
        onPreview?(nil)
        client.insertText(text, replacementRange: target.range)
        context = String((target.before + text).suffix(120))
        lastCommit = Conversion(id: target.conversionID, raw: target.raw, selected: preferred, separator: target.separator,
                                before: target.before,
                                range: NSRange(location: target.range.location, length: text.utf16.count), source: .correction)
        contextSelection = client.selectedRange()
        feedback = nil
        AppSupport.shared.clearError()
        logger.notice("User correction saved")
        let candidates = try CandidateBuilder.candidates(for: target.raw, includeSplits: true)
        let local = try localClient ?? LocalModelService.client()
        _ = try await local.correct(raw: target.raw, before: target.before,
                                    candidates: candidates, preferred: preferred, scope: scope)
    }

    private func validateFeedback(_ target: Feedback) throws {
        let selection = client.selectedRange()
        guard active, words.isEmpty, target.range.location != NSNotFound,
              selection == NSRange(location: target.range.location + target.range.length, length: 0) else {
            let reason = !active ? "session_inactive" : !words.isEmpty ? "pending_words" :
                target.range.location == NSNotFound ? "target_range_missing" : "caret_mismatch"
            diagnosticLogger.error("Validation rejected; session=\(self.diagnosticID, privacy: .public) reason=\(reason, privacy: .public) target=\(NSStringFromRange(target.range), privacy: .public) selection=\(NSStringFromRange(selection), privacy: .public)")
            throw SessionError("The cursor moved away from the conversion.")
        }
        var actualRange = NSRange(location: NSNotFound, length: 0)
        let hostText = client.string(from: target.range, actualRange: &actualRange)
        guard let text = hostText,
              actualRange == target.range, text == target.expectedText else {
            let reason = hostText == nil ? "host_text_unavailable" :
                actualRange != target.range ? "host_range_mismatch" : "host_text_mismatch"
            diagnosticLogger.error("Validation rejected; session=\(self.diagnosticID, privacy: .public) reason=\(reason, privacy: .public) target=\(NSStringFromRange(target.range), privacy: .public) returnedRange=\(NSStringFromRange(actualRange), privacy: .public) returnedUTF16=\(hostText?.utf16.count ?? -1) expectedUTF16=\(target.expectedText.utf16.count) textMatches=\(hostText == target.expectedText)")
            throw SessionError("The converted text changed before correction.")
        }
    }

    private func beginRequest() {
        guard active else { return }
        // Finish IMK updates before the host delivers the next key, as on Return.
        do { try decideQueuedWords() }
        catch { report(error) }
    }

    private func decision(for raw: String, before: String) throws -> (@Sendable () async throws -> Decided) {
        guard !raw.isEmpty else { return { Decided(text: "", probabilities: ["": 1]) } }
        let candidates = try CandidateBuilder.candidates(for: raw, includeSplits: true)
        let memory = try corrections.load()
        if let preferred = memory.preferred(raw: raw, before: before) {
            let rememberedCandidates = try CandidateBuilder.candidates(for: raw, includeSplits: true)
            guard rememberedCandidates.contains(where: { $0.text == preferred }) else {
                throw SessionError("The saved correction is not a valid candidate.")
            }
            return { Decided(text: preferred, probabilities: [preferred: 1]) }
        }
        let local = try localClient ?? LocalModelService.client()
        return {
            let result = try await local.decide(raw: raw, before: before, candidates: candidates)
            return Decided(text: result.predicted, probabilities: Dictionary(uniqueKeysWithValues:
                candidates.map { ($0.text, result.probabilities[$0.id]!) }))
        }
    }

    private var nextWord: Word? { words.first }

    /// The decisions the next word needs: one, or one per interpretation of the recent commits.
    private func nextRequests() throws -> (word: Word, requests: [@Sendable () async throws -> Decided])? {
        guard let word = nextWord else { return nil }
        if !PriorWordCorrectionSettings.enabled(in: previewDefaults) { reconsideration = nil }
        guard let recent = reconsideration else { return (word, [try decision(for: word.raw, before: context)]) }
        return (word, try [recent.decided, recent.other].map { chain in
            try decision(for: word.raw, before: String((recent.before + zip(chain, recent.words).map { $0 + $1.separator }.joined()).suffix(120)))
        })
    }

    /// Commits each word immediately; only internal records wait for a confident following word.
    private func advance(_ results: [Decided]) throws {
        guard let previous = reconsideration else {
            let word = words[0], result = results[0]
            let other = try otherReading(of: result, for: word), before = context
            try commitWords([result.text])
            guard active else { return }
            if let other, let commit = lastCommit {
                reconsideration = Reconsideration(before: before, words: [word], decided: [result.text],
                                                   other: [other], range: commit.range)
            }
            return
        }
        var recent = previous
        let word = words[0]
        let (decided, other) = (results[0], results[1])
        let anchor = decided.text == other.text && min(decided.confidence, other.confidence) >= Backfill.anchor
            ? try anchorLanguage(of: decided.text, raw: word.raw) : nil
        var otherText = other.text
        // A Korean prefix can bias both chains toward Korean. Keep an unsure next
        // word in the alternate chain's language until a confident anchor resolves it.
        if anchor == nil, let direction = try language(of: previous.other[0], raw: previous.words[0].raw),
           try language(of: otherText, raw: word.raw) != direction,
           let alternate = try otherReading(of: other, for: word),
           try language(of: alternate, raw: word.raw) == direction {
            otherText = alternate
        }
        recent.words.append(word)
        recent.decided.append(decided.text)
        recent.other.append(otherText)
        var keep = false
        var replace = false
        if let confirming = recent.confirming {
            replace = anchor == confirming
        } else if let anchor {
            let waiting = Array(zip(previous.other, previous.words))
            let agrees = try waiting.allSatisfy { text, word in
                try language(of: text, raw: word.raw) == anchor && text.allSatisfy(Self.readable)
            }
            let left = leftLanguage(in: previous.before)
            if agrees, left == nil, waiting.count == 1, Self.spaces(word.separator) {
                recent.confirming = anchor
                keep = true
            } else {
                replace = agrees && (left == anchor || waiting.count >= 2)
            }
        } else {
            keep = Self.spaces(word.separator) && recent.decided.count < Backfill.window
        }
        try commitWords(replace ? recent.other : [decided.text], replacing: replace ? previous : nil)
        reconsideration = nil
        if keep, let commit = lastCommit, commit.range.location != NSNotFound {
            let length = recent.text.utf16.count, end = commit.range.location + commit.range.length
            if end >= length {
                recent.range = NSRange(location: end - length, length: length)
                reconsideration = recent
            }
        }
    }

    /// The other pure-language reading when the model was unsure between it and its choice,
    /// or when both readings are common words (so/내, go/해).
    private func otherReading(of result: Decided, for word: Word) throws -> String? {
        guard PriorWordCorrectionSettings.enabled(in: previewDefaults),
              Self.spaces(word.separator), let language = try language(of: result.text, raw: word.raw) else { return nil }
        let korean = try HangulComposer.compose(word.raw)
        let other = language == .english ? korean : word.raw
        guard other != result.text, let probability = result.probabilities[other] else { return nil }
        if result.confidence < Backfill.hold, probability >= Backfill.floor { return other }
        let frequencies = try wordFrequencies ?? LocalModelService.wordFrequencies()
        return (frequencies.english[word.raw.lowercased()] ?? 0) >= Backfill.englishZipf &&
            (frequencies.korean[korean] ?? 0) >= Backfill.koreanZipf ? other : nil
    }

    private func language(of text: String, raw: String) throws -> Language? {
        text == raw ? .english : text == (try HangulComposer.compose(raw)) ? .korean : nil
    }

    /// Mixed candidates have an English prefix; home을 provides English evidence for preceding words.
    private func anchorLanguage(of text: String, raw: String) throws -> Language? {
        if let first = text.first, first.isASCII, first.isLetter { return .english }
        return try language(of: text, raw: raw)
    }

    private func recentMatchesCaret(_ recent: Reconsideration) -> Bool {
        guard client.selectedRange() == NSRange(location: recent.range.location + recent.range.length, length: 0) else {
            return false
        }
        var actual = NSRange(location: NSNotFound, length: 0)
        return client.string(from: recent.range, actualRange: &actual) == recent.text && actual == recent.range
    }

    /// Language of the committed word right before the caret when only spaces follow it.
    private func leftLanguage(in text: String) -> Language? {
        let word = text.reversed().drop(while: { $0 == " " })
            .prefix(while: { $0.isASCII ? $0.isLetter : Self.hangul($0) }).reversed()
        guard !word.isEmpty else { return nil }
        return word.contains(where: { !$0.isASCII }) ? .korean : .english
    }

    private static func spaces(_ separator: String) -> Bool { separator.allSatisfy { $0 == " " } }

    private static func hangul(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x3163).contains($0.value) }
    }

    /// Korean readings switched in by an anchor must be syllables or emoticon jamo, not jamo runs like ㅞㅡ.
    private static func readable(_ character: Character) -> Bool {
        character.isASCII || "ㅋㅎㅠㅜㅡ".contains(character) ||
            character.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// Commits queued words and any revised preceding words; right Command targets the last word.
    private func commitWords(_ selected: [String], source: SelectionSource = .automaticOrMemory,
                             replacing recent: Reconsideration? = nil) throws {
        if let recent {
            try pauseInput()
            let count = recent.words.count
            let current = Array(selected.dropFirst(count))
            let currentWords = Array(words.prefix(current.count))
            let committedText = zip(current, currentWords).map { $0 + $1.separator }.joined()
            let allWords = recent.words + currentWords
            let replacement = zip(selected, allWords).map { $0 + $1.separator }.joined()
            let expected = recent.text + committedText
            try commitWords(current, source: source)
            guard let anchor = lastCommit else { throw SessionError("The anchor has no committed edit target.") }
            let generation = inputGeneration
            rewriteTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.inlineTask?.value
                do {
                    try Task.checkCancellation()
                    guard self.active, self.inputGeneration == generation else { throw CancellationError() }
                    let terminal = try await self.usesTerminalKeyReplacement()
                    try self.checkInput(generation)
                    let target: NSRange
                    let payload: String
                    let nativeEdit: NativeTerminalOwnership.Edit?
                    if self.nativeTerminalClient {
                        nativeEdit = try await self.prepareNativeTerminalEdit(expected)
                        target = NSRange(location: NSNotFound, length: 0)
                        payload = String(repeating: "\u{7f}", count: expected.count) + replacement
                    } else {
                        guard !terminal else { throw SessionError("Terminal edits have no host completion acknowledgement.") }
                        nativeEdit = nil
                        target = try await self.selectCommittedText(expected)
                        payload = replacement
                    }
                    try Task.checkCancellation()
                    guard self.active, self.inputGeneration == generation else { throw CancellationError() }
                    self.client.insertText(payload, replacementRange: NSRange(location: NSNotFound, length: 0))
                    try self.checkInput(generation)
                    if let nativeEdit {
                        try await nativeEdit.confirm(replacement)
                        try self.checkInput(generation)
                    }
                    self.context = String((recent.before + replacement).suffix(120))
                    self.contextSelection = self.client.selectedRange()
                    let last = currentWords.last!
                    self.lastCommit = Conversion(id: anchor.id, raw: last.raw, selected: current.last!, separator: last.separator,
                        before: String((recent.before + zip(selected.dropLast(), allWords.dropLast()).map { $0 + $1.separator }.joined()).suffix(120)),
                        range: target.location == NSNotFound ? target : NSRange(location: target.location + replacement.utf16.count - anchor.text.utf16.count, length: anchor.text.utf16.count), source: source)
                    if !terminal {
                        let confirmedEnd = try await self.confirmCommittedText(self.lastCommit!.text)
                        try self.checkInput(generation)
                        guard confirmedEnd == target.location + replacement.utf16.count else {
                            throw SessionError("Committed rewrite ended at a different position.")
                        }
                    }
                    self.contextSelection = self.client.selectedRange()
                    // IMK and AX use different paragraph offsets. Keep IMK edit records in IMK coordinates.
                    if let caret = self.contextSelection, caret.location != NSNotFound, caret.length == 0,
                       caret.location >= anchor.text.utf16.count {
                        self.lastCommit?.range = NSRange(location: caret.location - anchor.text.utf16.count,
                                                        length: anchor.text.utf16.count)
                    }
                    AppSupport.shared.clearError()
                } catch {
                    self.failAutomaticEdit(error, generation: generation)
                    return
                }
                guard self.active, self.inputGeneration == generation else { return }
                self.rewriteTask = nil
                await self.drainBufferedEvents()
            }
            return
        }
        let count = selected.count
        let committed = Array(words.prefix(count))
        let preceding = context
        let texts = zip(selected, committed).map { $0 + $1.separator }
        let text = texts.joined(), last = texts[texts.count - 1], word = committed[committed.count - 1]
        // Popup and IMK calls can synchronously suspend this session. Consume the
        // queued words first so suspension cannot commit or remove them a second time.
        words.removeFirst(count)
        onPreview?(nil)
        let terminalMarkedRange = hostBundleID == "com.apple.Terminal" ? client.markedRange() : nil
        try insertPending(text)
        let before = String((preceding + texts.dropLast().joined()).suffix(120))
        context = String((preceding + text).suffix(120))
        let selection = client.selectedRange()
        contextSelection = selection
        feedback = nil
        var committedRange = NSRange(location: NSNotFound, length: 0)
        if let marked = terminalMarkedRange {
            // Terminal reports the former marked start after insertText, before its PTY has echoed the commit.
            if marked.location != NSNotFound {
                committedRange = NSRange(location: marked.location + text.utf16.count - last.utf16.count,
                                         length: last.utf16.count)
            }
        } else if selection.location != NSNotFound, selection.length == 0,
           selection.location >= last.utf16.count {
            // The host may rebase its text storage while ending marked composition.
            committedRange = NSRange(location: selection.location - last.utf16.count, length: last.utf16.count)
        }
        lastCommit = Conversion(id: word.id, raw: word.raw, selected: selected.last!, separator: word.separator,
                                before: before, range: committedRange, source: source)
        if committedRange.location == NSNotFound {
            logDiagnostic("commit_complete_without_edit_target")
        }
        if !rawText.isEmpty { render() }
        AppSupport.shared.clearError()
    }

    private func insertPending(_ text: String) throws {
        if inlineComposition.isActive {
            try updateInline(text, committing: true)
        } else {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func updateInline(_ text: String, committing: Bool) throws {
        if !nativeTerminalClient, !inlineComposition.requiresReplacement(text, committing: committing) {
            if committing { inlineComposition.commit(text) } else { inlineComposition.render(text) }
            return
        }
        try pauseInput()
        let generation = inputGeneration
        inlineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.checkInput(generation)
                if self.nativeTerminalClient {
                    let expected = self.inlineComposition.committedText
                    let edit = try await self.prepareNativeTerminalEdit(expected)
                    try self.checkInput(generation)
                    let shared = self.inlineComposition.sharedCommittedPrefix(with: text, committing: true)
                    let payload = String(repeating: "\u{7f}", count: expected.count - shared.count)
                        + String(text.dropFirst(shared.count))
                    // This is the first and only host mutation. A failed confirmation never resends it.
                    if !payload.isEmpty {
                        self.client.insertText(payload, replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    try self.checkInput(generation)
                    try await edit.confirm(text)
                    try self.checkInput(generation)
                    self.inlineComposition.adoptCommitted(committing ? "" : text)
                } else {
                    let terminal = try await self.usesTerminalKeyReplacement()
                    try self.checkInput(generation)
                    guard !terminal else {
                        throw SessionError("Terminal edits have no host completion acknowledgement.")
                    }
                    // Capability must be established before even committing the last marked character.
                    let expected = self.inlineComposition.finishMarked()
                    try self.checkInput(generation)
                    _ = try await self.selectCommittedText(expected)
                    try self.checkInput(generation)
                    self.inlineComposition.replaceSelected(text, previous: expected, committing: committing)
                    try self.checkInput(generation)
                }
                AppSupport.shared.clearError()
            } catch {
                self.failAutomaticEdit(error, generation: generation)
                return
            }
            guard self.active, self.inputGeneration == generation else { return }
            self.inlineTask = nil
            if self.rewriteTask == nil {
                // Do not schedule another identical native append merely to refresh the model request.
                self.beginRequest()
                self.requestLivePreview()
                await self.drainBufferedEvents()
            }
        }
    }

    private func checkInput(_ generation: Int) throws {
        try Task.checkCancellation()
        guard active, inputGeneration == generation else { throw CancellationError() }
    }

    private func failAutomaticEdit(_ error: Error, generation: Int) {
        guard inputGeneration == generation else { return }
        cancelInlineEdit()
        active = false
        onPreview?(nil)
        if !(error is CancellationError) { report(error, committedEdit: true) }
    }

    private func cancelInlineEdit() {
        inputGeneration += 1
        cancelLivePreview()
        inlineTask?.cancel()
        rewriteTask?.cancel()
        inlineTask = nil
        rewriteTask = nil
        bufferedEvents.removeAll()
        drainingEvents = false
        CommittedInputEvents.shared.cancel(owner: diagnosticID)
        raw = ""
        words.removeAll()
        reconsideration = nil
        lastCommit = nil
        context = ""
        contextSelection = nil
        feedback = nil
        inlineComposition.adoptCommitted("")
    }

    private func confirmRecentCommit() {
        guard let commit = lastCommit else { return }
        do { try pauseInput() }
        catch {
            reconsideration = nil
            report(error)
            CommittedInputEvents.shared.cancel(owner: diagnosticID)
            return
        }
        let expected = commit.text
        let generation = inputGeneration
        rewriteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.checkInput(generation)
                let end = try await self.confirmCommittedText(expected)
                try self.checkInput(generation)
                self.lastCommit?.range = NSRange(location: end - commit.text.utf16.count, length: commit.text.utf16.count)
                if let recent = self.reconsideration {
                    self.reconsideration?.range = NSRange(location: end - recent.text.utf16.count, length: recent.text.utf16.count)
                }
                self.contextSelection = self.client.selectedRange()
            } catch {
                self.failAutomaticEdit(error, generation: generation)
                return
            }
            self.rewriteTask = nil
            await self.drainBufferedEvents()
        }
    }

    private func drainBufferedEvents() async {
        let generation = inputGeneration
        drainingEvents = true
        defer {
            if inputGeneration == generation {
                drainingEvents = false
                if rewriteTask == nil, inlineTask == nil, bufferedEvents.isEmpty {
                    CommittedInputEvents.shared.release(owner: diagnosticID)
                }
            }
        }
        guard active else { bufferedEvents.removeAll(); return }
        while active, inputGeneration == generation, rewriteTask == nil, inlineTask == nil, !bufferedEvents.isEmpty {
            let event = bufferedEvents.removeFirst()
            if !handleNow(event) {
                do {
                    try await forwardHostEvent(event)
                    try checkInput(generation)
                    if event.keyCode == 51, reconsideration != nil {
                        confirmRecentCommit()
                        return
                    }
                }
                catch { failAutomaticEdit(error, generation: generation); return }
            }
        }
    }

    private func pauseInput() throws {
        guard (PriorWordCorrectionSettings.enabled(in: previewDefaults) || liveDetectionEnabled),
              let hostBundleID, CommittedTextSelection.isTrusted else { return }
        try CommittedInputEvents.shared.pause(owner: diagnosticID, hostBundleID: hostBundleID)
    }

    private func precedingText() -> String {
        let selected = client.selectedRange()
        let marked = client.markedRange()
        let end = marked.location == NSNotFound ? selected.location : marked.location
        guard end != NSNotFound, end > 0 else { return "" }
        let range = NSRange(location: max(0, end - 120), length: min(120, end))
        var actualRange = NSRange(location: NSNotFound, length: 0)
        let text = client.string(from: range, actualRange: &actualRange)
        return text?.precomposedStringWithCanonicalMapping ?? ""
    }


    private func report(_ error: Error, committedEdit: Bool = false) {
        onPreview?(nil)
        let isCommittedEdit = committedEdit || error is CommittedTextSelection.Failure
        logFailure(error, stage: isCommittedEdit ? "committed_edit_failed" : "composition_failed")
        // Log status/type without sending private typed text or response bodies to diagnostics.
        let failure = error as NSError
        logger.error("Composition failed: \(failure.domain, privacy: .public) code \(failure.code)")
        if let failure = error as? CommittedTextSelection.Failure {
            diagnosticLogger.error("Committed selection failed: \(failure.localizedDescription, privacy: .public)")
        }
        if case CommittedTextSelection.Failure.permissionRequired = error {
            onError(error.localizedDescription)
        } else if isCommittedEdit {
            onError("자동 교정을 중단했습니다. 입력한 내용과 커서 위치를 확인해 주세요.")
        } else {
            onError("판별하지 못했습니다. Space로 다시 시도하거나 Esc로 원문을 확정하세요.")
        }
    }

    // Metadata only: never include raw input, converted text, context, or correction candidates.
    func logDiagnostic(_ stage: String) {
        let selection = client.selectedRange()
        let marked = client.markedRange()
        diagnosticLogger.notice("Session state; session=\(self.diagnosticID, privacy: .public) stage=\(stage, privacy: .public) active=\(self.active) queued=\(self.words.count) rawUTF16=\(self.raw.utf16.count) recent=\(self.lastCommit != nil) selection=\(NSStringFromRange(selection), privacy: .public) marked=\(NSStringFromRange(marked), privacy: .public) recentRange=\(String(describing: self.lastCommit?.range), privacy: .public)")
    }

    func logFailure(_ error: Error, stage: String) {
        // SessionError details are fixed strings in this file; other error payloads stay private.
        if let failure = error as? SessionError {
            diagnosticLogger.error("Session failure; session=\(self.diagnosticID, privacy: .public) stage=\(stage, privacy: .public) detail=\(failure.detail, privacy: .public)")
        } else {
            let failure = error as NSError
            diagnosticLogger.error("Session failure; session=\(self.diagnosticID, privacy: .public) stage=\(stage, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code) detail=\(error.localizedDescription, privacy: .private)")
        }
        logDiagnostic(stage)
    }
}

private final class ReturnDecision<Value: Sendable>: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    static func resolve(_ select: @escaping @Sendable () async throws -> Value) throws -> Value {
        let completion = ReturnDecision()
        // IMK's synchronous event handler must finish commitment before returning false.
        Task.detached(priority: .userInitiated) {
            do { completion.result = .success(try await select()) }
            catch { completion.result = .failure(error) }
            completion.ready.signal()
        }
        let started = DispatchTime.now()
        completion.ready.wait()
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        if milliseconds > 300 {
            Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "Shortcuts")
                .notice("Return decision blocked main thread; ms=\(milliseconds)")
        }
        return try completion.result!.get()
    }
}

private struct SessionError: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}
