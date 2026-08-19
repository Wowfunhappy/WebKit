// QuartzCore: Objective-C methods on Core Animation classes that macOS 10.9 does not have, implemented
// with the APIs 10.9 does have. Uses the same recipe as AppKit.m: a `wk_`-prefixed category method,
// registered with WK_POLYFILL_SEL.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------------------------------------------
// -[CALayerHost setPreservesFlip:] (10.10+). It controls whether a hosted remote layer tree inherits
// the hosting tree's ambient geometry flip. 10.9's CALayerHost has no such method — a direct send
// throws unrecognized-selector — and 10.9's compositor has no host-flip-flag concept, so accept the
// value and leave the host as its default (unflipped) self. Every TiledCoreAnimation host passes NO,
// which is that default; the RemoteLayerTreeHost custom/AVPlayerLayer path can pass YES, which this OS
// cannot honor.
@interface CALayerHost : CALayer
@end
@interface CALayerHost (WKPolyfillScope)
- (void)wk_setPreservesFlip:(BOOL)preservesFlip;
@end
@implementation CALayerHost (WKPolyfillScope)
- (void)wk_setPreservesFlip:(BOOL)preservesFlip { (void)preservesFlip; }
@end
WK_POLYFILL_SEL("setPreservesFlip:", "wk_setPreservesFlip:");

// ---------------------------------------------------------------------------------------------------
// CAContext cross-process fence ports (createFencePort/setFencePort:/invalidateFences, ~10.10+): 10.9's
// QuartzCore has no cross-process CA fencing. A null port end-to-end (producer's createFencePort plus every
// consumer's setFencePort:/invalidateFences) is behavior-identical to the pre-fence path: no live-resize
// flicker suppression, correct eventual rendering, and — because nobody waits on a real port — no hang.
// CAContext is SPI (absent from the public QuartzCore headers), so it is declared here.
@interface CAContext : NSObject
@end
@interface CAContext (WKPolyfillScope)
- (mach_port_t)wk_createFencePort;
- (void)wk_setFencePort:(mach_port_t)port;
- (void)wk_invalidateFences;
@end
@implementation CAContext (WKPolyfillScope)
- (mach_port_t)wk_createFencePort { return MACH_PORT_NULL; }
- (void)wk_setFencePort:(mach_port_t)port { (void)port; }
- (void)wk_invalidateFences { }
@end
WK_POLYFILL_SEL("createFencePort", "wk_createFencePort");
WK_POLYFILL_SEL("setFencePort:", "wk_setFencePort:");
WK_POLYFILL_SEL("invalidateFences", "wk_invalidateFences");

// ---------------------------------------------------------------------------------------------------
@interface CALayer (WKPolyfillScope)
// -[CALayer setCornerCurve:] (10.13+, a CACornerCurve) and -[CALayer setContentsFormat:] (10.12+, a
// CAContentsFormat NSString). 10.9's CALayer has neither. Corners on 10.9 are always the classic circular
// curve, which is exactly the value PlatformCALayerCocoa requests (kCACornerCurveCircular, supplied in
// c/QuartzCore.m), so honoring the curve is a no-op. The contents format selects a layer's backing pixel
// format (wide-gamut / 16-bit); 10.9's compositor has only the fixed sRGB 8-bit backing, so there is
// nothing to opt into and the set is a no-op. (Per-class GAP_FILLs: WebKit's own WebTiledBackingLayer
// -setContentsFormat:(ContentsFormat) keeps its real method via the patcher's class-correct aliasing;
// only a plain CALayer, which lacks the selector on 10.9, gets this body.)
- (void)wk_setCornerCurve:(NSString *)curve;
- (void)wk_setContentsFormat:(NSString *)format;
@end
@implementation CALayer (WKPolyfillScope)
- (void)wk_setCornerCurve:(NSString *)curve { (void)curve; }
- (void)wk_setContentsFormat:(NSString *)format { (void)format; }
@end
WK_POLYFILL_SEL("setCornerCurve:", "wk_setCornerCurve:");
WK_POLYFILL_SEL("setContentsFormat:", "wk_setContentsFormat:");

// ---------------------------------------------------------------------------------------------------
// -[CALayer usesWebKitBehavior] (10.13+) selects the compositor semantics WebKit is written against.
// 10.9's CA has a single behavior set and no such mode, so the property is state a layer carries and
// nothing more. The one axis of that mode 10.9 spells separately is sublayer depth sorting, whose
// property it does have: PlatformCALayerCocoa::commonInit and RemoteLayerTreeHost send
// -setSortsSublayers: inside the branch this selector gates, giving every layer but a CATransformLayer
// painter's order. 10.9's default is to sort, which puts a composited layer whose 3D transform carries
// it behind z=0 under its opaque siblings.
static const char kWKUsesWebKitBehaviorKey;
@interface CALayer (WKPolyfillUsesWebKitBehavior)
- (void)wk_setUsesWebKitBehavior:(BOOL)usesWebKitBehavior;
- (BOOL)wk_usesWebKitBehavior;
@end
@implementation CALayer (WKPolyfillUsesWebKitBehavior)
- (void)wk_setUsesWebKitBehavior:(BOOL)usesWebKitBehavior
{
    objc_setAssociatedObject(self, &kWKUsesWebKitBehaviorKey, @(usesWebKitBehavior), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (BOOL)wk_usesWebKitBehavior
{
    return [objc_getAssociatedObject(self, &kWKUsesWebKitBehaviorKey) boolValue];
}
@end
WK_POLYFILL_SEL("setUsesWebKitBehavior:", "wk_setUsesWebKitBehavior:");
WK_POLYFILL_SEL("usesWebKitBehavior", "wk_usesWebKitBehavior");

// ---------------------------------------------------------------------------------------------------
// +[CATransaction addCommitHandler:forPhase:] (10.10+, absent on 10.9's CATransaction — sending it
// throws NSInvalidArgumentException, which aborted Safari from TiledCoreAnimationDrawingAreaProxy::
// createFence and permanently wedged window-resize propagation).
//
// 10.9's CoreAnimation has NO hook inside a commit. Audited on 10.9.5 (13F34): CATransaction's whole
// method list is +begin/+commit/+flush/+synchronize/+activate/+lock/+setCompletionBlock: and friends —
// nothing phase-related — and QuartzCore exports no commit callback either; the commit itself is
// CA::Transaction::commit, an internal C++ entry point. What IS observable is WHERE that commit happens:
// it runs from CA's own run-loop observer (CA::Transaction::observer_callback,
// kCFRunLoopBeforeWaiting|kCFRunLoopExit, order 2000000 — read straight off the run loop on 10.9.5, and
// the same number upstream WebKit hardcodes as `coreAnimationCommit` in
// WebCore/platform/cf/RunLoopObserverCF.cpp). A commit therefore has a position in the run loop, and
// both sides of this polyfill are run-loop observers placed around it: the pre side one order below
// CA's, the post side one order above. Order, not the registrant's identity, is what puts each handler
// on its side of the commit.
//
// WHAT THIS GUARANTEES: a PreLayout/PreCommit handler runs at the end of the run-loop pass it is
// registered in, immediately before CA's commit observer — after everything its registrant does in that
// pass, and before the commit that carries those changes. A PostCommit handler runs once a commit has
// actually been observed to happen (see the commit-counter gate below), from an observer ordered above
// CA's. The bracket is never inverted, and neither side depends on HOW the commit is triggered: it holds
// for the run-loop drain, for an explicit [CATransaction flush] or [CATransaction commit], and for a
// commit some other framework performs.
//
// The residual differences, all in the "wider" direction:
//   - PreLayout and PreCommit run at the same point, and that point is immediately before the commit
//     rather than inside it, so neither observes the layout CA does while committing. This OS offers no
//     callout between the two, so one slot is what there is.
//   - A pre handler registered before this thread's observers can fire — the pass in which the thread's
//     first handler is registered, or a thread that never runs a run loop — runs at registration
//     instead. That is earlier than the commit, never after it (CFRunLoop collects the observers for an
//     activity ONCE, as that activity's callouts begin, so an observer created during them first fires
//     in the NEXT pass; measured on 10.9.5).
//   - A post handler on a thread that commits explicitly and then never returns to its run loop does not
//     run.
//   - A handler registered from inside another handler runs at the next commit rather than at the end of
//     the current one, which upstream CA prohibits outright.
static const CFIndex wk_coreAnimationCommitOrder = 2000000;

// THE COMMIT GATE. "After the commit" is only a bracket if a commit happened. A PostCommit handler is the
// tail of a pair whose head is some change the caller has just made and expects to be on screen; running it
// on a pass where nothing committed hands the caller a completion for work that has not happened, which is
// an inversion rather than a wider bracket. Nothing about registering a handler makes a transaction exist,
// so a pass with no commit is an ordinary case that has to be recognised, not assumed away.
//
// The signal is CA's own commit counter. 10.9's QuartzCore exports CAGetTransactionCounter(), which returns a
// process-global int that CA increments once per COMMITTED transaction. Measured on 10.9.5 (13F34): reading
// it creates no transaction; [CATransaction begin] and layer mutations leave it alone; each [CATransaction
// commit] and each [CATransaction flush] that had a transaction to flush adds one; a flush with nothing
// pending adds nothing. That is exactly "a commit happened", observed rather than predicted — which is why
// this is used in preference to probing +[CATransaction currentState] for a PENDING transaction: the counter
// also catches a commit performed explicitly during the pass, and it does not depend on where the probe sits
// relative to WebKit's own RenderingUpdate observer (which shares order 2000000-1 and is where the pending
// transaction is usually created).
//
// So each queued handler records the counter at registration, and a second per-thread observer records it
// again each time the thread WAKES (kCFRunLoopAfterWaiting). The drain observer, at CA's order + 1, runs a
// handler only when the counter has advanced past BOTH:
//   - the value at that handler's registration — the commit must have come after the handler was queued; and
//   - the value read when this thread last woke — the commit must have happened while this thread was
//     running, not while it slept.
// Everything else stays queued and is carried to the next pass. Nothing here enumerates callers.
//
// The second test is what keeps the counter's one weakness in check: it is a single QuartzCore global, not a
// per-thread count (10.9 has no per-thread one), so ANY thread's commit moves it. Commits by the other thread
// that registers handlers here — ScrollingThread, whose transactions land while the main thread is between
// passes — are therefore rejected outright. What remains is a commit on another thread landing while this
// thread happens to be awake, which opens the gate one pass early: unconditional behaviour for that
// one pass, not a systematic inversion.
//
// The wake reading, rather than one taken just below CA's commit observer, is what makes an EXPLICIT commit
// count: [CATransaction commit]/[CATransaction flush] happens in the middle of a pass, so a reading taken
// below CA's commit observer is already past it and the handler would sit queued until some later implicit
// commit. Both readings were built and run against this translation unit on 10.9.5: the below-CA reading
// strands a handler registered before an explicit commit, the wake reading releases it on the same pass.
// If a thread's run loop never sleeps, the wake reading simply goes stale and the gate falls back to the
// registration test alone — later than CA, never earlier.
WK_SYSTEM_FN("QuartzCore", unsigned int, CAGetTransactionCounter, (void));

static unsigned int wk_caTransactionCounter(void)
{
    return WK_SYSTEM(CAGetTransactionCounter) ? WK_SYSTEM(CAGetTransactionCounter)() : 0;
}

// The queues and their observers are per thread (CA transactions are per thread) and the observers are
// REPEATING and kept for the life of the thread. That is not an optimization: CFRunLoop collects the
// observers for an activity ONCE, when that activity's callouts begin, so an observer created from inside a
// BeforeWaiting callout does not fire until the NEXT pass (measured on 10.9.5). Handlers are routinely
// registered from exactly there — a run-loop observer one order below CA's commit is where a caller
// preparing a commit belongs — so a fresh observer per registration would run every handler a full
// run-loop cycle late. The one pass that still has no live observers is the one in which a thread's first
// handler is registered, and `observersAreLive` is what says so.
typedef struct {
    NSMutableArray *preHandlers;        // pending pre-commit blocks, in registration order
    NSMutableArray *postHandlers;       // pending PostCommit blocks, in registration order
    NSMutableArray *postRegisteredAt;   // CA commit counter when each post handler was queued, same order
    CFRunLoopObserverRef wakeObserver;  // AfterWaiting: samples the counter as the pass starts
    CFRunLoopObserverRef preObserver;   // below CA's commit observer: runs the pre handlers
    CFRunLoopObserverRef postObserver;  // above CA's commit observer: drains what a commit released
    unsigned int counterAtWake;
    bool observersAreLive;              // a pass has begun since the observers were created
} WKCommitHandlerQueue;

static pthread_key_t wk_commitHandlerQueueKey;
static pthread_once_t wk_commitHandlerQueueOnce = PTHREAD_ONCE_INIT;

static void wk_invalidateObserver(CFRunLoopObserverRef observer)
{
    if (!observer)
        return;
    CFRunLoopObserverInvalidate(observer);
    CFRelease(observer);
}

static void wk_commitHandlerQueueDestroy(void *value)
{
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)value;
    wk_invalidateObserver(queue->wakeObserver);
    wk_invalidateObserver(queue->preObserver);
    wk_invalidateObserver(queue->postObserver);
    [queue->preHandlers release];
    [queue->postHandlers release];
    [queue->postRegisteredAt release];
    free(queue);
}

static void wk_commitHandlerQueueKeyInit(void)
{
    pthread_key_create(&wk_commitHandlerQueueKey, wk_commitHandlerQueueDestroy);
}

// Runs as the thread wakes, before anything else the pass does. It records the commit count this pass
// starts from, so that the post drain can tell a commit made while this thread was running from one
// another thread made while it slept; it marks the observers live, since reaching here means a pass has
// begun with them already collected; and it re-inserts the pre observer.
//
// The re-insertion is what makes the pre observer's position independent of when it was created. CFRunLoop
// runs observers of EQUAL order in the order they were added (measured on 10.9.5), and CA's commit sits at
// the next integer up, so there is no order between the two: being last among the observers at CA's order
// minus one is the only way to run after every one of them and still before the commit. Removing and
// re-adding during AfterWaiting takes effect for this pass, because BeforeWaiting collects its observers
// later.
static void wk_beginRunLoopPass(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer;
    (void)activity;
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)info;
    queue->counterAtWake = wk_caTransactionCounter();
    queue->observersAreLive = true;
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    CFRunLoopRemoveObserver(runLoop, queue->preObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(runLoop, queue->preObserver, kCFRunLoopCommonModes);
}

// Immediately below CA's commit observer: everything the pass did has happened, and the commit that will
// carry it has not. Unlike the post side there is nothing to gate on — a handler that runs here runs before
// the next commit whether or not this pass has one.
static void wk_runPendingPreCommitHandlers(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer;
    (void)activity;
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)info;
    if (![queue->preHandlers count])
        return;
    // Take the batch out first: a handler that registers another one queues it for the next commit instead
    // of extending this callout (upstream CA rejects that registration outright, so no caller can be
    // relying on either behaviour).
    NSArray *batch = [queue->preHandlers copy];
    [queue->preHandlers removeAllObjects];
    @autoreleasepool {
        for (void (^handler)(void) in batch)
            handler();
    }
    [batch release];
}

static void wk_runPendingPostCommitHandlers(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer;
    (void)activity;
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)info;
    if (![queue->postHandlers count])
        return;
    unsigned int now = wk_caTransactionCounter();
    if (now == queue->counterAtWake)
        return; // Nothing committed while this thread ran. Carry the queue to the next pass.
    // Drain the handlers registered before that commit — the leading run of the array, since the counters
    // are recorded in registration order. Anything registered at the current value was queued after the
    // commit (a CATransaction completion block can do that) and waits for the next one.
    NSUInteger drainCount = 0, queued = [queue->postHandlers count];
    while (drainCount < queued && [[queue->postRegisteredAt objectAtIndex:drainCount] unsignedIntValue] != now)
        drainCount++;
    if (!drainCount)
        return;
    NSRange range = NSMakeRange(0, drainCount);
    NSArray *batch = [[queue->postHandlers subarrayWithRange:range] copy];
    [queue->postHandlers removeObjectsInRange:range];
    [queue->postRegisteredAt removeObjectsInRange:range];
    @autoreleasepool {
        for (void (^handler)(void) in batch)
            handler();
    }
    [batch release];
}

static WKCommitHandlerQueue *wk_commitHandlerQueueForCurrentThread(void)
{
    pthread_once(&wk_commitHandlerQueueOnce, wk_commitHandlerQueueKeyInit);
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)pthread_getspecific(wk_commitHandlerQueueKey);
    if (queue)
        return queue;
    queue = (WKCommitHandlerQueue *)calloc(1, sizeof(WKCommitHandlerQueue));
    queue->preHandlers = [[NSMutableArray alloc] init];
    queue->postHandlers = [[NSMutableArray alloc] init];
    queue->postRegisteredAt = [[NSMutableArray alloc] init];
    CFRunLoopObserverContext context = { 0, queue, NULL, NULL, NULL };
    // The wake sampler takes the lowest order there is, so that it reads the counter before anything else
    // the pass does. The two drain observers carry CA's own activities and sit one below and one above its
    // commit; one above is also where CA's own PostCommit handlers land relative to WebKit's
    // PostRenderingUpdate observer (2000002), so the post handler keeps running before it, as upstream.
    queue->wakeObserver = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAfterWaiting,
                                                  true, LONG_MIN,
                                                  wk_beginRunLoopPass, &context);
    queue->preObserver = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit,
                                                 true, wk_coreAnimationCommitOrder - 1,
                                                 wk_runPendingPreCommitHandlers, &context);
    queue->postObserver = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit,
                                                  true, wk_coreAnimationCommitOrder + 1,
                                                  wk_runPendingPostCommitHandlers, &context);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), queue->wakeObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), queue->preObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), queue->postObserver, kCFRunLoopCommonModes);
    pthread_setspecific(wk_commitHandlerQueueKey, queue);
    return queue;
}

@interface CATransaction (WKPolyfillScope)
+ (void)wk_addCommitHandler:(void (^)(void))handler forPhase:(NSInteger)phase;
@end
@implementation CATransaction (WKPolyfillScope)
+ (void)wk_addCommitHandler:(void (^)(void))handler forPhase:(NSInteger)phase
{
    if (!handler)
        return;
    // kCATransactionPhasePreLayout = 0, PreCommit = 1, PostCommit = 2.
    enum { wkPostCommitPhase = 2 };
    WKCommitHandlerQueue *queue = wk_commitHandlerQueueForCurrentThread();
    // With no observer that can fire before the next commit, the last moment this thread offers that is
    // still on the pre side of that commit is now.
    if (phase != wkPostCommitPhase && !queue->observersAreLive) {
        handler();
        return;
    }
    void (^copied)(void) = [handler copy];
    if (phase == wkPostCommitPhase) {
        [queue->postHandlers addObject:copied];
        [queue->postRegisteredAt addObject:[NSNumber numberWithUnsignedInt:wk_caTransactionCounter()]];
    } else
        [queue->preHandlers addObject:copied];
    [copied release];
}
@end
WK_POLYFILL_SEL("addCommitHandler:forPhase:", "wk_addCommitHandler:forPhase:");

// -[CASpringAnimation setInitialVelocity:] (the property is public 10.11+, absent on 10.9). 10.9 ships a
// fully-functional private CASpringAnimation (mass/stiffness/damping/velocity settable + the internal
// _copyRenderAnimationForLayer:/_timeFunction: spring machinery) whose pre-10.11 name for the same
// concept is -velocity/-setVelocity:. Forward the modern setter to it (via KVC on "velocity", verified
// settable on-host) so PlatformCAAnimation*'s upstream `.initialVelocity = ...` works and those sources
// revert to pristine.
@interface CASpringAnimation (WKPolyfillScope)
- (void)wk_setInitialVelocity:(CGFloat)velocity;
@end
@implementation CASpringAnimation (WKPolyfillScope)
- (void)wk_setInitialVelocity:(CGFloat)velocity
{
    [self setValue:@(velocity) forKey:@"velocity"];
}
@end
WK_POLYFILL_SEL("setInitialVelocity:", "wk_setInitialVelocity:");

#pragma clang diagnostic pop
