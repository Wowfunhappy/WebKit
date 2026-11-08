// The task-metrics relay (polyfills/webkit/task_metrics.mm): every session a WebKit image creates records
// its tasks' transactions, whichever creator made it and whether or not it was given a delegate, and the
// session's -delegate answers the object passed at creation. The probe is a WebKit-marked image, so its
// selectors are rewritten the way WebKit's are.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <unistd.h>

@interface NSURLSessionTask (WKTaskMetricsRelayProbe)
- (id)_incompleteTaskMetrics;
@end

@interface WKTaskMetricsRelayProbeDelegate : NSObject <NSURLSessionDataDelegate>
@end
@implementation WKTaskMetricsRelayProbeDelegate
@end

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-66s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

// Runs one data task to completion and answers whether its metrics recorded the response.
static BOOL recordsResponse(NSURLSession *session, NSURL *url)
{
    NSURLSessionDataTask *task = [session dataTaskWithURL:url];
    [task resume];
    for (int i = 0; i < 500 && task.state != NSURLSessionTaskStateCompleted; i++)
        usleep(10000);
    id metrics = [task _incompleteTaskMetrics];
    NSArray *transactions = [metrics valueForKey:@"transactionMetrics"];
    id transaction = transactions.lastObject;
    return task.state == NSURLSessionTaskStateCompleted && transactions.count == 1
        && [transaction valueForKey:@"responseStartDate"] && [transaction valueForKey:@"response"];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[0]]];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];

        WKTaskMetricsRelayProbeDelegate *delegate = [[[WKTaskMetricsRelayProbeDelegate alloc] init] autorelease];
        NSURLSession *withDelegate = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
        check(withDelegate.delegate == delegate, "-delegate answers the delegate passed to the creator");
        check(recordsResponse(withDelegate, url), "a session with a delegate records its task's response");

        NSURLSession *nilDelegate = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:nil];
        check(!nilDelegate.delegate, "-delegate answers nil for a session created without one");
        check(recordsResponse(nilDelegate, url), "a session without a delegate records its task's response");

        NSURLSession *oneArgument = [NSURLSession sessionWithConfiguration:configuration];
        check(!oneArgument.delegate, "+sessionWithConfiguration: makes a session without a delegate");
        check(recordsResponse(oneArgument, url), "+sessionWithConfiguration:'s session records its task's response");

        [withDelegate invalidateAndCancel];
        [nilDelegate invalidateAndCancel];
        [oneArgument invalidateAndCancel];
    }
    if (failures)
        printf("task metrics relay probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
