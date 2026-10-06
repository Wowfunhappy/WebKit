// A WebKit1 host that touches JavaScript before it starts a load, so the JSDOMWindow for the frame's
// initial empty document exists before the real document is created. The window that services the
// loaded page must be a fresh one: the initial empty document of a main frame has no security origin
// to inherit, so a window built for it carries none of the [SecureContext] bindings. Prints one
// RESULT line: the marker planted on the early window, then what the loaded page sees.
//
// Build and run with run.sh.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <dlfcn.h>

// WTF::enableAllSDKAlignedBehaviors(), which +[WKProcessPool _setLinkedOnOrAfterEverything] calls, is
// how a host asks for the whole SDK-aligned behavior set. It postdates the 10.9 SDK this builds
// against, so it is resolved from the loaded JavaScriptCore by its mangled name.
static void enableAllSDKAlignedBehaviors(void)
{
    void (*fn)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "_ZN3WTF28enableAllSDKAlignedBehaviorsEv");
    if (!fn) {
        fprintf(stderr, "WTF::enableAllSDKAlignedBehaviors() not found in the loaded WebKit\n");
        exit(2);
    }
    fn();
}

@interface Host : NSObject
@end

@implementation Host

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    printf("RESULT %s\n", [[sender stringByEvaluatingJavaScriptFromString:
        @"[String(window.__early), typeof crypto.subtle, typeof window.SubtleCrypto,"
         "typeof window.CryptoKey, String(window.isSecureContext),"
         "typeof HTMLElement.prototype.showPopover].join(',')"] UTF8String] ?: "-");
    fflush(stdout);
    [NSApp terminate:nil];
}

- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    printf("LOADFAIL %s\n", [[error description] UTF8String]);
    fflush(stdout);
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "usage: host <url>\n");
        return 2;
    }

    @autoreleasepool {
        enableAllSDKAlignedBehaviors();

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 800, 600)
            styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        WebView *webView = [[WebView alloc] initWithFrame:[[window contentView] bounds]];
        [webView setFrameLoadDelegate:[[Host alloc] init]];
        [window setContentView:webView];
        [window makeKeyAndOrderFront:nil];

        printf("EARLY %s\n", [[webView stringByEvaluatingJavaScriptFromString:
            @"window.__early = 1; [typeof crypto.subtle, String(window.isSecureContext), location.href].join(',')"] UTF8String] ?: "-");
        fflush(stdout);

        [[webView mainFrame] loadRequest:[NSURLRequest requestWithURL:
            [NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]]]];

        [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:20];
        [NSApp run];
    }
    return 0;
}
