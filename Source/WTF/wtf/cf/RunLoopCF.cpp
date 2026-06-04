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
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <wtf/AutodrainedPool.h>
#include <wtf/SchedulePair.h>

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
    {
        FILE *_d = ((FILE*)0);
        if (_d) {
            uintptr_t bits;
            memcpy(&bits, (char*)this + 0x8, sizeof(bits));
            fprintf(_d, "[PID %d] RunLoop::RunLoop() this=%p m_bits@+8=0x%llx (should be 0x3)\n",
                getpid(), this, (unsigned long long)bits);
            fclose(_d);
        }
    }
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
    {FILE *_d = ((FILE*)0); if (_d) {fprintf(_d, "[RunLoop::wakeUp PID %d] this=%p mainSingleton=%p source=%p loop=%p\n", getpid(), this, &RunLoop::mainSingleton(), m_runLoopSource.get(), m_runLoop.get()); fclose(_d);}}
    // 10.9: WK2 XPC services run dispatch_main(), not CFRunLoopRun(). Their
    // mainSingleton RunLoop instance also has its memory periodically clobbered
    // by JSC's GC (m_runLoopSource is overwritten with NaN-boxed tag bits),
    // making CFRunLoopSourceSignal crash. Bypass it entirely on the main
    // RunLoop and use the dispatch_main GCD queue instead.
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
    // 10.9 backport: WK2 XPC services run dispatch_main(), which pumps GCD but
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
    // 10.9 backport: on the main RunLoop we use dispatch_after (see below), which
    // schedules a block at an absolute NSEC time at block-creation time and does
    // NOT honor CFRunLoopTimerSetNextFireDate. The "canReschedule" shortcut only
    // updates the CFRunLoopTimer's fire date, leaving the in-flight dispatch_after
    // block waiting for its original (potentially far-future) interval. That breaks
    // JSC's DeferredWorkTimer: it pre-arms its timer with a huge sentinel interval
    // (~10 days, s_decade), then later calls setTimeUntilFire(0) to wake immediately
    // — but the dispatch_after fires in 10 days, so async WebAssembly.compile /
    // .instantiate Promises never resolve. Force a stop+restart so the new
    // dispatch_after picks up the new interval.
    bool isMain = (this->m_runLoop.ptr() == &RunLoop::mainSingleton());
    if (m_timer) {
        bool canReschedule = !repeat && !CFRunLoopTimerDoesRepeat(m_timer.get()) && CFRunLoopTimerIsValid(m_timer.get());
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

    // 10.9 backport: WK2 XPC services run dispatch_main() which doesn't pump
    // CFRunLoop timers on the main thread. Use dispatch_after for the main
    // RunLoop and check m_timer validity at fire time for cancellation.
    if (isMain) {
        CFRunLoopTimerRef timerRef = (CFRunLoopTimerRef)CFRetain(m_timer.get());
        TimerBase* timerSelf = this;
        bool isRepeat = repeat;
        Seconds nextInterval = interval;
        dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval.seconds() * NSEC_PER_SEC));
        dispatch_after(when, dispatch_get_main_queue(), ^{
            if (!CFRunLoopTimerIsValid(timerRef)) {
                CFRelease(timerRef);
                return;
            }
            AutodrainedPool pool;
            if (!isRepeat)
                CFRunLoopTimerInvalidate(timerRef);
            timerSelf->fired();
            bool shouldRepeat = isRepeat && CFRunLoopTimerIsValid(timerRef);
            CFRelease(timerRef);
            if (shouldRepeat)
                timerSelf->start(nextInterval, true);
        });
        return;
    }

    CFRunLoopAddTimer(m_runLoop->m_runLoop.get(), m_timer.get(), kCFRunLoopCommonModes);
}

void RunLoop::TimerBase::stop()
{
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
