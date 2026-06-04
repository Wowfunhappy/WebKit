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
    // 10.9: dispatch_main() calls pthread_exit on the main thread (so dispatch
    // workers can take over), which triggers pthread TSD cleanup, which destroys
    // the per-thread RunLoop Holder, freeing the main RunLoop. After that point
    // s_mainRunLoop dangles. Pin the main RunLoop with multiple ref bumps to
    // make absolutely sure deref() can never reach zero from any other path.
    auto& mrl = RunLoop::currentSingleton();
    // Pre-transition the singleton to control block mode by taking a
    // ThreadSafeWeakPtr explicitly, then leak that weak. This ensures the
    // control block exists with a permanent weak ref so the underlying
    // ThreadSafeWeakPtrControlBlock is never freed (which would otherwise
    // happen when the last weak ref releases it). After that bump the strong
    // refcount through the control block by many refs to make destruction
    // through that path unreachable too.
    {
        auto* leaked = new ThreadSafeWeakPtr<RunLoop>(mrl);
        (void)leaked;
    }
    for (int i = 0; i < 100000; ++i)
        mrl.ref();
    s_mainRunLoop = &mrl;
    {
        FILE *_d = ((FILE*)0);
        if (_d) {
            uintptr_t bits = 0;
            if (s_mainRunLoop) memcpy(&bits, (char*)s_mainRunLoop + 0x8, sizeof(bits));
            fprintf(_d, "[PID %d] initializeMain s_mainRunLoop=%p m_bits=0x%llx\n",
                getpid(), s_mainRunLoop, (unsigned long long)bits);
            fclose(_d);
        }
    }
}

auto RunLoop::runLoopHolder() -> ThreadSpecific<Holder>&
{
    static NeverDestroyed<ThreadSpecific<Holder>> runLoopHolder;
    return runLoopHolder;
}

RunLoop& RunLoop::currentSingleton()
{
    // 10.9 backport: dispatch_main() pthread_exits the real main thread, so
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
    {
        FILE *_d = ((FILE*)0);
        if (_d) {
            uintptr_t bits = 0;
            if (s_mainRunLoop) memcpy(&bits, (char*)s_mainRunLoop + 0x8, sizeof(bits));
            fprintf(_d, "[PID %d] mainSingleton() s_mainRunLoop=%p m_bits=0x%llx\n",
                getpid(), s_mainRunLoop, (unsigned long long)bits);
            fclose(_d);
        }
    }
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
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[RunLoop::performWork PID %d] this=%p\n", getpid(), this); fclose(_d);}}
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
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[RunLoop::dispatch PID %d] this=%p needsWakeup=%d\n", getpid(), this, needsWakeup); fclose(_d);}}

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
