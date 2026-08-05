// The Objective-C garbage-collection regression test for github #118.
//
// Xcode 4 is the app that reported the bug: it is compiled -fobjc-gc, so the objc runtime
// enables collection for the process and then refuses to load any image that is not marked
// GC-capable. Xcode 4 is not installed on this VM and is a poor test subject anyway, so this
// stands in for it -- a plain Cocoa app that drives a WebView the way Xcode's documentation
// viewer does, while collecting far harder than any real app would.
//
// It is built WITHOUT -fobjc-gc (modern clang removed that mode); build.sh sets the
// REQUIRES_GC bit in its __objc_imageinfo afterwards, which is what actually makes the
// runtime collect. See MavericksSupport/polyfill/polyfills/objc-gc.c for the support layer
// this exercises.
//
// Exits 0 only after three real page loads, a JavaScript evaluation with a checked result,
// and an exhaustive collection between each. Any crash is the regression.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface GCTestDelegate : NSObject
{
    int _loads;
}
@end

@implementation GCTestDelegate

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    _loads++;
    fprintf(stderr, "LOAD %d FINISHED title='%s'\n", _loads, [[sender mainFrameTitle] UTF8String]);

    // Collect while the page's objects are live: anything WebKit holds only from C++ or from
    // a barrier-less static is a candidate to be freed out from under it here.
    [[NSGarbageCollector defaultCollector] collectExhaustively];

    if (_loads == 1) {
        [[sender mainFrame] loadRequest:[NSURLRequest requestWithURL:
            [NSURL URLWithString:@"https://example.com/"]]];
    } else if (_loads == 2) {
        // Exercises the JSVirtualMachine wrapper cache, which was one of the crash sites.
        NSString *js = [sender stringByEvaluatingJavaScriptFromString:
            @"document.title + ' / ' + document.links.length + ' links'"];
        fprintf(stderr, "JS RESULT: %s\n", [js UTF8String]);
        if (![js length]) {
            fprintf(stderr, "FAILED: JavaScript evaluation returned nothing\n");
            exit(1);
        }
        [[sender mainFrame] loadHTMLString:
            @"<html><body onload=\"document.title='inline-ok'\">"
             "<h1>GC test page</h1><script>var a=[];for(var i=0;i<1000;i++)"
             "a.push({n:i,s:'str'+i});</script></body></html>"
            baseURL:nil];
    } else {
        [[NSGarbageCollector defaultCollector] collectExhaustively];
        fprintf(stderr, "ALL LOADS OK\n");
        exit(0);
    }
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    fprintf(stderr, "FAILED: load error: %s\n", [[error description] UTF8String]);
    exit(1);
}

- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    fprintf(stderr, "FAILED: provisional load error: %s\n", [[error description] UTF8String]);
    exit(1);
}

@end

int main(void)
{
    [NSApplication sharedApplication];

    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(100, 100, 800, 600)
        styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    WebView *webView = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    GCTestDelegate *delegate = [[GCTestDelegate alloc] init];
    [webView setFrameLoadDelegate:(id)delegate];
    [[window contentView] addSubview:webView];
    [window makeKeyAndOrderFront:nil];

    if (![NSGarbageCollector defaultCollector]) {
        fprintf(stderr, "FAILED: this process is not collecting -- the REQUIRES_GC bit is "
            "missing from the test binary (build.sh sets it)\n");
        return 1;
    }
    fprintf(stderr, "GC enabled\n");

    [[webView mainFrame] loadRequest:[NSURLRequest requestWithURL:
        [NSURL URLWithString:@"https://www.apple.com/"]]];

    // Keep the collector busy between page loads, and fail rather than hang if the network
    // (or a wedged WebKit) never completes a load.
    [NSTimer scheduledTimerWithTimeInterval:0.5
        target:[NSGarbageCollector defaultCollector]
        selector:@selector(collectIfNeeded) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:60 target:[NSApplication sharedApplication]
        selector:@selector(terminate:) userInfo:nil repeats:NO];

    [NSApp run];
    return 0;
}
