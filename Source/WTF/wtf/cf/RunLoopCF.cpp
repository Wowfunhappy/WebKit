/*
 * Copyright (C) 2010-2019 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include <wtf/RunLoop.h>

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
// MAVERICKS_BACKPORT: extra C includes for the 10.9 GCD main-RunLoop timer path below.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <wtf/AutodrainedPool.h>
// MAVERICKS_BACKPORT: for the out-of-line mainDispatchTimers() map of cancellable GCD timers below.
#include <wtf/NeverDestroyed.h>
#include <wtf/OSObjectPtr.h>
#include <wtf/SchedulePair.h>

namespace {
// MAVERICKS_BACKPORT: cancellable GCD timers for the main RunLoop, stored out-of-line so
// RunLoop::TimerBase::stop()/dtor can cancel them WITHOUT enlarging the heavily-included
// RunLoop.h. Only main-RunLoop (main-thread) timers live here and are only touched on the
// main thread; the lock is belt-and-suspenders. A cancellable dispatch_source (vs the old
// uncancellable dispatch_after) is what makes the rapid-navigation teardown crash impossible.
static WTF::Lock s_mainDispatchTimerLock;
static WTF::HashMap<void*, WTF::OSObjectPtr<dispatch_source_t>>& mainDispatchTimers()
{
    static WTF::NeverDestroyed<WTF::HashMap<void*, WTF::OSObjectPtr<dispatch_source_t>>> timers;
    return timers;
}
}

namespace WTF {

static RetainPtr<CFRunLoopTimerRef> createTimer(Seconds interval, bool repeat, void(*timerFired)(CFRunLoopTimerRef, void*), void* info)
{
    CFRunLoopTimerContext context = { 0, info, 0, 0, 0 };
    Seconds repeatInterval = repeat ? interval : 0_s;
    return adoptCF(CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + interval.seconds(), repeatInterval.seconds(), 0, 0, timerFired, &context));
}

void RunLoop::performWork(void* context)
{
    AutodrainedPool pool;
    static_cast<RunLoop*>(context)->performWork();
}

RunLoop::RunLoop()
    : m_runLoop(CFRunLoopGetCurrent())
{
    CFRunLoopSourceContext context = { 0, this, 0, 0, 0, 0, 0, 0, 0, performWork };
    lazyInitialize(m_runLoopSource, adoptCF(CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)));
    CFRunLoopAddSource(m_runLoop.get(), m_runLoopSource.get(), kCFRunLoopCommonModes);
}

RunLoop::~RunLoop()
{
    CFRunLoopSourceInvalidate(m_runLoopSource.get());
}

void RunLoop::wakeUp()
{
    // MAVERICKS_BACKPORT: main-RunLoop wakeUp goes through the main GCD queue (rationale below).
    // 10.9: for the main RunLoop, wake via the main GCD queue rather than
    // CFRunLoopSourceSignal+CFRunLoopWakeUp. NOTE (2026-06-14): this is NOT the
    // old "GC clobbers the source" reason (that corruption is gone now that the main
    // thread runs a real CFRunLoop). The real reason is that this WTF RunLoop's custom
    // source is not reliably serviced by xpc_main's NSRunLoop on 10.9 — signalling it
    // delivers the first wake but does NOT reliably re-wake the loop once rendering goes
    // idle, freezing requestAnimationFrame to ~0.5fps (verified by reverting this). The
    // main dispatch queue IS serviced in all run-loop modes, so it wakes reliably.
    // TODO: the cleaner fix is to add m_runLoopSource to the exact mode xpc_main runs.
    if (this == &RunLoop::mainSingleton()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            performWork(this);
        });
        return;
    }
    CFRunLoopSourceSignal(m_runLoopSource.get());
    CFRunLoopWakeUp(m_runLoop.get());
}

RunLoop::CycleResult RunLoop::cycle(RunLoopMode mode)
{
    CFTimeInterval timeInterval = 0.05;
    CFRunLoopRunInMode(mode, timeInterval, true);
    return CycleResult::Continue;
}

void RunLoop::run()
{
    AutodrainedPool pool;
    CFRunLoopRun();
}

void RunLoop::stop()
{
    ASSERT(m_runLoop == CFRunLoopGetCurrent());
    CFRunLoopStop(m_runLoop.get());
}

void RunLoop::dispatch(const SchedulePairHashSet& schedulePairs, Function<void()>&& function)
{
    // MAVERICKS_BACKPORT: WK2 XPC services run dispatch_main(), which pumps GCD but
    // not CFRunLoop. CFRunLoopAddTimer() on the main loop would silently drop
    // the timer because nothing pumps it. Route everything through
    // RunLoop::mainSingleton().dispatch(), which honors our dispatch_main
    // wakeUp path (see wakeUp() above).
    UNUSED_PARAM(schedulePairs);
    RunLoop::mainSingleton().dispatch(WTF::move(function));
}

// RunLoop::Timer

RunLoop::TimerBase::TimerBase(Ref<RunLoop>&& runLoop, ASCIILiteral description)
    : m_runLoop(WTF::move(runLoop))
    , m_description(description)
{
    m_runLoop->registerTimer(*this);
}

RunLoop::TimerBase::~TimerBase()
{
    stop();
    m_runLoop->unregisterTimer(*this);
}

void RunLoop::TimerBase::start(Seconds interval, bool repeat)
{
    // MAVERICKS_BACKPORT — ROOT-CAUSE FIX (2026-06-11) for the rapid-navigation crash.
    // WK2 XPC services have dispatch_main() semantics, so the main RunLoop needs a
    // GCD-driven timer (a plain CFRunLoopAddTimer firing rate differs and busy-loops
    // here — the rendering/heartbeat scheduling on this backport is tuned to the GCD
    // cadence). The OLD approach used dispatch_after(), which CANNOT be cancelled, so
    // during a fast-navigation teardown an orphaned block could fire after its block
    // heap was freed/corrupted → SIGBUS at a garbage code address inside
    // _dispatch_client_callout, BEFORE any in-block guard could run. The fix: use a
    // CANCELLABLE dispatch_source timer instead. Same GCD cadence (no busy-loop, no
    // rendering regression), but stop()/dtor calls dispatch_source_cancel() so a
    // torn-down timer's handler never fires → the orphaned-block crash is impossible.
    bool isMain = (this->m_runLoop.ptr() == &RunLoop::mainSingleton());
    if (m_timer) {
        bool canReschedule = !repeat && !CFRunLoopTimerDoesRepeat(m_timer.get()) && CFRunLoopTimerIsValid(m_timer.get());
        // MAVERICKS_BACKPORT: never CF-reschedule a main-RunLoop timer; it uses the GCD dispatch_source path below.
        if (canReschedule && !isMain) {
            CFRunLoopTimerSetNextFireDate(m_timer.get(), CFAbsoluteTimeGetCurrent() + interval.seconds());
            return;
        }

        stop();
    }

    m_timer = createTimer(interval, repeat, [] (CFRunLoopTimerRef cfTimer, void* context) {
        AutodrainedPool pool;

        auto timer = static_cast<TimerBase*>(context);
        if (!CFRunLoopTimerDoesRepeat(cfTimer))
            CFRunLoopTimerInvalidate(cfTimer);

        timer->fired();
    }, this);

    // MAVERICKS_BACKPORT: main-RunLoop timers use a cancellable GCD dispatch_source (see below).
    if (isMain) {
        // Cancellable GCD timer for the main RunLoop. A NATIVE repeating dispatch_source re-fires
        // itself — the handler NEVER touches the timer after fired(). An earlier variant made every
        // timer one-shot and re-armed by calling start() AFTER fired() returned; that is a
        // use-after-free when a repeating timer's callback destroys its owner (TimerBase is not
        // ref-counted), an access pattern upstream's CF-internal rescheduling never has. The source
        // is tracked in mainDispatchTimers() so stop()/dtor cancels it; cancel + the handler both run
        // on the main thread (serialized), so a cancelled timer's handler never runs afterward — no
        // uncancellable orphaned block to fire after teardown (the rapid-navigation crash root cause).
        // (The old worry that a native repeating source pegs CPU when the handler outlasts the interval
        // was a mis-attribution — the active-page CPU peg was the TiledCoreAnimationDrawingArea render
        // loop, fixed separately; main-RunLoop timers here are infrequent with quick handlers.)
        OSObjectPtr<dispatch_source_t> source = adoptOSObject(dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue()));
        int64_t intervalNsec = static_cast<int64_t>(interval.seconds() * NSEC_PER_SEC);
        uint64_t repeatNsec = repeat ? static_cast<uint64_t>(std::max<int64_t>(intervalNsec, 1)) : DISPATCH_TIME_FOREVER;
        dispatch_source_set_timer(source.get(), dispatch_time(DISPATCH_TIME_NOW, intervalNsec), repeatNsec, 0);
        TimerBase* timerSelf = this;
        bool isRepeat = repeat;
        dispatch_source_set_event_handler(source.get(), ^{
            AutodrainedPool pool;
            if (!isRepeat) {
                // One-shot: invalidate the CF validity token and cancel+drop our source BEFORE
                // fired(), so the handler makes no access to the timer after fired() (which may
                // re-arm via start() — registering a fresh source — or destroy the timer).
                if (timerSelf->m_timer)
                    CFRunLoopTimerInvalidate(timerSelf->m_timer.get());
                Locker locker { s_mainDispatchTimerLock };
                if (auto cancelled = mainDispatchTimers().take(timerSelf))
                    dispatch_source_cancel(cancelled.get());
            }
            timerSelf->fired();
        });
        {
            Locker locker { s_mainDispatchTimerLock };
            mainDispatchTimers().set(this, source);
        }
        dispatch_resume(source.get());
        return;
    }

    CFRunLoopAddTimer(m_runLoop->m_runLoop.get(), m_timer.get(), kCFRunLoopCommonModes);
}

void RunLoop::TimerBase::stop()
{
    // MAVERICKS_BACKPORT: cancel the main-thread GCD timer (if any). Because this runs on the
    // main thread, serialized with the dispatch_source's event handler, a cancelled
    // source's handler will never run afterwards — so an in-flight/torn-down timer can
    // no longer fire an orphaned block (the rapid-navigation teardown crash).
    {
        Locker locker { s_mainDispatchTimerLock };
        if (auto source = mainDispatchTimers().take(this))
            dispatch_source_cancel(source.get());
    }

    if (!m_timer)
        return;
    
    CFRunLoopTimerInvalidate(m_timer.get());
    m_timer = nullptr;
}

bool RunLoop::TimerBase::isActive() const
{
    return m_timer && CFRunLoopTimerIsValid(m_timer.get());
}

Seconds RunLoop::TimerBase::secondsUntilFire() const
{
    if (isActive())
        return std::max<Seconds>(Seconds { CFRunLoopTimerGetNextFireDate(m_timer.get()) - CFAbsoluteTimeGetCurrent() }, 0_s);
    return 0_s;
}

} // namespace WTF
