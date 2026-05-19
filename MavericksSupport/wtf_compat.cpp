// WTF API compatibility shims for Safari 9.1.3 on macOS 10.9
// Maps old WTF API (WebKit ~601) to modern WTF API (WebKit 615)

#include <pthread.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>

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

// WTF::callOnMainThread(void(*)(void*), void*)
void callOnMainThread(void (*func)(void*), void* ctx) {
    dispatch_async(dispatch_get_main_queue(), ^{
        func(ctx);
    });
}

// WTF::cancelCallOnMainThread() - no modern equivalent, stub
void cancelCallOnMainThread(void (*)(void*), void*) {
    // No-op - cancellation not supported in modern WTF
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
