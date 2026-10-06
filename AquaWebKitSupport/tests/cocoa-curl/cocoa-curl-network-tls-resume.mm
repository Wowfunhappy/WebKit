// TLS session resumption in the network process. A certificate a client accepts from inside the
// handshake, by answering one task's server-trust challenge, covers that task alone: the session it
// established is never resumed, so the next task meets the certificate again. A platform-trusted
// session is resumed. Every load asks the fixture to close its connection, so the partition holds no
// connection between loads and each one opens its own, offering whatever session the partition's cache
// kept.
// Expects the root-signed fixture on 19445 and the self-signed one on 19446 (cocoa-curl-tls-fixtures.py).
#import <Cocoa/Cocoa.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKWebsiteDataStore.h>
#import "_WKDataTask.h"
#import "_WKDataTaskDelegate.h"
#include <cstdio>

@interface WKWebView (DataTaskFixture)
- (void)_dataTaskWithRequest:(NSURLRequest*)request completionHandler:(void (^)(_WKDataTask*))completion;
@end

static unsigned failures;
static void check(bool value, const char* message) { if (!value) { ++failures; printf("FAIL %s\n", message); } }

@interface ResumeProbe : NSObject <_WKDataTaskDelegate> {
@public
    _WKDataTask* task;
    unsigned challenges;
    NSInteger status;
    NSInteger errorCode;
    NSString* reused;
    bool completed;
}
@end

@implementation ResumeProbe
- (void)dataTask:(_WKDataTask*)value didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential*))completion
{
    ++challenges;
    completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
}
- (void)dataTask:(_WKDataTask*)value didReceiveResponse:(NSURLResponse*)response decisionHandler:(void (^)(_WKDataTaskResponsePolicy))decision
{
    NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
    status = http.statusCode;
    [http.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSString* field, BOOL*) {
        if ([name caseInsensitiveCompare:@"X-TLS-Session-Reused"] == NSOrderedSame)
            reused = field;
    }];
    decision(_WKDataTaskResponsePolicyAllow);
}
- (void)dataTask:(_WKDataTask*)value didReceiveData:(NSData*)data { }
- (void)dataTask:(_WKDataTask*)value didCompleteWithError:(NSError*)error
{
    errorCode = error.code;
    completed = true;
    CFRunLoopStop(CFRunLoopGetMain());
}
@end

static ResumeProbe* load(WKWebView* view, NSString* url)
{
    ResumeProbe* probe = [ResumeProbe new];
    [view _dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]] completionHandler:^(_WKDataTask* created) {
        probe->task = created;
        created.delegate = probe;
    }];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 15, false);
    printf("%s status=%ld reused=%s challenges=%u error=%ld\n", url.UTF8String, (long)probe->status,
        probe->reused.UTF8String ?: "-", probe->challenges, (long)probe->errorCode);
    check(probe->completed && !probe->errorCode && probe->status == 200, "task completed with 200");
    return probe;
}

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        [NSApplication sharedApplication];
        WKWebViewConfiguration* configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        WKWebView* view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:configuration];

        ResumeProbe* trustedFull = load(view, @"https://localhost:19445/full?close");
        check([trustedFull->reused isEqualToString:@"0"], "trusted chain: first connection completes a full handshake");
        ResumeProbe* trustedResumed = load(view, @"https://localhost:19445/resumed?close");
        check([trustedResumed->reused isEqualToString:@"1"], "trusted chain: second connection resumes the session");
        check(!trustedResumed->challenges, "trusted chain: resumed connection raises no challenge");

        ResumeProbe* accepted = load(view, @"https://127.0.0.1:19446/accepted?close");
        check(accepted->challenges == 1, "accepted challenge: the first task is challenged");
        ResumeProbe* next = load(view, @"https://127.0.0.1:19446/next?close");
        check(next->challenges == 1, "accepted challenge: the next task is challenged again");
        check([next->reused isEqualToString:@"0"], "accepted challenge: the excepted session is not resumed");

        printf("cocoa-curl-network-tls-resume: %s\n", failures ? "FAILED" : "passed");
        return failures ? 1 : 0;
    }
}
