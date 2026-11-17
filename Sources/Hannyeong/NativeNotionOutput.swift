import Foundation
import InputMethodKit
import HannyeongInputRuntime

/// A controller owns its client and the UTF-16 caret advanced by its own edits.
/// Chromium's selectedRange cache is not a confirmation of an explicit-range commit.
@MainActor
final class NativeNotionOutput {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private let client: any IMKTextInput
    let clientOwner: TypingEngine.ClientOwner?
    var usesClientRoute: Bool { clientOwner != nil }
    private var caret: Int?
    private var readCaretOnNextReplacement = false

    init(client: any IMKTextInput, clientOwner: TypingEngine.ClientOwner? = nil) {
        self.client = client
        self.clientOwner = clientOwner
    }

    func belongsTo(_ client: any IMKTextInput) -> Bool {
        (self.client as AnyObject) === (client as AnyObject)
    }

    func reset(afterHostDeletion: Bool = false) {
        caret = nil
        if afterHostDeletion { readCaretOnNextReplacement = true }
    }
    func advance(_ text: String) { advance(utf16: text.utf16.count) }
    /// A negative count follows a host Backspace over owned text.
    func advance(utf16 count: Int) {
        guard let caret else { return }
        self.caret = caret + count >= 0 ? caret + count : nil
    }

    func replace(deletingUTF16 length: Int, with text: String) throws {
        if readCaretOnNextReplacement && length == 0 {
            // Chromium can still report the selection from before its Backspace.
            // Insert at the host's current selection and read the range when a rewrite needs it.
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        if let caret {
            guard caret >= length else {
                throw Failure(errorDescription: "The Notion edit exceeds its owned UTF-16 caret (caret=\(caret), delete=\(length)).")
            }
            let range = NSRange(location: caret - length, length: length)
            client.insertText(text, replacementRange: range)
            self.caret = range.location + text.utf16.count
            return
        }

        let selection = client.selectedRange()
        if length == 0 {
            // Empty Notion fields may have no document range until the first insertion.
            // Do not require that range before sending the first real key.
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            if selection.location != NSNotFound {
                caret = selection.location + text.utf16.count
            } else {
                let inserted = client.selectedRange()
                if inserted.location != NSNotFound, inserted.length == 0 { caret = inserted.location }
            }
        } else {
            // Letters may already have passed through while AX was checking this field.
            guard selection.location != NSNotFound, selection.length == 0, selection.location >= length else {
                throw Failure(errorDescription: "The Notion replacement has no owned caret (location=\(selection.location), length=\(selection.length), delete=\(length)).")
            }
            let range = NSRange(location: selection.location - length, length: length)
            client.insertText(text, replacementRange: range)
            caret = range.location + text.utf16.count
            readCaretOnNextReplacement = false
        }
    }
}
