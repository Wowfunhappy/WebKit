// A session's invalidation is requested once: a second -invalidateAndCancel or -finishTasksAndInvalidate
// on a real __NSCFURLSession returns without reaching 10.9's method, and the delegate hears
// -URLSession:didBecomeInvalidWithError: exactly once. Each case runs in a child process, so a case that
// takes its process down is reported as a failure of that case. A class of this program's own that
// implements both selectors, the way WebCoreNSURLSession does, keeps running its own methods.
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const int iterations = 300;

@interface WKInvalidationGateDelegate : NSObject <NSURLSessionDataDelegate> {
@public
    int invalidations;
    dispatch_semaphore_t invalidated;
}
@end

@implementation WKInvalidationGateDelegate
- (instancetype)init
{
    if ((self = [super init]))
        invalidated = dispatch_semaphore_create(0);
    return self;
}
- (void)dealloc
{
    dispatch_release(invalidated);
    [super dealloc];
}
- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error
{
    ++invalidations;
    dispatch_semaphore_signal(invalidated);
}
@end

// The queue 10.9 runs a session's invalidation on. Draining it puts the first request's work behind us,
// so the second request reaches CFNetwork after the bridge has finished the first.
static dispatch_queue_t workQueue(NSURLSession *session)
{
    return ((dispatch_queue_t (*)(id, SEL))objc_msgSend)(session, sel_registerName("workQueue"));
}

@interface WKOwnInvalidationSession : NSObject {
@public
    int cancels;
    int finishes;
}
- (void)invalidateAndCancel;
- (void)finishTasksAndInvalidate;
@end

@implementation WKOwnInvalidationSession
- (void)invalidateAndCancel
{
    ++cancels;
    [self finishTasksAndInvalidate];
}
- (void)finishTasksAndInvalidate
{
    ++finishes;
}
@end

static int runCase(const char *mode)
{
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    [delegateQueue setMaxConcurrentOperationCount:1];
    for (int i = 0; i < iterations; ++i) {
        @autoreleasepool {
            WKInvalidationGateDelegate *delegate = [[[WKInvalidationGateDelegate alloc] init] autorelease];
            NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                delegate:delegate delegateQueue:delegateQueue];
            if (i % 2)
                [[session dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:9/"]]] resume];
            dispatch_queue_t queue = workQueue(session);

            if (!strcmp(mode, "back-to-back")) {
                [session invalidateAndCancel];
                [session invalidateAndCancel];
            } else if (!strcmp(mode, "race")) {
                [session invalidateAndCancel];
                dispatch_sync(queue, ^{ });
                [session invalidateAndCancel];
            } else if (!strcmp(mode, "finish-then-cancel")) {
                [session finishTasksAndInvalidate];
                dispatch_sync(queue, ^{ });
                [session invalidateAndCancel];
            } else
                return 2;

            if (dispatch_semaphore_wait(delegate->invalidated, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
                printf("    %s: session %d never became invalid\n", mode, i);
                return 1;
            }
            dispatch_sync(queue, ^{ });
            [delegateQueue waitUntilAllOperationsAreFinished];
            if (delegate->invalidations != 1) {
                printf("    %s: session %d became invalid %d times\n", mode, i, delegate->invalidations);
                return 1;
            }
        }
    }
    [delegateQueue release];
    return 0;
}

static int failures;

static void check(bool condition, const char *what)
{
    if (condition)
        return;
    printf("  FAIL: %s\n", what);
    ++failures;
}

static const char *childOutcome(const char *executable, const char *mode)
{
    char *arguments[] = { (char *)executable, (char *)mode, NULL };
    pid_t child = 0;
    if (posix_spawn(&child, executable, NULL, NULL, arguments, environ))
        return "could not be spawned";
    int status = 0;
    if (waitpid(child, &status, 0) != child)
        return "was lost";
    if (WIFSIGNALED(status))
        return strsignal(WTERMSIG(status));
    return WEXITSTATUS(status) ? "failed" : NULL;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc > 1)
            return runCase(argv[1]);

        printf("NSURLSession invalidation requested more than once:\n");
        WKOwnInvalidationSession *own = [[[WKOwnInvalidationSession alloc] init] autorelease];
        [own invalidateAndCancel];
        [own invalidateAndCancel];
        check(own->cancels == 2 && own->finishes == 2, "a WebKit-image class's own -invalidateAndCancel and -finishTasksAndInvalidate run on every call");

        const char *modes[] = { "back-to-back", "race", "finish-then-cancel" };
        for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
            const char *outcome = childOutcome(argv[0], modes[i]);
            char what[160];
            snprintf(what, sizeof(what), "%s: %d sessions each invalidate once (the case %s)", modes[i], iterations, outcome ? outcome : "passed");
            check(!outcome, what);
        }

        printf(failures ? "  %d FAILED\n" : "  ok\n", failures);
        return failures ? 1 : 0;
    }
}
