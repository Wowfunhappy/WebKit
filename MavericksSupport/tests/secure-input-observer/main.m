#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Carbon/Carbon.h>

@interface NSObject (SecureInputObserver)
- (BOOL)_secureEventInputEnabledForTesting;
@end

static void spin(double seconds)
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) {
        @autoreleasepool {
            NSEvent *event;
            while ((event = [NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate date] inMode:NSDefaultRunLoopMode dequeue:YES]))
                [NSApp sendEvent:event];
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
}

static BOOL waitTitle(WebView *view, NSString *title)
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:20];
    while (until.timeIntervalSinceNow > 0) {
        if ([[view stringByEvaluatingJavaScriptFromString:@"document.title"] isEqualToString:title])
            return YES;
        spin(0.01);
    }
    return NO;
}

static BOOL state(WebFrame *frame)
{
    return [(NSObject *)frame.frameView.documentView _secureEventInputEnabledForTesting];
}

int main(int argc, const char **argv)
{
    if (argc != 2)
        return 2;

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 500, 300) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        WebView *view = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300) frameName:nil groupName:nil];
        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        NSString *origin = [NSString stringWithFormat:@"http://127.0.0.1:%s/", argv[1]];
        NSString *childBlank = [NSString stringWithFormat:@"http://localhost:%s/blank.html", argv[1]];
        BOOL ok = YES;
        for (unsigned mainNavigation = 0; mainNavigation < 2; ++mainNavigation) {
            @autoreleasepool {
                [view.mainFrame loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"index.html" relativeToURL:[NSURL URLWithString:origin]]]];
                ok &= waitTitle(view, @"loaded");
                [NSApp activateIgnoringOtherApps:YES];
                [window makeKeyAndOrderFront:nil];
                spin(0.2);
                WebFrame *child = [view.mainFrame.childFrames firstObject];
                [window makeFirstResponder:child.frameView.documentView];
                [view stringByEvaluatingJavaScriptFromString:@"frames[0].postMessage('focus','*')"];
                ok &= waitTitle(view, @"focused");
                spin(0.2);
                printf("before %s navigation key=%d main=%d child=%d global=%d\n", mainNavigation ? "main" : "child", window.isKeyWindow, state(view.mainFrame), state(child), IsSecureEventInputEnabled());
                ok &= window.isKeyWindow && !state(view.mainFrame) && state(child) && IsSecureEventInputEnabled();
            }
            @autoreleasepool {
                if (mainNavigation)
                    [view.mainFrame loadHTMLString:@"<title>navigated</title>plain text" baseURL:[NSURL URLWithString:origin]];
                else
                    [view stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:@"document.querySelector('iframe').src='%@'", childBlank]];
                ok &= waitTitle(view, @"navigated");
            }
            spin(0.5);
            @autoreleasepool {
                printf("after %s navigation main=%d global=%d\n", mainNavigation ? "main" : "child", state(view.mainFrame), IsSecureEventInputEnabled());
                ok &= !state(view.mainFrame) && !IsSecureEventInputEnabled();
            }
        }
        puts(ok ? "PASS native child secure state and both navigation resets with normal ownership" : "FAIL native secure input");
        [view close];
        [window close];
        [view release];
        return ok ? 0 : 1;
    }
}
