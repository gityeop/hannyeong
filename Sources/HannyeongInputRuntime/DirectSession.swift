import Foundation
import HannyeongCore

public struct DirectFailure: LocalizedError {
    public let detail: String
    public var errorDescription: String? { detail }
}

/// Owns the current word and the bounded, already emitted words eligible for reconsideration.
struct DirectSession {
    struct Snapshot: Equatable {
        let revision: Int
        let raw: String
        let before: String
        var separator: String? = nil
        var recent: DirectBackfill.State? = nil
        var manualText: String? = nil
        var backfillEnabled = true
    }
    struct Projection: Equatable {
        let text: String
        let koreanStart: Int?
        init(text: String, raw: String) throws {
            guard let candidate = try CandidateBuilder.candidates(for: raw, includeSplits: true).first(where: { $0.text == text }) else {
                throw DirectFailure(detail: "The existing model returned an invalid direct-input candidate.")
            }
            self.text = text
            koreanStart = text == raw ? nil : (candidate.splitIndex ?? 0)
        }
    }
    enum Decision: Equatable {
        case live(Projection)
        case boundary(DirectBackfill.Resolution)
    }
    struct Edit: Equatable {
        let deleteCount: Int
        let text: String
        var isEmpty: Bool { deleteCount == 0 && text.isEmpty }
    }
    struct FeedbackTarget: Equatable {
        let revision: Int
        let raw: String
        let before: String
        let text: String
        let separator: String
        var wordID = UUID()
    }

    private(set) var raw = ""
    private(set) var displayed = ""
    private(set) var context = ""
    private(set) var revision = 0
    private var koreanStart: Int?
    private var manualCurrent = false
    private var currentWordID = UUID()
    private var reverseCurrent: (text: String, koreanStart: Int?)?
    private(set) var preferredLanguage: DirectBackfill.Language = .english
    private var languageHistory: [DirectBackfill.Language] = []

    mutating func setInitialLanguage(_ language: DirectBackfill.Language) {
        preferredLanguage = language
        languageHistory.removeAll()
    }

    private mutating func observe(_ language: DirectBackfill.Language?) {
        guard let language else { return }
        languageHistory.append(language)
        languageHistory = Array(languageHistory.suffix(4))
        let korean = languageHistory.filter { $0 == .korean }.count
        let english = languageHistory.count - korean
        if korean > english { preferredLanguage = .korean }
        if english > korean { preferredLanguage = .english }
    }
    private struct CompletedWord {
        let id: UUID
        var revision: Int
        let raw: String
        var text: String
        var separator: String
        var manualText: String?
        var alternate: String?
        var displayed: String { text + separator }
    }
    private struct LastWord {
        let id: UUID
        let raw: String
        var text: String
        var separator: String
        let before: String
        var alternate: String?
    }
    private var completed: [CompletedWord] = []
    private var lastWord: LastWord?
    private(set) var recent: DirectBackfill.State?
    var backfillEnabled = true {
        didSet { if !backfillEnabled { recent = nil } }
    }
    var snapshot: Snapshot {
        if let word = completed.first {
            return Snapshot(revision: word.revision, raw: word.raw, before: context, separator: word.separator, recent: recent, manualText: word.manualText, backfillEnabled: backfillEnabled)
        }
        return Snapshot(revision: revision, raw: raw, before: context, recent: recent, backfillEnabled: backfillEnabled)
    }
    var hasDecision: Bool { !completed.isEmpty || (!raw.isEmpty && !manualCurrent) }

    var feedbackTarget: FeedbackTarget? {
        if !raw.isEmpty {
            return .init(revision: revision, raw: raw,
                         before: String((context + completed.map(\.displayed).joined()).suffix(120)), text: displayed, separator: "", wordID: currentWordID)
        }
        if let word = completed.last {
            return .init(revision: revision, raw: word.raw,
                         before: String((context + completed.dropLast().map(\.displayed).joined()).suffix(120)),
                         text: word.text, separator: word.separator, wordID: word.id)
        }
        if let word = lastWord {
            return .init(revision: revision, raw: word.raw, before: word.before, text: word.text, separator: word.separator, wordID: word.id)
        }
        return nil
    }

    mutating func applyFeedback(_ projection: Projection, for target: FeedbackTarget) -> Edit? {
        guard feedbackTarget == target else { return nil }
        revision += 1
        recent = nil
        if !raw.isEmpty {
            reverseCurrent = (displayed, koreanStart)
            koreanStart = projection.koreanStart
            manualCurrent = true
            return replace(with: projection.text)
        }
        if !completed.isEmpty {
            let index = completed.count - 1
            completed[index].alternate = completed[index].text
            completed[index].text = projection.text
            completed[index].manualText = projection.text
            completed[index].revision = revision
        } else if var word = lastWord {
            word.alternate = word.text
            word.text = projection.text
            lastWord = word
            context = String((word.before + word.text + word.separator).suffix(120))
        }
        return Self.difference(from: target.text + target.separator, to: projection.text + target.separator)
    }

    /// The separator has already reached the host. Only analysis records wait, never keys.
    mutating func beginBoundary(_ separator: String) {
        precondition(!raw.isEmpty)
        revision += 1
        completed.append(CompletedWord(id: currentWordID, revision: revision, raw: raw, text: displayed, separator: separator,
                                      manualText: manualCurrent ? displayed : nil, alternate: reverseCurrent?.text))
        raw = ""
        displayed = ""
        koreanStart = nil
        manualCurrent = false
        reverseCurrent = nil
    }

    mutating func append(_ letters: String) throws -> Edit {
        guard !letters.isEmpty, letters.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || (97...122).contains($0.value) }) else {
            throw DirectFailure(detail: "Direct input received a non-alphabetic word key.")
        }
        if raw.isEmpty {
            currentWordID = UUID()
            koreanStart = preferredLanguage == .korean ? 0 : nil
            manualCurrent = false
        }
        reverseCurrent = nil
        raw += letters
        revision += 1
        return try project()
    }

    mutating func backspace() throws -> Edit {
        guard !raw.isEmpty else { throw DirectFailure(detail: "Direct input has no owned word to delete.") }
        raw.removeLast()
        reverseCurrent = nil
        revision += 1
        if raw.isEmpty { koreanStart = nil }
        return try project()
    }

    /// These keys already reached the host while its field identity is being rechecked.
    mutating func recordPassedLetters(_ letters: String) {
        if raw.isEmpty {
            currentWordID = UUID()
            koreanStart = nil
            manualCurrent = false
        }
        reverseCurrent = nil
        raw += letters
        displayed += letters
        revision += 1
    }

    mutating func accept(_ projection: Projection, for request: Snapshot) -> Edit? {
        guard request.separator == nil, snapshot == request else { return nil }
        koreanStart = projection.koreanStart
        return replace(with: projection.text)
    }

    mutating func restoreRaw() -> Edit { koreanStart = nil; revision += 1; return replace(with: raw) }

    mutating func toggleLanguage() throws -> Edit? {
        revision += 1
        if !raw.isEmpty {
            let previous = (text: displayed, koreanStart: koreanStart)
            let text = try reverseCurrent?.text ?? (displayed == raw ? HangulComposer.compose(raw) : raw)
            koreanStart = reverseCurrent?.koreanStart ?? (text == raw ? nil : 0)
            // An English reverse projection has nil as its valid Korean start.
            if text == raw { koreanStart = nil }
            reverseCurrent = previous
            manualCurrent = true
            return replace(with: text)
        }
        if !completed.isEmpty {
            let index = completed.count - 1
            let previous = completed[index].text
            let text = try completed[index].alternate ?? (previous == completed[index].raw ? HangulComposer.compose(completed[index].raw) : completed[index].raw)
            completed[index].text = text
            completed[index].manualText = text
            completed[index].alternate = previous
            completed[index].revision = revision
            return Self.difference(from: previous + completed[index].separator, to: text + completed[index].separator)
        }
        guard var word = lastWord else { return nil }
        let previous = word.text
        word.text = try word.alternate ?? (word.text == word.raw ? HangulComposer.compose(word.raw) : word.raw)
        word.alternate = previous
        lastWord = word
        context = String((word.before + word.text + word.separator).suffix(120))
        recent = nil
        return Self.difference(from: previous + word.separator, to: word.text + word.separator)
    }

    mutating func finish(_ result: DirectBackfill.Resolution, for request: Snapshot) throws -> Edit? {
        guard snapshot == request else { return nil }
        guard let word = completed.first else { throw DirectFailure(detail: "The boundary decision has no completed word.") }
        let before = (recent?.text ?? "") + completed.map(\.displayed).joined() + displayed
        let suffix = completed.dropFirst().map(\.displayed).joined() + displayed
        let prefix: String
        if let replacement = result.replacement {
            guard let recent else { throw DirectFailure(detail: "The backfill has no owned preceding words.") }
            prefix = replacement
            context = String((recent.before + replacement + word.separator).suffix(120))
        } else {
            prefix = (recent?.text ?? "") + result.text
            context = String((context + result.text + word.separator).suffix(120))
        }
        let edit = Self.difference(from: before, to: prefix + word.separator + suffix)
        completed.removeFirst()
        lastWord = LastWord(id: word.id, raw: word.raw, text: result.text, separator: word.separator,
                            before: String(context.dropLast(result.text.count + word.separator.count)), alternate: word.alternate)
        recent = result.next
        observe(result.confirmedLanguage)
        return edit
    }

    /// Extra spaces must stay in the owned suffix; punctuation ends the reconsideration window.
    mutating func recordSeparator(_ text: String) {
        if !completed.isEmpty {
            completed[completed.count - 1].separator += text
            revision += 1
            return
        }
        context = String((context + text).suffix(120))
        if lastWord != nil { lastWord!.separator += text }
        if text.allSatisfy({ $0 == " " }), var recent {
            recent.words[recent.words.count - 1].separator += text
            self.recent = recent
        } else { recent = nil }
        revision += 1
    }

    mutating func reset() {
        raw = ""
        displayed = ""
        context = ""
        koreanStart = nil
        manualCurrent = false
        reverseCurrent = nil
        completed.removeAll()
        lastWord = nil
        recent = nil
        revision += 1
    }

    private mutating func project() throws -> Edit {
        let text: String
        if let start = koreanStart {
            text = String(raw.prefix(start)) + (try HangulComposer.compose(String(raw.dropFirst(start))))
        } else { text = raw }
        return replace(with: text)
    }

    private mutating func replace(with text: String) -> Edit {
        let edit = Self.difference(from: displayed, to: text)
        displayed = text
        return edit
    }

    private static func difference(from old: String, to new: String) -> Edit {
        let shared = zip(old, new).prefix(while: { $0.0 == $0.1 }).count
        return Edit(deleteCount: old.count - shared, text: String(new.dropFirst(shared)))
    }
}
