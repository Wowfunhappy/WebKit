/*
 * Copyright (C) 2008, 2014 Apple Inc. All rights reserved.
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
 *
 */

#include "config.h"
#include "ThreadGlobalData.h"

#include "CachedResourceRequestInitiatorTypes.h"
#include "EventNames.h"
#include "FontCache.h"
// MAVERICKS_BACKPORT: MainThreadSharedTimer.h for attaching the CF shared timer to the
// process-shared ThreadTimers below.
#include "MainThreadSharedTimer.h"
#include "MIMETypeRegistry.h"
#include "QualifiedNameCache.h"
#include "SharedTimer.h"
#include "ThreadTimers.h"
#include <wtf/MainThread.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/Threading.h>
#include <wtf/text/StringImpl.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ThreadGlobalData);

ThreadGlobalData::ThreadGlobalData()
    : PAL::ThreadGlobalData(Type::WebCoreThreadGlobalData)
    , m_threadTimers(makeUniqueRef<ThreadTimers>())
#ifndef NDEBUG
    , m_isMainThread(isMainThread())
#endif
{
}

ThreadGlobalData::~ThreadGlobalData() = default;

#if PLATFORM(MAC)
// MAVERICKS_BACKPORT: threads whose ThreadTimers heap is serviced by their own run loop
// (worker/worklet threads, which install a SharedTimer via setSharedTimer) opt out of the
// process-shared heap. The flag is per-thread and set once at worker-thread entry, BEFORE
// any timer can arm, so the classification is sticky for the thread's whole lifetime.
static thread_local bool t_useDedicatedThreadTimers;

void setCurrentThreadUsesDedicatedThreadTimers()
{
    t_useDedicatedThreadTimers = true;
}

bool currentThreadUsesSharedThreadTimers()
{
    return !t_useDedicatedThreadTimers;
}

// The ONE process-shared main ThreadTimers. The CF shared timer is attached here (and only
// here) — never to per-thread private instances, which no run loop ever fires.
static ThreadTimers& sharedMainThreadTimers()
{
    static NeverDestroyed<UniqueRef<ThreadTimers>> shared { [] {
        auto timers = makeUniqueRef<ThreadTimers>();
        timers->setSharedTimer(&MainThreadSharedTimer::singleton());
        return timers;
    }() };
    return shared.get();
}
#endif

ThreadTimers& ThreadGlobalData::threadTimers()
{
#if PLATFORM(MAC)
    // MAVERICKS_BACKPORT: WK2 XPC services fragment the "main thread" identity across
    // libdispatch workers, and loader/network callbacks can run WebCore code on threads
    // that fail isMainThread() transiently. Any timer armed via a per-thread private
    // ThreadTimers on such a thread joins a heap NO run loop ever fires — the timer stays
    // isActive() forever and never runs (task #6: nytimes load-event stall, frozen
    // ScriptRunner/parser/load-delay timers, blank ad frames).
    //
    // So the classification must be structural, not time-varying: worker/worklet threads
    // (marked at thread entry; they service their own heap via WorkerDedicatedRunLoop's
    // SharedTimer) keep the upstream per-thread instance; EVERY other thread — main,
    // main-classified dispatch workers, and stray callback threads — shares one process-wide
    // ThreadTimers serviced by the main CF shared timer. Heap mutations are serialized by
    // sharedTimerHeapLock().
    if (t_useDedicatedThreadTimers)
        return m_threadTimers;
    return sharedMainThreadTimers();
#else
    return m_threadTimers;
#endif
}

void ThreadGlobalData::destroy()
{
    if (CheckedPtr fontCache = m_fontCache.get())
        fontCache->invalidate();
    m_fontCache = nullptr;
    m_destroyed = true;
}

#if USE(WEB_THREAD)
static ThreadGlobalData* sharedMainThreadStaticData { nullptr };

void ThreadGlobalData::setWebCoreThreadData()
{
    ASSERT(isWebThread());
    ASSERT(&threadGlobalDataSingleton() != sharedMainThreadStaticData);

    // Set WebThread's ThreadGlobalData object to be the same as the main UI thread.
    Thread::currentSingleton().m_clientData = adoptRef(sharedMainThreadStaticData);

    ASSERT(&threadGlobalDataSingleton() == sharedMainThreadStaticData);
}

ThreadGlobalData& threadGlobalDataSlow()
{
    auto& thread = Thread::currentSingleton();

    // No need to ref the clientData as we're simply returning it right away.
    SUPPRESS_UNCOUNTED_LOCAL if (auto* clientData = thread.m_clientData.get()) [[unlikely]]
        return *static_cast<ThreadGlobalData*>(clientData);

    Ref data = adoptRef(*new ThreadGlobalData);
    if (pthread_main_np()) {
        sharedMainThreadStaticData = data.ptr();
        data->ref();
    }


    // No need to ref clientData here as we've just constructed it.
    SUPPRESS_UNCOUNTED_LOCAL auto* clientData = data.ptr();
    thread.m_clientData = WTF::move(data);
    return *clientData;
}

#else

ThreadGlobalData& threadGlobalDataSlow()
{
    auto& thread = Thread::currentSingleton();
    // No need to ref the clientData as we're simply returning it right away.
    SUPPRESS_UNCOUNTED_LOCAL if (auto* clientData = thread.m_clientData.get()) [[unlikely]]
        return downcast<ThreadGlobalData>(*clientData);

    Ref data = adoptRef(*new ThreadGlobalData);
    // No need to ref clientData here as we've just constructed it.
    SUPPRESS_UNCOUNTED_LOCAL auto* clientData = data.ptr();
    thread.m_clientData = WTF::move(data);
    return *clientData;
}

#endif

void ThreadGlobalData::initializeCachedResourceRequestInitiatorTypes()
{
    ASSERT(!m_cachedResourceRequestInitiatorTypes);
    m_cachedResourceRequestInitiatorTypes = makeUnique<CachedResourceRequestInitiatorTypes>();
}

void ThreadGlobalData::initializeEventNames()
{
    ASSERT(!m_eventNames);
    m_eventNames = EventNames::create();
}

EventNames& ThreadGlobalData::eventNames()
{
    ASSERT(!m_destroyed);
#if PLATFORM(MAC)
    // MAVERICKS_BACKPORT: IDBDatabase (and a few other classes) cache `const EventNames&`
    // members captured at construction. If the originating ThreadGlobalData is destroyed
    // before the cache holder, accessing the cached reference reads freed memory and
    // crashes inside Event::create at the first AtomString deref. Same root cause as
    // QualifiedNameCache / AtomStringTable: per-thread caches don't survive the
    // libdispatch-worker lifecycle on Mac. Share a single process-wide EventNames so
    // the cached references stay valid forever.
    static NeverDestroyed<std::unique_ptr<EventNames>> sharedEventNames { EventNames::create() };
    return *sharedEventNames.get();
#else
    if (!m_eventNames) [[unlikely]]
        initializeEventNames();
    return *m_eventNames;
#endif
}

void ThreadGlobalData::initializeQualifiedNameCache()
{
    ASSERT(!m_qualifiedNameCache);
    m_qualifiedNameCache = makeUnique<QualifiedNameCache>();
}

QualifiedNameCache& ThreadGlobalData::qualifiedNameCache()
{
    ASSERT(!m_destroyed);
#if PLATFORM(MAC)
    // MAVERICKS_BACKPORT: dispatch_get_main_queue() callbacks land on whichever
    // libdispatch worker is available — per-thread caches fragment and race.
    // Use a process-wide singleton like ThreadTimers / AtomStringTable.
    static NeverDestroyed<std::unique_ptr<QualifiedNameCache>> sharedCache { makeUnique<QualifiedNameCache>() };
    return *sharedCache.get();
#else
    if (!m_qualifiedNameCache) [[unlikely]]
        initializeQualifiedNameCache();
    return *m_qualifiedNameCache;
#endif
}

void ThreadGlobalData::initializeMimeTypeRegistryThreadGlobalData()
{
    ASSERT(!m_MIMETypeRegistryThreadGlobalData);
    m_MIMETypeRegistryThreadGlobalData = MIMETypeRegistry::createMIMETypeRegistryThreadGlobalData();
}

void ThreadGlobalData::initializeFontCache()
{
    ASSERT(!m_fontCache);
    m_fontCache = makeUnique<FontCache>();
}

} // namespace WebCore

namespace PAL {

ThreadGlobalData& threadGlobalDataSingleton()
{
    return WebCore::threadGlobalDataSingleton();
}

} // namespace PAL
