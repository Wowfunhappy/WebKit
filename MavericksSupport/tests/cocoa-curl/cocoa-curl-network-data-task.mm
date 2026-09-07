// Exercise the API data-task route through NetworkDataTaskCocoa.
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
@interface DataTaskProbe : NSObject <_WKDataTaskDelegate> {
@public
    _WKDataTask* task;
    unsigned redirects;
    unsigned challenges;
    NSUInteger bytes;
    NSMutableData* body;
    NSInteger status;
    NSInteger errorCode;
    bool completed;
    bool responseReceived;
}
- (void)deadline;
@end
@implementation DataTaskProbe
- (void)dataTask:(_WKDataTask*)value didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential*))completion
{
    ++challenges;
    check([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic], "native API Basic protection space");
    completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialWithUser:@"curl-test" password:@"correct-password" persistence:NSURLCredentialPersistenceNone]);
}
- (void)dataTask:(_WKDataTask*)value willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request decisionHandler:(void (^)(_WKDataTaskRedirectPolicy))decision
{
    ++redirects;
    decision(_WKDataTaskRedirectPolicyAllow);
}
- (void)dataTask:(_WKDataTask*)value didReceiveResponse:(NSURLResponse*)response decisionHandler:(void (^)(_WKDataTaskResponsePolicy))decision
{
    check(!responseReceived, "one API response decision");
    responseReceived = true;
    status = [(NSHTTPURLResponse*)response statusCode];
    decision(_WKDataTaskResponsePolicyAllow);
}
- (void)dataTask:(_WKDataTask*)value didReceiveData:(NSData*)data
{
    check(responseReceived, "API data follows response policy");
    bytes += data.length;
    [body appendData:data];
}
- (void)dataTask:(_WKDataTask*)value didCompleteWithError:(NSError*)error
{
    check(!completed, "one API terminal callback");
    errorCode = error.code;
    completed = true;
    CFRunLoopStop(CFRunLoopGetMain());
}
- (void)deadline
{
    check(false, "API task deadline");
    [task cancel];
    CFRunLoopStop(CFRunLoopGetMain());
}
@end
int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        [NSApplication sharedApplication];
        WKWebViewConfiguration* configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        WKWebView* view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:configuration];
        struct Case { NSString* url; NSInteger error; NSUInteger bytes; unsigned redirects; unsigned challenges; NSString* echoedTarget; };
        Case cases[] = {
            { @"http://127.0.0.1:18981/probe/baseline", 0, 5, 0, 0 },
            { @"http://127.0.0.1:18981/probe/chunk_short_data", NSURLErrorNetworkConnectionLost, 3, 0, 0 },
            { @"http://127.0.0.1:18981/probe/redirect_limit_20", 0, 0, 20, 0, @"/echo/redirect_done_20" },
            { @"http://127.0.0.1:18981/probe/redirect_limit_21", NSURLErrorHTTPTooManyRedirects, 0, 20, 0 },
            { @"http://127.0.0.1:18982/basic", 0, 2097152, 0, 1 },
        };
        for (auto& item : cases) {
            DataTaskProbe* probe = [DataTaskProbe new];
            probe->body = [NSMutableData new];
            [view _dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:item.url]] completionHandler:^(_WKDataTask* task) {
                probe->task = [task retain];
                task.delegate = probe;
            }];
            NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:60 target:probe selector:@selector(deadline) userInfo:nil repeats:NO];
            CFRunLoopRun();
            [timer invalidate];
            check(probe->completed, "API task completed");
            check(probe->errorCode == item.error, "API task preserves the transport error");
            if (item.echoedTarget) {
                NSDictionary* echo = [NSJSONSerialization JSONObjectWithData:probe->body options:0 error:nil];
                check([echo[@"target"] isEqualToString:item.echoedTarget] && [echo[@"method"] isEqualToString:@"GET"], "API redirect reaches the actual final request");
            } else
                check(probe->bytes == item.bytes, "API task delivers the exact body length");
            check(probe->redirects == item.redirects, "API task owns the WebKit redirect limit");
            check(probe->challenges == item.challenges, "API task native challenge contract");
            printf("API task %s status=%ld bytes=%lu redirects=%u challenges=%u error=%ld\n", item.url.UTF8String, (long)probe->status, (unsigned long)probe->bytes, probe->redirects, probe->challenges, (long)probe->errorCode);
            probe->task.delegate = nil;
            [probe->task release];
            [probe->body release];
            [probe release];
        }
        printf("Cocoa curl WK2 API data task: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
