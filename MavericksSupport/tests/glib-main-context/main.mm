// Serves GLib's default context from the main CFRunLoop, as WebContent does, and checks timeouts,
// idle sources, run-loop fairness, and that RunLoop work queued by a dispatched callback runs before
// the context's next dispatch while an fd source's backlog drains.

#include "config.h"
#include "GLibMainContextMavericks.h"

#import <Foundation/Foundation.h>
#include <glib-unix.h>
#include <glib.h>
#include <atomic>
#include <cstdio>
#include <pthread.h>
#include <unistd.h>
#include <wtf/MainThread.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RunLoop.h>

static bool failed;

static void check(bool condition, const char* what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition)
        failed = true;
}

static void runUntil(bool (^done)(), double seconds)
{
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && [limit timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:limit];
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

        // A default-priority descriptor source with a backlog, written from another thread. Each
        // dispatch queues RunLoop work, which runs before the next dispatch.
        int pipeFDs[2];
        pipe(pipeFDs);
        static unsigned delivered, followed, overtaken;
        g_unix_fd_add_full(G_PRIORITY_DEFAULT, pipeFDs[0], G_IO_IN, [](gint fd, GIOCondition, gpointer) -> gboolean {
            char byte;
            if (read(fd, &byte, 1) == 1) {
                if (followed != delivered)
                    ++overtaken;
                ++delivered;
                RunLoop::mainSingleton().dispatch([] {
                    followed = delivered;
                });
            }
            return G_SOURCE_CONTINUE;
        }, nullptr, nullptr);
        int writeFD = pipeFDs[1];
        MonotonicTime backlogStart = MonotonicTime::now();
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            char backlog[200] = { };
            write(writeFD, backlog, sizeof(backlog));
        });
        runUntil(^{ return delivered >= 200 && followed == delivered; }, 5);
        double backlogTime = (MonotonicTime::now() - backlogStart).milliseconds();
        printf("200-byte backlog: %u delivered in %.1f ms, %u dispatches ahead of the previous one's RunLoop work\n", delivered, backlogTime, overtaken);
        check(delivered == 200 && backlogTime < 500, "a default-priority backlog drains promptly");
        check(!overtaken, "RunLoop work queued by a dispatch runs before the next dispatch");

        finished = true;
        printf("%s\n", failed ? "FAIL" : "PASS");
        return failed ? 1 : 0;
    }
}
