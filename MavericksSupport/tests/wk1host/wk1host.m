// A minimal WebKit1 host: one WebView in one window, loading the URL given on the command line.
// Console messages, alerts and load failures go to stdout, so a WK1-only bug can be driven and
// read from a shell. Build with build.sh.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface Host : NSObject
@end

@implementation Host

- (void)webView:(WebView *)sender addMessageToConsole:(NSDictionary *)message
{
    printf("CONSOLE %s:%s %s\n",
        [[[message objectForKey:@"sourceURL"] description] UTF8String] ?: "-",
        [[[message objectForKey:@"lineNumber"] description] UTF8String] ?: "-",
        [[[message objectForKey:@"message"] description] UTF8String] ?: "-");
    fflush(stdout);
}

- (void)webView:(WebView *)sender addMessageToConsole:(NSDictionary *)message withSource:(NSString *)source
{
    [self webView:sender addMessageToConsole:message];
}

- (void)webView:(WebView *)sender runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame
{
    printf("ALERT %s\n", [message UTF8String]);
    fflush(stdout);
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    printf("LOADED %s\n", [[[[[frame dataSource] request] URL] absoluteString] UTF8String]);
    fflush(stdout);
}

- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    printf("LOADFAIL %s\n", [[error description] UTF8String]);
    fflush(stdout);
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    printf("LOADFAIL %s\n", [[error description] UTF8String]);
    fflush(stdout);
}

@end

int main(int argc, const char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "usage: wk1host <url> [seconds]\n");
        return 2;
    }
    double seconds = argc > 2 ? atof(argv[2]) : 15;

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 1000, 700)
            styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
            backing:NSBackingStoreBuffered defer:NO];
        WebView *webView = [[WebView alloc] initWithFrame:[[window contentView] bounds]];
        Host *host = [[Host alloc] init];
        [webView setUIDelegate:host];
        [webView setFrameLoadDelegate:host];
        [window setContentView:webView];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        [[webView mainFrame] loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]]]];

        [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:seconds];
        [NSApp run];
    }
    return 0;
}
