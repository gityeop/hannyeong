import Foundation
import InputMethodKit

/// Only the last Hangul character stays marked; the rest is ordinary committed text.
@MainActor
final class InlineComposition {
    private let client: any IMKTextInput
    private var committed = ""
    private var marked = ""
    var isActive: Bool { !committed.isEmpty || !marked.isEmpty }

    init(client: any IMKTextInput) { self.client = client }

    func requiresReplacement(_ text: String, committing: Bool = false) -> Bool {
        !parts(text, committing: committing).prefix.hasPrefix(committed)
    }

    /// End the current composition before AX verifies and selects the whole owned word.
    func finishMarked() -> String {
        let text = committed + marked
        if !marked.isEmpty {
            let last = marked
            committed = text
            marked = ""
            client.insertText(last, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        return text
    }

    /// AX has already selected the exact previous word and confirmed that selection.
    func replaceSelected(_ text: String, previous: String, committing: Bool) {
        committed = ""
        marked = text.isEmpty ? previous : text
        client.setMarkedText(marked, selectionRange: NSRange(location: marked.utf16.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        guard isActive else { return }
        update(text, committing: committing)
    }

    func render(_ text: String) { update(text, committing: false) }
    func commit(_ text: String) { update(text, committing: true) }
    func adoptCommitted(_ text: String) { committed = text; marked = "" }

    var committedText: String { committed }

    func sharedCommittedPrefix(with text: String, committing: Bool) -> String {
        String(zip(committed, parts(text, committing: committing).prefix)
            .prefix(while: { $0.0 == $0.1 }).map { $0.0 })
    }

    private func parts(_ text: String, committing: Bool) -> (prefix: String, tail: String) {
        let tail = committing ? "" : text.last.map { character in
            character.unicodeScalars.allSatisfy {
                (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x3163).contains($0.value)
            } ? String(character) : ""
        } ?? ""
        return (tail.isEmpty ? text : String(text.dropLast()), tail)
    }

    private func update(_ text: String, committing: Bool) {
        let (prefix, tail) = parts(text, committing: committing)
        precondition(prefix.hasPrefix(committed))
        let added = String(prefix.dropFirst(committed.count))
        if !added.isEmpty {
            committed = prefix
            marked = ""
            client.insertText(added, replacementRange: NSRange(location: NSNotFound, length: 0))
            guard isActive else { return }
        } else if tail.isEmpty, !marked.isEmpty {
            marked = ""
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if !tail.isEmpty {
            marked = tail
            client.setMarkedText(tail, selectionRange: NSRange(location: tail.utf16.count, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if committing { committed = ""; marked = "" }
    }
}
