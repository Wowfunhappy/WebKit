// Exercises the production WebSocket polyfill against a loopback authentication server.
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
- (void)cancel;
@end
@interface Probe : NSObject <NSURLSessionTaskDelegate> {
@public
    NSString *password;
    NSString *user;
    BOOL cancelImmediately;
    int challenges;
    NSInteger lastFailureCount;
    BOOL opened;
    BOOL done;
    NSString *message;
    NSInteger errorCode;
    NSString *method;
}
@end
@implementation Probe
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
    ++challenges;
    lastFailureCount = challenge.previousFailureCount;
    method = challenge.protectionSpace.authenticationMethod;
    if (challenge.previousFailureCount || cancelImmediately) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }
    if (!password) {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialWithUser:user password:password persistence:NSURLCredentialPersistenceNone]);
}
- (void)URLSession:(NSURLSession *)session webSocketTask:(id)task didOpenWithProtocol:(NSString *)protocol
{
    opened = YES;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    errorCode = error.code;
    done = YES;
}
@end
static Probe *run(NSString *user, NSString *password, BOOL negotiate, BOOL cancelImmediately = NO)
{
    Probe *probe = [Probe new];
    probe->password = password;
    probe->user = user;
    probe->cancelImmediately = cancelImmediately;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:probe delegateQueue:[NSOperationQueue mainQueue]];
    NSString *url = negotiate ? @"ws://127.0.0.1:18986/negotiate" : @"ws://127.0.0.1:18986/socket";
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    WKWebSocketStream *stream = [[NSClassFromString(@"WKWebSocketStream") alloc] initWithRequest:request protocol:nil session:session taskIdentifier:1];
    [stream resume];
    [stream receiveMessageWithCompletionHandler:^(id received, NSError *error) {
        probe->message = [received valueForKey:@"string"];
        if (received)
            probe->done = YES;
        if (error) {
            probe->errorCode = error.code;
            probe->done = YES;
        }
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (!probe->done && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    [stream cancel];
    return probe;
}
int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        if (argc == 2) {
            NSString *mode = [NSString stringWithUTF8String:argv[1]];
            BOOL ticketOnly = [mode isEqualToString:@"ticket"];
            BOOL cancelled = [mode isEqualToString:@"cancel"];
            if (!ticketOnly && !cancelled && ![mode isEqualToString:@"password"])
                return 2;
            NSString *principal = [NSProcessInfo processInfo].environment[@"WEBSOCKET_KERBEROS_PRINCIPAL"];
            if (!principal.length)
                return 2;
            Probe *probe = run(principal, ticketOnly ? nil : @"correct-password", YES, cancelled);
            BOOL passed = probe->challenges == 1 && [probe->method isEqualToString:NSURLAuthenticationMethodNegotiate];
            if (cancelled)
                passed &= !probe->opened && probe->errorCode == NSURLErrorUserCancelledAuthentication;
            else
                passed &= probe->opened && [probe->message isEqualToString:@"hello"];
            printf("Negotiate %s: opened=%d challenges=%d error=%ld %s\n", argv[1], probe->opened, probe->challenges, (long)probe->errorCode, passed ? "PASS" : "FAIL");
            return !passed;
        }
        unsigned failures = 0;
        Probe *good = run(@"CURL\\curl-test", @"correct-password", NO);
        bool passed = good->opened && [good->message isEqualToString:@"hello"] && good->challenges == 1 && [good->method isEqualToString:NSURLAuthenticationMethodNTLM];
        printf("NTLM correct credential: opened=%d message=%s challenges=%d method=%s %s\n", good->opened, good->message.UTF8String, good->challenges, good->method.UTF8String, passed ? "PASS" : "FAIL");
        failures += !passed;
        Probe *bad = run(@"CURL\\curl-test", @"wrong-password", NO);
        passed = !bad->opened && bad->challenges == 2 && bad->lastFailureCount == 1 && bad->errorCode == NSURLErrorUserCancelledAuthentication;
        printf("NTLM refused credential: opened=%d challenges=%d lastFailureCount=%ld error=%ld %s\n", bad->opened, bad->challenges, (long)bad->lastFailureCount, (long)bad->errorCode, passed ? "PASS" : "FAIL");
        failures += !passed;
        printf("WebSocket NTLM: FAILED=%u\n", failures);
        return failures ? 1 : 0;
    }
}
