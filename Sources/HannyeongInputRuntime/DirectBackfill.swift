import Foundation
import HannyeongCore

/// The existing CompositionSession backfill rules, without IMK ranges or host mutations.
enum DirectBackfill {
    struct Reading: Equatable {
        let text: String
        let probabilities: [String: Double]
        var confidence: Double { probabilities[text]! }
    }
    struct Word: Equatable {
        let raw: String
        var separator: String
    }
    enum Language: String, Equatable { case english, korean }
    struct State: Equatable {
        let before: String
        var words: [Word]
        var decided: [String]
        var other: [String]
        var confirming: Language?
        var text: String { zip(decided, words).map { $0 + $1.separator }.joined() }
        var alternateContext: String { String((before + zip(other, words).map { $0 + $1.separator }.joined()).suffix(120)) }
    }
    struct Resolution: Equatable {
        let text: String
        /// Includes the previous owned words and the current word, excluding the pending separator.
        let replacement: String?
        let next: State?
        var confirmedLanguage: Language? = nil
    }

    // Kept identical to CompositionSession.Backfill; model probabilities are not measured accuracy.
    static let hold = 0.9
    static let anchor = 0.95
    static let floor = 0.05
    static let window = 4
    static let englishZipf = 5.5
    static let koreanZipf = 5.0

    static func resolve(word: Word, before: String, previous: State?, decided: Reading,
                        alternate: Reading?, frequencies: WordFrequencies) throws -> Resolution {
        guard let previous else {
            let other = try otherReading(decided, word: word, frequencies: frequencies)
            let next = other.map { State(before: before, words: [word], decided: [decided.text], other: [$0], confirming: nil) }
            return Resolution(text: decided.text, replacement: nil, next: next,
                confirmedLanguage: try stableLanguage(decided, raw: word.raw))
        }
        guard let alternate else { throw DirectFailure(detail: "The previous word has no alternate-context decision.") }
        var recent = previous
        let confirmingLanguage = decided.text == alternate.text && min(decided.confidence, alternate.confidence) >= anchor
            ? try anchorLanguage(decided.text, raw: word.raw) : nil
        var otherText = alternate.text
        if confirmingLanguage == nil, let direction = try language(previous.other[0], raw: previous.words[0].raw),
           try language(otherText, raw: word.raw) != direction,
           let other = try otherReading(alternate, word: word, frequencies: frequencies),
           try language(other, raw: word.raw) == direction {
            otherText = other
        }
        recent.words.append(word)
        recent.decided.append(decided.text)
        recent.other.append(otherText)
        var keep = false, replace = false
        if let confirming = recent.confirming {
            replace = confirmingLanguage == confirming
        } else if let confirmingLanguage {
            let waiting = Array(zip(previous.other, previous.words))
            let agrees = try waiting.allSatisfy { text, word in
                try language(text, raw: word.raw) == confirmingLanguage && text.allSatisfy(readable)
            }
            let left = leftLanguage(previous.before)
            if agrees, left == nil, waiting.count == 1, spaces(word.separator) {
                recent.confirming = confirmingLanguage
                keep = true
            } else {
                replace = agrees && (left == confirmingLanguage || waiting.count >= 2)
            }
        } else {
            keep = spaces(word.separator) && recent.decided.count < window
        }
        let text = replace ? otherText : decided.text
        let replacement = replace ? zip(previous.other, previous.words).map { $0 + $1.separator }.joined() + text : nil
        return Resolution(text: text, replacement: replacement, next: keep ? recent : nil,
            confirmedLanguage: try stableLanguage(replace ? alternate : decided, raw: word.raw))
    }

    private static func stableLanguage(_ result: Reading, raw: String) throws -> Language? {
        guard raw.count >= 3, result.confidence >= anchor else { return nil }
        return try language(result.text, raw: raw)
    }

    private static func otherReading(_ result: Reading, word: Word, frequencies: WordFrequencies) throws -> String? {
        guard spaces(word.separator), let direction = try language(result.text, raw: word.raw) else { return nil }
        let korean = try HangulComposer.compose(word.raw)
        let other = direction == .english ? korean : word.raw
        guard other != result.text, let probability = result.probabilities[other] else { return nil }
        if result.confidence < hold, probability >= floor { return other }
        return (frequencies.english[word.raw.lowercased()] ?? 0) >= englishZipf &&
            (frequencies.korean[korean] ?? 0) >= koreanZipf ? other : nil
    }
    private static func language(_ text: String, raw: String) throws -> Language? {
        text == raw ? .english : text == (try HangulComposer.compose(raw)) ? .korean : nil
    }
    private static func anchorLanguage(_ text: String, raw: String) throws -> Language? {
        if let first = text.first, first.isASCII, first.isLetter { return .english }
        return try language(text, raw: raw)
    }
    private static func spaces(_ text: String) -> Bool { text.allSatisfy { $0 == " " } }
    private static func hangul(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x3163).contains($0.value) }
    }
    private static func readable(_ character: Character) -> Bool {
        character.isASCII || "ㅋㅎㅠㅜㅡ".contains(character) || character.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) }
    }
    private static func leftLanguage(_ text: String) -> Language? {
        let word = text.reversed().drop(while: { $0 == " " })
            .prefix(while: { $0.isASCII ? $0.isLetter : hangul($0) }).reversed()
        guard !word.isEmpty else { return nil }
        return word.contains(where: { !$0.isASCII }) ? .korean : .english
    }
}
