import Foundation
import InputMethodKit

/// Replace a known filename suffix in one IMK call, without selecting it key by key.
@MainActor
enum NativeSheetReplacement {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func replace(client: any IMKTextInput, expected: String, with replacement: String) throws {
        let selection = client.selectedRange()
        let length = expected.utf16.count
        guard selection.location != NSNotFound, selection.length == 0, selection.location >= length else {
            throw Failure(errorDescription: "The save-field caret is unavailable or has a selection.")
        }
        let range = NSRange(location: selection.location - length, length: length)
        var actualRange = NSRange(location: NSNotFound, length: 0)
        guard client.string(from: range, actualRange: &actualRange) == expected, actualRange == range else {
            throw Failure(errorDescription: "The save-field suffix changed before language reversal.")
        }
        client.insertText(replacement, replacementRange: range)
    }
}
