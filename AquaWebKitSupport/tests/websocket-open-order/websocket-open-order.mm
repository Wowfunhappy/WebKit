// The WebSocket polyfill's open delivery against websocket-open-order-server.py: a task's open waits for the end of
// the read that carried its handshake response. Frames read with it, or a connection still up, open the task first,
// and the frames and any close or error follow. Built and run by run.sh.
#import <Foundation/Foundation.h>
#include <cmath>
#include <cstdio>
// The WebCore and polyfill-layer entry points websocket.mm reaches in WebKit's image; a ws:// handshake without
// cookies calls none of them.
extern "C" CFTypeRef WebCoreCookieCreateFromHTTPResponseField(CFStringRef, CFURLRef) { return NULL; }
extern "C" void WebCoreCookieStorageSetHTTPResponseCookies(CFTypeRef, CFArrayRef, CFURLRef, CFURLRef, bool, bool) { }
extern "C" CFTypeRef wk_createProtectionSpace(CFStringRef, int, int, CFStringRef, int, CFArrayRef, SecTrustRef) { return NULL; }
// The polyfill layer supplies this 10.13 accessor to WebKit's image.
@implementation NSHTTPURLResponse (WebSocketHarness)
- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    for (NSString *name in self.allHeaderFields) {
        if ([name caseInsensitiveCompare:field] == NSOrderedSame)
            return self.allHeaderFields[name];
    }
    return nil;
}
@end
@interface WKWebSocketStream : NSObject
- (instancetype)initWithRequest:(NSURLRequest *)request protocol:(NSString *)protocol session:(NSURLSession *)session taskIdentifier:(NSUInteger)identifier;
- (void)resume;
- (void)receiveMessageWithCompletionHandler:(void (^)(id, NSError *))handler;
- (void)cancelWithCloseCode:(NSInteger)closeCode reason:(NSData *)reason;
- (void)cancel;
- (NSURLSessionTaskState)state;
@end
@interface Recorder : NSObject <NSURLSessionTaskDelegate> {
@public
    NSMutableArray<NSString *> *events;
    BOOL finished;
    BOOL closeOnOpen;
}
@end
@implementation Recorder
- (void)URLSession:(NSURLSession *)session webSocketTask:(id)task didOpenWithProtocol:(NSString *)protocol
{
    [events addObject:@"open"];
    if (closeOnOpen)
        [(WKWebSocketStream *)task cancelWithCloseCode:4001 reason:nil];
}
- (void)URLSession:(NSURLSession *)session webSocketTask:(id)task didCloseWithCode:(NSInteger)closeCode reason:(NSData *)reason
{
    [events addObject:[NSString stringWithFormat:@"close:%ld", (long)closeCode]];
}
@end
static NSString *run(NSString *path, NSTimeInterval settle, BOOL closeOnOpen)
{
    Recorder *recorder = [Recorder new];
    recorder->events = [NSMutableArray array];
    recorder->closeOnOpen = closeOnOpen;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:recorder delegateQueue:[NSOperationQueue mainQueue]];
    NSURL *url = [NSURL URLWithString:[@"ws://127.0.0.1:18987" stringByAppendingString:path]];
    WKWebSocketStream *stream = [[NSClassFromString(@"WKWebSocketStream") alloc] initWithRequest:[NSURLRequest requestWithURL:url] protocol:nil session:session taskIdentifier:1];
    [stream resume];
    __weak Recorder *weakRecorder = recorder;
    __block void (^receive)(void);
    receive = ^{
        [stream receiveMessageWithCompletionHandler:^(id received, NSError *error) {
            Recorder *r = weakRecorder;
            if (!r)
                return;
            if (error) {
                [r->events addObject:@"error"];
                r->finished = YES;
                return;
            }
            [r->events addObject:[NSString stringWithFormat:@"message:%@", [received valueForKey:@"string"]]];
            receive();
        }];
    };
    receive();
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!recorder->finished && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSDate *settleUntil = [NSDate dateWithTimeIntervalSinceNow:settle];
    while ([settleUntil timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    [stream cancel];
    receive = nil;
    return [recorder->events componentsJoinedByString:@","];
}
// The handshake request's deadline: the request's own timeoutInterval when it was set, the session's otherwise.
static NSString *timeout(NSTimeInterval requestTimeout, NSTimeInterval sessionTimeout, NSString *pac = nil, NSString *url = @"ws://127.0.0.1:18987/no-answer", NSTimeInterval cancelAfter = 0)
{
    Recorder *recorder = [Recorder new];
    recorder->events = [NSMutableArray array];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = sessionTimeout;
    if (pac)
        configuration.connectionProxyDictionary = @{ @"ProxyAutoConfigEnable": @1, @"ProxyAutoConfigURLString": [@"http://127.0.0.1:18987" stringByAppendingString:pac] };
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:recorder delegateQueue:[NSOperationQueue mainQueue]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    if (!std::isnan(requestTimeout))
        request.timeoutInterval = requestTimeout;
    WKWebSocketStream *stream = [[NSClassFromString(@"WKWebSocketStream") alloc] initWithRequest:request protocol:nil session:session taskIdentifier:1];
    NSDate *start = [NSDate date];
    __block NSInteger code = 0;
    __block NSTimeInterval elapsed = 0;
    [stream resume];
    __block NSString *message = nil;
    [stream receiveMessageWithCompletionHandler:^(id received, NSError *error) {
        code = error ? error.code : 1;
        message = [received valueForKey:@"string"];
        elapsed = -[start timeIntervalSinceNow];
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:cancelAfter ?: 5];
    while (!code && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (cancelAfter) {
        // The task completes once its I/O queue reaches the teardown the cancel queued.
        [stream cancel];
        NSDate *cancelled = [NSDate date];
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
        while ([stream state] != NSURLSessionTaskStateCompleted && [limit timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        return [NSString stringWithFormat:@"completed:%d within-half-second:%d", [stream state] == NSURLSessionTaskStateCompleted, -[cancelled timeIntervalSinceNow] < 0.5];
    }
    [stream cancel];
    if (!code)
        return @"pending";
    if (message)
        return [NSString stringWithFormat:@"message:%@", message];
    return [NSString stringWithFormat:@"error:%ld after:%.0f", (long)code, elapsed];
}
int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        struct { NSString *path; NSTimeInterval settle; BOOL closeOnOpen; NSString *expected; const char *what; } cases[] = {
            { @"/abort", 0.5, NO, @"open,close:1006,error", "handshake then close in the same read: open, then abnormal close" },
            { @"/frame", 1.0, NO, @"open,message:hello", "handshake and a frame in one read, connection up: open, then the message" },
            { @"/late-close", 0.5, NO, @"open,close:1006,error", "handshake, close in a later read: open, then abnormal close" },
            { @"/frame-eof", 0.5, NO, @"open,message:hello,close:1006,error", "handshake, a frame and the end in one read: open, the message, then abnormal close" },
            { @"/close-1000", 0.5, NO, @"open,close:1000,error", "handshake, Close(1000) and the end in one read: open, close 1000, then the receive fails" },
            { @"/drop-client-close", 0.5, YES, @"open,close:1006,error", "peer drops TCP after the client Close: close 1006" },
            { @"/echo-client-close", 0.5, YES, @"open,close:4001,error", "peer echoes the client Close: the received code wins" },
        };
        unsigned failures = 0;
        for (auto& c : cases) {
            NSString *seen = run(c.path, c.settle, c.closeOnOpen);
            bool passed = [seen isEqualToString:c.expected];
            printf("%s: expected [%s] got [%s] %s\n", c.what, c.expected.UTF8String, seen.UTF8String, passed ? "PASS" : "FAIL");
            failures += !passed;
        }
        struct { NSTimeInterval request; NSTimeInterval session; NSString *expected; const char *what; } timeouts[] = {
            { NAN, 1, @"error:-1001 after:1", "unanswered handshake, session timeout 1 s: timed out after 1 s" },
            { 0, 1, @"pending", "unanswered handshake, request timeout 0: never times out" },
            { NAN, 0, @"pending", "unanswered handshake, session timeout 0: never times out" },
            { 1e300, 1, @"pending", "unanswered handshake, request timeout 1e300 over session 1 s: never times out" },
            { 1, 60, @"error:-1001 after:1", "unanswered handshake, request timeout 1 s: timed out after 1 s" },
            { 3, 1, @"error:-1001 after:3", "unanswered handshake, request 3 s over session 1 s: timed out after 3 s" },
        };
        struct { NSTimeInterval session; NSString *pac; NSString *url; NSTimeInterval cancelAfter; NSString *expected; const char *what; } routes[] = {
            { 1, @"/proxy.pac", @"ws://proxied.invalid/frame", 0, @"message:hello", "PAC file routes the host through an HTTP proxy" },
            { 1, @"/stalled.pac", @"ws://127.0.0.1:18987/frame", 0, @"error:-1001 after:1", "PAC file never arrives: timed out after 1 s" },
            { 0, @"/stalled.pac", @"ws://127.0.0.1:18987/frame", 0.5, @"completed:1 within-half-second:1", "PAC file never arrives, no timeout: a cancel ends the wait" },
        };
        for (auto& r : routes) {
            NSString *seen = timeout(NAN, r.session, r.pac, r.url, r.cancelAfter);
            bool passed = [seen isEqualToString:r.expected];
            printf("%s: expected [%s] got [%s] %s\n", r.what, r.expected.UTF8String, seen.UTF8String, passed ? "PASS" : "FAIL");
            failures += !passed;
        }
        for (auto& t : timeouts) {
            NSString *seen = timeout(t.request, t.session);
            bool passed = [seen isEqualToString:t.expected];
            printf("%s: expected [%s] got [%s] %s\n", t.what, t.expected.UTF8String, seen.UTF8String, passed ? "PASS" : "FAIL");
            failures += !passed;
        }
        printf("WebSocket open order: FAILED=%u\n", failures);
        return failures ? 1 : 0;
    }
}
