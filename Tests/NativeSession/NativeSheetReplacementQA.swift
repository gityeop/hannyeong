import AppKit

private final class ReplacementView: NativeTextView {
    var replacements: [NSRange] = []
    var nonemptySelections: [NSRange] = []
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        replacements.append(replacementRange)
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func setSelectedRange(_ charRange: NSRange) {
        if charRange.length > 0 { nonemptySelections.append(charRange) }
        super.setSelectedRange(charRange)
    }
}

@main
private struct NativeSheetReplacementQA {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let view = ReplacementView(frame: .zero)
            for (before, after) in [("안녕", "dkssud"), (String(repeating: "한글", count: 30), String(repeating: "gksrmf", count: 30))] {
                view.string = "📁 " + before + ".html"
                view.setSelectedRange(NSRange(location: 3 + before.utf16.count, length: 0))
                view.replacements.removeAll(); view.nonemptySelections.removeAll()
                try NativeSheetReplacement.replace(client: view, expected: before, with: after)
                precondition(view.string == "📁 " + after + ".html")
                precondition(view.replacements == [NSRange(location: 3, length: before.utf16.count)])
                precondition(view.nonemptySelections.isEmpty, "Language reversal visibly selected characters")
                precondition(view.selectedRange() == NSRange(location: 3 + after.utf16.count, length: 0))
                view.replacements.removeAll()
                try NativeSheetReplacement.replace(client: view, expected: after, with: before)
                precondition(view.string == "📁 " + before + ".html" && view.replacements.count == 1)
            }
            view.string = "안녕.html"
            view.setSelectedRange(NSRange(location: 2, length: 0))
            for unavailable in [false, true] {
                view.hidesSurroundingText = unavailable
                view.replacements.removeAll()
                do {
                    try NativeSheetReplacement.replace(client: view, expected: "다름", with: "wrong")
                    preconditionFailure("A changed or unreadable suffix was replaced")
                } catch is NativeSheetReplacement.Failure {}
                precondition(view.string == "안녕.html" && view.replacements.isEmpty)
            }
            view.hidesSurroundingText = false
            view.setSelectedRange(NSRange(location: 0, length: 2))
            do {
                try NativeSheetReplacement.replace(client: view, expected: "안녕", with: "wrong")
                preconditionFailure("A user selection was overwritten")
            } catch is NativeSheetReplacement.Failure {}
            print("PASS native sheet reversal: one replacement, no expanding selection, short/long words, exact reversal, UTF16 caret and extension preserved, changed/unreadable/selected targets rejected")
        } catch {
            fputs("Native sheet replacement QA failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
