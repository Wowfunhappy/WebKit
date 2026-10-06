// The share picker's popover form shows 10.9's services menu, reports the choice to its completion,
// and -hide closes the menu while it is up.
//
// The chosen-service case activates this process and drives the menu with keystrokes posted to the
// login session, so it needs the window server session this VM runs in.
#import <AppKit/AppKit.h>
#include <stdio.h>

@interface NSSharingServicePicker (PopoverProbe)
- (void)showPopoverRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)preferredEdge completion:(void (^)(NSSharingService *))completion;
- (void)hide;
@end

@interface ProbeDelegate : NSObject <NSSharingServicePickerDelegate, NSSharingServiceDelegate>
@property (nonatomic) BOOL choseNothing;
@property (nonatomic) NSUInteger chooseCount;
@property (nonatomic, retain) NSSharingService *chosenService;
@property (nonatomic, retain) NSSharingService *offeredService;
@property (nonatomic) NSUInteger serviceDelegateRequests;
@end

@implementation ProbeDelegate
- (void)sharingServicePicker:(NSSharingServicePicker *)picker didChooseSharingService:(NSSharingService *)service
{
    ++_chooseCount;
    _choseNothing = !service;
    self.chosenService = service;
}
- (NSArray *)sharingServicePicker:(NSSharingServicePicker *)picker sharingServicesForItems:(NSArray *)items proposedSharingServices:(NSArray *)proposed
{
    return _offeredService ? @[ _offeredService ] : proposed;
}
- (id<NSSharingServiceDelegate>)sharingServicePicker:(NSSharingServicePicker *)picker delegateForSharingService:(NSSharingService *)service
{
    ++_serviceDelegateRequests;
    return self;
}
@end

static void postKey(CGKeyCode key)
{
    for (int down = 1; down >= 0; --down) {
        CGEventRef event = CGEventCreateKeyboardEvent(NULL, key, down);
        CGEventPost(kCGSessionEventTap, event);
        CFRelease(event);
    }
}

static unsigned failures;

static void check(const char *name, BOOL matches)
{
    printf("%s %s\n", matches ? "PASS" : "FAIL", name);
    failures += !matches;
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 300, 200) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        [window orderFrontRegardless];
        NSView *view = [window contentView];

        NSSharingServicePicker *picker = [[NSSharingServicePicker alloc] initWithItems:@[ [NSURL URLWithString:@"https://webkit.org/"] ]];
        ProbeDelegate *delegate = [ProbeDelegate new];
        [picker setDelegate:delegate];

        [picker hide];
        check("hide with nothing shown is harmless", [picker delegate] == delegate);

        __block BOOL menuTracked = NO;
        __block BOOL delegateForwarded = NO;
        id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(__unused NSNotification *notification) {
            menuTracked = YES;
        }];
        CFRunLoopTimerRef hideTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.5, 0, 0, 0, ^(__unused CFRunLoopTimerRef timer) {
            id current = [picker delegate];
            delegateForwarded = [current respondsToSelector:@selector(sharingServicePicker:delegateForSharingService:)]
                && [(id<NSSharingServicePickerDelegate>)current sharingServicePicker:picker delegateForSharingService:[NSSharingService sharingServiceNamed:NSSharingServiceNameComposeEmail]] == (id)delegate;
            [picker hide];
        });
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), hideTimer, kCFRunLoopCommonModes);

        __block NSUInteger completionCount = 0;
        __block NSSharingService *completedService = (NSSharingService *)@"unset";
        [picker showPopoverRelativeToRect:NSMakeRect(10, 10, 1, 1) ofView:view preferredEdge:NSMinYEdge completion:^(NSSharingService *service) {
            ++completionCount;
            completedService = service;
        }];
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        CFRunLoopTimerInvalidate(hideTimer);
        CFRelease(hideTimer);

        check("the services menu was shown", menuTracked);
        check("delegate messages reach the client's delegate while shown", delegateForwarded);
        check("hide closed the menu and the completion ran once", completionCount == 1);
        check("the completion reports no service", !completedService);
        check("the delegate heard that nothing was chosen", delegate.chooseCount == 1 && delegate.choseNothing);
        check("the client's delegate is back in place", [picker delegate] == delegate);

        __block BOOL handlerRan = NO;
        ProbeDelegate *choosingDelegate = [ProbeDelegate new];
        choosingDelegate.offeredService = [[[NSSharingService alloc] initWithTitle:@"Probe" image:[NSImage imageNamed:NSImageNameShareTemplate] alternateImage:nil handler:^{
            handlerRan = YES;
        }] autorelease];
        NSSharingServicePicker *choosingPicker = [[NSSharingServicePicker alloc] initWithItems:@[ [NSURL URLWithString:@"https://webkit.org/"] ]];
        // Keystrokes reach a menu only in the active application.
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyWindow];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        [choosingPicker setDelegate:choosingDelegate];

        CFRunLoopTimerRef chooseTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.5, 0, 0, 0, ^(__unused CFRunLoopTimerRef timer) {
            postKey(125); // Down arrow: highlight the only item.
            postKey(36); // Return: choose it.
        });
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), chooseTimer, kCFRunLoopCommonModes);
        CFRunLoopTimerRef stuckTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 10, 0, 0, 0, ^(__unused CFRunLoopTimerRef timer) {
            [choosingPicker hide];
        });
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), stuckTimer, kCFRunLoopCommonModes);

        __block NSUInteger choiceCompletionCount = 0;
        __block NSSharingService *choiceCompletedService = nil;
        [choosingPicker showPopoverRelativeToRect:NSMakeRect(10, 10, 1, 1) ofView:view preferredEdge:NSMinYEdge completion:^(NSSharingService *service) {
            ++choiceCompletionCount;
            choiceCompletedService = [service retain];
        }];
        CFRunLoopTimerInvalidate(chooseTimer);
        CFRelease(chooseTimer);
        CFRunLoopTimerInvalidate(stuckTimer);
        CFRelease(stuckTimer);

        check("the completion ran once for a choice", choiceCompletionCount == 1);
        // ShareKit hands back its own instance for an offered service, so the choice is known by its title.
        check("the delegate heard the chosen service", choosingDelegate.chooseCount == 1 && [choosingDelegate.chosenService.title isEqualToString:@"Probe"]);
        check("the completion reports the service the delegate heard", choiceCompletedService && choiceCompletedService == choosingDelegate.chosenService);
        check("the service's delegate came from the client's delegate", choosingDelegate.serviceDelegateRequests > 0);
        check("the chosen service ran", handlerRan);
        check("the client's delegate is back in place after a choice", [choosingPicker delegate] == choosingDelegate);
    }
    return failures ? 1 : 0;
}
