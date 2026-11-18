import Foundation
import InputMethodKit

/// Replace a known filename suffix in one IMK call, without selecting it key by key.
@MainActor
struct NativeSheetReplacement {
    private weak var client: (any IMKTextInput)?

    init?(client: any IMKTextInput) {
        guard client.bundleIdentifier() == "com.apple.appkit.xpc.openAndSavePanelService" else { return nil }
        self.client = client
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static var unavailable: Failure { Failure(errorDescription: "The active save-field input client is unavailable.") }

    func replace(expected: String, with replacement: String) throws {
        guard let client else { throw Self.unavailable }
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
