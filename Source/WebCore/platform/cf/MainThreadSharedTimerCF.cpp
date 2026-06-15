/*
 * Copyright (C) 2006-2016 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "MainThreadSharedTimer.h"

#include <wtf/AutodrainedPool.h>
#include <wtf/RunLoop.h>
#include <wtf/cf/NotificationCenterCF.h>

#if PLATFORM(MAC)
#import "PowerObserverMac.h"
#import <wtf/NeverDestroyed.h>
#elif PLATFORM(IOS_FAMILY)
#import "WebCoreThreadInternal.h"
#import "WebCoreThreadRun.h"
#endif

namespace WebCore {

static RetainPtr<CFRunLoopTimerRef>& NODELETE sharedTimer()
{
    static NeverDestroyed<RetainPtr<CFRunLoopTimerRef>> sharedTimer;
    return sharedTimer;
}
static void timerFired(CFRunLoopTimerRef, void*);

static const CFTimeInterval kCFTimeIntervalDistantFuture = std::numeric_limits<CFTimeInterval>::max();

bool& MainThreadSharedTimer::shouldSetupPowerObserver()
{
    static bool setup = true;
    return setup;
}

#if PLATFORM(IOS_FAMILY)
static void applicationDidBecomeActive(CFNotificationCenterRef, void*, CFStringRef, const void*, CFDictionaryRef)
{
    WebThreadRun(^{
        MainThreadSharedTimer::restartSharedTimer();
    });
}
#endif

static void setupPowerObserver()
{
    if (!MainThreadSharedTimer::shouldSetupPowerObserver())
        return;
#if PLATFORM(MAC)
    static NeverDestroyed<std::unique_ptr<PowerObserver>> powerObserver;
    if (!powerObserver.get())
        powerObserver.get() = makeUnique<PowerObserver>(MainThreadSharedTimer::restartSharedTimer);
#elif PLATFORM(IOS_FAMILY)
    static bool registeredForApplicationNotification = false;
    if (!registeredForApplicationNotification) {
        registeredForApplicationNotification = true;
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenterSingleton(), nullptr, applicationDidBecomeActive, CFSTR("UIApplicationDidBecomeActiveNotification"), nullptr, CFNotificationSuspensionBehaviorCoalesce);
    }
#endif
}

static void timerFired(CFRunLoopTimerRef, void*)
{
    AutodrainedPool pool;
    MainThreadSharedTimer::singleton().fired();
}

// 10.9 backport: WebCore's shared timer never fires at the right rate on this port. The WK2 XPC
// service's main entry (XPCServiceMain.mm) calls xpc_main()→dispatch_main(); on 10.9 dispatch_main()
// RETURNS, and the code then falls into a bare CFRunLoopRun() loop. After dispatch_main() has run,
// the main GCD queue is no longer wired into the main CFRunLoop, so neither a main-queue dispatch
// source NOR (reliably) the CFRunLoopTimer wakes the run loop — it only wakes on inbound IPC, a
// ~6 Hz heartbeat. That throttles ALL DOM timers, requestAnimationFrame and IntersectionObserver-
// driven lazy loading to ~6 fps.
//
// Drive the shared timer from a re-armable dispatch-source timer on a BACKGROUND queue (reliably
// serviced by libdispatch worker threads), whose handler hops to the main thread by enqueuing the
// work on the main CFRunLoop and waking it. CFRunLoopWakeUp() demonstrably reaches the run loop
// (that is how inbound IPC is delivered), so this fires at the requested rate. (Replaces an earlier
// per-call dispatch_after + generation-counter scheme that, under steady timer churn, had every
// block superseded before it ran, so the timer effectively stopped.)
static dispatch_source_t s_dispatchTimer;

static void dispatchTimerFired(void*)
{
    // Runs on a background queue: hop to the main thread via RunLoop::dispatch — the same
    // CFRunLoopSource-signal mechanism WebKit uses to deliver IPC to the main thread (which is
    // demonstrably serviced here), rather than CFRunLoopPerformBlock which is not.
    RunLoop::mainSingleton().dispatch([] {
        timerFired(nullptr, nullptr);
    });
}

static void ensureDispatchTimer()
{
    if (s_dispatchTimer)
        return;
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    s_dispatchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_event_handler_f(s_dispatchTimer, dispatchTimerFired);
    dispatch_resume(s_dispatchTimer);
}

static void disableDispatchTimer()
{
    if (s_dispatchTimer)
        dispatch_source_set_timer(s_dispatchTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}

void MainThreadSharedTimer::restartSharedTimer()
{
    if (!sharedTimer())
        return;

    MainThreadSharedTimer::singleton().stop();
    timerFired(0, 0);
}

void MainThreadSharedTimer::invalidate()
{
    if (!sharedTimer())
        return;

    CFRunLoopTimerInvalidate(sharedTimer().get());
    sharedTimer() = nullptr;
    disableDispatchTimer();
}

void MainThreadSharedTimer::setFireInterval(Seconds interval)
{
    ASSERT(m_firedFunction);

    CFAbsoluteTime fireDate = CFAbsoluteTimeGetCurrent() + interval.value();
    if (!sharedTimer()) {
        sharedTimer() = adoptCF(CFRunLoopTimerCreate(nullptr, fireDate, kCFTimeIntervalDistantFuture, 0, 0, timerFired, nullptr));
#if PLATFORM(IOS_FAMILY)
        CFRunLoopAddTimer(WebThreadRunLoop(), sharedTimer().get(), kCFRunLoopCommonModes);
#else
        // 10.9 backport: WebKit code can run on libdispatch workers (processing
        // main GCD queue) while the actual CFRunLoopRun that pumps CFRunLoopTimers
        // runs on the original main pthread (XPCServiceMain.mm's CFRunLoopRun).
        // CFRunLoopGetCurrent() called from a worker returns a runloop that isn't
        // pumped. Always register on CFRunLoopGetMain() so the timer fires.
        CFRunLoopAddTimer(CFRunLoopGetMain(), sharedTimer().get(), kCFRunLoopCommonModes);
#endif

        setupPowerObserver();
    } else {
        CFRunLoopTimerSetNextFireDate(sharedTimer().get(), fireDate);
    }

    // 10.9: WebKit's "main" timer code runs on libdispatch worker threads, so creating/
    // re-arming the CFRunLoopTimer above does NOT wake the actual main thread's run loop
    // (the one xpc_main runs) to re-evaluate its fire date — the timer then fires late or
    // not at all. Explicitly wake the main run loop (CFRunLoopWakeUp demonstrably reaches
    // it; it's how inbound IPC is delivered) so the re-armed CFRunLoopTimer fires at the
    // requested time. This is what the dispatch-source workaround was compensating for.
    CFRunLoopWakeUp(CFRunLoopGetMain());

    // 10.9 backport: (re)arm the main-queue dispatch-source timer that actually drives firing
    // under dispatch_main(). dispatch_source_set_timer REPLACES the pending fire date rather than
    // enqueuing another block, so repeated setFireInterval calls (WebKit issues them thousands of
    // times per second) cost nothing and never starve or pile up. Because WebKit always passes the
    // soonest pending interval (= soonestFireTime - now), NOW + interval stays a stable absolute
    // fire time across repeated calls. interval=DISPATCH_TIME_FOREVER makes it one-shot; the next
    // setFireInterval (issued from fired()'s heap walk) re-arms it.
    // 10.9 backport: keep the UIProcess display-link heartbeat alive during short-interval timer
    // bursts (SPA asset loading etc.) so the throttled WebContent main thread runs near 60Hz.
    notifyShortTimerActivityIfNeeded(interval);

    // The dispatch-source timer below is still required for full-rate DOM timers
    // (setInterval/setTimeout): the CFRunLoopTimer + CFRunLoopWakeUp above keeps rAF
    // steady but the worker-thread re-arm path can't drive the loop at sub-heartbeat
    // (~6Hz) rates. The real root is that WebKit's "main" timer code runs on libdispatch
    // worker threads rather than the actual main thread (task #54); once that is fixed,
    // the upstream CFRunLoopTimer fires natively and this dispatch-source can be deleted.
    int64_t ns = interval.value() <= 0 ? 0 : static_cast<int64_t>(interval.value() * NSEC_PER_SEC);
    ensureDispatchTimer();
    dispatch_source_set_timer(s_dispatchTimer, dispatch_time(DISPATCH_TIME_NOW, ns), DISPATCH_TIME_FOREVER, ns / 20);
}

void MainThreadSharedTimer::stop()
{
    if (!sharedTimer())
        return;

    CFRunLoopTimerSetNextFireDate(sharedTimer().get(), kCFTimeIntervalDistantFuture);
    disableDispatchTimer();
}

} // namespace WebCore
