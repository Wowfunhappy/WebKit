// SameSite in a WebKit1 host, which is where a load runs in the application's own process rather than
// in the network process. Both modes print what the jar holds afterwards; the cookies srv.py sets have
// no expiry, so they live in the process that stored them and a second process sees nothing.
//
//   probe webkit http://localhost:18899 http://127.0.0.1:18899
//       A WebView loads A/set, then C/link, then follows the link to A/probe. That last hop is a
//       cross-site top-level GET, so srv.py's log must show laxc and nonec riding it and strictc not.
//
//   probe host http://localhost:18899
//       The application's own request, made with NSURLConnection from this same process. It carries
//       none of the cookie-policy properties WebKit stamps, so its response is stored carrying the
//       attribute the server sent and its next request is answered with every cookie the jar holds.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

// -sameSitePolicy is one of the methods WebKit reaches under a private selector, so an application
// asking for it by name is answered NO. -properties is the reader an application has: it reports the
// attribute under the same "SameSite" key a modern Foundation uses, and -comment gives back whatever
// comment the server sent.
static void printCookies(NSString *origin)
{
    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage]
        cookiesForURL:[NSURL URLWithString:origin]];
    for (NSHTTPCookie *cookie in cookies) {
        printf("STORED %s=%s SameSite=%s comment=%s\n", [[cookie name] UTF8String], [[cookie value] UTF8String],
            [[[[cookie properties] objectForKey:@"SameSite"] description] UTF8String] ?: "-",
            [[cookie comment] UTF8String] ?: "-");
    }
    fflush(stdout);
}

@interface Probe : NSObject {
@public
    NSString *originA;
    NSString *originC;
    int step;
}
@end

@implementation Probe

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    printf("LOADED %s\n", [[[[[frame dataSource] request] URL] absoluteString] UTF8String]);
    fflush(stdout);
    switch (step++) {
    case 0:
        printCookies(originA);
        [[sender mainFrame] loadRequest:[NSURLRequest requestWithURL:
            [NSURL URLWithString:[originC stringByAppendingString:@"/link"]]]];
        break;
    case 1:
        // The click is what makes the hop a top-level navigation, which is the only cross-site request
        // a Lax cookie rides.
        [sender stringByEvaluatingJavaScriptFromString:@"document.getElementById('go').click()"];
        break;
    default:
        [NSApp terminate:nil];
    }
}

- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    printf("LOADFAIL %s\n", [[error description] UTF8String]);
    fflush(stdout);
}

@end

static int webkitMode(NSString *originA, NSString *originC)
{
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 700, 500)
        styleMask:NSTitledWindowMask | NSClosableWindowMask
        backing:NSBackingStoreBuffered defer:NO];
    WebView *webView = [[WebView alloc] initWithFrame:[[window contentView] bounds]];
    Probe *probe = [[Probe alloc] init];
    probe->originA = originA;
    probe->originC = originC;
    [webView setFrameLoadDelegate:probe];
    [window setContentView:webView];
    [window makeKeyAndOrderFront:nil];
    [[webView mainFrame] loadRequest:[NSURLRequest requestWithURL:
        [NSURL URLWithString:[originA stringByAppendingString:@"/set"]]]];

    [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:20];
    [NSApp run];
    return 0;
}

static void get(NSString *url)
{
    NSURLResponse *response = nil;
    NSError *error = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]
                                        returningResponse:&response error:&error];
    if (!data) {
        printf("REQUESTFAILED %s %s\n", [url UTF8String], [[error description] UTF8String]);
        fflush(stdout);
    }
}

static int hostMode(NSString *originA)
{
    // WebKit is what carries the replacements into this process, and a WebView is what loads WebKit.
    [NSApplication sharedApplication];
    [[[WebView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)] release];

    get([originA stringByAppendingString:@"/set"]);
    get([originA stringByAppendingString:@"/setnone"]);
    printCookies(originA);
    // srv.py's log shows the Cookie header this carried.
    get([originA stringByAppendingString:@"/probe"]);
    return 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : nil;
        if ([mode isEqualToString:@"webkit"] && argc > 3) {
            return webkitMode([NSString stringWithUTF8String:argv[2]],
                              [NSString stringWithUTF8String:argv[3]]);
        }
        if ([mode isEqualToString:@"host"] && argc > 2)
            return hostMode([NSString stringWithUTF8String:argv[2]]);
        fprintf(stderr, "usage: probe webkit <originA> <originC> | probe host <originA>\n");
        return 2;
    }
}
