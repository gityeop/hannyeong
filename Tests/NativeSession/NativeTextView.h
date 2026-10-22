#import <AppKit/AppKit.h>
#import <InputMethodKit/InputMethodKit.h>
@interface NativeTextView : NSTextView <IMKTextInput>
- (BOOL)selectCommittedTextInRange:(NSRange)range expected:(NSString *)expected NS_SWIFT_NAME(selectCommittedText(in:expected:));
- (void)applyHostEvent:(NSEvent *)event;
@property BOOL hidesSurroundingText;
@property BOOL commitsOnlyMarkedText;
@property NSUInteger markedLineBreaks;
@property BOOL sendsOnReturn;
@property NSUInteger returnEvents;
@property NSUInteger lastReturnModifiers;
@property BOOL receivedReturnWithMarkedText;
@property(copy) NSString *lastSubmittedText;
- (void)setMarkedText:(id)string selectionRange:(NSRange)selectionRange replacementRange:(NSRange)replacementRange;
- (NSString *)stringFromRange:(NSRange)range actualRange:(NSRangePointer)actualRange;
@end

@interface NativeInputClient : NSObject <IMKTextInput>
@property(strong) NativeTextView *view;
@property BOOL hidesMarkedLocation;
@property BOOL reportsCompositionStartAfterCommit;
@end
