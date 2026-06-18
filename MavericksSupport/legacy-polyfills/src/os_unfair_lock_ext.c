/*
 * os_unfair_lock_lock_with_flags / _with_options (10.15+) --
 * custom polyfill (not from macports-legacy-support).
 *
 * Fall back to the plain os_unfair_lock_lock that this library also provides
 * (on top of OSSpinLock, see os_unfair_lock.c).
 */

#include <stdint.h>

extern void os_unfair_lock_lock(void *lock);

void os_unfair_lock_lock_with_flags(void *lock, uint32_t flags) {
	(void)flags;
	os_unfair_lock_lock(lock);
}

void os_unfair_lock_lock_with_options(void *lock, uint32_t options) {
	(void)options;
	os_unfair_lock_lock(lock);
}
