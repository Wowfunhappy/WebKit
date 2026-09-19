#import <AppKit/AppKit.h>
#include <stdio.h>

// The probe uses 10.9 headers and binds the class symbols supplied by the compatibility library.
@interface NSTouchBarItem : NSObject
@property (readonly) NSString *identifier;
@property (readonly, getter=isVisible) BOOL visible;
- (instancetype)initWithIdentifier:(NSString *)identifier;
@end
@interface NSTouchBar : NSObject
@property (copy) NSSet *templateItems;
@property (copy) NSArray *defaultItemIdentifiers;
@property (readonly, getter=isVisible) BOOL visible;
- (NSTouchBarItem *)itemForIdentifier:(NSString *)identifier;
@end
@interface NSCandidateListTouchBarItem : NSTouchBarItem
@property (weak) id delegate;
@property (readonly) NSArray *candidates;
@property (readonly, getter=isCandidateListVisible) BOOL candidateListVisible;
- (void)setCandidates:(NSArray *)candidates forSelectedRange:(NSRange)range inString:(NSString *)string;
@end
@interface NSGroupTouchBarItem : NSTouchBarItem
@property (retain) NSTouchBar *groupTouchBar;
+ (instancetype)groupItemWithIdentifier:(NSString *)identifier items:(NSArray *)items;
@end
@interface NSResponder (TouchBarProbe)
@property (retain) NSTouchBar *touchBar;
@end
@interface NSSpellChecker (TouchBarProbe)
+ (BOOL)isAutomaticTextCompletionEnabled;
@end
extern NSString * const NSTouchBarItemIdentifierCandidateList;

static int failures;
static void expectTouchBar(BOOL condition, const char *message)
{
    printf("%s %s\n", condition ? "PASS" : "FAIL", message);
    if (!condition)
        ++failures;
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        for (NSString *name in @[@"NSTouchBar", @"NSTouchBarItem", @"NSCandidateListTouchBarItem", @"NSCustomTouchBarItem", @"NSColorPickerTouchBarItem", @"NSGroupTouchBarItem", @"NSPopoverTouchBarItem", @"NSTextTouchBarItemController"])
            expectTouchBar(NSClassFromString(name) == Nil, name.UTF8String);

        NSTouchBar *bar = [[NSTouchBar alloc] init];
        NSCandidateListTouchBarItem *candidate = [[NSCandidateListTouchBarItem alloc] initWithIdentifier:NSTouchBarItemIdentifierCandidateList];
        NSMutableArray *identifiers = [NSMutableArray arrayWithObject:candidate.identifier];
        bar.templateItems = [NSSet setWithObject:candidate];
        bar.defaultItemIdentifiers = identifiers;
        [identifiers removeAllObjects];
        expectTouchBar(bar.defaultItemIdentifiers.count == 1, "item identifiers are copied");
        expectTouchBar([bar itemForIdentifier:candidate.identifier] == candidate, "template item identity");
        expectTouchBar(!bar.visible && !candidate.visible && !candidate.candidateListVisible, "hardware visibility is false");

        NSMutableArray *values = [NSMutableArray arrayWithObject:@"hello"];
        [candidate setCandidates:values forSelectedRange:NSMakeRange(0, 0) inString:@""];
        [values removeAllObjects];
        expectTouchBar([candidate.candidates isEqual:@[@"hello"]], "candidate configuration is copied");
        NSObject *delegate = [[NSObject alloc] init];
        candidate.delegate = (id)delegate;
        [delegate release];
        expectTouchBar(candidate.delegate == nil, "delegate is zeroing weak");

        NSGroupTouchBarItem *group = [NSGroupTouchBarItem groupItemWithIdentifier:@"group" items:@[candidate]];
        expectTouchBar([group.groupTouchBar itemForIdentifier:candidate.identifier] == candidate, "group retains item configuration");
        NSResponder *responder = [[NSResponder alloc] init];
        expectTouchBar(responder.touchBar == nil, "responder default has no bar");
        responder.touchBar = bar;
        expectTouchBar(responder.touchBar == bar, "responder retains explicit bar");
        responder.touchBar = nil;
        expectTouchBar(responder.touchBar == nil, "responder clears explicit bar");
        expectTouchBar(![NSSpellChecker isAutomaticTextCompletionEnabled], "automatic completion is unavailable");
        [responder release];
        [candidate release];
        [bar release];
    }
    return failures ? 1 : 0;
}
