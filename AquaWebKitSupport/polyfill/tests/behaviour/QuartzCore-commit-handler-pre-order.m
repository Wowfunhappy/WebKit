// A pre-commit handler runs before the commit its registration precedes and after the run-loop observers at
// CA's commit order minus one that the pre observer can follow. Queued during a pass, it runs at the end of
// that pass, after an order-1 observer added earlier; queued after that pass's pre side, it runs at the end
// of the next, after one added since. WebKit's rendering-update observer sits at that same order, created on
// demand, and registers a PreLayout and a PostCommit handler from its callout: scheduled mid-pass, after the
// pre observer has run, its PreLayout handler still comes before its PostCommit one; created during the
// previous pass's BeforeWaiting, its PreLayout handler runs from the pre observer once its callout returns.
#import <QuartzCore/QuartzCore.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface CATransaction (WKCommitHandler)
+ (void)addCommitHandler:(void (^)(void))block forPhase:(NSInteger)phase;
@end

enum { kCommitOrder = 2000000, kPreLayoutPhase = 0, kPreCommitPhase = 1, kPostCommitPhase = 2 };

static char sequence[2048];
static int failures;

static void note(const char *what)
{
    strlcat(sequence, what, sizeof(sequence));
    strlcat(sequence, " ", sizeof(sequence));
}

static void check(bool condition, const char *what)
{
    printf("  %-74s %s\n", what, condition ? "ok" : "FAIL");
    if (!condition)
        ++failures;
}

static CFRunLoopObserverRef addObserver(CFIndex order, const char *name)
{
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, order,
        ^(CFRunLoopObserverRef, CFRunLoopActivity) { note(name); });
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), observer, kCFRunLoopCommonModes);
    return observer;
}

static void removeObserver(CFRunLoopObserverRef observer)
{
    if (!observer)
        return;
    CFRunLoopObserverInvalidate(observer);
    CFRelease(observer);
}

// Runs this thread's run loop, woken every 10 ms, calling `atTick` with each wake's number until it answers
// false.
static void runTicks(bool (^atTick)(int))
{
    __block int tick = 0;
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.01, 0.01, 0, 0,
        ^(CFRunLoopTimerRef) {
            if (!atTick(++tick))
                CFRunLoopStop(CFRunLoopGetCurrent());
        });
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5, false);
    CFRunLoopTimerInvalidate(timer);
    CFRelease(timer);
}

static void observerPositions(void)
{
    __block CFRunLoopObserverRef late = NULL, commit = NULL, later = NULL, carrier = NULL;
    __block char *queuedMidPass = NULL, *queuedCarried = NULL;
    runTicks(^bool(int tick) {
        switch (tick) {
        case 2:
            late = addObserver(kCommitOrder - 1, "late");
            commit = addObserver(kCommitOrder, "commit");
            break;
        case 3:
            sequence[0] = 0;
            [CATransaction addCommitHandler:^{ note("handler"); } forPhase:kPreCommitPhase];
            break;
        case 5:
            queuedMidPass = strdup(sequence);
            sequence[0] = 0;
            // At the pass's end, past its pre side: queues a handler and adds an order-1 observer.
            carrier = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, false, kCommitOrder + 5,
                ^(CFRunLoopObserverRef, CFRunLoopActivity) {
                    note("|");
                    [CATransaction addCommitHandler:^{ note("carried"); } forPhase:kPreCommitPhase];
                    later = addObserver(kCommitOrder - 1, "later");
                });
            CFRunLoopAddObserver(CFRunLoopGetCurrent(), carrier, kCFRunLoopCommonModes);
            break;
        case 8:
            queuedCarried = strdup(sequence);
            return false;
        }
        return true;
    });

    const char *handler = queuedMidPass ? strstr(queuedMidPass, "handler") : NULL;
    const char *lateRun = queuedMidPass ? strstr(queuedMidPass, "late") : NULL;
    check(handler && lateRun && lateRun < handler, "a handler queued mid-pass runs after an order-1 observer added before it");
    check(handler && strstr(handler, "commit"), "and before the commit-order observer");
    const char *afterCarrier = queuedCarried ? strstr(queuedCarried, "|") : NULL;
    const char *carried = afterCarrier ? strstr(afterCarrier, "carried") : NULL;
    const char *laterRun = afterCarrier ? strstr(afterCarrier, "later") : NULL;
    check(carried && laterRun && laterRun < carried, "a handler carried to the next pass runs after an order-1 observer added since");
    check(carried && strstr(carried, "commit"), "and before the commit-order observer");

    removeObserver(late);
    removeObserver(commit);
    removeObserver(later);
    removeObserver(carrier);
    free(queuedMidPass);
    free(queuedCarried);
}

// WebKit's rendering-update pattern (TiledCoreAnimationDrawingArea::addCommitHandlers,
// WebViewRenderingUpdateScheduler::registerCACommitHandlers): an observer at CA's order minus one, created on
// demand and invalidated once it fires, that changes a layer and registers a PreLayout and a PostCommit
// handler. `fromBeforeWaiting` schedules it from an order-1 BeforeWaiting observer, otherwise from a timer
// mid-pass. Answers how many of `frames` frames ran PreLayout before PostCommit, and how many ran it after
// the observer's callout returned.
static void renderingPattern(bool fromBeforeWaiting, int *frames, int *preBeforePost, int *preAfterCallout)
{
    static CALayer *layer;
    if (!layer)
        layer = [[CALayer layer] retain];
    __block CFRunLoopObserverRef rendering = NULL;
    __block bool scheduleAtBeforeWaiting = false;
    void (^schedule)(void) = ^{
        if (rendering)
            return;
        rendering = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, kCommitOrder - 1,
            ^(CFRunLoopObserverRef, CFRunLoopActivity) {
                note("render");
                layer.opacity = layer.opacity == 1 ? 0.5 : 1;
                [CATransaction addCommitHandler:^{ note("PRE"); } forPhase:kPreLayoutPhase];
                [CATransaction addCommitHandler:^{ note("POST"); } forPhase:kPostCommitPhase];
                note("rendered");
                removeObserver(rendering);
                rendering = NULL;
            });
        CFRunLoopAddObserver(CFRunLoopGetCurrent(), rendering, kCFRunLoopCommonModes);
        CFRunLoopWakeUp(CFRunLoopGetCurrent());
    };
    CFRunLoopObserverRef early = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 1,
        ^(CFRunLoopObserverRef, CFRunLoopActivity) {
            if (scheduleAtBeforeWaiting) {
                scheduleAtBeforeWaiting = false;
                schedule();
            }
        });
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), early, kCFRunLoopCommonModes);
    sequence[0] = 0;
    runTicks(^bool(int tick) {
        if (tick >= 3 && tick <= 12 && !(tick % 3)) {
            if (fromBeforeWaiting)
                scheduleAtBeforeWaiting = true;
            else
                schedule();
        }
        return tick < 16;
    });
    removeObserver(early);

    *frames = *preBeforePost = *preAfterCallout = 0;
    for (char *frame = strstr(sequence, "render "); frame; frame = strstr(frame + 1, "render ")) {
        ++*frames;
        char *pre = strstr(frame, "PRE"), *post = strstr(frame, "POST"), *rendered = strstr(frame, "rendered");
        if (pre && (!post || pre < post))
            ++*preBeforePost;
        if (pre && rendered && rendered < pre && (!post || pre < post))
            ++*preAfterCallout;
    }
}

int main(void)
{
    @autoreleasepool {
        printf("commit handler pre order\n");
        // The thread's observers come into being with its first handler, live from the next pass.
        [CATransaction addCommitHandler:^{ } forPhase:kPreCommitPhase];
        runTicks(^bool(int tick) { return tick < 2; });

        observerPositions();

        int frames, preBeforePost, preAfterCallout;
        renderingPattern(false, &frames, &preBeforePost, &preAfterCallout);
        check(frames == 4 && preBeforePost == frames, "an on-demand order-1 observer scheduled mid-pass: PreLayout before PostCommit");
        renderingPattern(true, &frames, &preBeforePost, &preAfterCallout);
        check(frames == 4 && preBeforePost == frames, "one created during the previous BeforeWaiting: PreLayout before PostCommit");
        check(frames == 4 && preAfterCallout == frames, "and PreLayout from the pre observer, after the observer's callout returns");
    }
    if (failures)
        printf("commit handler pre order: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
