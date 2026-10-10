// The main thread owns GLib's default context and runs one GLib round per timer callout.
// Ready work and GLib deadlines share one main-thread RunLoop timer; the helper polls descriptors only.
// Before-waiting and exit observers prepare sources added on the main thread.

#include "config.h"
#include "GLibMainContextAquaWebKit.h"

#if USE(GLIB) && PLATFORM(COCOA)

#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <cerrno>
#include <fcntl.h>
#include <glib.h>
#include <mutex>
#include <optional>
#include <unistd.h>
#include <wtf/Condition.h>
#include <wtf/Lock.h>
#include <wtf/MainThread.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RetainPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/Threading.h>
#include <wtf/Vector.h>

namespace WebCore {

namespace {

class MainContextPump {
public:
    static MainContextPump& singleton()
    {
        static NeverDestroyed<MainContextPump> pump;
        return pump;
    }

    void attach()
    {
        ASSERT(isMainThread());
        m_context = g_main_context_default();
        g_main_context_acquire(m_context);

        pipe(m_wakePipe);
        fcntl(m_wakePipe[0], F_SETFL, O_NONBLOCK);
        fcntl(m_wakePipe[1], F_SETFL, O_NONBLOCK);

        CFRunLoopObserverContext observerContext { };
        observerContext.info = this;
        m_observer = adoptCF(CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 1, [](CFRunLoopObserverRef, CFRunLoopActivity, void* info) {
            static_cast<MainContextPump*>(info)->prepareBeforeWaitingOrExit();
        }, &observerContext));
        CFRunLoopAddObserver(CFRunLoopGetMain(), m_observer.get(), kCFRunLoopCommonModes);

        Thread::create("GLib main context poller"_s, [this] {
            pollLoop();
        })->detach();

        prepareBeforeWaitingOrExit();
    }

private:
    friend class NeverDestroyed<MainContextPump>;
    MainContextPump() = default;

    // Returns the timeout g_main_context_query() asks for; 0 when a source is ready without polling.
    int prepareAndQuery()
    {
        bool ready = g_main_context_prepare(m_context, &m_maxPriority);
        int timeout = -1;
        int count = m_fds.size() ? m_fds.size() : 8;
        do {
            m_fds.resize(count);
            count = g_main_context_query(m_context, m_maxPriority, &timeout, m_fds.mutableSpan().data(), m_fds.size());
        } while (static_cast<size_t>(count) > m_fds.size());
        m_fds.shrink(count);
        return ready ? 0 : timeout;
    }

    bool pollNow()
    {
        return g_poll(m_fds.mutableSpan().data(), m_fds.size(), 0) > 0;
    }

    void clearResults()
    {
        for (auto& fd : m_fds)
            fd.revents = 0;
    }

    void scheduleIteration(Seconds delay)
    {
        ASSERT(isMainThread());
        auto fireTime = MonotonicTime::now() + delay;
        if (m_nextFireTime && *m_nextFireTime <= fireTime)
            return;
        m_nextFireTime = fireTime;
        m_iterationTimer.startOneShot(delay);
    }

    void iterate()
    {
        ASSERT(isMainThread());
        disarm();
        int timeout = prepareAndQuery();
        pollNow();
        bool dispatched = g_main_context_check(m_context, m_maxPriority, m_fds.mutableSpan().data(), m_fds.size());
        if (dispatched)
            g_main_context_dispatch(m_context);
        clearResults();
        arm(dispatched ? 0 : timeout);
    }

    void prepareBeforeWaitingOrExit()
    {
        ASSERT(isMainThread());
        int timeout = prepareAndQuery();
        if (timeout && pollNow())
            timeout = 0;
        clearResults();
        arm(timeout);
    }

    // The helper polls only while the main thread is not iterating the context; a run of the pump
    // owns the context's descriptors from its first prepare to its last arm().
    void disarm()
    {
        Locker locker { m_lock };
        if (!m_pollArmed)
            return;
        m_pollArmed = false;
        ++m_request;
        m_condition.notifyOne();
        char byte = 0;
        (void)!write(m_wakePipe[1], &byte, 1);
    }

    void arm(int timeout)
    {
        if (timeout >= 0)
            scheduleIteration(Seconds::fromMilliseconds(timeout));

        if (!timeout)
            return;

        Locker locker { m_lock };
        bool sameSet = m_pollFDs.size() == m_fds.size();
        for (size_t i = 0; sameSet && i < m_fds.size(); ++i)
            sameSet = m_pollFDs[i].fd == m_fds[i].fd && m_pollFDs[i].events == m_fds[i].events;
        if (sameSet && m_pollArmed)
            return;

        m_pollFDs = m_fds;
        m_pollArmed = true;
        ++m_request;
        m_condition.notifyOne();
        char byte = 0;
        (void)!write(m_wakePipe[1], &byte, 1);
    }

    void pollLoop()
    {
        uint64_t signaled = 0;
        while (true) {
            Vector<GPollFD> fds;
            uint64_t request;
            {
                Locker locker { m_lock };
                while (m_request == signaled || !m_pollArmed)
                    m_condition.wait(m_lock);
                request = m_request;
                fds = m_pollFDs;
            }

            fds.append({ m_wakePipe[0], G_IO_IN, 0 });
            int result;
            do {
                result = g_poll(fds.mutableSpan().data(), fds.size(), -1);
            } while (result < 0 && errno == EINTR);
            if (fds.last().revents) {
                char buffer[64];
                while (read(m_wakePipe[0], buffer, sizeof(buffer)) > 0) { }
            }

            bool ready = result <= 0;
            for (size_t i = 0; !ready && i + 1 < fds.size(); ++i)
                ready = fds[i].revents;
            {
                Locker locker { m_lock };
                if (m_request != request || !ready)
                    continue;
                m_pollArmed = false;
            }
            signaled = request;
            if (!m_wakeQueued.exchange(true)) {
                RunLoop::mainSingleton().dispatch([this] {
                    m_wakeQueued = false;
                    scheduleIteration(0_s);
                });
            }
        }
    }

    GMainContext* m_context { nullptr };
    RetainPtr<CFRunLoopObserverRef> m_observer;
    std::optional<MonotonicTime> m_nextFireTime;
    RunLoop::Timer m_iterationTimer { RunLoop::mainSingleton(), "GLib main context"_s, [this] {
        m_nextFireTime.reset();
        iterate();
    } };
    std::atomic<bool> m_wakeQueued { false };
    int m_wakePipe[2] { -1, -1 };

    int m_maxPriority { 0 };
    Vector<GPollFD> m_fds;

    Lock m_lock;
    Condition m_condition;
    Vector<GPollFD> m_pollFDs WTF_GUARDED_BY_LOCK(m_lock);
    bool m_pollArmed WTF_GUARDED_BY_LOCK(m_lock) { false };
    uint64_t m_request WTF_GUARDED_BY_LOCK(m_lock) { 0 };
};

} // namespace

void attachGLibMainContextToMainRunLoop()
{
    static std::once_flag onceFlag;
    std::call_once(onceFlag, [] {
        callOnMainThread([] {
            MainContextPump::singleton().attach();
        });
    });
}

} // namespace WebCore

#endif // USE(GLIB) && PLATFORM(COCOA)
