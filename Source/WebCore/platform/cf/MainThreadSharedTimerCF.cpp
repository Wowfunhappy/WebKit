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
// MAVERICKS_BACKPORT: isMainThread() and the extra-run-loop-mode vector below (see addRunLoopMode).
#include <wtf/MainThread.h>
#include <wtf/Vector.h>
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

// MAVERICKS_BACKPORT: app-registered run-loop modes the shared timer must also fire in (in
// addition to kCFRunLoopCommonModes), so WebCore timers advance while an app pumps a private
// mode. Only ever touched on the main thread. See MainThreadSharedTimer::addRunLoopMode().
static Vector<RetainPtr<CFStringRef>>& extraTimerRunLoopModes()
{
    static NeverDestroyed<Vector<RetainPtr<CFStringRef>>> modes;
    return modes;
}

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

// MAVERICKS_BACKPORT: register an extra run-loop mode so the shared timer also fires while an app pumps a private mode; called from WK1's scheduleInRunLoop:forMode:.
void MainThreadSharedTimer::addRunLoopMode(CFStringRef mode)
{
    ASSERT(isMainThread());
    for (auto& existing : extraTimerRunLoopModes()) {
        if (CFEqual(existing.get(), mode))
            return;
    }
    extraTimerRunLoopModes().append(mode);

    // If the timer already exists, start firing it in this mode now; otherwise setFireInterval()
    // will pick the mode up from extraTimerRunLoopModes() when it creates the timer.
    if (sharedTimer())
        CFRunLoopAddTimer(CFRunLoopGetMain(), sharedTimer().get(), mode);
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
        // MAVERICKS_BACKPORT: addRunLoopMode() below adds this same timer to CFRunLoopGetMain() when
        // a WK1 host registers a private mode, and a CFRunLoopTimer belongs to one run loop, so both
        // sites have to name the same one. Naming the main run loop here says which.
        // CFRunLoopAddTimer(CFRunLoopGetCurrent(), sharedTimer().get(), kCFRunLoopCommonModes);
        CFRunLoopAddTimer(CFRunLoopGetMain(), sharedTimer().get(), kCFRunLoopCommonModes);

        // MAVERICKS_BACKPORT: also install in any app-registered private modes (see addRunLoopMode).
        for (auto& mode : extraTimerRunLoopModes())
            CFRunLoopAddTimer(CFRunLoopGetMain(), sharedTimer().get(), mode.get());
#endif

        setupPowerObserver();

        return;
    }

    CFRunLoopTimerSetNextFireDate(sharedTimer().get(), fireDate);
}

void MainThreadSharedTimer::stop()
{
    if (!sharedTimer())
        return;

    CFRunLoopTimerSetNextFireDate(sharedTimer().get(), kCFTimeIntervalDistantFuture);
}

} // namespace WebCore
