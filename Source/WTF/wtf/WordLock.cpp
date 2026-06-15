/*
 * Copyright (C) 2015-2017 Apple Inc. All rights reserved.
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
 */

#include "config.h"
#include <wtf/WordLock.h>

#include <condition_variable>
#include <mutex>
#include <wtf/Threading.h>

// 10.9 backport instrumentation: record whenever the m_word corruption-recovery
// guard below actually fires, so we can determine whether it is still needed.
// XPC-service stderr is /dev/null, so log to a file via low-level syscalls (safe
// on the rare corruption path; no malloc / no re-entrant WordLock).
#include <atomic>
#include <cstdio>
#include <execinfo.h>
#include <fcntl.h>
#include <unistd.h>

namespace WTF {

namespace {

// This data structure serves three purposes:
//
// 1) A parking mechanism for threads that go to sleep. That involves just a system mutex and
//    condition variable.
//
// 2) A queue node for when a thread is on some WordLock's queue.
//
// 3) The queue head. This is kind of funky. When a thread is the head of a queue, it also serves as
//    the basic queue bookkeeping data structure. When a thread is dequeued, the next thread in the
//    queue takes on the queue head duties.
struct ThreadData {
    // The parking mechanism.
    bool shouldPark { false };
    std::mutex parkingLock;
    std::condition_variable parkingCondition;

    // The queue node.
    ThreadData* nextInQueue { nullptr };

    // The queue itself.
    ThreadData* queueTail { nullptr };
};

} // anonymous namespace

// 10.9 backport: log a corruption-guard trip to a file (see #43). Rare path only.
// Captures the lock address (offset 0 of the owning object, e.g. a
// ThreadSafeWeakPtrControlBlock) and a raw backtrace of the victim thread (the
// one trying to lock the already-corrupted word) for offline symbolication with
// atos. backtrace() only walks the stack (no malloc), safe in this rare path.
static void logWordLockCorruptionTrip(const char* where, uintptr_t value, const void* lockAddr)
{
    static std::atomic<unsigned> s_count { 0 };
    unsigned n = ++s_count;
    void* frames[32];
    int nframes = ::backtrace(frames, 32);
    int fd = ::open("/tmp/wk_wordlock_trips.log", O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0)
        return;
    char buf[1280];
    int len = ::snprintf(buf, sizeof(buf), "WORDLOCK-TRIP #%u pid=%d %s word=0x%llx lock=%p frames=",
        n, static_cast<int>(::getpid()), where, static_cast<unsigned long long>(value), lockAddr);
    for (int i = 0; i < nframes && len > 0 && len < static_cast<int>(sizeof(buf)) - 20; ++i)
        len += ::snprintf(buf + len, sizeof(buf) - len, "%p ", frames[i]);
    if (len > 0 && len < static_cast<int>(sizeof(buf)))
        len += ::snprintf(buf + len, sizeof(buf) - len, "\n");
    if (len > 0)
        (void)::write(fd, buf, static_cast<size_t>(len));
    ::close(fd);
}

// 10.9 backport instrumentation (#43 keystone): declared in ThreadSafeWeakPtr.h. Logs a
// strong-refcount underflow (extra strongDeref / deref-after-destroy) + the culprit's backtrace.
void reportThreadSafeWeakStrongDerefUnderflow(const void* controlBlock, int strongCount, const void* object)
{
    static std::atomic<unsigned> s_udf { 0 };
    unsigned n = ++s_udf;
    void* frames[40];
    int nframes = ::backtrace(frames, 40);
    int fd = ::open("/tmp/wk_wordlock_trips.log", O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0)
        return;
    char buf[1600];
    int len = ::snprintf(buf, sizeof(buf), "STRONGDEREF-UNDERFLOW #%u pid=%d cb=%p count=%d obj=%p frames=",
        n, static_cast<int>(::getpid()), controlBlock, strongCount, object);
    for (int i = 0; i < nframes && len > 0 && len < static_cast<int>(sizeof(buf)) - 20; ++i)
        len += ::snprintf(buf + len, sizeof(buf) - len, "%p ", frames[i]);
    if (len > 0 && len < static_cast<int>(sizeof(buf)))
        len += ::snprintf(buf + len, sizeof(buf) - len, "\n");
    if (len > 0)
        (void)::write(fd, buf, static_cast<size_t>(len));
    ::close(fd);
}

// 10.9 backport instrumentation (#43 keystone): declared in ThreadSafeWeakPtr.h. Logs a
// WEAK-refcount underflow (an extra weakDeref, OR the deferred MainRunLoop deleteObject
// lambda running twice — the suspected double-dispatch). A weak underflow frees the
// control block early -> the surviving ThreadSafeWeakPtr later locks freed m_word -> the
// 0xfffffffe corruption. `where` distinguishes the weakDeref site from the deferred-delete site.
void reportThreadSafeWeakWeakDerefUnderflow(const void* controlBlock, const char* where, const void* object)
{
    static std::atomic<unsigned> s_wudf { 0 };
    unsigned n = ++s_wudf;
    void* frames[40];
    int nframes = ::backtrace(frames, 40);
    int fd = ::open("/tmp/wk_wordlock_trips.log", O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0)
        return;
    char buf[1600];
    int len = ::snprintf(buf, sizeof(buf), "WEAKDEREF-UNDERFLOW #%u pid=%d where=%s cb=%p obj=%p frames=",
        n, static_cast<int>(::getpid()), where, controlBlock, object);
    for (int i = 0; i < nframes && len > 0 && len < static_cast<int>(sizeof(buf)) - 20; ++i)
        len += ::snprintf(buf + len, sizeof(buf) - len, "%p ", frames[i]);
    if (len > 0 && len < static_cast<int>(sizeof(buf)))
        len += ::snprintf(buf + len, sizeof(buf) - len, "\n");
    if (len > 0)
        (void)::write(fd, buf, static_cast<size_t>(len));
    ::close(fd);
}

NEVER_INLINE void WordLock::lockSlow()
{
    unsigned spinCount = 0;

    // This magic number turns out to be optimal based on past JikesRVM experiments.
    const unsigned spinLimit = 40;

    for (;;) {
        uintptr_t currentWordValue = m_word.load();

        // Recovery for memory corruption observed on macOS 10.9 (see unlockSlow). If the
        // queue head portion encodes a value in the low 4GB, it can't be a real ThreadData*
        // and the state is corrupted. Force-reset and retry to acquire normally.
        uintptr_t maybeQueueHead = currentWordValue & ~queueHeadMask;
        if (maybeQueueHead && maybeQueueHead < 0x100000000ULL) {
            logWordLockCorruptionTrip("lockSlow", currentWordValue, this);
            m_word.store(0);
            continue;
        }

        if (!(currentWordValue & isLockedBit)) {
            // It's not possible for someone to hold the queue lock while the lock itself is no longer
            // held, since we will only attempt to acquire the queue lock when the lock is held and
            // the queue lock prevents unlock.
            ASSERT(!(currentWordValue & isQueueLockedBit));
            if (m_word.compareExchangeWeak(currentWordValue, currentWordValue | isLockedBit)) {
                // Success! We acquired the lock.
                return;
            }
        }

        // If there is no queue and we haven't spun too much, we can just try to spin around again.
        if (!(currentWordValue & ~queueHeadMask) && spinCount < spinLimit) {
            spinCount++;
            Thread::yield();
            continue;
        }

        // Need to put ourselves on the queue. Create the queue if one does not exist. This requries
        // owning the queue for a little bit. The lock that controls the queue is itself a spinlock.

        ThreadData me;

        // Reload the current word value, since some time may have passed.
        currentWordValue = m_word.load();

        // We proceed only if the queue lock is not held, the WordLock is held, and we succeed in
        // acquiring the queue lock.
        if ((currentWordValue & isQueueLockedBit)
            || !(currentWordValue & isLockedBit)
            || !m_word.compareExchangeWeak(currentWordValue, currentWordValue | isQueueLockedBit)) {
            Thread::yield();
            continue;
        }
        
        me.shouldPark = true;

        // We own the queue. Nobody can enqueue or dequeue until we're done. Also, it's not possible
        // to release the WordLock while we hold the queue lock.
        ThreadData* queueHead = std::bit_cast<ThreadData*>(currentWordValue & ~queueHeadMask);
        if (queueHead) {
            // Put this thread at the end of the queue.
            queueHead->queueTail->nextInQueue = &me;
            queueHead->queueTail = &me;

            // Release the queue lock.
            currentWordValue = m_word.load();
            ASSERT(currentWordValue & ~queueHeadMask);
            ASSERT(currentWordValue & isQueueLockedBit);
            ASSERT(currentWordValue & isLockedBit);
            m_word.store(currentWordValue & ~isQueueLockedBit);
        } else {
            // Make this thread be the queue-head.
            queueHead = &me;
            me.queueTail = &me;

            // Release the queue lock and install ourselves as the head. No need for a CAS loop, since
            // we own the queue lock.
            currentWordValue = m_word.load();
            ASSERT(~(currentWordValue & ~queueHeadMask));
            ASSERT(currentWordValue & isQueueLockedBit);
            ASSERT(currentWordValue & isLockedBit);
            uintptr_t newWordValue = currentWordValue;
            newWordValue |= std::bit_cast<uintptr_t>(queueHead);
            newWordValue &= ~isQueueLockedBit;
            m_word.store(newWordValue);
        }

        // At this point everyone who acquires the queue lock will see me on the queue, and anyone who
        // acquires me's lock will see that me wants to park. Note that shouldPark may have been
        // cleared as soon as the queue lock was released above, but it will happen while the
        // releasing thread holds me's parkingLock.

        {
            std::unique_lock<std::mutex> locker(me.parkingLock);
            while (me.shouldPark)
                me.parkingCondition.wait(locker);
        }

        ASSERT(!me.shouldPark);
        ASSERT(!me.nextInQueue);
        ASSERT(!me.queueTail);
        
        // Now we can loop around and try to acquire the lock again.
    }
}

NEVER_INLINE void WordLock::unlockSlow()
{
    // The fast path can fail either because of spurious weak CAS failure, or because someone put a
    // thread on the queue, or the queue lock is held. If the queue lock is held, it can only be
    // because someone *will* enqueue a thread onto the queue.

    // Acquire the queue lock, or release the lock. This loop handles both lock release in case the
    // fast path's weak CAS spuriously failed and it handles queue lock acquisition if there is
    // actually something interesting on the queue.
    for (;;) {
        uintptr_t currentWordValue = m_word.load();

        // Recovery for an as-yet-unidentified memory corruption observed on macOS 10.9
        // NetworkProcess: the m_word of certain ThreadSafeWeakPtrControlBlock locks gets
        // corrupted to 0x00000000ffffffff during a strongDeref hold, presumably from a
        // neighboring libdispatch object's writes overwriting offset 0 of the ControlBlock
        // allocation. The corrupted value treats both isLockedBit and isQueueLockedBit as
        // set, so the unlockSlow loop spins forever waiting for the (non-existent) queue
        // lock holder to release. The corrupted "queue head pointer" portion is in the low
        // 4GB which is invalid for any heap pointer. Detect and recover by force-releasing
        // the lock; any threads parked on this lock (which can't actually exist if the
        // queue head is bogus) would never have been wakeable anyway.
        uintptr_t maybeQueueHead = currentWordValue & ~queueHeadMask;
        if (maybeQueueHead && maybeQueueHead < 0x100000000ULL) {
            // The "queue head" portion is non-null but in the low 4GB — impossible for a
            // real ThreadData* on macOS x86_64. The state is corrupted; force-release.
            logWordLockCorruptionTrip("unlockSlow", currentWordValue, this);
            m_word.store(0);
            return;
        }

        ASSERT(currentWordValue & isLockedBit);

        if (currentWordValue == isLockedBit) {
            if (m_word.compareExchangeWeak(isLockedBit, 0)) {
                // The fast path's weak CAS had spuriously failed, and now we succeeded. The lock is
                // unlocked and we're done!
                return;
            }
            // Loop around and try again.
            Thread::yield();
            continue;
        }

        if (currentWordValue & isQueueLockedBit) {
            Thread::yield();
            continue;
        }

        // If it wasn't just a spurious weak CAS failure and if the queue lock is not held, then there
        // must be an entry on the queue.
        ASSERT(currentWordValue & ~queueHeadMask);

        if (m_word.compareExchangeWeak(currentWordValue, currentWordValue | isQueueLockedBit))
            break;
    }

    uintptr_t currentWordValue = m_word.load();
        
    // After we acquire the queue lock, the WordLock must still be held and the queue must be
    // non-empty. The queue must be non-empty since only the lockSlow() method could have held the
    // queue lock and if it did then it only releases it after putting something on the queue.
    ASSERT(currentWordValue & isLockedBit);
    ASSERT(currentWordValue & isQueueLockedBit);
    ThreadData* queueHead = std::bit_cast<ThreadData*>(currentWordValue & ~queueHeadMask);
    ASSERT(queueHead);

    ThreadData* newQueueHead = queueHead->nextInQueue;
    // Either this was the only thread on the queue, in which case we delete the queue, or there
    // are still more threads on the queue, in which case we create a new queue head.
    if (newQueueHead)
        newQueueHead->queueTail = queueHead->queueTail;

    // Change the queue head, possibly removing it if newQueueHead is null. No need for a CAS loop,
    // since we hold the queue lock and the lock itself so nothing about the lock can change right
    // now.
    currentWordValue = m_word.load();
    ASSERT(currentWordValue & isLockedBit);
    ASSERT(currentWordValue & isQueueLockedBit);
    ASSERT((currentWordValue & ~queueHeadMask) == std::bit_cast<uintptr_t>(queueHead));
    uintptr_t newWordValue = currentWordValue;
    newWordValue &= ~isLockedBit; // Release the WordLock.
    newWordValue &= ~isQueueLockedBit; // Release the queue lock.
    newWordValue &= queueHeadMask; // Clear out the old queue head.
    newWordValue |= std::bit_cast<uintptr_t>(newQueueHead); // Install new queue head.
    m_word.store(newWordValue);

    // Now the lock is available for acquisition. But we just have to wake up the old queue head.
    // After that, we're done!

    queueHead->nextInQueue = nullptr;
    queueHead->queueTail = nullptr;

    // We do this carefully because this may run either before or during the parkingLock critical
    // section in lockSlow().
    {
        // Be sure to hold the lock across our call to notify_one() because a spurious wakeup could
        // cause the thread at the head of the queue to exit and delete queueHead.
        std::scoped_lock<std::mutex> locker(queueHead->parkingLock);
        queueHead->shouldPark = false;

        // Doesn't matter if we notify_all() or notify_one() here since the only thread that could be
        // waiting is queueHead.
        queueHead->parkingCondition.notify_one();
    }

    // The old queue head can now contend for the lock again. We're done!
}

} // namespace WTF

