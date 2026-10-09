#import <AppKit/AppKit.h>
#include <stdio.h>

@interface PopoverFocusView : NSView
@property BOOL acceptsFocus;
@property NSUInteger resignations;
@end

@implementation PopoverFocusView
- (BOOL)acceptsFirstResponder { return _acceptsFocus; }
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
        [popover showRelativeToRect:NSMakeRect(20, 20, 50, 20) ofView:anchor preferredEdge:NSMinYEdge];
        check([popover isShown] && delegate.shows == 2, "focusable popover is shown on reuse");
        check(delegate.hadExpectedFocusDuringShow && [window firstResponder] == content, "focusable content receives focus during and after presentation");
        check(delegate.hadKeyAnchorDuringShow, "anchor is key during focusable didShow");
        check([window isKeyWindow] && [NSApp keyWindow] == window, "anchor is key after focusable presentation");
        check(!delegate.keyResignations, "focusable presentation sends no anchor resign-key notification");
        check(anchor.resignations == 1, "focusable presentation resigns the anchor once");
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
