import AppKit

final class CachedSelectionTextView: NativeTextView {
    var reportedSelection: NSRange?
    var hideInitialSelection = false
    var clampsReplacementAtEnd = false
    var replacements: [NSRange] = []
    var markedCalls = 0
    override func selectedRange() -> NSRange {
        if hideInitialSelection && replacements.isEmpty { return NSRange(location: NSNotFound, length: 0) }
        return reportedSelection ?? super.selectedRange()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        replacements.append(replacementRange)
        var range = replacementRange
        if clampsReplacementAtEnd {
            let cached = reportedSelection
            reportedSelection = nil
            defer { reportedSelection = cached }
            if range.location != NSNotFound {
                let end = self.string.utf16.count
                range.location = min(range.location, end)
                range.length = min(range.length, end - range.location)
            }
            super.insertText(string, replacementRange: range)
            return
        }
        super.insertText(string, replacementRange: range)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedCalls += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
}
