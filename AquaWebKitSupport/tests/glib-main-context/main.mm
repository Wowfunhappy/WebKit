// Serves GLib's default context from the main CFRunLoop, as WebContent does, and checks timeouts,
// idle sources, timers, and complete, ordered bus, descriptor and RunLoop delivery.

#include "config.h"
#include "GLibMainContextAquaWebKit.h"
#include "MainThreadSharedTimer.h"

#import <Foundation/Foundation.h>
#include <glib-unix.h>
#include <glib.h>
#include <atomic>
#include <cstdio>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <wtf/MainThread.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RunLoop.h>
#include <wtf/WorkQueue.h>
#include <wtf/glib/RunLoopSourcePriority.h>

static bool failed;
static std::atomic<bool> pausePoller, pollerPaused;
static std::atomic<unsigned> helperPolls, finiteHelperPolls;
static pthread_mutex_t pollerLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pollerCondition = PTHREAD_COND_INITIALIZER;

extern "C" gint g_poll(GPollFD* fds, guint count, gint timeout)
{
    static auto realPoll = reinterpret_cast<GPollFunc>(dlsym(RTLD_NEXT, "g_poll"));
    if (!pthread_main_np()) {
        ++helperPolls;
        if (timeout != -1)
            ++finiteHelperPolls;
    }
    int result = realPoll(fds, count, timeout);
    if (!pthread_main_np()) {
        pthread_mutex_lock(&pollerLock);
        while (pausePoller) {
            pollerPaused = true;
            pthread_cond_wait(&pollerCondition, &pollerLock);
        }
        pollerPaused = false;
        pthread_mutex_unlock(&pollerLock);
    }
    return result;
}

static void check(bool condition, const char* what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition)
        failed = true;
}

static void runUntil(bool (^done)(), double seconds)
{
    CFRunLoopObserverRef completionObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
        if (done())
            CFRunLoopStop(CFRunLoopGetMain());
    });
    CFRunLoopAddObserver(CFRunLoopGetMain(), completionObserver, kCFRunLoopCommonModes);
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && [limit timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:limit];
    CFRunLoopObserverInvalidate(completionObserver);
    CFRelease(completionObserver);
}

static std::atomic<bool> finished;
static void* watchdog(void*)
{
    sleep(30);
    if (!finished) {
        printf("FAIL: the main run loop stopped serving the context\n");
        fflush(stdout);
        _exit(1);
    }
    return nullptr;
}

struct SharedTimerUnderLoad {
    static SharedTimerUnderLoad* current;
    bool useWorkQueue, suspend, blockedPoller;
    bool finished { false };
    unsigned work { 0 }, workAtShared { 0 }, workAtCF { 0 }, passes { 0 }, passesAtShared { 0 };
    MonotonicTime start, sharedFired, cfFired;

    void post()
    {
        auto step = [] {
            auto& test = *current;
            ++test.work;
            if (test.suspend)
                RunLoop::mainSingleton().suspendFunctionDispatchForCurrentCycle();
            if ((!test.sharedFired || !test.cfFired) && MonotonicTime::now() - test.start < 100_ms)
                test.post();
            else
                test.finished = true;
        };
        if (useWorkQueue)
            WorkQueue::mainSingleton().dispatch(WTF::move(step));
        else
            RunLoop::mainSingleton().dispatch(WTF::move(step));
    }

    void run()
    {
        current = this;
        if (blockedPoller) {
            pausePoller = true;
            g_main_context_wakeup(g_main_context_default());
            MonotonicTime deadline = MonotonicTime::now() + 2_s;
            while (!pollerPaused && MonotonicTime::now() < deadline)
                usleep(1000);
        }
        auto& sharedTimer = WebCore::MainThreadSharedTimer::singleton();
        sharedTimer.setFiredFunction(nullptr);
        sharedTimer.setFiredFunction([] {
            current->sharedFired = MonotonicTime::now();
            current->workAtShared = current->work;
            current->passesAtShared = current->passes;
        });
        CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
            ++current->passes;
            if (current->finished && current->sharedFired && current->cfFired)
                CFRunLoopStop(CFRunLoopGetMain());
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
        CFRunLoopTimerRef cfTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1, 0, 0, 0, ^(CFRunLoopTimerRef) {
            current->cfFired = MonotonicTime::now();
            current->workAtCF = current->work;
        });
        CFRunLoopAddTimer(CFRunLoopGetMain(), cfTimer, kCFRunLoopCommonModes);
        RunLoop::mainSingleton().dispatch([cfTimer] {
            current->start = MonotonicTime::now();
            CFRunLoopTimerSetNextFireDate(cfTimer, CFAbsoluteTimeGetCurrent());
            WebCore::MainThreadSharedTimer::singleton().setFireInterval(0_s);
            current->post();
        });
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2, false);
        double sharedLatency = (sharedFired - start).milliseconds();
        double cfLatency = (cfFired - start).milliseconds();
        printf("shared timer under %s load%s%s: shared %.3f ms at work %u/pass %u, CF %.3f ms at work %u, %u callbacks total\n",
            useWorkQueue ? "WorkQueue" : "RunLoop", suspend ? " with suspension" : "", blockedPoller ? " with blocked poller" : "",
            sharedLatency, workAtShared, passesAtShared, cfLatency, workAtCF, work);
        check(finished && sharedFired && cfFired && sharedLatency < 10 && cfLatency < 10
            && workAtShared < work && workAtCF < work && (!blockedPoller || pollerPaused),
            "zero-delay shared and CF timers fire within 10 ms while dispatch continues");
        CFRunLoopTimerInvalidate(cfTimer);
        CFRelease(cfTimer);
        CFRunLoopObserverInvalidate(observer);
        CFRelease(observer);
        sharedTimer.stop();
        sharedTimer.setFiredFunction(nullptr);
        if (blockedPoller) {
            pthread_mutex_lock(&pollerLock);
            pausePoller = false;
            pthread_cond_signal(&pollerCondition);
            pthread_mutex_unlock(&pollerLock);
        }
        current = nullptr;
    }
};

SharedTimerUnderLoad* SharedTimerUnderLoad::current;

struct BusBurstSource {
    GSource source;
    static constexpr unsigned messageCount = 200;
    unsigned messages[messageCount];
    unsigned delivered, followed, outOfOrder, overtaken;
    unsigned observerPasses, messagesAtFirstObserver, observersDuringBurst;
};

struct NestedDrainSource {
    GSource source;
    static constexpr unsigned rounds = 8;
    unsigned delivered, dispatchDepth, maxDispatchDepth, nestedDispatches;
    unsigned timeoutFires, controlCallouts, nestedWaits;
    bool nested, timeoutOnMainThread, deadlinePendingAtEntry;
    CFRunLoopSourceRef controlSource;
    MonotonicTime timeoutAdded, timeoutFired, nestedStart, nestedEnd;
};

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IOLBF, 0);
        WTF::initializeMainThread();
        pthread_t thread;
        pthread_create(&thread, nullptr, watchdog, nullptr);

        WebCore::attachGLibMainContextToMainRunLoop();
        runUntil(^{ return false; }, 0.2);

        // A timeout added on the main thread while the run loop is idle.
        static MonotonicTime fired;
        MonotonicTime added = MonotonicTime::now();
        g_timeout_add(100, [](gpointer data) -> gboolean {
            *static_cast<MonotonicTime*>(data) = MonotonicTime::now();
            return G_SOURCE_REMOVE;
        }, &fired);
        runUntil(^{ return !!fired; }, 2);
        double latency = (fired - added).milliseconds();
        printf("timeout fired after %.1f ms\n", latency);
        check(latency >= 100 && latency < 160, "a main-thread timeout fires on time on an idle run loop");

        pausePoller = true;
        g_main_context_wakeup(g_main_context_default());
        MonotonicTime pauseDeadline = MonotonicTime::now() + 2_s;
        while (!pollerPaused && MonotonicTime::now() < pauseDeadline)
            usleep(1000);
        check(pollerPaused, "the descriptor poller is blocked before timer delivery");
        static bool timeoutOnMainThread;
        fired = { };
        added = MonotonicTime::now();
        g_timeout_add(100, [](gpointer) -> gboolean {
            fired = MonotonicTime::now();
            timeoutOnMainThread = pthread_main_np();
            return G_SOURCE_REMOVE;
        }, nullptr);
        runUntil(^{ return !!fired; }, 2);
        latency = ((fired ? fired : MonotonicTime::now()) - added).milliseconds();
        printf("timeout with blocked poller %s after %.1f ms\n", fired ? "fired" : "pending", latency);
        check(fired && timeoutOnMainThread && pollerPaused && latency >= 100 && latency < 160,
            "a GLib deadline fires on the main thread while the poller is blocked");

        // DRT's wait-attribute poll posts a new zero-delay timer from each timer callout.
        struct ZeroDelayPoll {
            CFRunLoopTimerRef timer { nullptr };
            unsigned callouts { 0 }, passes { 0 }, passesAtDispatch { 0 };
            unsigned passLimit { 1000 };
            unsigned workMicroseconds { 0 };
            MonotonicTime start, dispatched;
            bool onMainThread { false };

            void post()
            {
                CFRunLoopTimerContext context { };
                context.info = this;
                timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0, 0, 0, [](CFRunLoopTimerRef timer, void* info) {
                    auto& poll = *static_cast<ZeroDelayPoll*>(info);
                    CFRunLoopTimerInvalidate(timer);
                    CFRelease(timer);
                    poll.timer = nullptr;
                    ++poll.callouts;
                    if (!poll.dispatched && poll.workMicroseconds)
                        usleep(poll.workMicroseconds);
                    if (poll.dispatched || (poll.passLimit && poll.passes >= poll.passLimit) || MonotonicTime::now() - poll.start >= 100_ms)
                        CFRunLoopStop(CFRunLoopGetMain());
                    else
                        poll.post();
                }, &context);
                CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
            }
        } zeroDelayPoll;
        auto* poll = &zeroDelayPoll;
        CFRunLoopObserverRef zeroDelayObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
            ++poll->passes;
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), zeroDelayObserver, kCFRunLoopCommonModes);
        zeroDelayPoll.start = MonotonicTime::now();
        zeroDelayPoll.post();
        guint zeroDelayIdle = g_idle_add([](gpointer data) -> gboolean {
            auto& poll = *static_cast<ZeroDelayPoll*>(data);
            poll.dispatched = MonotonicTime::now();
            poll.passesAtDispatch = poll.passes;
            poll.onMainThread = pthread_main_np();
            return G_SOURCE_REMOVE;
        }, poll);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        double zeroDelayTime = ((zeroDelayPoll.dispatched ? zeroDelayPoll.dispatched : MonotonicTime::now()) - zeroDelayPoll.start).milliseconds();
        printf("zero-delay CF poll: %u callouts, %u observer passes, GLib idle %s after %.2f ms at pass %u\n",
            zeroDelayPoll.callouts, zeroDelayPoll.passes, zeroDelayPoll.dispatched ? "dispatched" : "pending",
            zeroDelayTime, zeroDelayPoll.passesAtDispatch);
        check(zeroDelayPoll.dispatched && zeroDelayPoll.onMainThread && zeroDelayPoll.callouts
            && zeroDelayPoll.passesAtDispatch < 1000 && zeroDelayTime < 100 && pollerPaused,
            "a GLib idle dispatches within 1000 passes and 100 ms while a zero-delay CF timer keeps reposting");
        if (!zeroDelayPoll.dispatched)
            g_source_remove(zeroDelayIdle);
        if (zeroDelayPoll.timer) {
            CFRunLoopTimerInvalidate(zeroDelayPoll.timer);
            CFRelease(zeroDelayPoll.timer);
        }
        CFRunLoopObserverInvalidate(zeroDelayObserver);
        CFRelease(zeroDelayObserver);

        ZeroDelayPoll zeroDelayDeadlinePoll;
        zeroDelayDeadlinePoll.passLimit = 0;
        zeroDelayDeadlinePoll.workMicroseconds = 15000;
        auto* deadlinePoll = &zeroDelayDeadlinePoll;
        CFRunLoopObserverRef deadlineObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
            ++deadlinePoll->passes;
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), deadlineObserver, kCFRunLoopCommonModes);
        zeroDelayDeadlinePoll.start = MonotonicTime::now();
        guint zeroDelayTimeout = g_timeout_add(20, [](gpointer data) -> gboolean {
            auto& poll = *static_cast<ZeroDelayPoll*>(data);
            poll.dispatched = MonotonicTime::now();
            poll.passesAtDispatch = poll.passes;
            poll.onMainThread = pthread_main_np();
            return G_SOURCE_REMOVE;
        }, deadlinePoll);
        zeroDelayDeadlinePoll.post();
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        double zeroDelayTimeoutTime = ((zeroDelayDeadlinePoll.dispatched ? zeroDelayDeadlinePoll.dispatched : MonotonicTime::now()) - zeroDelayDeadlinePoll.start).milliseconds();
        printf("zero-delay CF poll with 20 ms GLib timeout: %u callouts, %u observer passes, timeout %s after %.3f ms at pass %u\n",
            zeroDelayDeadlinePoll.callouts, zeroDelayDeadlinePoll.passes, zeroDelayDeadlinePoll.dispatched ? "fired" : "pending",
            zeroDelayTimeoutTime, zeroDelayDeadlinePoll.passesAtDispatch);
        check(zeroDelayDeadlinePoll.dispatched && zeroDelayDeadlinePoll.onMainThread && zeroDelayDeadlinePoll.callouts
            && zeroDelayDeadlinePoll.passesAtDispatch > 1 && zeroDelayTimeoutTime >= 20 && zeroDelayTimeoutTime < 40 && pollerPaused,
            "a 20 ms GLib timeout fires within 40 ms while a zero-delay CF timer keeps reposting and the helper is blocked");
        if (!zeroDelayDeadlinePoll.dispatched)
            g_source_remove(zeroDelayTimeout);
        if (zeroDelayDeadlinePoll.timer) {
            CFRunLoopTimerInvalidate(zeroDelayDeadlinePoll.timer);
            CFRelease(zeroDelayDeadlinePoll.timer);
        }
        CFRunLoopObserverInvalidate(deadlineObserver);
        CFRelease(deadlineObserver);

        WebCore::MainThreadSharedTimer::shouldSetupPowerObserver() = false;
        auto& sharedTimer = WebCore::MainThreadSharedTimer::singleton();
        static unsigned sharedTimerFires;
        static bool sharedTimerOnMainThread;
        static MonotonicTime sharedTimerRearmed, sharedTimerFired;
        sharedTimer.setFiredFunction([] {
            ++sharedTimerFires;
            sharedTimerOnMainThread = pthread_main_np();
            sharedTimerFired = MonotonicTime::now();
        });
        sharedTimer.setFireInterval(5_s);
        CFRunLoopTimerRef rearmTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.01, 0, 0, 0, ^(CFRunLoopTimerRef) {
            sharedTimerRearmed = MonotonicTime::now();
            WebCore::MainThreadSharedTimer::singleton().setFireInterval(100_ms);
        });
        CFRunLoopAddTimer(CFRunLoopGetMain(), rearmTimer, kCFRunLoopCommonModes);
        runUntil(^{ return !!sharedTimerFires; }, 2);
        latency = (sharedTimerFired - sharedTimerRearmed).milliseconds();
        printf("shared timer with blocked poller fired %.1f ms after rearming\n", latency);
        check(sharedTimerFires == 1 && sharedTimerOnMainThread && pollerPaused && latency >= 100 && latency < 160,
            "the shared timer's earlier deadline fires on the main thread while the poller is blocked");
        CFRunLoopTimerInvalidate(rearmTimer);
        CFRelease(rearmTimer);
        pthread_mutex_lock(&pollerLock);
        pausePoller = false;
        pthread_cond_signal(&pollerCondition);
        pthread_mutex_unlock(&pollerLock);

        // Idle sources each added by the previous one, with nothing else waking the run loop.
        static unsigned chained;
        struct Chain {
            static gboolean step(gpointer)
            {
                if (++chained < 50)
                    g_idle_add(step, nullptr);
                return G_SOURCE_REMOVE;
            }
        };
        MonotonicTime chainStart = MonotonicTime::now();
        g_idle_add(Chain::step, nullptr);
        runUntil(^{ return chained >= 50; }, 5);
        double chainTime = (MonotonicTime::now() - chainStart).milliseconds();
        printf("50 chained idle sources in %.1f ms\n", chainTime);
        check(chained >= 50 && chainTime < 500, "an idle source added from the main thread runs without an outside wake-up");

        // A repeating idle source shares the main thread with run-loop timers.
        static unsigned idles, ticks;
        guint idle = g_idle_add([](gpointer) -> gboolean {
            ++idles;
            return G_SOURCE_CONTINUE;
        }, nullptr);
        CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.01, 0.01, 0, 0, ^(CFRunLoopTimerRef) {
            ++ticks;
        });
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
        runUntil(^{ return false; }, 1);
        CFRunLoopTimerInvalidate(timer);
        CFRelease(timer);
        g_source_remove(idle);
        printf("repeating idle: %u dispatches, run-loop timer: %u fires in 1 s\n", idles, ticks);
        check(ticks >= 50 && idles >= 50, "a repeating idle source and a run-loop timer both advance");

        // Self-reposting RunLoop work shares the main thread with a CF source and a 2 ms timer.
        static unsigned reposts, repostsAtTimer, repostsAtSource;
        static MonotonicTime repostStart, repostTimerFired, repostSourceFired;
        static bool repostFinished;
        CFRunLoopSourceContext repostSourceContext { };
        repostSourceContext.perform = [](void*) {
            repostSourceFired = MonotonicTime::now();
            repostsAtSource = reposts;
        };
        CFRunLoopSourceRef repostSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 1, &repostSourceContext);
        CFRunLoopAddSource(CFRunLoopGetMain(), repostSource, kCFRunLoopCommonModes);
        CFRunLoopTimerRef repostTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1, 0, 0, 0, ^(CFRunLoopTimerRef) {
            repostTimerFired = MonotonicTime::now();
            repostsAtTimer = reposts;
        });
        CFRunLoopAddTimer(CFRunLoopGetMain(), repostTimer, kCFRunLoopCommonModes);
        struct Reposter {
            static void step()
            {
                ++reposts;
                if ((!repostTimerFired || !repostSourceFired) && MonotonicTime::now() - repostStart < 100_ms)
                    RunLoop::mainSingleton().dispatch(step);
                else {
                    repostFinished = true;
                    CFRunLoopStop(CFRunLoopGetMain());
                }
            }
        };
        RunLoop::mainSingleton().dispatch([repostSource, repostTimer] {
            repostStart = MonotonicTime::now();
            CFRunLoopTimerSetNextFireDate(repostTimer, CFAbsoluteTimeGetCurrent() + 0.002);
            CFRunLoopSourceSignal(repostSource);
            Reposter::step();
        });
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2, false);
        double repostTimerLatency = (repostTimerFired - repostStart).milliseconds();
        double repostSourceLatency = (repostSourceFired - repostStart).milliseconds();
        printf("self-reposting RunLoop: %u functions, CF timer after %.2f ms, CF source after %.2f ms\n", reposts, repostTimerLatency, repostSourceLatency);
        check(repostTimerFired && repostTimerLatency >= 2 && repostTimerLatency < 10 && repostsAtTimer && repostsAtTimer < reposts,
            "a CF timer fires within a few ms while RunLoop work keeps reposting");
        check(repostSourceFired && repostSourceLatency < 10 && repostsAtSource && repostsAtSource < reposts,
            "a CF source runs within a few ms while RunLoop work keeps reposting");
        check(repostFinished && reposts > 1, "self-reposting RunLoop work completes after CF callbacks run");
        CFRunLoopTimerInvalidate(repostTimer);
        CFRelease(repostTimer);
        CFRunLoopSourceInvalidate(repostSource);
        CFRelease(repostSource);

        for (bool blockedPoller : { false, true }) {
            for (bool useWorkQueue : { false, true }) {
                for (bool suspend : { false, true }) {
                    SharedTimerUnderLoad test { useWorkQueue, suspend, blockedPoller };
                    test.run();
                }
            }
        }

        // A ready shared timer competes with several generations of main WorkQueue work,
        // including a generation that suspends the CF cycle. No bus or descriptor source is ready.
        static unsigned continuations, continuationsAtTimer;
        static bool priorityTimerFired;
        sharedTimer.setFiredFunction(nullptr);
        sharedTimer.setFiredFunction([] {
            continuationsAtTimer = continuations;
            priorityTimerFired = true;
        });
        WorkQueue::mainSingleton().dispatch([] {
            WebCore::MainThreadSharedTimer::singleton().setFireInterval(0_s);
            WorkQueue::mainSingleton().dispatch([] {
                ++continuations;
                RunLoop::mainSingleton().suspendFunctionDispatchForCurrentCycle();
                WorkQueue::mainSingleton().dispatch([] {
                    ++continuations;
                    WorkQueue::mainSingleton().dispatch([] {
                        ++continuations;
                    });
                });
            });
        });
        runUntil(^{ return priorityTimerFired && continuations == 3; }, 2);
        printf("Main WorkQueue continuations at shared timer: %u\n", continuationsAtTimer);
        check(priorityTimerFired && continuations == 3,
            "the shared timer and every continuation of a main WorkQueue chain finish across a suspended cycle");
        sharedTimer.setFiredFunction(nullptr);
        sharedTimer.setFiredFunction([] {
            ++sharedTimerFires;
        });

        // WK1 hosts can run WebCore in a private CFRunLoop mode.
        CFStringRef privateMode = CFSTR("WebKitGLibContextTestMode");
        sharedTimer.invalidate();
        WebCore::MainThreadSharedTimer::addRunLoopMode(privateMode);
        static bool privateRunLoopWork, privateMainThreadWork, privateGLibWork;
        RunLoop::mainSingleton().dispatch([] {
            privateRunLoopWork = true;
        });
        callOnMainThread([] {
            privateMainThreadWork = true;
        });
        g_timeout_add(10, [](gpointer) -> gboolean {
            privateGLibWork = true;
            return G_SOURCE_REMOVE;
        }, nullptr);
        sharedTimerFires = 0;
        sharedTimer.setFireInterval(10_ms);
        MonotonicTime privateModeDeadline = MonotonicTime::now() + 2_s;
        while (!sharedTimerFires && MonotonicTime::now() < privateModeDeadline)
            CFRunLoopRunInMode(privateMode, 0.1, true);
        check(sharedTimerFires == 1, "the shared timer fires in a registered WK1 private mode");
        check(!privateRunLoopWork && !privateMainThreadWork && !privateGLibWork,
            "a private mode leaves RunLoop, callOnMainThread and GLib work pending");
        runUntil(^{ return privateRunLoopWork && privateMainThreadWork && privateGLibWork; }, 2);
        check(privateRunLoopWork && privateMainThreadWork && privateGLibWork,
            "pending private-mode work runs on return to common modes");
        check(sharedTimerFires == 1, "a private-mode shared timer does not fire again in common modes");

        CFStringRef secondPrivateMode = CFSTR("WebKitGLibContextSecondTestMode");
        sharedTimer.setFireInterval(10_ms);
        WebCore::MainThreadSharedTimer::addRunLoopMode(secondPrivateMode);
        CFRunLoopRunInMode(secondPrivateMode, 0.05, false);
        check(sharedTimerFires == 2, "a private mode registered after arming receives the shared timer once");
        sharedTimer.setFireInterval(10_ms);
        sharedTimer.stop();
        CFRunLoopRunInMode(privateMode, 0.05, false);
        runUntil(^{ return false; }, 0.05);
        check(sharedTimerFires == 2, "stopping the shared timer cancels both mode paths");

        // Each descriptor dispatch queues RunLoop work; suspension defers one batch in FIFO order.
        int pipeFDs[2];
        pipe(pipeFDs);
        static unsigned delivered, followed, overtaken, unexpectedOvertakes, outOfOrder;
        static void (^deliveryHook)();
        static bool suspendOnDelivery;
        g_unix_fd_add_full(G_PRIORITY_DEFAULT, pipeFDs[0], G_IO_IN, [](gint fd, GIOCondition, gpointer) -> gboolean {
            char byte;
            if (read(fd, &byte, 1) == 1) {
                if (followed != delivered) {
                    ++overtaken;
                    if (!suspendOnDelivery || !RunLoop::mainSingleton().wasFunctionDispatchSuspended() || followed + 1 != delivered)
                        ++unexpectedOvertakes;
                }
                ++delivered;
                if (deliveryHook)
                    deliveryHook();
                RunLoop::mainSingleton().dispatch([delivery = delivered] {
                    if (++followed != delivery)
                        ++outOfOrder;
                    if (suspendOnDelivery)
                        RunLoop::mainSingleton().suspendFunctionDispatchForCurrentCycle();
                });
            }
            return G_SOURCE_CONTINUE;
        }, nullptr, nullptr);
        int writeFD = pipeFDs[1];
        // The run loop's Exit and BeforeWaiting observers mark the passes of the run loop.
        static unsigned passes;
        CFRunLoopObserverRef passObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
            ++passes;
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), passObserver, kCFRunLoopCommonModes);
        static unsigned passesAtFirstDelivery, passesAtLastDelivery;
        deliveryHook = ^{
            if (delivered == 1)
                passesAtFirstDelivery = passes;
            passesAtLastDelivery = passes;
        };
        MonotonicTime backlogStart = MonotonicTime::now();
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            char backlog[200] = { };
            write(writeFD, backlog, sizeof(backlog));
        });
        runUntil(^{ return delivered >= 200 && followed == delivered; }, 5);
        double backlogTime = (MonotonicTime::now() - backlogStart).milliseconds();
        printf("200-byte backlog: %u delivered in %.1f ms, %u dispatches ahead of the previous one's RunLoop work, %u run-loop passes between the first and the last delivery\n", delivered, backlogTime, overtaken, passesAtLastDelivery - passesAtFirstDelivery);
        check(delivered == 200 && followed == delivered && backlogTime < 500, "a default-priority backlog and all its RunLoop work drain promptly");
        check(!overtaken && !outOfOrder, "RunLoop work queued by a dispatch runs before the next dispatch in FIFO order");

        // Suspended RunLoop work completes between deliveries; the outer cycle holds after the drain.
        static unsigned passesAtFirstSuspendedDelivery, passesAtLastSuspendedDelivery, overtakenBefore;
        overtakenBefore = overtaken;
        suspendOnDelivery = true;
        deliveryHook = ^{
            if (delivered == 201)
                passesAtFirstSuspendedDelivery = passes;
            passesAtLastSuspendedDelivery = passes;
        };
        MonotonicTime suspendedBacklogStart = MonotonicTime::now();
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            char backlog[20] = { };
            write(writeFD, backlog, sizeof(backlog));
        });
        runUntil(^{ return delivered >= 220 && followed == delivered; }, 5);
        double suspendedBacklogTime = (MonotonicTime::now() - suspendedBacklogStart).milliseconds();
        unsigned passesAfterSuspendedDrain = passes;
        printf("20-byte backlog with suspended cycles: %u delivered in %.1f ms, %u deliveries during suspended function dispatch, %u run-loop passes between the first and the last delivery, %u after the drain\n", delivered - 200, suspendedBacklogTime, overtaken - overtakenBefore, passesAtLastSuspendedDelivery - passesAtFirstSuspendedDelivery, passesAfterSuspendedDrain - passesAtLastSuspendedDelivery);
        check(delivered == 220 && followed == delivered && suspendedBacklogTime < 500 && !outOfOrder,
            "a suspended-cycle backlog and all its RunLoop work drain promptly in order");
        check(!unexpectedOvertakes, "only an explicitly suspended round defers RunLoop work past one descriptor delivery");
        check(passesAfterSuspendedDrain > passesAtLastSuspendedDelivery, "the run loop passes after a drain that suspended the cycle");
        CFRunLoopObserverInvalidate(passObserver);
        CFRelease(passObserver);
        sharedTimer.invalidate();
        sharedTimer.setFiredFunction(nullptr);

        // One bus watch dispatch pops one queued message at RunLoopDispatcher priority.
        static GSourceFuncs busFunctions {
            [](GSource* source, gint* timeout) -> gboolean {
                *timeout = -1;
                return reinterpret_cast<BusBurstSource*>(source)->delivered < BusBurstSource::messageCount;
            },
            [](GSource* source) -> gboolean {
                return reinterpret_cast<BusBurstSource*>(source)->delivered < BusBurstSource::messageCount;
            },
            [](GSource* source, GSourceFunc, gpointer) -> gboolean {
                auto* bus = reinterpret_cast<BusBurstSource*>(source);
                if (bus->followed != bus->delivered)
                    ++bus->overtaken;
                unsigned message = bus->messages[bus->delivered];
                if (message != bus->delivered++)
                    ++bus->outOfOrder;
                RunLoop::mainSingleton().dispatch([bus, message] {
                    if (message != bus->followed++)
                        ++bus->outOfOrder;
                });
                return bus->delivered < BusBurstSource::messageCount ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
            },
            nullptr, nullptr, nullptr
        };
        auto* bus = reinterpret_cast<BusBurstSource*>(g_source_new(&busFunctions, sizeof(BusBurstSource)));
        for (unsigned i = 0; i < BusBurstSource::messageCount; ++i)
            bus->messages[i] = i;
        g_source_set_priority(&bus->source, RunLoopSourcePriority::RunLoopDispatcher);
        CFRunLoopObserverRef busObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 1999999, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
            if (!bus->delivered)
                return;
            if (!bus->observerPasses++)
                bus->messagesAtFirstObserver = bus->delivered;
            if (bus->delivered < BusBurstSource::messageCount)
                ++bus->observersDuringBurst;
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), busObserver, kCFRunLoopCommonModes);
        g_source_attach(&bus->source, g_main_context_default());
        runUntil(^{ return bus->delivered == BusBurstSource::messageCount && bus->followed == bus->delivered && bus->observerPasses; }, 2);
        printf("bus burst: %u messages, %u at first rendering observer, %u observers during burst, %u RunLoop overtakes\n",
            bus->delivered, bus->messagesAtFirstObserver, bus->observersDuringBurst, bus->overtaken);
        check(bus->delivered == BusBurstSource::messageCount && bus->observerPasses
            && bus->messagesAtFirstObserver == BusBurstSource::messageCount && !bus->observersDuringBurst,
            "all 200 bus messages drain before the first rendering observer after delivery starts");
        check(bus->followed == bus->delivered && !bus->outOfOrder && !bus->overtaken,
            "bus messages and their RunLoop callbacks complete in FIFO order before the next message");
        CFRunLoopObserverInvalidate(busObserver);
        CFRelease(busObserver);
        g_source_destroy(&bus->source);
        g_source_unref(&bus->source);

        // The first GLib dispatch stays outstanding through its nested RunLoop continuation.
        static GSourceFuncs nestedDrainFunctions {
            [](GSource* source, gint* timeout) -> gboolean {
                *timeout = -1;
                return reinterpret_cast<NestedDrainSource*>(source)->delivered < NestedDrainSource::rounds;
            },
            [](GSource* source) -> gboolean {
                return reinterpret_cast<NestedDrainSource*>(source)->delivered < NestedDrainSource::rounds;
            },
            [](GSource* source, GSourceFunc, gpointer) -> gboolean {
                auto* test = reinterpret_cast<NestedDrainSource*>(source);
                ++test->dispatchDepth;
                if (test->dispatchDepth > test->maxDispatchDepth)
                    test->maxDispatchDepth = test->dispatchDepth;
                if (test->nested)
                    ++test->nestedDispatches;
                if (++test->delivered == 1) {
                    RunLoop::mainSingleton().dispatch([test] {
                        test->deadlinePendingAtEntry = !test->timeoutFires && MonotonicTime::now() - test->timeoutAdded < 5_ms;
                        test->nested = true;
                        test->nestedStart = MonotonicTime::now();
                        // A signaled CF source keeps BeforeWaiting observers out of this nested pump.
                        CFRunLoopSourceContext context { };
                        context.info = test;
                        context.perform = [](void* info) {
                            auto& test = *static_cast<NestedDrainSource*>(info);
                            ++test.controlCallouts;
                            CFRunLoopSourceSignal(test.controlSource);
                        };
                        test->controlSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 1, &context);
                        CFRunLoopAddSource(CFRunLoopGetMain(), test->controlSource, kCFRunLoopCommonModes);
                        CFRunLoopSourceSignal(test->controlSource);
                        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.03, false);
                        test->nestedEnd = MonotonicTime::now();
                        test->nested = false;
                        CFRunLoopSourceInvalidate(test->controlSource);
                        CFRelease(test->controlSource);
                        test->controlSource = nullptr;
                        --test->dispatchDepth;
                    });
                } else
                    --test->dispatchDepth;
                return test->delivered < NestedDrainSource::rounds ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
            },
            nullptr, nullptr, nullptr
        };
        auto* nestedDrain = reinterpret_cast<NestedDrainSource*>(g_source_new(&nestedDrainFunctions, sizeof(NestedDrainSource)));
        g_source_set_priority(&nestedDrain->source, RunLoopSourcePriority::RunLoopDispatcher);
        pausePoller = true;
        g_main_context_wakeup(g_main_context_default());
        pauseDeadline = MonotonicTime::now() + 2_s;
        while (!pollerPaused && MonotonicTime::now() < pauseDeadline)
            usleep(1000);
        CFRunLoopObserverRef nestedObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
            if (nestedDrain->nested)
                ++nestedDrain->nestedWaits;
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), nestedObserver, kCFRunLoopCommonModes);
        nestedDrain->timeoutAdded = MonotonicTime::now();
        guint nestedTimeout = g_timeout_add(5, [](gpointer data) -> gboolean {
            auto& test = *static_cast<NestedDrainSource*>(data);
            ++test.timeoutFires;
            test.timeoutFired = MonotonicTime::now();
            test.timeoutOnMainThread = pthread_main_np();
            if (test.nested)
                ++test.nestedDispatches;
            return G_SOURCE_REMOVE;
        }, nestedDrain);
        // A short common-mode pass prepares the timeout before the ready source is attached.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, false);
        double armedDeadlineDelay = CFRunLoopGetNextTimerFireDate(CFRunLoopGetMain(), kCFRunLoopDefaultMode) - CFAbsoluteTimeGetCurrent();
        bool nestedDeadlineArmed = armedDeadlineDelay > 0 && armedDeadlineDelay <= 0.005;
        g_source_attach(&nestedDrain->source, g_main_context_default());
        runUntil(^{ return nestedDrain->nestedEnd && nestedDrain->delivered == NestedDrainSource::rounds && nestedDrain->timeoutFires; }, 2);
        printf("nested GLib drain: deadline armed %.2f ms ahead, %u rounds, maximum dispatch depth %u, %u nested dispatches, %.2f ms nested loop, %u control callouts, %u nested waits, timeout %.2f ms after add / %.2f ms after nested loop\n",
            armedDeadlineDelay * 1000,
            nestedDrain->delivered, nestedDrain->maxDispatchDepth, nestedDrain->nestedDispatches,
            (nestedDrain->nestedEnd - nestedDrain->nestedStart).milliseconds(), nestedDrain->controlCallouts, nestedDrain->nestedWaits,
            (nestedDrain->timeoutFired - nestedDrain->timeoutAdded).milliseconds(), (nestedDrain->timeoutFired - nestedDrain->nestedEnd).milliseconds());
        check(nestedDeadlineArmed && nestedDrain->deadlinePendingAtEntry && pollerPaused
            && nestedDrain->controlCallouts && !nestedDrain->nestedWaits
            && nestedDrain->nestedEnd - nestedDrain->nestedStart >= 30_ms,
            "a prearmed 5 ms GLib deadline falls due during a 30 ms nested default-mode loop inside a drain's RunLoop callback");
        check(nestedDrain->delivered == NestedDrainSource::rounds && !nestedDrain->dispatchDepth
            && nestedDrain->maxDispatchDepth == 1 && !nestedDrain->nestedDispatches,
            "GLib dispatch does not reenter the drain while its RunLoop callback spins a nested loop");
        check(nestedDrain->timeoutFires == 1 && nestedDrain->timeoutOnMainThread && nestedDrain->nestedEnd
            && nestedDrain->timeoutFired >= nestedDrain->nestedEnd && nestedDrain->timeoutFired - nestedDrain->timeoutAdded < 500_ms,
            "the GLib timeout fires once on the main thread after the nested loop returns");
        if (!nestedDrain->timeoutFires)
            g_source_remove(nestedTimeout);
        CFRunLoopObserverInvalidate(nestedObserver);
        CFRelease(nestedObserver);
        g_source_destroy(&nestedDrain->source);
        g_source_unref(&nestedDrain->source);
        pthread_mutex_lock(&pollerLock);
        pausePoller = false;
        pthread_cond_signal(&pollerCondition);
        pthread_mutex_unlock(&pollerLock);

        printf("descriptor helper: %u polls, %u with a finite timeout\n", helperPolls.load(), finiteHelperPolls.load());
        check(helperPolls && !finiteHelperPolls, "the descriptor helper only polls with an infinite timeout");

        finished = true;
        printf("%s\n", failed ? "FAIL" : "PASS");
        return failed ? 1 : 0;
    }
}
