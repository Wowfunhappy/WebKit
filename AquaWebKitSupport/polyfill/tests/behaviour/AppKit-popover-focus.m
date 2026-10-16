#import <AppKit/AppKit.h>
#include <stdio.h>

@interface PopoverFocusView : NSView
@property BOOL acceptsFocus;
@property NSUInteger resignations;
@property NSUInteger becomes;
@end

@implementation PopoverFocusView
- (BOOL)acceptsFirstResponder { return _acceptsFocus; }
- (BOOL)becomeFirstResponder
{
    ++_becomes;
    return [super becomeFirstResponder];
}
- (BOOL)resignFirstResponder
{
    ++_resignations;
    return [super resignFirstResponder];
}
@end

@interface PopoverFocusDelegate : NSObject <NSPopoverDelegate>
@property (assign) NSWindow *anchorWindow;
@property (assign) NSResponder *expectedResponder;
@property NSUInteger shows;
@property BOOL hadExpectedFocusDuringShow;
@property BOOL hadKeyAnchorDuringShow;
@property BOOL hadNonKeyPopoverDuringShow;
@property NSUInteger keyResignations;
@end

@implementation PopoverFocusDelegate
- (void)popoverDidShow:(NSNotification *)notification
{
    ++_shows;
    _hadExpectedFocusDuringShow = [_anchorWindow firstResponder] == _expectedResponder;
    _hadKeyAnchorDuringShow = [_anchorWindow isKeyWindow] && [NSApp keyWindow] == _anchorWindow;
    NSWindow *popoverWindow = [[[[notification object] contentViewController] view] window];
    // Shared windows inherit isKeyWindow from their parent; NSApp identifies the key window itself.
    _hadNonKeyPopoverDuringShow = popoverWindow && [NSApp keyWindow] != popoverWindow;
}
- (void)anchorDidResignKey:(NSNotification *)notification
{
    ++_keyResignations;
}
@end

static unsigned failures;
static void check(BOOL condition, const char *message)
{
    printf("%s %s\n", condition ? "PASS" : "FAIL", message);
    failures += !condition;
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        [NSApp activateIgnoringOtherApps:YES];
        NSDate *activationDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (![NSApp isActive] && [activationDeadline timeIntervalSinceNow] > 0) {
            NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask untilDate:activationDeadline
                inMode:NSDefaultRunLoopMode dequeue:YES];
            if (!event)
                break;
            [NSApp sendEvent:event];
        }
        check([NSApp isActive], "application is active");
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 400, 300)
            styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        [window setReleasedWhenClosed:NO];
        PopoverFocusView *anchor = [[PopoverFocusView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        anchor.acceptsFocus = YES;
        [window setContentView:anchor];
        [window makeKeyAndOrderFront:nil];
        [window makeFirstResponder:anchor];

        PopoverFocusView *content = [[PopoverFocusView alloc] initWithFrame:NSMakeRect(0, 0, 200, 50)];
        NSViewController *controller = [[NSViewController alloc] init];
        [controller setView:content];
        NSPopover *popover = [[NSPopover alloc] init];
        [popover setContentViewController:controller];
        [popover setBehavior:NSPopoverBehaviorTransient];
        [popover setAnimates:NO];
        PopoverFocusDelegate *delegate = [[PopoverFocusDelegate alloc] init];
        delegate.anchorWindow = window;
        delegate.expectedResponder = anchor;
        [popover setDelegate:delegate];
        [[NSNotificationCenter defaultCenter] addObserver:delegate selector:@selector(anchorDidResignKey:)
            name:NSWindowDidResignKeyNotification object:window];

        check([window isKeyWindow] && [NSApp keyWindow] == window, "anchor is key before passive presentation");
        [popover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:anchor preferredEdge:NSMinYEdge];
        check([popover isShown], "passive popover is shown");
        check(delegate.shows == 1 && delegate.hadExpectedFocusDuringShow, "passive presentation preserves focus during delegate notification");
        check(delegate.hadKeyAnchorDuringShow, "anchor is key during passive didShow");
        check([window isKeyWindow] && [NSApp keyWindow] == window, "anchor is key after passive presentation");
        check(delegate.hadNonKeyPopoverDuringShow, "passive popover is not key during didShow");
        check([content window] && [NSApp keyWindow] != [content window], "passive popover is not key after show");
        check(!delegate.keyResignations, "passive presentation sends no anchor resign-key notification");
        check([window firstResponder] == anchor && !anchor.resignations, "passive presentation sends no resignFirstResponder callback");
        [popover close];
        check([window firstResponder] == anchor && !anchor.resignations, "closing a passive popover preserves focus");
        check([window isKeyWindow] && [NSApp keyWindow] == window && !delegate.keyResignations, "closing a passive popover preserves the anchor key state without resign-key notifications");

        content.acceptsFocus = YES;
        delegate.expectedResponder = content;
        [[content window] setInitialFirstResponder:content];
        check([window isKeyWindow] && [NSApp keyWindow] == window, "anchor is key before focusable presentation");
        content.becomes = 0;
        [popover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:anchor preferredEdge:NSMinYEdge];
        check([popover isShown] && delegate.shows == 2, "focusable popover is shown on reuse");
        check(delegate.hadExpectedFocusDuringShow && [window firstResponder] == content, "focusable content receives focus during and after presentation");
        check(delegate.hadKeyAnchorDuringShow, "anchor is key during focusable didShow");
        check([window isKeyWindow] && [NSApp keyWindow] == window, "anchor is key after focusable presentation");
        check(!delegate.keyResignations, "focusable presentation sends no anchor resign-key notification");
        check(anchor.resignations == 1 && content.becomes == 1, "focusable presentation resigns the anchor once and focuses the content once");
        [popover close];
        check([window isKeyWindow] && [NSApp keyWindow] == window && !delegate.keyResignations, "closing a focusable popover preserves the anchor key state without resign-key notifications");

        content.acceptsFocus = NO;
        [window makeFirstResponder:anchor];
        anchor.resignations = 0;
        delegate.expectedResponder = anchor;
        check([window isKeyWindow] && [NSApp keyWindow] == window, "anchor is key before reused passive presentation");
        [popover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:anchor preferredEdge:NSMinYEdge];
        check(delegate.shows == 3 && delegate.hadExpectedFocusDuringShow && !anchor.resignations, "a reused passive popover preserves focus");
        check(delegate.hadKeyAnchorDuringShow, "anchor is key during reused passive didShow");
        check([window isKeyWindow] && [NSApp keyWindow] == window, "anchor is key after reused passive presentation");
        check(delegate.hadNonKeyPopoverDuringShow, "reused passive popover is not key during didShow");
        check([content window] && [NSApp keyWindow] != [content window], "reused passive popover is not key after show");
        check(!delegate.keyResignations, "reused passive presentation sends no anchor resign-key notification");
        check([window firstResponder] == anchor, "reused passive presentation preserves the anchor first responder");
        [popover close];
        check([window firstResponder] == anchor && !anchor.resignations, "closing a reused passive popover preserves focus");
        check([window isKeyWindow] && [NSApp keyWindow] == window && !delegate.keyResignations, "closing a reused passive popover preserves the anchor key state without resign-key notifications");

        // A popover with its own content view controller, shown once from the anchor.
        PopoverFocusView *(^makeContent)(NSPopover **) = ^PopoverFocusView *(NSPopover **outPopover) {
            PopoverFocusView *view = [[[PopoverFocusView alloc] initWithFrame:NSMakeRect(0, 0, 200, 50)] autorelease];
            NSViewController *viewController = [[[NSViewController alloc] init] autorelease];
            [viewController setView:view];
            NSPopover *newPopover = [[[NSPopover alloc] init] autorelease];
            [newPopover setContentViewController:viewController];
            [newPopover setBehavior:NSPopoverBehaviorTransient];
            [newPopover setAnimates:NO];
            *outPopover = newPopover;
            return view;
        };
        void (^resetAnchor)(void) = ^{
            [window makeFirstResponder:anchor];
            anchor.resignations = 0;
        };

        // Content that rejects focus around a focusable view, no initialFirstResponder: ordering the popover
        // window selects that view as its first key view, and sharing hands it to the anchor window.
        NSPopover *subviewPopover = nil;
        PopoverFocusView *subviewContent = makeContent(&subviewPopover);
        PopoverFocusView *subviewField = [[[PopoverFocusView alloc] initWithFrame:NSMakeRect(10, 10, 50, 20)] autorelease];
        subviewField.acceptsFocus = YES;
        [subviewContent addSubview:subviewField];
        resetAnchor();
        [subviewPopover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:anchor preferredEdge:NSMinYEdge];
        check([window firstResponder] == subviewField && subviewField.becomes == 1 && anchor.resignations == 1, "the first key view inside rejecting content takes focus once from the anchor");
        check([window isKeyWindow] && [NSApp keyWindow] == window, "anchor stays key when the first key view takes focus");
        [subviewPopover close];

        // Content that rejects focus, with the popover window's initialFirstResponder set to a focusable view.
        NSPopover *initialPopover = nil;
        PopoverFocusView *initialContent = makeContent(&initialPopover);
        PopoverFocusView *initialField = [[[PopoverFocusView alloc] initWithFrame:NSMakeRect(10, 10, 50, 20)] autorelease];
        [initialContent addSubview:initialField];
        resetAnchor();
        [initialPopover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:anchor preferredEdge:NSMinYEdge];
        check([window firstResponder] == anchor && !anchor.resignations, "content with no view that accepts focus leaves the anchor focused");
        [initialPopover close];
        initialField.acceptsFocus = YES;
        initialField.becomes = 0;
        [[initialContent window] setInitialFirstResponder:initialField];
        resetAnchor();
        [initialPopover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:anchor preferredEdge:NSMinYEdge];
        check([window firstResponder] == initialField && initialField.becomes == 1 && anchor.resignations == 1, "a focusable initialFirstResponder takes focus once from the anchor");
        check([window isKeyWindow] && [NSApp keyWindow] == window, "anchor stays key when the initialFirstResponder takes focus");
        [initialPopover close];

        // Content that accepts focus, no initialFirstResponder set: the content view is the first key view.
        NSPopover *acceptingPopover = nil;
        PopoverFocusView *acceptingContent = makeContent(&acceptingPopover);
        acceptingContent.acceptsFocus = YES;
        resetAnchor();
        [acceptingPopover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:anchor preferredEdge:NSMinYEdge];
        check([window firstResponder] == acceptingContent && acceptingContent.becomes == 1 && anchor.resignations == 1, "content that accepts focus takes it once from the anchor");
        [acceptingPopover close];

        // The shape of WebCore's ValidationBubbleMac: a plain view holding a non-editable NSTextField label.
        NSPopover *bubblePopover = nil;
        PopoverFocusView *bubbleContent = makeContent(&bubblePopover);
        NSTextField *bubbleLabel = [[[NSTextField alloc] init] autorelease];
        [bubbleLabel setEditable:NO];
        [bubbleLabel setDrawsBackground:NO];
        [bubbleLabel setBordered:NO];
        [bubbleLabel setStringValue:@"Fill out this field"];
        [bubbleLabel setFrame:NSMakeRect(5, 5, 150, 20)];
        [bubbleContent addSubview:bubbleLabel];
        resetAnchor();
        [bubblePopover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:anchor preferredEdge:NSMinYEdge];
        check(![bubbleLabel isSelectable] && ![bubbleLabel acceptsFirstResponder], "a non-editable label does not accept focus");
        check([bubblePopover isShown] && [window firstResponder] == anchor && !anchor.resignations, "a validation-bubble popover leaves the anchor focused");
        [bubblePopover close];

        // An anchor window that cannot become key: the popover window keeps its own first responder.
        NSWindow *borderless = [[NSWindow alloc] initWithContentRect:NSMakeRect(600, 100, 300, 200)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        [borderless setReleasedWhenClosed:NO];
        PopoverFocusView *borderlessAnchor = [[PopoverFocusView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
        [borderless setContentView:borderlessAnchor];
        [borderless orderFront:nil];
        check(![borderless canBecomeKeyWindow], "borderless anchor cannot become key");
        [initialPopover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:borderlessAnchor preferredEdge:NSMinYEdge];
        check([initialPopover isShown] && [borderless firstResponder] == borderless, "an anchor that cannot become key does not share its first responder");
        check([[initialContent window] firstResponder] == initialField, "the popover window's own first responder is the initialFirstResponder");
        [initialPopover close];
        [borderless close];
        [borderlessAnchor release];
        [borderless release];

        [[NSNotificationCenter defaultCenter] removeObserver:delegate];
        [popover setDelegate:nil];
        [delegate release];
        [popover release];
        [controller release];
        [content release];
        [window close];
        [window release];
        [anchor release];
    }
    return failures ? 1 : 0;
}
