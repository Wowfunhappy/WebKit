// Page WebSockets in a WKWebView, for the cocoa-curl-websocket-* programs. A case's script runs in a page of the
// origin it names and drives its sockets with socketEvents(url, options), which records each socket's events as
// "open", "message:<text>", "binary:<bytes>", "error" and "close:<code>"; the case resolves window.__result, which
// runWebSocketPage returns as JSON. The view's authentication challenges go to the delegate's handler.
#import <Cocoa/Cocoa.h>
#import <WebKit/WKNavigationDelegate.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKWebsiteDataStore.h>
#include <cstdio>

@interface _WKWebsiteDataStoreConfiguration : NSObject
- (instancetype)initNonPersistentConfiguration;
@property (nonatomic, copy) NSDictionary *proxyConfiguration;
@end

@interface WKWebsiteDataStore (WebSocketPageConfiguration)
- (instancetype)_initWithConfiguration:(_WKWebsiteDataStoreConfiguration *)configuration;
@end

typedef void (^WebSocketChallengeAnswer)(NSURLSessionAuthChallengeDisposition, NSURLCredential *);

@interface WebSocketPageDelegate : NSObject <WKNavigationDelegate>
@property (nonatomic, copy) void (^challengeHandler)(NSURLAuthenticationChallenge *, WebSocketChallengeAnswer);
@end

@implementation WebSocketPageDelegate
- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(WebSocketChallengeAnswer)completionHandler
{
    if (self.challengeHandler)
        self.challengeHandler(challenge, completionHandler);
    else
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

static WKWebView *makeWebSocketView(WebSocketPageDelegate *delegate, NSDictionary *proxyConfiguration = nil)
{
    [NSApplication sharedApplication];
    _WKWebsiteDataStoreConfiguration *storeConfiguration = [[_WKWebsiteDataStoreConfiguration alloc] initNonPersistentConfiguration];
    if (proxyConfiguration)
        storeConfiguration.proxyConfiguration = proxyConfiguration;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = [[WKWebsiteDataStore alloc] _initWithConfiguration:storeConfiguration];
    WKWebView *view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:configuration];
    view.navigationDelegate = delegate;
    return view;
}

static NSString *const webSocketPagePrelude = @"<script>\n"
    "window.__result = undefined;\n"
    "function socketEvents(url, options) {\n"
    "    options = options || {};\n"
    "    return new Promise(resolve => {\n"
    "        const events = [];\n"
    "        let socket, settleTimer;\n"
    "        const finish = () => { clearTimeout(timer); clearTimeout(settleTimer); resolve({ events, socket }); };\n"
    "        const settle = () => { if (options.settle) { clearTimeout(settleTimer); settleTimer = setTimeout(finish, options.settle); } };\n"
    "        const timer = setTimeout(() => { events.push('timeout'); finish(); }, options.timeout || 15000);\n"
    "        try { socket = new WebSocket(url); } catch (error) { events.push('throw:' + error.name); finish(); return; }\n"
    "        socket.binaryType = 'arraybuffer';\n"
    "        if (options.onCreate) options.onCreate(socket, events);\n"
    "        socket.onopen = () => { events.push('open'); settle(); if (options.onOpen) options.onOpen(socket, events); };\n"
    "        socket.onmessage = event => { events.push(typeof event.data === 'string' ? 'message:' + event.data : 'binary:' + event.data.byteLength); settle(); if (options.onMessage) options.onMessage(socket, event, events); };\n"
    "        socket.onerror = () => events.push('error');\n"
    "        socket.onclose = event => { events.push('close:' + event.code); finish(); };\n"
    "    });\n"
    "}\n"
    "</script>\n";

// The value of |expression| in the page whose window.__runId is |runId|, once it is a string, or nil after |timeout| seconds.
static NSString *pageString(WKWebView *view, NSString *runId, NSString *expression, NSTimeInterval timeout)
{
    NSString *poll = [NSString stringWithFormat:@"window.__runId === '%@' && typeof (%@) === 'string' ? (%@) : null", runId, expression, expression];
    __block NSString *result = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!result && deadline.timeIntervalSinceNow > 0) {
        __block bool answered = false;
        [view evaluateJavaScript:poll completionHandler:^(id value, NSError *) {
            if ([value isKindOfClass:[NSString class]])
                result = [value copy];
            answered = true;
        }];
        while (!answered && deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if (!result)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return result;
}

// Loads the case's script in a page of |origin| and returns what it resolved window.__result with, as JSON, or nil
// when it did not resolve within |timeout| seconds. The previous case's page is replaced by a blank one first, which
// closes its sockets before this case begins.
static NSString *runWebSocketPage(WKWebView *view, NSString *origin, NSString *script, NSTimeInterval timeout = 30)
{
    NSString *blankId = [[NSUUID UUID] UUIDString];
    [view loadHTMLString:[NSString stringWithFormat:@"<script>window.__runId = '%@'; window.__ready = 'ready';</script>", blankId] baseURL:[NSURL URLWithString:@"about:blank"]];
    pageString(view, blankId, @"window.__ready", 10);
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];

    NSString *runId = [[NSUUID UUID] UUIDString];
    NSString *html = [NSString stringWithFormat:@"<!DOCTYPE html><script>window.__runId = '%@';</script>%@<script>\n(async () => { try { window.__result = JSON.stringify(await (async () => {\n%@\n})()); } catch (error) { window.__result = JSON.stringify('threw ' + error); } })();\n</script>", runId, webSocketPagePrelude, script];
    [view loadHTMLString:html baseURL:[NSURL URLWithString:origin]];
    return pageString(view, runId, @"window.__result", timeout);
}

static unsigned webSocketFailures;

static void expectResult(const char *what, NSString *seen, NSString *expected)
{
    bool passed = [seen isEqualToString:expected];
    printf("%s: expected [%s] got [%s] %s\n", what, expected.UTF8String, seen.UTF8String ?: "(no result)", passed ? "PASS" : "FAIL");
    webSocketFailures += !passed;
}

static void expectTrue(const char *what, bool passed, NSString *detail)
{
    printf("%s: %s %s\n", what, detail.UTF8String ?: "", passed ? "PASS" : "FAIL");
    webSocketFailures += !passed;
}
