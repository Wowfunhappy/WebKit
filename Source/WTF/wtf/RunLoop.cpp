/*
 * Copyright (C) 2010 Apple Inc. All rights reserved.
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

// MAVERICKS_BACKPORT: extra includes for the 10.9 main-GCD-queue RunLoop equivalence logic below.
#include <dispatch/dispatch.h>
#include <wtf/Lock.h>
#include <wtf/Vector.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Ref.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/threads/BinarySemaphore.h>

namespace WTF {

SUPPRESS_UNCOUNTED_LOCAL static RunLoop* s_mainRunLoop;
#if USE(WEB_THREAD)
SUPPRESS_UNCOUNTED_LOCAL static RunLoop* s_webRunLoop;
#endif

// Helper class for ThreadSpecificData.
class RunLoop::Holder {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(RunLoop);
public:
    Holder()
        : m_runLoop(adoptRef(*new RunLoop))
    {
    }

    ~Holder()
    {
        m_runLoop->threadWillExit();
    }

    RunLoop& NODELETE runLoop() { return m_runLoop; }

private:
    const Ref<RunLoop> m_runLoop;
};

void RunLoop::initializeMain()
{
    RELEASE_ASSERT(!s_mainRunLoop);
    // MAVERICKS_BACKPORT: no main-RunLoop pinning needed on 10.9 (rationale below).
    // The main thread runs a real CFRunLoop for the whole process lifetime
    // (XPCServiceMain → xpc_main → -[NSRunLoop run], via RunLoopType=NSRunLoop;
    // verified the main thread is parked in __CFRunLoopRun), so its per-thread
    // RunLoop holder keeps the main RunLoop alive — no pinning needed. (The old
    // 100000x ref + leaked weak was a workaround for an earlier dispatch_main()
    // configuration where dispatch_main pthread_exited the main thread and TSD
    // teardown freed the RunLoop; that configuration is gone.)
    s_mainRunLoop = &RunLoop::currentSingleton();
}

auto RunLoop::runLoopHolder() -> ThreadSpecific<Holder>&
{
    static NeverDestroyed<ThreadSpecific<Holder>> runLoopHolder;
    return runLoopHolder;
}

RunLoop& RunLoop::currentSingleton()
{
    // MAVERICKS_BACKPORT: dispatch_main() pthread_exits the real main thread, so
    // blocks on dispatch_get_main_queue() run on transient dispatch workers
    // (each with its own per-thread RunLoop holder). When code constructs an
    // object on the "main" thread (e.g. JSC's VM caches RunLoop::currentSingleton()
    // in m_runLoop), it gets the worker's per-thread RunLoop instead of the
    // real main RunLoop. That breaks RunLoop::TimerBase::start's mainSingleton()
    // guard in RunLoopCF.cpp, falling into the non-pumped CFRunLoopAddTimer
    // path — JSC's DeferredWorkTimer (async WebAssembly.compile / instantiate)
    // never fires. Treat "running on the main GCD queue" as equivalent to the
    // main RunLoop, symmetric to isCurrent()'s existing 10.9 logic.
    if (s_mainRunLoop && dispatch_get_current_queue() == dispatch_get_main_queue())
        return *s_mainRunLoop;
    return runLoopHolder()->runLoop();
}

RunLoop& RunLoop::mainSingleton()
{
    ASSERT(s_mainRunLoop);
    return *s_mainRunLoop;
}

#if USE(WEB_THREAD)
void RunLoop::initializeWeb()
{
    RELEASE_ASSERT(!s_webRunLoop);
    s_webRunLoop = &RunLoop::currentSingleton();
}

RunLoop& RunLoop::webSingleton()
{
    ASSERT(s_webRunLoop);
    return *s_webRunLoop;
}

RunLoop* RunLoop::webIfExists()
{
    return s_webRunLoop;
}
#endif

Ref<RunLoop> RunLoop::create(ASCIILiteral threadName, ThreadType threadType, Thread::QOS qos)
{
    RefPtr<RunLoop> runLoop;
    BinarySemaphore semaphore;
    Thread::create(threadName, [&] SUPPRESS_UNCOUNTED_LAMBDA_CAPTURE {
        auto& current = RunLoop::currentSingleton();
        runLoop = &current;
        semaphore.signal();
        current.run();
    }, threadType, qos)->detach();
    semaphore.wait();
    return runLoop.releaseNonNull();
}

bool RunLoop::isCurrent() const
{
    // Avoid constructing the RunLoop for the current thread if it has not been created yet.
    // MAVERICKS_BACKPORT: also treat the main GCD queue as the main RunLoop (see 10.9 note below).
    if (runLoopHolder().isSet() && this == &RunLoop::currentSingleton())
        return true;
    // 10.9: dispatch_main() calls pthread_exit on the main thread, so blocks
    // dispatched to dispatch_get_main_queue() actually execute on dispatch worker
    // threads (each with its own per-thread RunLoop). When the main RunLoop's
    // wakeUp dispatches performWork to the main queue, the lambda runs on a
    // worker — `currentSingleton()` returns that worker's RunLoop, not us.
    // Treat "running on the main GCD queue" as equivalent to "on main RunLoop".
    if (this == s_mainRunLoop && dispatch_get_current_queue() == dispatch_get_main_queue())
        return true;
    return false;
}

void RunLoop::performWork()
{
    bool didSuspendFunctions = false;

    {
        Locker locker { m_nextIterationLock };

        // If the RunLoop re-enters or re-schedules, we're expected to execute all functions in order.
        while (!m_currentIteration.isEmpty())
            m_nextIteration.prepend(m_currentIteration.takeLast());

        m_currentIteration = std::exchange(m_nextIteration, { });
    }

    while (!m_currentIteration.isEmpty()) {
        if (m_isFunctionDispatchSuspended) {
            didSuspendFunctions = true;
            break;
        }

        auto function = m_currentIteration.takeFirst();
        function();
    }

    // Suspend only for a single cycle.
    m_isFunctionDispatchSuspended = false;
    m_hasSuspendedFunctions = didSuspendFunctions;

    if (m_hasSuspendedFunctions)
        wakeUp();
}

void RunLoop::dispatch(Function<void()>&& function)
{
    RELEASE_ASSERT(function);
    bool needsWakeup = false;

    {
        Locker locker { m_nextIterationLock };
        needsWakeup = m_nextIteration.isEmpty();
        m_nextIteration.append(WTF::move(function));
    }

    if (needsWakeup)
        wakeUp();
}

Ref<RunLoop::DispatchTimer> RunLoop::dispatchAfter(Seconds delay, Function<void()>&& function)
{
    RELEASE_ASSERT(function);
    Ref<DispatchTimer> timer = adoptRef(*new DispatchTimer(*this));
    timer->setFunction([timer = timer.copyRef(), function = WTF::move(function)]() mutable {
        Ref<DispatchTimer> protectedTimer { WTF::move(timer) };
        function();
        protectedTimer->stop();
    });
    timer->startOneShot(delay);
    return timer;
}

void RunLoop::suspendFunctionDispatchForCurrentCycle()
{
    // Don't suspend if there are already suspended functions to avoid unexecuted function pile-up.
    if (m_isFunctionDispatchSuspended || m_hasSuspendedFunctions)
        return;

    m_isFunctionDispatchSuspended = true;
    // Wake up (even if there is nothing to do) to disable suspension.
    wakeUp();
}

void RunLoop::threadWillExit()
{
    m_currentIteration.clear();
    {
        Locker locker { m_nextIterationLock };
        m_nextIteration.clear();
    }
}

void RunLoop::registerTimer(TimerBase& timer)
{
    Locker locker { m_registeredTimerLock };
    m_registeredTimers.add(&timer);
}

void RunLoop::unregisterTimer(TimerBase& timer)
{
    Locker locker { m_registeredTimerLock };
    m_registeredTimers.remove(&timer);
}

String RunLoop::listActiveTimersForLogging() const
{
    Vector<ASCIILiteral> timers;
    {
        Locker locker { m_registeredTimerLock };
        for (auto* timer : m_registeredTimers)
            timers.append(timer->description());
    }

    if (timers.isEmpty())
        return "{ }"_s;

    StringBuilder builder;
    builder.append("{ "_s);
    for (size_t i = 0; i < timers.size() - 1; ++i) {
        builder.append(timers[i]);
        builder.append(", "_s);
    }
    builder.append(timers.last());
    builder.append(" }"_s);
    return builder.toString();
}

} // namespace WTF
