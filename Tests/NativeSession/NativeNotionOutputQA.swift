import AppKit
import InputMethodKit

@main private struct NativeNotionOutputQA {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let view = CachedSelectionTextView(frame: .zero)
        view.string = "📌 뒤"; view.setSelectedRange(NSRange(location: 3, length: 0))
        let output = NativeNotionOutput(client: view)
        try output.replace(deletingUTF16: 0, with: "x")
        view.reportedSelection = NSRange(location: 1, length: 0)
        try output.replace(deletingUTF16: 1, with: "ㅌ")
        view.reportedSelection = NSRange(location: 4, length: 1)
        try output.replace(deletingUTF16: 1, with: "타")
        try output.replace(deletingUTF16: 1, with: "탕")
        try output.replace(deletingUTF16: 1, with: "타이")
        precondition(view.string == "📌 타이뒤", "Stale Notion selection changed the replacement location")
        precondition(view.replacements.last == NSRange(location: 3, length: 1))
        view.reportedSelection = nil
        view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0)); output.advance(" ")
        try output.replace(deletingUTF16: 3, with: "타이핑 ")
        precondition(view.string == "📌 타이핑 뒤", "Passed Space was not included in the owned suffix")
        precondition(view.markedCalls == 0 && !view.hasMarkedText(), "A whole-word underline was introduced")

        let empty = CachedSelectionTextView(frame: .zero)
        empty.hideInitialSelection = true
        let emptyOutput = NativeNotionOutput(client: empty)
        try emptyOutput.replace(deletingUTF16: 0, with: "ㅌ")
        try emptyOutput.replace(deletingUTF16: 1, with: "타")
        precondition(empty.string == "타", "An empty field required a cursor before the first key")

        let erased = CachedSelectionTextView(frame: .zero)
        let erasedOutput = NativeNotionOutput(client: erased)
        try erasedOutput.replace(deletingUTF16: 0, with: "닿")
        try erasedOutput.replace(deletingUTF16: 0, with: "ㅎ")
        erased.deleteBackward(nil); erasedOutput.advance(utf16: -1)
        erased.reportedSelection = NSRange(location: 0, length: 0)
        try erasedOutput.replace(deletingUTF16: 1, with: "다")
        precondition(erased.string == "다", "A host Backspace left the owned caret behind the deleted character")

        output.reset()
        view.setSelectedRange(NSRange(location: 3, length: 3))
        try output.replace(deletingUTF16: 0, with: "안녕")
        precondition(view.string == "📌 안녕 뒤", "Field reset reused an old caret or lost the selection")
        let other = CachedSelectionTextView(frame: .zero)
        let otherOutput = NativeNotionOutput(client: other)
        try otherOutput.replace(deletingUTF16: 0, with: "본문")
        precondition(other.string == "본문" && view.string == "📌 안녕 뒤", "Controller output crossed clients")
        otherOutput.reset(); other.reportedSelection = NSRange(location: NSNotFound, length: 0)
        let count = other.replacements.count
        do {
            try otherOutput.replace(deletingUTF16: 1, with: "wrong")
            preconditionFailure("A missing caret was fabricated")
        } catch is NativeNotionOutput.Failure {}
        precondition(other.replacements.count == count)

        let retyped = CachedSelectionTextView(frame: .zero)
        retyped.clampsReplacementAtEnd = true
        let retypedOutput = NativeNotionOutput(client: retyped)
        try retypedOutput.replace(deletingUTF16: 0, with: "ㄳ")
        retypedOutput.reset()
        retyped.insertNewline(nil)
        retypedOutput.reset(.hostBackspace)
        retyped.deleteBackward(nil)
        retypedOutput.reset(.hostBackspace)
        retyped.deleteBackward(nil)
        precondition(retyped.string.isEmpty)
        retyped.reportedSelection = NSRange(location: 1, length: 0)
        try retypedOutput.replace(deletingUTF16: 0, with: "ㄱ")
        retyped.reportedSelection = nil
        try retypedOutput.replace(deletingUTF16: 1, with: "ㄳ")
        guard retyped.string == "ㄳ" else {
            fputs("Return and two Backspaces: expected ㄳ, got \(retyped.string).\n", stderr)
            exit(1)
        }
        try openAICommandDeleteChecks()
        print("PASS Notion native output, including ㄳ → Return → Backspace ×2 → ㄳ after a stale selection")
    }

    @MainActor private static func openAICommandDeleteChecks() throws {
        for prefix in ["", "📌 앞줄\n"] {
            let view = CachedSelectionTextView(frame: .zero)
            view.clampsReplacementAtEnd = true
            view.string = prefix
            view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            let output = NativeNotionOutput(client: view, clientOwner: .openAI)
            try output.replace(deletingUTF16: 0, with: "안녕 ")
            output.reset(.hostBackspace)
            view.deleteBackward(nil)
            output.reset()
            view.setSelectedRange(NSRange(location: prefix.utf16.count, length: "안녕".utf16.count))
            view.deleteBackward(nil)
            precondition(view.string == prefix)
            view.reportedSelection = NSRange(location: prefix.utf16.count, length: 0)
            // ChatGPT reports the position from before ㄱ when the next key arrives immediately.
            try output.replace(deletingUTF16: 0, with: "ㄱ")
            try output.replace(deletingUTF16: 1, with: "가")
            try output.replace(deletingUTF16: 1, with: "간")
            try output.replace(deletingUTF16: 1, with: "가나")
            precondition(view.string == prefix + "가나", "OpenAI rapid retyping changed the preceding line: \(view.string)")
        }
        print("PASS OpenAI Command-Delete and immediate r k s k with stale selection in empty and multiline fields")
    }
}
