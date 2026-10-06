// Concurrent loads over a server whose certificate the client accepts per task.
//
// A task against an untrusted certificate raises a server-trust challenge and restarts once the client
// accepts it, and with no exception recorded it is the task that opens a connection which pays one --
// which is what a test runner drives for a whole page, the document and its subresources challenging
// and restarting while the others are in flight. Expects the fixture on 19446
// (cocoa-curl-tls-fixtures.py serve, self-signed).
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
static unsigned outstanding;
static void check(bool value, const char* message) { if (!value) { ++failures; printf("FAIL %s\n", message); } }

@interface TrustProbe : NSObject <_WKDataTaskDelegate> {
@public
    NSString* label;
    _WKDataTask* task;
    unsigned challenges;
    NSUInteger bytes;
    NSInteger status;
    NSInteger errorCode;
    bool completed;
}
@end

@implementation TrustProbe
- (void)dataTask:(_WKDataTask*)value didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential*))completion
{
    ++challenges;
    check([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust], "server-trust protection space");
    completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
}
- (void)dataTask:(_WKDataTask*)value didReceiveResponse:(NSURLResponse*)response decisionHandler:(void (^)(_WKDataTaskResponsePolicy))decision
{
    status = [(NSHTTPURLResponse*)response statusCode];
    decision(_WKDataTaskResponsePolicyAllow);
}
- (void)dataTask:(_WKDataTask*)value didReceiveData:(NSData*)data { bytes += data.length; }
- (void)dataTask:(_WKDataTask*)value didCompleteWithError:(NSError*)error
{
    check(!completed, "one terminal callback");
    errorCode = error.code;
    completed = true;
    if (!--outstanding)
        CFRunLoopStop(CFRunLoopGetMain());
}
@end

static TrustProbe* startTask(WKWebView* view, NSString* label, NSString* url)
{
    TrustProbe* probe = [TrustProbe new];
    probe->label = label;
    ++outstanding;
    [view _dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]] completionHandler:^(_WKDataTask* created) {
        probe->task = created;
        created.delegate = probe;
    }];
    return probe;
}

// A task pays its own challenge when it opens a connection, and none when it takes one another task
// left in the pool, so a burst's total is what is fixed and each member's is not. More than one on a
// single task would mean the certificate it accepted did not carry into the transfer it restarted.
static void report(TrustProbe* probe, unsigned leastChallenges)
{
    printf("%s status=%ld bytes=%lu challenges=%u error=%ld\n", probe->label.UTF8String, (long)probe->status,
        (unsigned long)probe->bytes, probe->challenges, (long)probe->errorCode);
    check(probe->completed, "task completed");
    check(!probe->errorCode, "task carried no error");
    check(probe->status == 200, "task saw 200");
    check(probe->bytes > 0, "task received a body");
    check(probe->challenges >= leastChallenges, "task was challenged for the server's certificate");
    check(probe->challenges <= 1, "task was challenged at most once");
}

int main(int argc, const char** argv)
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        NSString* base = argc > 1 ? @(argv[1]) : @"https://127.0.0.1:19446";
        NSString* documentPath = argc > 5 ? @(argv[2]) : @"/document";
        NSArray<NSString*>* subresources = argc > 5
            ? @[ @(argv[3]), @(argv[4]), @(argv[5]) ] : @[ @"/a.js", @"/b.js", @"/c.js" ];
        [NSApplication sharedApplication];
        WKWebViewConfiguration* configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        WKWebView* view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:configuration];

        // One task on its own, as a document is fetched before anything it references.
        // The first task always opens the connection, so its challenge is the one this fixture's
        // certificate is guaranteed to raise; without it the run would pass against a trusted server
        // having tested nothing.
        TrustProbe* first = startTask(view, @"document", [base stringByAppendingString:documentPath]);
        CFRunLoopRun();
        report(first, 1);

        // Then the burst that document would start, each on a connection of its own or on the one the
        // document left in the pool.
        TrustProbe* a = startTask(view, @"subresource-a", [base stringByAppendingString:subresources[0]]);
        TrustProbe* b = startTask(view, @"subresource-b", [base stringByAppendingString:subresources[1]]);
        TrustProbe* c = startTask(view, @"subresource-c", [base stringByAppendingString:subresources[2]]);
        CFRunLoopRun();
        report(a, 0);
        report(b, 0);
        report(c, 0);
        check(a->challenges + b->challenges + c->challenges >= 1, "the burst opened a connection of its own");

        printf("cocoa-curl-tls-concurrent: %s\n", failures ? "FAILED" : "passed");
        return failures ? 1 : 0;
    }
}
