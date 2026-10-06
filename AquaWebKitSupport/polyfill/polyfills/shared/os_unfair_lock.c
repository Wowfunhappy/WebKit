/*
 * os_unfair_lock (10.12+) on the 10.9 kernel.
 *
 * The lock word is the owner's mach thread port, zero while free, the layout libplatform's
 * os_unfair_lock keeps. A contended acquire parks on the owner with thread_switch(owner,
 * SWITCH_OPTION_OSLOCK_*): the kernel hands the waiter's processor to the owner whenever the
 * owner is runnable, the handoff ulock_wait performs from 10.12 on. There is no ulock here to
 * wake the waiter from the unlock, so each wait is timed and re-armed; the wait protocol --
 * OSLOCK_DEPRESS for the first hundred rounds, then OSLOCK_WAIT -- is the one 10.9's own
 * os_lock_handoff (libplatform) runs. OS_UNFAIR_LOCK_ADAPTIVE_SPIN, the request to spin while
 * the owner is on core, spins for the ulock budget (ulock_adaptive_spin_usecs, 20us) before the
 * first handoff.
 *
 * Plain C, no wk_polyfill.h: the vendored non-WebKit binaries (the GStreamer/FFmpeg media
 * stack) compile this same source, and they carry no polyfill registry. One definition, used
 * by all of them. Diagnostics go to syslog: WebContent has no stderr.
 */

#include <mach/kern_return.h>
#include <mach/mach_time.h>
#include <mach/mach_traps.h>
#include <mach/message.h>
#include <stdbool.h>
#include <stdint.h>
#include <syslog.h>

#include <os/lock.h>

/* osfmk/mach/thread_switch.h, PRIVATE. */
#define SWITCH_OPTION_OSLOCK_DEPRESS 4
#define SWITCH_OPTION_OSLOCK_WAIT    5

#define OSLOCK_DEPRESS_ROUNDS 100
#define HANDOFF_TIMEOUT_MS    1
#define ADAPTIVE_SPIN_USECS   20

/* TSD slot 3, __TSD_MACH_THREAD_SELF: the port pthread_mach_thread_np() returns, and the owner id
 * libplatform's handoff lock reads. A thread the slot is not yet set for is owner UINT32_MAX. */
#define TSD_MACH_THREAD_SELF_OFFSET (3 * sizeof(void *))

static inline uint32_t self_tid(void)
{
	uintptr_t tid;
#if defined(__x86_64__)
	__asm__("movq %%gs:%c1, %0" : "=r"(tid) : "i"(TSD_MACH_THREAD_SELF_OFFSET));
#elif defined(__i386__)
	__asm__("movl %%gs:%c1, %0" : "=r"(tid) : "i"(TSD_MACH_THREAD_SELF_OFFSET));
#else
#error os_unfair_lock: no TSD access for this architecture
#endif
	return tid ? (uint32_t)tid : UINT32_MAX;
}

static inline uint32_t *word(const os_unfair_lock *lock)
{
	return (uint32_t *)&lock->_os_unfair_lock_opaque;
}

static uint64_t adaptive_spin_ticks(void)
{
	static uint64_t ticks;
	uint64_t cached = __atomic_load_n(&ticks, __ATOMIC_RELAXED);
	if (!cached) {
		mach_timebase_info_data_t timebase;
		mach_timebase_info(&timebase);
		cached = ADAPTIVE_SPIN_USECS * 1000ull * timebase.denom / timebase.numer;
		__atomic_store_n(&ticks, cached, __ATOMIC_RELAXED);
	}
	return cached;
}

static inline bool acquire(uint32_t *w, uint32_t self, uint32_t *owner)
{
	*owner = 0;
	return __atomic_compare_exchange_n(w, owner, self, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED);
}

__attribute__((noreturn, noinline, cold))
static void client_crash(const char *what, const os_unfair_lock *lock, uint32_t owner)
{
	syslog(LOG_ERR, "[wk_polyfill] os_unfair_lock %p: %s (owner 0x%x, self 0x%x)",
	       (const void *)lock, what, owner, self_tid());
	__builtin_trap();
}

__attribute__((noinline))
static void lock_slow(os_unfair_lock_t lock, uint32_t self, uint32_t owner, bool adaptive_spin)
{
	uint32_t *w = word(lock);
	int option = SWITCH_OPTION_OSLOCK_DEPRESS;
	unsigned rounds = 0;

	for (;;) {
		if (owner == self)
			client_crash("lock held by current thread", lock, owner);
		if (adaptive_spin) {
			uint64_t deadline = mach_absolute_time() + adaptive_spin_ticks();
			while (owner && mach_absolute_time() < deadline) {
				__builtin_ia32_pause();
				owner = __atomic_load_n(w, __ATOMIC_RELAXED);
			}
			adaptive_spin = false;
		}
		if (owner) {
			thread_switch(owner, option, HANDOFF_TIMEOUT_MS);
			if (++rounds == OSLOCK_DEPRESS_ROUNDS)
				option = SWITCH_OPTION_OSLOCK_WAIT;
		}
		if (acquire(w, self, &owner))
			return;
	}
}

void os_unfair_lock_lock(os_unfair_lock_t lock)
{
	uint32_t self = self_tid(), owner;
	if (__builtin_expect(acquire(word(lock), self, &owner), 1))
		return;
	lock_slow(lock, self, owner, false);
}

void os_unfair_lock_lock_with_options(os_unfair_lock_t lock, os_unfair_lock_options_t options)
{
	uint32_t self = self_tid(), owner;
	if (__builtin_expect(acquire(word(lock), self, &owner), 1))
		return;
	lock_slow(lock, self, owner, options & OS_UNFAIR_LOCK_ADAPTIVE_SPIN);
}

void os_unfair_lock_lock_with_flags(os_unfair_lock_t lock, os_unfair_lock_flags_t flags)
{
	os_unfair_lock_lock_with_options(lock, flags);
}

bool os_unfair_lock_trylock(os_unfair_lock_t lock)
{
	uint32_t owner;
	return acquire(word(lock), self_tid(), &owner);
}

void os_unfair_lock_unlock(os_unfair_lock_t lock)
{
	uint32_t owner = self_tid();
	if (__builtin_expect(__atomic_compare_exchange_n(word(lock), &owner, 0, false,
	                                                 __ATOMIC_RELEASE, __ATOMIC_RELAXED), 1))
		return;
	client_crash("unlock of a lock not owned by current thread", lock, owner);
}

void os_unfair_lock_assert_owner(const os_unfair_lock *lock)
{
	uint32_t owner = __atomic_load_n(word(lock), __ATOMIC_RELAXED);
	if (owner != self_tid())
		client_crash("assertion failed: lock unexpectedly not owned by current thread", lock, owner);
}

void os_unfair_lock_assert_not_owner(const os_unfair_lock *lock)
{
	uint32_t owner = __atomic_load_n(word(lock), __ATOMIC_RELAXED);
	if (owner == self_tid())
		client_crash("assertion failed: lock unexpectedly owned by current thread", lock, owner);
}
