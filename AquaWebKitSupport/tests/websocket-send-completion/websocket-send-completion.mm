// The WebSocket polyfill's send completions against websocket-send-completion-server.py: a message's completion runs
// once the transport has written it, so it keeps pace with a slow reader (WebKit derives the page's bufferedAmount
// from it), and messages still unwritten when the task is cancelled complete once each, with an error. A message sent
// before the handshake completes waits for it; one sent after the client's Close fails. Built and run by run.sh.
#import <Foundation/Foundation.h>
#include <cstdio>
#include <vector>
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
- (void)sendMessage:(id)message completionHandler:(void (^)(NSError *))completionHandler;
- (void)receiveMessageWithCompletionHandler:(void (^)(id, NSError *))handler;
- (void)cancelWithCloseCode:(NSInteger)closeCode reason:(NSData *)reason;
- (void)cancel;
@end
@interface OpenWaiter : NSObject <NSURLSessionTaskDelegate> {
@public
    BOOL opened;
}
@end
@implementation OpenWaiter
- (void)URLSession:(NSURLSession *)session webSocketTask:(id)task didOpenWithProtocol:(NSString *)protocol
{
    opened = YES;
}
@end
static const unsigned messageSize = 64 * 1024;
struct Sends {
    std::vector<int> calls;
    std::vector<int> errors;
    std::vector<unsigned> order;
};
static void spin(NSTimeInterval seconds, BOOL (^done)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ((!done || !done()) && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
static WKWebSocketStream *create(NSString *path, OpenWaiter *waiter)
{
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:waiter delegateQueue:[NSOperationQueue mainQueue]];
    NSURL *url = [NSURL URLWithString:[@"ws://127.0.0.1:18992" stringByAppendingString:path]];
    return [[NSClassFromString(@"WKWebSocketStream") alloc] initWithRequest:[NSURLRequest requestWithURL:url] protocol:nil session:session taskIdentifier:1];
}
static WKWebSocketStream *open(NSString *path, OpenWaiter *waiter)
{
    WKWebSocketStream *stream = create(path, waiter);
    [stream resume];
    spin(5, ^{ return waiter->opened; });
    return stream;
}
static unsigned errorCount(const Sends& sends)
{
    unsigned errors = 0;
    for (int e : sends.errors)
        errors += e;
    return errors;
}
static void sendAll(WKWebSocketStream *stream, unsigned count, Sends& sends)
{
    sends.calls.assign(count, 0);
    sends.errors.assign(count, 0);
    sends.order.clear();
    NSData *payload = [NSMutableData dataWithLength:messageSize];
    Sends* record = &sends;
    for (unsigned i = 0; i < count; ++i) {
        id message = [[NSClassFromString(@"NSURLSessionWebSocketMessage") alloc] initWithData:payload];
        [stream sendMessage:message completionHandler:^(NSError *error) {
            record->calls[i]++;
            record->errors[i] += !!error;
            record->order.push_back(i);
        }];
    }
}
static unsigned completed(const Sends& sends)
{
    unsigned count = 0;
    for (int calls : sends.calls)
        count += calls > 0;
    return count;
}
static bool inOrderOnce(const Sends& sends)
{
    for (size_t i = 0; i < sends.order.size(); ++i) {
        if (sends.order[i] != i)
            return false;
    }
    for (int calls : sends.calls) {
        if (calls > 1)
            return false;
    }
    return true;
}
static unsigned check(bool passed, const char* what)
{
    printf("%s %s\n", what, passed ? "PASS" : "FAIL");
    return !passed;
}
int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        unsigned failures = 0;
        {
            // 16 MiB to a 2 MB/s reader: after one second the kernel's buffers and the reader hold a few MB.
            OpenWaiter *waiter = [OpenWaiter new];
            WKWebSocketStream *stream = open(@"/slow-sink", waiter);
            failures += check(waiter->opened, "slow sink: the task opens");
            Sends sends;
            const unsigned count = 256;
            sendAll(stream, count, sends);
            spin(1, nil);
            unsigned early = completed(sends);
            printf("slow sink: %u of %u messages complete after 1 s\n", early, count);
            failures += check(early < count / 2, "slow sink: completions wait for the writes");
            spin(30, ^{ return BOOL(completed(sends) == count); });
            failures += check(completed(sends) == count && !errorCount(sends), "slow sink: every message completes without an error");
            failures += check(inOrderOnce(sends), "slow sink: completions run once each, in send order");
            [stream cancelWithCloseCode:1000 reason:nil];
            Sends afterClose;
            sendAll(stream, 1, afterClose);
            spin(1, ^{ return BOOL(completed(afterClose) == 1); });
            failures += check(completed(afterClose) == 1 && errorCount(afterClose) == 1, "after the client's Close: a message fails");
            [stream cancel];
        }
        {
            OpenWaiter *waiter = [OpenWaiter new];
            WKWebSocketStream *stream = open(@"/stall", waiter);
            failures += check(waiter->opened, "stalled reader: the task opens");
            Sends sends;
            const unsigned count = 128;
            sendAll(stream, count, sends);
            spin(0.5, nil);
            unsigned written = completed(sends);
            printf("stalled reader: %u of %u messages complete before the cancel\n", written, count);
            failures += check(written < count, "stalled reader: unwritten messages have not completed");
            [stream cancel];
            spin(3, ^{ return BOOL(completed(sends) == count); });
            failures += check(completed(sends) == count, "stalled reader: every message completes after the cancel");
            failures += check(errorCount(sends) == count - written, "stalled reader: exactly the unwritten messages carry an error");
            failures += check(inOrderOnce(sends), "stalled reader: completions run once each, in send order");
        }
        {
            // Sent before resume: nothing reaches the server ahead of its 101, and the messages go out after it.
            OpenWaiter *waiter = [OpenWaiter new];
            WKWebSocketStream *stream = create(@"/late-open", waiter);
            Sends sends;
            const unsigned count = 4;
            sendAll(stream, count, sends);
            __block NSString *report = nil;
            [stream receiveMessageWithCompletionHandler:^(id message, NSError *) { report = [message valueForKey:@"string"]; }];
            [stream resume];
            spin(5, ^{ return BOOL(report && completed(sends) == count); });
            printf("handshake in progress: the server reports [%s]\n", report.UTF8String ?: "");
            failures += check([report isEqualToString:@"early 0"], "handshake in progress: no message precedes the 101");
            failures += check(completed(sends) == count && !errorCount(sends), "handshake in progress: the messages are written once it opens");
            failures += check(inOrderOnce(sends), "handshake in progress: completions run once each, in send order");
            [stream cancel];
        }
        printf("WebSocket send completion: FAILED=%u\n", failures);
        return failures ? 1 : 0;
    }
}
