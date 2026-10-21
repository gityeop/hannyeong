#import "NativeTextView.h"
@implementation NativeTextView
- (BOOL)selectCommittedTextInRange:(NSRange)range expected:(NSString *)expected {
    if (self.hidesSurroundingText || NSMaxRange(range) > self.string.length || ![[self.string substringWithRange:range] isEqualToString:expected]) return NO;
    [self unmarkText];
    [self setSelectedRange:range];
    return YES;
}
- (void)applyHostEvent:(NSEvent *)event {
    if (event.keyCode == 51) [self deleteBackward:nil];
    else if (event.keyCode == 36 || event.keyCode == 76 || (event.keyCode >= 123 && event.keyCode <= 126)) [self keyDown:event];
    else [self insertText:event.characters replacementRange:NSMakeRange(NSNotFound, 0)];
}
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    // Codex ignores empty commits and keeps the confirmed prefix while marked text is active.
    if (self.commitsOnlyMarkedText) {
        NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
        if (text.length == 0) return;
        if (self.hasMarkedText) replacementRange = self.markedRange;
    }
    [super insertText:string replacementRange:replacementRange];
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 36 || event.keyCode == 76) {
        self.returnEvents += 1;
        self.lastReturnModifiers = event.modifierFlags;
        self.receivedReturnWithMarkedText = self.hasMarkedText;
        if (self.sendsOnReturn && !(event.modifierFlags & NSEventModifierFlagShift)) {
            self.lastSubmittedText = self.string;
            self.string = @"";
            [self setSelectedRange:NSMakeRange(0, 0)];
        } else {
            [self insertNewline:nil];
        }
        return;
    }
    [super keyDown:event];
}
- (void)setMarkedText:(id)string selectionRange:(NSRange)selectionRange replacementRange:(NSRange)replacementRange {
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    self.markedLineBreaks += [[text componentsSeparatedByString:@"\n"] count] - 1;
    [super setMarkedText:string selectedRange:selectionRange replacementRange:replacementRange];
}
- (NSString *)stringFromRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (self.hidesSurroundingText) { *actualRange = NSMakeRange(NSNotFound, 0); return nil; }
    *actualRange = range;
    return [self.string substringWithRange:range];
}
@end

// Model IMK's missing location without changing NSTextView's own composition state.
@implementation NativeInputClient
- (id)forwardingTargetForSelector:(SEL)selector { return self.view; }
- (NSRange)markedRange {
    NSRange range = self.view.markedRange;
    if (self.hidesMarkedLocation && range.length > 0) range.location = NSNotFound;
    return range;
}
@end
