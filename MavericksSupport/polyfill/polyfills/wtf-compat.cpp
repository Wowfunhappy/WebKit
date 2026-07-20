// Legacy WTF entry points for Safari 7.0.6 on macOS 10.9.5. Safari's WebKit binds
// against the WTF C++ API of its era (currentTime, monotonicallyIncreasingTime, the
// threadID-based thread calls, callOnMainThread/cancelCallOnMainThread, the
// atomically-initialized static mutex, ...); modern WTF (615) no longer exports
// these, so this unit defines them. Force-loaded into JavaScriptCore.

#include <pthread.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace WTF {

// WTF::initializeThreading(): a no-op — modern WTF initializes threading on demand.
void initializeThreading() {
}

// WTF::currentTime() (modern WTF: WallTime::now())
double currentTime() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

// WTF::monotonicallyIncreasingTime() (modern WTF: MonotonicTime::now())
double monotonicallyIncreasingTime() {
    static mach_timebase_info_data_t info;
    if (info.denom == 0)
        mach_timebase_info(&info);
    uint64_t t = mach_absolute_time();
    return (double)(t * info.numer / info.denom) / 1e9;
}

// WTF::ThreadIdentifier and the threadID-based thread calls.
//
// A Safari-7 WTF::ThreadIdentifier is a 32-bit index handed out by WTF's own thread map,
// NOT a pthread_t: Safari stores it in a 32-bit field and tests it against 0 to mean "no
// thread" (CoalescedAsynchronousWriter keeps m_threadID at +0x40 and guards every
// detach/join with `testl %edi,%edi; je`). So identifiers start at 1, are never 0, and are
// never reused; a pthread_t is reachable only by looking one up in this table.
//
// The table is a small vector under a mutex — the identified threads are few (Safari makes
// one per coalesced write, one message run loop, one URL-completion lookup) — plus a
// thread-specific key caching the current thread's identifier. The key is what makes
// currentThread() correct rather than a pthread_t comparison: a pthread_t is recycled after
// a thread exits, so matching on the handle would hand a new thread a dead thread's
// identifier.
namespace {

struct ThreadRecord {
    unsigned int id;
    pthread_t handle;
    // True while WE own the handle, i.e. it was created by createThread() and has not yet
    // been joined or detached. Records for threads we merely identified (currentThread() on
    // a thread Safari or the system created) are not ours to join, detach or outlive.
    bool joinable;
};

pthread_mutex_t s_threadTableMutex = PTHREAD_MUTEX_INITIALIZER;
std::vector<ThreadRecord>* s_threadTable = nullptr;
unsigned int s_nextThreadID = 1;

pthread_key_t s_threadIDKey;
pthread_once_t s_threadIDKeyOnce = PTHREAD_ONCE_INIT;

// Drops the record for a thread that has exited. A createThread() thread's record has to
// outlive its body, because waitForThreadCompletion()/detachThread() still needs the handle
// afterwards; only a record we do not own is retired here.
void forgetIdentifiedThread(void* value) {
    unsigned int id = (unsigned int)(uintptr_t)value;
    pthread_mutex_lock(&s_threadTableMutex);
    if (s_threadTable) {
        for (auto it = s_threadTable->begin(); it != s_threadTable->end(); ++it) {
            if (it->id == id && !it->joinable) {
                s_threadTable->erase(it);
                break;
            }
        }
    }
    pthread_mutex_unlock(&s_threadTableMutex);
}

void createThreadIDKey() {
    pthread_key_create(&s_threadIDKey, forgetIdentifiedThread);
}

// Caller holds s_threadTableMutex.
unsigned int allocateThreadIDLocked() {
    if (!s_threadTable)
        s_threadTable = new std::vector<ThreadRecord>();
    unsigned int id = s_nextThreadID++;
    if (!id)                          // 0 is Safari's "no thread"; skip it if we ever wrap
        id = s_nextThreadID++;
    return id;
}

// Caller holds s_threadTableMutex. Returns nullptr if there is no such identifier.
ThreadRecord* findThreadLocked(unsigned int id) {
    if (!s_threadTable)
        return nullptr;
    for (ThreadRecord& record : *s_threadTable) {
        if (record.id == id)
            return &record;
    }
    return nullptr;
}

struct ThreadStart {
    void (*func)(void*);
    void* arg;
    unsigned int id;
    char name[64];                    // pthread_setname_np truncates at MAXTHREADNAMESIZE (64)
};

void* threadEntryPoint(void* context) {
    ThreadStart* start = static_cast<ThreadStart*>(context);
    pthread_once(&s_threadIDKeyOnce, createThreadIDKey);
    pthread_setspecific(s_threadIDKey, (void*)(uintptr_t)start->id);
    // Darwin's pthread_setname_np names the CALLING thread, so the name has to be applied
    // here rather than by createThread() — which is where WTF applies it too
    // (initializeCurrentThreadInternal, run from the new thread).
    if (start->name[0])
        pthread_setname_np(start->name);
    void (*func)(void*) = start->func;
    void* arg = start->arg;
    delete start;
    func(arg);
    return nullptr;
}

} // namespace

// WTF::currentThread() (modern WTF: Thread::current())
unsigned int currentThread() {
    pthread_once(&s_threadIDKeyOnce, createThreadIDKey);
    unsigned int id = (unsigned int)(uintptr_t)pthread_getspecific(s_threadIDKey);
    if (id)
        return id;
    // A thread we did not create asking for its identifier: establish one, as WTF does.
    pthread_mutex_lock(&s_threadTableMutex);
    id = allocateThreadIDLocked();
    s_threadTable->push_back(ThreadRecord { id, pthread_self(), false });
    pthread_mutex_unlock(&s_threadTableMutex);
    pthread_setspecific(s_threadIDKey, (void*)(uintptr_t)id);
    return id;
}

// WTF::createThread() (modern WTF: Thread::create())
unsigned int createThread(void (*func)(void*), void* arg, const char* name) {
    pthread_once(&s_threadIDKeyOnce, createThreadIDKey);

    // The whole creation runs under the table mutex so the new thread cannot observe its own
    // identifier before the record carrying its handle exists: Safari's URL-completion body
    // calls detachThread(currentThread()) as its last act, and that lookup must find the
    // handle even if the body races ahead of pthread_create() returning here.
    pthread_mutex_lock(&s_threadTableMutex);
    unsigned int id = allocateThreadIDLocked();

    ThreadStart* start = new ThreadStart;
    start->func = func;
    start->arg = arg;
    start->id = id;
    start->name[0] = '\0';
    if (name) {
        strncpy(start->name, name, sizeof(start->name) - 1);
        start->name[sizeof(start->name) - 1] = '\0';
    }

    pthread_t handle;
    if (pthread_create(&handle, nullptr, threadEntryPoint, start) != 0) {
        delete start;
        pthread_mutex_unlock(&s_threadTableMutex);
        return 0;                     // WTF returns 0 on failure; Safari tests for it
    }
    s_threadTable->push_back(ThreadRecord { id, handle, true });
    pthread_mutex_unlock(&s_threadTableMutex);
    return id;
}

// WTF::detachThread()
void detachThread(unsigned int threadID) {
    pthread_t handle;
    bool owned = false;
    pthread_mutex_lock(&s_threadTableMutex);
    if (ThreadRecord* record = findThreadLocked(threadID)) {
        if (record->joinable) {
            handle = record->handle;
            owned = true;
            s_threadTable->erase(s_threadTable->begin() + (record - s_threadTable->data()));
        }
    }
    pthread_mutex_unlock(&s_threadTableMutex);
    // Dropped the record first: the identifier is retired before the handle can be reused,
    // so a second detach or a join of the same identifier is a no-op instead of undefined.
    if (owned)
        pthread_detach(handle);
}

// WTF::waitForThreadCompletion() — returns pthread_join's result, as the WTF of this era did.
int waitForThreadCompletion(unsigned int threadID) {
    pthread_t handle;
    bool owned = false;
    pthread_mutex_lock(&s_threadTableMutex);
    if (ThreadRecord* record = findThreadLocked(threadID)) {
        if (record->joinable) {
            handle = record->handle;
            owned = true;
            s_threadTable->erase(s_threadTable->begin() + (record - s_threadTable->data()));
        }
    }
    pthread_mutex_unlock(&s_threadTableMutex);
    if (!owned)
        return ESRCH;
    return pthread_join(handle, nullptr);
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

// WTF::Mutex (modern WTF: Lock)
class Mutex {
    pthread_mutex_t m_mutex;
public:
    Mutex() { pthread_mutex_init(&m_mutex, nullptr); }
};

// WTF::ThreadCondition (modern WTF: Condition)
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

// WTF::callOnMainThread(Function<void()> const&) — the function-object overload.
//
// Safari 7's WTF::Function<void()> (wtf/Functional.h of that era) is exactly one word: a
// RefPtr<FunctionImplBase>, so the const& we are handed points at a single pointer that may
// be null. The pointee's layout, read straight out of Safari's own inlined uses of it
// (WTF::Function<void()>::operator block_pointer() const, and the ref/deref sequences around
// each call site):
//
//     +0x00  vptr        vtable[0] = ~FunctionImplBase()  (complete, D1)
//                        vtable[1] = ~FunctionImplBase()  (deleting, D0)
//                        vtable[2] = FunctionImpl<void()>::operator()()
//     +0x08  int m_refCount, constructed as 1 (ThreadSafeRefCounted)
//
// ref() is `lock incl 8(%rdi)`; deref() is `lock xaddl $-1, 8(%rdi)` followed by a call
// through vtable[1] when the count reaches 0. Invocation is `movq (%rdi),%rax; call *0x10(%rax)`
// with the impl itself as `this` — no thunk adjustment, the hierarchy is single inheritance.
//
// Lifetime: the Function is a caller-owned temporary. Both of Safari's call sites build the
// impl, store it into a stack slot, pass &slot, and deref the impl the instant we return —
// which destroys it if we did not take our own reference. So we ref() on entry and deref()
// after the invocation, which is what WTF's own implementation did by copying the Function.
namespace {

struct LegacyFunctionImpl {
    void** vtable;
    int refCount;
};

inline void refFunctionImpl(LegacyFunctionImpl* impl) {
    __sync_fetch_and_add(&impl->refCount, 1);
}

inline void derefFunctionImpl(LegacyFunctionImpl* impl) {
    if (__sync_fetch_and_sub(&impl->refCount, 1) <= 1)
        reinterpret_cast<void (*)(LegacyFunctionImpl*)>(impl->vtable[1])(impl);
}

inline void invokeFunctionImpl(LegacyFunctionImpl* impl) {
    reinterpret_cast<void (*)(LegacyFunctionImpl*)>(impl->vtable[2])(impl);
}

} // namespace

// The type only has to mangle the way Safari's import does; its one member is the RefPtr above.
template<typename> class Function;
template<> class Function<void()> {
public:
    LegacyFunctionImpl* m_impl;
};

void callOnMainThread(const Function<void()>& function) {
    LegacyFunctionImpl* impl = function.m_impl;
    if (!impl)
        return;
    refFunctionImpl(impl);
    // Asynchronous even when the caller is already the main thread, as WTF's is.
    dispatch_async(dispatch_get_main_queue(), ^{
        invokeFunctionImpl(impl);
        derefFunctionImpl(impl);
    });
}

} // namespace WTF
