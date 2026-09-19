// The WebSocket polyfill's open delivery against websocket-open-order-server.py: a task's open waits for the end of
// the read that carried its handshake response. Frames read with it, or a connection still up, open the task first,
// and the frames and any close or error follow. Built and run by run.sh.
#import <Foundation/Foundation.h>
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
        printf("WebSocket open order: FAILED=%u\n", failures);
        return failures ? 1 : 0;
    }
}
