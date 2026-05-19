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

    // 10.9 backport: WK2 XPC services run dispatch_main() which doesn't pump
    // CFRunLoop timers. Schedule a parallel dispatch_after that fires the
    // shared timer on the main GCD queue. timerFired calls
    // sharedTimerFiredInternal which walks the heap — it's idempotent, so
    // a double-fire is safe (second call sees an empty heap or no-due
    // timers). DON'T push CFRunLoopTimer to DistantFuture: that races with
    // a subsequent setFireInterval call's CFRunLoopTimerSetNextFireDate,
    // causing the runloop timer to stop firing for repeated cycles.
    CFRunLoopTimerRef timerRef = (CFRunLoopTimerRef)CFRetain(sharedTimer().get());
    dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval.value() * NSEC_PER_SEC));
    dispatch_after(when, dispatch_get_main_queue(), ^{
        // Only fire if this is still the active shared timer.
        if (sharedTimer().get() == timerRef && CFRunLoopTimerIsValid(timerRef))
            timerFired(timerRef, nullptr);
        CFRelease(timerRef);
    });
}

void MainThreadSharedTimer::stop()
{
    if (!sharedTimer())
        return;

    CFRunLoopTimerSetNextFireDate(sharedTimer().get(), kCFTimeIntervalDistantFuture);
}

} // namespace WebCore
