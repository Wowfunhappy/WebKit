// WTF API compatibility shims for Safari 9.1.3 on macOS 10.9
// Maps old WTF API (WebKit ~601) to modern WTF API (WebKit 615)

#include <pthread.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace WTF {

// WTF::initializeThreading() - was removed, threading is auto-initialized
void initializeThreading() {
    // No-op in modern WebKit - threading is initialized automatically
}

// WTF::currentTime() -> replaced by WallTime::now()
double currentTime() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

// WTF::monotonicallyIncreasingTime() -> replaced by MonotonicTime::now()
double monotonicallyIncreasingTime() {
    static mach_timebase_info_data_t info;
    if (info.denom == 0)
        mach_timebase_info(&info);
    uint64_t t = mach_absolute_time();
    return (double)(t * info.numer / info.denom) / 1e9;
}

// WTF::currentThread() -> replaced by Thread::current()
unsigned int currentThread() {
    return (unsigned int)(uintptr_t)pthread_self();
}

// WTF::createThread() -> replaced by Thread::create()
unsigned int createThread(void (*func)(void*), void* arg, const char* name) {
    pthread_t thread;
    pthread_create(&thread, nullptr, (void*(*)(void*))func, arg);
    if (name)
        pthread_setname_np(name);
    return (unsigned int)(uintptr_t)thread;
}

// WTF::detachThread()
void detachThread(unsigned int threadID) {
    pthread_detach((pthread_t)(uintptr_t)threadID);
}

// WTF::waitForThreadCompletion()
void waitForThreadCompletion(unsigned int threadID) {
    pthread_join((pthread_t)(uintptr_t)threadID, nullptr);
}

// WTF::callOnMainThread(void(*)(void*), void*) and cancelCallOnMainThread().
//
// The old (Safari-7-era) WTF API lets a caller SCHEDULE a function+context to run
// on the main thread and later CANCEL it if it is no longer wanted. Safari relies
// on this: e.g. CoalescedAsynchronousWriter schedules
// callOnMainThread(postWriteMainThreadCleanup, this) and, when it is destroyed,
// calls cancelCallOnMainThread(postWriteMainThreadCleanup, this). If cancellation
// is a no-op, the already-scheduled callback fires on the freed object → "pointer
// being freed was not allocated" / heap corruption that crashes the UI process
// during navigation. So cancellation must really work.
//
// dispatch blocks can't be unscheduled, so we keep a registry of pending calls;
// the dispatched block runs the function only if its record is still live and not
// cancelled, and cancelCallOnMainThread marks matching records cancelled.
namespace {
struct MainThreadCall {
    void (*func)(void*);
    void* ctx;
    bool cancelled;
};
pthread_mutex_t s_mainThreadCallsMutex = PTHREAD_MUTEX_INITIALIZER;
std::vector<MainThreadCall*>* s_mainThreadCalls = nullptr;
}

void callOnMainThread(void (*func)(void*), void* ctx) {
    MainThreadCall* call = new MainThreadCall { func, ctx, false };
    pthread_mutex_lock(&s_mainThreadCallsMutex);
    if (!s_mainThreadCalls)
        s_mainThreadCalls = new std::vector<MainThreadCall*>();
    s_mainThreadCalls->push_back(call);
    pthread_mutex_unlock(&s_mainThreadCallsMutex);

    dispatch_async(dispatch_get_main_queue(), ^{
        bool shouldRun = false;
        pthread_mutex_lock(&s_mainThreadCallsMutex);
        if (s_mainThreadCalls) {
            for (auto it = s_mainThreadCalls->begin(); it != s_mainThreadCalls->end(); ++it) {
                if (*it == call) {
                    shouldRun = !call->cancelled;
                    s_mainThreadCalls->erase(it);
                    break;
                }
            }
        }
        pthread_mutex_unlock(&s_mainThreadCallsMutex);
        if (shouldRun)
            call->func(call->ctx);
        delete call;
    });
}

// Cancels any still-pending call scheduled with the same (func, ctx). The record
// is only removed/freed by the dispatched block itself, so we just flag it here.
void cancelCallOnMainThread(void (*func)(void*), void* ctx) {
    pthread_mutex_lock(&s_mainThreadCallsMutex);
    if (s_mainThreadCalls) {
        for (MainThreadCall* call : *s_mainThreadCalls) {
            if (call->func == func && call->ctx == ctx)
                call->cancelled = true;
        }
    }
    pthread_mutex_unlock(&s_mainThreadCallsMutex);
}

// WTF::Mutex - replaced by Lock
class Mutex {
    pthread_mutex_t m_mutex;
public:
    Mutex() { pthread_mutex_init(&m_mutex, nullptr); }
};

// WTF::ThreadCondition - replaced by Condition
class ThreadCondition {
    pthread_cond_t m_cond;
public:
    ThreadCondition() { pthread_cond_init(&m_cond, nullptr); }
};

// WTF::numberToFixedWidthString
void numberToFixedWidthString(double value, unsigned int width, char* buf) {
    snprintf(buf, 32, "%.*f", width, value);
}

// WTF::lockAtomicallyInitializedStaticMutex / unlock
static pthread_mutex_t s_atomicInitMutex = PTHREAD_MUTEX_INITIALIZER;
void lockAtomicallyInitializedStaticMutex() {
    pthread_mutex_lock(&s_atomicInitMutex);
}
void unlockAtomicallyInitializedStaticMutex() {
    pthread_mutex_unlock(&s_atomicInitMutex);
}

// WTF::callOnMainThread(Function<void()> const&) - C++ function object version
// This needs the WTF::Function type. Use a simple dispatch wrapper.
class Function_void {
public:
    void operator()() const;
};
void callOnMainThread(const Function_void& func) {
    // Copy and dispatch
    dispatch_async(dispatch_get_main_queue(), ^{
        func();
    });
}

} // namespace WTF
