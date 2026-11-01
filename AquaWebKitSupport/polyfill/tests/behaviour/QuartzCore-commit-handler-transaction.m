// A commit handler registered while no transaction is open still has a commit to belong to: registering
// opens the thread's implicit transaction, as CA's own registration does, so the PostCommit handler runs
// within the run-loop passes that follow even though nothing else on the thread touches a layer.
#import <QuartzCore/QuartzCore.h>

#include <stdio.h>

extern unsigned int CAGetTransactionCounter(void);

@interface CATransaction (WKCommitHandler)
+ (void)addCommitHandler:(void (^)(void))block forPhase:(NSInteger)phase;
@end

static int failures;

static void check(bool condition, const char *what)
{
    if (condition)
        return;
    fprintf(stderr, "FAIL %s\n", what);
    ++failures;
}

int main(void)
{
    @autoreleasepool {
        enum { preLayout = 0, postCommit = 2, registeringPass = 3 };
        __block int pass = 0;
        __block int preRanAtPass = -1;
        __block int postRanAtPass = -1;
        __block unsigned counterAtRegistration = 0;

        CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
            if (++pass != registeringPass)
                return;
            counterAtRegistration = CAGetTransactionCounter();
            [CATransaction addCommitHandler:^{
                preRanAtPass = pass;
            } forPhase:preLayout];
            [CATransaction addCommitHandler:^{
                postRanAtPass = pass;
            } forPhase:postCommit];
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);

        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:[NSNull null] selector:@selector(description) userInfo:nil repeats:YES];
        for (int i = 0; i < 20 && postRanAtPass < 0; ++i)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        [timer invalidate];
        CFRunLoopObserverInvalidate(observer);
        CFRelease(observer);

        check(preRanAtPass == registeringPass, "the PreLayout handler runs in the registering pass");
        check(postRanAtPass >= registeringPass && postRanAtPass <= registeringPass + 2, "the PostCommit handler runs within two passes");
        check(CAGetTransactionCounter() > counterAtRegistration, "registering opened a transaction that committed");
    }
    if (failures)
        return 1;
    printf("commit handler transaction: all cases match\n");
    return 0;
}
