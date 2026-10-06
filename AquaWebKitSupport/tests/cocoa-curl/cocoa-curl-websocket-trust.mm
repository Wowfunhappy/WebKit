// Compare the WebSocket polyfill's server-trust decisions with Mavericks' native NSURLSession.
// run.sh supplies a trusted root-signed server on 19445 and an untrusted server on 19446.
#import <WebKit/WKWebView.h>
#import <Security/Security.h>
#import <wtf/RetainPtr.h>
#include <cstdio>

@interface WKWebSocketStream : NSObject
- (instancetype)initWithRequest:(NSURLRequest *)request protocol:(NSString *)protocol session:(NSURLSession *)session taskIdentifier:(NSUInteger)identifier;
- (void)receiveMessageWithCompletionHandler:(void (^)(id, NSError *))handler;
- (void)resume;
- (void)cancel;
@end

@interface TrustDelegate : NSObject <NSURLSessionTaskDelegate>
@property NSURLSessionAuthChallengeDisposition answer;
@property BOOL supplyCredential;
@property BOOL trusted;
@property BOOL onMainThread;
@property NSUInteger challenges;
@end

@implementation TrustDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion
{
    ++_challenges;
    _onMainThread = [NSThread isMainThread];
    SecTrustResultType result = kSecTrustResultInvalid;
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    _trusted = SecTrustEvaluate(trust, &result) == errSecSuccess
        && (result == kSecTrustResultProceed || result == kSecTrustResultUnspecified);
    completion(_answer, _supplyCredential ? [NSURLCredential credentialForTrust:trust] : nil);
}
@end

static bool run(bool websocket, bool trusted, NSURLSessionAuthChallengeDisposition answer, bool supplyCredential, bool hasDelegate, bool expected)
{
    auto delegate = adoptNS([TrustDelegate new]);
    delegate.get().answer = answer;
    delegate.get().supplyCredential = supplyCredential;
    auto configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.connectionProxyDictionary = @{};
    auto session = retainPtr([NSURLSession sessionWithConfiguration:configuration delegate:hasDelegate ? delegate.get() : nil delegateQueue:[NSOperationQueue mainQueue]]);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%s://127.0.0.1:%d/%s", websocket ? "wss" : "https", trusted ? 19445 : 19446, websocket ? "websocket" : ""]];
    __block bool done = false;
    __block bool received = false;
    RetainPtr<WKWebSocketStream> stream;
    RetainPtr<NSURLSessionDataTask> dataTask;
    if (websocket) {
        stream = adoptNS([(WKWebSocketStream *)[NSClassFromString(@"WKWebSocketStream") alloc] initWithRequest:[NSURLRequest requestWithURL:url] protocol:nil session:session.get() taskIdentifier:1]);
        [stream receiveMessageWithCompletionHandler:^(id message, NSError *error) {
            received = !error && [[message valueForKey:@"string"] isEqualToString:@"mTLS"];
            done = true;
        }];
        [stream resume];
    } else {
        dataTask = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            received = !error && [(NSHTTPURLResponse *)response statusCode] == 200
                && [data isEqualToData:[@"mTLS" dataUsingEncoding:NSUTF8StringEncoding]];
            done = true;
        }];
        [dataTask resume];
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    bool passed = done && received == expected && delegate.get().challenges == (hasDelegate ? 1u : 0u)
        && (!hasDelegate || (delegate.get().trusted == trusted && delegate.get().onMainThread));
    printf("%s trusted=%d disposition=%ld credential=%d delegate=%d received=%d: %s\n",
        websocket ? "WebSocket" : "native HTTPS", trusted, (long)answer, supplyCredential, hasDelegate, received, passed ? "PASS" : "FAIL");
    [stream cancel];
    [dataTask cancel];
    [session invalidateAndCancel];
    return passed;
}

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        // Keep the framework loaded: it registers the production WKWebSocketStream class.
        if (![WKWebView class] || !NSClassFromString(@"WKWebSocketStream"))
            return 1;
        unsigned failures = 0;
        for (bool websocket : { false, true }) {
            for (bool trusted : { false, true }) {
                failures += !run(websocket, trusted, NSURLSessionAuthChallengeUseCredential, true, true, true);
                failures += !run(websocket, trusted, NSURLSessionAuthChallengeUseCredential, false, true, trusted);
                failures += !run(websocket, trusted, NSURLSessionAuthChallengePerformDefaultHandling, false, true, trusted);
                failures += !run(websocket, trusted, NSURLSessionAuthChallengeRejectProtectionSpace, false, true, trusted);
                failures += !run(websocket, trusted, NSURLSessionAuthChallengeCancelAuthenticationChallenge, false, true, false);
                failures += !run(websocket, trusted, NSURLSessionAuthChallengePerformDefaultHandling, false, false, trusted);
            }
        }
        printf("WebSocket/native server trust: FAILED=%u\n", failures);
        return failures ? 1 : 0;
    }
}
