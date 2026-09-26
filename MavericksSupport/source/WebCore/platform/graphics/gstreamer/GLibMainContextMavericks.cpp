// GLib's external-loop protocol on the main run loop. The main thread owns the default context and
// iterates it (prepare, query, a non-blocking poll, check, dispatch); while nothing is ready, a
// helper thread blocks in the poll on the queried descriptors and the queried timeout.
//
// Each context iteration is RunLoop work: the GLib ports attach bus watches at
// RunLoopSourcePriority::RunLoopDispatcher, the priority of RunLoop::dispatch(), so RunLoop work
// that a dispatched callback queues runs before the context's next iteration.
//
// GLib wakes an owned context only for sources attached from other threads, so before the run loop
// waits or exits the main thread prepares and queries the context again, which picks up sources and
// timeouts it added itself.

#include "config.h"
#include "GLibMainContextMavericks.h"

#if USE(GLIB) && PLATFORM(COCOA)

#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <cerrno>
#include <cmath>
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

    void queueIteration()
    {
        if (!m_iterationQueued.exchange(true)) {
            RunLoop::mainSingleton().dispatch([this] {
                iterate();
            });
        }
    }

    void iterate()
    {
        ASSERT(isMainThread());
        m_iterationQueued = false;
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

    void arm(int timeout)
    {
        if (!timeout) {
            queueIteration();
            return;
        }

        std::optional<MonotonicTime> deadline;
        if (timeout > 0)
            deadline = MonotonicTime::now() + Seconds::fromMilliseconds(timeout);

        Locker locker { m_lock };
        bool sameSet = m_pollFDs.size() == m_fds.size();
        for (size_t i = 0; sameSet && i < m_fds.size(); ++i)
            sameSet = m_pollFDs[i].fd == m_fds[i].fd && m_pollFDs[i].events == m_fds[i].events;
        bool sameDeadline = deadline == m_pollDeadline || (deadline && m_pollDeadline && *deadline >= *m_pollDeadline);
        if (sameSet && sameDeadline && m_pollArmed)
            return;

        m_pollFDs = m_fds;
        m_pollDeadline = deadline;
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
            std::optional<MonotonicTime> deadline;
            uint64_t request;
            {
                Locker locker { m_lock };
                while (m_request == signaled)
                    m_condition.wait(m_lock);
                request = m_request;
                fds = m_pollFDs;
                deadline = m_pollDeadline;
            }

            fds.append({ m_wakePipe[0], G_IO_IN, 0 });
            int result;
            do {
                int timeout = -1;
                if (deadline)
                    timeout = std::max<int>(0, std::ceil((*deadline - MonotonicTime::now()).milliseconds()));
                result = g_poll(fds.mutableSpan().data(), fds.size(), timeout);
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
            queueIteration();
        }
    }

    GMainContext* m_context { nullptr };
    RetainPtr<CFRunLoopObserverRef> m_observer;
    std::atomic<bool> m_iterationQueued { false };
    int m_wakePipe[2] { -1, -1 };

    int m_maxPriority { 0 };
    Vector<GPollFD> m_fds;

    Lock m_lock;
    Condition m_condition;
    Vector<GPollFD> m_pollFDs WTF_GUARDED_BY_LOCK(m_lock);
    std::optional<MonotonicTime> m_pollDeadline WTF_GUARDED_BY_LOCK(m_lock);
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
